// ============================================================
// Profile: dual-app
// ------------------------------------------------------------
// Two Container Apps (a backend + a frontend) sharing one PostgreSQL Flexible
// Server and a one-shot migrate job, plus observability + ACR + CAE.
// Models the asset-management-hub shape (Flask backend :8000 + Next.js frontend :3000).
//
// The frontend's own FQDN and the backend's reference to it are computed from the
// CAE default domain BEFORE the apps exist — eliminating the chicken-and-egg problem
// with AUTH_URL / BASE_URL.
//
// Two-phase rollout (deploy.ps1 orchestrates):
//   Phase 1: deployApps=false           — infra + 3 MIs + AcrPull (then 60s IAM sleep)
//   Phase 2: build + push both images
//   Phase 3: deployMigrateJob=true      — migrate job only
//   Phase 4: az containerapp job start  — run migrations
//   Phase 5: deployApps=true            — deploy both Container Apps
//
// You only edit the ">>> FILL IN <<<" config block further down (per-app env +
// secrets); it carries the full how-to. Everything else is wired automatically.
// ============================================================

@description('Base name used to derive all resource names.')
param appName string

@description('Azure region.')
param location string = resourceGroup().location

@allowed(['dev', 'staging', 'prod'])
param environment string = 'prod'

// ─── Deploy flags ────────────────────────────────────────────────────────────
@description('false = provision infra only (Phase 1). true = deploy Container Apps (Phase 5).')
param deployApps bool = true

@description('Deploy the migrate job definition without the apps (Phase 3).')
param deployMigrateJob bool = false

@description('Backend image reference. Required when deployApps=true.')
param backendImage string = ''

@description('Frontend image reference. Required when deployApps=true, and Phase 3 (the migrate job runs in the frontend image).')
param frontendImage string = ''

// ─── App runtime ─────────────────────────────────────────────────────────────
param backendPort int = 8000
param backendProbePath string = '/health'
param frontendPort int = 3000
param frontendProbePath string = '/login'

// ─── Postgres ────────────────────────────────────────────────────────────────
param postgresAdminUser string = 'appadmin'
@secure()
param postgresAdminPassword string
param postgresAppUser string = 'app_user'
@secure()
param postgresAppPassword string
param postgresDbName string = 'appdb'

@description('Migration entrypoint command (runs inside the frontend image).')
param migrateCommand array = ['node', '/app/scripts/migrate.mjs']

@description('Optional migration args (overrides image CMD). Empty = none.')
param migrateArgs array = []

// ─── Auth (frontend) ─────────────────────────────────────────────────────────
@allowed(['none', 'nextauth', 'easyauth'])
param authMode string = 'nextauth'
@secure()
param authSecret string = ''
param entraClientId string = ''
@secure()
param entraClientSecret string = ''
param entraTenantId string = '9fbce44f-d64c-4f7e-bbe0-19479c36278b'

// ─── Custom domains (optional, per app) ──────────────────────────────────────
// Leave empty to use the default ACA URLs. To use your own hostnames: deploy empty
// first, create the CNAME + asuid TXT in DNS, then re-deploy with the values set
// (Azure issues a free managed cert per domain at deploy time). The frontend is the
// usual public one; the backend is often left internal.
@description('Frontend custom domain, e.g. assets.pike.com. Empty = default ACA URL.')
param frontendCustomDomain string = ''
@description('Frontend BYO cert resource ID. Empty = free ACA managed cert.')
param frontendCustomDomainCertificateId string = ''
@description('Backend custom domain. Empty = default ACA URL.')
param backendCustomDomain string = ''
@description('Backend BYO cert resource ID. Empty = free ACA managed cert.')
param backendCustomDomainCertificateId string = ''

// ─── Your apps' secret params  >>> ADD HERE <<< ──────────────────────────────
// One @secure param per secret either app needs. Keep the default '' — the REAL
// value is supplied at deploy time via deploy.ps1, never written in this file.
// EXAMPLE (uncomment + rename), then wire it into the backend/frontend secrets +
// env blocks below and add a matching -SendgridApiKey arg in deploy.ps1:
//
// @secure()
// @description('SendGrid API key. Supplied via deploy.ps1 -SendgridApiKey; never stored here.')
// param sendgridApiKey string = ''

