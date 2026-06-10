# pike-azure-infra

Reusable **Azure Container Apps** deployment template for Pike projects. Stand up a new
project's infrastructure by scaffolding from here and filling in app-specific values —
instead of copy-pasting and re-editing a whole `infra/` folder each time.

Extracted from three existing pipelines that all share the same backbone:
Log Analytics + Application Insights + Azure Container Registry + Container Apps Environment +
user-assigned managed identity (AcrPull), provisioned by a phased `deploy.ps1` with a 60s
IAM-propagation wait and a two-phase `deployApps` gate.

## What's here

```
modules/        Generic, proven Bicep building blocks (shared, copied into each project)
profiles/       Starting main.bicep + deploy.ps1 per project shape
shared/         Dockerfile.python, Dockerfile.node, .dockerignore
ci/             Optional GitHub Actions OIDC deploy workflow
templates/      parameters.json token skeleton
New-Project.ps1 The scaffolder
Deploy-Wizard.ps1  Interactive end-to-end wizard (login → scaffold → deploy)
```

### Modules

| Module | Purpose | Optional |
|---|---|---|
| `logAnalytics` | Log Analytics workspace (backing store) | no |
| `appInsights` | Workspace-based Application Insights | no |
| `containerRegistry` | ACR (admin disabled; MI pulls) | no |
| `containerAppsEnvironment` | Shared Container Apps host | no |
| `appIdentity` | User-assigned MI + AcrPull role | no |
| `containerApp` | Generic Container App — `env`/`secrets`/`probePath`/scale/EasyAuth driven by params | no |
| `postgresFlexibleServer` | PostgreSQL Flexible Server | yes |
| `migrateJob` | One-shot Container Apps Job (any migration tool via `command` + optional `args`) | yes |

`containerApp` and `migrateJob` are authored once and reused: the caller passes an `env` array
and a `@secure` `secrets` name→value map, so any app shape works without editing the module.

### Profiles

- **single-app** — one Container App + observability + ACR + CAE. Flags `-IncludeDatabase` /
  `-IncludeMigrateJob` add Postgres + a migrate job; `authMode` selects `none` / `nextauth` / `easyauth`.
- **dual-app** — a backend + a frontend sharing one Postgres + migrate job (the asset-hub shape),
  with the cross-app FQDN wired (backend's `BASE_URL` = frontend's URL).

How the source projects map onto the profiles:

| Project | Profile | Flags |
|---|---|---|
| national-grid-e5-automation | single-app | python, no DB, `authMode=easyauth` |
| resource-management-tool | single-app | node, `-IncludeDatabase -IncludeMigrateJob`, `authMode=nextauth` |
| asset-management-hub | dual-app | node frontend + python backend, DB + migrate, `authMode=nextauth` |

## Authentication

`authMode` picks **how** Entra ID single sign-on is implemented — both real modes are SSO:

| `authMode` | What runs the login | Use for | Needs at deploy |
|---|---|---|---|
| `none` | nothing | internal-only / unauthenticated | — |
| `easyauth` | **ACA EasyAuth** (platform `authConfig`) intercepts requests before your app | apps with no auth library (Flask/Python) | `EntraClientId` + `EntraClientSecret` (no password fallback, so required up front) |
| `nextauth` | **Auth.js / NextAuth** inside the app (env + secrets) | Next.js apps | `AuthSecret` always; Entra creds optional |

**Deferred SSO (nextauth only).** You can deploy before you have the Entra app registration:
pass `-AuthSecret` now and leave the Entra creds empty — the app runs password-only and SSO
stays dormant. The Entra client id/tenant go in as plain env (empty is fine); the client
**secret** is only wired when non-empty (ACA rejects empty secrets). Enable SSO later by
re-running `deploy.ps1` with `-EntraClientId`/`-EntraClientSecret`, or
`az containerapp secret set …` + a revision restart. The app lights up the Entra provider once
all three values are present. The single-app profile uses `AZURE_AD_*` env names — switch to
`AUTH_MICROSOFT_ENTRA_ID_*` if your app follows that convention.

