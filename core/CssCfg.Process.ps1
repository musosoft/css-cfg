# Private process helpers, dot-sourced by CssCfg.Core.psm1. No actions on load.
# Running user-session apps are discoverable; OS-critical and game/Steam processes are protected.
function Get-CssProcessWarning {
    'NOT RESTORABLE: closing a process can lose unsaved work. Process termination is not reversible; relaunches and session recovery are not guaranteed. Only a graceful CloseMainWindow request is attempted; prompts may remain open. This action is NOT included in service/task restore.'
}

function Test-CssProcessCandidate {
    param($Item, [string[]]$ProtectedRoots = @())
    if ($Item.Id -le 0 -or $Item.Id -eq $PID -or $Item.StartTimeUtcTicks -le 0 -or
        $Item.SessionId -ne $Item.CurrentSessionId) { return $false }
    if ($Item.Name -match '^(?i:(?:System|Registry|smss|csrss|wininit|services|lsass|winlogon|svchost|fontdrvhost|dwm|MsMpEng|NisSrv|SecurityHealthService|Sense|TrustedInstaller|Steam|steamwebhelper|hl2|cs2|css|WinUIShell\.Server))$') { return $false }
    if (-not (Test-CssApplicationImage ([string]$Item.Path) ([string]$Item.Publisher) $ProtectedRoots)) { return $false }
    # Missing/relative paths and traversal are not eligible. Do not infer trust from a process name.
    $path = ([string]$Item.Path).Replace('/', '\')
    if ($path -notmatch '^[A-Za-z]:\\' -or $path -match '(?:^|\\)\.{1,2}(?:\\|$)' -or
        $path.Substring(2).Contains(':')) { return $false }
    return $true
}

function ConvertTo-CssNativeProcessItem {
    param([Diagnostics.Process]$Process)
    try {
        $path = $Process.Path
        $publisher = $null
        # Company metadata is display data, not proof of a verified signer.
        if ($path) { try { $publisher = [Diagnostics.FileVersionInfo]::GetVersionInfo($path).CompanyName } catch { } }
        [pscustomobject]@{
            Id = $Process.Id; Name = $Process.ProcessName; Path = $path; Publisher = $publisher
            PublisherSource = 'FileVersionInfo.CompanyName (unverified)'
            StartTimeUtcTicks = $Process.StartTime.ToUniversalTime().Ticks
            SessionId = $Process.SessionId; CurrentSessionId = [Diagnostics.Process]::GetCurrentProcess().SessionId
            HasMainWindow = ($Process.MainWindowHandle -ne [IntPtr]::Zero)
        }
    } catch {
        # Exited/inaccessible processes are not selectable; never guess identity or path.
    }
}

function Get-CssProcessAdapter {
    if (-not $IsWindows) { throw 'Windows process inspection is unavailable on this platform' }
    @{
        Inspect = {
            foreach ($process in (Get-Process -ErrorAction Stop)) {
                try { ConvertTo-CssNativeProcessItem $process } finally { $process.Dispose() }
            }
        }
        Close = {
            param($Item, $ProtectedRoots)
            $process = $null
            try {
                $process = Get-Process -Id $Item.Id -ErrorAction SilentlyContinue
                if (-not $process) { return 'GoneOrChanged' }
                $current = ConvertTo-CssNativeProcessItem $process
                if (-not $current -or -not (Test-CssProcessCandidate $current $ProtectedRoots)) { return 'GoneOrChanged' }
                # Recheck start time AND executable path immediately before requesting close, not just PID.
                if ($current.StartTimeUtcTicks -ne $Item.StartTimeUtcTicks -or
                    -not $current.Path.Equals($Item.Path, [StringComparison]::OrdinalIgnoreCase)) { return 'GoneOrChanged' }
                if (-not $current.HasMainWindow) { return 'NoMainWindow' }
                if ($process.CloseMainWindow()) { return 'Requested' }
                return 'Rejected'
            } finally { if ($process) { $process.Dispose() } }
        }
    }
}

function Get-CssProcessInspection {
    [CmdletBinding()]
    param([hashtable]$Adapter, [string[]]$ProtectedRoots = @())
    if (-not $Adapter) { $Adapter = Get-CssProcessAdapter }
    foreach ($item in (& $Adapter.Inspect)) {
        if (-not (Test-CssProcessCandidate $item $ProtectedRoots)) { continue }
        [pscustomobject]@{
            Kind = 'Process'; Key = "Process:$($item.Id):$($item.StartTimeUtcTicks)"
            Id = $item.Id; Name = $item.Name; Path = $item.Path; Publisher = $item.Publisher
            PublisherSource = $item.PublisherSource; StartTimeUtcTicks = $item.StartTimeUtcTicks
            SessionId = $item.SessionId; CurrentSessionId = $item.CurrentSessionId
            HasMainWindow = [bool]$item.HasMainWindow; CanClose = [bool]$item.HasMainWindow
            Selected = $false; Restorable = $false; RestoreStatus = 'NOT RESTORABLE'
            Warning = Get-CssProcessWarning
        }
    }
}

function Invoke-CssProcessClose {
    [CmdletBinding()]
    param([string[]]$SelectedKeys = @(), [switch]$AcknowledgeNotRestorable,
        [hashtable]$Adapter, [string[]]$ProtectedRoots = @())
    if ($SelectedKeys.Count -eq 0) { return }
    # Emit before inspecting or invoking any close adapter, even when acknowledgement was supplied.
    $warningText = Get-CssProcessWarning
    Write-Warning $warningText
    if (-not $AcknowledgeNotRestorable) { throw 'Explicit AcknowledgeNotRestorable is required before any process close request.' }
    if (-not $Adapter) { $Adapter = Get-CssProcessAdapter }
    # No cleanup journal is read or written: these actions cannot be restored or relaunched.
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($key in $SelectedKeys) {
        if (-not $seen.Add($key)) { continue }
        $status = 'Skipped'; $reason = 'No longer present or not an eligible application'; $errorText = $null
        try {
            # Fresh inspection for each requested action; stale selections cannot target reused PIDs.
            $matches = @(Get-CssProcessInspection -Adapter $Adapter -ProtectedRoots $ProtectedRoots | Where-Object { $_.Key -ceq $key })
            if ($matches.Count -eq 1) {
                $item = $matches[0]
                if (-not $item.HasMainWindow) { $reason = 'No main window; no close attempt made' } else {
                    $outcome = & $Adapter.Close $item $ProtectedRoots
                    switch ($outcome) {
                        'Requested' { $status = 'CloseRequested'; $reason = 'Graceful close requested only; exit is not confirmed and the application may prompt or cancel' }
                        'GoneOrChanged' { $reason = 'Process exited, changed identity, or became protected' }
                        'NoMainWindow' { $reason = 'No main window; no close attempt made' }
                        'Rejected' { $status = 'Failed'; $reason = 'Application rejected CloseMainWindow; no forced close attempted' }
                        default { $status = 'Failed'; $reason = 'Unexpected close adapter result; no further action attempted' }
                    }
                }
            }
        } catch { $status = 'Failed'; $reason = 'Graceful close failed; no further action attempted'; $errorText = 'Process inspection or graceful close failed; no forced close attempted.' }
        [pscustomobject]@{
            Kind = 'Process'; Key = $key; Status = $status; Reason = $reason; Error = $errorText
            Restorable = $false; RestoreStatus = 'NOT RESTORABLE'; Warning = $warningText
        }
    }
}