// ─── Derived names ───────────────────────────────────────────────────────────
var prefix       = '${appName}-${environment}'
var acrName      = replace('${prefix}acr', '-', '')
var backendName  = '${prefix}-backend'
var frontendName = '${prefix}-frontend'

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

// ─── Postgres ────────────────────────────────────────────────────────────────
module postgres '../../modules/postgresFlexibleServer.bicep' = {
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
module backendIdentity '../../modules/appIdentity.bicep' = {
  name: 'backendIdentity'
  params: { name: '${prefix}-backend-mi', location: location, tags: tags, acrId: acr.outputs.id, acrName: acrName }
}

module frontendIdentity '../../modules/appIdentity.bicep' = {
  name: 'frontendIdentity'
  params: { name: '${prefix}-frontend-mi', location: location, tags: tags, acrId: acr.outputs.id, acrName: acrName }
}

module jobIdentity '../../modules/appIdentity.bicep' = {
  name: 'jobIdentity'
  params: { name: '${prefix}-job-mi', location: location, tags: tags, acrId: acr.outputs.id, acrName: acrName }
}

// ─── Connection strings + FQDNs ──────────────────────────────────────────────
var appDatabaseUrl = 'postgresql://${postgresAppUser}:${postgresAppPassword}@${postgres.outputs.fullyQualifiedDomainName}:5432/${postgres.outputs.databaseName}?sslmode=require'
var adminDatabaseUrl = 'postgresql://${postgresAdminUser}:${postgresAdminPassword}@${postgres.outputs.fullyQualifiedDomainName}:5432/${postgres.outputs.databaseName}?sslmode=require'

// Computed before the apps exist: Container App FQDN = <name>.<caeDefaultDomain>.
var frontendFqdn = 'https://${frontendName}.${cae.outputs.defaultDomain}'

// ═════════════════════════════════════════════════════════════════════════════
// >>> FILL IN: each app's runtime configuration <<<
//
// The only part you normally edit. Names, identities, Postgres, phasing, and the
// cross-app FQDN are wired automatically. Each app has a `*Secrets` map (sensitive
// values → encrypted Container App secrets; never empty) and a `*Env` array (use
// `value:` for plain vars, `secretRef:` to pull from that app's secrets map).
//
// ── ADD A PLAIN ENV VAR (e.g. LOG_LEVEL) ──  add one line to the relevant *Env array:
//        { name: 'LOG_LEVEL', value: 'info' }
//
// ── ADD A SECRET (e.g. SENDGRID_API_KEY) ──  real value never lives here:
//   1. Declare a placeholder @secure param above (see the `sendgridApiKey` example).
//   2. Add to the app's secrets:   'sendgrid-api-key': sendgridApiKey
//   3. Reference it in the env:     { name: 'SENDGRID_API_KEY', secretRef: 'sendgrid-api-key' }
//   4. In infra\deploy.ps1: add -SendgridApiKey + forward it (see the EXAMPLE there),
//      then pass the real value: .\infra\deploy.ps1 ... -SendgridApiKey 'SG.xxxx'
// Add it to whichever app needs it (backend, frontend, or both).
// ═════════════════════════════════════════════════════════════════════════════

// ─── Backend env + secrets ───────────────────────────────────────────────────
var backendSecrets = {
  'appinsights-connection-string': appInsights.outputs.connectionString
  'database-url': appDatabaseUrl
  // ── ADD BACKEND SECRETS HERE, e.g.: ──
  // 'sendgrid-api-key': sendgridApiKey
}

var backendEnv = [
  { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', secretRef: 'appinsights-connection-string' }
  { name: 'DATABASE_URL', secretRef: 'database-url' }
  // Backend points at the frontend's public URL (e.g. for tracking links / callbacks).
  { name: 'BASE_URL', value: frontendFqdn }
  { name: 'PORT', value: '${backendPort}' }
  // ── ADD BACKEND ENV HERE, e.g.: ──
  // { name: 'LOG_LEVEL', value: 'info' }
  // { name: 'SENDGRID_API_KEY', secretRef: 'sendgrid-api-key' }
]

// ─── Frontend env + secrets ──────────────────────────────────────────────────
var frontendSecrets = union(
  {
    'appinsights-connection-string': appInsights.outputs.connectionString
    'database-url': appDatabaseUrl
    'auth-secret': authSecret
    // ── ADD FRONTEND SECRETS HERE, e.g.: ──
    // 'sendgrid-api-key': sendgridApiKey
  },
  authMode == 'easyauth' ? { 'microsoft-provider-authentication-secret': entraClientSecret } : {}
)

var frontendEnv = [
  { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', secretRef: 'appinsights-connection-string' }
  { name: 'DATABASE_URL', secretRef: 'database-url' }
  { name: 'AUTH_SECRET', secretRef: 'auth-secret' }
  { name: 'NODE_ENV', value: 'production' }
  { name: 'AUTH_TRUST_HOST', value: 'true' }
  { name: 'AUTH_URL', value: frontendFqdn }
  { name: 'BASE_URL', value: frontendFqdn }
  { name: 'PORT', value: '${frontendPort}' }
  // ── ADD FRONTEND ENV HERE, e.g.: ──
  // { name: 'LOG_LEVEL', value: 'info' }
  // { name: 'SENDGRID_API_KEY', secretRef: 'sendgrid-api-key' }
]

// ─── Migrate job env + secrets  >>> FILL IN <<< ──────────────────────────────
var migrateSecrets = {
  'database-url-admin': adminDatabaseUrl
  'app-db-password': postgresAppPassword
}

var migrateEnv = [
  { name: 'DATABASE_URL', secretRef: 'database-url-admin' }
  { name: 'APP_DB_USER', value: postgresAppUser }
  { name: 'APP_DB_PASSWORD', secretRef: 'app-db-password' }
]

// ─── Migrate job (runs in the frontend image) ────────────────────────────────
module migrateJob '../../modules/migrateJob.bicep' = if (deployApps || deployMigrateJob) {
  name: 'migrateJob'
  params: {
    name: '${prefix}-migrate-job'
    location: location
    tags: tags
    containerAppsEnvironmentId: cae.outputs.environmentId
    containerRegistryLoginServer: acr.outputs.loginServer
    image: frontendImage
    userAssignedIdentityId: jobIdentity.outputs.identityId
    command: migrateCommand
    args: migrateArgs
    env: migrateEnv
    #disable-next-line use-secure-value-for-secure-inputs
    secrets: migrateSecrets
  }
}

// ─── Backend Container App ────────────────────────────────────────────────────
module backend '../../modules/containerApp.bicep' = if (deployApps) {
  name: 'backend'
  params: {
    name: backendName
    location: location
    tags: tags
    containerAppsEnvironmentId: cae.outputs.environmentId
    containerRegistryLoginServer: acr.outputs.loginServer
    userAssignedIdentityId: backendIdentity.outputs.identityId
    image: backendImage
    port: backendPort
    env: backendEnv
    #disable-next-line use-secure-value-for-secure-inputs
    secrets: backendSecrets
    probePath: backendProbePath
    customDomain: backendCustomDomain
    customDomainCertificateId: backendCustomDomainCertificateId
  }
}

// ─── Frontend Container App ───────────────────────────────────────────────────
module frontend '../../modules/containerApp.bicep' = if (deployApps) {
  name: 'frontend'
  params: {
    name: frontendName
    location: location
    tags: tags
    containerAppsEnvironmentId: cae.outputs.environmentId
    containerRegistryLoginServer: acr.outputs.loginServer
    userAssignedIdentityId: frontendIdentity.outputs.identityId
    image: frontendImage
    port: frontendPort
    env: frontendEnv
    #disable-next-line use-secure-value-for-secure-inputs
    secrets: frontendSecrets
    probePath: frontendProbePath
    authMode: authMode
    entraClientId: entraClientId
    entraTenantId: entraTenantId
    customDomain: frontendCustomDomain
    customDomainCertificateId: frontendCustomDomainCertificateId
  }
}

// ─── Outputs ──────────────────────────────────────────────────────────────────
@description('ACR login server.')
output acrLoginServer string = acr.outputs.loginServer

@description('ACR name.')
output acrName string = acr.outputs.name

@description('Postgres FQDN.')
output postgresFqdn string = postgres.outputs.fullyQualifiedDomainName

@description('Migrate job name — pass to az containerapp job start.')
output migrateJobName string = (deployApps || deployMigrateJob) ? migrateJob!.outputs.name : ''

@description('Backend URL (empty when deployApps=false).')
output backendUrl string = deployApps ? 'https://${backend!.outputs.fqdn}' : ''

@description('Frontend URL (empty when deployApps=false).')
output frontendUrl string = deployApps ? 'https://${frontend!.outputs.fqdn}' : ''
