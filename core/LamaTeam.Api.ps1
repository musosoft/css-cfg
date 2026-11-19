# Public facade for LamaTeam.App.ps1. No UI/bootstrap, networking or system actions on import.
function Resolve-LamaTeamRoot {
    param($Game, [string]$GameRoot)
    if ($Game -is [string]) { $GameRoot = $Game }
    elseif ($Game) {
        if ($Game.PSObject.Properties['Root']) { $GameRoot = $Game.Root }
        elseif ($Game.PSObject.Properties['GameRoot']) { $GameRoot = $Game.GameRoot }
    }
    if (-not $GameRoot) { throw 'Supply a validated Game object or explicit GameRoot' }
    $root = [IO.Path]::GetFullPath($GameRoot)
    if ((Split-Path $root -Leaf) -ieq 'cstrike') { $root = Split-Path $root -Parent }
    if (-not (Test-Path -LiteralPath (Join-Path $root 'cstrike/gameinfo.txt') -PathType Leaf)) {
        throw 'Invalid CS:S root: require cstrike/gameinfo.txt'
    }
    $root
}

function Find-LamaTeamGame {
    [CmdletBinding()]
    param([string]$Path, [string[]]$SteamRoots = @(), [string[]]$GameRoots = @())
    if ($Path) { $root = Resolve-LamaTeamRoot -GameRoot $Path; return [pscustomobject]@{ Root = $root; GameRoot = $root; Cstrike = Join-Path $root 'cstrike' } }
    $games = @(Get-CssGameInstall -SteamRoots $SteamRoots -GameRoots $GameRoots)
    if ($games.Count -gt 1) { throw 'Multiple CS:S installations found; choose one using Find-LamaTeamGame -Path' }
    if ($games.Count -eq 1) { $games[0] }
}

function Get-LamaTeamPaths {
    [CmdletBinding()]
    param($Game, [string]$GameRoot, [string]$StateRoot = (Get-CssConfiguration).StateRoot)
    $config = Get-CssConfiguration -StateRoot ([IO.Path]::GetFullPath($StateRoot))
    $root = if ($Game -or $GameRoot) { Resolve-LamaTeamRoot $Game $GameRoot } else { $null }
    $cstrike = if ($root) { Join-Path $root 'cstrike' } else { $null }
    $media = $null
    if ($root) {
        foreach ($relative in @('hl2/media','cstrike/media')) {
            $candidate = Join-Path $root $relative
            if (Test-Path -LiteralPath (Join-Path $candidate 'valve.bik') -PathType Leaf) { $media = $candidate; break }
        }
    }
    $legacy = $null; $legacyError = $null
    try { $legacy = Get-CssConfigPlan -Profile Legacy -AssetRoot $config.AssetRoot } catch { $legacyError = $_.Exception.Message }
    $backupDirectory = if ($cstrike) { Join-Path $cstrike 'cfg/lamateam-backups' } else { $null }
    $id = [guid]::NewGuid().ToString('N')
    [pscustomobject]@{
        Server = $config.Server; FastDlOrigin = $config.FastDlOrigin; CatalogUri = $config.CatalogUri
        StateRoot = $config.StateRoot; ProfilePath = $config.ProfilePath; SessionPath = $config.SessionPath
        JournalPath = $config.JournalPath; RecoveryPath = $config.JournalPath; AssetRoot = $config.AssetRoot
        Root = $root; GameRoot = $root; Cstrike = $cstrike
        ConfigPath = $(if ($cstrike) { Join-Path $cstrike 'cfg/autoexec.cfg' })
        ConnectPath = $(if ($cstrike) { Join-Path $cstrike 'cfg/autoexec.cfg' })
        GameMenuPath = $(if ($cstrike) { Join-Path $cstrike 'custom/lamateam/resource/GameMenu.res' })
        BackupDirectory = $backupDirectory
        ConfigBackupPath = $(if ($backupDirectory) { Join-Path $backupDirectory "autoexec-config-$id.bak" })
        ConnectBackupPath = $(if ($backupDirectory) { Join-Path $backupDirectory "autoexec-connect-$id.bak" })
        GameMenuBackupPath = $(if ($backupDirectory) { Join-Path $backupDirectory "GameMenu-$id.bak" })
        MapsPath = $(if ($cstrike) { Join-Path $cstrike 'download/maps' })
        MapsDirectory = $(if ($cstrike) { Join-Path $cstrike 'download/maps' })
        DefaultMapsPath = $(if ($cstrike) { Join-Path $cstrike 'maps' })
        MediaDirectory = $media
        IntroSourcePath = $(if ($media) { Join-Path $media 'valve.bik' })
        IntroTargetPath = $(if ($media) { Join-Path $media 'valve.webm' })
        IntroBackupPath = $(if ($media) { Join-Path $media "valve.webm.$id.bak" })
        IntroTargetBackupPermitted = $false; ConverterPath = Find-CssFfmpeg
        LegacyAssetAvailable = [bool]$legacy; LegacyAssetPath = $(if ($legacy) { Join-Path $config.AssetRoot $legacy.Files[0].Source })
        LegacySourceYear = 2016; LegacySourceCommit = '22604b7c4c4ac3553c684f343926c18f5a083799'
        LegacySourceSha256 = $(if ($legacy) { $legacy.ReviewSha256 }); LegacyUnavailableReason = $legacyError
    }
}

