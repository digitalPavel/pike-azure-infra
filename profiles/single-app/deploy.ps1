# Single-app profile — Azure Container Apps deployment (PowerShell).
#
# Usage (no database):
#   .\infra\deploy.ps1 -ResourceGroup my-rg
#
# Usage (with database + migrations):
#   .\infra\deploy.ps1 -ResourceGroup my-rg -IncludeDatabase -IncludeMigrateJob `
#       -PostgresAdminPassword '<admin-pw>' -PostgresAppPassword '<app-pw>'
#
# Prerequisites: az login; Docker Desktop running.
#
# Phases:
#   1. Provision infra (ACR, CAE, observability, MI + AcrPull[, Postgres])
#   2. Build + push the app image
#   3. Deploy migrate job definition          (only with -IncludeMigrateJob)
#   4. Run migrate job                          (only with -IncludeMigrateJob)
#   5. Deploy the Container App

#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$ResourceGroup,
    [string]$Location = 'eastus2',

    # Override appName/environment from parameters.json for isolated stacks.
    [string]$AppName = '',
    [string]$Environment = '',

    [switch]$IncludeDatabase,
    [switch]$IncludeMigrateJob,

    [string]$PostgresAdminPassword = '',
    [string]$PostgresAppPassword = '',

    [ValidateSet('none', 'nextauth', 'easyauth')]
    [string]$AuthMode = 'none',
    # NextAuth JWT signing secret (required for -AuthMode nextauth). openssl rand -base64 32
    [string]$AuthSecret = '',
    # Entra app-registration creds — leave empty to deploy SSO dormant and add them later.
    [string]$EntraClientId = '',
    [string]$EntraClientSecret = '',
    [string]$EntraTenantId = '9fbce44f-d64c-4f7e-bbe0-19479c36278b',

    # Custom domain (optional). Leave empty first deploy; set once DNS records exist.
    [string]$CustomDomain = '',
    [string]$CustomDomainCertificateId = '',

    # Docker build context, relative to the repo root (where the Dockerfile lives).
    [string]$DockerContext = '.',

    [string]$ImageTag = 'latest'

    # ── ADD YOUR APP SECRETS HERE (one param each). EXAMPLE (uncomment): ──
    # The real value is passed on the command line at deploy; never hardcode it.
    # , [string]$SendgridApiKey = ''
)

$ErrorActionPreference = 'Stop'
$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoRoot   = Split-Path -Parent $ScriptDir
$Template   = Join-Path $ScriptDir 'main.bicep'
$ParamsFile = Join-Path $ScriptDir 'parameters.json'

$Params = Get-Content $ParamsFile -Raw | ConvertFrom-Json
if (-not $AppName)     { $AppName     = $Params.parameters.appName.value }
if (-not $Environment) { $Environment = $Params.parameters.environment.value }
$Prefix = "$AppName-$Environment"

if ($IncludeMigrateJob -and -not $IncludeDatabase) {
    throw "-IncludeMigrateJob requires -IncludeDatabase."
}
if ($AuthMode -eq 'easyauth' -and (-not $EntraClientSecret -or -not $EntraClientId)) {
    throw "-AuthMode easyauth requires -EntraClientId and -EntraClientSecret. Deploy with -AuthMode none first, then re-run with the Entra values once the app registration exists (ACA rejects empty secrets)."
}
if ($AuthMode -eq 'nextauth' -and -not $AuthSecret) {
    throw "-AuthMode nextauth requires -AuthSecret (NextAuth JWT signing key). Generate one: openssl rand -base64 32. Entra creds can stay empty for now — SSO stays dormant until you supply them."
}

# az/ARM require lowercase JSON booleans — PowerShell's $true renders as 'True'.
$dbFlag = if ($IncludeDatabase) { 'true' } else { 'false' }
$mjFlag = if ($IncludeMigrateJob) { 'true' } else { 'false' }

Write-Host "==> Deploying $AppName ($Environment) to: $ResourceGroup" -ForegroundColor Cyan

# ---------- Preflight ----------
if (-not (Get-Command az     -ErrorAction SilentlyContinue)) { throw "Azure CLI not found." }
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { throw "Docker not found." }
az account show 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Not logged in to Azure. Run: az login" }
docker info 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Docker Desktop is not running." }

