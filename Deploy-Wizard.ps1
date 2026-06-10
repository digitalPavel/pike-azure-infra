# Deploy-Wizard.ps1 — guided, interactive deploy. Run with no arguments:
#
#   .\Deploy-Wizard.ps1
#
# It logs into Azure (if needed), asks for each value step by step (with defaults
# and auto-generated secrets), scaffolds the project, pauses so you can fill in any
# app-specific config, then runs the phased deploy and prints the app URL.
#
# Prerequisites: Azure CLI + Docker Desktop installed; Docker running.

#Requires -Version 5.1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path

# ─── Prompt helpers ──────────────────────────────────────────────────────────
function Ask([string]$Prompt, [string]$Default = '') {
    $suffix = if ($Default -ne '') { " [$Default]" } else { '' }
    $val = Read-Host "$Prompt$suffix"
    if ([string]::IsNullOrWhiteSpace($val)) { return $Default }
    return $val.Trim()
}
function AskChoice([string]$Prompt, [string[]]$Options, [string]$Default) {
    while ($true) {
        $val = Ask "$Prompt ($($Options -join '/'))" $Default
        if ($Options -contains $val) { return $val }
        Write-Host "  Choose one of: $($Options -join ', ')" -ForegroundColor Yellow
    }
}
# Numbered picklist with a final "Other (type any)" option.
function AskMenu([string]$Prompt, [string[]]$Options, [string]$Default) {
    Write-Host "  $Prompt"
    for ($i = 0; $i -lt $Options.Count; $i++) {
        $mark = if ($Options[$i] -eq $Default) { '  (default)' } else { '' }
        Write-Host ("    {0,2}) {1}{2}" -f ($i + 1), $Options[$i], $mark)
    }
    $otherNum = $Options.Count + 1
    Write-Host ("    {0,2}) Other (type any)" -f $otherNum)
    $defaultNum = ([array]::IndexOf($Options, $Default) + 1)
    while ($true) {
        $val = Ask "  Choice (number)" "$defaultNum"
        $n = 0
        if ([int]::TryParse($val, [ref]$n)) {
            if ($n -ge 1 -and $n -le $Options.Count) { return $Options[$n - 1] }
            if ($n -eq $otherNum) {
                $custom = Ask "  Enter value"
                if ($custom) { return $custom }
            }
        }
        Write-Host "  Enter a number from the list." -ForegroundColor Yellow
    }
}
function AskYesNo([string]$Prompt, [bool]$Default = $false) {
    $d = if ($Default) { 'Y' } else { 'N' }
    while ($true) {
        $val = (Ask "$Prompt (y/n)" $d).ToLower()
        if ($val -in @('y', 'yes')) { return $true }
        if ($val -in @('n', 'no'))  { return $false }
    }
}
function AskSecret([string]$Prompt) {
    $sec = Read-Host $Prompt -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}
function New-RandomSecret([int]$Bytes = 32) {
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $b = New-Object byte[] $Bytes
    $rng.GetBytes($b)
    return [Convert]::ToBase64String($b)
}
# Alphanumeric only — base64 ('/','+','=') would corrupt the postgresql://user:pw@host
# connection string (Bicep doesn't URL-encode it). Upper+lower+digit satisfies Azure
# Postgres complexity (3 of 4 categories) with no URL-unsafe characters.
function New-RandomPassword([int]$Length = 24) {
    $alphabet = 'abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789'
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $bytes = New-Object byte[] $Length
    $rng.GetBytes($bytes)
    $chars = for ($i = 0; $i -lt $Length; $i++) { $alphabet[$bytes[$i] % $alphabet.Length] }
    # Prefix guarantees an uppercase, a lowercase, and a digit are present.
    return 'Aa7' + (-join $chars)
}

# Curated regions (Container Apps + PostgreSQL Flexible Server + burstable SKU all available).
$Regions = @('eastus2', 'eastus', 'centralus', 'westus2', 'westus3', 'southcentralus', 'westeurope', 'uksouth')

Write-Host "`n=== Pike Azure Deploy Wizard ===`n" -ForegroundColor Cyan

