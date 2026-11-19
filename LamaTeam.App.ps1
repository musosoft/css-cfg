#Requires -Version 7.4
using namespace WinUIShell
using namespace WinUIShell.Microsoft.UI.Xaml
using namespace WinUIShell.Microsoft.UI.Xaml.Controls
using namespace WinUIShell.Microsoft.UI.Xaml.Media
using namespace WinUIShell.Microsoft.UI.Text
using namespace WinUIShell.Windows.UI
using namespace WinUIShell.Windows.UI.Core
using namespace WinUIShell.Windows.System
using namespace WinUIShell.Microsoft.UI.Input

<#
Dot-source, load the operation adapters, then call Start-LamaTeamApp. No bootstrap.
UI targets WinUIShell 0.14.0; adapters are deliberately separate from this view.
Expected adapter boundary (parent integration must reconcile with the core):
  Find-LamaTeamGame -Path <optional string> => game object
  Get-LamaTeamPaths -Game <object> => Root, ConfigPath, ConnectPath, BackupDirectory,
    ConfigBackupPath, ConnectBackupPath, GameMenuPath, GameMenuBackupPath,
    MapsDirectory, MediaDirectory, RecoveryPath,
    IntroSourcePath, IntroTargetPath, IntroBackupPath, ConverterPath (absolute paths).
    Backup paths are the actual planned destinations, not UI-generated names.
    LegacyAssetAvailable (boolean) + LegacyAssetPath + LegacySourceYear = 2016
    confirm the 2016 historical source; otherwise Legacy is unavailable.
    Legacy provenance: core/assets/Legacy-2016/autoexec.cfg, commit 22604b7
    (2016-07-17). Historical identity is not a compatibility guarantee.
    IntroTargetBackupPermitted is false by default; replacing an existing target
    always creates a backup at the exact BackupPath below.
    ConverterPath is detected when present; FFmpeg provisioning remains app-local and hash-pinned.
  Install-LamaTeamConfig -Game <object> -Paths <object> -Profile Modern|Legacy
    Legacy additionally requires -ReviewedSha256 <exact preview ReviewSha256>.
  Get-LamaTeamConfigPreview -Profile Modern|Legacy => read-only text, or object
    with Text (full content) and Files (source file names).
    Modern previews the CS:S autoexec only. The optional Add-LamaTeamConnect
    operation adds both the lama alias and GameMenu.res, with separate backups.
    This inspection adapter must not modify game files or install anything.
    Legacy returns Profile, ReviewSha256, Warnings, SourceYear, SourceCommit;
    preserve the exact hash only after its contents/metadata render successfully.
  Add-LamaTeamConnect -Game <object> -Paths <object>
  Get-LamaTeamMaps -Game <object> => rows: Name, Status
  Sync-LamaTeamMaps -Game <object> -Maps <rows[]> -Progress <scriptblock>
    Progress receives a display-safe record: Name, Status, Completed, Total, Error.
  Get-LamaTeamCleanupCandidates => Items, Subsystems; rows: Key, Kind (Process/Service/Task),
    Name, Details, Eligible (explicit boolean), Risk (otherwise shown as Unknown),
    Publisher, Path; services: DisplayName, State, Startup; tasks: TaskPath, State.
    Processes receive graceful CloseMainWindow requests only, never force-kill.
  Apply-LamaTeamCleanup -SelectedKeys <string[]> => Status, Items, Error
    -AcknowledgeNotRestorable (only after confirmation of selected process closure)
  Restore-LamaTeamCleanup -RecoveryPath <string> => Status, Items, Error
  Get-LamaTeamCleanupRecovery -RecoveryPath <string> => Exists, Status, Items, Error
  Convert-LamaTeamIntroVideo -Game <object> -Paths <object> -OptIn
    -BackupExisting -BackupPath <exact planned path>
Mutation adapters return display-safe per-item outcomes, including partial failures.
UI never infers success counts.
Calls are synchronous: no cancellation or background execution is promised here.
#>
# Cleanup envelopes: scan {Items,Subsystems[{Kind,Available,Error}]}; mutation
# {Status,Items,Error}; Get-LamaTeamCleanupRecovery {Exists,Status,Items,Error}.
# Cleanup and recovery use the adapters' default journal, independently of CS:S.

function New-LTText([string]$Text, [string]$Style = 'BodyTextBlockStyle') {
    $control = [TextBlock]::new()
    $control.Text = $Text
    $control.TextWrapping = 'Wrap'
    $control.Style = [Application]::Current.Resources[$Style]
    return $control
}

function Add-LTAction($Panel, [string]$Text, [string]$Action, [switch]$Primary) {
    $button = [Button]::new()
    $button.Content = $Text
    $button.Tag = $Action
    if ($Primary) { $button.Style = [Application]::Current.Resources['AccentButtonStyle'] }
    $button.AddClick({
        param($argumentList, $sender, $eventArgs)
        Invoke-LTAction ([string]$sender.Tag)
    })
    $Panel.Children.Add($button)
    $script:LTUi.Buttons.Add($button)
}

function New-LTActionRow($Panel) {
    $row = [StackPanel]::new()
    $row.Orientation = 'Horizontal'
    $row.Spacing = 8
    $Panel.Children.Add($row)
    return $row
}

function Add-LTDisclosure($Panel, [string]$Title, $Content) {
    $expander = [Expander]::new()
    $expander.Header = $Title
    $expander.Content = $Content
    $expander.HorizontalAlignment = 'Stretch'
    $Panel.Children.Add($expander)
    return $expander
}

