param(
    [string]$RuntimeRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path,
    [switch]$ValidateOnly
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $RuntimeRoot 'src/CodexProfiles/CodexProfiles.psd1') -Force
if ($ValidateOnly) {
    # Exercise package discovery inside the EXE's embedded Windows PowerShell runspace.
    & (Get-Module CodexProfiles) { Get-CodexDesktopPackage } | Out-Null
    if (-not [IO.File]::Exists((Join-Path $RuntimeRoot 'bin/ConversationSync.exe'))) {
        throw 'The embedded conversation enhancer is missing.'
    }
    & (Get-Module CodexProfiles) { Get-CodexProfileShell } | Out-Null
    Write-Output 'Codex Profiles runtime OK'
    return
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()

$form = [Windows.Forms.Form]::new()
$form.Text = 'Codex 多实例管理器'
$form.ClientSize = [Drawing.Size]::new(820, 660)
$form.MinimumSize = [Drawing.Size]::new(836, 699)
$form.StartPosition = 'CenterScreen'
$form.Font = [Drawing.Font]::new('Microsoft YaHei UI', 10)
$form.AutoScaleMode = 'Dpi'

$title = [Windows.Forms.Label]::new()
$title.Text = '创建与启动实例'
$title.Font = [Drawing.Font]::new('Microsoft YaHei UI', 16, [Drawing.FontStyle]::Bold)
$title.SetBounds(24, 18, 740, 34)
$form.Controls.Add($title)

$nameLabel = [Windows.Forms.Label]::new()
$nameLabel.Text = '实例名称'
$nameLabel.SetBounds(24, 76, 100, 26)
$form.Controls.Add($nameLabel)
$nameBox = [Windows.Forms.TextBox]::new()
$nameBox.SetBounds(130, 72, 310, 30)
$form.Controls.Add($nameBox)
$nameHint = [Windows.Forms.Label]::new()
$nameHint.Text = '使用英文、数字或连字符，例如 work-2'
$nameHint.SetBounds(455, 77, 345, 26)
$form.Controls.Add($nameHint)

$independent = [Windows.Forms.RadioButton]::new()
$independent.Text = '独立空间'
$independent.Checked = $true
$independent.SetBounds(130, 118, 160, 28)
$form.Controls.Add($independent)
$shared = [Windows.Forms.RadioButton]::new()
$shared.Text = '共享已有实例的会话空间'
$shared.SetBounds(300, 118, 330, 28)
$form.Controls.Add($shared)

$sourceLabel = [Windows.Forms.Label]::new()
$sourceLabel.Text = '共享来源'
$sourceLabel.SetBounds(24, 165, 100, 28)
$form.Controls.Add($sourceLabel)
$sourceBox = [Windows.Forms.ComboBox]::new()
$sourceBox.DropDownStyle = 'DropDownList'
$sourceBox.DisplayMember = 'Label'
$sourceBox.SetBounds(130, 160, 560, 30)
$sourceBox.Enabled = $false
$form.Controls.Add($sourceBox)
$browseButton = [Windows.Forms.Button]::new()
$browseButton.Text = '浏览…'
$browseButton.SetBounds(704, 158, 90, 34)
$browseButton.Enabled = $false
$form.Controls.Add($browseButton)

$explanation = [Windows.Forms.Label]::new()
$explanation.Text = '独立空间会分别保存账号、设置和对话。'
$explanation.SetBounds(130, 205, 660, 70)
$form.Controls.Add($explanation)

$shortcutBox = [Windows.Forms.CheckBox]::new()
$shortcutBox.Text = '创建桌面快捷方式'
$shortcutBox.SetBounds(130, 278, 240, 28)
$form.Controls.Add($shortcutBox)
$createButton = [Windows.Forms.Button]::new()
$createButton.Text = '确认创建'
$createButton.SetBounds(610, 272, 184, 40)
$form.Controls.Add($createButton)

$listLabel = [Windows.Forms.Label]::new()
$listLabel.Text = '已有实例'
$listLabel.SetBounds(24, 336, 300, 28)
$form.Controls.Add($listLabel)
$list = [Windows.Forms.ListView]::new()
$list.View = 'Details'
$list.FullRowSelect = $true
$list.MultiSelect = $false
$list.HideSelection = $false
$list.SetBounds(24, 370, 770, 180)
$list.Anchor = 'Top,Bottom,Left,Right'
[void]$list.Columns.Add('实例', 150)
[void]$list.Columns.Add('空间', 90)
[void]$list.Columns.Add('共享来源 / 数据目录', 400)
[void]$list.Columns.Add('自动刷新', 105)
$form.Controls.Add($list)

$refreshButton = [Windows.Forms.Button]::new()
$refreshButton.Text = '刷新'
$refreshButton.SetBounds(24, 564, 92, 36)
$refreshButton.Anchor = 'Bottom,Left'
$form.Controls.Add($refreshButton)
$folderButton = [Windows.Forms.Button]::new()
$folderButton.Text = '打开数据目录'
$folderButton.SetBounds(130, 564, 145, 36)
$folderButton.Anchor = 'Bottom,Left'
$form.Controls.Add($folderButton)
$deleteButton = [Windows.Forms.Button]::new()
$deleteButton.Text = '删除实例'
$deleteButton.SetBounds(289, 564, 118, 36)
$deleteButton.Anchor = 'Bottom,Left'
$deleteButton.Enabled = $false
$form.Controls.Add($deleteButton)
$launchButton = [Windows.Forms.Button]::new()
$launchButton.Text = '启动选中实例'
$launchButton.SetBounds(610, 564, 184, 36)
$launchButton.Anchor = 'Bottom,Right'
$form.Controls.Add($launchButton)
$status = [Windows.Forms.Label]::new()
$status.Text = '新实例首次启动时需要单独登录。'
$status.SetBounds(24, 616, 770, 26)
$status.Anchor = 'Bottom,Left,Right'
$form.Controls.Add($status)

function Update-ProfileList {
    $selectedSource = if ($sourceBox.SelectedItem) { $sourceBox.SelectedItem.Home } else { '' }
    $sourceBox.Items.Clear()
    $defaultHome = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex'
    if ([IO.Directory]::Exists($defaultHome)) {
        [void]$sourceBox.Items.Add([pscustomobject]@{ Label = "原应用 ($defaultHome)"; Home = $defaultHome })
    }
    $list.Items.Clear()
    $defaultProfile = [pscustomobject]@{
        ProfileName = '<default>'
        Home = $defaultHome
        SharedHome = ''
        SyncStatusPath = (Join-Path $env:LOCALAPPDATA 'CodexProfilesLauncher/default/conversation-sync.json')
    }
    foreach ($profile in @($defaultProfile) + @(Get-CodexDesktopProfiles)) {
        $label = if ($profile.ProfileName -eq '<default>') { '原应用' } else { $profile.DisplayName }
        $item = [Windows.Forms.ListViewItem]::new($label)
        $mode = if ($profile.SharedHome) { '共享' } else { '独立' }
        [void]$item.SubItems.Add($mode)
        $location = if ($profile.SharedHome) { $profile.SharedHome } else { $profile.Home }
        [void]$item.SubItems.Add($location)
        [void]$item.SubItems.Add('未连接')
        if ($profile.ProfileName -ne '<default>') {
            $profile | Add-Member -NotePropertyName SyncStatusPath -NotePropertyValue (Join-Path $profile.Home 'conversation-sync.json')
        }
        $item.Tag = $profile
        [void]$list.Items.Add($item)
        if ($profile.ProfileName -ne '<default>') { [void]$sourceBox.Items.Add([pscustomobject]@{
            Label = $profile.DisplayName + ' (' + $profile.Home + ')'
            Home = $profile.Home
        }) }
    }
    for ($index = 0; $index -lt $sourceBox.Items.Count; $index++) {
        if ($sourceBox.Items[$index].Home -eq $selectedSource) { $sourceBox.SelectedIndex = $index }
    }
    if ($sourceBox.SelectedIndex -lt 0 -and $sourceBox.Items.Count -gt 0) { $sourceBox.SelectedIndex = 0 }
}

function Update-SyncStatus {
    # Update status cells in place so background checks preserve the user's current selection.
    foreach ($item in $list.Items) {
        $label = '未连接'
        try {
            $path = $item.Tag.SyncStatusPath
            if ([IO.File]::Exists($path)) {
                $sync = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) | ConvertFrom-Json
                $label = switch ($sync.state) {
                    'ready' {
                        if ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - $sync.lastRefresh -lt 20000) { '运行中' }
                        else { '等待刷新' }
                    }
                    'restart-required' { '需重新打开' }
                    'connecting' { '连接中' }
                    'reconnecting' { '重连中' }
                    'retrying' { '重试中' }
                    'stopped' { '已停止' }
                    'unsupported-version' { '版本待适配' }
                    'connection-failed' { '连接失败' }
                    default { '等待应用就绪' }
                }
            }
        }
        catch { $label = '等待状态更新' }
        $item.SubItems[3].Text = $label
    }
}

