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

    [pscustomobject]@{
        Package = $package
        Version = $package.Version.ToString()
        AppDirectory = $appDirectory
        ExePath = $exePath
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

function Ensure-CodexDesktopClone {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true)]
        $PackageInfo,

        [string]$ParallelRoot = (Join-Path $env:LOCALAPPDATA 'CodexParallelDesktop'),

        [switch]$ForceRefresh
    )

    $versionsRoot = Join-Path $ParallelRoot 'versions'
    $cloneRoot = Join-Path $versionsRoot $PackageInfo.Version
    $cloneAppDirectory = Join-Path $cloneRoot 'app'
    $cloneExe = Join-Path $cloneAppDirectory (Split-Path -Path $PackageInfo.ExePath -Leaf)

    if ((-not $ForceRefresh) -and (Test-Path $cloneExe)) {
        return $cloneExe
    }

    if ($PSCmdlet.ShouldProcess($cloneAppDirectory, 'Clone Codex desktop binaries')) {
        New-Item -ItemType Directory -Force -Path $cloneAppDirectory | Out-Null
        & robocopy.exe $PackageInfo.AppDirectory $cloneAppDirectory /E /NFL /NDL /NJH /NJS /NC /NS | Out-Null
        $robocopyExit = $LASTEXITCODE
        if ($robocopyExit -gt 7) {
            throw "Failed to clone Codex desktop app (robocopy exit code $robocopyExit)."
        }
    }

    if (-not (Test-Path $cloneExe)) {
        throw "Cloned Codex executable not found: $cloneExe"
    }

    return $cloneExe
}