function Get-LamaTeamConfigPreview {
    [CmdletBinding()]
    param([Parameter(Mandatory)][ValidateSet('Modern','Legacy')][string]$Profile,
        [string]$AssetRoot = (Get-CssConfiguration).AssetRoot, [switch]$IncludeConnect)
    $plan = Get-CssConfigPlan -Profile $Profile -AssetRoot $AssetRoot -IncludeConnect:$IncludeConnect
    $text = @($plan.Files | ForEach-Object Content) -join "`n`n"
    [pscustomobject]@{
        Profile = $plan.Profile; Label = $plan.Label; Text = $text -join "`n"; Warnings = $plan.Warnings
        Files = @($plan.Files | ForEach-Object Source); Assets = @($plan.Files | Select-Object Source,Target,Content,Sha256)
        ReviewRequired = $plan.ReviewRequired; ReviewSha256 = $plan.ReviewSha256
        IncludeConnect = [bool]$IncludeConnect
        ConnectAlias = $(if ($IncludeConnect) { 'alias lama "connect 82.208.17.101:27516"' })
        SourceCommit = $(if ($Profile -eq 'Legacy') { '22604b7c4c4ac3553c684f343926c18f5a083799' })
        SourceYear = $(if ($Profile -eq 'Legacy') { 2016 })
    }
}

function Assert-LamaTeamPaths {
    param($Paths, [string]$Root)
    if (-not $Paths) { return }
    foreach ($entry in @(@('ConfigPath','cstrike/cfg/autoexec.cfg'), @('ConnectPath','cstrike/cfg/autoexec.cfg'), @('GameMenuPath','cstrike/custom/lamateam/resource/GameMenu.res'))) {
        if (-not $Paths.PSObject.Properties[$entry[0]] -or
            [IO.Path]::GetFullPath([string]$Paths.($entry[0])) -cne [IO.Path]::GetFullPath((Join-Path $Root $entry[1]))) { throw "Paths object does not belong to this game's $($entry[0]); detect again" }
    }
}

function Install-LamaTeamConfig {
    [CmdletBinding()]
    param($Game, $Paths, [string]$GameRoot, [Parameter(Mandatory)][ValidateSet('Modern','Legacy')][string]$Profile,
        [string]$ReviewedSha256, [string]$AssetRoot = (Get-CssConfiguration).AssetRoot)
    $root = Resolve-LamaTeamRoot $Game $GameRoot; Assert-LamaTeamPaths $Paths $root
    if (-not $Paths) { $Paths = Get-LamaTeamPaths -GameRoot $root }
    Install-CssConfig -Cstrike (Join-Path $root 'cstrike') -Profile $Profile -ReviewedSha256 $ReviewedSha256 -AssetRoot $AssetRoot -ConfigBackupPath $Paths.ConfigBackupPath -MenuBackupPath $Paths.GameMenuBackupPath
}

