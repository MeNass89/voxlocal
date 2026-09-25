[CmdletBinding()]
param(
    [string]$BackendUrl = $env:VOXLOCAL_GPU_URL,
    [string]$BindAddress = '127.0.0.1',
    [ValidateRange(1, 65535)] [int]$Port = 47365,
    [string]$TlsCert,
    [string]$TlsKey,
    [string]$TlsClientCA,
    [string]$GpuCAFile,
    [string]$PythonPath,
    [switch]$Mock
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

function Assert-File([string]$Path, [string]$Label) {
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Label is missing or unreadable: $Path"
    }
}

$projectRoot = Split-Path -Parent $PSScriptRoot
$serverScript = Join-Path $PSScriptRoot 'voxlocal_server.py'
Assert-File $serverScript 'server entrypoint'
$python = Resolve-Python311 $PythonPath

if ([string]::IsNullOrWhiteSpace($env:VOXLOCAL_PAIRING_CODE)) {
    throw 'VOXLOCAL_PAIRING_CODE is required from the environment or hospital secret provider; it is never accepted as a command-line argument.'
}
if ($Mock) {
    if ($BindAddress -notin @('127.0.0.1', '::1', 'localhost')) { throw 'Mock mode must bind to localhost.' }
    Remove-Item Env:VOXLOCAL_GPU_URL -ErrorAction SilentlyContinue
    Remove-Item Env:VOXLOCAL_LLM_URL -ErrorAction SilentlyContinue
} else {
    if ([string]::IsNullOrWhiteSpace($BackendUrl)) { throw 'VOXLOCAL_GPU_URL (HTTPS) is required for production mode.' }
    $backendUri = $null
    if (-not [Uri]::TryCreate($BackendUrl, [UriKind]::Absolute, [ref]$backendUri) -or $backendUri.Scheme -ne 'https') {
        throw 'VOXLOCAL_GPU_URL must be an https:// URL; plaintext upstreams are refused.'
    }
    if ([string]::IsNullOrWhiteSpace($env:VOXLOCAL_GPU_TOKEN)) { throw 'VOXLOCAL_GPU_TOKEN is required from the environment or secret provider.' }
    if ($env:VOXLOCAL_PAIRING_CODE.Length -lt 12) { throw 'VOXLOCAL_PAIRING_CODE must contain at least 12 characters in production mode.' }
    if ($BindAddress -in @('0.0.0.0', '::', '*', '127.0.0.1', '::1', 'localhost')) {
        throw 'Production mode requires an explicit clinical-interface -BindAddress (not wildcard or loopback).'
    }
    Assert-File $TlsCert 'TLS certificate'
    Assert-File $TlsKey 'TLS private key'
    if ($TlsClientCA) { Assert-File $TlsClientCA 'TLS client CA' }
    if ($GpuCAFile) { Assert-File $GpuCAFile 'GPU CA bundle' }
    $env:VOXLOCAL_GPU_URL = $BackendUrl
}

$scriptArgs = @($serverScript, '--host', $BindAddress, '--port', $Port.ToString())
if ($Mock) {
    $scriptArgs += @('--mock', '--insecure-test-only')
} else {
    $scriptArgs += @('--tls-cert', $TlsCert, '--tls-key', $TlsKey)
    if ($TlsClientCA) { $scriptArgs += @('--tls-client-ca', $TlsClientCA) }
    if ($GpuCAFile) { $scriptArgs += @('--gpu-ca-file', $GpuCAFile) }
}
Write-Host "VoxLocal server starting on $BindAddress`:$Port (mock=$($Mock.IsPresent)); secrets are read from the process environment only."
Push-Location $projectRoot
try { & $python @scriptArgs }
finally { Pop-Location }
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