function Clear-CodexDesktopInheritedEnv {
    [CmdletBinding()]
    param()

    $varsToRemove = @(
        'OPENAI_BASE_URL',
        'OPENAI_API_KEY',
        'OPENAI_ORG_ID',
        'OPENAI_PROJECT_ID',
        'ANTHROPIC_BASE_URL',
        'ANTHROPIC_API_KEY',
        'ANTHROPIC_AUTH_TOKEN',
        'CODEX_THREAD_ID'
    )

    foreach ($name in $varsToRemove) {
        Remove-Item -Path ("Env:$name") -ErrorAction SilentlyContinue
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
        [string]$CloneExe,

        [Parameter(Mandatory = $true)]
        [string]$UiData
    )

    # Base64 keeps generated no-BOM scripts compatible with non-ASCII Windows user paths in PowerShell 5.1.
    $cloneExeBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($CloneExe))
    $uiDataBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($UiData))
    $content = @(
        '[CmdletBinding(SupportsShouldProcess = $true)]',
        'param()',
        '',
        '$ErrorActionPreference = ''Stop''',
        '$targetExe = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(''' + $cloneExeBase64 + '''))',
        '$targetUiData = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(''' + $uiDataBase64 + '''))',
        '$processName = [System.IO.Path]::GetFileName($targetExe)',
        '$profileArgument = "--user-data-dir=$targetUiData"',
        '',
        '# Match the profile-specific main process; taskkill /T also terminates its Electron children.',
        '$processes = Get-CimInstance Win32_Process -Filter ("Name = ''{0}''" -f $processName.Replace("''", "''''")) |',
        '    Where-Object {',
        '        $_.ExecutablePath -and',
        '        [string]::Equals($_.ExecutablePath, $targetExe, [System.StringComparison]::OrdinalIgnoreCase) -and',
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
        [string]$CloneExe,

        [Parameter(Mandatory = $true)]
        [string]$ProfileHome,

        [Parameter(Mandatory = $true)]
        [string]$UiData,

        [Parameter(Mandatory = $true)]
        [string]$ProfileKey
    )

    # Encode paths so the generated script remains ASCII-only and works in Windows PowerShell 5.1.
    $cloneExeBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($CloneExe))
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
        '$targetExe = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(''' + $cloneExeBase64 + '''))',
        '$profileHome = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(''' + $profileHomeBase64 + '''))',
        '$targetUiData = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(''' + $uiDataBase64 + '''))',
        '$stopScriptPath = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(''' + $stopScriptBase64 + '''))',
        "`$profileKey = '$escapedProfileKey'",
        '$processName = [System.IO.Path]::GetFileName($targetExe)',
        '$profileArgument = "--user-data-dir=$targetUiData"',
        '',
        'function Get-ProfileProcesses {',
        '    return @(Get-CimInstance Win32_Process -Filter ("Name = ''{0}''" -f $processName.Replace("''", "''''")) |',
        '        Where-Object {',
        '            $_.ExecutablePath -and',
        '            [string]::Equals($_.ExecutablePath, $targetExe, [System.StringComparison]::OrdinalIgnoreCase) -and',
        '            $_.CommandLine -and',
        '            ($_.CommandLine.IndexOf($profileArgument, [System.StringComparison]::OrdinalIgnoreCase) -ge 0)',
        '        })',
        '}',
        '',
        'function Start-ProfileApp {',
        '    foreach ($name in @(''OPENAI_BASE_URL'',''OPENAI_API_KEY'',''OPENAI_ORG_ID'',''OPENAI_PROJECT_ID'',''ANTHROPIC_BASE_URL'',''ANTHROPIC_API_KEY'',''ANTHROPIC_AUTH_TOKEN'',''CODEX_THREAD_ID'')) {',
        '        Remove-Item -Path ("Env:$name") -ErrorAction SilentlyContinue',
        '    }',
        '    $env:CODEX_HOME = $profileHome',
        '    Start-Process -FilePath $targetExe -WorkingDirectory (Split-Path $targetExe) -ArgumentList @("--user-data-dir=$targetUiData") | Out-Null',
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

        [string]$LauncherScriptPath,

        [switch]$ForceRefreshClone
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
    $cloneExe = Ensure-CodexDesktopClone -PackageInfo $packageInfo -ParallelRoot $ParallelRoot -ForceRefresh:$ForceRefreshClone -WhatIf:$WhatIfPreference
    $stopScriptPath = Join-Path $paths.Home 'Stop-CodexDesktopProfile.ps1'
    Write-CodexProfileStopScript -StopScriptPath $stopScriptPath -CloneExe $cloneExe -UiData $paths.UiData -WhatIf:$WhatIfPreference
    $trayScriptPath = Join-Path $paths.Home 'Show-CodexDesktopProfileTray.ps1'
    Write-CodexProfileTrayScript -TrayScriptPath $trayScriptPath -StopScriptPath $stopScriptPath -CloneExe $cloneExe -ProfileHome $paths.Home -UiData $paths.UiData -ProfileKey $paths.ProfileKey -WhatIf:$WhatIfPreference

    if ($LauncherScriptPath) {
        $launcherFullPath = (Resolve-Path $LauncherScriptPath).Path
        if ($CreateDesktopShortcut) {
            $desktopShortcut = Join-Path ([Environment]::GetFolderPath('Desktop')) ("$DisplayName.lnk")
            New-CodexDesktopShortcut -ShortcutPath $desktopShortcut -LauncherScriptPath $launcherFullPath -ProfileName $ProfileName -DisplayName $DisplayName -IconPath $cloneExe -WhatIf:$WhatIfPreference
        }

        if ($CreateStartMenuShortcut) {
            $startMenuDirectory = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Codex Profiles'
            $startMenuShortcut = Join-Path $startMenuDirectory ("$DisplayName.lnk")
            New-CodexDesktopShortcut -ShortcutPath $startMenuShortcut -LauncherScriptPath $launcherFullPath -ProfileName $ProfileName -DisplayName $DisplayName -IconPath $cloneExe -WhatIf:$WhatIfPreference
        }
    }

    [pscustomobject]@{
        ProfileName = $ProfileName
        DisplayName = $DisplayName
        ProfileKey = $paths.ProfileKey
        Home = $paths.Home
        UiData = $paths.UiData
        ConfigPath = $configPath
        CloneExe = $cloneExe
        StopScriptPath = $stopScriptPath
        TrayScriptPath = $trayScriptPath
    }
}

