[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [string]$ProfileName,

    [string]$DisplayName,

    [switch]$EnableCommonMcp,

    [switch]$OverwriteConfig,

    [switch]$CreateDesktopShortcut,

    [switch]$CreateStartMenuShortcut,

    [switch]$ForceRefreshClone
)

$ErrorActionPreference = 'Stop'
$modulePath = Join-Path $PSScriptRoot '..\..\src\CodexProfiles\CodexProfiles.psd1'
Import-Module (Resolve-Path $modulePath) -Force

$launcherScriptPath = Join-Path $PSScriptRoot 'Start-CodexDesktopProfile.ps1'
New-CodexDesktopProfile @PSBoundParameters -LauncherScriptPath $launcherScriptPath