`easyauth` can't be deferred (no fallback login): deploy `authMode=none` first, then switch to
`easyauth` once the secret exists.

## Custom domain

By default an app is reachable at the auto-assigned ACA URL
(`https://<app>.<random-label>.<region>.azurecontainerapps.io`) — the random label is fixed by
Azure and can't be renamed. To serve a real hostname (e.g. `assets.pike.com`), set the
`customDomain` param; the `containerApp` module binds it and issues a **free ACA managed
certificate**. Bring-your-own cert is supported via `customDomainCertificateId`.

Azure validates the domain and issues the cert **at deploy time**, so the DNS records must
already exist. Deploy in three steps:

1. **Deploy with the domain empty** → app live on the ACA URL. Read the values you'll need:
   ```powershell
   az containerapp show -n <app> -g <rg> --query properties.configuration.ingress.fqdn -o tsv          # CNAME target
   az containerapp show -n <app> -g <rg> --query properties.customDomainVerificationId -o tsv           # asuid TXT value
   ```
2. **Create the DNS records** at the registrar for the domain:
   - `CNAME`  `assets` → the FQDN from step 1
   - `TXT`    `asuid.assets` → the verification ID from step 1
3. **Re-deploy with the domain set** → Azure validates, issues the managed cert, and binds it:
   ```powershell
   .\infra\deploy.ps1 -ResourceGroup my-app-prod-rg -CustomDomain assets.pike.com   # + your usual args
   ```
   (dual-app: `-FrontendCustomDomain` / `-BackendCustomDomain`.)

The param can live in `parameters.json`/`deploy.ps1` from day one — it stays dormant while empty
(the binding is conditional), so step 1 is safe. If you set it before the DNS records exist,
step 3's cert validation fails — the condition only protects the empty case, not the DNS-first
requirement. The app keeps answering on the ACA URL too; point `AUTH_URL`/`BASE_URL` at the
custom domain once it's live.

## Usage

### Easiest: the interactive wizard

```powershell
.\Deploy-Wizard.ps1
```

Run it with no arguments. It logs you into Azure (if needed), asks for each value
step by step — app name, environment, region (a numbered picklist), profile, runtime,
features, auth — auto-generates the secrets (and prints them once so you can save them),
scaffolds the project, pauses so you can fill in any app-specific config, then runs the
full phased deploy and prints the app URL. You only answer prompts.

The manual steps below are what the wizard automates — use them when you want explicit control.

### 1. Scaffold

```powershell
# Single Flask tool, no database, platform SSO:
.\New-Project.ps1 -TargetPath C:\dev\other-projects\my-tool `
    -AppName my-tool -Profile single-app -Runtime python -AuthMode easyauth

# Single Next.js app + Postgres + migrations + CI:
.\New-Project.ps1 -TargetPath C:\dev\other-projects\my-app `
    -AppName my-app -Profile single-app -Runtime node `
    -IncludeDatabase -IncludeMigrateJob -AuthMode nextauth -IncludeCICD

# Backend + frontend + shared Postgres:
.\New-Project.ps1 -TargetPath C:\dev\other-projects\my-suite `
    -AppName my-suite -Profile dual-app -Runtime node
```

This writes into the target project:
`infra/main.bicep`, `infra/deploy.ps1`, `infra/parameters.json`, `infra/modules/*.bicep`,
a root `Dockerfile` + `.dockerignore`, and (with `-IncludeCICD`) `.github/workflows/deploy.yml`.

### 2. Fill in

Open `infra/main.bicep` and complete the `>>> FILL IN <<<` blocks — the `env` arrays and
`secrets` maps for your app(s). Everything else (resource names, identities, phasing,
observability) is wired from `parameters.json`. The blocks carry inline examples and a
step-by-step guide; the recipe is:

