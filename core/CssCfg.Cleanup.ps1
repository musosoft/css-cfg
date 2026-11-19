# Cleanup adapters are trusted injection points for tests. Native adapters re-inspect before each action.
function Test-CssApplicationImage {
    param([string]$Path, [string]$Publisher, [string[]]$ProtectedRoots = @())
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $pathText = $Path.Replace('/', '\')
    if ($pathText -notmatch '^[A-Za-z]:\\' -or $pathText -match '(?:^|\\)\.{1,2}(?:\\|$)' -or $pathText.Substring(2).Contains(':')) { return $false }
    if ($pathText -match '(?i)(?:^|\\)(?:Windows|WindowsApps|System32|SysWOW64|WinSxS)(?:\\|$)') { return $false }
    if ($pathText -match '(?i)(?:^|\\)(?:Steam|SteamVR|Valve|Counter-Strike[^\\]*|cstrike|hl2)(?:\\|$)') { return $false }
    if ($pathText -match '(?i)\\WindowsApps\\') { return $false }
    $roots = @($ProtectedRoots)
    foreach ($root in @($env:SystemRoot, $env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if ($root) {
            if ($root -eq $env:SystemRoot) { $roots += $root } else { $roots += (Join-Path $root 'Steam') }
        }
    }
    foreach ($root in $roots) {
        if (-not $root) { continue }
        $prefix = $root.Replace('/', '\').TrimEnd('\')
        if ($pathText.Equals($prefix, [StringComparison]::OrdinalIgnoreCase) -or $pathText.StartsWith($prefix + '\', [StringComparison]::OrdinalIgnoreCase)) { return $false }
    }
    return $true
}

function Get-CssImageMetadata {
    param([string]$CommandLine)
    $path = $null
    if ($CommandLine -match '^\s*"([^"]+\.exe)"(?:\s|$)') { $path = $Matches[1] }
    elseif ($CommandLine -match '^\s*([^"\r\n]+?\.exe)(?:\s|$)') { $path = $Matches[1] }
    $publisher = $null
    if ($path -and (Test-Path -LiteralPath $path -PathType Leaf)) {
        try { $publisher = [Diagnostics.FileVersionInfo]::GetVersionInfo($path).CompanyName } catch { }
    }
    [pscustomobject]@{ Path = [string]$path; Publisher = [string]$publisher }
}

function Test-CssCleanupItem {
    param($Item, [string[]]$ProtectedRoots = @())
    if ($Item.Kind -notin @('Service','Task') -or -not $Item.Name -or
        -not (Test-CssApplicationImage $Item.Path $Item.Publisher $ProtectedRoots)) { return $false }
    if ($Item.Kind -eq 'Service') {
        if ($Item.Name -match '^(?i:(?:RpcSs|DcomLaunch|RpcEptMapper|RpcLocator|EventLog|PlugPlay|Power|LSM|SamSs|ProfSvc|Schedule|Winmgmt|CryptSvc|BFE|MpsSvc|WdNisSvc|WinDefend|SecurityHealthService|TrustedInstaller|Appinfo|Dhcp|Dnscache|LanmanServer|LanmanWorkstation|NlaSvc|Netlogon|W32Time|WlanSvc|AudioSrv|Audiosrv|Themes|TokenBroker|UserManager|Winlogon|TermService|UsoSvc|wuauserv|BITS|msiserver))$') { return $false }
        return ($Item.Dependents.Count -eq 0 -and $Item.ServiceType -eq 'Own Process' -and
            ($Item.State -eq 'Stopped' -or [bool]$Item.AcceptStop))
    }
    # System tasks and system principals are protected; only single-action tasks are actionable.
    return ($Item.Principal -notmatch '^(?i:SYSTEM|LOCAL SERVICE|NETWORK SERVICE|S-1-5-(?:18|19|20)|NT AUTHORITY\\)' -and
        $Item.ActionCount -eq 1 -and $Item.State -in @('Ready','Disabled'))
}

function Get-CssCleanupKey {
    param($Item)
    "$($Item.Kind):$($Item.TaskPath)$($Item.Name)"
}

function Test-CssCleanupIdentity {
    param($Original, $Current)
    if (-not $Current) { return $false }
    # Fingerprint includes command/action arguments and startup/principal, not merely the friendly name.
    return ((Get-CssCleanupKey $Original) -ceq (Get-CssCleanupKey $Current) -and
        $Original.Path -ieq $Current.Path -and $Original.Publisher -ceq $Current.Publisher -and
        $Original.Fingerprint -ceq $Current.Fingerprint)
}

function Get-CssCleanupFingerprint {
    param([string]$Text)
    $hash = [Security.Cryptography.SHA256]::Create()
    try { [BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))).Replace('-', '').ToLowerInvariant() } finally { $hash.Dispose() }
}

function Get-CssCleanupAdapter {
    if (-not $IsWindows) { throw 'Windows cleanup is unavailable on this platform' }
    @{
        Inspect = {
            foreach ($service in (Get-CimInstance Win32_Service -ErrorAction Stop)) {
                $metadata = Get-CssImageMetadata $service.PathName
                if (-not $metadata.Path) { continue }
                $dependentNames = @()
                try { $dependentNames = @((Get-Service -Name $service.Name -ErrorAction Stop).DependentServices | ForEach-Object Name) } catch { continue }
                [pscustomobject]@{
                    Kind = 'Service'; Name = $service.Name; DisplayName = $service.DisplayName; TaskPath = ''
                    Path = $metadata.Path; Publisher = $metadata.Publisher; PublisherSource = 'FileVersionInfo.CompanyName (unverified)'
                    State = $service.State; Startup = $service.StartMode; Active = ($service.State -eq 'Running'); Enabled = ($service.StartMode -ne 'Disabled')
                    Dependents = $dependentNames; ServiceType = $service.ServiceType; AcceptStop = [bool]$service.AcceptStop
                    Fingerprint = Get-CssCleanupFingerprint "$($service.PathName)|$($service.StartMode)|$($service.StartName)|$($service.ServiceType)"
                }
            }
            foreach ($task in (Get-ScheduledTask -ErrorAction Stop)) {
                $actions = @($task.Actions)
                if ($actions.Count -ne 1 -or -not $actions[0].PSObject.Properties['Execute']) { continue }
                $metadata = Get-CssImageMetadata ('"' + $actions[0].Execute + '"')
                [pscustomobject]@{
                    Kind = 'Task'; Name = $task.TaskName; DisplayName = $task.TaskName; TaskPath = $task.TaskPath
                    Path = $metadata.Path; Publisher = $metadata.Publisher; PublisherSource = 'FileVersionInfo.CompanyName (unverified)'
                    State = [string]$task.State; Startup = 'Scheduled'; Active = ($task.State -eq 'Running'); Enabled = [bool]$task.Settings.Enabled
                    ActionCount = $actions.Count; Principal = [string]$task.Principal.UserId
                    Fingerprint = Get-CssCleanupFingerprint "$($actions | ConvertTo-Json -Depth 8 -Compress)|$($task.Principal | ConvertTo-Json -Depth 8 -Compress)|$($task.Triggers | ConvertTo-Json -Depth 8 -Compress)"
                }
            }
        }
        Change = {
            param($item, $ProtectedRoots)
            $current = Get-CssCurrentCleanupItem (Get-CssCleanupAdapter) $item $ProtectedRoots
            if (($item.Kind -eq 'Service' -and -not $current.Active) -or ($item.Kind -eq 'Task' -and -not $current.Enabled)) { throw 'Cleanup state changed before action' }
            if ($item.Kind -eq 'Service') { Stop-Service -Name $item.Name -ErrorAction Stop } else {
                Disable-ScheduledTask -TaskPath $item.TaskPath -TaskName $item.Name -ErrorAction Stop | Out-Null
            }
        }
        Restore = {
            param($item, $ProtectedRoots)
            $current = Get-CssCurrentCleanupItem (Get-CssCleanupAdapter) $item $ProtectedRoots
            if (($item.Kind -eq 'Service' -and $current.State -ne 'Stopped') -or ($item.Kind -eq 'Task' -and $current.Enabled)) { throw 'Changed state no longer matches before restore' }
            if ($item.Kind -eq 'Service') { Start-Service -Name $item.Name -ErrorAction Stop } else {
                Enable-ScheduledTask -TaskPath $item.TaskPath -TaskName $item.Name -ErrorAction Stop | Out-Null
            }
        }
    }
}

function Get-CssCleanupInspection {
    param([hashtable]$Adapter, [string[]]$ProtectedRoots = @())
    if (-not $Adapter) { $Adapter = Get-CssCleanupAdapter }
    foreach ($item in (& $Adapter.Inspect)) {
        if (Test-CssCleanupItem $item $ProtectedRoots) {
            $copy = $item.PSObject.Copy()
            $copy | Add-Member -NotePropertyName Selected -NotePropertyValue $false -Force
            $copy
        }
    }
}

function Get-CssCurrentCleanupItem {
    param([hashtable]$Adapter, $Original, [string[]]$ProtectedRoots)
    $key = Get-CssCleanupKey $Original
    $matches = @(Get-CssCleanupInspection -Adapter $Adapter -ProtectedRoots $ProtectedRoots | Where-Object { (Get-CssCleanupKey $_) -ceq $key })
    if ($matches.Count -ne 1 -or -not (Test-CssCleanupIdentity $Original $matches[0])) { throw 'Cleanup item disappeared, changed identity, or is now protected' }
    $matches[0]
}

function Read-CssCleanupJournal {
    param([string]$JournalPath)
    if (-not (Test-Path -LiteralPath $JournalPath)) { return $null }
    $journal = Read-CssState $JournalPath
    if (-not $journal -or -not $journal.PSObject.Properties['Version'] -or $journal.Version -ne 2 -or
        -not $journal.PSObject.Properties['Entries'] -or $journal.Entries -isnot [array]) {
        throw 'Malformed or unsupported cleanup journal; no automatic repair attempted.'
    }
    foreach ($entry in $journal.Entries) {
        foreach ($field in @('Key','Item','Status','Error','Utc')) {
            if (-not $entry -or -not $entry.PSObject.Properties[$field]) { throw 'Malformed cleanup journal entry.' }
        }
        if ($entry.Status -notin @('Pending','Changed','RestoreFailed','Restored') -or -not $entry.Item -or
            $entry.Item.Kind -notin @('Service','Task') -or $entry.Key -cne (Get-CssCleanupKey $entry.Item)) {
            throw 'Malformed cleanup journal entry.'
        }
        foreach ($field in @('Name','TaskPath','Path','Publisher','Fingerprint','State','Startup','Active','Enabled')) {
            if (-not $entry.Item.PSObject.Properties[$field]) { throw 'Malformed cleanup journal item.' }
        }
    }
    $journal
}

function Invoke-CssCleanup {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$JournalPath, [string[]]$SelectedKeys = @(), [hashtable]$Adapter,
        [switch]$Restore, [string[]]$ProtectedRoots = @(), [Collections.Generic.List[object]]$OutcomeBuffer)
    if (-not $Restore -and $SelectedKeys.Count -eq 0) { return }
    if ($Restore -and -not (Test-Path -LiteralPath $JournalPath)) { return }
    if (-not $Adapter) { $Adapter = Get-CssCleanupAdapter }
    $JournalPath = [IO.Path]::GetFullPath($JournalPath)
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($JournalPath))
    $lock = [IO.File]::Open("$JournalPath.lock", [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $journal = Read-CssCleanupJournal $JournalPath
        if (-not $journal) { $journal = [pscustomobject]@{ Version = 2; Entries = @() } }
        if ($journal.Version -ne 2) { throw 'Unsupported cleanup journal version; inspect older journal manually, no automatic restore' }
        if ($Restore) {
            foreach ($entry in @($journal.Entries)) {
                if ($null -ne $OutcomeBuffer) { $OutcomeBuffer.Add($entry) }
                if ($entry.Status -eq 'Pending') { Write-Warning "Uncertain action requires manual inspection: $($entry.Key)"; $entry; continue }
                if ($entry.Status -notin @('Changed','RestoreFailed')) { $entry; continue }
                try {
                    if (-not (Test-CssCleanupItem $entry.Item $ProtectedRoots)) { throw 'Journal item is no longer eligible' }
                    $current = Get-CssCurrentCleanupItem $Adapter $entry.Item $ProtectedRoots
                    $originallyEligible = if ($entry.Item.Kind -eq 'Service') { $entry.Item.Active } else { $entry.Item.Enabled }
                    $stillChanged = if ($entry.Item.Kind -eq 'Service') { $current.State -eq 'Stopped' -and $current.Startup -eq $entry.Item.Startup } else { -not $current.Enabled -and $current.State -eq 'Disabled' }
                    if (-not $originallyEligible -or -not $stillChanged) { throw 'RestoreConflict: original eligibility or app-changed state no longer matches; no action taken' }
                    $null = & $Adapter.Restore $entry.Item $ProtectedRoots
                    $after = Get-CssCurrentCleanupItem $Adapter $entry.Item $ProtectedRoots
                    if (($entry.Item.Kind -eq 'Service' -and -not $after.Active) -or ($entry.Item.Kind -eq 'Task' -and -not $after.Enabled)) { throw 'Restore did not reach the original running/enabled state' }
                    $entry.Status = 'Restored'; $entry.Error = $null
                } catch { $entry.Status = 'RestoreFailed'; $entry.Error = 'Restore could not be verified; entry retained for inspection/retry.' }
                Save-CssState $JournalPath $journal
                $entry
            }
        } else {
            $items = @(Get-CssCleanupInspection -Adapter $Adapter -ProtectedRoots $ProtectedRoots)
            foreach ($key in $SelectedKeys) {
                if (@($items | Where-Object { (Get-CssCleanupKey $_) -ceq $key }).Count -ne 1) { throw "Ineligible cleanup selection: $key" }
                if (@($journal.Entries | Where-Object { $_.Key -eq $key -and $_.Status -in @('Pending','Changed','RestoreFailed') }).Count) { throw 'Unresolved cleanup journal entry; restore or inspect recovery before applying.' }
            }
            foreach ($original in $items) {
                $key = Get-CssCleanupKey $original
                if ($key -cnotin $SelectedKeys) { continue }
                $item = Get-CssCurrentCleanupItem $Adapter $original $ProtectedRoots
                if (($item.Kind -eq 'Service' -and -not $item.Active) -or ($item.Kind -eq 'Task' -and -not $item.Enabled)) {
                    $skipped = [pscustomobject]@{ Key = $key; Item = $item; Status = 'Skipped'; Error = 'Item is no longer running/enabled; no action or journal ownership claimed'; Utc = [DateTime]::UtcNow.ToString('o') }
                    if ($null -ne $OutcomeBuffer) { $OutcomeBuffer.Add($skipped) }
                    $skipped
                    continue
                }
                $entry = [pscustomobject]@{ Key = $key; Item = $item; Status = 'Pending'; Error = $null; Utc = [DateTime]::UtcNow.ToString('o') }
                if ($null -ne $OutcomeBuffer) { $OutcomeBuffer.Add($entry) }
                $journal.Entries = @($journal.Entries) + @($entry)
                Save-CssState $JournalPath $journal # Write-ahead intent: no operation if persistence fails.
                try {
                    $null = & $Adapter.Change $item $ProtectedRoots
                    $after = Get-CssCurrentCleanupItem $Adapter $item $ProtectedRoots
                    if (($item.Kind -eq 'Service' -and $after.State -ne 'Stopped') -or ($item.Kind -eq 'Task' -and $after.Enabled)) { throw 'Requested changed state was not verified' }
                    $entry.Status = 'Changed'
                } catch { $entry.Error = 'Cleanup action could not be verified; pending intent requires manual inspection.' } # Pending is uncertain, never auto-restored.
                Save-CssState $JournalPath $journal
                $entry
            }
        }
    } finally { $lock.Dispose() }
}
