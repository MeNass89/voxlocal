# Launch the dsh web UI on the VoxLocal "scribe" profile (Windows workstation; also runs under pwsh on macOS).
# Same contract as run-web.sh:
#   $env:VOXLOCAL_LLM_URL   = 'https://<pod>:8443/llm/v1'   # OpenAI-compatible base URL, ends in /v1
#   $env:VOXLOCAL_LLM_TOKEN = '...'                         # GPU edge bearer token, from the environment only
#   .\harness\run-web.ps1 [dsh web flags, for example --port 3081]
# The portal bridge tokens (PORTAIL_BRIDGE_TOKEN, PORTAIL_BRIDGE_APPROVER_TOKEN) and SCRIBE_CLINICIAN are read
# by the plugins from this process environment. The web UI stays on the loopback interface: a non-loopback
# --host and any --trusted-host are refused here, and dsh itself refuses --host 0.0.0.0.
[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(ValueFromRemainingArguments = $true)] [string[]]$DshArgs = @()
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$onWindows = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
$loopbackHosts = @('127.0.0.1', '::1', '[::1]', 'localhost')

function Assert-LoopbackOrHttps([string]$Name, [string]$Value, [switch]$LoopbackOnly) {
    $uri = $null
    if (-not [Uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -notin @('http', 'https') -or $uri.UserInfo) {
        throw "$Name must be an absolute http(s) URL without credentials: $Value"
    }
    $isLoopback = $loopbackHosts -contains $uri.Host
    if ($LoopbackOnly -and -not $isLoopback) { throw "$Name must point at the loopback interface (127.0.0.1): $Value" }
    if ($uri.Scheme -eq 'http' -and -not $isLoopback) { throw "$Name uses plaintext HTTP to a remote host; use https:// or 127.0.0.1: $Value" }
}

if ([string]::IsNullOrWhiteSpace($env:VOXLOCAL_LLM_URL)) {
    throw 'set VOXLOCAL_LLM_URL to the OpenAI-compatible base URL (ending in /v1)'
}
if ([string]::IsNullOrWhiteSpace($env:VOXLOCAL_LLM_TOKEN)) {
    throw 'set VOXLOCAL_LLM_TOKEN to the GPU edge bearer token (environment only, never an argument)'
}
Assert-LoopbackOrHttps 'VOXLOCAL_LLM_URL' $env:VOXLOCAL_LLM_URL
if (-not [string]::IsNullOrWhiteSpace($env:PORTAIL_BRIDGE_URL)) {
    Assert-LoopbackOrHttps 'PORTAIL_BRIDGE_URL' $env:PORTAIL_BRIDGE_URL -LoopbackOnly
}
if ([string]::IsNullOrWhiteSpace($env:PORTAIL_BRIDGE_TOKEN) -or [string]::IsNullOrWhiteSpace($env:PORTAIL_BRIDGE_APPROVER_TOKEN)) {
    Write-Warning 'PORTAIL_BRIDGE_TOKEN and PORTAIL_BRIDGE_APPROVER_TOKEN are not both set: portal tools and approvals will fail until they are.'
} elseif ($env:PORTAIL_BRIDGE_TOKEN -eq $env:PORTAIL_BRIDGE_APPROVER_TOKEN) {
    throw 'PORTAIL_BRIDGE_APPROVER_TOKEN must differ from PORTAIL_BRIDGE_TOKEN.'
}

# The web UI must stay on this machine.
for ($i = 0; $i -lt $DshArgs.Count; $i++) {
    $arg = $DshArgs[$i]
    if ($arg -like '--trusted-host*') { throw '--trusted-host is refused: the clinical web UI is reachable from this workstation only.' }
    $hostValue = $null
    if ($arg -eq '--host') {
        if ($i + 1 -ge $DshArgs.Count) { throw '--host needs a value' }
        $hostValue = $DshArgs[$i + 1]
    } elseif ($arg -like '--host=*') {
        $hostValue = $arg.Substring(7)
    }
    if ($null -ne $hostValue -and $loopbackHosts -notcontains $hostValue) {
        throw "--host $hostValue is refused: the web UI binds the loopback interface only (127.0.0.1)."
    }
}

$harnessDir = $PSScriptRoot
$profileDir = Join-Path $harnessDir 'profile'
$env:DSH_HOME = Join-Path $harnessDir '.dsh-home'
# Keep the operator's personal ~/.agents skills and instructions out of the clinical agent.
$env:DSH_AGENTS_HOME = Join-Path $env:DSH_HOME 'agents'

$binDir = Join-Path (Join-Path $profileDir 'node_modules') '.bin'
$dsh = if ($onWindows) { Join-Path $binDir 'dsh.cmd' } else { Join-Path $binDir 'dsh' }

# Install the pinned dsh exactly as locked.
if (-not (Test-Path -LiteralPath $dsh -PathType Leaf)) {
    if (-not (Get-Command pnpm -ErrorAction SilentlyContinue)) { throw 'pnpm was not found on PATH (Node >= 22.19 and pnpm are required).' }
    Push-Location $profileDir
    try { & pnpm install --frozen-lockfile }
    finally { Pop-Location }
    if ($LASTEXITCODE -ne 0) { throw "pnpm install --frozen-lockfile exited with $LASTEXITCODE" }
    if (-not (Test-Path -LiteralPath $dsh -PathType Leaf)) { throw "dsh is missing after install: $dsh" }
}

# dsh looks up profiles under $DSH_HOME/profiles/<name>; point "scribe" at the tracked profile directory so
# the repository stays the single source. A directory junction needs no administrator right on Windows.
$profilesDir = Join-Path $env:DSH_HOME 'profiles'
$profileLink = Join-Path $profilesDir 'scribe'
if (-not (Test-Path -LiteralPath $profilesDir)) { New-Item -ItemType Directory -Path $profilesDir -Force | Out-Null }
if (-not (Test-Path -LiteralPath $profileLink)) {
    $linkType = if ($onWindows) { 'Junction' } else { 'SymbolicLink' }
    New-Item -ItemType $linkType -Path $profileLink -Target $profileDir | Out-Null
}

$dshArgv = @('--profile', 'scribe', '--no-open') + $DshArgs
Write-Host 'dsh web starting on the loopback interface; secrets are read from the process environment only.'
& $dsh @dshArgv
exit $LASTEXITCODE
