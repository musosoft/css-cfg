# Syntax/import/export and UI parameter contracts only; no network or system adapters invoked.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$core = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$files = @(Get-ChildItem -LiteralPath $core -Recurse -File | Where-Object Extension -in '.ps1','.psm1','.psd1')
foreach ($file in $files) {
    $tokens = $null; $errors = $null
    $null = [Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
    if ($errors.Count) { throw ($errors | Out-String) }
}
$manifest = Import-PowerShellDataFile (Join-Path $core 'CssCfg.Core.psd1')
Import-Module (Join-Path $core 'CssCfg.Core.psd1') -Force -DisableNameChecking
$exports = @((Get-Command -Module CssCfg.Core).Name | Sort-Object)
if (@($manifest.FunctionsToExport | Select-Object -Unique).Count -ne $manifest.FunctionsToExport.Count) { throw 'Duplicate manifest exports' }
if (Compare-Object @($manifest.FunctionsToExport | Sort-Object) $exports) { throw 'Manifest/runtime exports differ' }
$contracts = @{
    'Find-LamaTeamGame' = @('Path')
    'Get-LamaTeamPaths' = @('Game','StateRoot')
    'Get-LamaTeamConfigPreview' = @('Profile','IncludeConnect')
    'Install-LamaTeamConfig' = @('Game','Paths','Profile','ReviewedSha256')
    'Set-LamaTeamPlayerConfig' = @('Game','Paths','Profile','Tweaks','ReviewedSha256')
    'Add-LamaTeamConnect' = @('Game','Paths')
    'Get-LamaTeamMaps' = @('Game','HttpAdapter')
    'Sync-LamaTeamMaps' = @('Game','Maps','Progress','Downloader','Decompressor','ExtractorDiscovery')
    'Get-LamaTeamCleanupCandidates' = @('ServiceTaskAdapter','ProcessAdapter')
    'Apply-LamaTeamCleanup' = @('SelectedKeys','JournalPath','AcknowledgeNotRestorable')
    'Restore-LamaTeamCleanup' = @('JournalPath')
    'Get-LamaTeamCleanupRecovery' = @('JournalPath')
    'Convert-LamaTeamIntroVideo' = @('Game','Paths','OptIn','BackupExisting','BackupPath','VideoAdapter','HttpAdapter')
}
foreach ($name in $contracts.Keys) {
    $command = Get-Command $name -Module CssCfg.Core
    foreach ($parameter in $contracts[$name]) {
        if (-not $command.Parameters.ContainsKey($parameter)) { throw "Missing public contract: $name -$parameter" }
    }
}
foreach ($name in @('Apply-LamaTeamCleanup','Restore-LamaTeamCleanup')) {
    if ('RecoveryPath' -notin (Get-Command $name).Parameters['JournalPath'].Aliases) { throw "$name -RecoveryPath alias missing" }
}
foreach ($profile in @('Modern','Legacy')) {
    $preview = Get-LamaTeamConfigPreview -Profile $profile
    if ([string]::IsNullOrWhiteSpace($preview.Text) -or -not $preview.Assets[0].Content) { throw 'Preview does not contain local source text' }
}
$modernPreview = Get-LamaTeamConfigPreview -Profile Modern
if ($modernPreview.Assets.Count -ne 1 -or $modernPreview.Assets[0].Target -cne 'cfg/autoexec.cfg') { throw 'Modern config action must preview autoexec only' }
$connectPreview = Get-LamaTeamConfigPreview -Profile Modern -IncludeConnect
if (@($connectPreview.Assets | Where-Object Target -ceq 'custom/lamateam/resource/GameMenu.res').Count -ne 1 -or -not $connectPreview.ConnectAlias) { throw 'Optional connection preview must expose menu and alias' }
if ((Get-CssMapUri -Name de_contract).AbsoluteUri -cne 'https://fastdl.lamateam.eu/maps/de_contract.bsp.bz2') { throw 'Default FastDL layout contract differs from the real archive format' }
Write-Output "PASS: $($files.Count) files parsed, $($exports.Count) runtime exports match manifest, $($contracts.Count) UI contracts checked."
