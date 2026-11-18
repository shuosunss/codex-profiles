[CmdletBinding()]
param(
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '../../dist'),
    [string]$SidebarSource = (Join-Path $PSScriptRoot '../../../codex-sidebar-usage/src')
)

$ErrorActionPreference = 'Stop'
$projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$outputRoot = [IO.Path]::GetFullPath($OutputDirectory)
$buildRoot = Join-Path $projectRoot 'build'
$compiler = Join-Path $env:SystemRoot 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
if (-not [IO.File]::Exists($compiler)) {
    $compiler = Join-Path $env:SystemRoot 'Microsoft.NET/Framework/v4.0.30319/csc.exe'
}
if (-not [IO.File]::Exists($compiler)) { throw 'The Windows .NET Framework C# compiler was not found.' }

New-Item -ItemType Directory -Path $outputRoot, $buildRoot -Force | Out-Null
$binRoot = Join-Path $projectRoot 'bin'
New-Item -ItemType Directory -Path $binRoot -Force | Out-Null
# The background enhancer reuses the reference project's local protocol implementation.
$syncRoot = Join-Path $projectRoot 'src/ConversationSync'
$syncInputs = @('Protocol.cs', 'BackgroundSync.cs', 'SharedProjectSnapshot.cs', 'conversation-sync.js', 'project-sync.js') | ForEach-Object {
    (Get-FileHash -LiteralPath (Join-Path $syncRoot $_) -Algorithm SHA256).Hash
}
$hash = [Security.Cryptography.SHA256]::Create()
try {
    $syncVersion = [BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes(($syncInputs -join '')))).Replace('-', '').Substring(0, 16).ToLowerInvariant()
}
finally { $hash.Dispose() }
# Content-addressed helper files allow rebuilding while an earlier enhancer is still running.
$syncName = 'ConversationSync-' + $syncVersion + '.exe'
$syncExePath = Join-Path $binRoot $syncName
$syncArguments = @(
    '/nologo', '/target:winexe', '/platform:anycpu', '/optimize+',
    ('/out:' + $syncExePath),
    '/reference:System.Web.Extensions.dll',
    ('/resource:' + (Join-Path $syncRoot 'conversation-sync.js') + ',conversation-sync.js'),
    ('/resource:' + (Join-Path $syncRoot 'project-sync.js') + ',project-sync.js'),
    (Join-Path $syncRoot 'Protocol.cs'),
    (Join-Path $syncRoot 'SharedProjectSnapshot.cs'),
    (Join-Path $syncRoot 'BackgroundSync.cs')
)
if (-not [IO.File]::Exists($syncExePath)) {
    & $compiler @syncArguments
    if ($LASTEXITCODE -ne 0) { throw 'Background enhancer compilation failed.' }
}
[IO.File]::WriteAllText((Join-Path $binRoot 'ConversationSync.current'), $syncName, [Text.UTF8Encoding]::new($false))

# Embed the same Windows shell implementation that the standalone side enhancer uses.
$sidebarRoot = [IO.Path]::GetFullPath($SidebarSource)
$shellInputs = Get-ChildItem -LiteralPath $sidebarRoot -File | Sort-Object Name | ForEach-Object {
    (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
}
$hash = [Security.Cryptography.SHA256]::Create()
try {
    $shellVersion = [BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes((($shellInputs + $syncInputs) -join '')))).Replace('-', '').Substring(0, 16).ToLowerInvariant()
}
finally { $hash.Dispose() }
$shellName = 'ProfileShell-' + $shellVersion + '.exe'
$shellExePath = Join-Path $binRoot $shellName
if (-not [IO.File]::Exists($shellExePath)) {
    & (Join-Path $sidebarRoot 'build.ps1') -OutputPath $shellExePath -SyncSource $syncRoot | Out-Null
}
[IO.File]::WriteAllText((Join-Path $binRoot 'ProfileShell.current'), $shellName, [Text.UTF8Encoding]::new($false))
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$runtimeZip = Join-Path $buildRoot ('runtime-' + [Guid]::NewGuid().ToString('N') + '.zip')

# Only runtime source files are embedded, excluding profile data, credentials, and build products.
$runtimeFiles = @(
    'src/CodexProfiles/CodexProfiles.psm1',
    'src/CodexProfiles/CodexProfiles.psd1',
    'src/CodexProfiles/ProfileSpace.ps1',
    'src/CodexProfiles/RemoveProfile.ps1',
    'src/CodexProfiles/ConversationSync.ps1',
    'src/CodexProfiles/ProfileShell.ps1',
    'src/CodexProfiles/Sync-WindowsSandbox.ps1',
    'bin/ConversationSync.exe',
    'bin/ProfileShell.exe',
    'scripts/windows/Show-CodexProfiles.ps1',
    'scripts/windows/Start-CodexDesktopProfile.ps1',
    'scripts/windows/New-CodexDesktopProfile.ps1'
)
$archive = [IO.Compression.ZipFile]::Open($runtimeZip, 'Create')
try {
    foreach ($relativePath in $runtimeFiles) {
        $sourcePath = Join-Path $projectRoot $relativePath
        if ($relativePath -eq 'bin/ConversationSync.exe') { $sourcePath = $syncExePath }
        if ($relativePath -eq 'bin/ProfileShell.exe') { $sourcePath = $shellExePath }
        [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $sourcePath, $relativePath, 'Optimal') | Out-Null
    }
}
finally { $archive.Dispose() }

$exePath = Join-Path $outputRoot 'CodexProfiles.exe'
$frameworkDirectory = Split-Path -Parent $compiler
$automationAssembly = Join-Path $env:SystemRoot 'Microsoft.NET/assembly/GAC_MSIL/System.Management.Automation/v4.0_3.0.0.0__31bf3856ad364e35/System.Management.Automation.dll'
if (-not [IO.File]::Exists($automationAssembly)) { throw 'Windows PowerShell 5.1 is required.' }
$compilerArguments = @(
    '/nologo', '/target:winexe', '/platform:anycpu', '/optimize+',
    ('/out:' + $exePath),
    ('/resource:' + $runtimeZip + ',CodexProfiles.Runtime.zip'),
    '/reference:System.Windows.Forms.dll',
    ('/reference:' + $automationAssembly),
    ('/reference:' + (Join-Path $frameworkDirectory 'System.IO.Compression.dll')),
    ('/reference:' + (Join-Path $frameworkDirectory 'System.IO.Compression.FileSystem.dll')),
    (Join-Path $projectRoot 'src/Launcher/Program.cs')
)
try {
    & $compiler @compilerArguments
    if ($LASTEXITCODE -ne 0) { throw 'C# compilation failed.' }
}
finally { [IO.File]::Delete($runtimeZip) }
Get-Item -LiteralPath $exePath | Select-Object FullName, Length
