// ============================================================
// Profile: single-app
// ------------------------------------------------------------
// One Container App + observability (Log Analytics + App Insights) + ACR + CAE,
// with OPTIONAL PostgreSQL Flexible Server, OPTIONAL one-shot migrate job, and
// OPTIONAL Entra ID auth (NextAuth in-app, or EasyAuth at the platform).
//
// Covers shapes such as:
//   - Flask tool, no DB        → includeDatabase=false, authMode='easyauth' (or 'none')
//   - Next.js app + Postgres   → includeDatabase=true, includeMigrateJob=true, authMode='nextauth'
//
// Two-phase rollout (deploy.ps1 orchestrates):
//   Phase 1: deployApps=false              — infra + MI + AcrPull (then 60s IAM sleep)
//   Phase 2: build + push image
//   Phase 3: deployMigrateJob=true         — migrate job only (if includeMigrateJob)
//   Phase 4: az containerapp job start     — run migrations
//   Phase 5: deployApps=true               — deploy the Container App
//
// You only edit the ">>> FILL IN <<<" config block further down (app env +
// secrets); it carries the full how-to. Everything else is wired for you.
// ============================================================

@description('Base name used to derive all resource names.')
param appName string

@description('Azure region.')
param location string = resourceGroup().location

@allowed(['dev', 'staging', 'prod'])
param environment string = 'prod'

// ─── Deploy flags ────────────────────────────────────────────────────────────
@description('false = provision infra only (Phase 1). true = deploy the Container App (Phase 5).')
param deployApps bool = true

@description('Deploy the migrate job definition without the app (Phase 3). Requires includeMigrateJob.')
param deployMigrateJob bool = false

@description('Full app image reference. Required when deployApps=true (and Phase 3 when migrating).')
param containerImage string = ''

// ─── App runtime ─────────────────────────────────────────────────────────────
@description('Container port — also the ingress target port.')
param appPort int = 8000

@description('HTTP probe path. Empty disables probes.')
param probePath string = '/health'

param minReplicas int = 1
param maxReplicas int = 1

// ─── Feature flags ───────────────────────────────────────────────────────────
@description('Provision a PostgreSQL Flexible Server.')
param includeDatabase bool = false

@description('Provision + run a one-shot migrate job. Requires includeDatabase.')
param includeMigrateJob bool = false

// ─── Postgres (used only when includeDatabase) ───────────────────────────────
param postgresAdminUser string = 'appadmin'
@secure()
param postgresAdminPassword string = ''
param postgresAppUser string = 'app_user'
@secure()
param postgresAppPassword string = ''
param postgresDbName string = 'appdb'

@description('Migration entrypoint command, e.g. [\'node\',\'/app/scripts/migrate.mjs\'] or [\'node_modules/.bin/tsx\'].')
param migrateCommand array = ['node', '/app/scripts/migrate.mjs']

@description('Optional migration args (overrides image CMD), e.g. [\'backend/src/db/migrate.ts\']. Empty = none.')
param migrateArgs array = []

// ─── Auth ────────────────────────────────────────────────────────────────────
@allowed(['none', 'nextauth', 'easyauth'])
param authMode string = 'none'

@secure()
@description('NextAuth/Auth.js JWT signing secret. Required when authMode=nextauth. Generate: openssl rand -base64 32')
param authSecret string = ''

@description('Entra ID app registration client ID. May be empty now and supplied later to enable SSO.')
param entraClientId string = ''

@secure()
@description('Entra ID app registration client secret. Empty = SSO dormant (nextauth runs password-only until set).')
param entraClientSecret string = ''

param entraTenantId string = '9fbce44f-d64c-4f7e-bbe0-19479c36278b'

