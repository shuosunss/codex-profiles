Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Space management is shared by the scripts and the packaged desktop launcher.
. (Join-Path $PSScriptRoot 'ProfileSpace.ps1')
. (Join-Path $PSScriptRoot 'RemoveProfile.ps1')
. (Join-Path $PSScriptRoot 'ConversationSync.ps1')
. (Join-Path $PSScriptRoot 'ProfileShell.ps1')

function ConvertTo-CodexProfileKey {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProfileName
    )

    $key = $ProfileName.Trim().ToLowerInvariant()
    if (-not $key) {
        throw 'ProfileName cannot be empty.'
    }

    $key = [regex]::Replace($key, '[^a-z0-9]+', '-')
    $key = $key.Trim('-')

    if (-not $key) {
        throw "ProfileName '$ProfileName' does not contain any usable characters."
    }

    return $key
}

function Expand-CodexProfileNames {
    [CmdletBinding()]
    param(
        [string[]]$ProfileName
    )

    $expanded = foreach ($value in $ProfileName) {
        if ($null -eq $value) {
            continue
        }

        foreach ($segment in ($value -split ',')) {
            $trimmed = $segment.Trim()
            if ($trimmed) {
                $trimmed
            }
        }
    }

    if (-not $expanded) {
        throw 'At least one profile name is required.'
    }

    return $expanded
}

function Get-CodexDesktopPackage {
    [CmdletBinding()]
    param()

    $package = Get-AppxPackage OpenAI.Codex | Sort-Object Version -Descending | Select-Object -First 1
    if (-not $package) {
        throw 'OpenAI.Codex MS Store package not found. Install Codex from the Microsoft Store first.'
    }

    $appDirectory = Join-Path $package.InstallLocation 'app'
    # New unified desktop builds use ChatGPT.exe; keep Codex.exe as a fallback for older packages.
    $exePath = @('ChatGPT.exe', 'Codex.exe') |
        ForEach-Object { Join-Path $appDirectory $_ } |
        Where-Object { Test-Path $_ } |
        Select-Object -First 1
    if (-not $exePath) {
        throw "Codex desktop executable not found under: $appDirectory"
    }

    # Current packaged builds refuse to start when the exe is run directly ("no package identity"),
    # so profiles must be activated through the package's app user model id (AUMID).
    $exeLeaf = Split-Path -Path $exePath -Leaf
    $application = (Get-AppxPackageManifest -Package $package).Package.Applications.Application |
        Where-Object { (Split-Path -Path $_.Executable -Leaf) -eq $exeLeaf } |
        Select-Object -First 1
    if (-not $application) {
        throw 'No application entry found in the OpenAI.Codex package manifest.'
    }

    [pscustomobject]@{
        Package = $package
        Version = $package.Version.ToString()
        ExePath = $exePath
        ProcessName = $exeLeaf
        AppUserModelId = "$($package.PackageFamilyName)!$($application.Id)"
    }
}
function Resolve-NpxCommand {
    [CmdletBinding()]
    param()

    $command = Get-Command npx.cmd -ErrorAction SilentlyContinue
    if (-not $command) {
        $command = Get-Command npx -ErrorAction SilentlyContinue
    }

    if (-not $command) {
        throw 'Unable to find npx. Install Node.js if you want to enable the common MCP defaults.'
    }

    return $command.Source
}

function Get-CodexProfilePaths {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProfileName,

        [string]$ProfilesRoot = (Join-Path $env:LOCALAPPDATA 'CodexProfiles'),

        [string]$ParallelRoot = (Join-Path $env:LOCALAPPDATA 'CodexParallelDesktop')
    )

    $profileKey = ConvertTo-CodexProfileKey -ProfileName $ProfileName

    [pscustomobject]@{
        ProfileName = $ProfileName
        ProfileKey = $profileKey
        Home = Join-Path $ProfilesRoot $profileKey
        UiData = Join-Path (Join-Path $ParallelRoot 'ui') $profileKey
        ParallelRoot = $ParallelRoot
    }
}

