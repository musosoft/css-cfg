# pwsh -NoProfile -File core/tests/Invoke-ProcessTests.ps1
# All inspection and close actions are fake. Never inspects or closes a real process.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../CssCfg.Core.psd1') -Force
$script:checks = 0
function Assert($Condition, [string]$Message) {
    if (-not $Condition) { throw "Assertion failed: $Message" }
    $script:checks++
}
function New-FakeProcess {
    param([int]$Id = 424242, [string]$Name = 'firefox',
        [AllowEmptyString()][string]$Path = 'C:\Program Files\Mozilla Firefox\firefox.exe',
        [AllowNull()][string]$Publisher = 'Mozilla Corporation', [bool]$Window = $true,
        [long]$Ticks = 638000000000000000, [int]$Session = 1)
    [pscustomobject]@{
        Id = $Id; Name = $Name; Path = $Path; Publisher = $Publisher
        PublisherSource = 'FileVersionInfo.CompanyName (unverified)'
        StartTimeUtcTicks = $Ticks; SessionId = $Session; CurrentSessionId = 1; HasMainWindow = $Window
    }
}
$state = @{ Items = @(); Calls = 0; Outcome = 'Requested'; Fail = $false; Inspections = 0 }
$adapter = @{
    Inspect = { $state.Inspections++; $state.Items }.GetNewClosure()
    Close = {
        param($item, $roots)
        $state.Calls++
        if ($state.Fail) { throw 'fake access denied' }
        $state.Outcome
    }.GetNewClosure()
}
$state.Items = @(
    (New-FakeProcess),
    (New-FakeProcess -Id 424243 -Name discord -Path 'C:\Users\tester\AppData\Local\Discord\Discord.exe' -Publisher $null),
    (New-FakeProcess -Id 424244 -Name spotify -Window $false),
    (New-FakeProcess -Id 424245 -Name hl2),
    (New-FakeProcess -Id 424246 -Name steam),
    (New-FakeProcess -Id 424247 -Name MsMpEng),
    (New-FakeProcess -Id 424248 -Name explorer),
    (New-FakeProcess -Id 424249 -Path 'C:\Windows\System32\firefox.exe'),
    (New-FakeProcess -Id 424250 -Path 'C:\Program Files\Steam\steamapps\firefox.exe'),
    (New-FakeProcess -Id 424251 -Publisher 'Microsoft Corporation'),
    (New-FakeProcess -Id 424252 -Publisher 'CrowdStrike Security'),
    (New-FakeProcess -Id 424253 -Session 0),
    (New-FakeProcess -Id 424254 -Path ''),
    (New-FakeProcess -Id 424255 -Path 'C:\Program Files\..\Windows\firefox.exe'),
    (New-FakeProcess -Id 424256 -Path 'C:\Program Files\GameDependency\firefox.exe')
)
$roots = @('C:\Program Files\GameDependency')
$inspection = @(Get-CssProcessInspection -Adapter $adapter -ProtectedRoots $roots)
Assert ($inspection.Count -eq 6) 'user-session apps included; OS-critical, Steam/game, Windows roots, invalid paths and other sessions excluded'
Assert (@($inspection | Where-Object Selected).Count -eq 0) 'default zero selected'
Assert (@($inspection | Where-Object Restorable).Count -eq 0) 'nothing claims reversibility'
Assert (@($inspection | Where-Object { $_.RestoreStatus -ne 'NOT RESTORABLE' }).Count -eq 0) 'prominent restore status'
Assert ($inspection[0].Path -eq 'C:\Program Files\Mozilla Firefox\firefox.exe') 'path displayed'
Assert ($inspection[0].Publisher -eq 'Mozilla Corporation') 'publisher displayed as metadata'
Assert ($inspection[0].PublisherSource -match 'unverified') 'publisher not claimed as signature verification'
Assert ([string]::IsNullOrEmpty($inspection[1].Publisher)) 'missing publisher allowed for display'
Assert (-not $inspection[2].CanClose) 'windowless process visible but not closeable'
Assert ($inspection[3].Name -eq 'explorer') 'noncritical Windows shell process remains visible'
Assert ($inspection[4].Publisher -eq 'Microsoft Corporation') 'publisher alone does not filter a running user app'
Assert ($inspection[5].Publisher -eq 'CrowdStrike Security') 'security vendor process remains visible for explicit selection'
Assert ($inspection[0].Warning -match 'termination is not reversible; relaunches.*not guaranteed') 'explicit irreversibility warning'