function Set-LamaTeamPlayerConfig {
    [CmdletBinding()]
    param($Game, $Paths, [string]$GameRoot,
        [ValidateSet('Modern','Legacy')][string]$Profile, [string[]]$Tweaks = @(),
        [string]$ReviewedSha256, [string]$AssetRoot = (Get-CssConfiguration).AssetRoot,
        [AllowEmptyString()][string]$Content, [switch]$BackupAlreadyCreated,
        [string]$ExpectedSha256, [switch]$ExpectedMissing)
    $root = Resolve-LamaTeamRoot $Game $GameRoot
    Assert-LamaTeamPaths $Paths $root
    if (-not $Paths) { $Paths = Get-LamaTeamPaths -GameRoot $root }
    $arguments = @{
        Cstrike = Join-Path $root 'cstrike'; Tweaks = $Tweaks
        ReviewedSha256 = $ReviewedSha256; AssetRoot = $AssetRoot
        ConfigBackupPath = $Paths.ConfigBackupPath
    }
    if ($PSBoundParameters.ContainsKey('Content')) { $arguments.Content = $Content }
    if ($BackupAlreadyCreated) { $arguments.BackupAlreadyCreated = $true }
    if ($ExpectedSha256) { $arguments.ExpectedSha256 = $ExpectedSha256 }
    if ($ExpectedMissing) { $arguments.ExpectedMissing = $true }
    if ($Profile) { $arguments.Profile = $Profile }
    Set-CssPlayerConfig @arguments
}

function Save-LamaTeamConfigText {
    [CmdletBinding()]
    param($Game, $Paths, [string]$GameRoot, [Parameter(Mandatory)][AllowEmptyString()][string]$Content,
        [switch]$BackupAlreadyCreated, [string]$ExpectedSha256, [switch]$ExpectedMissing)
    $arguments = @{
        Game = $Game; Paths = $Paths; GameRoot = $GameRoot
        Content = $Content; Tweaks = [string[]]@()
        BackupAlreadyCreated = $BackupAlreadyCreated
        ExpectedSha256 = $ExpectedSha256; ExpectedMissing = $ExpectedMissing
    }
    Set-LamaTeamPlayerConfig @arguments
}

function Add-LamaTeamConnect {
    [CmdletBinding()]
    param($Game, $Paths, [string]$GameRoot)
    $root = Resolve-LamaTeamRoot $Game $GameRoot; Assert-LamaTeamPaths $Paths $root
    if (-not $Paths) { $Paths = Get-LamaTeamPaths -GameRoot $root }
    $menuSource = Join-Path (Get-CssConfiguration).AssetRoot 'gamemenu.res'
    if (-not (Test-Path -LiteralPath $menuSource -PathType Leaf)) { throw 'MissingAsset: gamemenu.res. No connection files changed.' }
    $menuBytes = [IO.File]::ReadAllBytes($menuSource)
    $aliasPlan = Get-CssServerAliasPlan -Path $Paths.ConnectPath
    $menuChanged = -not ((Test-Path -LiteralPath $Paths.GameMenuPath -PathType Leaf) -and
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($Paths.GameMenuPath)) -ceq [Convert]::ToBase64String($menuBytes))
    $operations = @(
        [pscustomobject]@{ Kind='Alias'; Path=$Paths.ConnectPath; PlannedBackup=$Paths.ConnectBackupPath; Changed=$aliasPlan.Changed; Bytes=$aliasPlan.Bytes; Backup=$null },
        [pscustomobject]@{ Kind='Menu'; Path=$Paths.GameMenuPath; PlannedBackup=$Paths.GameMenuBackupPath; Changed=$menuChanged; Bytes=$menuBytes; Backup=$null }
    )
    # Known backup/target conflicts are checked before modifying either connection target.
    foreach ($operation in $operations) {
        if (-not $operation.Changed) { continue }
        if ((Test-Path -LiteralPath $operation.Path) -and -not (Test-Path -LiteralPath $operation.Path -PathType Leaf)) { throw "Connection target is not a file: $($operation.Path). No files changed." }
        if ((Test-Path -LiteralPath $operation.Path -PathType Leaf) -and (Test-Path -LiteralPath $operation.PlannedBackup)) {
            throw "Planned backup already exists: $($operation.PlannedBackup). Refresh/re-detect paths before replacing $($operation.Path). No files changed."
        }
    }
    # Preserve both originals before the first target write. Later I/O failures are not a multi-file transaction.
    foreach ($operation in $operations) {
        if ($operation.Changed) { $operation.Backup = Backup-CssFile -Path $operation.Path -BackupPath $operation.PlannedBackup }
    }
    foreach ($operation in $operations) {
        if ($operation.Changed) { Write-CssAtomicFile -Path $operation.Path -Bytes $operation.Bytes }
        [pscustomobject]@{ Kind=$operation.Kind; Path=$operation.Path; Changed=$operation.Changed; Backup=$operation.Backup; Status=$(if ($operation.Changed) { 'Installed' } else { 'Unchanged' }) }
    }
}