// ─── Custom domain (optional) ────────────────────────────────────────────────
// Leave empty to deploy on the default ACA URL. To use your own hostname:
//   1) deploy empty first, 2) create the CNAME + asuid TXT in DNS, 3) re-deploy
//      with -CustomDomain set (Azure issues a free managed cert at deploy time).
@description('Custom domain, e.g. assets.pike.com. Empty = default ACA URL.')
param customDomain string = ''

@description('Resource ID of an existing cert to bind. Empty = free ACA managed cert.')
param customDomainCertificateId string = ''

// ─── Your app's secret params  >>> ADD HERE <<< ──────────────────────────────
// Declare one @secure param per secret your app needs. Keep the default '' — the
// REAL value is supplied at deploy time via deploy.ps1, never written in this file.
// EXAMPLE (uncomment + rename), then wire it in the appSecrets/appEnv blocks below
// and add a matching -SendgridApiKey arg in deploy.ps1:
//
// @secure()
// @description('SendGrid API key. Supplied via deploy.ps1 -SendgridApiKey; never stored here.')
// param sendgridApiKey string = ''

// ─── Derived names ───────────────────────────────────────────────────────────
var prefix          = '${appName}-${environment}'
var acrName         = replace('${prefix}acr', '-', '') // ACR: alphanumeric only
var appResourceName = '${prefix}-app'

var tags = {
  application: appName
  environment: environment
  managedBy: 'bicep'
}

// ─── Observability + registry + environment ──────────────────────────────────
module logAnalytics '../../modules/logAnalytics.bicep' = {
  name: 'logAnalytics'
  params: { name: '${prefix}-laws', location: location, tags: tags }
}

module appInsights '../../modules/appInsights.bicep' = {
  name: 'appInsights'
  params: {
    name: '${prefix}-insights'
    location: location
    tags: tags
    logAnalyticsWorkspaceId: logAnalytics.outputs.workspaceId
  }
}

module acr '../../modules/containerRegistry.bicep' = {
  name: 'containerRegistry'
  params: { name: acrName, location: location, tags: tags }
}

module cae '../../modules/containerAppsEnvironment.bicep' = {
  name: 'containerAppsEnvironment'
  params: {
    name: '${prefix}-cae'
    location: location
    tags: tags
    logAnalyticsWorkspaceId: logAnalytics.outputs.workspaceId
    logAnalyticsCustomerId: logAnalytics.outputs.customerId
  }
}

// ─── Database (optional) ──────────────────────────────────────────────────────
module postgres '../../modules/postgresFlexibleServer.bicep' = if (includeDatabase) {
  name: 'postgres'
  params: {
    name: '${prefix}-pgfs'
    location: location
    tags: tags
    databaseName: postgresDbName
    administratorLogin: postgresAdminUser
    administratorPassword: postgresAdminPassword
  }
}

// ─── Identities + AcrPull (Phase 1 — always created) ─────────────────────────
module appIdentity '../../modules/appIdentity.bicep' = {
  name: 'appIdentity'
  params: { name: '${prefix}-app-mi', location: location, tags: tags, acrId: acr.outputs.id, acrName: acrName }
}

module jobIdentity '../../modules/appIdentity.bicep' = if (includeMigrateJob) {
  name: 'jobIdentity'
  params: { name: '${prefix}-job-mi', location: location, tags: tags, acrId: acr.outputs.id, acrName: acrName }
}

// ─── Connection strings (only meaningful when includeDatabase) ───────────────
// Built here so passwords never appear in a non-@secure context. ARM if() only
// evaluates the taken branch, so postgres!.outputs is not referenced when absent.
// sslmode=require is mandatory for Azure Database for PostgreSQL Flexible Server.
var appDatabaseUrl = includeDatabase ? 'postgresql://${postgresAppUser}:${postgresAppPassword}@${postgres!.outputs.fullyQualifiedDomainName}:5432/${postgres!.outputs.databaseName}?sslmode=require' : ''
var adminDatabaseUrl = includeDatabase ? 'postgresql://${postgresAdminUser}:${postgresAdminPassword}@${postgres!.outputs.fullyQualifiedDomainName}:5432/${postgres!.outputs.databaseName}?sslmode=require' : ''

