<#
Generate the TLS identity of a VoxLocal Windows host.

Same certificate as VoxLocal.app and scripts/make-tls-identity.sh: RSA 2048,
self-signed, 3650 days, SAN DNS:<host>.local, DNS:localhost, IP:127.0.0.1.
The iPhone pins the SHA-256 of the DER certificate; this script prints it in
base64 (Bonjour TXT "fp", server log) and in grouped hex (what the phone shows).

  .\new-tls-identity.ps1 -OutputDir C:\ProgramData\VoxLocal\tls

An existing identity is never overwritten without -Force: the script prints
its fingerprint and returns it, so it is safe to run again. The private key
ACL is reduced to read access for the current account only.

Returns an object with CertPath, KeyPath, FingerprintBase64 and
FingerprintDisplay (used by install-runtime.ps1).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$OutputDir,

    [string]$HostName,

    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Resolve-OpenSsl {
    $candidates = @()
    if ($env:OPENSSL_EXE) { $candidates += $env:OPENSSL_EXE }
    $command = Get-Command openssl -ErrorAction SilentlyContinue
    if ($command) { $candidates += $command.Source }
    $candidates += 'C:\Program Files\Git\usr\bin\openssl.exe'
    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) { return $candidate }
    }
    throw 'openssl.exe was not found. Install Git for Windows (it ships usr\bin\openssl.exe), add openssl to PATH, or set OPENSSL_EXE.'
}

function Get-CertificateFingerprint([string]$CertPath) {
    # SHA-256 of the DER bytes of the first (leaf) certificate in the PEM file.
    $text = [IO.File]::ReadAllText($CertPath)
    $match = [regex]::Match($text, '-----BEGIN CERTIFICATE-----(.+?)-----END CERTIFICATE-----', [Text.RegularExpressions.RegexOptions]::Singleline)
    if (-not $match.Success) { throw "No PEM certificate found in $CertPath" }
    $der = [Convert]::FromBase64String(($match.Groups[1].Value -replace '\s', ''))
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $digest = $sha.ComputeHash($der) } finally { $sha.Dispose() }
    $hex = -join ($digest | ForEach-Object { $_.ToString('X2') })
    return [pscustomobject]@{
        Base64  = [Convert]::ToBase64String($digest)
        Display = (($hex -split '(.{4})' | Where-Object { $_ }) -join ' ')
    }
}

function Invoke-Native([string]$FilePath, [string[]]$Arguments, [string]$Label) {
    # Windows PowerShell 5.1 turns native stderr into terminating errors under
    # ErrorActionPreference=Stop; openssl writes progress there, so capture it.
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $output = & $FilePath @Arguments 2>&1 | Out-String } finally { $ErrorActionPreference = $previous }
    if ($LASTEXITCODE -ne 0) { throw "$Label failed (exit $LASTEXITCODE): $($output.Trim())" }
}

function Write-Identity([string]$CertPath, [string]$KeyPath) {
    $fingerprint = Get-CertificateFingerprint $CertPath
    Write-Host "Certificate: $CertPath"
    Write-Host "Private key: $KeyPath"
    Write-Host "SHA-256 fingerprint (base64): $($fingerprint.Base64)"
    Write-Host "SHA-256 fingerprint (compare on the iPhone): $($fingerprint.Display)"
    return [pscustomobject]@{
        CertPath           = $CertPath
        KeyPath            = $KeyPath
        FingerprintBase64  = $fingerprint.Base64
        FingerprintDisplay = $fingerprint.Display
    }
}

if (-not $HostName) { $HostName = ([Net.Dns]::GetHostName() -split '\.')[0] }
$HostName = ($HostName -replace '\.local$', '').ToLowerInvariant()
# The name is interpolated into the openssl config and -addext: accept a DNS label only.
if ($HostName -notmatch '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$') {
    throw "Invalid host name '$HostName'; pass -HostName with letters, digits and hyphens only."
}

# Resolve against the PowerShell location (not the .NET current directory); the path may not exist yet.
$dir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDir)
$keyPath = Join-Path $dir 'server.key.pem'
$certPath = Join-Path $dir 'server.cert.pem'
$hasKey = Test-Path -LiteralPath $keyPath -PathType Leaf
$hasCert = Test-Path -LiteralPath $certPath -PathType Leaf

$icacls = Join-Path $env:SystemRoot 'System32\icacls.exe'
$account = "${env:USERDOMAIN}\${env:USERNAME}"