function Show-LTMapRows {
    foreach ($button in $script:LTUi.MapButtons) { $null = $script:LTUi.Buttons.Remove($button) }
    $script:LTUi.MapButtons = @()
    $script:LTUi.MapRows.Items.Clear()
    $script:LTUi.MapViews = @{}
    $query = $script:LTUi.MapSearch.Text.Trim()
    foreach ($map in $script:LTUi.Maps) {
        if ($query -and $map.Name.IndexOf($query, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
        $row = [StackPanel]::new()
        $row.Orientation = 'Horizontal'
        $row.Spacing = 8
        $script:LTUi.MapRows.Items.Add($row)
        $name = Add-LTCheck $row $map.Name
        $name.IsEnabled = $map.Status -in @('Missing', 'Failed')
        $name.Width = 240
        $name.Tag = $map.Name
        $name.IsChecked = ($script:LTUi.MapSelections.ContainsKey($map.Name))
        $name.AddChecked({
            param($argumentList, $sender, $eventArgs)
            $script:LTUi.MapSelections[[string]$sender.Tag] = $true
            Save-LTPreferences
        })
        $name.AddUnchecked({
            param($argumentList, $sender, $eventArgs)
            $null = $script:LTUi.MapSelections.Remove([string]$sender.Tag)
            Save-LTPreferences
        })
        $state = New-LTText "$($map.Status)$(if ($script:LTUi.MapErrors[$map.Name]) { ": $($script:LTUi.MapErrors[$map.Name])" })"
        $state.Width = 180
        $row.Children.Add($state)
        $progress = [ProgressBar]::new()
        $progress.Width = 100
        $progress.Maximum = 100
        if ($map.Status -eq 'Installed') { $progress.Value = 100 }
        $row.Children.Add($progress)
        if ($map.Status -in @('Missing', 'Failed')) {
            $download = [Button]::new()
            $download.Content = 'Download'
            $download.Tag = $map.Name
            $download.AddClick({
                param($argumentList, $sender, $eventArgs)
                $script:LTUi.MapTarget = [string]$sender.Tag
                try { Invoke-LTAction 'Maps' } finally { $script:LTUi.MapTarget = $null }
            })
            $row.Children.Add($download)
            $script:LTUi.Buttons.Add($download)
            $script:LTUi.MapButtons += $download
        }
        $script:LTUi.MapViews[$map.Name] = @{ Status = $state; Progress = $progress; Check = $name }
    }
    if (-not $script:LTUi.MapRows.Items.Count) {
        $script:LTUi.MapRows.Items.Add((New-LTText 'No maps to show. Check maps or change the filter.'))
    }
}

function Update-LTMapOutcomes($Results) {
    foreach ($result in @($Results)) {
        foreach ($map in $script:LTUi.Maps) {
            if ($map.Name -ceq $result.Name) {
                if ($result.Status -in @('Installed', 'Skipped')) { $map.Status = 'Installed' }
                elseif ($result.Status -eq 'Failed') { $map.Status = 'Failed' }
                $script:LTUi.MapErrors[$map.Name] = [string]$result.Error
                if ($result.Status -in @('Installed', 'Skipped')) { $null = $script:LTUi.MapSelections.Remove($map.Name) }
            }
        }
    }
    Save-LTPreferences
}

function Add-LTOperation([string]$Summary) {
    if ($script:LTUi.ResultText) { $script:LTUi.ResultText.Text = $Summary }
}

function Format-LTValue($Value) {
    if ([string]::IsNullOrWhiteSpace([string]$Value)) { return 'Not available' }
    return [string]$Value
}

function Test-LTLegacySource {
    $paths = $script:LTUi.Paths
    return ($paths -and $paths.LegacyAssetAvailable -eq $true -and
        $paths.LegacyAssetPath -and [string]$paths.LegacySourceYear -eq '2016')
}

function Get-LTReviewedLegacyHash {
    $review = $script:LTUi.LegacyReview
    if (-not $review -or $script:LTUi.Profile.SelectedIndex -ne 1 -or
        $review.Profile -cne 'Legacy' -or
        $review.ConfigPath -cne [string]$script:LTUi.Paths.ConfigPath -or
        $review.SourcePath -cne [string]$script:LTUi.Paths.LegacyAssetPath) {
        throw 'Preview Legacy and read its warnings before installing. The preview must match this game folder.'
    }
    return $review.ReviewSha256
}

function Update-LTPreview {
    $paths = $script:LTUi.Paths
    $script:LTUi.LocationStatus.Text = 'CS:S detected'
    $confirmed = Test-LTLegacySource
    $script:LTUi.LegacyOption.Content = 'Rivals.cz Legacy PC'
    $script:LTUi.LegacyOption.IsEnabled = [bool]$confirmed
    $script:LTUi.LegacyStatus.Text = if ($confirmed) {
        "Legacy ($($paths.LegacySourceYear)): historical config, not guaranteed compatible."
    } else { 'Legacy source unavailable.' }
    $script:LTUi.IntroPreview.Text = if ($paths.ConverterPath) { 'FFmpeg ready. Original video stays unchanged.' } else { 'FFmpeg will download automatically on first use (~110 MB, one time).' }
}

function Add-LTCheck($Panel, [string]$Text) {
    $check = [CheckBox]::new()
    $check.Content = New-LTText $Text
    $check.IsChecked = $false
    $Panel.Children.Add($check)
    return $check
}

function Write-LTStatus([string]$Text) {
    $script:LTUi.Status.Text = $Text
    if ($script:LTUi.ResultText -and -not $Text.EndsWith('…')) {
        $script:LTUi.ResultText.Text = $Text
    }
}

function Invoke-LTAdapter([string]$Name, [hashtable]$Arguments = @{}) {
    $command = Get-Command $Name -CommandType Function, Cmdlet -ErrorAction SilentlyContinue
    if (-not $command) {
        throw "Missing operation: $Name. Reload the app with its core module and try again."
    }
    & $command @Arguments -ErrorAction Stop
}

function Test-LTSteamRunning {
    return [bool](Get-Process -Name steam -ErrorAction SilentlyContinue)
}

function Assert-LTGame {
    if (-not $script:LTUi.Game -or -not $script:LTUi.Paths) {
        throw 'CS:S not found. Enter its folder on Setup and choose Find game.'
    }
}

function Get-LTPath([string]$Name) {
    Assert-LTGame
    $value = [string]$script:LTUi.Paths.$Name
    if (-not $value -or -not [IO.Path]::IsPathFullyQualified($value)) {
        throw "Missing destination: $Name. Find the game again before continuing."
    }
    return $value
}

function Confirm-LTAction([string]$Title, [string]$Body, [string]$Accept) {
    $dialog = [ContentDialog]::new()
    $dialog.XamlRoot = $script:LTUi.Root.XamlRoot
    $dialog.Title = $Title
    $dialog.Content = New-LTText $Body
    $dialog.PrimaryButtonText = $Accept
    $dialog.CloseButtonText = 'Cancel'
    $dialog.DefaultButton = 'Close'
    $script:LTUi.Dialog = $dialog
    try { return ([string]$dialog.ShowAsync().WaitForCompleted() -eq 'Primary') }
    finally { $script:LTUi.Dialog = $null }
}

function Show-LTResult($Result) {
    if ($null -ne $Result) {
        $lines = @()
        if ($Result -is [string]) { $lines += $Result }
        else {
            if ($Result.Status) { $lines += [string]$Result.Status }
            foreach ($item in $(if ($Result.PSObject.Properties['Items']) { @($Result.Items) } else { @($Result) })) {
                $entry = if ($item.Item) { $item.Item } else { $item }
                $name = if ($entry.DisplayName) { $entry.DisplayName } elseif ($entry.Name) { $entry.Name } elseif ($entry.Kind) { $entry.Kind } else { 'File' }
                $lines += ('{0} — {1}{2}' -f $name, (Format-LTValue $item.Status), $(if ($item.Error) { ": $($item.Error)" } else { '' }))
                if ($item.PSObject.Properties['Backup']) {
                    $lines += $(if ($item.Backup) { "Backup saved: $($item.Backup)" } else { 'No backup created for this item.' })
                }
                foreach ($candidate in $script:LTUi.Candidates) {
                    if ($entry.Key -and $candidate.Row.Key -ceq $entry.Key) {
                        $candidate.Outcome.Text = "$(Format-LTValue $item.Status)$(if ($item.Error) { ": $($item.Error)" })"
                    }
                }
            }
            if ($Result.Error) { $lines += "Error: $($Result.Error)" }
        }
        $resultText = $lines -join "`n"
        if ($script:LTUi.CleanupOutcomes) { $script:LTUi.CleanupOutcomes.Text = $resultText }
    } else {
        $resultText = 'No result details. Check the recovery journal before retrying.'
    }
    $script:LTUi.LastResult = $resultText
    $summary = if ($Result.Status) { @($Result.Status) -join ', ' } elseif ($null -eq $Result) { 'Outcome unavailable — inspect details' } else { 'Operation returned details' }
    Add-LTOperation "$($script:LTUi.OperationLabel) · $summary"
}

function Get-LTCandidatePreferenceKey($Row) {
    $identity = if ($Row.Kind -eq 'Process') {
        @('Process', $Row.Name, $Row.Path)
    } else {
        @($Row.Kind, $Row.TaskPath, $Row.Name, $Row.Path)
    }
    return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($identity -join "`0")))
}

function Get-LTConfigEditorText {
    $range = $script:LTUi.ConfigEditor.Document.GetRange(0, 1000000)
    $text = [string]$range.Text
    if ($text.EndsWith("`r")) { $text = $text.Substring(0, $text.Length - 1) }
    return $text.Replace("`r`n", "`n").Replace("`r", "`n").Replace("`n", "`r`n")
}

function Set-LTConfigEditorText([string]$Text, [switch]$PreserveHistory) {
    if (-not $script:LTUi.ConfigEditor) { return }
    $script:LTUi.ConfigEditorInitializing = $true
    try {
        $script:LTUi.ConfigEditor.Document.SetText([TextSetOptions]::None, $Text)
        $script:LTUi.ConfigEditor.Document.ClearUndoRedoHistory()
        $script:LTUi.ConfigLastText = $Text.Replace("`r`n", "`n").Replace("`r", "`n").Replace("`n", "`r`n")
        if (-not $PreserveHistory) {
            $script:LTUi.ConfigUndo.Clear()
            $script:LTUi.ConfigRedo.Clear()
        }
    } finally { $script:LTUi.ConfigEditorInitializing = $false }
    Set-LTConfigSyntaxHighlight
}

function Update-LTConfigChoiceLabel {
    if (-not $script:LTUi.UseConfig) { return }
    $script:LTUi.UseConfig.Content = switch ($script:LTUi.Profile.SelectedIndex) {
        0 { 'Replace config with LamaTeam Modern PC config' }
        1 { 'Replace config with Rivals.cz Legacy PC config' }
        default { 'Replace config with selected preset' }
    }
}

function Update-LTMapCount($Rows) {
    if (-not $script:LTUi.AutoMaps) { return }
    $count = @($Rows | Where-Object Status -eq 'Missing').Count
    $script:LTUi.AutoMaps.Content = "Automatically download $count missing maps"
}

function Set-LTConfigSyntaxHighlight {
    if (-not $script:LTUi.ConfigEditor -or $script:LTUi.ConfigHighlighting) { return }
    $editor = $script:LTUi.ConfigEditor
    $document = $editor.Document
    $text = Get-LTConfigEditorText
    if (-not $text.Length) { return }
    $selectionStart = $document.Selection.StartPosition
    $selectionEnd = $document.Selection.EndPosition
    $script:LTUi.ConfigHighlighting = $true
    try {
        $base = $document.GetRange(0, 1000000)
        $format = $base.CharacterFormat
        $format.ForegroundColor = [Color]::FromArgb(255, 222, 226, 232)
        $base.CharacterFormat = $format
        $rules = @(
            @{ Pattern = '(?m)^\s*(?:alias|bind|exec|echo|say|wait|toggle|incrementvar|host_writeconfig|unbind|unbindall)\b'; Color = [Color]::FromArgb(255, 116, 190, 255) },
            @{ Pattern = '"(?:\\.|[^"\\])*"'; Color = [Color]::FromArgb(255, 231, 176, 112) },
            @{ Pattern = '(?<![\w])[-+]?\d+(?:\.\d+)?\b'; Color = [Color]::FromArgb(255, 202, 153, 255) },
            @{ Pattern = '(?m)//.*$'; Color = [Color]::FromArgb(255, 126, 183, 137) }
        )
        foreach ($rule in $rules) {
            foreach ($match in [regex]::Matches($text, $rule.Pattern)) {
                if (-not $match.Length) { continue }
                $range = $document.GetRange($match.Index, $match.Index + $match.Length)
                $format = $range.CharacterFormat
                $format.ForegroundColor = $rule.Color
                $range.CharacterFormat = $format
            }
        }
        $document.Selection.SetRange(
            [Math]::Min($selectionStart, $text.Length),
            [Math]::Min($selectionEnd, $text.Length)
        )
    } finally { $script:LTUi.ConfigHighlighting = $false }
}

