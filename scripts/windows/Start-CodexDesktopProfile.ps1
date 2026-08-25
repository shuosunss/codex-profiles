[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [string]$ProfileName,

    [string]$DisplayName,

    [switch]$EnableCommonMcp,

    [switch]$OverwriteConfig,

    [switch]$ForceRefreshClone,

    [string[]]$AdditionalArguments,

    [switch]$NoTrayIcon,

    [switch]$PassThru
)

$ErrorActionPreference = 'Stop'
$modulePath = Join-Path $PSScriptRoot '..\..\src\CodexProfiles\CodexProfiles.psd1'
Import-Module (Resolve-Path $modulePath) -Force

Start-CodexDesktopProfile @PSBoundParameters