function Get-CodexProfileConfigContent {
    [CmdletBinding()]
    param(
        [switch]$EnableCommonMcp
    )

    $lines = @(
        "forced_login_method = 'chatgpt'",
        "cli_auth_credentials_store = 'file'",
        "model_provider = 'openai'"
    )

    if ($EnableCommonMcp) {
        $npxPath = Resolve-NpxCommand
        $programFiles = [Environment]::GetFolderPath('ProgramFiles')
        $systemRoot = $env:SystemRoot

        $lines += @(
            '',
            '[mcp_servers.playwright]',
            "command = '$npxPath'",
            'args = ["-y", "@playwright/mcp@latest"]',
            '',
            '[mcp_servers.chrome-devtools]',
            "command = '$npxPath'",
            'args = ["-y", "chrome-devtools-mcp@latest"]',
            '',
            '[mcp_servers.chrome-devtools.env]',
            "CI = '1'",
            "CHROME_DEVTOOLS_MCP_NO_USAGE_STATISTICS = '1'",
            "PROGRAMFILES = '$programFiles'",
            "SystemRoot = '$systemRoot'",
            '',
            '[mcp_servers.context7]',
            "command = '$npxPath'",
            'args = ["-y", "@upstash/context7-mcp"]'
        )
    }

    return ($lines -join [Environment]::NewLine) + [Environment]::NewLine
}

function Write-CodexProfileConfig {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigPath,

        [switch]$EnableCommonMcp,

        [switch]$OverwriteConfig
    )

    if ((Test-Path $ConfigPath) -and (-not $OverwriteConfig)) {
        return
    }

    $content = Get-CodexProfileConfigContent -EnableCommonMcp:$EnableCommonMcp
    if ($PSCmdlet.ShouldProcess($ConfigPath, 'Write profile config')) {
        $parent = Split-Path -Path $ConfigPath -Parent
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
        [System.IO.File]::WriteAllText($ConfigPath, $content, [System.Text.UTF8Encoding]::new($false))
    }
}

function Write-CodexProfileStopScript {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [string]$StopScriptPath,

        [Parameter(Mandatory = $true)]
        [string]$ProcessName,

        [Parameter(Mandatory = $true)]
        [string]$UiData
    )

    # Base64 keeps generated no-BOM scripts compatible with non-ASCII Windows user paths in PowerShell 5.1.
    $processNameBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($ProcessName))
    $uiDataBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($UiData))
    $content = @(
        '[CmdletBinding(SupportsShouldProcess = $true)]',
        'param()',
        '',
        '$ErrorActionPreference = ''Stop''',
        '$processName = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(''' + $processNameBase64 + '''))',
        '$targetUiData = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(''' + $uiDataBase64 + '''))',
        '$profileArgument = "--user-data-dir=$targetUiData"',
        '',
        '# All profiles share the same packaged exe, so the profile-specific main process is matched',
        '# by its --user-data-dir argument; taskkill /T also terminates its Electron children.',
        '$processes = Get-CimInstance Win32_Process -Filter ("Name = ''{0}''" -f $processName.Replace("''", "''''")) |',
        '    Where-Object {',
        '        $_.CommandLine -and',
        '        ($_.CommandLine.IndexOf($profileArgument, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) -and',
        '        ($_.CommandLine.IndexOf(''--type='', [System.StringComparison]::OrdinalIgnoreCase) -lt 0)',
        '    }',
        '',
        'if (-not $processes) {',
        '    Write-Output "No running app found for profile UI data: $targetUiData"',
        '    return',
        '}',
        '',
        '$taskkill = Join-Path $env:SystemRoot ''System32\taskkill.exe''',
        'foreach ($process in $processes) {',
        '    if ($PSCmdlet.ShouldProcess("$processName (PID $($process.ProcessId))", ''Stop profile process tree'')) {',
        '        & $taskkill /PID $process.ProcessId /T /F',
        '        if (($LASTEXITCODE -ne 0) -and (Get-Process -Id $process.ProcessId -ErrorAction SilentlyContinue)) {',
        '            throw "Failed to stop $processName (PID $($process.ProcessId)); taskkill exit code: $LASTEXITCODE"',
        '        }',
        '    }',
        '}',
        ''
    ) -join [Environment]::NewLine

    if ($PSCmdlet.ShouldProcess($StopScriptPath, 'Write profile stop script')) {
        $parent = Split-Path -Path $StopScriptPath -Parent
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
        [System.IO.File]::WriteAllText($StopScriptPath, $content, [System.Text.UTF8Encoding]::new($false))
    }
}