// Own FQDN, computed before the app exists (Container App FQDN = <name>.<caeDefaultDomain>).
// Use for AUTH_URL / BASE_URL when the app needs to know its own public URL.
var appFqdn = 'https://${appResourceName}.${cae.outputs.defaultDomain}'

// ═════════════════════════════════════════════════════════════════════════════
// >>> FILL IN: your app's runtime configuration <<<
//
// This is the ONLY part you normally edit. Everything else — resource names,
// identities, Postgres, deploy phasing, health probes — is wired automatically
// from parameters.json and the feature flags.
//
// Two blocks:
//   • appSecrets — sensitive values (tokens, passwords, connection strings).
//       Stored as encrypted Container App secrets. A secret VALUE must never be
//       empty (ACA rejects empty secrets). Reference each from env via secretRef.
//   • appEnv     — the environment variables your app reads. Use `value:` for a
//       plain value, or `secretRef:` to pull from a secret defined in appSecrets.
//
// ── HOW TO ADD A PLAIN (non-secret) ENV VAR, e.g. LOG_LEVEL ──
//   1. Add one line to the base array in appEnv:
//          { name: 'LOG_LEVEL', value: 'info' }
//      Done — a literal is fine here because it isn't sensitive.
//
// ── HOW TO ADD A SECRET, e.g. SENDGRID_API_KEY ──  (real value never lives here)
//   1. Declare a placeholder param above (see the `sendgridApiKey` example in the
//      "Your app's secret params" section). Leave its default ''.
//   2. Add it to appSecrets:   { 'sendgrid-api-key': sendgridApiKey }
//   3. Reference it in appEnv:  { name: 'SENDGRID_API_KEY', secretRef: 'sendgrid-api-key' }
//   4. In infra\deploy.ps1: add a -SendgridApiKey param + forward it in $common
//      (see the commented EXAMPLE there), then pass the real value at deploy:
//          .\infra\deploy.ps1 -ResourceGroup <rg> -SendgridApiKey 'SG.xxxx'
// ═════════════════════════════════════════════════════════════════════════════
var appSecrets = union(
  {
    'appinsights-connection-string': appInsights.outputs.connectionString
  },
  includeDatabase ? { 'database-url': appDatabaseUrl } : {},
  authMode == 'nextauth' ? { 'auth-secret': authSecret } : {},
  (authMode == 'nextauth' && entraClientSecret != '') ? { 'azure-ad-client-secret': entraClientSecret } : {},
  authMode == 'easyauth' ? { 'microsoft-provider-authentication-secret': entraClientSecret } : {}
  // ── ADD YOUR SECRETS HERE (comma-separated objects), e.g.: ──
  // , { 'sendgrid-api-key': sendgridApiKey }
)

