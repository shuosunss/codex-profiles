Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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
        "model_provider = 'openai'",
        '',
        '[windows]',
        'sandbox = "elevated"'
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
        Set-Content -Path $ConfigPath -Value $content -Encoding UTF8
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

function Write-CodexProfileTrayScript {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [string]$TrayScriptPath,

        [Parameter(Mandatory = $true)]
        [string]$StopScriptPath,

        [Parameter(Mandatory = $true)]
        [string]$AppUserModelId,

        [Parameter(Mandatory = $true)]
        [string]$ProcessName,

        [Parameter(Mandatory = $true)]
        [string]$ExePath,

        [Parameter(Mandatory = $true)]
        [string]$ProfileHome,

        [Parameter(Mandatory = $true)]
        [string]$UiData,

        [Parameter(Mandatory = $true)]
        [string]$ProfileKey
    )

    # Encode paths so the generated script remains ASCII-only and works in Windows PowerShell 5.1.
    $appUserModelIdBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($AppUserModelId))
    $processNameBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($ProcessName))
    $exePathBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($ExePath))
    $profileHomeBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($ProfileHome))
    $uiDataBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($UiData))
    $stopScriptBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($StopScriptPath))
    $escapedProfileKey = $ProfileKey.Replace("'", "''")

    $content = @(
        '[CmdletBinding()]',
        'param()',
        '',
        '$ErrorActionPreference = ''Stop''',
        'Add-Type -AssemblyName System.Windows.Forms',
        'Add-Type -AssemblyName System.Drawing',
        "Add-Type -TypeDefinition @'",
        'using System;',
        'using System.Runtime.InteropServices;',
        'public static class CodexProfilesWindow {',
        '    [DllImport("user32.dll")]',
        '    public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);',
        '    [DllImport("user32.dll")]',
        '    public static extern bool SetForegroundWindow(IntPtr hWnd);',
        '}',
        "'@",
        '',
        "Add-Type -TypeDefinition @'",
        'using System;',
        'using System.Runtime.InteropServices;',
        'public static class CodexProfileActivator {',
        '    [ComImport, Guid("2e941141-7f97-4756-ba1d-9decde894a3d"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]',
        '    private interface IApplicationActivationManager {',
        '        [PreserveSig] int ActivateApplication([MarshalAs(UnmanagedType.LPWStr)] string appUserModelId, [MarshalAs(UnmanagedType.LPWStr)] string arguments, int options, out int processId);',
        '        [PreserveSig] int ActivateForFile(string appUserModelId, IntPtr itemArray, string verb, out int processId);',
        '        [PreserveSig] int ActivateForProtocol(string appUserModelId, IntPtr itemArray, out int processId);',
        '    }',
        '    [ComImport, Guid("45BA127D-10A8-46EA-8AB7-56EA9078943C")]',
        '    private class ApplicationActivationManager { }',
        '    public static int Activate(string appUserModelId, string arguments) {',
        '        var manager = (IApplicationActivationManager)new ApplicationActivationManager();',
        '        int processId;',
        '        int hr = manager.ActivateApplication(appUserModelId, arguments, 0, out processId);',
        '        if (hr != 0) { Marshal.ThrowExceptionForHR(hr); }',
        '        return processId;',
        '    }',
        '}',
        "'@",
        '',
        '$appUserModelId = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(''' + $appUserModelIdBase64 + '''))',
        '$processName = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(''' + $processNameBase64 + '''))',
        '$targetExe = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(''' + $exePathBase64 + '''))',
        '$profileHome = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(''' + $profileHomeBase64 + '''))',
        '$targetUiData = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(''' + $uiDataBase64 + '''))',
        '$stopScriptPath = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(''' + $stopScriptBase64 + '''))',
        "`$profileKey = '$escapedProfileKey'",
        '$profileArgument = "--user-data-dir=$targetUiData"',
        '',
        'function Get-ProfileProcesses {',
        '    return @(Get-CimInstance Win32_Process -Filter ("Name = ''{0}''" -f $processName.Replace("''", "''''")) |',
        '        Where-Object {',
        '            $_.CommandLine -and',
        '            ($_.CommandLine.IndexOf($profileArgument, [System.StringComparison]::OrdinalIgnoreCase) -ge 0)',
        '        })',
        '}',
        '',
        'function Start-ProfileApp {',
        '    # The packaged build refuses a direct exe launch ("no package identity"), so activation goes',
        '    # through the app user model id. Packaged activation inherits user-level env vars rather than',
        '    # this process'' env, so CODEX_HOME is published there only for the activation call itself,',
        '    # with inherited proxy/API vars scrubbed the same way. Values are written straight to the',
        '    # registry: SetEnvironmentVariable broadcasts WM_SETTINGCHANGE to every top-level window and',
        '    # can stall for minutes behind a busy app window. The mutex keeps parallel launches apart.',
        '    $mutex = [System.Threading.Mutex]::new($false, ''Local\CodexProfilesActivate'')',
        '    $mutex.WaitOne() | Out-Null',
        '    $envKey = ''HKCU:\Environment''',
        '    $scrubNames = @(''OPENAI_BASE_URL'',''OPENAI_API_KEY'',''OPENAI_ORG_ID'',''OPENAI_PROJECT_ID'',''ANTHROPIC_BASE_URL'',''ANTHROPIC_API_KEY'',''ANTHROPIC_AUTH_TOKEN'',''CODEX_THREAD_ID'',''CODEX_HOME'')',
        '    $savedUserEnv = @{}',
        '    foreach ($name in $scrubNames) {',
        '        $savedUserEnv[$name] = [Environment]::GetEnvironmentVariable($name, ''User'')',
        '    }',
        '    try {',
        '        foreach ($name in $scrubNames) {',
        '            Remove-ItemProperty -Path $envKey -Name $name -ErrorAction SilentlyContinue',
        '        }',
        '        Set-ItemProperty -Path $envKey -Name ''CODEX_HOME'' -Value $profileHome',
        '        [CodexProfileActivator]::Activate($appUserModelId, "--user-data-dir=$targetUiData") | Out-Null',
        '    }',
        '    finally {',
        '        foreach ($name in $scrubNames) {',
        '            if ($null -eq $savedUserEnv[$name]) {',
        '                Remove-ItemProperty -Path $envKey -Name $name -ErrorAction SilentlyContinue',
        '            }',
        '            else {',
        '                Set-ItemProperty -Path $envKey -Name $name -Value $savedUserEnv[$name]',
        '            }',
        '        }',
        '        $mutex.ReleaseMutex()',
        '        $mutex.Dispose()',
        '    }',
        '}',
        '',
        'function Show-ProfileWindow {',
        '    $shown = $false',
        '    foreach ($processInfo in (Get-ProfileProcesses)) {',
        '        $process = Get-Process -Id $processInfo.ProcessId -ErrorAction SilentlyContinue',
        '        if ($process -and ($process.MainWindowHandle -ne [IntPtr]::Zero)) {',
        '            [void][CodexProfilesWindow]::ShowWindowAsync($process.MainWindowHandle, 9)',
        '            [void][CodexProfilesWindow]::SetForegroundWindow($process.MainWindowHandle)',
        '            $shown = $true',
        '        }',
        '    }',
        '    if (-not $shown) {',
        '        # Starting the same isolated Electron instance either launches it or asks it to show its window.',
        '        Start-ProfileApp',
        '    }',
        '}',
        '',
        'function Hide-ProfileWindow {',
        '    $hidden = $false',
        '    foreach ($processInfo in (Get-ProfileProcesses)) {',
        '        $process = Get-Process -Id $processInfo.ProcessId -ErrorAction SilentlyContinue',
        '        if ($process -and ($process.MainWindowHandle -ne [IntPtr]::Zero)) {',
        '            [void][CodexProfilesWindow]::ShowWindowAsync($process.MainWindowHandle, 0)',
        '            $hidden = $true',
        '        }',
        '    }',
        '    return $hidden',
        '}',
        '',
        '$createdNew = $false',
        '$mutex = [System.Threading.Mutex]::new($true, "Local\CodexProfiles.Tray.$profileKey", [ref]$createdNew)',
        'if (-not $createdNew) {',
        '    $mutex.Dispose()',
        '    return',
        '}',
        '',
        '$context = [System.Windows.Forms.ApplicationContext]::new()',
        '$notifyIcon = [System.Windows.Forms.NotifyIcon]::new()',
        '$menu = [System.Windows.Forms.ContextMenuStrip]::new()',
        '$icon = [System.Drawing.Icon]::ExtractAssociatedIcon($targetExe)',
        '$notifyIcon.Icon = if ($icon) { $icon } else { [System.Drawing.SystemIcons]::Application }',
        '$notifyIcon.Text = "Codex $profileKey"',
        '',
        '$showItem = $menu.Items.Add(''Show window'')',
        '$hideItem = $menu.Items.Add(''Hide window'')',
        '[void]$menu.Items.Add([System.Windows.Forms.ToolStripSeparator]::new())',
        '$exitItem = $menu.Items.Add(''Exit'')',
        '',
        '$showAction = {',
        '    try { Show-ProfileWindow }',
        '    catch { [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Codex $profileKey") }',
        '}',
        '$showItem.add_Click($showAction)',
        '$notifyIcon.add_DoubleClick($showAction)',
        '$hideItem.add_Click({',
        '    try {',
        '        if (-not (Hide-ProfileWindow)) {',
        '            $notifyIcon.ShowBalloonTip(2000, "Codex $profileKey", ''No visible profile window was found.'', [System.Windows.Forms.ToolTipIcon]::Info)',
        '        }',
        '    }',
        '    catch { [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Codex $profileKey") }',
        '})',
        '$exitItem.add_Click({',
        '    try {',
        '        & $stopScriptPath -Confirm:$false',
        '        $notifyIcon.Visible = $false',
        '        $context.ExitThread()',
        '    }',
        '    catch { [void][System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Codex $profileKey") }',
        '})',
        '',
        '$notifyIcon.ContextMenuStrip = $menu',
        '$notifyIcon.Visible = $true',
        'try {',
        '    [System.Windows.Forms.Application]::Run($context)',
        '}',
        'finally {',
        '    $notifyIcon.Visible = $false',
        '    $notifyIcon.Dispose()',
        '    $menu.Dispose()',
        '    $context.Dispose()',
        '    if ($icon) { $icon.Dispose() }',
        '    $mutex.ReleaseMutex()',
        '    $mutex.Dispose()',
        '}',
        ''
    ) -join [Environment]::NewLine

    if ($PSCmdlet.ShouldProcess($TrayScriptPath, 'Write profile tray script')) {
        $parent = Split-Path -Path $TrayScriptPath -Parent
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
        [System.IO.File]::WriteAllText($TrayScriptPath, $content, [System.Text.UTF8Encoding]::new($false))
    }
}

