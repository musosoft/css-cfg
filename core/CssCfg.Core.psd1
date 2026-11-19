@{
    RootModule = 'CssCfg.Core.psm1'
    ModuleVersion = '0.1.0'
    GUID = '1aef7cc5-17ad-4ae4-8af2-f65bf802b38b'
    Author = 'LamaTeam'
    Description = 'UI-independent CS:S configuration, map sync and opt-in reversible cleanup core.'
    PowerShellVersion = '7.0'
    FunctionsToExport = @(
        'Get-CssConfiguration', 'Save-CssState', 'Read-CssState', 'Get-CssGameInstall',
        'Install-CssConfig', 'Set-CssPlayerConfig', 'Add-CssServerAlias', 'Test-CssMapName', 'ConvertFrom-CssMapList',
        'Get-CssMapUri', 'Test-CssBsp', 'Sync-CssMaps', 'Find-CssFfmpeg', 'Convert-CssValveVideo',
        'Get-CssCleanupInspection', 'Invoke-CssCleanup', 'Get-CssProcessInspection', 'Invoke-CssProcessClose',
        'Get-LamaTeamPaths', 'Find-LamaTeamGame', 'Get-LamaTeamConfigPreview', 'Install-LamaTeamConfig', 'Set-LamaTeamPlayerConfig', 'Save-LamaTeamConfigText',
        'Add-LamaTeamConnect', 'Get-LamaTeamMaps', 'Sync-LamaTeamMaps', 'Get-LamaTeamCleanupCandidates',
        'Apply-LamaTeamCleanup', 'Restore-LamaTeamCleanup', 'Get-LamaTeamCleanupRecovery', 'Convert-LamaTeamIntroVideo',
        'Get-CssVdfApp240Section', 'Get-CssSteamLaunchOptionsFromText', 'Resolve-CssSteamUserConfig',
        'Get-CssSteamLaunchOptions', 'Set-CssSteamLaunchOptions', 'Get-CssDisplayRefreshInfo', 'Set-CssDisplayRefreshRate'
    )
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
}
