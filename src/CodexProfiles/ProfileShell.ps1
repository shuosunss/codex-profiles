function Get-CodexProfileDisplayName {
    param([string]$ProfileHome, [string]$Fallback)

    $path = Join-Path $ProfileHome 'profile-display-name.txt'
    if ([IO.File]::Exists($path)) {
        $name = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8).Trim()
        if ($name -and $name -notmatch '\p{Cc}') { return $name }
    }
    return $Fallback
}

function Get-CodexProfileShell {
    $bin = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../bin'))
    $name = 'ProfileShell.exe'
    $manifest = Join-Path $bin 'ProfileShell.current'
    if ([IO.File]::Exists($manifest)) {
        $name = [IO.File]::ReadAllText($manifest, [Text.Encoding]::UTF8).Trim()
        if ($name -notmatch '^ProfileShell-[a-f0-9]{16}\.exe$') { throw 'The Windows shell helper manifest is invalid.' }
    }
    $helper = Join-Path $bin $name
    if (-not [IO.File]::Exists($helper)) { throw 'Build the EXE first. The Windows shell helper is missing.' }
    return $helper
}

function Start-CodexProfileShell {
    param([int]$ProcessId, [string]$ProfileHome, [string]$UiData)

    $home = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($ProfileHome))
    $ui = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($UiData))
    $arguments = '--attach-managed {0} {1} {2}' -f $ProcessId, $home, $ui
    Start-Process -FilePath (Get-CodexProfileShell) -ArgumentList $arguments -WindowStyle Hidden | Out-Null
}

function Write-CodexProfileTrayScript {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([string]$TrayScriptPath, [string]$ProfileHome, [string]$UiData)

    if (-not $PSCmdlet.ShouldProcess($TrayScriptPath, 'Write profile tray entry')) { return }
    # Keep the previously generated entry point usable while routing it to the common tray.
    $module = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((Join-Path $PSScriptRoot 'CodexProfiles.psd1')))
    $home = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($ProfileHome))
    $ui = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($UiData))
    $source = @(
        '$ErrorActionPreference = ''Stop''',
        '$encoding = [Text.Encoding]::UTF8',
        ('$module = $encoding.GetString([Convert]::FromBase64String(''{0}''))' -f $module),
        ('$home = $encoding.GetString([Convert]::FromBase64String(''{0}''))' -f $home),
        ('$ui = $encoding.GetString([Convert]::FromBase64String(''{0}''))' -f $ui),
        'Import-Module $module -Force',
        '& (Get-Module CodexProfiles) {',
        '    param($profileHome, $uiData)',
        '    Start-CodexProfileShell -ProcessId 0 -ProfileHome $profileHome -UiData $uiData',
        '} $home $ui', '') -join [Environment]::NewLine
    [IO.File]::WriteAllText($TrayScriptPath, $source, [Text.UTF8Encoding]::new($false))
}

function New-CodexDesktopShortcut {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([string]$ShortcutPath, [string]$LauncherScriptPath, [string]$ProfileHome, [string]$UiData)

    if (-not $PSCmdlet.ShouldProcess($ShortcutPath, 'Create shortcut')) { return }
    # The common helper sets the same official theme icon and AppUserModelID on both kinds of shortcuts.
    $encoded = foreach ($value in @($ProfileHome, $UiData, $ShortcutPath, $LauncherScriptPath)) {
        [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($value))
    }
    $process = Start-Process -FilePath (Get-CodexProfileShell) -ArgumentList ('--shortcut-managed ' + ($encoded -join ' ')) `
        -WindowStyle Hidden -Wait -PassThru
    if ($process.ExitCode -ne 0) { throw "Could not create the profile shortcut: $ShortcutPath" }
}