az group create --name $ResourceGroup --location $Location --output none
if ($LASTEXITCODE -ne 0) { throw "Resource group create failed." }

# Parameters shared across every phase.
$common = @(
    "@$ParamsFile",
    "appName=$AppName", "environment=$Environment", "location=$Location",
    "includeDatabase=$dbFlag",
    "includeMigrateJob=$mjFlag",
    "postgresAdminPassword=$PostgresAdminPassword",
    "postgresAppPassword=$PostgresAppPassword",
    "authMode=$AuthMode",
    "authSecret=$AuthSecret",
    "entraClientId=$EntraClientId",
    "entraClientSecret=$EntraClientSecret",
    "entraTenantId=$EntraTenantId",
    "customDomain=$CustomDomain",
    "customDomainCertificateId=$CustomDomainCertificateId"
    # ── FORWARD YOUR SECRETS TO BICEP HERE (name must match the @secure param in
    #    main.bicep). EXAMPLE (uncomment): ──
    # , "sendgridApiKey=$SendgridApiKey"
)

# ---------- Phase 1: Infrastructure ----------
Write-Host "==> Phase 1: Provisioning infrastructure..." -ForegroundColor Cyan
$p1 = az deployment group create --resource-group $ResourceGroup --template-file $Template `
    --parameters $common deployApps=false --output json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) { throw "Phase 1 failed." }

$AcrServer = $p1.properties.outputs.acrLoginServer.value
$AcrName   = $p1.properties.outputs.acrName.value
$Image     = "$AcrServer/$Prefix-app:$ImageTag"
Write-Host "    ACR: $AcrServer"

Write-Host "==> Waiting 60s for AcrPull role to propagate..." -ForegroundColor Yellow
Start-Sleep -Seconds 60

# ---------- Phase 2: Build + push ----------
Write-Host "==> Phase 2: Building + pushing image..." -ForegroundColor Cyan
az acr login --name $AcrName
if ($LASTEXITCODE -ne 0) { throw "ACR login failed." }
docker build -t $Image (Join-Path $RepoRoot $DockerContext)
if ($LASTEXITCODE -ne 0) { throw "Docker build failed." }
docker push $Image
if ($LASTEXITCODE -ne 0) { throw "Docker push failed." }
Write-Host "    Pushed: $Image"

# ---------- Phases 3 + 4: Migrations ----------
if ($IncludeMigrateJob) {
    Write-Host "==> Phase 3: Deploying migrate job definition..." -ForegroundColor Cyan
    $p3 = az deployment group create --resource-group $ResourceGroup --template-file $Template `
        --parameters $common deployApps=false deployMigrateJob=true "containerImage=$Image" `
        --output json | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) { throw "Phase 3 failed." }
    $MigrateJob = $p3.properties.outputs.migrateJobName.value
    if (-not $MigrateJob) { throw "Migrate job name missing from Phase 3 outputs." }

    Write-Host "==> Phase 4: Running migrations ($MigrateJob)..." -ForegroundColor Cyan
    $Exec = (az containerapp job start --name $MigrateJob --resource-group $ResourceGroup --query name -o tsv).Trim()
    if ($LASTEXITCODE -ne 0) { throw "Failed to start migrate job." }

    $Deadline = (Get-Date).AddMinutes(10)
    $Status = 'Running'
    while ((Get-Date) -lt $Deadline -and $Status -notin @('Succeeded', 'Failed')) {
        Start-Sleep -Seconds 10
        $Status = (az containerapp job execution show --name $MigrateJob --resource-group $ResourceGroup `
            --job-execution-name $Exec --query 'properties.status' -o tsv).Trim()
        Write-Host "    Status: $Status"
    }
    if ($Status -ne 'Succeeded') { throw "Migration did not succeed (last: $Status). Check Log Analytics: $Prefix-laws" }
}

# ---------- Phase 5: Deploy the Container App ----------
Write-Host "==> Phase 5: Deploying the Container App..." -ForegroundColor Cyan
$p5 = az deployment group create --resource-group $ResourceGroup --template-file $Template `
    --parameters $common deployApps=true "containerImage=$Image" --output json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) { throw "Phase 5 failed." }

Write-Host ""
Write-Host "==> Deployment complete!" -ForegroundColor Green
Write-Host "    App: $($p5.properties.outputs.appUrl.value)"