function Invoke-CodexDesktopLaunch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$CloneExe,

        [Parameter(Mandatory = $true)]
        [string]$ProfileHome,

        [Parameter(Mandatory = $true)]
        [string]$UiData,

        [string[]]$AdditionalArguments,

        [switch]$PassThru
    )

    $saved = @{}
    foreach ($name in @('OPENAI_BASE_URL','OPENAI_API_KEY','OPENAI_ORG_ID','OPENAI_PROJECT_ID','ANTHROPIC_BASE_URL','ANTHROPIC_API_KEY','ANTHROPIC_AUTH_TOKEN','CODEX_THREAD_ID','CODEX_HOME')) {
        $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
    }

    try {
        Clear-CodexDesktopInheritedEnv
        $env:CODEX_HOME = $ProfileHome

        $arguments = @("--user-data-dir=$UiData")
        if ($AdditionalArguments) {
            $arguments += $AdditionalArguments
        }

        if ($PassThru) {
            return Start-Process -FilePath $CloneExe -WorkingDirectory (Split-Path $CloneExe) -ArgumentList $arguments -PassThru
        }

        Start-Process -FilePath $CloneExe -WorkingDirectory (Split-Path $CloneExe) -ArgumentList $arguments | Out-Null
    }
    finally {
        foreach ($entry in $saved.GetEnumerator()) {
            if ($null -eq $entry.Value) {
                Remove-Item -Path ("Env:$($entry.Key)") -ErrorAction SilentlyContinue
            }
            else {
                Set-Item -Path ("Env:$($entry.Key)") -Value $entry.Value
            }
        }
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

        [switch]$ForceRefreshClone,

        [string[]]$AdditionalArguments,

        [switch]$NoTrayIcon,

        [switch]$PassThru
    )

    $profile = New-CodexDesktopProfile -ProfileName $ProfileName -DisplayName $DisplayName -ProfilesRoot $ProfilesRoot -ParallelRoot $ParallelRoot -EnableCommonMcp:$EnableCommonMcp -OverwriteConfig:$OverwriteConfig -ForceRefreshClone:$ForceRefreshClone -WhatIf:$WhatIfPreference

    if ($PSCmdlet.ShouldProcess($profile.DisplayName, 'Launch isolated Codex desktop profile')) {
        $process = Invoke-CodexDesktopLaunch -CloneExe $profile.CloneExe -ProfileHome $profile.Home -UiData $profile.UiData -AdditionalArguments $AdditionalArguments -PassThru:$PassThru
        if (-not $NoTrayIcon) {
            Start-CodexProfileTray -TrayScriptPath $profile.TrayScriptPath -WhatIf:$WhatIfPreference
        }
        if ($PassThru) {
            return [pscustomobject]@{
                ProfileName = $profile.ProfileName
                DisplayName = $profile.DisplayName
                Home = $profile.Home
                UiData = $profile.UiData
                CloneExe = $profile.CloneExe
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

        [string]$LauncherScriptPath,

        [switch]$ForceRefreshClone
    )

    $profileNames = Expand-CodexProfileNames -ProfileName $ProfileName

    $results = foreach ($name in $profileNames) {
        $displayName = 'Codex ' + (Get-Culture).TextInfo.ToTitleCase((ConvertTo-CodexProfileKey -ProfileName $name))
        New-CodexDesktopProfile -ProfileName $name -DisplayName $displayName -EnableCommonMcp:$EnableCommonMcp -OverwriteConfig:$OverwriteConfig -CreateDesktopShortcut:$CreateDesktopShortcuts -CreateStartMenuShortcut:$CreateStartMenuShortcuts -LauncherScriptPath $LauncherScriptPath -ForceRefreshClone:$ForceRefreshClone -WhatIf:$WhatIfPreference
    }

    return $results
}

Export-ModuleMember -Function Get-CodexProfilePaths, New-CodexDesktopProfile, Start-CodexDesktopProfile, Install-CodexDesktopProfiles