function Get-LamaTeamMaps {
    [CmdletBinding()]
    param($Game, [string]$GameRoot, [string]$Text, [ValidateSet('Lines','Csv')][string]$Format = 'Lines',
        [string]$Column = 'map', [hashtable]$HttpAdapter)
    if ($PSBoundParameters.ContainsKey('Text')) { $names = @(ConvertFrom-CssMapList -Text $Text -Format $Format -Column $Column) }
    else { $names = @(Get-CssMapCatalog -HttpAdapter $HttpAdapter) }
    if ($names.Count -eq 0) { throw 'Empty map catalog' }
    $paths = if ($Game -or $GameRoot) { Get-LamaTeamPaths -GameRoot (Resolve-LamaTeamRoot $Game $GameRoot) } else { $null }
    foreach ($name in $names) {
        $installed = $false
        if ($paths) { foreach ($dir in @($paths.MapsDirectory,$paths.DefaultMapsPath)) { if (Test-CssBsp (Join-Path $dir "$name.bsp")) { $installed = $true; break } } }
        [pscustomobject]@{ Name = $name; Status = $(if ($installed) { 'Installed' } else { 'Missing' }); Uri = (Get-CssMapUri $name).AbsoluteUri }
    }
}

function Sync-LamaTeamMaps {
    [CmdletBinding()]
    param($Game, [string]$GameRoot, [object[]]$Maps, [string[]]$Names, [string]$FastDlDirectory = 'maps',
        [scriptblock]$Progress, [scriptblock]$Downloader, [scriptblock]$Decompressor,
        [scriptblock]$ExtractorDiscovery, [hashtable]$HttpAdapter)
    $root = Resolve-LamaTeamRoot $Game $GameRoot; $paths = Get-LamaTeamPaths -GameRoot $root
    if ($PSBoundParameters.ContainsKey('Maps')) { $Names = @($Maps | ForEach-Object { if ($_ -is [string]) { $_ } else { $_.Name } }) }
    if (-not $Names -or $Names.Count -eq 0) { throw 'No maps selected; scan a nonempty catalog first' }
    $results = @(Sync-CssMaps -Names $Names -Destination $paths.MapsDirectory -ExistingDirectories @($paths.DefaultMapsPath) -FastDlDirectory $FastDlDirectory -Progress $Progress -Downloader $Downloader -Decompressor $Decompressor -ExtractorDiscovery $ExtractorDiscovery -HttpAdapter $HttpAdapter)
    # Public UI contract: return EVERY per-map outcome, including Failed/Error records.
    # Throwing here discards the UI's `$result = ...` assignment and hides useful History details.
    # Invalid game/selection still fails before sync; a per-map failure is data, not a batch exception.
    $results
}