function New-CodexDesktopProfile {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProfileName,

        [string]$DisplayName,

        [string]$SharedHome,

        [string]$ProfilesRoot = (Join-Path $env:LOCALAPPDATA 'CodexProfiles'),

        [string]$ParallelRoot = (Join-Path $env:LOCALAPPDATA 'CodexParallelDesktop'),

        [switch]$EnableCommonMcp,

        [switch]$OverwriteConfig,

        [switch]$CreateDesktopShortcut,

        [switch]$CreateStartMenuShortcut,

        [string]$LauncherScriptPath
    )

    $paths = Get-CodexProfilePaths -ProfileName $ProfileName -ProfilesRoot $ProfilesRoot -ParallelRoot $ParallelRoot
    $configuredName = Get-CodexProfileDisplayName -ProfileHome $paths.Home -Fallback $ProfileName.Trim()
    $DisplayName = if ([string]::IsNullOrWhiteSpace($DisplayName)) { $configuredName } else { $DisplayName.Trim() }
    if ($DisplayName -match '\p{Cc}') { throw 'The instance name cannot contain control characters.' }

    # Validate installation before creating profile data, including in shared mode.
    $packageInfo = Get-CodexDesktopPackage
    $sharedSpace = Initialize-CodexProfileSpace -ProfileHome $paths.Home -SharedHome $SharedHome -WhatIf:$WhatIfPreference

    if ($PSCmdlet.ShouldProcess($paths.Home, 'Create isolated profile directories')) {
        New-Item -ItemType Directory -Force -Path $paths.Home | Out-Null
        New-Item -ItemType Directory -Force -Path $paths.UiData | Out-Null
    }

    # Keep one name for the manager, taskbar, tray and side enhancer, including case and Unicode.
    $displayPath = Join-Path $paths.Home 'profile-display-name.txt'
    if ((-not [IO.File]::Exists($displayPath) -or $configuredName -cne $DisplayName) -and
        $PSCmdlet.ShouldProcess($displayPath, 'Save the display name')) {
        $temp = $displayPath + '.' + [Guid]::NewGuid().ToString('N') + '.tmp'
        [IO.File]::WriteAllText($temp, $DisplayName, [Text.UTF8Encoding]::new($false))
        if ([IO.File]::Exists($displayPath)) { [IO.File]::Replace($temp, $displayPath, [NullString]::Value) }
        else { [IO.File]::Move($temp, $displayPath) }
    }

    $configPath = Join-Path $paths.Home 'config.toml'
    if (-not $sharedSpace) {
        Write-CodexProfileConfig -ConfigPath $configPath -EnableCommonMcp:$EnableCommonMcp -OverwriteConfig:$OverwriteConfig -WhatIf:$WhatIfPreference
    }
    if (-not $sharedSpace -and $PSCmdlet.ShouldProcess($configPath, 'Follow the default Windows sandbox settings')) {
        # Sync only Windows sandbox keys and keep profile-specific settings intact.
        try {
            & (Join-Path $PSScriptRoot 'Sync-WindowsSandbox.ps1') -ProfileHome $paths.Home
        }
        catch {
            Write-Warning ('Windows sandbox configuration was left unchanged: ' + $_.Exception.Message)
        }
    }

    $stopScriptPath = Join-Path $paths.Home 'Stop-CodexDesktopProfile.ps1'
    Write-CodexProfileStopScript -StopScriptPath $stopScriptPath -ProcessName $packageInfo.ProcessName -UiData $paths.UiData -WhatIf:$WhatIfPreference
    $trayScriptPath = Join-Path $paths.Home 'Show-CodexDesktopProfileTray.ps1'
    Write-CodexProfileTrayScript -TrayScriptPath $trayScriptPath -ProfileHome $paths.Home -UiData $paths.UiData -WhatIf:$WhatIfPreference

    if ($LauncherScriptPath) {
        $launcherFullPath = (Resolve-Path $LauncherScriptPath).Path
        $shortcutName = if ($DisplayName.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0 -or $DisplayName.EndsWith('.')) {
            $paths.ProfileKey
        } else { $DisplayName }
        if ($CreateDesktopShortcut) {
            $desktopShortcut = Join-Path ([Environment]::GetFolderPath('DesktopDirectory')) ("$shortcutName.lnk")
            New-CodexDesktopShortcut -ShortcutPath $desktopShortcut -LauncherScriptPath $launcherFullPath -ProfileHome $paths.Home -UiData $paths.UiData -WhatIf:$WhatIfPreference
        }

        if ($CreateStartMenuShortcut) {
            $startMenuDirectory = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Codex Profiles'
            $startMenuShortcut = Join-Path $startMenuDirectory ("$shortcutName.lnk")
            New-CodexDesktopShortcut -ShortcutPath $startMenuShortcut -LauncherScriptPath $launcherFullPath -ProfileHome $paths.Home -UiData $paths.UiData -WhatIf:$WhatIfPreference
        }
    }

    [pscustomobject]@{
        ProfileName = $ProfileName
        DisplayName = $DisplayName
        ProfileKey = $paths.ProfileKey
        Home = $paths.Home
        UiData = $paths.UiData
        ConfigPath = $configPath
        ExePath = $packageInfo.ExePath
        AppUserModelId = $packageInfo.AppUserModelId
        StopScriptPath = $stopScriptPath
        TrayScriptPath = $trayScriptPath
        SharedHome = $sharedSpace
    }
}