# ─── Step 1/6: Azure login ───────────────────────────────────────────────────
Write-Host "Step 1/6 — Azure" -ForegroundColor Cyan
if (-not (Get-Command az -ErrorAction SilentlyContinue)) { throw "Azure CLI not found. Install: https://aka.ms/installazurecli" }
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { throw "Docker not found. Install Docker Desktop." }
az account show -o none 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Host "  Not logged in — opening browser..." -ForegroundColor Yellow
    az login -o none
    if ($LASTEXITCODE -ne 0) { throw "az login failed." }
}
$sub = az account show --query name -o tsv
Write-Host "  Subscription: $sub"
if (-not (AskYesNo "  Use this subscription?" $true)) {
    az account list --query "[].name" -o tsv | ForEach-Object { Write-Host "    - $_" }
    az account set --subscription (Ask "  Enter subscription name or id")
}

# ─── Step 2/6: Project shape ─────────────────────────────────────────────────
Write-Host "`nStep 2/6 — Project" -ForegroundColor Cyan
# Must be a valid Container App / ACR name: lowercase letter first, then lowercase
# alphanumeric or hyphen, no trailing hyphen, short enough that <name>-<env>-app fits.
while ($true) {
    $AppName = Ask "  App name (lowercase, drives all resource names)"
    if ($AppName -cmatch '^[a-z][a-z0-9-]{1,22}[a-z0-9]$') { break }
    Write-Host "  Use lowercase letters, digits, and hyphens; start with a letter; 3-24 chars." -ForegroundColor Yellow
}
$Environment = AskChoice "  Environment" @('dev', 'staging', 'prod') 'prod'
$Location    = AskMenu "  Azure region:" $Regions 'eastus2'
$ProfileName = AskChoice "  Profile" @('single-app', 'dual-app') 'single-app'
$Runtime     = AskChoice "  Runtime" @('python', 'node') 'node'
$TargetPath  = Ask "  Target project path" "C:\dev\other-projects\$AppName"

# ─── Step 3/6: Features ──────────────────────────────────────────────────────
Write-Host "`nStep 3/6 — Features" -ForegroundColor Cyan
if ($ProfileName -eq 'dual-app') {
    $IncludeDatabase = $true; $IncludeMigrateJob = $true
    Write-Host "  dual-app always includes PostgreSQL + a migrate job."
} else {
    $IncludeDatabase  = AskYesNo "  Include PostgreSQL database?" $true
    $IncludeMigrateJob = if ($IncludeDatabase) { AskYesNo "  Include migrate job (container job)?" $true } else { $false }
}
$defaultAuth = if ($Runtime -eq 'node') { 'nextauth' } else { 'easyauth' }
$AuthMode    = AskChoice "  Auth mode" @('none', 'nextauth', 'easyauth') $defaultAuth
$IncludeCICD = AskYesNo "  Add GitHub Actions CI/CD workflow?" $false

# ─── Step 4/6: Secrets ───────────────────────────────────────────────────────
Write-Host "`nStep 4/6 — Secrets (press Enter to auto-generate)" -ForegroundColor Cyan
$PgAdmin = ''; $PgApp = ''; $AuthSecret = ''
$generated = @()
if ($IncludeDatabase) {
    $PgAdmin = AskSecret "  Postgres ADMIN password (Enter = auto-generate)"
    if (-not $PgAdmin) { $PgAdmin = New-RandomPassword; $generated += "Postgres admin: $PgAdmin" }
    $PgApp = AskSecret "  Postgres APP password (Enter = auto-generate)"
    if (-not $PgApp) { $PgApp = New-RandomPassword; $generated += "Postgres app:   $PgApp" }
}
# dual-app requires AuthSecret regardless of mode; single-app needs it for nextauth.
if ($AuthMode -eq 'nextauth' -or $ProfileName -eq 'dual-app') {
    $AuthSecret = AskSecret "  AUTH_SECRET (Enter = auto-generate)"
    if (-not $AuthSecret) { $AuthSecret = New-RandomSecret 32; $generated += "AUTH_SECRET:    $AuthSecret" }
}

