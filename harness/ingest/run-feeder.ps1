# Launch the VoxLocal dictation feeder (Windows workstation; also runs under pwsh on macOS).
# Same contract as `python3 -m harness.ingest.dictation_feeder`, run from the repository root:
#   $env:VOXLOCAL_API_TOKEN = '...'                     # dictation API token, from the environment only
#   $env:VOXLOCAL_API_URL   = 'http://127.0.0.1:47367'  # optional; loopback only in this launcher
#   .\harness\ingest\run-feeder.ps1 [feeder flags, for example --backend dryrun --once]
# DSH_HOME defaults to harness\.dsh-home (the Harness home run-web.ps1 uses) for the sdk backend.
# The dictation API must be on this machine: a non-loopback VOXLOCAL_API_URL or --api-url is refused here.
[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$PythonPath,
    [Parameter(ValueFromRemainingArguments = $true)] [string[]]$FeederArgs = @()
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$loopbackHosts = @('127.0.0.1', '::1', '[::1]', 'localhost')

function Resolve-Python311 {
    param([string]$Requested)
    $candidates = @()
    if ($Requested) { $candidates += $Requested }
    if ($env:pythonLocation) {
        $candidates += (Join-Path $env:pythonLocation 'python.exe')
        $candidates += (Join-Path (Join-Path $env:pythonLocation 'bin') 'python3')
    }
    foreach ($name in @('python', 'python3', 'py')) {
        $command = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
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

function Assert-LoopbackUrl([string]$Name, [string]$Value) {
    $uri = $null
    if (-not [Uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -notin @('http', 'https') -or $uri.UserInfo) {
        throw "$Name must be an absolute http(s) URL without credentials: $Value"
    }
    if ($loopbackHosts -notcontains $uri.Host) { throw "$Name must point at the loopback interface (127.0.0.1): $Value" }
}

if ([string]::IsNullOrWhiteSpace($env:VOXLOCAL_API_TOKEN)) {
    throw 'VOXLOCAL_API_TOKEN is required from the environment (never as an argument).'
}
if (-not [string]::IsNullOrWhiteSpace($env:VOXLOCAL_API_URL)) { Assert-LoopbackUrl 'VOXLOCAL_API_URL' $env:VOXLOCAL_API_URL }
for ($i = 0; $i -lt $FeederArgs.Count; $i++) {
    $arg = $FeederArgs[$i]
    if ($arg -eq '--api-url') {
        if ($i + 1 -ge $FeederArgs.Count) { throw '--api-url needs a value' }
        Assert-LoopbackUrl '--api-url' $FeederArgs[$i + 1]
    } elseif ($arg -like '--api-url=*') {
        Assert-LoopbackUrl '--api-url' $arg.Substring(10)
    }
}

$harnessDir = Split-Path -Parent $PSScriptRoot
$repoRoot = Split-Path -Parent $harnessDir
if ([string]::IsNullOrWhiteSpace($env:DSH_HOME)) { $env:DSH_HOME = Join-Path $harnessDir '.dsh-home' }
if ([string]::IsNullOrWhiteSpace($env:DSH_AGENTS_HOME)) { $env:DSH_AGENTS_HOME = Join-Path $env:DSH_HOME 'agents' }

$python = Resolve-Python311 $PythonPath
$argv = @('-m', 'harness.ingest.dictation_feeder') + $FeederArgs
Write-Host "dictation feeder starting with $python; secrets are read from the process environment only."
# Run from the repository root so `harness.ingest` resolves as a package.
Push-Location $repoRoot
try { & $python @argv }
finally { Pop-Location }
exit $LASTEXITCODE
