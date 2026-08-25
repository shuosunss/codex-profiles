[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string[]]$ProfileName = @('alpha', 'bloom', 'apex', 'prime', 'flow', 'turbo', 'sonic', 'nova'),

    [switch]$EnableCommonMcp,

    [switch]$OverwriteConfig,

    [switch]$CreateDesktopShortcuts,

    [switch]$CreateStartMenuShortcuts,

    [switch]$ForceRefreshClone
)

$ErrorActionPreference = 'Stop'
$modulePath = Join-Path $PSScriptRoot '..\..\src\CodexProfiles\CodexProfiles.psd1'
Import-Module (Resolve-Path $modulePath) -Force

$launcherScriptPath = Join-Path $PSScriptRoot 'Start-CodexDesktopProfile.ps1'
Install-CodexDesktopProfiles @PSBoundParameters -LauncherScriptPath $launcherScriptPath