var appEnv = union(
  [
    { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', secretRef: 'appinsights-connection-string' }
    { name: 'PORT', value: '${appPort}' }
    // ── ADD YOUR PLAIN ENV VARS HERE, e.g.: ──
    // { name: 'LOG_LEVEL', value: 'info' }
  ],
  includeDatabase ? [ { name: 'DATABASE_URL', secretRef: 'database-url' } ] : [],
  // NextAuth plumbing + Entra provider. Client ID/tenant are plain env (empty is fine);
  // the app enables the Entra SSO provider only once all three values are present, so
  // until then it runs password-only. (App var names follow the AZURE_AD_* convention;
  // swap to AUTH_MICROSOFT_ENTRA_ID_* if your app expects those.)
  authMode == 'nextauth' ? [
    { name: 'AUTH_SECRET', secretRef: 'auth-secret' }
    { name: 'AUTH_URL', value: appFqdn }
    { name: 'AUTH_TRUST_HOST', value: 'true' }
    { name: 'AZURE_AD_CLIENT_ID', value: entraClientId }
    { name: 'AZURE_AD_TENANT_ID', value: entraTenantId }
  ] : [],
  // Secret-backed env only when the secret exists (empty secretRef would fail).
  (authMode == 'nextauth' && entraClientSecret != '') ? [
    { name: 'AZURE_AD_CLIENT_SECRET', secretRef: 'azure-ad-client-secret' }
  ] : []
  // ── ADD YOUR SECRET-BACKED ENV VARS HERE (as another array arg), e.g.: ──
  // , [ { name: 'SENDGRID_API_KEY', secretRef: 'sendgrid-api-key' } ]
)

// ─── Migrate job env + secrets  >>> FILL IN (if includeMigrateJob) <<< ────────
// Defaults follow the Prisma / asset-hub migrate.mjs contract (creates the app role
// from APP_DB_USER/APP_DB_PASSWORD). For a Drizzle-style job (resource-mgmt) set
// migrateCommand=['node_modules/.bin/tsx'], migrateArgs=['backend/src/db/migrate.ts'],
// and adjust these to { POSTGRES_APP_PASSWORD } as that script expects.
var migrateSecrets = {
  'database-url-admin': adminDatabaseUrl
  'app-db-password': postgresAppPassword
}

var migrateEnv = [
  { name: 'DATABASE_URL', secretRef: 'database-url-admin' }
  { name: 'APP_DB_USER', value: postgresAppUser }
  { name: 'APP_DB_PASSWORD', secretRef: 'app-db-password' }
]

// ─── Migrate job ──────────────────────────────────────────────────────────────
module migrateJob '../../modules/migrateJob.bicep' = if (includeMigrateJob && (deployApps || deployMigrateJob)) {
  name: 'migrateJob'
  params: {
    name: '${prefix}-migrate-job'
    location: location
    tags: tags
    containerAppsEnvironmentId: cae.outputs.environmentId
    containerRegistryLoginServer: acr.outputs.loginServer
    image: containerImage
    userAssignedIdentityId: jobIdentity!.outputs.identityId
    command: migrateCommand
    args: migrateArgs
    env: migrateEnv
    #disable-next-line use-secure-value-for-secure-inputs
    secrets: migrateSecrets
  }
}

// ─── Container App ──────────────────────────────────────────────────────────────
module app '../../modules/containerApp.bicep' = if (deployApps) {
  name: 'containerApp'
  params: {
    name: appResourceName
    location: location
    tags: tags
    containerAppsEnvironmentId: cae.outputs.environmentId
    containerRegistryLoginServer: acr.outputs.loginServer
    userAssignedIdentityId: appIdentity.outputs.identityId
    image: containerImage
    port: appPort
    env: appEnv
    #disable-next-line use-secure-value-for-secure-inputs
    secrets: appSecrets
    probePath: probePath
    minReplicas: minReplicas
    maxReplicas: maxReplicas
    authMode: authMode
    entraClientId: entraClientId
    entraTenantId: entraTenantId
    customDomain: customDomain
    customDomainCertificateId: customDomainCertificateId
  }
}

// ─── Outputs ──────────────────────────────────────────────────────────────────
@description('ACR login server — used by deploy.ps1 for docker push.')
output acrLoginServer string = acr.outputs.loginServer

@description('ACR name — used by deploy.ps1 for az acr login.')
output acrName string = acr.outputs.name

@description('Postgres FQDN (empty when includeDatabase=false).')
output postgresFqdn string = includeDatabase ? postgres!.outputs.fullyQualifiedDomainName : ''

@description('Migrate job name — pass to az containerapp job start (empty when not deployed).')
output migrateJobName string = (includeMigrateJob && (deployApps || deployMigrateJob)) ? migrateJob!.outputs.name : ''

@description('Container App URL (empty when deployApps=false).')
output appUrl string = deployApps ? 'https://${app!.outputs.fqdn}' : ''
