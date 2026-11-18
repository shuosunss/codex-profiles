function Remove-CodexDesktopProfile {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory = $true)]
        [ValidatePattern('^[a-z0-9]+(?:-[a-z0-9]+)*$')]
        [string]$ProfileName,

        [string]$ProfilesRoot = (Join-Path $env:LOCALAPPDATA 'CodexProfiles'),

        [string]$ParallelRoot = (Join-Path $env:LOCALAPPDATA 'CodexParallelDesktop')
    )

    $profilesDirectory = [IO.Path]::GetFullPath($ProfilesRoot).TrimEnd('\')
    $uiRoot = [IO.Path]::GetFullPath((Join-Path $ParallelRoot 'ui')).TrimEnd('\')
    $paths = Get-CodexProfilePaths -ProfileName $ProfileName -ProfilesRoot $profilesDirectory -ParallelRoot $ParallelRoot
    $profileHome = [IO.Path]::GetFullPath($paths.Home)
    $uiData = [IO.Path]::GetFullPath($paths.UiData)
    $recoveryRoot = Join-Path (Split-Path -Parent $profilesDirectory) 'CodexProfilesDeleted'
    $defaultPath = [IO.Path]::GetFullPath((Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex'))
    $mutex = [Threading.Mutex]::new($false, 'Local\CodexProfilesActivate')
    $ownsMutex = $false
    try {
        # Serialize removal with the application activator and verify the instance is closed.
        try { $ownsMutex = $mutex.WaitOne(0) }
        catch [Threading.AbandonedMutexException] { $ownsMutex = $true }
        if (-not $ownsMutex) { throw 'An instance is starting. Try again after it finishes.' }

        if (-not [IO.Directory]::Exists($profileHome)) { throw 'The selected profile no longer exists.' }
        if ((Split-Path -Parent $profileHome) -ine $profilesDirectory -or
            (Split-Path -Parent $uiData) -ine $uiRoot -or
            $profileHome -ieq $uiData -or
            $profileHome.StartsWith($uiData + '\', [StringComparison]::OrdinalIgnoreCase) -or
            $uiData.StartsWith($profileHome + '\', [StringComparison]::OrdinalIgnoreCase) -or
            $profileHome -ieq $defaultPath -or $uiData -ieq $defaultPath) {
            throw 'The selected data directories do not match a removable profile.'
        }

        # Move the profile roots as directory entries. Never walk directories or follow junctions.
        foreach ($directory in @($profileHome, $uiData, $recoveryRoot)) {
            $item = Get-Item -LiteralPath $directory -Force -ErrorAction SilentlyContinue
            while ($item) {
                if ($item -isnot [IO.DirectoryInfo] -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                    throw "A profile or recovery path is not an ordinary directory: $($item.FullName)"
                }
                $item = $item.Parent
            }
        }

        foreach ($other in @(Get-CodexDesktopProfiles -ProfilesRoot $profilesDirectory)) {
            if ($other.ProfileName -ieq $paths.ProfileKey -or -not $other.SharedHome) { continue }
            $source = [IO.Path]::GetFullPath($other.SharedHome).TrimEnd('\')
            if ($source -ieq $profileHome -or $source -ieq $uiData -or
                $source.StartsWith($profileHome + '\', [StringComparison]::OrdinalIgnoreCase) -or
                $source.StartsWith($uiData + '\', [StringComparison]::OrdinalIgnoreCase)) {
                throw "This profile is the shared-space source for '$($other.ProfileName)'. Remove the dependent profile first."
            }
        }

        $trayMutex = $null
        try {
            if ([Threading.Mutex]::TryOpenExisting(('Local\CodexProfiles.Tray.' + $paths.ProfileKey), [ref]$trayMutex)) {
                throw 'Exit this profile from its tray menu before removing it.'
            }
        }
        finally { if ($trayMutex) { $trayMutex.Dispose() } }

        $sessionId = [Diagnostics.Process]::GetCurrentProcess().SessionId
        $processes = Get-CimInstance Win32_Process -Filter "(Name = 'ChatGPT.exe' OR Name = 'Codex.exe') AND SessionId = $sessionId"
        foreach ($processInfo in $processes) {
            if (-not $processInfo.CommandLine) { throw 'Could not verify that all desktop instances in this session are closed.' }
            $argument = [regex]::Match($processInfo.CommandLine, '(?i)(?:^|\s)(?:"--user-data-dir=(?<path>[^"]+)"|--user-data-dir="(?<path>[^"]+)"|--user-data-dir=(?<path>[^\s"]+))')
            if (-not $argument.Success) { continue }
            if ([IO.Path]::GetFullPath($argument.Groups['path'].Value).TrimEnd('\') -ieq $uiData) {
                throw 'Exit this profile completely, including its tray window, before removing it.'
            }
        }

        # An older enhancer can still be writing its final status after the desktop process exits.
        $statusPath = Join-Path $profileHome 'conversation-sync.json'
        $hasher = [Security.Cryptography.SHA256]::Create()
        try {
            $statusBytes = [Text.Encoding]::UTF8.GetBytes($statusPath.ToLowerInvariant())
            $statusKey = [BitConverter]::ToString($hasher.ComputeHash($statusBytes)).Replace('-', '')
        }
        finally { $hasher.Dispose() }
        $syncMutex = $null
        try {
            if ([Threading.Mutex]::TryOpenExisting(('Local\CodexProfilesConversationSync.' + $statusKey), [ref]$syncMutex)) {
                throw 'The background refresh process is still closing. Try again in a few seconds.'
            }
        }
        finally { if ($syncMutex) { $syncMutex.Dispose() } }

        $suffix = [Guid]::NewGuid().ToString('N').Substring(0, 10)
        $recoveryPath = Join-Path $recoveryRoot ($paths.ProfileKey + '-' + $suffix)
        if (-not $PSCmdlet.ShouldProcess($profileHome, "Move profile data and window data to '$recoveryPath'")) { return }

        New-Item -ItemType Directory -Path $recoveryPath | Out-Null
        $savedHome = Join-Path $recoveryPath 'home'
        $savedUi = Join-Path $recoveryPath 'ui'
        $movedUi = $false
        try {
            if ([IO.Directory]::Exists($uiData)) {
                [IO.Directory]::Move($uiData, $savedUi)
                $movedUi = $true
            }
            # Move the list entry last so a failed UI move leaves the profile available to retry.
            [IO.Directory]::Move($profileHome, $savedHome)
        }
        catch {
            $moveError = $_
            try {
                if ($movedUi) { [IO.Directory]::Move($savedUi, $uiData) }
                [IO.Directory]::Delete($recoveryPath)
            }
            catch { throw "Removal was incomplete. Check the original directories and the recovery folder at '$recoveryPath'." }
            throw $moveError
        }

        [pscustomobject]@{
            ProfileName = $paths.ProfileKey
            RecoveryPath = $recoveryPath
        }
    }
    finally {
        if ($ownsMutex) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}
