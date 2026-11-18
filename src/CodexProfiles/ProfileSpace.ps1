# Profile homes keep authentication private while shared histories use one physical store.
function Get-CodexSpaceConfig {
    param([string]$SourceHome)

    $sourceConfig = Join-Path $SourceHome 'config.toml'
    $content = ''
    if ([IO.File]::Exists($sourceConfig)) {
        $content = [IO.File]::ReadAllText($sourceConfig, [Text.Encoding]::UTF8)
    }

    $databaseHome = $SourceHome
    $keptLines = [Collections.Generic.List[string]]::new()
    $inRoot = $true
    $multiline = ''
    foreach ($line in ($content -split '\r\n|\n')) {
        if ($multiline) {
            $keptLines.Add($line)
            if ($line.Contains($multiline)) { $multiline = '' }
            continue
        }
        if ($line -match '^\s*\[') { $inRoot = $false }
        # Only root keys are replaced. Identically named keys in MCP tables stay intact.
        if ($inRoot -and $line -match '^\s*(?:"(sqlite_home|cli_auth_credentials_store)"|''(sqlite_home|cli_auth_credentials_store)''|(sqlite_home|cli_auth_credentials_store))\s*=\s*(.*)$') {
            $key = $Matches[1] + $Matches[2] + $Matches[3]
            $value = $Matches[4]
            if ($key -eq 'sqlite_home') {
                if ($value -match "^'([^']*)'\s*(?:#.*)?$") {
                    $databaseHome = $Matches[1]
                }
                elseif ($value -match '^"((?:[^"\\]|\\.)*)"\s*(?:#.*)?$') {
                    # JSON and TOML basic strings share the escapes needed for Windows paths.
                    $databaseHome = ('"' + $Matches[1] + '"') | ConvertFrom-Json
                }
                else {
                    throw 'The source sqlite_home must be a single-line quoted absolute path.'
                }
            }
            continue
        }
        $keptLines.Add($line)
        if ($line -match '=\s*("""|'''''')') {
            $delimiter = $Matches[1]
            if ([regex]::Matches($line, [regex]::Escape($delimiter)).Count -eq 1) {
                $multiline = $delimiter
            }
        }
    }

    if (-not [IO.Path]::IsPathRooted($databaseHome)) {
        throw 'The source sqlite_home is relative. Set an absolute sqlite_home in the source configuration first.'
    }
    $databaseHome = [IO.Path]::GetFullPath($databaseHome)
    # A literal TOML path avoids changing existing provider, model, or MCP configuration.
    $tomlPath = $databaseHome.Replace('\', '/')
    if ($tomlPath.Contains("'") -or $tomlPath.Contains("`n") -or $tomlPath.Contains("`r")) {
        throw 'The shared database path contains characters unsupported by this launcher.'
    }
    $prefix = "cli_auth_credentials_store = 'file'`r`nsqlite_home = '$tomlPath'`r`n"
    [pscustomobject]@{
        Content = $prefix + ($keptLines -join "`r`n")
        DatabaseHome = $databaseHome
    }
}

function Initialize-CodexProfileSpace {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [string]$ProfileHome,
        [string]$SharedHome
    )

    $profileRoot = [IO.Path]::GetFullPath($ProfileHome).TrimEnd('\')
    $hash = [Security.Cryptography.SHA256]::Create()
    try {
        $profileId = [BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($profileRoot.ToLowerInvariant()))).Replace('-', '')
    }
    finally { $hash.Dispose() }
    $mutex = [Threading.Mutex]::new($false, ('Local\CodexProfileSpace.' + $profileId))
    $locked = $false
    try {
        try { $locked = $mutex.WaitOne(30000) }
        catch [Threading.AbandonedMutexException] { $locked = $true }
        if (-not $locked) { throw 'Another process is preparing this profile. Try again shortly.' }

        $metadataPath = Join-Path $profileRoot 'codex-profile.json'
        $metadata = $null
        if ([IO.File]::Exists($metadataPath)) {
            $metadata = [IO.File]::ReadAllText($metadataPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
            if ($metadata.SharedHome) {
                if ($SharedHome -and ([IO.Path]::GetFullPath($SharedHome).TrimEnd('\') -ine $metadata.SharedHome)) {
                    throw 'This profile already has a different shared space.'
                }
                $SharedHome = $metadata.SharedHome
            }
            elseif ($SharedHome) {
                throw 'Create a new profile name to use a shared space. Existing profiles are preserved.'
            }
        }

        if (-not $SharedHome) { return $null }
        $sourceRoot = [IO.Path]::GetFullPath($SharedHome).TrimEnd('\')
        $visited = @{}
        # Follow shared profiles to their original physical space and reject cycles.
        while ($true) {
            if ($sourceRoot -ieq $profileRoot -or $visited.ContainsKey($sourceRoot)) {
                throw 'A profile cannot share its own space or a cyclic shared space.'
            }
            if (-not [IO.Directory]::Exists($sourceRoot)) {
                throw "Shared space directory does not exist: $sourceRoot"
            }
            if ($sourceRoot.StartsWith($profileRoot + '\', [StringComparison]::OrdinalIgnoreCase) -or
                $profileRoot.StartsWith($sourceRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
                throw 'Profile home and shared home cannot contain one another.'
            }
            $visited[$sourceRoot] = $true
            $sourceMetadataPath = Join-Path $sourceRoot 'codex-profile.json'
            if (-not [IO.File]::Exists($sourceMetadataPath)) { break }
            $sourceMetadata = [IO.File]::ReadAllText($sourceMetadataPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
            if (-not $sourceMetadata.SharedHome) { break }
            $sourceRoot = [IO.Path]::GetFullPath($sourceMetadata.SharedHome).TrimEnd('\')
        }
        if (-not $metadata -and [IO.Directory]::Exists($profileRoot) -and
            @(Get-ChildItem -LiteralPath $profileRoot -Force).Count -gt 0) {
            throw 'The target profile already contains data. Choose a new profile name for shared mode.'
        }

        $settings = Get-CodexSpaceConfig -SourceHome $sourceRoot
        # Directory junctions keep rollout paths and their writer locks in the same physical space.
        # Browser data, authentication, sandbox credentials, and process state remain profile-local.
        $sharedDirectories = @(
            'sessions', 'archived_sessions', 'attachments', 'generated_images',
            'skills', 'rules', 'plugins', 'worktrees', 'sqlite',
            'thread-writer-locks', 'project-metadata-locks', 'rollout-migrations',
            'session-index-repair'
        )
        foreach ($name in $sharedDirectories) {
            $targetPath = Join-Path $profileRoot $name
            $sourcePath = Join-Path $sourceRoot $name
            if (Test-Path -LiteralPath $targetPath) {
                $existing = Get-Item -LiteralPath $targetPath -Force
                if ($existing.LinkType -ne 'Junction' -or
                    [IO.Path]::GetFullPath([string]@($existing.Target)[0]).TrimEnd('\') -ine $sourcePath) {
                    throw "A shared directory has been replaced or conflicts with local data: $targetPath"
                }
            }
        }

        $authPath = Join-Path $profileRoot 'auth.json'
        if (Test-Path -LiteralPath $authPath) {
            $authItem = Get-Item -LiteralPath $authPath -Force
            if ($authItem.LinkType) {
                throw 'The profile auth.json must be a private regular file, without symbolic or hard links.'
            }
        }

        if ($PSCmdlet.ShouldProcess($profileRoot, 'Initialize shared conversation space with private authentication')) {
            New-Item -ItemType Directory -Path $profileRoot -Force | Out-Null
            # Persist intent before creating links so a partially failed creation can be retried.
            $spaceMetadata = @{ Version = 1; SharedHome = $sourceRoot }
            if (-not $metadata -or $metadata.SharedHome -ine $sourceRoot) {
                $metadataTemp = Join-Path $profileRoot ('space-' + [Guid]::NewGuid().ToString('N') + '.tmp')
                [IO.File]::WriteAllText($metadataTemp, ($spaceMetadata | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
                if ([IO.File]::Exists($metadataPath)) {
                    [IO.File]::Replace($metadataTemp, $metadataPath, [NullString]::Value)
                }
                else { [IO.File]::Move($metadataTemp, $metadataPath) }
            }
            foreach ($name in $sharedDirectories) {
                $sourcePath = Join-Path $sourceRoot $name
                $targetPath = Join-Path $profileRoot $name
                New-Item -ItemType Directory -Path $sourcePath -Force | Out-Null
                if (-not (Test-Path -LiteralPath $targetPath)) {
                    New-Item -ItemType Junction -Path $targetPath -Target $sourcePath | Out-Null
                }
            }
            # Refresh the source configuration at launch, enforcing private file-based auth storage.
            $configPath = Join-Path $profileRoot 'config.toml'
            $currentConfig = if ([IO.File]::Exists($configPath)) { [IO.File]::ReadAllText($configPath, [Text.Encoding]::UTF8) } else { $null }
            if ($currentConfig -cne $settings.Content) {
                $configTemp = Join-Path $profileRoot ('config-' + [Guid]::NewGuid().ToString('N') + '.tmp')
                [IO.File]::WriteAllText($configTemp, $settings.Content, [Text.UTF8Encoding]::new($false))
                if ([IO.File]::Exists($configPath)) { [IO.File]::Replace($configTemp, $configPath, [NullString]::Value) }
                else { [IO.File]::Move($configTemp, $configPath) }
            }
            # Seed project/sidebar metadata once, excluding account-specific UI and login state.
            $sourceState = Join-Path $sourceRoot '.codex-global-state.json'
            $targetState = Join-Path $profileRoot '.codex-global-state.json'
            if ([IO.File]::Exists($sourceState) -and -not [IO.File]::Exists($targetState)) {
                $sourceUi = [IO.File]::ReadAllText($sourceState, [Text.Encoding]::UTF8) | ConvertFrom-Json
                $projectUi = @{}
                $projectKeys = @(
                    'local-projects', 'project-appearances', 'sidebar-project-thread-orders',
                    'thread-project-assignments', 'thread-project-membership-host-ids',
                    'projectless-thread-ids', 'project-order', 'pinned-project-ids',
                    'pinned-thread-ids', 'electron-saved-workspace-roots',
                    'electron-workspace-root-labels'
                )
                foreach ($property in $sourceUi.PSObject.Properties) {
                    if ($property.Name -in $projectKeys) {
                        $projectUi[$property.Name] = $property.Value
                    }
                }
                [IO.File]::WriteAllText($targetState, ($projectUi | ConvertTo-Json -Depth 100), [Text.UTF8Encoding]::new($false))
            }
        }
        return $sourceRoot
    }
    finally {
        if ($locked) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Get-CodexDesktopProfiles {
    [CmdletBinding()]
    param([string]$ProfilesRoot = (Join-Path $env:LOCALAPPDATA 'CodexProfiles'))

    if (-not [IO.Directory]::Exists($ProfilesRoot)) { return }
    foreach ($directory in (Get-ChildItem -LiteralPath $ProfilesRoot -Directory | Sort-Object Name)) {
        $metadataPath = Join-Path $directory.FullName 'codex-profile.json'
        $sharedHome = ''
        if ([IO.File]::Exists($metadataPath)) {
            $metadata = [IO.File]::ReadAllText($metadataPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
            $sharedHome = [string]$metadata.SharedHome
        }
        [pscustomobject]@{
            ProfileName = $directory.Name
            DisplayName = Get-CodexProfileDisplayName -ProfileHome $directory.FullName -Fallback $directory.Name
            Home = $directory.FullName
            SharedHome = $sharedHome
        }
    }
}