function Get-LamaTeamCleanupCandidates {
    [CmdletBinding()]
    param([hashtable]$ServiceTaskAdapter, [hashtable]$ProcessAdapter, [string[]]$ProtectedRoots = @())
    $rows = [Collections.Generic.List[object]]::new()
    $subsystems = [Collections.Generic.List[object]]::new()
    $serviceItems = @()
    $serviceError = $null
    try { $serviceItems = @(Get-CssCleanupInspection -Adapter $ServiceTaskAdapter -ProtectedRoots $ProtectedRoots -ErrorAction Stop) }
    catch { $serviceError = 'Service/task inspection unavailable; no changes were made.' }
    foreach ($kind in @('Service','Task')) { $subsystems.Add([pscustomobject]@{ Kind=$kind; Available=($null -eq $serviceError); Error=$serviceError }) }
    foreach ($item in $serviceItems) {
        if (($item.Kind -eq 'Service' -and -not $item.Active) -or
            ($item.Kind -eq 'Task' -and ($item.State -ne 'Ready' -or -not $item.Enabled))) { continue }
        $eligible = if ($item.Kind -eq 'Service') { $item.Active } else { $item.Enabled }
        $rows.Add([pscustomobject]@{
            Kind = $item.Kind; Key = Get-CssCleanupKey $item; Name = $item.Name; DisplayName = $item.DisplayName
            Path = $item.Path; Publisher = $item.Publisher; PublisherSource = $item.PublisherSource; Id = $null
            TaskPath = $item.TaskPath; State = $item.State; Startup = $item.Startup
            Active = $item.Active; Enabled = $item.Enabled; Selected = $false; Eligible = [bool]$eligible; CanApply = [bool]$eligible
            Risk = 'Optional application interruption'; Details = 'Selected services stop without startup changes; selected tasks disable without ending running tasks. Restore is state-checked and journaled.'
            Restorable = $true; RestoreStatus = 'Journaled restore'; Warning = $null
        })
    }
    $processItems = @(); $processError = $null
    try { $processItems = @(Get-CssProcessInspection -Adapter $ProcessAdapter -ProtectedRoots $ProtectedRoots -ErrorAction Stop) }
    catch { $processError = 'Process inspection unavailable; no changes were made.' }
    $subsystems.Add([pscustomobject]@{ Kind='Process'; Available=($null -eq $processError); Error=$processError })
    foreach ($item in $processItems) {
        $rows.Add([pscustomobject]@{
            Kind = 'Process'; Key = $item.Key; Name = $item.Name; DisplayName = $item.Name; Path = $item.Path; Publisher = $item.Publisher
            PublisherSource = $item.PublisherSource; Id = $item.Id; TaskPath = $null; State = 'Running'; Startup = $null
            Active = $true; Enabled = $null; Selected = $false; Eligible = $item.CanClose; CanApply = $item.CanClose
            Risk = 'NOT RESTORABLE — possible unsaved work loss'; Details = $item.Warning
            Restorable = $false; RestoreStatus = 'NOT RESTORABLE'; Warning = $item.Warning
        })
    }
    [pscustomobject]@{ Items=$rows.ToArray(); Subsystems=$subsystems.ToArray() }
}

function New-LamaTeamCleanupResult {
    param([object[]]$Items = @(), [string]$Error, [string[]]$SuccessStatuses)
    $successes = @($Items | Where-Object Status -in $SuccessStatuses).Count
    $status = if (-not $Error -and $successes -eq $Items.Count) { 'Succeeded' } elseif ($successes -gt 0) { 'Partial' } else { 'Failed' }
    [pscustomobject]@{ Status=$status; Items=@($Items); Error=$(if ($Error) { $Error } else { $null }) }
}

function Apply-LamaTeamCleanup {
    [CmdletBinding()]
    param([string[]]$SelectedKeys = @(), [Alias('RecoveryPath')][string]$JournalPath = (Get-CssConfiguration).JournalPath,
        [switch]$AcknowledgeNotRestorable, [hashtable]$ServiceTaskAdapter, [hashtable]$ProcessAdapter, [string[]]$ProtectedRoots = @())
    $results = [Collections.Generic.List[object]]::new()
    if ($SelectedKeys.Count -eq 0) { return New-LamaTeamCleanupResult -SuccessStatuses @('Changed','CloseRequested') }
    $processKeys = @($SelectedKeys | Where-Object { $_ -clike 'Process:*' }); $otherKeys = @($SelectedKeys | Where-Object { $_ -cnotlike 'Process:*' })
    if ($processKeys.Count -gt 0 -and -not $AcknowledgeNotRestorable) {
        throw 'Explicit AcknowledgeNotRestorable is required before any process close request.'
    }
    $operationError = $null
    try {
        if ($otherKeys.Count -gt 0) {
            $null = Invoke-CssCleanup -JournalPath $JournalPath -SelectedKeys $otherKeys -Adapter $ServiceTaskAdapter -ProtectedRoots $ProtectedRoots -OutcomeBuffer $results -ErrorAction Stop
        }
        if ($processKeys.Count -gt 0) {
            Invoke-CssProcessClose -SelectedKeys $processKeys -AcknowledgeNotRestorable -Adapter $ProcessAdapter -ProtectedRoots $ProtectedRoots -ErrorAction Stop | ForEach-Object { $results.Add($_) }
        }
    } catch { $operationError = 'Cleanup could not complete; inspect outcomes and recovery journal before retrying. Processes cannot be restored.' }
    New-LamaTeamCleanupResult -Items $results.ToArray() -Error $operationError -SuccessStatuses @('Changed','CloseRequested')
}