function Save-LTConfigEditorText([string]$Text) {
    if (-not $script:LTUi.Game -or -not $script:LTUi.Paths) {
        $script:LTUi.ConfigSaveStatus.Text = 'Detect CS:S before saving config edits.'
        return
    }
    $arguments = @{
        Game = $script:LTUi.Game; Paths = $script:LTUi.Paths; Content = $Text
        ExpectedSha256 = [string]$script:LTUi.ConfigExpectedSha256
        ExpectedMissing = ($script:LTUi.ConfigExpectedMissing -eq $true)
        BackupAlreadyCreated = ($script:LTUi.ConfigBackupCreated -eq $true)
    }
    try {
        $result = Invoke-LTAdapter 'Save-LamaTeamConfigText' $arguments
        if ($result.Changed) {
            $script:LTUi.ConfigBackupCreated = ($script:LTUi.ConfigBackupCreated -or [bool]$result.Backup)
            $script:LTUi.ConfigExpectedMissing = $false
            $script:LTUi.ConfigExpectedSha256 = [string]$result.Sha256
            $script:LTUi.ConfigSaveStatus.Text = if ($result.Backup) { 'Saved · original backed up' } else { 'Saved' }
        } else { $script:LTUi.ConfigSaveStatus.Text = 'Saved' }
    } catch {
        $script:LTUi.ConfigSaveStatus.Text = "Save blocked: $($_.Exception.Message)"
    }
}

function Invoke-LTConfigHistory([switch]$Redo) {
    $source = if ($Redo) { $script:LTUi.ConfigRedo } else { $script:LTUi.ConfigUndo }
    $destination = if ($Redo) { $script:LTUi.ConfigUndo } else { $script:LTUi.ConfigRedo }
    if (-not $source.Count) { return }
    $current = Get-LTConfigEditorText
    $destination.Add($current)
    $target = [string]$source[$source.Count - 1]
    $source.RemoveAt($source.Count - 1)
    Set-LTConfigEditorText $target -PreserveHistory
    Save-LTConfigEditorText $target
}

function Update-LTConfigPreview {
    if (-not $script:LTUi.Game -or -not $script:LTUi.Paths) {
        Set-LTConfigEditorText ''
        return
    }
    $profile = switch ($script:LTUi.Profile.SelectedIndex) { 0 { 'Modern' }; 1 { 'Legacy' }; default { $null } }
    if (-not $profile) { Set-LTConfigEditorText ''; return }
    try {
        if ($profile -eq 'Legacy' -and -not (Test-LTLegacySource)) { throw 'Legacy source unavailable.' }
        $preview = Invoke-LTAdapter 'Get-LamaTeamConfigPreview' @{ Profile = $profile }
        $text = if ($preview -is [string]) { $preview } else { [string]$preview.Text }
        if ([string]::IsNullOrWhiteSpace($text)) { throw 'Config preview is unavailable.' }
        Set-LTConfigEditorText $text
        $script:LTUi.ConfigSaveStatus.Text = 'Edit to save to the detected CS:S config.'
        if ($profile -eq 'Legacy') {
            if ($preview -is [string] -or $preview.Profile -cne 'Legacy' -or
                $preview.ReviewRequired -ne $true -or
                [string]$preview.ReviewSha256 -cnotmatch '^[a-fA-F0-9]{64}$') {
                throw 'Legacy preview did not return its exact review hash and metadata.'
            }
            $script:LTUi.LegacyReview = @{
                Profile = 'Legacy'; ReviewSha256 = [string]$preview.ReviewSha256
                ConfigPath = [string]$script:LTUi.Paths.ConfigPath
                SourcePath = [string]$script:LTUi.Paths.LegacyAssetPath
            }
        } else { $script:LTUi.LegacyReview = $null }
    } catch {
        $script:LTUi.LegacyReview = $null
        $script:LTUi.ConfigSaveStatus.Text = "Config preview unavailable: $($_.Exception.Message)"
    }
}

function Get-LTLamaStartupOptions {
    param([string]$Base, [int]$RefreshRate = 0, [switch]$IncludeLamaDefaults)
    $options = $Base.Trim()
    if ($IncludeLamaDefaults) {
        foreach ($flag in @('-novid', '-nojoy')) {
            if ($options -notmatch "(?i)(?:^|\s)$([regex]::Escape($flag))(?:\s|$)") {
                $options = (@($options, $flag) | Where-Object { $_ }) -join ' '
                $options = $options.Trim()
            }
        }
    }
    if ($RefreshRate -gt 0) {
        $options = [regex]::Replace($options, '(?i)(?:^|\s)-refresh\s+\d+(?=\s|$)', '')
        $options = (@($options.Trim(), "-refresh $RefreshRate" | Where-Object { $_ }) -join ' ').Trim()
    }
    return $options
}

function Update-LTStartupOptions {
    if ($script:LTUi.UpdatingStartupOptions) { return }
    $script:LTUi.UpdatingStartupOptions = $true
    try {
        $base = if ($script:LTUi.UseLamaStartupOptions.IsChecked -eq $true) {
            [string]$script:LTUi.CurrentStartupOptions
        } else { [string]$script:LTUi.CustomStartupOptions }
        $refresh = 0
        if ($script:LTUi.MonitorMaxRefreshRate.IsChecked -eq $true) {
            $selected = $script:LTUi.DisplayModes | Where-Object DeviceName -CEQ $script:LTUi.MonitorDeviceName | Select-Object -First 1
            if ($selected -and $selected.Available) { $refresh = [int]$selected.MaxHz }
        }
        $options = if ($script:LTUi.UseLamaStartupOptions.IsChecked -eq $true -or $refresh -gt 0) {
            Get-LTLamaStartupOptions -Base $base -RefreshRate $refresh -IncludeLamaDefaults:($script:LTUi.UseLamaStartupOptions.IsChecked -eq $true)
        } else { $base }
        if ($script:LTUi.StartupOptions.Text -cne $options) { $script:LTUi.StartupOptions.Text = $options }
        $script:LTUi.StartupOptions.IsReadOnly = (
            $script:LTUi.UseLamaStartupOptions.IsChecked -eq $true -or
            $script:LTUi.MonitorMaxRefreshRate.IsChecked -eq $true
        )
        $script:LTUi.StartupOptionsState.Text = if ($script:LTUi.UseLamaStartupOptions.IsChecked -eq $true) {
            'LamaTeam preset'
        } elseif ($script:LTUi.CustomStartupOptions -ceq $script:LTUi.CurrentStartupOptions) {
            'Current settings'
        } else { 'Custom' }
        Save-LTPreferences
    } finally { $script:LTUi.UpdatingStartupOptions = $false }
}

function Save-LTPreferences {
    if (-not $script:LTUi.PreferencePath -or -not $script:LTUi.Profile) { return }
    $cleanup = @(
        $script:LTUi.Candidates |
            Where-Object { $_.Check.IsChecked -eq $true -and $_.Row.Eligible -eq $true } |
            ForEach-Object { Get-LTCandidatePreferenceKey $_.Row }
    )
    $state = [ordered]@{
        PreferenceVersion = 3
        GamePath = [string]$script:LTUi.GamePath.Text
        ProfileIndex = [int]$script:LTUi.Profile.SelectedIndex
        UseConfig = ($script:LTUi.UseConfig.IsChecked -eq $true)
        Connect = ($script:LTUi.ConnectCheck.IsChecked -eq $true)
        VideoOptIn = ($script:LTUi.VideoOptIn.IsChecked -eq $true)
        AutoMaps = ($script:LTUi.AutoMaps.IsChecked -eq $true)
        Tweaks = @($script:LTUi.TweakChecks.Keys | Where-Object { $script:LTUi.TweakChecks[$_].IsChecked -eq $true })
        ValidateIntegrity = ($script:LTUi.ValidateIntegrity.IsChecked -eq $true)
        StartupOptions = [string]$script:LTUi.StartupOptions.Text
        StartupOptionsCustom = [string]$script:LTUi.CustomStartupOptions
        UseLamaStartupOptions = ($script:LTUi.UseLamaStartupOptions.IsChecked -eq $true)
        MonitorMaxRefreshRate = ($script:LTUi.MonitorMaxRefreshRate.IsChecked -eq $true)
        MonitorDeviceName = [string]$script:LTUi.MonitorDeviceName
        Cleanup = @($cleanup | Select-Object -Unique)
    }
    try { Save-CssState -Path $script:LTUi.PreferencePath -State $state }
    catch { $script:LTUi.Status.Text = 'Preferences could not be saved.' }
}

function Update-LTCleanupSelection {
    $selected = @($script:LTUi.Candidates | Where-Object {
        $_.Check.IsChecked -eq $true -and $_.Check.IsEnabled -eq $true -and $_.Row.Eligible -eq $true
    })
    foreach ($button in $script:LTUi.Buttons) {
        if ($button.Tag -eq 'Play') {
            $button.IsEnabled = -not $script:LTUi.Busy
        }
    }
}