function Start-CodexProfileTray {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [string]$TrayScriptPath
    )

    if (-not (Test-Path $TrayScriptPath)) {
        throw "Profile tray script not found: $TrayScriptPath"
    }

    $powerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $TrayScriptPath
    if ($PSCmdlet.ShouldProcess($TrayScriptPath, 'Start profile tray controller')) {
        Start-Process -FilePath $powerShellExe -ArgumentList $arguments -WindowStyle Hidden | Out-Null
    }
}

function New-CodexDesktopShortcut {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ShortcutPath,

        [Parameter(Mandatory = $true)]
        [string]$LauncherScriptPath,

        [Parameter(Mandatory = $true)]
        [string]$ProfileName,

        [Parameter(Mandatory = $true)]
        [string]$DisplayName,

        [string]$IconPath
    )

    $targetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -ProfileName "{1}" -DisplayName "{2}"' -f $LauncherScriptPath, $ProfileName, $DisplayName

    if ($PSCmdlet.ShouldProcess($ShortcutPath, 'Create shortcut')) {
        $shortcutDirectory = Split-Path -Path $ShortcutPath -Parent
        New-Item -ItemType Directory -Force -Path $shortcutDirectory | Out-Null

        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($ShortcutPath)
        $shortcut.TargetPath = $targetPath
        $shortcut.Arguments = $arguments
        $shortcut.WorkingDirectory = Split-Path -Path $LauncherScriptPath -Parent
        $shortcut.WindowStyle = 1
        $shortcut.Description = $DisplayName
        if ($IconPath) {
            $shortcut.IconLocation = $IconPath
        }
        $shortcut.Save()
    }
}