$null = Invoke-CssProcessClose -Adapter $adapter
Assert ($state.Calls -eq 0) 'default does not close'
$key = $inspection[0].Key
$thrown = $false
$warnings = @()
try { $null = Invoke-CssProcessClose -SelectedKeys $key -Adapter $adapter -WarningVariable warnings -WarningAction SilentlyContinue } catch { $thrown = $true }
Assert $thrown 'acknowledgement required'
Assert ($state.Calls -eq 0) 'no close before acknowledgement'
Assert ($warnings.Count -gt 0 -and $warnings[0].Message -match 'NOT RESTORABLE') 'warning emitted without acknowledgement'
$warnings = @()
$results = @(Invoke-CssProcessClose -SelectedKeys @($key, $key) -AcknowledgeNotRestorable -Adapter $adapter -ProtectedRoots $roots -WarningVariable warnings -WarningAction SilentlyContinue)
Assert ($warnings.Count -gt 0) 'warning emitted even with acknowledgement'
Assert ($state.Calls -eq 1 -and $results.Count -eq 1) 'duplicate selections only attempted once'
Assert ($results[0].Status -eq 'CloseRequested') 'graceful request not claimed as confirmed exit'
Assert ($results[0].Reason -match 'exit is not confirmed') 'asynchronous exit caveat'
Assert (-not $results[0].Restorable -and $results[0].RestoreStatus -eq 'NOT RESTORABLE') 'results visibly not restorable'

$results = @(Invoke-CssProcessClose -SelectedKeys $inspection[2].Key -AcknowledgeNotRestorable -Adapter $adapter -WarningAction SilentlyContinue)
Assert ($results[0].Status -eq 'Skipped' -and $state.Calls -eq 1) 'no window skipped, not forced'
$results = @(Invoke-CssProcessClose -SelectedKeys 'Process:424246:638000000000000000' -AcknowledgeNotRestorable -Adapter $adapter -WarningAction SilentlyContinue)
Assert ($results[0].Status -eq 'Skipped' -and $state.Calls -eq 1) 'protected process selection skipped'