function Get-LTCleanupView {
    if ($script:LTUi.CleanupNeedsScan -eq $true) {
        return @{ State = 'Stale'; Rows = @(); Message = 'Scan again before another action.' }
    }
    if ($script:LTUi.CleanupScanned -ne $true) {
        return @{ State = 'NotScanned'; Rows = @(); Message = 'Scanning…' }
    }
    $unavailable = @($script:LTUi.CleanupSubsystems | Where-Object Available -ne $true)
    if (-not $script:LTUi.CleanupSubsystems.Count -or $unavailable.Count -eq $script:LTUi.CleanupSubsystems.Count) {
        $errorText = @($unavailable | ForEach-Object Error | Where-Object { $_ }) -join '; '
        return @{
            State = $(if ($script:LTUi.CleanupScanned) { 'Unavailable' } else { 'NotScanned' })
            Rows = @()
            Message = $(if ($script:LTUi.CleanupScanned) { "Inspection unavailable. $errorText" } else { 'Scanning…' })
        }
    }
    $all = @($script:LTUi.CleanupItems)
    $rows = $all
    return @{
        State = $(if (-not $all.Count) { 'Empty' } elseif (-not $rows.Count) { 'NoMatch' } else { 'Ready' })
        Rows = $rows
        Message = $(if (-not $all.Count) { '0 eligible' } else { "$($rows.Count) found" })
    }
}

function Invalidate-LTCleanupCandidates {
    foreach ($candidate in $script:LTUi.Candidates) { $candidate.Check.IsEnabled = $false }
    $script:LTUi.CleanupItems = @()
    $script:LTUi.CleanupSubsystems = @()
    $script:LTUi.CleanupNeedsScan = $true
}

function Show-LTCleanupRows {
    $script:LTUi.CleanupRows.Children.Clear()
    $script:LTUi.Candidates = @()
    $view = Get-LTCleanupView
    foreach ($row in @($view.Rows | Sort-Object Name, Kind)) {
        $name = if ($row.DisplayName) { $row.DisplayName } else { $row.Name }
        $check = Add-LTCheck $script:LTUi.CleanupRows $name
        $check.HorizontalAlignment = 'Stretch'
        $check.Tag = $row
        $check.IsEnabled = ($row.Eligible -eq $true -and -not [string]::IsNullOrWhiteSpace($row.Key))
        $preferred = @($script:LTUi.Preferences.Cleanup)
        $check.IsChecked = ($check.IsEnabled -and (Get-LTCandidatePreferenceKey $row) -in $preferred)
        $check.AddChecked({ param($argumentList, $sender, $eventArgs); Update-LTCleanupSelection; Save-LTPreferences })
        $check.AddUnchecked({ Update-LTCleanupSelection; Save-LTPreferences })
        $script:LTUi.Candidates += @{ Row = $row; Check = $check; Outcome = (New-LTText '') }
    }
    Update-LTCleanupSelection
}

function Update-LTRecovery {
    $script:LTUi.Recovery = $null
    $script:LTUi.RestoreEligible = $false
    $record = Invoke-LTAdapter 'Get-LamaTeamCleanupRecovery'
    $script:LTUi.Recovery = $record
    $eligible = 0
    $lines = @()
    foreach ($item in @($record.Items)) {
        $entry = if ($item.Item) { $item.Item } else { $item }
        if ($entry.Kind -in @('Service', 'Task') -and $item.Status -in @('Changed', 'RestoreFailed')) { $eligible++ }
        if ($item.Status -in @('Pending', 'Uncertain')) { $lines += "$($entry.Name): inspect manually" }
    }
    if ($record.Error) { $lines += 'Recovery unreadable.' }
    elseif ($eligible) { $lines += "$eligible service/task changes can be restored." }
    elseif (-not $lines.Count) { $lines += 'No changes to restore.' }
    $script:LTUi.RecoveryText.Text = $lines -join "`n"
    $script:LTUi.RestoreEligible = ($eligible -gt 0)
    foreach ($button in $script:LTUi.Buttons) {
        if ($button.Tag -eq 'Restore') { $button.IsEnabled = ($script:LTUi.RestoreEligible -and -not $script:LTUi.Busy) }
    }
}

