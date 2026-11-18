@{
    RootModule = 'CodexProfiles.psm1'
    ModuleVersion = '0.7.0'
    GUID = '2f9f1efe-8cb4-4a25-951d-6bcb64b58010'
    Author = 'ychampion'
    CompanyName = 'ychampion'
    Copyright = '(c) ychampion'
    Description = 'Windows helpers for isolated Codex desktop profiles.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
        'Get-CodexProfilePaths',
        'Get-CodexDesktopProfiles',
        'New-CodexDesktopProfile',
        'Start-CodexDesktopProfile',
        'Start-CodexDefaultInstance',
        'Remove-CodexDesktopProfile',
        'Install-CodexDesktopProfiles'
    )
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
}