foreach ($outcome in @('Rejected', 'GoneOrChanged', 'NoMainWindow')) {
    $state.Outcome = $outcome
    $result = @(Invoke-CssProcessClose -SelectedKeys $key -AcknowledgeNotRestorable -Adapter $adapter -WarningAction SilentlyContinue)[0]
    $expected = if ($outcome -eq 'Rejected') { 'Failed' } else { 'Skipped' }
    Assert ($result.Status -eq $expected) "report $outcome without fallback"
}
$state.Fail = $true
$result = @(Invoke-CssProcessClose -SelectedKeys $key -AcknowledgeNotRestorable -Adapter $adapter -WarningAction SilentlyContinue)[0]
Assert ($result.Status -eq 'Failed' -and $result.Error -match 'graceful close failed') 'display-safe close exception reported'
$state.Fail = $false
$before = $state.Calls
$state.Items = @((New-FakeProcess -Ticks 638000000000000001))
$result = @(Invoke-CssProcessClose -SelectedKeys $key -AcknowledgeNotRestorable -Adapter $adapter -WarningAction SilentlyContinue)[0]
Assert ($result.Status -eq 'Skipped' -and $state.Calls -eq $before) 'PID reuse not targeted'
$state.Items = @()
$result = @(Invoke-CssProcessClose -SelectedKeys $key -AcknowledgeNotRestorable -Adapter $adapter -WarningAction SilentlyContinue)[0]
Assert ($result.Status -eq 'Skipped' -and $state.Calls -eq $before) 'exited process skipped'
$state.Items = @((New-FakeProcess), (New-FakeProcess -Id 424243 -Name chrome))
$state.Fail = $true
$keys = @(Get-CssProcessInspection -Adapter $adapter | ForEach-Object Key)
$results = @(Invoke-CssProcessClose -SelectedKeys $keys -AcknowledgeNotRestorable -Adapter $adapter -WarningAction SilentlyContinue)
Assert ($results.Count -eq 2 -and @($results | Where-Object Status -eq 'Failed').Count -eq 2) 'per-item failure isolation'
$state.Fail = $false; $state.Outcome = 'Requested'; $state.Items = @((New-FakeProcess))
$serviceAdapter = @{ Inspect = { @() }; Change = { throw 'not allowed' }; Restore = { throw 'not allowed' } }
$facadeCandidates = (Get-LamaTeamCleanupCandidates -ServiceTaskAdapter $serviceAdapter -ProcessAdapter $adapter).Items
Assert ($facadeCandidates.Count -eq 1 -and $facadeCandidates[0].Eligible) 'facade exposes selectable process metadata'
Assert ($facadeCandidates[0].Details -match 'NOT RESTORABLE' -and -not $facadeCandidates[0].Selected) 'facade prominently warns with no default selection'
$journal = Join-Path ([IO.Path]::GetTempPath()) ('unused-process-journal-' + [guid]::NewGuid().ToString('N') + '.json')
$before = $state.Calls
$facadeResult = Apply-LamaTeamCleanup -SelectedKeys $facadeCandidates[0].Key -RecoveryPath $journal -AcknowledgeNotRestorable -ServiceTaskAdapter $serviceAdapter -ProcessAdapter $adapter -WarningAction SilentlyContinue
Assert ($state.Calls -eq $before + 1 -and $facadeResult.Status -eq 'Succeeded' -and $facadeResult.Items[0].Status -eq 'CloseRequested') 'facade actually invokes graceful close adapter'
Assert (-not (Test-Path -LiteralPath $journal) -and -not (Test-Path -LiteralPath "$journal.lock")) 'process-only operation has no journal/restore claim'
$inspectionWarnings = @()
$partialCandidates = Get-LamaTeamCleanupCandidates -ServiceTaskAdapter @{Inspect={throw 'fake task enumeration denied'}} -ProcessAdapter $adapter
Assert ($partialCandidates.Items.Count -eq 1 -and $partialCandidates.Items[0].Kind -eq 'Process') 'service/task enumeration failure does not break process inspection'
Assert (@($partialCandidates.Subsystems | Where-Object { -not $_.Available }).Count -eq 2 -and $partialCandidates.Subsystems[0].Error -notmatch 'fake task') 'partial inspection explicitly reports display-safe errors'
$processUnavailable = Get-LamaTeamCleanupCandidates -ServiceTaskAdapter $serviceAdapter -ProcessAdapter @{Inspect={throw 'sensitive native details'}}
Assert ($processUnavailable.Items.Count -eq 0 -and -not $processUnavailable.Subsystems[2].Available -and $processUnavailable.Subsystems[0].Available) 'process failure independent of service/task availability'
$state.Outcome = 'Rejected'
$failedBatch = Apply-LamaTeamCleanup -SelectedKeys $key -AcknowledgeNotRestorable -ProcessAdapter $adapter -WarningAction SilentlyContinue -ErrorAction Stop
Assert ($failedBatch.Status -eq 'Failed' -and $failedBatch.Items.Count -eq 1) 'facade assignment retains failure without throwing'
$state.Outcome = 'Requested'
$mixedBatch = Apply-LamaTeamCleanup -SelectedKeys @($key,'Process:999:1') -AcknowledgeNotRestorable -ProcessAdapter $adapter -WarningAction SilentlyContinue -ErrorAction Stop
Assert ($mixedBatch.Status -eq 'Partial' -and $mixedBatch.Items.Count -eq 2) 'mixed close and skip truthfully partial'
Write-Output "PASS: $script:checks process checks; only fake inspection/close adapters invoked."