function Add-CodexProfileActivatorType {
    [CmdletBinding()]
    param()

    # Add-Type fails when the type already exists in the session; skip if loaded.
    if ('CodexProfileActivator' -as [type]) {
        return
    }

    # Double-quoted here-string is safe: the C# source contains no PowerShell variables.
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class CodexProfileActivator {
    [ComImport, Guid("2e941141-7f97-4756-ba1d-9decde894a3d"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IApplicationActivationManager {
        [PreserveSig] int ActivateApplication([MarshalAs(UnmanagedType.LPWStr)] string appUserModelId, [MarshalAs(UnmanagedType.LPWStr)] string arguments, int options, out int processId);
        [PreserveSig] int ActivateForFile(string appUserModelId, IntPtr itemArray, string verb, out int processId);
        [PreserveSig] int ActivateForProtocol(string appUserModelId, IntPtr itemArray, out int processId);
    }
    [ComImport, Guid("45BA127D-10A8-46EA-8AB7-56EA9078943C")]
    private class ApplicationActivationManager { }
    public static int Activate(string appUserModelId, string arguments) {
        var manager = (IApplicationActivationManager)new ApplicationActivationManager();
        int processId;
        int hr = manager.ActivateApplication(appUserModelId, arguments, 0, out processId);
        if (hr != 0) { Marshal.ThrowExceptionForHR(hr); }
        return processId;
    }
}
"@
}

function Invoke-CodexDesktopLaunch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$AppUserModelId,

        [Parameter(Mandatory = $true)]
        [string]$ProfileHome,

        [Parameter(Mandatory = $true)]
        [string]$UiData,

        [string[]]$AdditionalArguments,

        [switch]$DefaultInstance,

        [switch]$PassThru
    )

    Add-CodexProfileActivatorType

    # The enhancer uses the same per-instance loopback channel as codex-sidebar-usage.
    $arguments = @('--remote-debugging-port=0', '--remote-debugging-address=127.0.0.1')
    if (-not $DefaultInstance) {
        $arguments += '"' + "--user-data-dir=$UiData" + '"'
    }
    if ($AdditionalArguments) {
        $arguments += $AdditionalArguments
    }
    $argumentLine = $arguments -join ' '

    # The packaged build refuses a direct exe launch ("no package identity"), so activation goes
    # through the app user model id. Packaged activation inherits user-level env vars rather than
    # this process' env, so CODEX_HOME is published there only for the activation call itself,
    # with inherited proxy/API vars scrubbed the same way. Values are written straight to the
    # registry: SetEnvironmentVariable broadcasts WM_SETTINGCHANGE to every top-level window and
    # can stall for minutes behind a busy app window. The mutex keeps parallel launches apart.
    $mutex = [System.Threading.Mutex]::new($false, 'Local\CodexProfilesActivate')
    $mutex.WaitOne() | Out-Null
    $envKey = 'HKCU:\Environment'
    $scrubNames = @('OPENAI_BASE_URL','OPENAI_API_KEY','OPENAI_ORG_ID','OPENAI_PROJECT_ID','ANTHROPIC_BASE_URL','ANTHROPIC_API_KEY','ANTHROPIC_AUTH_TOKEN','CODEX_THREAD_ID','CODEX_HOME','CODEX_SQLITE_HOME')
    $savedUserEnv = @{}
    foreach ($name in $scrubNames) {
        $savedUserEnv[$name] = [Environment]::GetEnvironmentVariable($name, 'User')
    }
    try {
        # An instance may have been removed after preparation but before activation acquired the lock.
        if (-not $DefaultInstance -and (-not [IO.Directory]::Exists($ProfileHome) -or -not [IO.Directory]::Exists($UiData))) {
            throw 'The profile was removed before it could start.'
        }
        foreach ($name in $scrubNames) {
            Remove-ItemProperty -Path $envKey -Name $name -ErrorAction SilentlyContinue
        }
        Set-ItemProperty -Path $envKey -Name 'CODEX_HOME' -Value $ProfileHome
        $processId = [CodexProfileActivator]::Activate($AppUserModelId, $argumentLine)
    }
    finally {
        foreach ($name in $scrubNames) {
            if ($null -eq $savedUserEnv[$name]) {
                Remove-ItemProperty -Path $envKey -Name $name -ErrorAction SilentlyContinue
            }
            else {
                Set-ItemProperty -Path $envKey -Name $name -Value $savedUserEnv[$name]
            }
        }
        $mutex.ReleaseMutex()
        $mutex.Dispose()
    }

    if ($PassThru) {
        return Get-Process -Id $processId -ErrorAction SilentlyContinue
    }
}
function Start-CodexDesktopProfile {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProfileName,

        [string]$DisplayName,

        [string]$SharedHome,

        [string]$ProfilesRoot = (Join-Path $env:LOCALAPPDATA 'CodexProfiles'),

        [string]$ParallelRoot = (Join-Path $env:LOCALAPPDATA 'CodexParallelDesktop'),

        [switch]$EnableCommonMcp,

        [switch]$OverwriteConfig,

        [string[]]$AdditionalArguments,

        [switch]$NoTrayIcon,

        [switch]$PassThru
    )

    $profile = New-CodexDesktopProfile -ProfileName $ProfileName -DisplayName $DisplayName -SharedHome $SharedHome -ProfilesRoot $ProfilesRoot -ParallelRoot $ParallelRoot -EnableCommonMcp:$EnableCommonMcp -OverwriteConfig:$OverwriteConfig -WhatIf:$WhatIfPreference

    if ($PSCmdlet.ShouldProcess($profile.DisplayName, 'Launch isolated Codex desktop profile')) {
        $process = Invoke-CodexDesktopLaunch -AppUserModelId $profile.AppUserModelId -ProfileHome $profile.Home -UiData $profile.UiData -AdditionalArguments $AdditionalArguments -PassThru
        Start-CodexConversationSync -ProcessId $process.Id -UiDirectories @($profile.UiData) `
            -StatusPath (Join-Path $profile.Home 'conversation-sync.json') -ProfileHome $profile.Home -ProfilesRoot $ProfilesRoot
        if (-not $NoTrayIcon) {
            Start-CodexProfileShell -ProcessId $process.Id -ProfileHome $profile.Home -UiData $profile.UiData
        }
        if ($PassThru) {
            return [pscustomobject]@{
                ProfileName = $profile.ProfileName
                DisplayName = $profile.DisplayName
                Home = $profile.Home
                UiData = $profile.UiData
                AppUserModelId = $profile.AppUserModelId
                StopScriptPath = $profile.StopScriptPath
                TrayScriptPath = $profile.TrayScriptPath
                Process = $process
            }
        }
    }

    return $profile
}

function Install-CodexDesktopProfiles {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [string[]]$ProfileName = @('alpha', 'bloom', 'apex', 'prime', 'flow', 'turbo', 'sonic', 'nova'),

        [switch]$EnableCommonMcp,

        [switch]$OverwriteConfig,

        [switch]$CreateDesktopShortcuts,

        [switch]$CreateStartMenuShortcuts,

        [string]$LauncherScriptPath
    )

    $profileNames = Expand-CodexProfileNames -ProfileName $ProfileName

    $results = foreach ($name in $profileNames) {
        $displayName = 'Codex ' + (Get-Culture).TextInfo.ToTitleCase((ConvertTo-CodexProfileKey -ProfileName $name))
        New-CodexDesktopProfile -ProfileName $name -DisplayName $displayName -EnableCommonMcp:$EnableCommonMcp -OverwriteConfig:$OverwriteConfig -CreateDesktopShortcut:$CreateDesktopShortcuts -CreateStartMenuShortcut:$CreateStartMenuShortcuts -LauncherScriptPath $LauncherScriptPath -WhatIf:$WhatIfPreference
    }

    return $results
}

Export-ModuleMember -Function Get-CodexProfilePaths, Get-CodexDesktopProfiles, New-CodexDesktopProfile, Start-CodexDesktopProfile, Start-CodexDefaultInstance, Remove-CodexDesktopProfile, Install-CodexDesktopProfiles
