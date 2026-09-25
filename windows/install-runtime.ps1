[CmdletBinding()]
param(
    [string]$InstallRoot = $(Join-Path $env:ProgramData 'VoxLocal'),
    [string]$PythonPath,
    [ValidateSet('Agent', 'Server')] [string]$ScheduledTask,
    [switch]$RegisterScheduledTask,
    [switch]$MockTask,
    [string]$TaskName,
    [string]$BindAddress = '127.0.0.1',
    [ValidateRange(1, 65535)] [int]$Port = 47365,
    [ValidateRange(1, 65535)] [int]$AgentPort = 47366,
    [string]$TlsCert,
    [string]$TlsKey,
    [string]$TlsDir,
    [string]$TlsClientCA,
    [string]$GpuCAFile,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Resolve-Python311 {
    param([string]$Requested)
    $candidates = @(); if ($Requested) { $candidates += $Requested }
    foreach ($name in @('python', 'python3', 'py')) { $command = Get-Command $name -ErrorAction SilentlyContinue; if ($command) { $candidates += $command.Source } }
    foreach ($candidate in ($candidates | Select-Object -Unique)) {
        try {
            $prefix = @(); if ([IO.Path]::GetFileName($candidate) -ieq 'py.exe') { $prefix = @('-3.11') }
            $versionText = (& $candidate @prefix -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>$null | Select-Object -First 1).Trim()
            if ($LASTEXITCODE -eq 0 -and $versionText -match '^\d+\.\d+$' -and ([version]$versionText -ge [version]'3.11')) {
                if ($prefix.Count -eq 0) { return $candidate }
                return ((& $candidate @prefix -c 'import sys; print(sys.executable)' 2>$null | Select-Object -First 1).Trim())
            }
        } catch { }
    }
    throw 'Python 3.11 or newer was not found. Install it first or pass -PythonPath C:\Path\python.exe.'
}

function Assert-File([string]$Path, [string]$Label) {
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "$Label is missing or unreadable: $Path" }
}

function Assert-Directory([string]$Path, [string]$Label) {
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Container)) { throw "$Label is missing or unreadable: $Path" }
}

$sourceRoot = Split-Path -Parent $PSScriptRoot
$sourceFull = [IO.Path]::GetFullPath($sourceRoot).TrimEnd('\')
$targetFull = [IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
if ($targetFull -eq $sourceFull -or $targetFull.StartsWith($sourceFull + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw '-InstallRoot must be outside the source checkout; refusing a recursive self-copy.'
}
if ($TlsDir -and ($TlsCert -or $TlsKey)) { throw 'Pass either -TlsDir (generated identity) or -TlsCert/-TlsKey (provided certificate), not both.' }
if ($RegisterScheduledTask -and $ScheduledTask -eq 'Server' -and -not $MockTask -and -not $TlsCert -and -not $TlsDir) {
    throw 'A production server task requires -TlsDir (VoxLocal generates and keeps the identity there) or -TlsCert/-TlsKey.'
}
$python = Resolve-Python311 $PythonPath
$existingManifest = Join-Path $targetFull 'windows-runtime.manifest.json'
if ((Test-Path -LiteralPath $targetFull) -and -not (Test-Path -LiteralPath $existingManifest) -and ((Get-ChildItem -LiteralPath $targetFull -Force | Measure-Object).Count -gt 0) -and -not $Force) {
    throw "InstallRoot already contains files and no VoxLocal manifest. Choose an empty directory or pass -Force after review."
}
if (-not (Test-Path -LiteralPath $targetFull)) { New-Item -ItemType Directory -Path $targetFull -Force | Out-Null }
$src = Join-Path $targetFull 'src'
$venv = Join-Path $targetFull '.venv'
if (-not (Test-Path -LiteralPath $src)) { New-Item -ItemType Directory -Path $src -Force | Out-Null }
foreach ($item in @('agent', 'server', 'windows', 'pyproject.toml')) {
    $from = Join-Path $sourceRoot $item
    if (-not (Test-Path -LiteralPath $from)) { throw "Source item is missing: $from" }
    if ($item -eq 'pyproject.toml') { Assert-File $from $item } else { Assert-Directory $from $item }
    Copy-Item -LiteralPath $from -Destination $src -Recurse -Force
}

$venvPython = Join-Path $venv 'Scripts\python.exe'
if (-not (Test-Path -LiteralPath $venvPython -PathType Leaf)) {
    Write-Host "Creating Python virtual environment at $venv"
    & $python -m venv $venv
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $venvPython -PathType Leaf)) { throw 'Python venv creation failed; check filesystem ACLs and the Python installation.' }
}
Write-Host 'Registering the local VoxLocal package in the venv (no pip, no index, no build backend).'
# A .pth file makes the copied src/ importable from site-packages without any
# build step: it works on every CPython >= 3.11 regardless of the bundled
# setuptools version, and leaves nothing to download.
$sitePackages = (& $venvPython -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])' 2>$null | Select-Object -First 1)
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($sitePackages) -or -not (Test-Path -LiteralPath $sitePackages -PathType Container)) {
    throw 'Could not locate the venv site-packages directory.'
}
Set-Content -LiteralPath (Join-Path $sitePackages 'voxlocal.pth') -Value $src -Encoding ASCII -NoNewline
# Verify from outside the checkout so the import resolves through the .pth entry.
Push-Location $env:TEMP
try {
    & $venvPython -c 'import agent.voxlocal_agent_api; print("agent import ok")'
    if ($LASTEXITCODE -ne 0) { throw 'Installed agent package could not be imported from the new venv.' }
} finally { Pop-Location }