function Get-ForeignKeyReaders([string]$Path) {
    # SIDs, not names: icacls prints localized principals (AUTORITE NT\Système...).
    $allowed = @('S-1-5-18', 'S-1-5-32-544', [Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
    $sids = @()
    foreach ($ace in (Get-Acl -LiteralPath $Path).Access) {
        if ($ace.AccessControlType -ne 'Allow') { continue }
        try { $sid = $ace.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value }
        catch { $sid = "$($ace.IdentityReference)" }
        if ($allowed -notcontains $sid) { $sids += $sid }
    }
    return @($sids | Select-Object -Unique)
}

if (($hasKey -or $hasCert) -and -not $Force) {
    if ($hasKey -and $hasCert) {
        Write-Host 'Existing TLS identity kept (-Force replaces it; every iPhone must then approve the new fingerprint).'
        # A key copied in or edited by hand may be readable by another account, which
        # could then impersonate the pinned host: tighten it before reusing it.
        $foreign = @(Get-ForeignKeyReaders $keyPath)
        if ($foreign.Count -gt 0) {
            Invoke-Native $icacls @($keyPath, '/inheritance:r', '/grant:r', "${account}:(R)") 'icacls'
            # /inheritance:r drops inherited ACEs only; explicit grants need /remove.
            $explicit = @(Get-ForeignKeyReaders $keyPath)
            if ($explicit.Count -gt 0) {
                $removeArgs = @($keyPath, '/remove') + @($explicit | ForEach-Object { if ($_ -like 'S-1-*') { "*$_" } else { $_ } })
                Invoke-Native $icacls $removeArgs 'icacls'
            }
            $left = @(Get-ForeignKeyReaders $keyPath)
            if ($left.Count -gt 0) { throw "Private key $keyPath is still readable by $($left -join ', '); fix its ACL or rerun with -Force." }
            Write-Warning "ACL de la clé privée resserrée : $keyPath (retiré : $($foreign -join ', '))."
        }
        return (Write-Identity $certPath $keyPath)
    }
    throw "Incomplete TLS identity in $dir; rerun with -Force to regenerate it."
}

$openssl = Resolve-OpenSsl
if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
$work = Join-Path $dir ('.tls-identity.' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work -Force | Out-Null
try {
    # The key is born in a directory only this account can open, so no inherited ACE ever covers it.
    Invoke-Native $icacls @($work, '/inheritance:r', '/grant:r', "${account}:(OI)(CI)(F)") 'icacls'
    # A minimal config file carries the subject: several Windows openssl builds point
    # at a default openssl.cnf that does not exist, which makes "req" fail.
    $configPath = Join-Path $work 'req.cnf'
    [IO.File]::WriteAllText($configPath, "[req]`ndistinguished_name = dn`nprompt = no`n[dn]`nCN = $HostName.local`nO = VoxLocal`n", (New-Object Text.UTF8Encoding($false)))
    $workKey = Join-Path $work 'server.key.pem'
    $workCert = Join-Path $work 'server.cert.pem'
    Invoke-Native $openssl @('req', '-x509', '-newkey', 'rsa:2048', '-nodes',
        '-keyout', $workKey, '-out', $workCert, '-days', '3650', '-config', $configPath,
        '-addext', "subjectAltName=DNS:$HostName.local,DNS:localhost,IP:127.0.0.1") 'openssl req'
    if (-not (Test-Path -LiteralPath $workKey -PathType Leaf) -or -not (Test-Path -LiteralPath $workCert -PathType Leaf)) {
        throw 'openssl did not produce server.key.pem and server.cert.pem.'
    }
    if ($hasKey) {
        # A previous run left the key read-only for this account; restore full control before replacing it.
        Invoke-Native $icacls @($keyPath, '/grant', "${account}:(F)") 'icacls'
        Remove-Item -LiteralPath $keyPath -Force
    }
    Move-Item -LiteralPath $workKey -Destination $keyPath -Force
    Move-Item -LiteralPath $workCert -Destination $certPath -Force
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

# Private key: drop inherited ACEs, read access for the account that runs the host only.
Invoke-Native $icacls @($keyPath, '/inheritance:r', '/grant:r', "${account}:(R)") 'icacls'

Write-Host "TLS identity created for $HostName.local."
return (Write-Identity $certPath $keyPath)