function Invoke-LTAction([string]$Action) {
    if ($Action -eq 'Join') { $Action = 'Play' }
    if ($script:LTUi.Busy) { return }
    $rescanCleanupAfterAction = $false
    $script:LTUi.Busy = $true
    $script:LTUi.OperationLabel = switch ($Action) {
        Play { 'Prepare & play' }
        Maps { 'Download maps' }
        MapsSelected { 'Download selected maps' }
        Restore { 'Restore services & tasks' }
        Video { 'Convert intro video' }
        default { $Action }
    }
    foreach ($button in $script:LTUi.Buttons) { $button.IsEnabled = $false }
    try {
        switch ($Action) {
            'Play' {
                Assert-LTGame
                # Backup destinations are one-shot plans; refresh them before every apply.
                $script:LTUi.Paths = Invoke-LTAdapter 'Get-LamaTeamPaths' @{ Game = $script:LTUi.Game }
                if ($script:LTUi.ValidateIntegrity.IsChecked -eq $true) {
                    if (Confirm-LTAction 'Validate game integrity?' 'Steam will verify Counter-Strike: Source files. This can take several minutes. Wait for Steam to finish, then click Apply and play again.' 'Check in Steam') {
                        Start-Process 'steam://validate/240' -ErrorAction Stop
                        $script:LTUi.ValidateIntegrity.IsChecked = $false
                        Save-LTPreferences
                        Write-LTStatus 'Steam integrity check started · apply again after it finishes.'
                    }
                    return
                }
                $selected = @($script:LTUi.Candidates | Where-Object {
                    $_.Check.IsChecked -eq $true -and $_.Check.IsEnabled -eq $true -and $_.Row.Eligible -eq $true
                })
                $profile = if ($script:LTUi.UseConfig.IsChecked -eq $true) {
                    switch ($script:LTUi.Profile.SelectedIndex) { 0 { 'Modern' }; 1 { 'Legacy' }; default { throw 'Choose Modern PC or Legacy PC.' } }
                } else { $null }
                if ($profile -eq 'Legacy' -and -not (Test-LTLegacySource)) {
                    throw 'Legacy source unavailable. Find game again or choose Modern.'
                }
                if ($profile -eq 'Legacy') { $null = Get-LTReviewedLegacyHash }
                $tweaks = @($script:LTUi.TweakChecks.Keys | Where-Object { $script:LTUi.TweakChecks[$_].IsChecked -eq $true })
                $startupOptions = [string]$script:LTUi.StartupOptions.Text
                if ($startupOptions.Length -gt 256 -or $startupOptions -match '[^\x20-\x7E]') {
                    throw 'Startup options must be at most 256 printable ASCII characters.'
                }
                $startupOptionsChanged = $false
                if ($script:LTUi.SteamSettings) {
                    $diskSettings = Get-CssSteamLaunchOptions -ConfigPath $script:LTUi.SteamSettings.ConfigPath
                    if ($diskSettings.Options -cne $script:LTUi.CurrentStartupOptions) {
                        throw 'Steam launch options changed while this form was open. Reopen the launcher to avoid overwriting newer settings.'
                    }
                    $startupOptionsChanged = $startupOptions -cne $script:LTUi.CurrentStartupOptions
                } elseif (-not [string]::IsNullOrWhiteSpace($startupOptions)) {
                    throw "Steam launch options are unavailable: $($script:LTUi.SteamSettingsError)"
                }
                $steamWasRunning = Test-LTSteamRunning
                $selectedDisplay = $script:LTUi.DisplayModes | Where-Object DeviceName -CEQ $script:LTUi.MonitorDeviceName | Select-Object -First 1
                if ($script:LTUi.MonitorMaxRefreshRate.IsChecked -eq $true -and
                    (-not $selectedDisplay -or -not $selectedDisplay.Available)) {
                    throw 'The selected monitor maximum refresh rate could not be verified.'
                }
                $mapsToDownload = @()
                if ($script:LTUi.AutoMaps.IsChecked -eq $true) {
                    Write-LTStatus 'Checking missing maps…'
                    $mapRows = @(Invoke-LTAdapter 'Get-LamaTeamMaps' @{ Game = $script:LTUi.Game })
                    $mapsToDownload = @($mapRows | Where-Object Status -in @('Missing', 'Failed'))
                    Update-LTMapCount $mapRows
                }
                $targets = @()
                if ($profile -or $tweaks.Count) {
                    $targets += if ($profile) { "Config: $profile · $(Get-LTPath 'ConfigPath') · backup $(Get-LTPath 'ConfigBackupPath')" } else { "Tweaks: $(Get-LTPath 'ConfigPath') · backup $(Get-LTPath 'ConfigBackupPath')" }
                }
                if ($tweaks.Count) {
                    $targets += @($tweaks | ForEach-Object { "Tweak: $($_ -replace '_', ' ')" })
                }
                if ($script:LTUi.ConnectCheck.IsChecked -eq $true) {
                    $targets += "Connect: $(Get-LTPath 'ConnectPath') · backup $(Get-LTPath 'ConnectBackupPath')"
                    $targets += "Menu: $(Get-LTPath 'GameMenuPath') · backup $(Get-LTPath 'GameMenuBackupPath')"
                }
                $convertVideo = ($script:LTUi.VideoOptIn.IsChecked -eq $true)
                if ($convertVideo) {
                    $targets += "Intro video: $(Get-LTPath 'IntroTargetPath') · backup $(Get-LTPath 'IntroBackupPath')"
                }
                if ($script:LTUi.AutoMaps.IsChecked -eq $true) {
                    $targets += if ($mapsToDownload.Count) { "Missing maps: $($mapsToDownload.Name -join ', ')" } else { 'Missing maps: none' }
                }
                if ($selected.Count) {
                    $targets += @($selected | ForEach-Object { "$($_.Row.Kind): $($_.Row.Name)" })
                }
                if ($startupOptionsChanged) {
                    $targets += "Steam launch options: $startupOptions (saved with a backup; Steam remains open)"
                }
                if ($script:LTUi.MonitorMaxRefreshRate.IsChecked -eq $true) {
                    $targets += "Monitor: $($selectedDisplay.DisplayName) · $($selectedDisplay.CurrentHz) → $($selectedDisplay.MaxHz) Hz"
                }
                if (-not $targets.Count) { $targets = @('Launch CS:S and connect to LamaTeam') }
                $body = "Selected actions:`n$($targets -join "`n")`n`nProcess closes are graceful requests only and cannot be restored. Service/task changes can be restored. Config backups are created before replacement. Continue, then open Steam and connect to LamaTeam?"
                if (Confirm-LTAction 'Apply and play?' $body 'Apply and play') {
                    if ($startupOptionsChanged) {
                        $write = Set-CssSteamLaunchOptions -ConfigPath $script:LTUi.SteamSettings.ConfigPath -Options $startupOptions
                        if ($write.Changed) {
                            $script:LTUi.CurrentStartupOptions = $startupOptions
                            $script:LTUi.SteamSettings.Options = $startupOptions
                            $steamState = if ($steamWasRunning) { 'Steam remains open' } else { 'Steam is not running' }
                            Write-LTStatus "Launch options saved; $steamState. Backup: $($write.Backup)"
                        }
                    }
                    if ($script:LTUi.MonitorMaxRefreshRate.IsChecked -eq $true) {
                        $displayResult = Set-CssDisplayRefreshRate -DeviceName $script:LTUi.MonitorDeviceName -RefreshRate $selectedDisplay.MaxHz
                        if ($displayResult.CurrentHz -ne $selectedDisplay.MaxHz) {
                            throw 'Monitor refresh rate did not verify; Steam was not opened.'
                        }
                    }
                    if ($script:LTUi.AutoMaps.IsChecked -eq $true -and $mapsToDownload.Count) {
                        $result = Invoke-LTAdapter 'Sync-LamaTeamMaps' @{
                            Game = $script:LTUi.Game; Maps = $mapsToDownload
                            Progress = {
                                param($record)
                                $script:LTUi.Status.Text = "$($record.Name): $($record.Status)"
                            }
                        }
                        Show-LTResult $result
                        if (@($result | Where-Object Status -notin @('Installed','Skipped')).Count) {
                            throw 'Some maps could not be downloaded; Steam was not opened. Retry Apply and play.'
                        }
                    }
                    if ($profile -or $tweaks.Count) {
                        $arguments = @{
                            Game = $script:LTUi.Game; Paths = $script:LTUi.Paths; Tweaks = [string[]]$tweaks
                            Content = (Get-LTConfigEditorText)
                            ExpectedSha256 = [string]$script:LTUi.ConfigExpectedSha256
                            ExpectedMissing = ($script:LTUi.ConfigExpectedMissing -eq $true)
                        }
                        if ($script:LTUi.ConfigBackupCreated) { $arguments.BackupAlreadyCreated = $true }
                        if ($profile) { $arguments.Profile = $profile }
                        if ($profile -eq 'Legacy') { $arguments.ReviewedSha256 = Get-LTReviewedLegacyHash }
                        $configResult = Invoke-LTAdapter 'Set-LamaTeamPlayerConfig' $arguments
                        if ($configResult.Backup) { $script:LTUi.ConfigBackupCreated = $true }
                        if ($configResult.Sha256) {
                            $script:LTUi.ConfigExpectedSha256 = [string]$configResult.Sha256
                            $script:LTUi.ConfigExpectedMissing = $false
                        }
                        Show-LTResult $configResult
                    }
                    if ($script:LTUi.ConnectCheck.IsChecked -eq $true) {
                        Show-LTResult (Invoke-LTAdapter 'Add-LamaTeamConnect' @{ Game = $script:LTUi.Game; Paths = $script:LTUi.Paths })
                    }
                    $convertVideo = ($script:LTUi.VideoOptIn.IsChecked -eq $true)
                    if ($convertVideo) {
                        $videoResult = Invoke-LTAdapter 'Convert-LamaTeamIntroVideo' @{
                            Game = $script:LTUi.Game; Paths = $script:LTUi.Paths; OptIn = $true
                            BackupExisting = $true; BackupPath = (Get-LTPath 'IntroBackupPath')
                        }
                        Show-LTResult $videoResult
                        if ($videoResult.Status -ne 'Converted') { throw 'Intro conversion did not complete; Steam was not opened.' }
                    }
                    if ($selected.Count) {
                        $arguments = @{
                            SelectedKeys = [string[]]@($selected | ForEach-Object { $_.Row.Key })
                            AcknowledgeNotRestorable = (@($selected | Where-Object { $_.Row.Kind -eq 'Process' }).Count -gt 0)
                        }
                        $result = Invoke-LTAdapter 'Apply-LamaTeamCleanup' $arguments
                        Show-LTResult $result
                        if ($result.Status -notin @('Succeeded', 'NoOp')) {
                            throw 'Some selected cleanup actions did not complete; Steam was not opened. Review results and refresh.'
                        }
                        Invalidate-LTCleanupCandidates
                        Update-LTRecovery
                        $rescanCleanupAfterAction = $true
                    }
                    Start-Process 'steam://connect/82.208.17.101:27516' -ErrorAction Stop
                    Write-LTStatus 'Steam connect requested.'
                }
            }
            'Integrity' {
                if (Confirm-LTAction 'Validate game integrity?' 'Steam will verify Counter-Strike: Source files. This can take several minutes.' 'Check in Steam') {
                    Start-Process 'steam://validate/240' -ErrorAction Stop
                    $script:LTUi.ValidateIntegrity.IsChecked = $false
                    Save-LTPreferences
                    Write-LTStatus 'Steam integrity check started.'
                }
            }
            'Detect' {
                $script:LTUi.LegacyReview = $null
                $script:LTUi.Game = $null
                $script:LTUi.Paths = $null
                $script:LTUi.LocationStatus.Text = 'Finding CS:S…'
                $script:LTUi.LegacyOption.IsEnabled = $false
                $script:LTUi.LegacyStatus.Text = 'Legacy source not checked.'
                Set-LTConfigEditorText ''
                $script:LTUi.IntroPreview.Text = 'Find CS:S to see media paths.'
                $arguments = @{}
                if ($script:LTUi.GamePath.Text.Trim()) { $arguments.Path = $script:LTUi.GamePath.Text.Trim() }
                $game = Invoke-LTAdapter 'Find-LamaTeamGame' $arguments
                if (-not $game) { throw 'CS:S not found. Paste its folder path to detect it.' }
                $paths = Invoke-LTAdapter 'Get-LamaTeamPaths' @{ Game = $game }
                if (-not $paths) { throw 'No paths returned. Check the operation adapter before installing.' }
                $script:LTUi.Game = $game
                $script:LTUi.Paths = $paths
                $script:LTUi.ConfigBackupCreated = $false
                $script:LTUi.ConfigExpectedSha256 = ''
                $script:LTUi.ConfigExpectedMissing = -not (Test-Path -LiteralPath $paths.ConfigPath -PathType Leaf)
                if (-not $script:LTUi.ConfigExpectedMissing) {
                    $script:LTUi.ConfigExpectedSha256 = (Get-FileHash -LiteralPath $paths.ConfigPath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
                }
                $script:LTUi.LastDetectPath = [string]$game.Root
                if ($script:LTUi.GamePath.Text -cne [string]$game.Root) {
                    $script:LTUi.SuppressDetect = $true
                    try { $script:LTUi.GamePath.Text = [string]$game.Root } finally { $script:LTUi.SuppressDetect = $false }
                }
                Update-LTPreview
                Update-LTConfigChoiceLabel
                $scan = Invoke-LTAdapter 'Get-LamaTeamCleanupCandidates'
                $script:LTUi.CleanupItems = @($scan.Items)
                $script:LTUi.CleanupSubsystems = @($scan.Subsystems)
                $script:LTUi.CleanupScanned = $true
                $script:LTUi.CleanupNeedsScan = $false
                Show-LTCleanupRows
                Update-LTRecovery
                Write-LTStatus 'CS:S found.'
            }
            { $_ -in @('PreviewConfig', 'RefreshPreview') } {
                Update-LTConfigPreview
                if ($script:LTUi.ConfigSaveStatus.Text -like 'Config preview unavailable:*') { throw $script:LTUi.ConfigSaveStatus.Text }
            }
            'ScanMaps' {
                Assert-LTGame
                $script:LTUi.Maps = @()
                $script:LTUi.MapErrors = @{}
                if ($script:LTUi.MapText) { $script:LTUi.MapText.Text = 'Checking catalogue and installed maps…' }
                $rows = @(Invoke-LTAdapter 'Get-LamaTeamMaps' @{ Game = $script:LTUi.Game })
                $script:LTUi.Maps = $rows
                Update-LTMapCount $rows
                if ($script:LTUi.MapRows) { Show-LTMapRows }
                if ($script:LTUi.MapText) {
                    $script:LTUi.MapText.Text = if ($rows.Count) { "$($rows.Count) maps checked · installed files are kept" } else { 'Map list unavailable. Check the catalogue and try again.' }
                }
                Write-LTStatus "$($rows.Count) maps checked."
            }
            { $_ -in @('Maps', 'MapsSelected') } {
                $destination = Get-LTPath 'MapsDirectory'
                $missing = @($script:LTUi.Maps | Where-Object { $_.Status -in @('Missing', 'Failed') })
                if ($script:LTUi.MapTarget) { $missing = @($missing | Where-Object Name -CEQ $script:LTUi.MapTarget) }
                if ($Action -eq 'MapsSelected') {
                    $missing = @($missing | Where-Object { $script:LTUi.MapSelections.ContainsKey($_.Name) })
                }
                if (-not $missing.Count) { throw 'Check maps first. Only missing or failed maps are downloaded.' }
                if (Confirm-LTAction 'Download missing / retry failed maps?' "Maps: $($missing.Name -join ', ')`nDestination: $destination`nFastDL host: fastdl.lamateam.eu`nExisting installed maps must be kept. Size is not known here. Extractor requirements are controlled by the operation adapter; no security verification is implied." 'Download selected missing maps') {
                    $script:LTUi.MapProgress.IsIndeterminate = $true
                    $script:LTUi.MapProgress.Value = 0
                    foreach ($map in $missing) {
                        if ($script:LTUi.MapViews.ContainsKey($map.Name)) {
                            $script:LTUi.MapViews[$map.Name].Status.Text = 'Queued'
                            $script:LTUi.MapViews[$map.Name].Progress.IsIndeterminate = $true
                        }
                    }
                    Write-LTStatus 'Downloading… Keep this window open; cannot cancel.'
                    $result = Invoke-LTAdapter 'Sync-LamaTeamMaps' @{
                        Game = $script:LTUi.Game; Maps = $missing
                        Progress = {
                            param($record)
                            $script:LTUi.MapProgress.IsIndeterminate = -not ($record.Total -gt 0)
                            if ($record.Total -gt 0) { $script:LTUi.MapProgress.Value = [math]::Clamp(100.0 * $record.Completed / $record.Total, 0, 100) }
                            $script:LTUi.MapText.Text = "$($record.Name) — $($record.Status) ($($record.Completed)/$($record.Total))"
                            if ($record.Error) { $script:LTUi.MapText.Text += "`n$($record.Error)" }
                            if ($script:LTUi.MapViews.ContainsKey($record.Name)) {
                                $view = $script:LTUi.MapViews[$record.Name]
                                $view.Status.Text = "$($record.Status)$(if ($record.Error) { ": $($record.Error)" })"
                                $view.Progress.IsIndeterminate = $false
                                if ($record.Status -in @('Installed', 'Skipped', 'Completed')) { $view.Progress.Value = 100 }
                            }
                            Write-LTStatus $script:LTUi.MapText.Text
                        }
                    }
                    Show-LTResult $result
                    Update-LTMapOutcomes $result
                    Show-LTMapRows
                    Write-LTStatus 'Download finished. Check maps again to retry failures.'
                }
            }
            'ScanCleanup' {
                $script:LTUi.CleanupNeedsScan = $false
                $script:LTUi.CleanupItems = @()
                $script:LTUi.CleanupSubsystems = @()
                $script:LTUi.CleanupScanned = $true
                Show-LTCleanupRows
                $scan = Invoke-LTAdapter 'Get-LamaTeamCleanupCandidates'
                $script:LTUi.CleanupItems = @($scan.Items)
                $script:LTUi.CleanupSubsystems = @($scan.Subsystems)
                Show-LTCleanupRows
                Save-LTPreferences
                Write-LTStatus 'Scan complete.'
            }
            'Restore' {
                Update-LTRecovery
                $targets = @($script:LTUi.Recovery.Items | Where-Object {
                    $entry = if ($_.Item) { $_.Item } else { $_ }
                    $entry.Kind -in @('Service', 'Task') -and $_.Status -in @('Changed', 'RestoreFailed')
                })
                if (-not $targets.Count) { throw 'No confirmed service/task changes to restore. Pending entries need inspection.' }
                $names = ($targets | ForEach-Object { $entry = if ($_.Item) { $_.Item } else { $_ }; "$($entry.Kind): $($entry.Name) [$($entry.Key)]" }) -join "`n"
                if (Confirm-LTAction 'Restore recorded changes?' "$names`n`nRestores recorded service/task state. Apps are not restored. Pending/uncertain entries remain for inspection." 'Restore') {
                    Show-LTResult (Invoke-LTAdapter 'Restore-LamaTeamCleanup')
                    Update-LTRecovery
                    Write-LTStatus 'Restore finished. Review per-item results.'
                }
            }
            'Video' {
                if ($script:LTUi.VideoOptIn.IsChecked -ne $true) { throw 'Intro conversion is optional. Read the preservation warning and explicitly opt in first.' }
                $source = Get-LTPath 'IntroSourcePath'
                $target = Get-LTPath 'IntroTargetPath'
                $backup = Get-LTPath 'IntroBackupPath'
                $converter = if ($script:LTUi.Paths.ConverterPath) {
                    $script:LTUi.Paths.ConverterPath
                } else { 'Will download automatically on first use (~110 MB)' }
                if (Confirm-LTAction 'Convert to WebM?' "Source: $source`nTarget: $target`nExisting target backup: $backup (created automatically only if needed)`nFFmpeg: $converter`nThe source stays unchanged." 'Convert') {
                    Write-LTStatus 'Preparing FFmpeg if needed, then converting… Keep this window open.'
                    $arguments = @{
                        Game = $script:LTUi.Game; Paths = $script:LTUi.Paths; OptIn = $true
                        BackupExisting = $true; BackupPath = $backup
                    }
                    $result = Invoke-LTAdapter 'Convert-LamaTeamIntroVideo' $arguments
                    Show-LTResult $result
                    $script:LTUi.IntroPreview.Text = 'FFmpeg ready. Original video stays unchanged.'
                    Write-LTStatus 'Conversion finished.'
                }
            }
        }
    } catch {
        if ($Action -eq 'ScanCleanup') { Write-LTStatus "Cleanup inspection unavailable: $($_.Exception.Message)" }
        if ($Action -eq 'Restore') { $script:LTUi.RecoveryText.Text = "Restore unavailable: $($_.Exception.Message)" }
        if ($Action -in @('ScanMaps', 'Maps', 'MapsSelected') -and $script:LTUi.MapText) { $script:LTUi.MapText.Text = $_.Exception.Message }
        if ($Action -eq 'Detect') {
            $message = 'CS:S not detected. Paste its folder path to detect it.'
            $script:LTUi.LocationStatus.Text = $message
            Write-LTStatus $message
        } else {
            Write-LTStatus $_.Exception.Message
            Add-LTOperation "Not completed: $($_.Exception.Message)"
        }
    } finally {
        foreach ($button in $script:LTUi.Buttons) { $button.IsEnabled = $true }
        $script:LTUi.Busy = $false
        Update-LTCleanupSelection
        foreach ($button in $script:LTUi.Buttons) {
            if ($button.Tag -eq 'Restore') { $button.IsEnabled = ($script:LTUi.RestoreEligible -eq $true) }
        }
    }
    if ($Action -eq 'Detect' -and $script:LTUi.Game) {
        Invoke-LTAction 'RefreshPreview'
        Invoke-LTAction 'ScanMaps'
    }
    if ($rescanCleanupAfterAction) { Invoke-LTAction 'ScanCleanup' }
}

