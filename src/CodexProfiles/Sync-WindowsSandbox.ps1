param(
    [Parameter(Mandatory = $true)]
    [string]$ProfileHome,

    [string]$DefaultHome = (Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex')
)

$ErrorActionPreference = 'Stop'
$encoding = [Text.UTF8Encoding]::new($false, $true)
$defaultRoot = [IO.Path]::GetFullPath($DefaultHome).TrimEnd('\')
$profileRoot = [IO.Path]::GetFullPath($ProfileHome).TrimEnd('\')
if ($defaultRoot -eq $profileRoot) {
    throw 'Cannot synchronize the default Codex configuration into itself.'
}

function Read-SandboxKeys {
    param([string]$File)

    $text = if ([IO.File]::Exists($File)) { [IO.File]::ReadAllText($File, $encoding) } else { '' }
    $lines = [Collections.Generic.List[string]]::new()
    $lines.AddRange([string[]]($text -split '\r\n|\n'))
    $sections = @{}
    $keys = @{}
    $section = ''
    $multiline = ''
    for ($index = 0; $index -lt $lines.Count; $index++) {
        $line = $lines[$index]
        if ($multiline) {
            if ($line.Contains($multiline)) { $multiline = '' }
            continue
        }
        if ($line -match '^\s*(?:#|$)') { continue }
        if ($line -match '^\s*\[\s*(windows|features)\s*\]\s*(?:#.*)?$') {
            $section = $Matches[1]
            if ($sections.ContainsKey($section)) { throw 'Duplicate sandbox configuration table.' }
            $sections[$section] = $index
            continue
        }
        if ($line -match '^\s*\[') {
            $section = '<other>'
            continue
        }
        $fullKey = $null
        if ($section -in @('windows', 'features') -and $line -cmatch '^\s*(sandbox|prefer_mxc)\s*=\s*(.*?)\s*(#.*)?$') {
            $fullKey = "$section.$($Matches[1])"
        }
        elseif (-not $section -and $line -cmatch '^\s*(windows|features)\s*\.\s*(sandbox|prefer_mxc)\s*=\s*(.*?)\s*(#.*)?$') {
            $fullKey = "$($Matches[1]).$($Matches[2])"
        }
        elseif (-not $section -and $line -match '^\s*["'']?(windows|features)["'']?\s*=') {
            throw 'Inline sandbox configuration tables must be expanded before synchronization.'
        }
        if ($fullKey -in @('windows.sandbox', 'features.prefer_mxc')) {
            if ($keys.ContainsKey($fullKey)) { throw 'Duplicate sandbox configuration key.' }
            $value = ($line -split '=', 2)[1].Trim()
            if ($fullKey -eq 'windows.sandbox') {
                if ($value -cnotmatch '^(?:"([a-z][a-z0-9_-]*)"|''([a-z][a-z0-9_-]*)'')\s*(#.*)?$') {
                    throw 'Cannot read windows.sandbox.'
                }
                $rawValue = $Matches[1] + $Matches[2]
                $comment = $Matches[3]
            }
            else {
                if ($value -cnotmatch '^(true|false)\s*(#.*)?$') { throw 'Cannot read features.prefer_mxc.' }
                $rawValue = $Matches[1]
                $comment = $Matches[2]
            }
            $keys[$fullKey] = @{ Index = $index; Value = $rawValue; Comment = $comment }
        }
        # Ignore TOML-looking text inside multi-line string values.
        if ($line -match '=\s*("""|'''''')') {
            $delimiter = $Matches[1]
            if ([regex]::Matches($line, [regex]::Escape($delimiter)).Count -eq 1) {
                $multiline = $delimiter
            }
        }
    }
    return @{ Text = $text; Lines = $lines; Sections = $sections; Keys = $keys }
}

$defaultPath = Join-Path $defaultRoot 'config.toml'
$statePath = Join-Path $defaultRoot '.codex-global-state.json'
if (-not ([IO.File]::Exists($defaultPath) -or [IO.File]::Exists($statePath))) { return }
$default = Read-SandboxKeys -File $defaultPath
$sandbox = if ($default.Keys.ContainsKey('windows.sandbox')) { $default.Keys['windows.sandbox'].Value }
$preferMxc = if ($default.Keys.ContainsKey('features.prefer_mxc')) { $default.Keys['features.prefer_mxc'].Value }
if ([IO.File]::Exists($statePath)) {
    $state = [IO.File]::ReadAllText($statePath, $encoding) | ConvertFrom-Json -ErrorAction Stop
    # The desktop adds the same preference to its backend launch arguments when the flag is true.
    $desktopPreference = if ($state) { $state.PSObject.Properties['electron-prefer-mxc-enabled'] }
    if ($desktopPreference -and $desktopPreference.Value -is [bool] -and $desktopPreference.Value) {
        $preferMxc = 'true'
    }
}

$profilePath = Join-Path $profileRoot 'config.toml'
$profile = Read-SandboxKeys -File $profilePath
$changes = @()
foreach ($item in @(
    @{ Table = 'windows'; Key = 'sandbox'; Value = $sandbox; Quoted = $true },
    @{ Table = 'features'; Key = 'prefer_mxc'; Value = $preferMxc; Quoted = $false }
)) {
    $current = $profile.Keys["$($item.Table).$($item.Key)"]
    $currentValue = if ($current) { $current.Value }
    if ($currentValue -ceq $item.Value) { continue }
    if ($current) {
        $index = $current.Index
    }
    elseif ($profile.Sections.ContainsKey($item.Table)) {
        $index = $profile.Sections[$item.Table] + 1
    }
    else {
        $index = $profile.Lines.Count
    }
    $changes += @{ Index = $index; Item = $item; Current = $current }
}
if (-not $changes.Count) { return }

# Apply from bottom to top so inserting or removing a key cannot shift remaining edit positions.
foreach ($change in ($changes | Sort-Object { $_.Index } -Descending)) {
    $item = $change.Item
    $current = $change.Current
    if ($null -eq $item.Value) {
        $profile.Lines.RemoveAt($change.Index)
        continue
    }
    $value = if ($item.Quoted) { '"' + $item.Value + '"' } else { $item.Value }
    if ($current) {
        $prefix = ($profile.Lines[$change.Index] -split '=', 2)[0].TrimEnd()
        $comment = if ($current.Comment) { ' ' + $current.Comment } else { '' }
        $profile.Lines[$change.Index] = "$prefix = $value$comment"
    }
    elseif ($profile.Sections.ContainsKey($item.Table)) {
        $profile.Lines.Insert($change.Index, "$($item.Key) = $value")
    }
    else {
        $profile.Lines.Add("[$($item.Table)]")
        $profile.Lines.Add("$($item.Key) = $value")
        $profile.Lines.Add('')
    }
}

$newline = if ($profile.Text.Contains("`r`n")) { "`r`n" } else { "`n" }
$updated = $profile.Lines -join $newline
$temp = Join-Path $profileRoot ('.sandbox-config-' + [Guid]::NewGuid().ToString('N') + '.tmp')
[IO.File]::WriteAllText($temp, $updated, $encoding)
try {
    if ([IO.File]::Exists($profilePath)) {
        if ([IO.File]::ReadAllText($profilePath, $encoding) -cne $profile.Text) {
            throw 'The profile configuration changed during synchronization. Try opening it again.'
        }
        $backup = Join-Path $profileRoot ('config.toml.before-sandbox-sync-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '.bak')
        [IO.File]::Replace($temp, $profilePath, $backup)
    }
    else {
        [IO.File]::Move($temp, $profilePath)
    }
}
finally {
    if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) }
}
