[CmdletBinding()]
param(
    [switch]$Mock,
    [ValidateRange(1, 65535)] [int]$Port = 47366,
    [string]$PythonPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Resolve-Python311 {
    param([string]$Requested)
    $candidates = @()
    if ($Requested) { $candidates += $Requested }
    $projectRoot = Split-Path -Parent $PSScriptRoot
    $venvPython = Join-Path $projectRoot '.venv\Scripts\python.exe'
    if (Test-Path -LiteralPath $venvPython -PathType Leaf) { $candidates += $venvPython }
    # Installed runtime keeps .venv beside src/, while source checkouts keep it beside agent/ or server/.
    $runtimeVenv = Join-Path (Split-Path -Parent $projectRoot) '.venv\Scripts\python.exe'
    if (Test-Path -LiteralPath $runtimeVenv -PathType Leaf) { $candidates += $runtimeVenv }
    if ($env:pythonLocation) { $candidates += (Join-Path $env:pythonLocation 'python.exe') }
    foreach ($name in @('python', 'python3', 'py')) {
        $command = Get-Command $name -ErrorAction SilentlyContinue
        if ($command -and $command.Source) { $candidates += $command.Source }
    }
    $probe = 'import sys; print("%d.%d" % sys.version_info[:2]); print(sys.executable)'
    foreach ($candidate in ($candidates | Where-Object { $_ } | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        $prefix = @(); if ([IO.Path]::GetFileName($candidate) -ieq 'py.exe') { $prefix = @('-3') }
        # Native stderr must not become a terminating error under Stop/StrictMode.
        $previous = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try { $lines = @(& $candidate @prefix -c $probe 2>$null | ForEach-Object { "$_".Trim() } | Where-Object { $_ }) }
        catch { $lines = @() }
        finally { $ErrorActionPreference = $previous }
        if ($LASTEXITCODE -ne 0 -or $lines.Count -lt 2) { continue }
        if ($lines[0] -match '^\d+\.\d+$' -and ([version]$lines[0] -ge [version]'3.11')) { return $lines[1] }
    }
    throw 'Python 3.11 or newer was not found. Install it for the machine or pass -PythonPath C:\Path\python.exe.'
}

$python = Resolve-Python311 $PythonPath
if ([string]::IsNullOrWhiteSpace($env:VOXLOCAL_AGENT_TOKEN)) { throw 'VOXLOCAL_AGENT_TOKEN is required from the environment or hospital secret provider.' }
if ($Mock) {
    Remove-Item Env:VOXLOCAL_GPU_URL -ErrorAction SilentlyContinue
    Remove-Item Env:VOXLOCAL_CLEAN_URL -ErrorAction SilentlyContinue
    Remove-Item Env:VOXLOCAL_LLM_URL -ErrorAction SilentlyContinue
} else {
    if ([string]::IsNullOrWhiteSpace($env:VOXLOCAL_GPU_URL)) { throw 'VOXLOCAL_GPU_URL (HTTPS) is required for production mode.' }
    $voiceUri = $null
    if (-not [Uri]::TryCreate($env:VOXLOCAL_GPU_URL, [UriKind]::Absolute, [ref]$voiceUri) -or $voiceUri.Scheme -ne 'https') { throw 'VOXLOCAL_GPU_URL must be an https:// URL.' }
    if ([string]::IsNullOrWhiteSpace($env:VOXLOCAL_GPU_TOKEN)) { throw 'VOXLOCAL_GPU_TOKEN is required from the environment or secret provider.' }
}

$projectRoot = Split-Path -Parent $PSScriptRoot
$scriptArgs = @('-m', 'agent.voxlocal_agent_api', 'serve', '--host', '127.0.0.1', '--port', $Port.ToString())
if ($Mock) { $scriptArgs += '--mock' }
Write-Host "VoxLocal agent API starting on loopback 127.0.0.1:$Port (mock=$($Mock.IsPresent)); secrets are read from the process environment only."
Push-Location $projectRoot
try { & $python @scriptArgs }
finally { Pop-Location }
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
