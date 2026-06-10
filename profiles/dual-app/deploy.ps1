# Dual-app profile — Azure Container Apps deployment (PowerShell).
#
# Usage:
#   .\infra\deploy.ps1 -ResourceGroup my-rg `
#       -PostgresAdminPassword '<admin-pw>' -PostgresAppPassword '<app-pw>' `
#       -AuthSecret '<base64-32>'
#
# Generate AuthSecret: openssl rand -base64 32
# Prerequisites: az login; Docker Desktop running.
#
# Phases:
#   1. Provision infra (ACR, CAE, Postgres, observability, 3 MIs + AcrPull)
#   2. Build + push backend and frontend images
#   3. Deploy migrate job definition (runs in the frontend image)
#   4. Run migrate job
#   5. Deploy both Container Apps

#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$ResourceGroup,
    [string]$Location = 'eastus2',
    [string]$AppName = '',
    [string]$Environment = '',

    [Parameter(Mandatory)] [string]$PostgresAdminPassword,
    [Parameter(Mandatory)] [string]$PostgresAppPassword,
    [Parameter(Mandatory)] [string]$AuthSecret,

    [ValidateSet('none', 'nextauth', 'easyauth')]
    [string]$AuthMode = 'nextauth',
    [string]$EntraClientId = '',
    [string]$EntraClientSecret = '',
    [string]$EntraTenantId = '9fbce44f-d64c-4f7e-bbe0-19479c36278b',

    # Custom domains (optional). Leave empty first deploy; set once DNS records exist.
    [string]$FrontendCustomDomain = '',
    [string]$FrontendCustomDomainCertificateId = '',
    [string]$BackendCustomDomain = '',
    [string]$BackendCustomDomainCertificateId = '',

    # Docker build contexts, relative to the repo root.
    [string]$BackendContext = '.',
    [string]$FrontendContext = 'frontend',

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

if ($AuthMode -eq 'easyauth' -and (-not $EntraClientSecret -or -not $EntraClientId)) {
    throw "-AuthMode easyauth requires -EntraClientId and -EntraClientSecret. Deploy with -AuthMode nextauth/none first, then re-run with the Entra values once the app registration exists (ACA rejects empty secrets)."
}

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

$common = @(
    "@$ParamsFile",
    "appName=$AppName", "environment=$Environment", "location=$Location",
    "postgresAdminPassword=$PostgresAdminPassword",
    "postgresAppPassword=$PostgresAppPassword",
    "authSecret=$AuthSecret",
    "authMode=$AuthMode",
    "entraClientId=$EntraClientId",
    "entraClientSecret=$EntraClientSecret",
    "entraTenantId=$EntraTenantId",
    "frontendCustomDomain=$FrontendCustomDomain",
    "frontendCustomDomainCertificateId=$FrontendCustomDomainCertificateId",
    "backendCustomDomain=$BackendCustomDomain",
    "backendCustomDomainCertificateId=$BackendCustomDomainCertificateId"
    # ── FORWARD YOUR SECRETS TO BICEP HERE (name must match the @secure param in
    #    main.bicep). EXAMPLE (uncomment): ──
    # , "sendgridApiKey=$SendgridApiKey"
)

# ---------- Phase 1: Infrastructure ----------
Write-Host "==> Phase 1: Provisioning infrastructure..." -ForegroundColor Cyan
$p1 = az deployment group create --resource-group $ResourceGroup --template-file $Template `
    --parameters $common deployApps=false --output json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) { throw "Phase 1 failed." }

$AcrServer     = $p1.properties.outputs.acrLoginServer.value
$AcrName       = $p1.properties.outputs.acrName.value
$BackendImage  = "$AcrServer/$Prefix-backend:$ImageTag"
$FrontendImage = "$AcrServer/$Prefix-frontend:$ImageTag"
Write-Host "    ACR: $AcrServer"

Write-Host "==> Waiting 60s for AcrPull role to propagate..." -ForegroundColor Yellow
Start-Sleep -Seconds 60

# ---------- Phase 2: Build + push ----------
Write-Host "==> Phase 2: Building + pushing images..." -ForegroundColor Cyan
az acr login --name $AcrName
if ($LASTEXITCODE -ne 0) { throw "ACR login failed." }

docker build -t $BackendImage (Join-Path $RepoRoot $BackendContext)
if ($LASTEXITCODE -ne 0) { throw "Backend build failed." }
docker push $BackendImage
if ($LASTEXITCODE -ne 0) { throw "Backend push failed." }
Write-Host "    Pushed: $BackendImage"

docker build -t $FrontendImage (Join-Path $RepoRoot $FrontendContext)
if ($LASTEXITCODE -ne 0) { throw "Frontend build failed." }
docker push $FrontendImage
if ($LASTEXITCODE -ne 0) { throw "Frontend push failed." }
Write-Host "    Pushed: $FrontendImage"

# ---------- Phase 3: Migrate job definition ----------
Write-Host "==> Phase 3: Deploying migrate job definition..." -ForegroundColor Cyan
$p3 = az deployment group create --resource-group $ResourceGroup --template-file $Template `
    --parameters $common deployApps=false deployMigrateJob=true "frontendImage=$FrontendImage" `
    --output json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) { throw "Phase 3 failed." }
$MigrateJob = $p3.properties.outputs.migrateJobName.value
if (-not $MigrateJob) { throw "Migrate job name missing from Phase 3 outputs." }

# ---------- Phase 4: Run migrations ----------
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

# ---------- Phase 5: Deploy both Container Apps ----------
Write-Host "==> Phase 5: Deploying Container Apps..." -ForegroundColor Cyan
$p5 = az deployment group create --resource-group $ResourceGroup --template-file $Template `
    --parameters $common deployApps=true "backendImage=$BackendImage" "frontendImage=$FrontendImage" `
    --output json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) { throw "Phase 5 failed." }

Write-Host ""
Write-Host "==> Deployment complete!" -ForegroundColor Green
Write-Host "    Backend:  $($p5.properties.outputs.backendUrl.value)"
Write-Host "    Frontend: $($p5.properties.outputs.frontendUrl.value)"