$tlsFingerprint = $null
if ($TlsDir) {
    # Generates server.cert.pem/server.key.pem once (reused on later installs) and returns the pinned fingerprint.
    $identity = & (Join-Path $PSScriptRoot 'new-tls-identity.ps1') -OutputDir $TlsDir
    $TlsCert = $identity.CertPath
    $TlsKey = $identity.KeyPath
    $tlsFingerprint = $identity.FingerprintBase64
    Write-Host "Compare this fingerprint with the one the iPhone shows at first connection: $($identity.FingerprintDisplay)"
}

$taskNames = @()
if ($RegisterScheduledTask) {
    if (-not $ScheduledTask) { throw '-ScheduledTask Agent or -ScheduledTask Server is required with -RegisterScheduledTask.' }
    $taskNameEffective = if ($TaskName) { $TaskName } else { "VoxLocal $ScheduledTask" }
    if ($ScheduledTask -eq 'Server' -and -not $MockTask) {
        if ($BindAddress -in @('127.0.0.1', '::1', 'localhost', '0.0.0.0', '::', '*')) { throw 'A production server task requires an explicit clinical-interface -BindAddress.' }
        Assert-File $TlsCert 'TLS certificate'; Assert-File $TlsKey 'TLS private key'; if ($TlsClientCA) { Assert-File $TlsClientCA 'TLS client CA' }; if ($GpuCAFile) { Assert-File $GpuCAFile 'GPU CA bundle' }
    }
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $runRelative = if ($ScheduledTask -eq 'Agent') { 'agent\run-windows.ps1' } else { 'server\run-windows.ps1' }
    $runScript = Join-Path $src $runRelative
    Assert-File $runScript 'scheduled task launcher'
    $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $runScript)
    if ($ScheduledTask -eq 'Agent') { $args += @('-Port', $AgentPort.ToString()) } else { $args += @('-BindAddress', $BindAddress, '-Port', $Port.ToString()); if ($TlsCert) { $args += @('-TlsCert', $TlsCert) }; if ($TlsKey) { $args += @('-TlsKey', $TlsKey) }; if ($TlsClientCA) { $args += @('-TlsClientCA', $TlsClientCA) }; if ($GpuCAFile) { $args += @('-GpuCAFile', $GpuCAFile) } }
    if ($MockTask) { $args += '-Mock' }
    $quotedArgs = ($args | ForEach-Object { '"' + $_.Replace('"', '\"') + '"' }) -join ' '
    $action = New-ScheduledTaskAction -Execute $ps -Argument $quotedArgs
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType InteractiveToken -RunLevel Limited
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
    Register-ScheduledTask -TaskName $taskNameEffective -Action $action -Principal $principal -Trigger $trigger -Description 'VoxLocal launcher; foreground Python process, not a Windows Service.' -Force | Out-Null
    $taskNames += $taskNameEffective
    Write-Warning 'Scheduled Task runs only at interactive logon and is not a Windows Service. Configure secret injection for that account; no token is stored in the task action.'
}

$manifest = [ordered]@{ schema = 1; installRoot = $targetFull; source = $sourceFull; venv = $venv; scheduledTasks = $taskNames; tlsFingerprintSha256 = $tlsFingerprint; installedUtc = [DateTime]::UtcNow.ToString('o') }
$manifestPath = Join-Path $targetFull 'windows-runtime.manifest.json'
$manifest | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
Write-Host "VoxLocal runtime installed at $targetFull. Secrets were not written by this script."
