function Start-CodexConversationSync {
    param(
        [int]$ProcessId,
        [string[]]$UiDirectories,
        [string]$StatusPath,
        [string]$ProfileHome,
        [string]$ProfilesRoot
    )

    $helper = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../bin/ConversationSync.exe'))
    $manifest = Join-Path (Split-Path -Parent $helper) 'ConversationSync.current'
    if ([IO.File]::Exists($manifest)) {
        $helperName = [IO.File]::ReadAllText($manifest, [Text.Encoding]::UTF8).Trim()
        if ($helperName -notmatch '^ConversationSync-[a-f0-9]{16}\.exe$') {
            throw 'The background enhancer build manifest is invalid.'
        }
        $helper = Join-Path (Split-Path -Parent $helper) $helperName
    }
    if (-not [IO.File]::Exists($helper)) {
        throw 'Build the EXE first. The background conversation enhancer is missing.'
    }
    # Base64 arguments preserve spaces, quotes, and non-ASCII profile paths without shell evaluation.
    $uiArgument = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($UiDirectories -join [char]0)))
    $statusArgument = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($StatusPath))
    $homeArgument = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([IO.Path]::GetFullPath($ProfileHome)))
    $profilesArgument = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([IO.Path]::GetFullPath($ProfilesRoot)))
    $arguments = '--attach {0} {1} {2} {3} {4}' -f $ProcessId, $uiArgument, $statusArgument, $homeArgument, $profilesArgument
    Start-Process -FilePath $helper -ArgumentList $arguments -WindowStyle Hidden | Out-Null
}

function Start-CodexDefaultInstance {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([string]$ProfilesRoot = (Join-Path $env:LOCALAPPDATA 'CodexProfiles'))

    $package = Get-CodexDesktopPackage
    $defaultHome = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex'
    # MSIX may virtualize the default roaming data directory. Check both physical locations.
    $uiDirectories = @(
        (Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'Codex'),
        (Join-Path $env:LOCALAPPDATA ('Packages/' + $package.Package.PackageFamilyName + '/LocalCache/Roaming/Codex'))
    )
    $explicitUi = [Environment]::GetEnvironmentVariable('CODEX_ELECTRON_USER_DATA_PATH', 'User')
    if ($explicitUi) { $uiDirectories = @($explicitUi) + $uiDirectories }
    $statusPath = Join-Path $env:LOCALAPPDATA 'CodexProfilesLauncher/default/conversation-sync.json'
    if ($PSCmdlet.ShouldProcess('Default ChatGPT instance', 'Launch with automatic background conversation refresh')) {
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $statusPath))
        $process = Invoke-CodexDesktopLaunch -AppUserModelId $package.AppUserModelId `
            -ProfileHome $defaultHome -UiData $uiDirectories[0] -DefaultInstance -PassThru
        # The default status file lives outside its Codex home, so pass the real project data directory separately.
        Start-CodexConversationSync -ProcessId $process.Id -UiDirectories $uiDirectories -StatusPath $statusPath `
            -ProfileHome $defaultHome -ProfilesRoot $ProfilesRoot
    }
}
