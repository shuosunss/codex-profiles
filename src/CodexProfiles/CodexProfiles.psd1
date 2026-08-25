@{
    RootModule = 'CodexProfiles.psm1'
    ModuleVersion = '0.1.0'
    GUID = '2f9f1efe-8cb4-4a25-951d-6bcb64b58010'
    Author = 'ychampion'
    CompanyName = 'ychampion'
    Copyright = '(c) ychampion'
    Description = 'Windows helpers for isolated Codex desktop profiles.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
        'Get-CodexProfilePaths',
        'New-CodexDesktopProfile',
        'Start-CodexDesktopProfile',
        'Install-CodexDesktopProfiles'
    )
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
}