function Start-LamaTeamApp {
    [CmdletBinding()]
    param()
    if ($script:LTUi -and $script:LTUi.Running) { throw 'A LamaTeam app window is already open.' }
    Import-Module WinUIShell -RequiredVersion 0.14.0 -ErrorAction Stop
    $preferencePath = Join-Path (Get-CssConfiguration).StateRoot 'launcher-preferences.json'
    $stored = $null
    try { $stored = Read-CssState $preferencePath } catch { }
    $steamSettings = $null
    $steamSettingsError = $null
    try { $steamSettings = Get-CssSteamLaunchOptions } catch { $steamSettingsError = $_.Exception.Message }
    $currentStartupOptions = if ($steamSettings) { [string]$steamSettings.Options } else { '' }
    $customStartupOptions = if ($steamSettings) {
        $currentStartupOptions
    } elseif ($stored -and $stored.PSObject.Properties['StartupOptionsCustom']) {
        [string]$stored.StartupOptionsCustom
    } elseif ($stored -and $stored.PSObject.Properties['StartupOptions']) {
        [string]$stored.StartupOptions
    } else { $currentStartupOptions }
    $displayModes = @()
    try { $displayModes = @(Get-CssDisplayRefreshInfo) } catch { }
    $savedDevice = if ($stored -and $stored.PSObject.Properties['MonitorDeviceName']) { [string]$stored.MonitorDeviceName } else { '' }
    $selectedDisplay = $displayModes | Where-Object DeviceName -CEQ $savedDevice | Select-Object -First 1
    if (-not $selectedDisplay) { $selectedDisplay = $displayModes | Where-Object IsPrimary | Select-Object -First 1 }
    if (-not $selectedDisplay) { $selectedDisplay = $displayModes | Select-Object -First 1 }
    $useLamaStartupOptions = ($stored -and $stored.UseLamaStartupOptions -eq $true)
    $monitorMaxRefreshRate = ($stored -and $stored.MonitorMaxRefreshRate -eq $true -and $null -ne $selectedDisplay)
    $savedMaps = if ($stored -and $stored.Maps) { @($stored.Maps) } else { @() }
    $mapSelections = @{}
    foreach ($mapName in $savedMaps) { $mapSelections[[string]$mapName] = $true }
    $script:LTUi = @{
        Running = $true; Busy = $false; Dialog = $null; Game = $null; Paths = $null
        Maps = @(); MapErrors = @{}; MapSelections = $mapSelections; MapViews = @{}; MapButtons = @(); MapTarget = $null; Candidates = @(); LegacyReview = $null
        RestoreEligible = $false; LastResult = ''; OperationLabel = ''
        CleanupNeedsScan = $false; CleanupItems = @(); CleanupSubsystems = @(); CleanupScanned = $false; Recovery = $null
        Buttons = [Collections.Generic.List[object]]::new(); PreferencePath = $preferencePath
        SuppressDetect = $false; LastDetectPath = $null
        SteamSettings = $steamSettings; SteamSettingsError = $steamSettingsError
        CurrentStartupOptions = $currentStartupOptions; CustomStartupOptions = $customStartupOptions
        UseLamaStartupOptions = $null; StartupOptions = $null; StartupOptionsState = $null
        UpdatingStartupOptions = $false; DisplayModes = $displayModes
        MonitorDeviceName = $(if ($selectedDisplay) { [string]$selectedDisplay.DeviceName } else { '' })
        MonitorMaxRefreshRate = $null
        ConfigEditor = $null; ConfigEditorInitializing = $false; ConfigHighlighting = $false
        ConfigLastText = ''; ConfigUndo = [Collections.Generic.List[string]]::new()
        ConfigRedo = [Collections.Generic.List[string]]::new(); ConfigSaveStatus = $null
        ConfigBackupCreated = $false; ConfigExpectedSha256 = ''; ConfigExpectedMissing = $true
        AutoMaps = $null; CleanupRows = $null; UseConfig = $null
        Preferences = @{ Cleanup = $(if ($stored -and $stored.Cleanup) { @($stored.Cleanup) } else { @() }) }
    }
    try {
        $win = [Window]::new()
        $win.Title = 'CS:S Launcher'
        $win.AppWindow.ResizeClient(1200, 760)
        $root = [Grid]::new()
        $contentRow = [RowDefinition]::new()
        $contentRow.Height = [GridLength]::new(1, [GridUnitType]::Star)
        $footerRow = [RowDefinition]::new()
        $footerRow.Height = [GridLength]::Auto
        $root.RowDefinitions.Add($contentRow)
        $root.RowDefinitions.Add($footerRow)
        $script:LTUi.Root = $root
        $content = [StackPanel]::new()
        $content.Margin = [Thickness]::new(16, 12, 16, 12)
        $content.Spacing = 6
        $formScroll = [ScrollViewer]::new()
        $formScroll.Content = $content
        $formScroll.VerticalScrollBarVisibility = 'Auto'
        $root.Children.Add($formScroll)

        $script:LTUi.Status = New-LTText ''
        $script:LTUi.Status.Margin = 12
        $footer = [StackPanel]::new()
        $footer.Margin = [Thickness]::new(12, 4, 12, 4)
        $footer.Children.Add($script:LTUi.Status)
        [Grid]::SetRow($footer, 1)
        $root.Children.Add($footer)
        $win.Content = $root
        $script:LTUi.Window = $win
        $content.Children.Add((New-LTText 'CS:S Launcher' 'TitleTextBlockStyle'))

        $gameRow = New-LTActionRow $content
        $script:LTUi.LocationStatus = New-LTText 'Finding CS:S…'
        $script:LTUi.LocationStatus.Width = 118
        $script:LTUi.LocationStatus.VerticalAlignment = 'Center'
        $gameRow.Children.Add($script:LTUi.LocationStatus)
        $script:LTUi.GamePath = [TextBox]::new()
        $script:LTUi.GamePath.Width = 420
        $script:LTUi.GamePath.PlaceholderText = 'CS:S folder'
        $script:LTUi.GamePath.Text = if ($stored) { [string]$stored.GamePath } else { '' }
        $script:LTUi.GamePath.Margin = [Thickness]::new(0)
        $gameRow.Spacing = 0
        $gameRow.Children.Add($script:LTUi.GamePath)

        $basicOptions = [StackPanel]::new()
        $basicOptions.Spacing = 3
        $content.Children.Add($basicOptions)
        $script:LTUi.VideoOptIn = Add-LTCheck $basicOptions 'Fix Intro video'
        $script:LTUi.VideoOptIn.IsChecked = ($stored -and $stored.VideoOptIn -eq $true)
        $script:LTUi.ConnectCheck = Add-LTCheck $basicOptions 'Add LamaTeam connect to menu'
        $script:LTUi.ConnectCheck.IsChecked = ($stored -and $stored.Connect -eq $true)
        $configRow = New-LTActionRow $basicOptions
        $script:LTUi.UseConfig = Add-LTCheck $configRow 'Replace config with LamaTeam Modern PC config'
        $script:LTUi.UseConfig.IsChecked = ($stored -and $stored.UseConfig -eq $true)
        $script:LTUi.Profile = [ComboBox]::new()
        $script:LTUi.Profile.Width = 165
        $script:LTUi.Profile.Items.Add('LamaTeam Modern PC')
        $script:LTUi.LegacyOption = [ComboBoxItem]::new()
        $script:LTUi.LegacyOption.Content = 'Rivals.cz Legacy PC'
        $script:LTUi.Profile.Items.Add($script:LTUi.LegacyOption)
        $savedProfile = if ($stored -and $stored.PreferenceVersion -ge 2 -and $stored.ProfileIndex -in @(0, 1)) {
            [int]$stored.ProfileIndex
        } elseif ($stored -and $stored.ProfileIndex -eq 2) { 1 } else { 0 }
        $script:LTUi.Profile.SelectedIndex = $savedProfile
        if ($stored -and $null -eq $stored.PreferenceVersion -and $stored.ProfileIndex -in @(1, 2)) {
            $script:LTUi.UseConfig.IsChecked = $true
        }
        $configRow.Children.Add($script:LTUi.Profile)
        $script:LTUi.AutoMaps = Add-LTCheck $basicOptions 'Automatically download 0 missing maps'
        $script:LTUi.AutoMaps.IsChecked = ($stored -and $stored.AutoMaps -eq $true)
        $script:LTUi.TweakChecks = [ordered]@{}
        $tweakRows = @(
            @('fps_max_300', 'FPS limit 300'),
            @('mat_vsync_off', 'VSync off'),
            @('con_enable', 'Enable console'),
            @('cl_showfps', 'Show FPS'),
            @('net_graph', 'Show net graph'),
            @('m_rawinput', 'Raw mouse input')
        )
        $savedTweaks = if ($stored -and $stored.Tweaks) { @($stored.Tweaks) } else { @() }
        foreach ($tweak in $tweakRows) {
            $check = Add-LTCheck $basicOptions $tweak[1]
            $check.IsChecked = ($tweak[0] -in $savedTweaks)
            $script:LTUi.TweakChecks[$tweak[0]] = $check
            $check.AddChecked({ Save-LTPreferences })
            $check.AddUnchecked({ Save-LTPreferences })
        }
        $integrityRow = New-LTActionRow $basicOptions
        $script:LTUi.ValidateIntegrity = Add-LTCheck $integrityRow 'Validate game integrity'
        $script:LTUi.ValidateIntegrity.IsChecked = ($stored -and $stored.ValidateIntegrity -eq $true)
        $script:LTUi.DisplayRow = New-LTActionRow $basicOptions
        $script:LTUi.MonitorMaxRefreshRate = Add-LTCheck $script:LTUi.DisplayRow 'Use selected monitor maximum refresh rate'
        $script:LTUi.MonitorMaxRefreshRate.IsChecked = $monitorMaxRefreshRate
        $script:LTUi.MonitorMaxRefreshRate.IsEnabled = ($displayModes.Count -gt 0 -and $selectedDisplay -and $selectedDisplay.Available)
        $script:LTUi.DisplayMonitor = [ComboBox]::new()
        $script:LTUi.DisplayMonitor.Width = 220
        foreach ($display in $displayModes) {
            $item = [ComboBoxItem]::new()
            $item.Content = if ($display.IsPrimary) { "$($display.DisplayName) · primary" } else { [string]$display.DisplayName }
            $item.Tag = [string]$display.DeviceName
            $script:LTUi.DisplayMonitor.Items.Add($item)
        }
        if ($selectedDisplay) {
            $selectedIndex = 0
            for ($i = 0; $i -lt $script:LTUi.DisplayMonitor.Items.Count; $i++) {
                if ($script:LTUi.DisplayMonitor.Items[$i].Tag -ceq $selectedDisplay.DeviceName) { $selectedIndex = $i; break }
            }
            $script:LTUi.DisplayMonitor.SelectedIndex = $selectedIndex
        }
        $script:LTUi.DisplayRow.Children.Add($script:LTUi.DisplayMonitor)
        $script:LTUi.DisplayRateLabel = New-LTText $(if ($selectedDisplay) { "$($selectedDisplay.CurrentHz) → $($selectedDisplay.MaxHz) Hz" } else { 'Refresh rate unavailable' })
        $script:LTUi.DisplayRow.Children.Add($script:LTUi.DisplayRateLabel)
        $startupPresetRow = New-LTActionRow $basicOptions
        $script:LTUi.UseLamaStartupOptions = Add-LTCheck $startupPresetRow 'Use LamaTeam startup options'
        $script:LTUi.UseLamaStartupOptions.IsChecked = $useLamaStartupOptions
        $script:LTUi.StartupOptionsState = New-LTText ''
        $startupPresetRow.Children.Add($script:LTUi.StartupOptionsState)
        $script:LTUi.StartupOptions = [TextBox]::new()
        $script:LTUi.StartupOptions.PlaceholderText = if ($steamSettings) { 'Current Steam launch options' } else { 'Steam launch options unavailable' }
        $script:LTUi.StartupOptions.Text = $customStartupOptions
        $basicOptions.Children.Add($script:LTUi.StartupOptions)
        $content.Children.Add((New-LTText 'CS:S config · edits save immediately' 'SubtitleTextBlockStyle'))
        $script:LTUi.ConfigEditor = [RichEditBox]::new()
        $script:LTUi.ConfigEditor.Height = 440
        $script:LTUi.ConfigEditor.AcceptsReturn = $true
        $script:LTUi.ConfigEditor.TextWrapping = 'NoWrap'
        $script:LTUi.ConfigEditor.FontFamily = [FontFamily]::new('Consolas')
        $script:LTUi.ConfigEditor.IsSpellCheckEnabled = $false
        $script:LTUi.ConfigEditor.TabFocusNavigation = 'Local'
        $script:LTUi.ConfigEditor.Document.UndoLimit = 500
        $content.Children.Add($script:LTUi.ConfigEditor)
        $script:LTUi.ConfigSaveStatus = New-LTText 'Detect CS:S to edit its config.'
        $content.Children.Add($script:LTUi.ConfigSaveStatus)
        $script:LTUi.LegacyStatus = New-LTText ''
        $script:LTUi.IntroPreview = New-LTText 'Startup video'

        $script:LTUi.CleanupRows = [StackPanel]::new()
        $script:LTUi.CleanupRows.Spacing = 2
        $basicOptions.Children.Add($script:LTUi.CleanupRows)
        $script:LTUi.CleanupOutcomes = New-LTText ''
        $content.Children.Add($script:LTUi.CleanupOutcomes)
        $playRow = New-LTActionRow $content
        Add-LTAction $playRow 'Apply and play' 'Play' -Primary
        $recoveryRow = New-LTActionRow $content
        $script:LTUi.RecoveryText = New-LTText 'No changes to restore.'
        $recoveryRow.Children.Add($script:LTUi.RecoveryText)
        Add-LTAction $recoveryRow 'Restore' 'Restore'

        $script:LTUi.IntroPreview.Visibility = 'Collapsed'
        $script:LTUi.GamePath.AddTextChanged({
            Save-LTPreferences
            if ($script:LTUi.SuppressDetect -or $script:LTUi.Busy) { return }
            $candidate = $script:LTUi.GamePath.Text.Trim()
            if (-not $candidate -or $candidate -ceq $script:LTUi.LastDetectPath -or
                -not (Test-Path -LiteralPath $candidate -PathType Container)) { return }
            $validGameFolder = (Test-Path -LiteralPath (Join-Path $candidate 'cstrike/gameinfo.txt') -PathType Leaf) -or
                (Test-Path -LiteralPath (Join-Path $candidate 'gameinfo.txt') -PathType Leaf)
            if ($validGameFolder) {
                $script:LTUi.LastDetectPath = $candidate
                Invoke-LTAction 'Detect'
            }
        })
        $script:LTUi.StartupOptions.AddTextChanged({
            if ($script:LTUi.UpdatingStartupOptions) { return }
            if ($script:LTUi.UseLamaStartupOptions.IsChecked -ne $true -and
                $script:LTUi.MonitorMaxRefreshRate.IsChecked -ne $true) {
                $script:LTUi.CustomStartupOptions = [string]$script:LTUi.StartupOptions.Text
            }
            $script:LTUi.StartupOptionsState.Text = if (-not $script:LTUi.SteamSettings) {
                'Current settings unavailable'
            } elseif ($script:LTUi.UseLamaStartupOptions.IsChecked -eq $true) {
                'LamaTeam preset'
            } elseif ($script:LTUi.CustomStartupOptions -ceq $script:LTUi.CurrentStartupOptions) {
                'Current settings'
            } else { 'Custom' }
            Save-LTPreferences
        })
        $script:LTUi.UseLamaStartupOptions.AddChecked({
            if (-not $script:LTUi.UpdatingStartupOptions) {
                Update-LTStartupOptions
            }
        })
        $script:LTUi.UseLamaStartupOptions.AddUnchecked({
            if (-not $script:LTUi.UpdatingStartupOptions) { Update-LTStartupOptions }
        })
        $script:LTUi.MonitorMaxRefreshRate.AddChecked({
            if (-not $script:LTUi.UpdatingStartupOptions) { Update-LTStartupOptions }
        })
        $script:LTUi.MonitorMaxRefreshRate.AddUnchecked({
            if (-not $script:LTUi.UpdatingStartupOptions) { Update-LTStartupOptions }
        })
        $script:LTUi.DisplayMonitor.AddSelectionChanged({
            $item = $script:LTUi.DisplayMonitor.SelectedItem
            if (-not $item) { return }
            $script:LTUi.MonitorDeviceName = [string]$item.Tag
            $display = $script:LTUi.DisplayModes | Where-Object DeviceName -CEQ $script:LTUi.MonitorDeviceName | Select-Object -First 1
            if ($display) {
                $script:LTUi.DisplayRateLabel.Text = "$($display.CurrentHz) → $($display.MaxHz) Hz"
                $script:LTUi.MonitorMaxRefreshRate.IsEnabled = [bool]$display.Available
                if (-not $display.Available -and $script:LTUi.MonitorMaxRefreshRate.IsChecked -eq $true) {
                    $script:LTUi.MonitorMaxRefreshRate.IsChecked = $false
                }
            }
            Save-LTPreferences
            if (-not $script:LTUi.Busy) { Update-LTStartupOptions }
        })
        $script:LTUi.Profile.AddSelectionChanged({
            $script:LTUi.LegacyReview = $null
            Save-LTPreferences
            Update-LTConfigChoiceLabel
            if (-not $script:LTUi.Busy) { Invoke-LTAction 'RefreshPreview' }
        })
        $script:LTUi.UseConfig.AddChecked({ Save-LTPreferences; if (-not $script:LTUi.Busy) { Invoke-LTAction 'RefreshPreview' } })
        $script:LTUi.UseConfig.AddUnchecked({ Save-LTPreferences; if (-not $script:LTUi.Busy) { Invoke-LTAction 'RefreshPreview' } })
        $script:LTUi.ConnectCheck.AddChecked({ Save-LTPreferences })
        $script:LTUi.ConnectCheck.AddUnchecked({ Save-LTPreferences })
        $script:LTUi.VideoOptIn.AddChecked({ Save-LTPreferences })
        $script:LTUi.VideoOptIn.AddUnchecked({ Save-LTPreferences })
        $script:LTUi.AutoMaps.AddChecked({ Save-LTPreferences })
        $script:LTUi.AutoMaps.AddUnchecked({ Save-LTPreferences })
        $script:LTUi.ValidateIntegrity.AddChecked({ Save-LTPreferences })
        $script:LTUi.ValidateIntegrity.AddUnchecked({ Save-LTPreferences })
        $script:LTUi.ConfigEditor.AddTextChanged({
            if ($script:LTUi.ConfigEditorInitializing -or $script:LTUi.ConfigHighlighting) { return }
            $text = Get-LTConfigEditorText
            if ($text -ceq $script:LTUi.ConfigLastText) { return }
            $script:LTUi.ConfigUndo.Add([string]$script:LTUi.ConfigLastText)
            if ($script:LTUi.ConfigUndo.Count -gt 250) { $script:LTUi.ConfigUndo.RemoveAt(0) }
            $script:LTUi.ConfigRedo.Clear()
            $script:LTUi.ConfigLastText = $text
            Save-LTConfigEditorText $text
            Set-LTConfigSyntaxHighlight
        })
        $script:LTUi.ConfigEditor.AddPreviewKeyDown({
            param($argumentList, $sender, $eventArgs)
            $controlState = [InputKeyboardSource]::GetKeyStateForCurrentThread([VirtualKey]::Control)
            if (($controlState -band [CoreVirtualKeyStates]::Down) -eq [CoreVirtualKeyStates]::None) { return }
            switch ([string]$eventArgs.Key) {
                Z { $eventArgs.Handled = $true; Invoke-LTConfigHistory }
                Y { $eventArgs.Handled = $true; Invoke-LTConfigHistory -Redo }
            }
        })
        Update-LTConfigChoiceLabel
        Update-LTStartupOptions

        $closing = [EventCallback]@{
            RunspaceMode = [EventCallbackRunspaceMode]::MainRunspaceSyncUI
            ScriptBlock = {
                param($argumentList, $sender, $eventArgs)
                if ($script:LTUi.Dialog) { $script:LTUi.Dialog.Hide() }
                if ($script:LTUi.Busy) { $eventArgs.Cancel = $true }
            }
        }
        $win.AppWindow.AddClosing($closing)
        Invoke-LTAction 'Detect'
        $win.Activate()
        $win.WaitForClosed()
    } finally { $script:LTUi.Running = $false }
}
