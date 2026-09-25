[CmdletBinding(SupportsShouldProcess, ConfirmImpact='High')]
param(
    [string]$InstallRoot = $(Join-Path $env:ProgramData 'VoxLocal'),
    [switch]$KeepData
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$target = [IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
if ([IO.Path]::GetPathRoot($target).TrimEnd('\') -eq $target) { throw 'Refusing to uninstall a filesystem root.' }
$manifestPath = Join-Path $target 'windows-runtime.manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { throw "No VoxLocal runtime manifest found at $manifestPath; refusing to remove an unrecognised directory." }
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
if ($manifest.installRoot -and ([IO.Path]::GetFullPath($manifest.installRoot).TrimEnd('\') -ne $target)) { throw 'Manifest installRoot does not match -InstallRoot; refusing to continue.' }
foreach ($task in @($manifest.scheduledTasks)) {
    if ($task) {
        $existing = Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue
        if ($existing -and $PSCmdlet.ShouldProcess($task, 'unregister Scheduled Task')) { Unregister-ScheduledTask -TaskName $task -Confirm:$false }
    }
}
if ($KeepData) {
    $preserve = Join-Path $target 'preserved-data'
    New-Item -ItemType Directory -Path $preserve -Force | Out-Null
    Write-Warning "-KeepData leaves the runtime directory in place at $target; remove it manually after review."
} elseif ($PSCmdlet.ShouldProcess($target, 'remove VoxLocal runtime and venv')) {
    Remove-Item -LiteralPath $target -Recurse -Force
}
