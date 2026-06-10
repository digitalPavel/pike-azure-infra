# Scaffolds a new Azure Container Apps deployment into a target project, using the
# shared modules + a chosen profile from this template repo. Run from anywhere.
#
# Example (single Flask tool, no DB, EasyAuth):
#   .\New-Project.ps1 -TargetPath C:\dev\other-projects\my-tool `
#       -AppName my-tool -Profile single-app -Runtime python -AuthMode easyauth
#
# Example (single Next.js app + Postgres + migrations + CI):
#   .\New-Project.ps1 -TargetPath C:\dev\other-projects\my-app `
#       -AppName my-app -Profile single-app -Runtime node `
#       -IncludeDatabase -IncludeMigrateJob -AuthMode nextauth -IncludeCICD
#
# Example (dual app — backend + frontend + shared Postgres):
#   .\New-Project.ps1 -TargetPath C:\dev\other-projects\my-suite `
#       -AppName my-suite -Profile dual-app -Runtime node

#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$TargetPath,
    [Parameter(Mandatory)] [string]$AppName,

    [ValidateSet('dev', 'staging', 'prod')]
    [string]$Environment = 'prod',
    [string]$Location = 'eastus2',

    [ValidateSet('single-app', 'dual-app')]
    [string]$Profile = 'single-app',

    [ValidateSet('python', 'node')]
    [string]$Runtime = 'python',

    [switch]$IncludeDatabase,
    [switch]$IncludeMigrateJob,

    [ValidateSet('none', 'nextauth', 'easyauth')]
    [string]$AuthMode = 'none',

    [switch]$IncludeCICD,

    [string]$TenantId = '9fbce44f-d64c-4f7e-bbe0-19479c36278b',

    # Overwrite an existing infra/ folder in the target.
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path  # this template repo

# dual-app always provisions a shared database + migrate job.
if ($Profile -eq 'dual-app') {
    $IncludeDatabase  = $true
    $IncludeMigrateJob = $true
}
if ($IncludeMigrateJob -and -not $IncludeDatabase) {
    throw "-IncludeMigrateJob requires -IncludeDatabase."
}

$InfraDir   = Join-Path $TargetPath 'infra'
$ModulesDir = Join-Path $InfraDir 'modules'

if ((Test-Path (Join-Path $InfraDir 'main.bicep')) -and -not $Force) {
    throw "infra\main.bicep already exists in '$TargetPath'. Re-run with -Force to overwrite."
}

New-Item -ItemType Directory -Path $ModulesDir -Force | Out-Null

# ---------- Select modules ----------
$modules = @(
    'logAnalytics.bicep'
    'appInsights.bicep'
    'containerRegistry.bicep'
    'containerAppsEnvironment.bicep'
    'appIdentity.bicep'
    'containerApp.bicep'
)
if ($IncludeDatabase)  { $modules += 'postgresFlexibleServer.bicep' }
if ($IncludeMigrateJob) { $modules += 'migrateJob.bicep' }

foreach ($m in $modules) {
    Copy-Item (Join-Path $Root "modules\$m") (Join-Path $ModulesDir $m) -Force
}
Write-Host "Copied $($modules.Count) modules -> infra\modules\"

# ---------- Copy the chosen profile (main.bicep + deploy.ps1) ----------
# In the repo, profile main.bicep references modules via '../../modules/' (so it
# resolves in place). In a scaffolded project the modules sit at infra\modules\,
# next to main.bicep, so rewrite the path to 'modules/'.
$ProfileDir = Join-Path $Root "profiles\$Profile"
$mainBicep = (Get-Content (Join-Path $ProfileDir 'main.bicep') -Raw).Replace("'../../modules/", "'modules/")
Set-Content (Join-Path $InfraDir 'main.bicep') $mainBicep -NoNewline
Copy-Item (Join-Path $ProfileDir 'deploy.ps1') (Join-Path $InfraDir 'deploy.ps1') -Force
Write-Host "Copied profile '$Profile' -> infra\main.bicep + infra\deploy.ps1"

# ---------- Token substitution helper ----------
$acrName = (($AppName + $Environment) -replace '-', '') + 'acr'
$tokens = @{
    '{{APP_NAME}}'    = $AppName
    '{{ENVIRONMENT}}' = $Environment
    '{{LOCATION}}'    = $Location
    '{{TENANT_ID}}'   = $TenantId
    '{{ACR_NAME}}'    = $acrName
}
function Expand-Tokens([string]$Text) {
    foreach ($k in $tokens.Keys) { $Text = $Text.Replace($k, $tokens[$k]) }
    return $Text
}

# ---------- Render parameters.json ----------
$paramsTmpl = Get-Content (Join-Path $Root 'templates\parameters.json.tmpl') -Raw
Set-Content (Join-Path $InfraDir 'parameters.json') (Expand-Tokens $paramsTmpl) -NoNewline
Write-Host "Rendered infra\parameters.json"

# ---------- Dockerfile + .dockerignore ----------
$dockerfile = if ($Runtime -eq 'node') { 'Dockerfile.node' } else { 'Dockerfile.python' }
if (-not (Test-Path (Join-Path $TargetPath 'Dockerfile')) -or $Force) {
    Copy-Item (Join-Path $Root "shared\$dockerfile") (Join-Path $TargetPath 'Dockerfile') -Force
    Write-Host "Copied $dockerfile -> Dockerfile"
} else {
    Write-Host "Skipped Dockerfile (already exists; use -Force to overwrite)" -ForegroundColor Yellow
}
if (-not (Test-Path (Join-Path $TargetPath '.dockerignore'))) {
    Copy-Item (Join-Path $Root 'shared\.dockerignore') (Join-Path $TargetPath '.dockerignore') -Force
}

# ---------- Optional CI workflow ----------
if ($IncludeCICD) {
    $wfDir = Join-Path $TargetPath '.github\workflows'
    New-Item -ItemType Directory -Path $wfDir -Force | Out-Null
    $wf = Get-Content (Join-Path $Root 'ci\github-deploy.yml') -Raw
    Set-Content (Join-Path $wfDir 'deploy.yml') (Expand-Tokens $wf) -NoNewline
    Write-Host "Copied CI workflow -> .github\workflows\deploy.yml"
}

# ---------- Next steps ----------
Write-Host ""
Write-Host "Scaffolded '$AppName' ($Profile / $Runtime) into $TargetPath" -ForegroundColor Green
Write-Host "Next:" -ForegroundColor Yellow
Write-Host "  1. Edit infra\main.bicep — fill in the >>> FILL IN <<< env/secrets blocks for your app."
Write-Host "  2. Adjust the Dockerfile COPY lines / entrypoint for your project."
Write-Host "  3. az bicep build --file infra\main.bicep   # validate it compiles"
$dbArgs = if ($IncludeDatabase) { " -IncludeDatabase" } else { "" }
$mjArgs = if ($IncludeMigrateJob) { " -IncludeMigrateJob -PostgresAdminPassword <pw> -PostgresAppPassword <pw>" } else { "" }
Write-Host "  4. .\infra\deploy.ps1 -ResourceGroup $AppName-$Environment-rg$dbArgs$mjArgs"
