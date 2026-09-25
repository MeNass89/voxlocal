<#
Configure the minimum inbound rule for a Remote Scribe pilot host.

Run from an elevated PowerShell prompt and provide the clinical VLAN(s):

  .\install-firewall-rule.ps1 -ProgramPath C:\VoxLocal\python.exe `
      -RemoteAddress 10.42.0.0/16

The rule is deliberately restricted to the Private profile.  No rule is
created for Public networks, and omitting -RemoteAddress aborts rather than
opening the service to every local subnet.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string] $ProgramPath,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string[]] $RemoteAddress,

    [ValidateRange(1, 65535)]
    [int] $Port = 47365,

    [string] $RuleName = 'Remote Scribe host (Private clinical VLAN)'
)

$ErrorActionPreference = 'Stop'

if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this script from an elevated PowerShell prompt.'
}

$existing = Get-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue
if ($existing) {
    if ($PSCmdlet.ShouldProcess($RuleName, 'replace existing firewall rule')) {
        $existing | Remove-NetFirewallRule
    }
}

if ($PSCmdlet.ShouldProcess($RuleName, "allow TCP $Port from the supplied clinical VLANs")) {
    New-NetFirewallRule `
        -DisplayName $RuleName `
        -Description 'Remote Scribe v1 compatibility listener; Private profile only.' `
        -Direction Inbound `
        -Action Allow `
        -Enabled True `
        -Profile Private `
        -Protocol TCP `
        -LocalPort $Port `
        -RemoteAddress $RemoteAddress `
        -Program $ProgramPath `
        -EdgeTraversalPolicy Block
}

