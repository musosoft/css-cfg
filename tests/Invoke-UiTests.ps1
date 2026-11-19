# Headless UI action harness: extract only view functions, replace all adapters,
# dialogs and rendering. No WinUIShell, game writes, network or OS mutations.
param([switch]$CleanupOnly)

$ErrorActionPreference = 'Stop'
$app = Join-Path $PSScriptRoot '../LamaTeam.App.ps1'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($app, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
$functions = @(
    'Invoke-LTAction', 'Update-LTCleanupSelection',
    'Assert-LTGame', 'Get-LTPath',
    'Get-LTReviewedLegacyHash', 'Test-LTLegacySource',
    'Update-LTMapOutcomes', 'Format-LTValue', 'Show-LTResult'
    'Get-LTCleanupView', 'Invalidate-LTCleanupCandidates',
    'Get-LTCandidatePreferenceKey', 'Save-LTPreferences'
    'Get-LTLamaStartupOptions', 'Update-LTStartupOptions'
    'Update-LTMapCount'
)
foreach ($node in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    if ($node.Name -in $functions) { Invoke-Expression $node.Extent.Text }
}
function Assert($Value, [string]$Message) { if (-not $Value) { throw $Message } }
function Text { [pscustomobject]@{ Text = '' } }
function Reset-View {
    $script:Calls = [Collections.Generic.List[object]]::new()
    $script:Confirmations = [Collections.Generic.List[object]]::new()
    $script:Accept = $true
    $script:AdapterThrows = $false
    $script:SyncMapStatus = 'Installed'
    $script:SteamIsRunning = $false
    $script:LTUi = @{
        Busy = $false; Game = @{ Root = '/test/game' }
        Paths = @{
            MapsDirectory = '/test/maps'; ConfigPath = '/test/autoexec.cfg'
            ConfigBackupPath = '/test/backup.cfg'; BackupDirectory = '/test'
            ConnectPath = '/test/autoexec.cfg'; ConnectBackupPath = '/test/connect.backup'
            GameMenuPath = '/test/menu.res'; GameMenuBackupPath = '/test/menu.backup'
            IntroSourcePath = '/test/media/valve.bik'
            IntroTargetPath = '/test/media/valve.webm'
            IntroBackupPath = '/test/media/valve.webm.backup'
            ConverterPath = '/test/tools/ffmpeg'
        }
        Buttons = @(
            [pscustomobject]@{ Tag = 'Play'; Content = ''; IsEnabled = $false },
            [pscustomobject]@{ Tag = 'Restore'; Content = ''; IsEnabled = $false }
        )
        Candidates = @(); Maps = @(); MapTarget = $null; MapErrors = @{}; MapSelections = @{}; MapViews = @{}
        MapProgress = [pscustomobject]@{ IsIndeterminate = $false; Value = 0 }
         MapText = (Text)
        CleanupOutcomes = (Text); CleanupScanStatus = (Text)
        RecoveryText = (Text); Profile = @{ SelectedIndex = 0 }
         UseConfig = @{ IsChecked = $false }; AutoMaps = @{ IsChecked = $false; Content = '' }
         TweakChecks = [ordered]@{}; ValidateIntegrity = @{ IsChecked = $false }
         StartupOptions = @{ Text = '' }
         SteamSettings = @{ ConfigPath = '/test/localconfig.vdf'; Options = '' }
         SteamSettingsError = ''; CurrentStartupOptions = ''; DisplayModes = @()
         MonitorDeviceName = ''; MonitorMaxRefreshRate = @{ IsChecked = $false }
        ConnectCheck = @{ IsChecked = $false }; SetupResult = (Text)
        VideoOptIn = @{ IsChecked = $false }
        RestoreEligible = $false; LegacyReview = $null; OperationLabel = 'Operation'
        CleanupScanned = $false; CleanupNeedsScan = $false; CleanupItems = @(); CleanupSubsystems = @()
        PreferencePath = '/test/preferences.json'; Preferences = @{ Cleanup = @() }
        GamePath = @{ Text = '/test/game' }; MapSearch = @{ Text = '' }; ResultText = (Text)
    }
    $script:SavedPreferences = $null
    $script:Launches = [Collections.Generic.List[string]]::new()
}
function Invoke-LTAdapter($Name, $Arguments = @{}) {
    if ($Name -eq 'Get-LamaTeamPaths') { return $script:LTUi.Paths }
    $script:Calls.Add(@{ Name = $Name; Arguments = $Arguments })
    if ($script:AdapterThrows) { throw 'Mock adapter unavailable' }
    if ($Name -eq 'Get-LamaTeamMaps') {
        @([pscustomobject]@{ Name = 'missing'; Status = 'Missing' })
    } elseif ($Name -eq 'Sync-LamaTeamMaps') {
        foreach ($map in $Arguments.Maps) {
            [pscustomobject]@{ Name = $map.Name; Status = $script:SyncMapStatus; Error = $(if ($script:SyncMapStatus -eq 'Failed') { 'network' }) }
        }
    } elseif ($Name -eq 'Apply-LamaTeamCleanup') {
        [pscustomobject]@{ Status = 'Succeeded'; Items = @() }
    } else { [pscustomobject]@{ Status = 'Changed'; Items = @() } }
}
function Save-CssState($Path, $State) { $script:SavedPreferences = $State }
function Start-Process($Uri) { $script:Launches.Add([string]$Uri) }
function Get-CssSteamLaunchOptions($ConfigPath) { [pscustomobject]@{ ConfigPath=$ConfigPath; Options=[string]$script:LTUi.CurrentStartupOptions } }
function Set-CssSteamLaunchOptions($ConfigPath, $Options) {
    $script:LTUi.CurrentStartupOptions = $Options
    [pscustomobject]@{ Changed=$true; Backup='/test/localconfig.bak'; ConfigPath=$ConfigPath }
}
function Test-LTSteamRunning { return $script:SteamIsRunning }
function Set-CssDisplayRefreshRate($DeviceName, $RefreshRate) { [pscustomobject]@{ Changed=$true; CurrentHz=$RefreshRate; MaxHz=$RefreshRate } }
function Confirm-LTAction($Title, $Body, $Accept) {
    $script:Confirmations.Add(@{ Title = $Title; Body = $Body })
    return $script:Accept
}
function Show-LTMapRows {}
function Show-LTCleanupRows {}
function Add-LTOperation($Summary) { $script:OperationSummary = $Summary }
function Write-LTStatus($Text) { $script:LastStatus = $Text }
function Get-LTConfigEditorText { 'editable config' }
function Update-LTRecovery { $script:LTUi.Recovery = $script:RecoveryRecord }
function Candidate($Key, $Kind, $Checked = $false, $Enabled = $true) {
    @{ Row = @{ Key = $Key; Name = "Name-$Key"; Kind = $Kind; Eligible = $Enabled }
       Check = [pscustomobject]@{ IsChecked = $Checked; IsEnabled = $Enabled }
       Outcome = (Text) }
}

if (-not $CleanupOnly) {
Reset-View
$script:LTUi.UseConfig.IsChecked = $true
$script:LTUi.Profile.SelectedIndex = 0
Invoke-LTAction 'Play'
Assert ($script:Calls[0].Name -eq 'Set-LamaTeamPlayerConfig') 'Play applies selected preset'
Assert ($script:Calls[0].Arguments.Profile -eq 'Modern') 'Modern profile forwarded to config adapter'
Assert ($script:Confirmations[0].Body.Contains('/test/autoexec.cfg')) 'Play confirms config destination'
Assert ($script:Launches.Count -eq 1) 'Play launches after applying selected config'

Reset-View
$script:LTUi.UseConfig.IsChecked = $true
$script:LTUi.Profile.SelectedIndex = 1
$script:LTUi.Paths.LegacyAssetAvailable = $true
$script:LTUi.Paths.LegacyAssetPath = '/test/legacy.cfg'
$script:LTUi.Paths.LegacySourceYear = 2016
Invoke-LTAction 'Play'
Assert ($script:Calls.Count -eq 0 -and $script:Launches.Count -eq 0) 'Unreviewed Legacy must never install or launch'
$hash = 'a' * 64
$script:LTUi.LegacyReview = @{ Profile = 'Legacy'; ReviewSha256 = $hash; ConfigPath = '/test/autoexec.cfg'; SourcePath = '/test/legacy.cfg' }
Invoke-LTAction 'Play'
Assert ($script:Calls[0].Arguments.ReviewedSha256 -ceq $hash) 'Exact reviewed Legacy hash must pass unchanged'
Assert ($script:Launches.Count -eq 1) 'Reviewed Legacy preset can then launch'
}

Reset-View
$script:LTUi.Candidates = @((Candidate p1 Process), (Candidate s1 Service $true))
Update-LTCleanupSelection
Assert ($script:LTUi.Candidates.Count -eq 2) 'Cleanup candidates remain grouped in one form without a selection count'
Assert ($script:LTUi.Buttons[0].IsEnabled) 'Play remains available for selected candidates'
$script:LTUi.Candidates[0].Check.IsChecked = $true
Update-LTCleanupSelection
Assert ($script:LTUi.Candidates.Count -eq 2) 'Mixed cleanup candidates remain available after selection changes'

if (-not $CleanupOnly) {
Reset-View
$script:LTUi.Maps = @(
    [pscustomobject]@{ Name = 'present'; Status = 'Installed' },
    [pscustomobject]@{ Name = 'one'; Status = 'Missing' },
    [pscustomobject]@{ Name = 'two'; Status = 'Failed' }
)
$script:LTUi.MapTarget = 'one'
Invoke-LTAction 'Maps'
Assert ($script:Calls[0].Arguments.Maps.Count -eq 1 -and $script:Calls[0].Arguments.Maps[0].Name -eq 'one') 'Per-map download is exact'
Assert ($script:LTUi.Maps[0].Status -eq 'Installed') 'Installed map preserved'
Assert ($script:LTUi.Maps[1].Status -eq 'Installed') 'Adapter outcome updates row'
Update-LTMapOutcomes @([pscustomobject]@{ Name = 'two'; Status = 'Failed'; Error = 'test failure' })
Assert ($script:LTUi.MapErrors.two -eq 'test failure') 'Per-map failure retained'
$script:Calls.Clear()
$script:LTUi.MapTarget = $null
$script:LTUi.MapSelections = @{ two = $true }
$script:LTUi.MapViews = @{ two = @{
    Check = @{ IsChecked = $true }; Status = (Text)
    Progress = [pscustomobject]@{ IsIndeterminate = $false; Value = 0 }
} }
Invoke-LTAction 'MapsSelected'
Assert ($script:Calls[0].Arguments.Maps[0].Name -eq 'two') 'Selected visible maps scoped exactly'

Reset-View
$script:RecoveryRecord = @{ Items = @(
    @{ Item = @{ Kind = 'Process'; Name = 'app'; Key = 'p' }; Status = 'Changed' },
    @{ Item = @{ Kind = 'Service'; Name = 'uncertain'; Key = 's' }; Status = 'Pending' }
) }
Invoke-LTAction 'Restore'
Assert ($script:Calls.Count -eq 0) 'Processes and pending entries cannot restore'
$script:RecoveryRecord.Items += @{ Item = @{ Kind = 'Task'; Name = 'eligible'; Key = 't' }; Status = 'Changed' }
Invoke-LTAction 'Restore'
Assert ($script:Calls[0].Name -eq 'Restore-LamaTeamCleanup') 'Journal restore adapter retained'
Assert ($script:Confirmations[0].Body.Contains('[t]') -and -not $script:Confirmations[0].Body.Contains('[p]') -and -not $script:Confirmations[0].Body.Contains('[s]')) 'Restore confirms eligible exact targets only'

Reset-View
$script:LTUi.VideoOptIn = @{ IsChecked = $true }
Invoke-LTAction 'Video'
Assert ($script:Calls.Count -eq 1 -and $script:Calls[0].Name -eq 'Convert-LamaTeamIntroVideo') 'Video adapter is called'
Assert ($script:Calls[0].Arguments.OptIn) 'Explicit video opt-in reaches adapter'
Assert ($script:Calls[0].Arguments.BackupExisting -and $script:Calls[0].Arguments.BackupPath -ceq '/test/media/valve.webm.backup') 'Existing WebM is automatically backed up at exact planned path'
}

Reset-View
$script:LTUi.Candidates = @((Candidate result Service))
Show-LTResult ([pscustomobject]@{ Status = 'Partial'; Items = @(
    [pscustomobject]@{ Item = @{ Key = 'result'; Name = 'Result' }; Status = 'Failed'; Error = 'Denied' }
) })
Assert ($script:LTUi.Candidates[0].Outcome.Text -eq 'Failed: Denied') 'Inline per-item outcome'
Assert ($script:OperationSummary -eq 'Operation · Partial') 'Operation history uses adapter outcome'
Assert (-not $script:LTUi.Busy) 'Actions release busy state'

# Cleanup view boundaries are tested without loading any native UI types.
Reset-View
Assert ((Get-LTCleanupView).State -eq 'NotScanned') 'Initial state is not an empty scan'
$script:LTUi.CleanupScanned = $true
Assert ((Get-LTCleanupView).State -eq 'Unavailable') 'Missing subsystem is unavailable'
$script:LTUi.CleanupSubsystems = @(@{ Kind = 'Process'; Available = $false; Error = 'Inspection denied' })
Assert ((Get-LTCleanupView).Message.Contains('Inspection denied')) 'Unavailable reason retained'
$script:LTUi.CleanupSubsystems[0].Available = $true
Assert ((Get-LTCleanupView).State -eq 'Empty') 'Available empty subsystem'
$script:LTUi.CleanupItems = @(
    @{ Kind = 'Process'; Name = 'Player'; Publisher = 'Example Publisher'; State = 'Running' },
    @{ Kind = 'Service'; Name = 'Other category'; Publisher = 'Example Publisher'; State = 'Running' }
)
$view = Get-LTCleanupView
Assert ($view.State -eq 'Ready' -and $view.Rows.Count -eq 2) 'All eligible cleanup categories appear together'
$script:LTUi.CleanupNeedsScan = $true
Assert ((Get-LTCleanupView).State -eq 'Stale') 'Invalidated scan requires fresh discovery'

Reset-View
$script:LTUi.Candidates = @((Candidate p1 Process $true), (Candidate s1 Service $true), (Candidate t1 Task $true))
$script:LTUi.CleanupScanStatus = Text
$script:LTUi.AutoMaps.IsChecked = $true
Update-LTMapCount @([pscustomobject]@{ Status = 'Missing' }, [pscustomobject]@{ Status = 'Installed' })
Assert ($script:LTUi.AutoMaps.Content -eq 'Automatically download 1 missing maps') 'Auto-map label displays live missing-map count'
Invoke-LTAction 'Play'
Assert ($script:Calls[0].Name -eq 'Get-LamaTeamMaps') 'Auto-map selection scans missing maps'
Assert ($script:Calls[1].Name -eq 'Sync-LamaTeamMaps') 'Auto-map selection downloads before cleanup'
Assert ($script:Calls[2].Name -eq 'Apply-LamaTeamCleanup') 'Play applies mixed selected cleanup in one adapter call'
Assert ($script:Calls[2].Arguments.SelectedKeys.Count -eq 3) 'Play preserves exact selected cleanup keys'
Assert $script:Calls[2].Arguments.AcknowledgeNotRestorable 'Mixed process cleanup requires explicit process acknowledgement'
Assert ($script:Confirmations[0].Body.Contains('Process: Name-p1') -and $script:Confirmations[0].Body.Contains('Service: Name-s1') -and $script:Confirmations[0].Body.Contains('Task: Name-t1')) 'One confirmation names every selected target'
Assert ($script:Launches[0] -eq 'steam://connect/82.208.17.101:27516') 'Steam launch follows selected setup actions'

Reset-View
$script:LTUi.TweakChecks = [ordered]@{
    fps_max_300 = [pscustomobject]@{ IsChecked = $true }
    m_rawinput = [pscustomobject]@{ IsChecked = $false }
}
Invoke-LTAction 'Play'
Assert ($script:Calls[0].Name -eq 'Set-LamaTeamPlayerConfig') 'Individual tweaks use the guarded config writer'
Assert ($script:Calls[0].Arguments.Tweaks.Count -eq 1 -and $script:Calls[0].Arguments.Tweaks[0] -eq 'fps_max_300') 'Only checked individual tweaks are written'
Assert (-not $script:Calls[0].Arguments.ContainsKey('Profile')) 'Tweaks do not force a config preset'

Reset-View
$script:LTUi.StartupOptions.Text = '-console -novid'
Invoke-LTAction 'Play'
Assert ($script:LTUi.CurrentStartupOptions -eq '-console -novid') 'Validated startup options are saved to Steam'
Assert ($script:Launches[0] -eq 'steam://connect/82.208.17.101:27516') 'Steam options persist before server connect'
Assert ((Get-LTLamaStartupOptions -Base '-windowed -novid' -IncludeLamaDefaults) -ceq '-windowed -novid -nojoy') 'LamaTeam preset preserves current options and adds only missing flags'
Assert ((Get-LTLamaStartupOptions -Base '-windowed -refresh 60 -novid' -RefreshRate 144) -ceq '-windowed -novid -refresh 144') 'Maximum refresh replaces any prior refresh launch option'

Reset-View
$script:LTUi.ValidateIntegrity.IsChecked = $true
Invoke-LTAction 'Play'
Assert ($script:Calls.Count -eq 0) 'Integrity validation blocks apply/play actions'
Assert ($script:Launches.Count -eq 1 -and $script:Launches[0] -eq 'steam://validate/240') 'Integrity request opens Steam validation'
Assert (-not $script:LTUi.ValidateIntegrity.IsChecked) 'Validation request clears the validation choice'
Invoke-LTAction 'Play'
Assert ($script:Launches.Count -eq 2 -and $script:Launches[1] -eq 'steam://connect/82.208.17.101:27516') 'Apply and play must be pressed again after validation completes'

Reset-View
$script:LTUi.StartupOptions.Text = '-console & shutdown'
Invoke-LTAction 'Play'
Assert ($script:LTUi.CurrentStartupOptions -eq '-console & shutdown') 'VDF persistence treats launch options as data, not shell commands'

Reset-View
$script:SteamIsRunning = $true
$script:LTUi.StartupOptions.Text = '-novid -nojoy'
Invoke-LTAction 'Play'
Assert ($script:LTUi.CurrentStartupOptions -eq '-novid -nojoy') 'launch options update while Steam is already running'
Assert ($script:Launches.Count -eq 1 -and $script:Launches[0] -eq 'steam://connect/82.208.17.101:27516') 'running Steam does not block the requested game launch'

Reset-View
$script:LTUi.AutoMaps.IsChecked = $true
$script:SyncMapStatus = 'Failed'
Invoke-LTAction 'Play'
Assert ($script:Launches.Count -eq 0) 'Failed automatic map download blocks launch'
Assert ($script:Calls.Count -eq 2) 'Map failure stops later modifications'

Reset-View
$script:LTUi.Candidates = @((Candidate p1 Process $true))
$script:LTUi.ValidateIntegrity.IsChecked = $true
$script:LTUi.StartupOptions.Text = '-novid -console'
Save-LTPreferences
Assert ($script:SavedPreferences.Cleanup.Count -eq 1) 'Preferences persist cleanup intent'
Assert ($script:SavedPreferences.Cleanup[0] -eq (Get-LTCandidatePreferenceKey $script:LTUi.Candidates[0].Row)) 'Cleanup preference uses stable app identity, not process id'
Assert ($script:SavedPreferences.ValidateIntegrity -and $script:SavedPreferences.StartupOptions -eq '-novid -console') 'Integrity choice and startup options persist'
if ($CleanupOnly) {
    Write-Output 'PASS: UI parsed; mocked compact cleanup selection and mixed-category play action. Native rendering not exercised.'
} else {
    Write-Output 'PASS: UI parsed; mocked config, Legacy, mixed cleanup, maps, recovery, preferences and play boundaries checked. Native rendering not exercised.'
}