$shared.add_CheckedChanged({
    $sourceBox.Enabled = $shared.Checked
    $browseButton.Enabled = $shared.Checked
    $explanation.Text = if ($shared.Checked) {
        "共用会话数据库、历史及相关文件，auth.json 与窗口登录状态独立。`r`n配置启动时跟随来源，侧边栏布局初始导入。`r`n后台约 5 秒刷新列表，同一条对话请轮流操作。"
    }
    else { '独立空间会分别保存账号、设置和对话。' }
})

$browseButton.add_Click({
    $dialog = [Windows.Forms.FolderBrowserDialog]::new()
    $dialog.Description = '选择已有实例的 CODEX_HOME，例如用户目录下的 .codex'
    $dialog.ShowNewFolderButton = $false
    try {
        if ($dialog.ShowDialog($form) -eq 'OK') {
            $homePath = $dialog.SelectedPath
            $entry = [pscustomobject]@{ Label = $homePath; Home = $homePath }
            $sourceBox.SelectedIndex = $sourceBox.Items.Add($entry)
        }
    }
    finally { $dialog.Dispose() }
})

$createButton.add_Click({
    try {
        $profileName = $nameBox.Text.Trim()
        if ($profileName -notmatch '^[a-zA-Z0-9]+(?:-[a-zA-Z0-9]+)*$') {
            throw '请输入英文、数字和连字符组成的实例名称。'
        }
        $paths = Get-CodexProfilePaths -ProfileName $profileName
        if ([IO.Directory]::Exists($paths.Home)) { throw '此实例名称已存在，请选择已有实例启动或换一个名称。' }
        $sharedHome = ''
        $description = '独立空间'
        if ($shared.Checked) {
            if (-not $sourceBox.SelectedItem) { throw '请选择共享来源。' }
            $sharedHome = $sourceBox.SelectedItem.Home
            if (-not ((Test-Path -LiteralPath (Join-Path $sharedHome 'config.toml')) -or
                      (Test-Path -LiteralPath (Join-Path $sharedHome 'sessions')))) {
                throw '所选目录不是可识别的 Codex 实例空间，请选择含有 config.toml 或 sessions 的目录。'
            }
            $description = "共享会话空间`r`n来源：$sharedHome`r`nauth.json 独立，首次启动后单独登录。"
        }
        $confirmation = "实例：$profileName`r`n方式：$description`r`n数据目录：$($paths.Home)`r`n`r`n确认创建？"
        if ([Windows.Forms.MessageBox]::Show($form, $confirmation, '确认创建实例', 'YesNo', 'Question') -ne 'Yes') { return }
        $createButton.Enabled = $false
        $status.Text = '正在创建实例…'
        $form.Refresh()
        $launcherPath = Join-Path $RuntimeRoot 'scripts/windows/Start-CodexDesktopProfile.ps1'
        $created = New-CodexDesktopProfile -ProfileName $profileName -SharedHome $sharedHome `
            -CreateDesktopShortcut:$shortcutBox.Checked -LauncherScriptPath $launcherPath
        Update-ProfileList
        foreach ($item in $list.Items) {
            if ($item.Tag.ProfileName -eq $created.ProfileKey) { $item.Selected = $true }
        }
        $status.Text = '创建完成，选中实例后点击“启动选中实例”。'
    }
    catch {
        $status.Text = '创建未完成，可查看错误后重试。'
        [void][Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, '创建失败', 'OK', 'Error')
    }
    finally { $createButton.Enabled = $true }
})

$launchButton.add_Click({
    try {
        if ($list.SelectedItems.Count -ne 1) { throw '请先选中一个实例。' }
        $profile = $list.SelectedItems[0].Tag
        $launchButton.Enabled = $false
        $status.Text = '正在启动 ' + $list.SelectedItems[0].Text + '…'
        $form.Refresh()
        if ($profile.ProfileName -eq '<default>') { Start-CodexDefaultInstance }
        else { Start-CodexDesktopProfile -ProfileName $profile.ProfileName | Out-Null }
        $status.Text = '已发送启动请求，后台每隔约 5 秒刷新会话。旧入口启动的实例需重新打开一次。'
    }
    catch {
        $status.Text = '启动失败。'
        [void][Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, '启动失败', 'OK', 'Error')
    }
    finally { $launchButton.Enabled = $true }
})
$folderButton.add_Click({
    if ($list.SelectedItems.Count -eq 1) {
        Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + $list.SelectedItems[0].Tag.Home + '"')
    }
})
$list.add_SelectedIndexChanged({
    $deleteButton.Enabled = $list.SelectedItems.Count -eq 1 -and $list.SelectedItems[0].Tag.ProfileName -ne '<default>'
})
$deleteButton.add_Click({
    if ($list.SelectedItems.Count -ne 1) { return }
    $profile = $list.SelectedItems[0].Tag
    if ($profile.ProfileName -eq '<default>') { return }
    try {
        $paths = Get-CodexProfilePaths -ProfileName $profile.ProfileName
        $message = "将从实例列表移除 $($profile.DisplayName)，并把以下目录移到恢复文件夹。`r`n`r`n$($paths.Home)`r`n$($paths.UiData)"
        if ($profile.SharedHome) {
            $message += "`r`n`r`n共享来源保留在 $($profile.SharedHome)"
        }
        $message += "`r`n`r`n若实例仍在运行，请先通过托盘菜单完全退出。确认删除？"
        if ([Windows.Forms.MessageBox]::Show($form, $message, '删除实例', 'YesNo', 'Warning', 'Button2') -ne 'Yes') { return }
        $removed = Remove-CodexDesktopProfile -ProfileName $profile.ProfileName -Confirm:$false
        Update-ProfileList
        $status.Text = '已删除实例 ' + $profile.DisplayName
        [void][Windows.Forms.MessageBox]::Show($form, "已从列表移除实例。数据已移到以下恢复目录。`r`n`r`n$($removed.RecoveryPath)", '删除完成', 'OK', 'Information')
    }
    catch {
        $status.Text = '实例删除未完成。'
        [void][Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, '删除实例失败', 'OK', 'Error')
    }
})
$refreshButton.add_Click({
    try { Update-ProfileList }
    catch { [void][Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, '读取实例失败', 'OK', 'Error') }
})

$syncTimer = [Windows.Forms.Timer]::new()
$syncTimer.Interval = 2000
$syncTimer.add_Tick({ Update-SyncStatus })
try {
    Update-ProfileList
    Update-SyncStatus
    $syncTimer.Start()
    [void]$form.ShowDialog()
}
finally { $syncTimer.Dispose(); $form.Dispose() }
