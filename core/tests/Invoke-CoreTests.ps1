# Built-ins only. All HTTP, extraction, conversion and Windows actions below are injected fakes.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '../CssCfg.Core.psd1') -Force
$root = Join-Path ([IO.Path]::GetTempPath()) ('css-core-tests-' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($root)
$script:checks = 0
function Assert($Condition, [string]$Message) {
    if (-not $Condition) { throw "Assertion failed: $Message" }
    $script:checks++
}
function Assert-Throws([scriptblock]$Action, [string]$Message) {
    $thrown = $false
    try { $null = & $Action } catch { $thrown = $true }
    Assert $thrown $Message
}
function New-TestBsp([string]$Path) {
    $bytes = [byte[]]::new(1036)
    [Text.Encoding]::ASCII.GetBytes('VBSP').CopyTo($bytes,0)
    [BitConverter]::GetBytes([int]20).CopyTo($bytes,4)
    [IO.File]::WriteAllBytes($Path,$bytes)
}
function New-FakeService([string]$Name = 'AdobeARMservice', [string]$Publisher = 'Adobe Inc.') {
    [pscustomobject]@{
        Kind='Service'; Name=$Name; DisplayName=$Name; TaskPath=''; Path="C:\Program Files\Adobe\$Name.exe"; Publisher=$Publisher
        PublisherSource='unverified test metadata'; State='Running'; Startup='Auto'; Active=$true; Enabled=$true
        Dependents=@(); ServiceType='Own Process'; AcceptStop=$true; Fingerprint="$Name|Auto|LocalSystem|Own Process"
    }
}
try {
    $config = Get-CssConfiguration -StateRoot $root
    Assert ($config.Server -eq '82.208.17.101:27516') 'canonical server'
    Save-CssState $config.ProfilePath @{Profile='Modern'}
    Assert ((Read-CssState $config.ProfilePath).Profile -eq 'Modern') 'atomic state round trip'

    # Automatic Steam discovery honors modern and legacy libraryfolders.vdf layouts.
    $steamRoot = Join-Path $root 'steam-root'
    $library = Join-Path $root 'steam-library'
    [void][IO.Directory]::CreateDirectory((Join-Path $steamRoot 'steamapps'))
    [void][IO.Directory]::CreateDirectory((Join-Path $library 'steamapps/common/Counter-Strike Source/cstrike'))
    [IO.File]::WriteAllText((Join-Path $library 'steamapps/appmanifest_240.acf'), '"AppState" { "installdir" "Counter-Strike Source" }')
    [IO.File]::WriteAllText((Join-Path $library 'steamapps/common/Counter-Strike Source/cstrike/gameinfo.txt'), 'fixture')
    # The earlier detector accepted a valid cstrike marker without requiring the root executable.
    $libraryEscaped = $library.Replace('\','\\')
    [IO.File]::WriteAllText((Join-Path $steamRoot 'steamapps/libraryfolders.vdf'), "`"libraryfolders`" { `"0`" { `"path`" `"$libraryEscaped`" } }")
    $autoDetected = @(Find-LamaTeamGame -SteamRoots @($steamRoot))
    Assert ($autoDetected.Count -eq 1 -and $autoDetected[0].Root -eq [IO.Path]::GetFullPath((Join-Path $library 'steamapps/common/Counter-Strike Source'))) 'auto-detect finds CS:S in a modern secondary Steam library'
    Assert ((Get-LamaTeamPaths -Game $autoDetected[0] -StateRoot $root).Root -eq $autoDetected[0].Root) 'valid cstrike marker remains usable without root executable'
    [IO.File]::WriteAllText((Join-Path $steamRoot 'steamapps/libraryfolders.vdf'), "`"libraryfolders`" {`n`"1`" `"$libraryEscaped`"`n}")
    Assert ((Find-LamaTeamGame -SteamRoots @($steamRoot)).Root -eq $autoDetected[0].Root) 'auto-detect supports legacy numeric Steam library entries'
    $primaryGame = Join-Path $steamRoot 'steamapps/common/Counter-Strike Source'
    [void][IO.Directory]::CreateDirectory((Join-Path $primaryGame 'cstrike'))
    [IO.File]::WriteAllText((Join-Path $primaryGame 'cstrike/gameinfo.txt'), 'fixture')
    [IO.File]::WriteAllText((Join-Path $primaryGame 'hl2.exe'), 'fixture only')
    Assert ((Find-LamaTeamGame -SteamRoots @($steamRoot)).Root -eq [IO.Path]::GetFullPath($primaryGame)) 'duplicate CS:S installs select the first Steam library deterministically'

    foreach ($name in @('../x','x/y','x\y','x.bsp','x?y','x%2fy','CON','nul','x:ads','x ','')) { Assert (-not (Test-CssMapName $name)) "unsafe $name" }
    Assert (Test-CssMapName '$2000$') 'legitimate dollar-prefixed map name is safe'
    Assert ((Get-CssMapUri '$2000$').AbsoluteUri -ceq 'https://fastdl.lamateam.eu/maps/$2000$.bsp.bz2') 'dollar map URL retains exact literal name'
    Assert (@(ConvertFrom-CssMapList -Format Csv -Text ('map' + "`n" + '"""$2000$"""' + "`n" + '"""3mc_training"""')).Count -eq 2) 'CSV quote wrappers normalize before strict user-list validation'
    Assert ((Get-CssMapUri de_dust2).AbsoluteUri -eq 'https://fastdl.lamateam.eu/maps/de_dust2.bsp.bz2') 'real FastDL archive format'
    Assert-Throws { Get-CssMapUri de_test '../maps' } 'invalid layout rejected'
    Assert (@(ConvertFrom-CssMapList "de_test.bsp.bz2`nde_test`ncs_test").Count -eq 2) 'map dedup/extensions'
    Assert-Throws { ConvertFrom-CssMapList '../evil' } 'unsafe list rejected'
    Assert-Throws { ConvertFrom-CssMapList -Format Csv -Text "map`n`"unterminated" } 'malformed CSV quoting rejected'

    $gameRoot = Join-Path $root 'game'
    [void][IO.Directory]::CreateDirectory((Join-Path $gameRoot 'cstrike'))
    [IO.File]::WriteAllText((Join-Path $gameRoot 'cstrike/gameinfo.txt'),'fixture')
    [IO.File]::WriteAllText((Join-Path $gameRoot 'hl2.exe'),'fixture only; never executed')
    $game = Find-LamaTeamGame -Path (Join-Path $gameRoot 'cstrike')
    $paths = Get-LamaTeamPaths -Game $game -StateRoot $root
    Assert ($paths.ConfigPath -eq (Join-Path $gameRoot 'cstrike/cfg/autoexec.cfg')) 'UI Game/Paths contracts'
    Assert ($paths.GameMenuPath -eq (Join-Path $gameRoot 'cstrike/custom/lamateam/resource/GameMenu.res')) 'custom menu convention'
    Assert ($paths.ConnectPath -eq $paths.ConfigPath -and [IO.Path]::IsPathFullyQualified($paths.ConfigBackupPath)) 'explicit alias and planned backup paths'
    Assert ($paths.LegacyAssetAvailable -and $paths.LegacySourceYear -eq 2016) 'verified history available'
    $preview = Get-LamaTeamConfigPreview -Profile Modern
    Assert ($preview.Assets.Count -eq 1 -and $preview.Files[0] -eq 'autoexec.cfg') 'config-only preview contains current autoexec only'
    Assert ($preview.Assets[0].Content -eq [IO.File]::ReadAllText((Join-Path $paths.AssetRoot 'autoexec.cfg'))) 'preview exact current config content'
    $connectPreview = Get-LamaTeamConfigPreview -Profile Modern -IncludeConnect
    Assert ($connectPreview.Assets.Count -eq 2 -and $connectPreview.Text -match 'GameMenu' -and $connectPreview.ConnectAlias -match '82.208.17.101:27516') 'optional connection preview includes preserved menu and alias'
    $legacy = Get-LamaTeamConfigPreview -Profile Legacy
    Assert ($legacy.Text -match 'alias fps' -and $legacy.ReviewRequired -and $legacy.SourceYear -eq 2016) 'historical full text and disclosure'
    Assert ($legacy.ReviewSha256 -ceq 'a846b241f7ccfc26fdbaf805f015ba96102cbc316c120f4cb74d4f80da7a2aa1') 'pinned legacy source hash'
    Assert ($preview.Text -ceq $preview.Assets[0].Content) 'modern preview contains config only, without decorative labels or hashes'
    $steamConfig = Join-Path $root 'localconfig.vdf'
    $steamText = '"UserLocalConfigStore" {' + "`n" +
        "`t`"Software`" {`n`t`t`"Valve`" {`n`t`t`t`"Steam`" {`n`t`t`t`t`"apps`" {`n`t`t`t`t`t`"240`" {`n`t`t`t`t`t`t`"LaunchOptions`"`t`"-windowed -w 1280`"`n`t`t`t`t`t}`n`t`t`t`t}`n`t`t`t}`n`t`t}`n`t}`n"
    [IO.File]::WriteAllText($steamConfig, $steamText, [Text.UTF8Encoding]::new($false))
    $currentLaunch = Get-CssSteamLaunchOptions -ConfigPath $steamConfig
    Assert ($currentLaunch.Options -ceq '-windowed -w 1280') 'Steam app 240 launch options read from VDF'
    $steamWrite = Set-CssSteamLaunchOptions -ConfigPath $steamConfig -Options '-windowed -w 1280 -novid -nojoy -refresh 144'
    Assert ($steamWrite.Changed -and (Test-Path -LiteralPath $steamWrite.Backup)) 'Steam VDF update creates an exact backup'
    Assert ((Get-CssSteamLaunchOptions -ConfigPath $steamConfig).Options -ceq '-windowed -w 1280 -novid -nojoy -refresh 144') 'Steam launch options write is re-read and verified'
    Assert ([IO.File]::ReadAllText($steamWrite.Backup) -ceq $steamText) 'Steam backup preserves original VDF bytes'
    $withoutLaunchOptions = $steamText.Replace("`t`t`t`t`t`t`"LaunchOptions`"`t`"-windowed -w 1280`"`n", '')
    [IO.File]::WriteAllText($steamConfig, $withoutLaunchOptions, [Text.UTF8Encoding]::new($false))
    $steamWriteMissingKey = Set-CssSteamLaunchOptions -ConfigPath $steamConfig -Options '-novid -nojoy'
    Assert ($steamWriteMissingKey.Changed -and (Get-CssSteamLaunchOptions -ConfigPath $steamConfig).Options -ceq '-novid -nojoy') 'Steam app section gains a missing LaunchOptions key'
    $editorRoot = Join-Path $root 'editor-game'
    [void][IO.Directory]::CreateDirectory((Join-Path $editorRoot 'cstrike/cfg'))
    [IO.File]::WriteAllText((Join-Path $editorRoot 'cstrike/gameinfo.txt'), 'fixture')
    [IO.File]::WriteAllText((Join-Path $editorRoot 'hl2.exe'), 'fixture only')
    $editorGame = Find-LamaTeamGame -Path $editorRoot
    $editorPaths = Get-LamaTeamPaths -Game $editorGame -StateRoot $root
    $originalEditorText = '// existing user config' + "`n" + 'fps_max 90' + "`n"
    [IO.File]::WriteAllText($editorPaths.ConfigPath, $originalEditorText, [Text.UTF8Encoding]::new($false))
    $originalEditorHash = (Get-FileHash -LiteralPath $editorPaths.ConfigPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $editorSave = Save-LamaTeamConfigText -Game $editorGame -Paths $editorPaths -Content 'fps_max 144' -ExpectedSha256 $originalEditorHash
    Assert ($editorSave.Changed -and $editorSave.Backup -eq $editorPaths.ConfigBackupPath) 'first editor autosave creates the planned backup'
    Assert ([IO.File]::ReadAllText($editorSave.Backup) -ceq $originalEditorText) 'editor backup keeps the exact pre-edit config'
    $editorSaveAgain = Save-LamaTeamConfigText -Game $editorGame -Paths $editorPaths -Content 'fps_max 200' -BackupAlreadyCreated -ExpectedSha256 $editorSave.Sha256
    Assert ($editorSaveAgain.Changed -and -not $editorSaveAgain.Backup) 'later editor autosaves reuse the first backup'
    Assert ([IO.File]::ReadAllText($editorPaths.ConfigPath) -ceq 'fps_max 200') 'editor autosave writes the latest text'
    Assert-Throws {
        Save-LamaTeamConfigText -Game $editorGame -Paths $editorPaths -Content 'fps_max 300' -BackupAlreadyCreated -ExpectedSha256 $originalEditorHash
    } 'editor autosave rejects an external/stale config change'
    Assert-Throws { Install-LamaTeamConfig -Game $game -Paths $paths -Profile Legacy } 'legacy unreviewed fails closed'
    Assert (-not (Test-Path -LiteralPath $paths.ConfigPath)) 'unreviewed legacy no writes'
    $first = @(Install-LamaTeamConfig -Game $game -Paths $paths -Profile Modern)
    Assert ($first.Count -eq 1 -and $first[0].Changed) 'modern installs autoexec only'
    Assert (-not ([IO.File]::ReadAllText($paths.ConfigPath) -match '(?im)^\s*alias\s+lama\b')) 'modern config has no LamaTeam connection alias by default'
    Assert (-not (Test-Path -LiteralPath $paths.GameMenuPath)) 'config-only install does not add connection menu'
    $repeat = @(Install-LamaTeamConfig -Game $game -Paths $paths -Profile Modern)
    Assert (@($repeat | Where-Object Changed).Count -eq 0) 'repeat config install idempotent'
    $modernConnect = @(Add-LamaTeamConnect -Game $game -Paths $paths)
    $modernAlias = @($modernConnect | Where-Object Kind -eq 'Alias')[0]
    Assert ($modernConnect.Count -eq 2 -and $modernAlias.Changed -and $modernAlias.Backup -eq $paths.ConnectBackupPath) 'opt-in connect adds alias with its planned backup'
    Assert (@($modernConnect | Where-Object Kind -eq 'Menu')[0].Changed -and
        (Get-FileHash -LiteralPath $paths.GameMenuPath).Hash -ceq (Get-FileHash -LiteralPath (Join-Path $paths.AssetRoot 'gamemenu.res')).Hash) 'opt-in connect installs menu bytes verbatim'
    $connectRepeat = @(Add-LamaTeamConnect -Game $game -Paths $paths)
    Assert (@($connectRepeat | Where-Object Changed).Count -eq 0 -and @($connectRepeat | Where-Object Backup).Count -eq 0) 'repeat optional connection setup is idempotent without extra backups'
    $statementFixture = Join-Path $root 'statements.cfg'
    [IO.File]::WriteAllText($statementFixture, 'echo "not an alias;alias lama ''example''" // alias lama "connect 82.208.17.101:27516"')
    Assert ((Add-CssServerAlias -Path $statementFixture).Changed) 'quoted and commented alias text cannot falsely satisfy connect insertion'
    [IO.File]::WriteAllText($statementFixture, 'echo test;alias lama "quit"')
    Assert-Throws { Add-CssServerAlias -Path $statementFixture } 'inline conflicting alias is not silently replaced or shadowed'
    $menuHash = (Get-FileHash -LiteralPath $paths.GameMenuPath).Hash
    $legacyResult = @(Install-LamaTeamConfig -Game $game -Paths $paths -Profile Legacy -ReviewedSha256 $legacy.ReviewSha256 -WarningAction SilentlyContinue)
    Assert ($legacyResult.Count -eq 1 -and $legacyResult[0].Backup -eq $paths.ConfigBackupPath) 'legacy actual backup equals planned backup'
    Assert ((Get-FileHash -LiteralPath $paths.ConfigPath).Hash.ToLowerInvariant() -ceq $legacy.ReviewSha256) 'legacy bytes installed faithfully'
    Assert ((Get-FileHash -LiteralPath $paths.GameMenuPath).Hash -eq $menuHash) 'legacy leaves menu untouched'
    $legacyConnectPaths = Get-LamaTeamPaths -Game $game -StateRoot $root
    $legacyConnect = @(Add-LamaTeamConnect -Game $game -Paths $legacyConnectPaths)
    $alias = @($legacyConnect | Where-Object Kind -eq 'Alias')[0]
    Assert ($alias.Changed -and $alias.Backup -eq $legacyConnectPaths.ConnectBackupPath) 'opt-in alias after Legacy replacement uses its newly planned backup'
    Assert (@(Add-LamaTeamConnect -Game $game -Paths $legacyConnectPaths | Where-Object Changed).Count -eq 0) 'alias and menu repeat idempotent'
    Assert-Throws { Install-LamaTeamConfig -Game $game -Paths $paths -Profile Modern } 'consumed planned backup fails safely until paths refreshed'
    $preflightRoot = Join-Path $root 'config-preflight'
    [void][IO.Directory]::CreateDirectory((Join-Path $preflightRoot 'cstrike/cfg'))
    [void][IO.Directory]::CreateDirectory((Join-Path $preflightRoot 'cstrike/custom/lamateam/resource'))
    [IO.File]::WriteAllText((Join-Path $preflightRoot 'cstrike/gameinfo.txt'),'fixture')
    [IO.File]::WriteAllText((Join-Path $preflightRoot 'hl2.exe'),'fixture only')
    $preflightPaths = Get-LamaTeamPaths -GameRoot $preflightRoot -StateRoot $root
    [IO.File]::WriteAllText($preflightPaths.ConfigPath,'personal config before request')
    [IO.File]::WriteAllText($preflightPaths.GameMenuPath,'personal menu before request')
    [void][IO.Directory]::CreateDirectory($preflightPaths.BackupDirectory)
    [IO.File]::WriteAllText($preflightPaths.GameMenuBackupPath,'existing backup must be retained')
    Assert-Throws { Add-LamaTeamConnect -GameRoot $preflightRoot -Paths $preflightPaths } 'stale menu backup blocks optional connection setup'
    Assert ([IO.File]::ReadAllText($preflightPaths.ConfigPath) -ceq 'personal config before request') 'known menu-backup conflict must be detected BEFORE changing config'
    Assert ([IO.File]::ReadAllText($preflightPaths.GameMenuPath) -ceq 'personal menu before request' -and -not (Test-Path -LiteralPath $preflightPaths.ConnectBackupPath)) 'connection preflight failure leaves both target files and unused backup unchanged'
    $configOnly = @(Install-LamaTeamConfig -GameRoot $preflightRoot -Paths $preflightPaths -Profile Modern)
    Assert ($configOnly.Count -eq 1 -and [IO.File]::ReadAllText($preflightPaths.GameMenuPath) -ceq 'personal menu before request') 'config action ignores connection backup and leaves personal menu untouched'
    # Fresh preview paths are needed for another replacement; originals must land at those exact destinations.
    $freshPaths = Get-LamaTeamPaths -GameRoot $preflightRoot -StateRoot $root
    [IO.File]::WriteAllText($freshPaths.ConnectPath,'personal config without alias')
    $optional = @(Add-LamaTeamConnect -GameRoot $preflightRoot -Paths $freshPaths)
    Assert ($optional[0].Backup -ceq $freshPaths.ConnectBackupPath -and $optional[1].Backup -ceq $freshPaths.GameMenuBackupPath) 'both opt-in backups use exact previewed paths'
    Assert ([IO.File]::ReadAllText($freshPaths.ConnectBackupPath) -ceq 'personal config without alias' -and [IO.File]::ReadAllText($freshPaths.GameMenuBackupPath) -ceq 'personal menu before request') 'opt-in backups preserve both originals'
    Assert (@(Add-LamaTeamConnect -GameRoot $preflightRoot -Paths $freshPaths | Where-Object Changed).Count -eq 0) 'opt-in repeat does not overwrite or recreate backups'
    $badRoot = Join-Path $root 'bad-assets'
    Assert-Throws { Get-LamaTeamConfigPreview -Profile Legacy -AssetRoot $badRoot } 'missing legacy blocked'
    $badAsset = Join-Path $badRoot 'core/assets/Legacy-2016/autoexec.cfg'
    [void][IO.Directory]::CreateDirectory((Split-Path $badAsset -Parent)); [IO.File]::WriteAllText($badAsset,'invented')
    Assert-Throws { Get-LamaTeamConfigPreview -Profile Legacy -AssetRoot $badRoot } 'modified legacy blocked'

    $httpState = @{ Code=200; Type='text/csv; charset=utf-8'; Text="ID,MAPA,Note`n1,de_test,ok`n2,cs_test,ok`n3,de_test.bsp,duplicate"; Calls=0; LastUri=$null; Length=$null; Location='' }
    $httpAdapter = @{ Get = {
        param($uri)
        $httpState.Calls++; $httpState.LastUri=$uri.AbsoluteUri
        $bytes=[Text.Encoding]::UTF8.GetBytes($httpState.Text)
        [pscustomobject]@{ StatusCode=$httpState.Code; Headers=@{ContentType=$httpState.Type;ContentLength=$httpState.Length;Location=$httpState.Location}; Stream=[IO.MemoryStream]::new($bytes,$false) }
    }.GetNewClosure() }
    $rows = @(Get-LamaTeamMaps -Game $game -HttpAdapter $httpAdapter)
    Assert ($rows.Count -eq 2 -and $rows[0].Status -eq 'Missing') 'catalog retrieval parsing and UI rows'
    Assert ($httpState.LastUri -ceq $config.CatalogUri) 'exact existing published CSV URL'
    $httpState.Text = ',MAPA,NOTE' + "`n" + ',"""$2000$""",real map' + "`n" + ',"""3mc_training""",map' + "`n" + ',"""de_dust2""",map' + "`n" + ',"""de_dust2.bsp""",duplicate' + "`n" + ',min_players,valid filename without footer context' + "`n" + ',TBD,not classified by label' + "`n" + ',,empty'
    $catalogWarnings = @()
    $normalized = @(Get-LamaTeamMaps -Game $game -HttpAdapter $httpAdapter -WarningVariable catalogWarnings -WarningAction SilentlyContinue)
    Assert ($normalized.Count -eq 5 -and $normalized[0].Name -ceq '$2000$' -and $normalized[1].Name -ceq '3mc_training') 'quoted dollar and ordinary maps normalize; safe names are not price/placeholder filtered'
    Assert ($catalogWarnings.Count -gt 0 -and $catalogWarnings[0].Message -match 'Skipped 1 empty') 'only the empty row was filtered'
    $httpState.Text = ',MAPA,,,OTHER' + "`n" + '"""de_syksy""","""min_players""",29,"""max_players""",34' + "`n" + ',"""$2000$""",,,map'
    $normalized = @(Get-LamaTeamMaps -Game $game -HttpAdapter $httpAdapter -WarningAction SilentlyContinue)
    Assert ($normalized.Count -eq 1 -and $normalized[0].Name -ceq '$2000$') 'only structurally identified UMC footer is excluded, never the dollar map'
    $httpState.Text = 'MAPA' + "`n" + '""""""'
    Assert-Throws { Get-LamaTeamMaps -Game $game -HttpAdapter $httpAdapter -WarningAction SilentlyContinue } 'all-filtered catalog still fails closed'
    $httpState.Text = 'MAPA' + "`n" + '"""../escape"""' + "`n" + '"""de_safe"""'
    Assert-Throws { Get-LamaTeamMaps -Game $game -HttpAdapter $httpAdapter } 'quoted unsafe catalog paths are never accepted or silently filtered'
    Assert (@(Get-LamaTeamMaps -Text '$2000$')[0].Name -ceq '$2000$') 'direct safe dollar names are supported too'
    Assert-Throws { Get-LamaTeamMaps -Text '"../escape"' } 'edge-quote normalization never bypasses traversal rejection'
    foreach ($case in @('status','empty','html','unsafe','length','redirect','bodyLimit')) {
        $httpState.Code=200; $httpState.Type='text/csv'; $httpState.Text="MAPA`nde_test"; $httpState.Length=$null
        switch ($case) {
            status {$httpState.Code=503}; empty {$httpState.Text='MAPA'}; html {$httpState.Type='text/html';$httpState.Text='<html>error</html>'}
            unsafe {$httpState.Text="MAPA`n../evil"}; length {$httpState.Length=5MB}
            redirect {$httpState.Code=302;$httpState.Location='http://evil.example/catalog'}
            bodyLimit {$httpState.Text='x' * (4MB + 1)}
        }
        Assert-Throws { Get-LamaTeamMaps -Game $game -HttpAdapter $httpAdapter } "catalog rejects $case"
    }

    $fixture = Join-Path $root 'fixture.bsp'; New-TestBsp $fixture
    Assert (Test-CssBsp $fixture) 'valid structural BSP'
    $downloadState = @{Calls=0; Uri=$null; Corrupt=$false}
    $downloader = {param($uri,$path,$limit);$downloadState.Calls++;$downloadState.Uri=$uri.AbsoluteUri;[IO.File]::WriteAllBytes($path,[Text.Encoding]::ASCII.GetBytes('BZh9fake payload'))}.GetNewClosure()
    $decompressor = {param($archive,$output,$extractor,$limit);if($downloadState.Corrupt){[IO.File]::WriteAllText($output,'HTML')}else{[IO.File]::Copy($fixture,$output)}}.GetNewClosure()
    $discovery = { [pscustomobject]@{Path='fake-only';Kind='7zip'} }
    $script:progress = 0
    $results = @(Sync-CssMaps -Names @('de_test','../evil','cs_test') -Destination $paths.MapsDirectory -Downloader $downloader -Decompressor $decompressor -ExtractorDiscovery $discovery -Progress {param($r);$script:progress++})
    Assert (($results.Status -join ',') -eq 'Installed,Failed,Installed' -and $script:progress -eq 3) 'per-map isolation and progress'
    Assert ($downloadState.Uri -eq 'https://fastdl.lamateam.eu/maps/cs_test.bsp.bz2') 'downloads compressed archives only'
    $dollarResult = @(Sync-CssMaps -Names '$2000$' -Destination $paths.MapsDirectory -Downloader $downloader -Decompressor $decompressor -ExtractorDiscovery $discovery)[0]
    Assert ($dollarResult.Status -eq 'Installed' -and (Test-CssBsp (Join-Path $paths.MapsDirectory '$2000$.bsp'))) 'literal dollar map passes fake download, decompression, validation and file install'
    Assert ($downloadState.Uri -ceq 'https://fastdl.lamateam.eu/maps/$2000$.bsp.bz2') 'dollar filename is never interpolated or stripped during sync'
    $before = $downloadState.Calls
    $null = Sync-CssMaps -Names de_test -Destination $paths.MapsDirectory -Downloader $downloader -ExtractorDiscovery {throw 'skip must not discover'}
    Assert ($downloadState.Calls -eq $before) 'valid installed map retained without download/extractor'
    $result = @(Sync-CssMaps -Names de_missing -Destination $paths.MapsDirectory -Downloader $downloader -ExtractorDiscovery { $null })[0]
    Assert ($result.Status -eq 'Failed' -and $result.Error -match 'MissingExtractor' -and $downloadState.Calls -eq $before) 'actionable missing extractor, no download'
    $downloadState.Corrupt=$true
    $result = @(Sync-CssMaps -Names de_bad -Destination $paths.MapsDirectory -Downloader $downloader -Decompressor $decompressor -ExtractorDiscovery $discovery)[0]
    Assert ($result.Status -eq 'Failed' -and -not (Test-Path (Join-Path $paths.MapsDirectory 'de_bad.bsp'))) 'invalid extracted BSP never installed'
    Assert (@(Get-ChildItem -LiteralPath $paths.MapsDirectory -Directory -Force).Count -eq 0) 'private archive/output temps removed'
    Assert-Throws { Sync-CssMaps -Names @() -Destination $paths.MapsDirectory -ExtractorDiscovery $discovery } 'empty sync never succeeds'
    $downloadState.Corrupt=$false
    $null = Sync-LamaTeamMaps -Game $game -Maps @([pscustomobject]@{Name='de_facade';Status='Missing'}) -Downloader $downloader -Decompressor $decompressor -ExtractorDiscovery $discovery
    Assert (Test-CssBsp (Join-Path $paths.MapsDirectory 'de_facade.bsp')) 'UI map-row facade invokes actual operation'
    $script:failedProgress = @()
    # Mirror the UI's assignment and ErrorAction Stop. Per-map failures must NOT throw away this result.
    $uiResult = @(Sync-LamaTeamMaps -Game $game -Maps @([pscustomobject]@{Name='de_no_extractor';Status='Missing'}) -Downloader { throw 'must not contact network' } -ExtractorDiscovery { $null } -Progress {param($record);$script:failedProgress += $record} -ErrorAction Stop)
    Assert ($uiResult.Count -eq 1 -and $uiResult[0].Status -eq 'Failed' -and $uiResult[0].Name -eq 'de_no_extractor' -and $uiResult[0].Error -match 'MissingExtractor: install 7-Zip or bzip2') 'UI assignment receives failed status with actionable extractor error, without throwing'
    Assert ($script:failedProgress.Count -eq 1 -and $script:failedProgress[0].Error -match 'MissingExtractor') 'failed progress preserves structured detail'
    $uiResult = @(Sync-LamaTeamMaps -Game $game -Maps @([pscustomobject]@{Name='de_http_fail';Status='Missing'}) -Downloader { throw 'HTTP 503 from fastdl.lamateam.eu' } -Decompressor {throw 'must not decompress failed download'} -ExtractorDiscovery $discovery -ErrorAction Stop)
    Assert ($uiResult.Count -eq 1 -and $uiResult[0].Status -eq 'Failed' -and $uiResult[0].Error -ceq 'HTTP 503 from fastdl.lamateam.eu') 'returned HTTP failure is distinct from missing extractor'
    Assert (($uiResult | ConvertTo-Json -Depth 8) -match 'HTTP 503 from fastdl.lamateam.eu') 'History serialization retains the returned failure cause'
    $mixedRows = @([pscustomobject]@{Name='de_facade';Status='Installed'},[pscustomobject]@{Name='de_http_fail';Status='Missing'})
    $uiResult = @(Sync-LamaTeamMaps -Game $game -Maps $mixedRows -Downloader {throw 'HTTP 503 from fastdl.lamateam.eu'} -Decompressor {throw 'must not decompress failed download'} -ExtractorDiscovery $discovery -ErrorAction Stop)
    Assert (($uiResult.Status -join ',') -eq 'Skipped,Failed' -and $uiResult[0].Total -eq 2 -and $uiResult[1].Completed -eq 2) 'mixed results survive UI assignment with accurate batch progress'
    Assert (Test-CssBsp (Join-Path $paths.MapsDirectory 'de_facade.bsp')) 'failed batch retains valid installed maps'
    Assert-Throws { Sync-LamaTeamMaps -Game $game -Maps @() -Downloader {throw 'must not download empty selection'} -ExtractorDiscovery {throw 'must not inspect extractor for empty selection'} } 'facade empty selection remains a terminating precondition failure'

    $cstrikeMedia=Join-Path $gameRoot 'cstrike/media'; [void][IO.Directory]::CreateDirectory($cstrikeMedia)
    [IO.File]::WriteAllText((Join-Path $cstrikeMedia 'valve.bik'),'not the requested HL2 intro')
    $media=Join-Path $gameRoot 'hl2/media'; [void][IO.Directory]::CreateDirectory($media)
    [IO.File]::WriteAllText((Join-Path $media 'valve.bik'),'source never overwritten')
    $paths2=Get-LamaTeamPaths -Game $game -StateRoot $root
    Assert ($paths2.MediaDirectory -eq $media -and -not $paths2.IntroTargetBackupPermitted) 'intro actual source detection, no default replacement'
    $videoState=@{ConvertCalls=0;Valid=$true}
    $videoAdapter=@{
        Convert={param($source,$output,$exe);$videoState.ConvertCalls++;[IO.File]::WriteAllBytes($output,[byte[]]@(0x1a,0x45,0xdf,0xa3,0,0,0,0))}.GetNewClosure()
        Validate={param($path,$exe);$videoState.Valid}.GetNewClosure()
    }
    Assert-Throws { Convert-LamaTeamIntroVideo -Game $game -Paths $paths2 -VideoAdapter $videoAdapter } 'conversion requires opt-in'
    Assert ($videoState.ConvertCalls -eq 0) 'no converter before opt-in'
    $converted=Convert-LamaTeamIntroVideo -Game $game -Paths $paths2 -OptIn -VideoAdapter $videoAdapter
    Assert ($converted.Validated -and [IO.File]::ReadAllText($converted.Source) -eq 'source never overwritten') 'validated video, source untouched'
    Assert-Throws { Convert-LamaTeamIntroVideo -Game $game -Paths $paths2 -OptIn -VideoAdapter $videoAdapter } 'existing output default fails closed'
    $videoState.Valid=$false
    Assert-Throws { Convert-LamaTeamIntroVideo -Game $game -Paths $paths2 -OptIn -BackupExisting -VideoAdapter $videoAdapter } 'decode rejection preserves target'
    Assert (-not (Test-Path -LiteralPath $paths2.IntroBackupPath)) 'failed decode no backup/replacement'
    $videoState.Valid=$true
    $converted=Convert-LamaTeamIntroVideo -Game $game -Paths $paths2 -OptIn -BackupExisting -VideoAdapter $videoAdapter
    Assert ($converted.Backup -eq $paths2.IntroBackupPath -and (Test-Path -LiteralPath $converted.Backup)) 'explicit target backup flow'

    $archivePath = Join-Path $root 'ffmpeg-fixture.zip'
    $zipStream = [IO.File]::Open($archivePath, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    $zip = [IO.Compression.ZipArchive]::new($zipStream, [IO.Compression.ZipArchiveMode]::Create, $true)
    try {
        $entry = $zip.CreateEntry('ffmpeg-fixture/bin/ffmpeg.exe')
        $entryStream = $entry.Open()
        try { $entryStream.Write([byte[]]::new(1MB + 1), 0, 1MB + 1) }
        finally { $entryStream.Dispose() }
    } finally { $zip.Dispose(); $zipStream.Dispose() }
    $archiveHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash
    $extractedPath = Join-Path $root 'ffmpeg-extracted.exe'
    $module = Get-Module CssCfg.Core
    $null = & $module {
        param($Archive, $Destination, $Hash)
        Expand-CssFfmpegArchive -ArchivePath $Archive -Destination $Destination -ExpectedSha256 $Hash
    } $archivePath $extractedPath $archiveHash
    Assert ((Get-Item -LiteralPath $extractedPath).Length -eq (1MB + 1)) 'FFmpeg archive extracts only the executable entry'
    $badHashPath = Join-Path $root 'ffmpeg-bad-hash.exe'
    Assert-Throws {
        & $module {
            param($Archive, $Destination)
            Expand-CssFfmpegArchive -ArchivePath $Archive -Destination $Destination -ExpectedSha256 ('0' * 64)
        } $archivePath $badHashPath
    } 'FFmpeg archive checksum mismatch fails closed'
    Assert (-not (Test-Path -LiteralPath $badHashPath)) 'bad FFmpeg archive is not extracted'

    $service=New-FakeService
    $google=New-FakeService -Name gupdate -Publisher 'Google LLC'
    $mozilla=New-FakeService -Name MozillaMaintenance -Publisher 'Mozilla Corporation'
    $protected=New-FakeService -Name WinDefend -Publisher 'Microsoft Corporation'
    $dependent=New-FakeService -Name DropboxUpdate -Publisher 'Dropbox, Inc.'; $dependent.Dependents=@('other-dependent')
    $task=[pscustomobject]@{Kind='Task';Name='Mozilla Update';DisplayName='Mozilla Update';TaskPath='\Mozilla\';Path='C:\Program Files\Mozilla Firefox\updater.exe';Publisher='Mozilla Corporation';PublisherSource='test metadata';State='Ready';Startup='Scheduled';Active=$false;Enabled=$true;ActionCount=1;Principal='tester';Fingerprint='MozillaTaskOriginal'}
    $windowsTask=$task.PSObject.Copy();$windowsTask.Name='OneDrive Maintenance';$windowsTask.TaskPath='\Microsoft\Windows\OneDrive\';$windowsTask.Fingerprint='WindowsUserTask'
    $systemTask=$task.PSObject.Copy();$systemTask.Name='System Task';$systemTask.Principal='SYSTEM'
    $state=@{Items=@($service,$google,$mozilla,$protected,$dependent,$task,$windowsTask,$systemTask);Changes=0;Restores=0;FailRestore=$false;FailChange=$false}
    $adapter=@{
        Inspect={$state.Items}.GetNewClosure()
        Change={param($i,$roots);$state.Changes++;if($state.FailChange){throw 'fake action failed'};$target=@($state.Items|Where-Object{$_.Name -eq $i.Name})[0];if($i.Kind -eq 'Service'){$target.Active=$false;$target.State='Stopped';$target.AcceptStop=$false}else{$target.Enabled=$false;$target.State='Disabled'}}.GetNewClosure()
        Restore={param($i,$roots);$state.Restores++;if($state.FailRestore){throw 'fake restore failure'};$target=@($state.Items|Where-Object{$_.Name -eq $i.Name})[0];if($i.Kind -eq 'Service'){$target.Active=$true;$target.State='Running';$target.AcceptStop=$true}else{$target.Enabled=$true;$target.State='Ready'}}.GetNewClosure()
    }
    $emptyProcesses=@{Inspect={@()};Close={throw 'never close'}}
    $scan=Get-LamaTeamCleanupCandidates -ServiceTaskAdapter $adapter -ProcessAdapter $emptyProcesses
    $candidates=$scan.Items
    Assert ($scan.Subsystems.Count -eq 3 -and @($scan.Subsystems | Where-Object { -not $_.Available }).Count -eq 0) 'scan exposes all subsystem availability'
    Assert ($candidates.Count -eq 5) 'running services and ready user tasks shown across vendor and Windows task paths; system/security excluded'
    Assert (@($candidates | Where-Object { $_.TaskPath -eq '\Microsoft\Windows\OneDrive\' }).Count -eq 1) 'non-system Windows task remains discoverable'
    Assert (@($candidates|Where-Object Selected).Count -eq 0 -and $candidates[0].Path -and $candidates[0].DisplayName) 'usable metadata, zero selected'
    $journal=Join-Path $root 'cleanup.json'
    $null=Apply-LamaTeamCleanup -RecoveryPath $journal -ServiceTaskAdapter $adapter -ProcessAdapter $emptyProcesses
    Assert ($state.Changes -eq 0 -and -not (Test-Path $journal)) 'empty selection has zero actions'
    Assert-Throws { Apply-LamaTeamCleanup -SelectedKeys @('Service:AdobeARMservice','Process:424242:123') -RecoveryPath $journal -ServiceTaskAdapter $adapter -ProcessAdapter $emptyProcesses -WarningAction SilentlyContinue } 'mixed selection acknowledgement before any action'
    Assert ($state.Changes -eq 0) 'no service change without process acknowledgement'
    $null=Invoke-CssCleanup -JournalPath $journal -SelectedKeys @('Service:AdobeARMservice','Task:\Mozilla\Mozilla Update') -Adapter $adapter
    $record=Read-CssState $journal
    Assert ($record.Version -eq 2 -and $record.Entries.Count -eq 2 -and @($record.Entries|Where-Object Status -eq 'Changed').Count -eq 2) 'verified successful actions durable'
    Assert ($record.Entries[0].Item.Active -and $record.Entries[1].Item.Enabled) 'journal original eligibility not mutated by fake changes'
    $state.FailRestore=$true
    $null=Invoke-CssCleanup -JournalPath $journal -Restore -Adapter $adapter
    Assert (@((Read-CssState $journal).Entries|Where-Object Status -eq 'RestoreFailed').Count -eq 2) 'failed restores retained'
    $state.FailRestore=$false
    $null=Restore-LamaTeamCleanup -RecoveryPath $journal -ServiceTaskAdapter $adapter
    Assert (@((Read-CssState $journal).Entries|Where-Object Status -eq 'Restored').Count -eq 2) 'retry successful only original app-changed entries'
    $before=$state.Restores; $null=Restore-LamaTeamCleanup -RecoveryPath $journal -ServiceTaskAdapter $adapter
    Assert ($state.Restores -eq $before) 'no repeated restore'
    $null=Invoke-CssCleanup -JournalPath $journal -SelectedKeys 'Service:gupdate' -Adapter $adapter
    $google.State='Running';$google.Active=$true;$google.AcceptStop=$true
    $null=Invoke-CssCleanup -JournalPath $journal -Restore -Adapter $adapter
    Assert ($state.Restores -eq $before -and (Read-CssState $journal).Entries[2].Status -eq 'RestoreFailed') 'external state change blocks restoration'
    $state.FailChange=$true
    $null=Invoke-CssCleanup -JournalPath $journal -SelectedKeys 'Service:MozillaMaintenance' -Adapter $adapter
    Assert ((Read-CssState $journal).Entries[3].Status -eq 'Pending') 'failed action stays uncertain, not owned'
    $null=Invoke-CssCleanup -JournalPath $journal -Restore -Adapter $adapter -WarningAction SilentlyContinue
    Assert ((Read-CssState $journal).Entries[3].Status -eq 'Pending') 'uncertain action never auto-restored'
    $task.Enabled=$false;$task.State='Disabled'
    $before=$state.Changes
    $skipped=@(Invoke-CssCleanup -JournalPath $journal -SelectedKeys 'Task:\Mozilla\Mozilla Update' -Adapter $adapter)[0]
    Assert ($skipped.Status -eq 'Skipped' -and $state.Changes -eq $before) 'stale inactive selection reports skip without claiming ownership'

    $configRoot = Join-Path $root 'player-config'
    $cstrike = Join-Path $configRoot 'cstrike'
    [void][IO.Directory]::CreateDirectory((Join-Path $cstrike 'cfg'))
    $configPath = Join-Path $cstrike 'cfg/autoexec.cfg'
    [IO.File]::WriteAllText($configPath, 'personal_command 1' + "`n")
    $backupPath = Join-Path $configRoot 'autoexec.backup'
    $written = Set-CssPlayerConfig -Cstrike $cstrike -Tweaks @('fps_max_300','m_rawinput') -ConfigBackupPath $backupPath
    $contents = [IO.File]::ReadAllText($configPath)
    Assert ($written.Status -eq 'Installed' -and $contents.Contains('personal_command 1')) 'standalone tweaks preserve existing config'
    Assert ($contents.Contains('fps_max 300') -and $contents.Contains('m_rawinput 1')) 'selected allowlisted tweaks are written'
    Assert ([IO.File]::ReadAllText($backupPath) -ceq "personal_command 1`n") 'tweak write backs up original bytes'
    $repeat = Set-CssPlayerConfig -Cstrike $cstrike -Tweaks @('fps_max_300','m_rawinput') -ConfigBackupPath $backupPath
    Assert (-not $repeat.Changed -and $repeat.Status -eq 'Unchanged') 'reapplying identical tweaks is a no-op'
    Assert-Throws { Set-CssPlayerConfig -Cstrike $cstrike -Tweaks @('exec_untrusted') -ConfigBackupPath $backupPath } 'unknown tweak rejected'
    Assert (([IO.File]::ReadAllText($configPath)).Contains('m_rawinput 1')) 'rejected tweak leaves config unchanged'

    $profileRoot = Join-Path $root 'profile-config'
    $profileCstrike = Join-Path $profileRoot 'cstrike'
    [void][IO.Directory]::CreateDirectory((Join-Path $profileCstrike 'cfg'))
    $profileTarget = Join-Path $profileCstrike 'cfg/autoexec.cfg'
    [IO.File]::WriteAllText($profileTarget, 'old config')
    $profileBackup = Join-Path $profileRoot 'autoexec.backup'
    $assetRoot = Split-Path $PSScriptRoot -Parent | Split-Path -Parent
    $profileResult = Set-CssPlayerConfig -Cstrike $profileCstrike -Profile Modern -Tweaks @('mat_vsync_off') -AssetRoot $assetRoot -ConfigBackupPath $profileBackup
    $profileContents = [IO.File]::ReadAllText($profileTarget)
    Assert ($profileResult.Profile -eq 'Modern' -and $profileResult.Status -eq 'Installed') 'profile and tweak selection are one config operation'
    Assert ($profileContents.Contains('Optimized CFG') -and $profileContents.Contains('mat_vsync 0')) 'selected profile includes tweak overrides'
    Assert ([IO.File]::ReadAllText($profileBackup) -ceq 'old config') 'profile+tweak operation creates one pre-write backup'

    $apiRoot = Join-Path $root 'api-config'
    $apiCstrike = Join-Path $apiRoot 'cstrike'
    [void][IO.Directory]::CreateDirectory((Join-Path $apiCstrike 'cfg'))
    [IO.File]::WriteAllText((Join-Path $apiCstrike 'gameinfo.txt'), 'test game')
    [IO.File]::WriteAllText((Join-Path $apiCstrike 'cfg/autoexec.cfg'), 'api personal config')
    $apiPaths = Get-LamaTeamPaths -GameRoot $apiRoot -StateRoot (Join-Path $root 'state')
    $apiResult = Set-LamaTeamPlayerConfig -GameRoot $apiRoot -Paths $apiPaths -Tweaks @('fps_max_300')
    Assert ($apiResult.Tweaks -contains 'fps_max_300') 'public facade supports tweaks without forcing a profile'
    Assert (([IO.File]::ReadAllText((Join-Path $apiCstrike 'cfg/autoexec.cfg'))).Contains('api personal config')) 'public standalone tweak path preserves current config'
    Write-Output "PASS: $script:checks core checks. No real HTTP, extractor, FFmpeg or Windows actions invoked."
} finally { Remove-Item -LiteralPath $root -Recurse -Force }