function Restore-LamaTeamCleanup {
    [CmdletBinding()]
    param([Alias('RecoveryPath')][string]$JournalPath = (Get-CssConfiguration).JournalPath, [hashtable]$ServiceTaskAdapter, [string[]]$ProtectedRoots = @())
    $results = [Collections.Generic.List[object]]::new(); $operationError = $null
    try { $null = Invoke-CssCleanup -JournalPath $JournalPath -Restore -Adapter $ServiceTaskAdapter -ProtectedRoots $ProtectedRoots -OutcomeBuffer $results -ErrorAction Stop }
    catch { $operationError = 'Recovery could not complete; journal retained for inspection/retry.' }
    New-LamaTeamCleanupResult -Items $results.ToArray() -Error $operationError -SuccessStatuses @('Restored')
}

function Get-LamaTeamCleanupRecovery {
    [CmdletBinding()]
    param([Alias('RecoveryPath')][string]$JournalPath = (Get-CssConfiguration).JournalPath)
    # Read only: deliberately no adapter, lock, directory creation or Save-CssState.
    $exists = $false
    try {
        $exists = Test-Path -LiteralPath $JournalPath -ErrorAction Stop
        $journal = Read-CssCleanupJournal $JournalPath
        $items = @()
        if ($journal) {
            $items = @($journal.Entries | ForEach-Object {
                $copy = $_.PSObject.Copy()
                if ($copy.Error) { $copy.Error = 'Previous action was not verified; inspect this recovery entry before retrying.' }
                $copy
            })
        }
        [pscustomobject]@{ Exists=[bool]$exists; Status=$(if ($exists) { 'Available' } else { 'Missing' }); Items=$items; Error=$null }
    } catch {
        [pscustomobject]@{ Exists=[bool]$exists; Status='Error'; Items=@(); Error='Cleanup journal is unreadable, malformed or unsupported; no repair or changes attempted.' }
    }
}

function Convert-LamaTeamIntroVideo {
    [CmdletBinding()]
    param($Game, $Paths, [string]$GameRoot, [string]$MediaDirectory, [switch]$OptIn, [string]$FfmpegPath,
        [switch]$BackupExisting, [string]$BackupPath, [hashtable]$VideoAdapter, [hashtable]$HttpAdapter)
    if (-not $MediaDirectory) {
        $root = Resolve-LamaTeamRoot $Game $GameRoot; Assert-LamaTeamPaths $Paths $root
        if (-not $Paths) { $Paths = Get-LamaTeamPaths -GameRoot $root }
        $MediaDirectory = $Paths.MediaDirectory
        if (-not $FfmpegPath) { $FfmpegPath = $Paths.ConverterPath }
        if (-not $BackupPath) { $BackupPath = $Paths.IntroBackupPath }
    }
    if (-not $MediaDirectory) { throw 'valve.bik media directory not found; no conversion attempted' }
    $result = Convert-CssValveVideo -MediaDirectory $MediaDirectory -OptIn:$OptIn -FfmpegPath $FfmpegPath -BackupExisting:$BackupExisting -BackupPath $BackupPath -VideoAdapter $VideoAdapter -HttpAdapter $HttpAdapter
    if ($Paths -and $Paths.PSObject.Properties['ConverterPath']) { $Paths.ConverterPath = $result.ConverterPath }
    return $result
}