# Entra / SSO
$EntraId = ''; $EntraSecret = ''; $haveEntra = $false
if ($AuthMode -ne 'none') {
    $haveEntra = AskYesNo "  Do you have Entra app-registration creds now?" $false
    if ($haveEntra) {
        $EntraId     = Ask "    Entra client ID"
        $EntraSecret = AskSecret "    Entra client secret"
    }
    elseif ($AuthMode -eq 'easyauth') {
        Write-Host "    easyauth needs creds and has no fallback — deploying authMode=none for now;" -ForegroundColor Yellow
        Write-Host "    re-run later with creds to enable EasyAuth." -ForegroundColor Yellow
        $AuthMode = 'none'
    }
    else {
        Write-Host "    OK — SSO stays dormant (password-only). Re-run later with creds to enable it." -ForegroundColor Yellow
    }
}
$ResourceGroup = Ask "  Resource group" "$AppName-$Environment-rg"

# Show auto-generated secrets so they aren't lost.
if ($generated.Count -gt 0) {
    Write-Host "`n  >>> SAVE THESE — auto-generated, shown once: <<<" -ForegroundColor Yellow
    $generated | ForEach-Object { Write-Host "    $_" -ForegroundColor Yellow }
}

# ─── Step 5/6: Scaffold ──────────────────────────────────────────────────────
Write-Host "`nStep 5/6 — Scaffolding '$AppName' ($ProfileName / $Runtime)..." -ForegroundColor Cyan
$scaffold = @{
    TargetPath  = $TargetPath
    AppName     = $AppName
    Environment = $Environment
    Location    = $Location
    Profile     = $ProfileName
    Runtime     = $Runtime
    AuthMode    = $AuthMode
}
if ($IncludeDatabase)   { $scaffold.IncludeDatabase   = $true }
if ($IncludeMigrateJob) { $scaffold.IncludeMigrateJob = $true }
if ($IncludeCICD)       { $scaffold.IncludeCICD        = $true }
if (Test-Path (Join-Path $TargetPath 'infra\main.bicep')) {
    if (AskYesNo "  infra\ already exists in target — overwrite?" $false) { $scaffold.Force = $true }
    else { throw "Aborted (infra already exists)." }
}
& (Join-Path $Root 'New-Project.ps1') @scaffold

# ─── Fill-in pause ───────────────────────────────────────────────────────────
Write-Host "`n--- Fill in app config (optional) ---" -ForegroundColor Yellow
Write-Host "  1. $TargetPath\infra\main.bicep  — add any app-specific env/secrets (>>> FILL IN <<< block)."
Write-Host "  2. $TargetPath\Dockerfile        — adjust COPY lines / entrypoint / port for your app."
Write-Host "  Skip if your app needs nothing beyond the wired defaults."
if (-not (AskYesNo "`n  Ready to deploy now?" $true)) {
    Write-Host "`nStopped before deploy. When ready, run from $TargetPath:" -ForegroundColor Cyan
    Write-Host "  .\infra\deploy.ps1 -ResourceGroup $ResourceGroup ..."
    return
}

# ─── Step 6/6: Deploy ────────────────────────────────────────────────────────
Write-Host "`nStep 6/6 — Deploying (phased: infra -> build/push -> migrate -> app)..." -ForegroundColor Cyan
$deploy = @{
    ResourceGroup = $ResourceGroup
    Location      = $Location
    AuthMode      = $AuthMode
}
if ($IncludeDatabase) {
    $deploy.PostgresAdminPassword = $PgAdmin
    $deploy.PostgresAppPassword   = $PgApp
}
if ($AuthSecret) { $deploy.AuthSecret = $AuthSecret }
if ($haveEntra)  { $deploy.EntraClientId = $EntraId; $deploy.EntraClientSecret = $EntraSecret }
# single-app's deploy.ps1 takes the feature switches; dual-app's does not.
if ($ProfileName -eq 'single-app') {
    if ($IncludeDatabase)   { $deploy.IncludeDatabase   = $true }
    if ($IncludeMigrateJob) { $deploy.IncludeMigrateJob = $true }
}
& (Join-Path $TargetPath 'infra\deploy.ps1') @deploy

Write-Host "`n=== Wizard complete. The app URL is printed above. ===" -ForegroundColor Green