**Add a plain (non-secret) env var** — e.g. `LOG_LEVEL`. One line in the `*Env` array; a literal
is fine because it isn't sensitive:
```bicep
{ name: 'LOG_LEVEL', value: 'info' }
```

**Add a secret** — e.g. `SENDGRID_API_KEY`. The real value is supplied at deploy time and never
written in any file. Four steps:
```bicep
// 1. main.bicep — declare a placeholder param (default '', the real value comes later):
@secure()
param sendgridApiKey string = ''

// 2. main.bicep — add to the secrets map:
{ 'sendgrid-api-key': sendgridApiKey }

// 3. main.bicep — reference it from env:
{ name: 'SENDGRID_API_KEY', secretRef: 'sendgrid-api-key' }
```
```powershell
# 4. deploy.ps1 — add the param and forward it in $common:
[string]$SendgridApiKey = ''
"sendgridApiKey=$SendgridApiKey"
```
```powershell
# then pass the real value on the command line (the only place it exists):
.\infra\deploy.ps1 -ResourceGroup my-app-prod-rg -SendgridApiKey 'SG.xxxx'
```

The split: **Bicep holds the wiring** (an empty placeholder param + the name/secretRef mapping);
**the terminal supplies the value**. That's why a secret value can't live in the committed
`parameters.json`, but its wiring can live in Bicep.

Finally, adjust the `Dockerfile` COPY lines / entrypoint so it builds and starts *your* app on
the expected port (8000 Python / 3000 Node).

### 3. Validate + deploy

```powershell
az bicep build --file infra\main.bicep         # must compile clean

# Postgres + migrations + NextAuth (SSO dormant until Entra creds are supplied):
.\infra\deploy.ps1 -ResourceGroup my-app-prod-rg `
    -IncludeDatabase -IncludeMigrateJob `
    -PostgresAdminPassword '<pw>' -PostgresAppPassword '<pw>' `
    -AuthMode nextauth -AuthSecret '<openssl rand -base64 32>'

# …later, enable SSO by re-running with the Entra app-registration creds:
#   -AuthMode nextauth -AuthSecret '<same>' -EntraClientId '<id>' -EntraClientSecret '<secret>'
```

`deploy.ps1` runs the phases: infra → (60s IAM wait) → build/push → migrate job → apps.
It fails fast on missing prerequisites (e.g. `nextauth` without `-AuthSecret`, `easyauth`
without Entra creds).

## Conventions

- **Naming:** resources derive from `<appName>-<environment>` (ACR strips dashes:
  `<appname><environment>acr`).
- **Secrets** are never committed. Non-secret structural values live in `parameters.json`;
  secrets are passed to `deploy.ps1` at runtime and stored as Container App secrets.
- **Region** defaults to `eastus2`; **tenant** defaults to the Pike Enterprises Entra tenant.
- **Postgres passwords** are interpolated into a `postgresql://user:pw@host` string that isn't
  URL-encoded — if you set them manually, avoid `@ : / ? # %`. The wizard's auto-generated
  passwords are alphanumeric, so they're always safe.

## Editing this template

Profile `main.bicep` files reference modules via `'../../modules/…'` so they resolve — and
compile (`az bicep build profiles\<profile>\main.bicep`) — directly in this repo. `New-Project.ps1`
rewrites that to `'modules/'` when copying into a project's `infra/` (where modules sit at
`infra/modules/`). If you add a module reference to a profile, use the `'../../modules/'` form.

## Adding a resource type

If two or more projects will need it (Service Bus, Redis, Key Vault), add a module to
`modules/`, reference it from the relevant profile behind a flag, and re-scaffold. One-off
resources can stay in a single project's `infra/`.

## Upgrade path

Modules are **vendored** (copied) into each project today, so a project is self-contained and
deployable offline. When drift across projects becomes a concern, publish `modules/` to a Bicep
registry (ACR) and switch profiles to versioned `br:` references.