function New-CodexDesktopProfile {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProfileName,

        [string]$DisplayName,

        [string]$ProfilesRoot = (Join-Path $env:LOCALAPPDATA 'CodexProfiles'),

        [string]$ParallelRoot = (Join-Path $env:LOCALAPPDATA 'CodexParallelDesktop'),

        [switch]$EnableCommonMcp,

        [switch]$OverwriteConfig,

        [switch]$CreateDesktopShortcut,

        [switch]$CreateStartMenuShortcut,

        [string]$LauncherScriptPath
    )

    $paths = Get-CodexProfilePaths -ProfileName $ProfileName -ProfilesRoot $ProfilesRoot -ParallelRoot $ParallelRoot
    if (-not $DisplayName) {
        $DisplayName = 'Codex ' + (Get-Culture).TextInfo.ToTitleCase($paths.ProfileKey)
    }

    if ($PSCmdlet.ShouldProcess($paths.Home, 'Create isolated profile directories')) {
        New-Item -ItemType Directory -Force -Path $paths.Home | Out-Null
        New-Item -ItemType Directory -Force -Path $paths.UiData | Out-Null
    }

    $configPath = Join-Path $paths.Home 'config.toml'
    Write-CodexProfileConfig -ConfigPath $configPath -EnableCommonMcp:$EnableCommonMcp -OverwriteConfig:$OverwriteConfig -WhatIf:$WhatIfPreference

    $packageInfo = Get-CodexDesktopPackage
    $stopScriptPath = Join-Path $paths.Home 'Stop-CodexDesktopProfile.ps1'
    Write-CodexProfileStopScript -StopScriptPath $stopScriptPath -ProcessName $packageInfo.ProcessName -UiData $paths.UiData -WhatIf:$WhatIfPreference
    $trayScriptPath = Join-Path $paths.Home 'Show-CodexDesktopProfileTray.ps1'
    Write-CodexProfileTrayScript -TrayScriptPath $trayScriptPath -StopScriptPath $stopScriptPath -AppUserModelId $packageInfo.AppUserModelId -ProcessName $packageInfo.ProcessName -ExePath $packageInfo.ExePath -ProfileHome $paths.Home -UiData $paths.UiData -ProfileKey $paths.ProfileKey -WhatIf:$WhatIfPreference

    if ($LauncherScriptPath) {
        $launcherFullPath = (Resolve-Path $LauncherScriptPath).Path
        if ($CreateDesktopShortcut) {
            $desktopShortcut = Join-Path ([Environment]::GetFolderPath('Desktop')) ("$DisplayName.lnk")
            New-CodexDesktopShortcut -ShortcutPath $desktopShortcut -LauncherScriptPath $launcherFullPath -ProfileName $ProfileName -DisplayName $DisplayName -IconPath $packageInfo.ExePath -WhatIf:$WhatIfPreference
        }

        if ($CreateStartMenuShortcut) {
            $startMenuDirectory = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Codex Profiles'
            $startMenuShortcut = Join-Path $startMenuDirectory ("$DisplayName.lnk")
            New-CodexDesktopShortcut -ShortcutPath $startMenuShortcut -LauncherScriptPath $launcherFullPath -ProfileName $ProfileName -DisplayName $DisplayName -IconPath $packageInfo.ExePath -WhatIf:$WhatIfPreference
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

        [switch]$PassThru
    )

    Add-CodexProfileActivatorType

    $arguments = @("--user-data-dir=$UiData")
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
    $scrubNames = @('OPENAI_BASE_URL','OPENAI_API_KEY','OPENAI_ORG_ID','OPENAI_PROJECT_ID','ANTHROPIC_BASE_URL','ANTHROPIC_API_KEY','ANTHROPIC_AUTH_TOKEN','CODEX_THREAD_ID','CODEX_HOME')
    $savedUserEnv = @{}
    foreach ($name in $scrubNames) {
        $savedUserEnv[$name] = [Environment]::GetEnvironmentVariable($name, 'User')
    }
    try {
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

        [string]$ProfilesRoot = (Join-Path $env:LOCALAPPDATA 'CodexProfiles'),

        [string]$ParallelRoot = (Join-Path $env:LOCALAPPDATA 'CodexParallelDesktop'),

        [switch]$EnableCommonMcp,

        [switch]$OverwriteConfig,

        [string[]]$AdditionalArguments,

        [switch]$NoTrayIcon,

        [switch]$PassThru
    )

    $profile = New-CodexDesktopProfile -ProfileName $ProfileName -DisplayName $DisplayName -ProfilesRoot $ProfilesRoot -ParallelRoot $ParallelRoot -EnableCommonMcp:$EnableCommonMcp -OverwriteConfig:$OverwriteConfig -WhatIf:$WhatIfPreference

    if ($PSCmdlet.ShouldProcess($profile.DisplayName, 'Launch isolated Codex desktop profile')) {
        $process = Invoke-CodexDesktopLaunch -AppUserModelId $profile.AppUserModelId -ProfileHome $profile.Home -UiData $profile.UiData -AdditionalArguments $AdditionalArguments -PassThru:$PassThru
        if (-not $NoTrayIcon) {
            Start-CodexProfileTray -TrayScriptPath $profile.TrayScriptPath -WhatIf:$WhatIfPreference
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

Export-ModuleMember -Function Get-CodexProfilePaths, New-CodexDesktopProfile, Start-CodexDesktopProfile, Install-CodexDesktopProfiles
