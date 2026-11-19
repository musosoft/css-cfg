# UI-independent core. Importing this module performs no system or network actions.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-CssConfiguration {
    param([string]$StateRoot = (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'LamaTeam/CssCfg'))
    [pscustomobject]@{
        Server = '82.208.17.101:27516'
        FastDlOrigin = 'https://fastdl.lamateam.eu/'
        CatalogUri = 'https://docs.google.com/spreadsheets/d/e/2PACX-1vTufS4N6N-30qHu47IuYFnR8CqjM9iTTWQLQ9d4w0SxpmdI984EcnbG8D4ZAerbtKzuxtTHAlHrZpHQ/pub?output=csv'
        StateRoot = $StateRoot
        ProfilePath = Join-Path $StateRoot 'profile.json'
        SessionPath = Join-Path $StateRoot 'session.json'
        JournalPath = Join-Path $StateRoot 'cleanup-journal.json'
        AssetRoot = Split-Path $PSScriptRoot -Parent
    }
}

function Write-CssAtomicFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][byte[]]$Bytes)
    $full = [IO.Path]::GetFullPath($Path)
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($full))
    $temp = "$full.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        $stream = [IO.FileStream]::new($temp, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $stream.Write($Bytes, 0, $Bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
        [IO.File]::Move($temp, $full, $true)
    } finally { if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) } }
}

function Save-CssState {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$State)
    Write-CssAtomicFile $Path ([Text.UTF8Encoding]::new($false).GetBytes(($State | ConvertTo-Json -Depth 20)))
}

function Read-CssState {
    param([Parameter(Mandatory)][string]$Path)
    if (Test-Path -LiteralPath $Path -PathType Leaf) { Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json }
}

function Get-CssGameInstall {
    [CmdletBinding()]
    param([string[]]$SteamRoots = @(), [string[]]$GameRoots = @())
    # Prefer caller-specified and registered Steam roots, then common install paths.
    # Registry access is limited to known Valve keys and skipped off Windows.
    $roots = [Collections.Generic.List[string]]::new()
    $seenRoots = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $addRoot = {
        param([string]$Path)
        if ([string]::IsNullOrWhiteSpace($Path)) { return }
        try { $fullPath = [IO.Path]::GetFullPath($Path) } catch { return }
        if ((Test-Path -LiteralPath $fullPath -PathType Container) -and $seenRoots.Add($fullPath)) { $roots.Add($fullPath) }
    }
    foreach ($root in $SteamRoots) { & $addRoot $root }
    if ($IsWindows) {
        foreach ($key in @('HKCU:\Software\Valve\Steam','HKLM:\SOFTWARE\Wow6432Node\Valve\Steam','HKLM:\SOFTWARE\Valve\Steam')) {
            try {
                $entry = Get-ItemProperty -LiteralPath $key -ErrorAction Stop
                foreach ($property in @('InstallPath','SteamPath')) {
                    if ($entry.$property) { & $addRoot ([string]$entry.$property) }
                }
            } catch { }
        }
    }
    foreach ($base in @(${env:ProgramFiles(x86)}, $env:ProgramFiles)) {
        if ($base) { & $addRoot (Join-Path $base 'Steam') }
    }

    # Parse both legacy `"1" "D:\\SteamLibrary"` and current nested
    # `"1" { "path" "D:\\SteamLibrary" }` libraryfolders entries.
    $primaryRoots = @($roots.ToArray())
    foreach ($root in $primaryRoots) {
        $vdf = Join-Path $root 'steamapps/libraryfolders.vdf'
        if (-not (Test-Path -LiteralPath $vdf -PathType Leaf)) { continue }
        $text = [IO.File]::ReadAllText($vdf)
        foreach ($pattern in @('(?m)^\s*"\d+"\s+"([^"]+)"', '"path"\s+"([^"]+)"')) {
            foreach ($match in [regex]::Matches($text, $pattern)) {
                $library = $match.Groups[1].Value.Replace('\\', '\')
                & $addRoot $library
            }
        }
    }
    $candidates = [Collections.Generic.List[string]]::new()
    foreach ($p in $GameRoots) { $candidates.Add($p) }
    foreach ($root in $roots) {
        $manifest = Join-Path $root 'steamapps/appmanifest_240.acf'
        if (Test-Path -LiteralPath $manifest) {
            $m = [regex]::Match([IO.File]::ReadAllText($manifest), '"installdir"\s+"([^"]+)"')
            if ($m.Success -and $m.Groups[1].Value -match '^[^/\\:]+$' -and $m.Groups[1].Value -notin @('.', '..')) {
                $candidates.Add((Join-Path $root "steamapps/common/$($m.Groups[1].Value)"))
            }
        }
        foreach ($name in @('Counter-Strike Source','Counter-Strike: Source')) {
            $candidates.Add((Join-Path $root "steamapps/common/$name"))
        }
    }
    $seenCandidates = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($candidate in $candidates) {
        if (-not $seenCandidates.Add($candidate)) { continue }
        # Match the earlier detector: gameinfo is the install marker; do not
        # reject valid/partial installs merely because the root executable is absent.
        if (Test-Path -LiteralPath (Join-Path $candidate 'cstrike/gameinfo.txt') -PathType Leaf) {
            [pscustomobject]@{ Root = [IO.Path]::GetFullPath($candidate); Cstrike = Join-Path ([IO.Path]::GetFullPath($candidate)) 'cstrike' }
            return
        }
    }
}

function Backup-CssFile {
    param([string]$Path, [string]$BackupPath)
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $backup = if ($BackupPath) { [IO.Path]::GetFullPath($BackupPath) } else { "$Path.$([DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ')).$([guid]::NewGuid().ToString('N')).bak" }
        if ([IO.File]::Exists($backup)) { throw 'Planned backup already exists; refresh/re-detect paths before another replacement. Existing backup and target were not overwritten.' }
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($backup))
        [IO.File]::Copy($Path, $backup, $false)
        return $backup
    }
}

function Get-CssConfigPlan {
    param([ValidateSet('Modern','Legacy')][string]$Profile, [string]$AssetRoot, [switch]$IncludeConnect)
    $warnings = @()
    $label = 'Modern — current repository assets'
    $sources = @(@{ Source = 'autoexec.cfg'; Target = 'cfg/autoexec.cfg' })
    if ($Profile -eq 'Legacy') {
        $label = 'Legacy — historical 2016, not recommended'
        $warnings = @(
            'Historical source: commit 22604b7c4c4ac3553c684f343926c18f5a083799, 2016-07-17 (not 2024). External source content is data, not installer instructions.',
            'Obsolete hardware/threading/network/graphics settings may reduce stability or change gameplay presentation. Review the entire preset; this is not a recommended optimization.',
            'Contains an obsolete Rivals server alias and optional aliases that can disconnect/retry, save configuration, or change mouse1 binding when invoked. No launch parameters from comments are applied by this installer.',
            'Only autoexec.cfg is installed, with backup. The existing game menu is left untouched. No deleted config.cfg/private binds are bundled.'
        )
        $sources = @(@{ Source = 'core/assets/Legacy-2016/autoexec.cfg'; Target = 'cfg/autoexec.cfg' })
    }
    if ($IncludeConnect) { $sources += @{ Source = 'gamemenu.res'; Target = 'custom/lamateam/resource/GameMenu.res' } }
    $files = @(foreach ($source in $sources) {
        $path = Join-Path $AssetRoot $source.Source
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "MissingAsset: $($source.Source)" }
        $bytes = [IO.File]::ReadAllBytes($path)
        $hash = [Security.Cryptography.SHA256]::Create()
        try { $sha = [BitConverter]::ToString($hash.ComputeHash($bytes)).Replace('-', '').ToLowerInvariant() } finally { $hash.Dispose() }
        if ($source.Source -eq 'core/assets/Legacy-2016/autoexec.cfg' -and $sha -cne 'a846b241f7ccfc26fdbaf805f015ba96102cbc316c120f4cb74d4f80da7a2aa1') {
            throw 'HistoricalAssetIntegrity: Legacy asset does not match the audited historical bytes.'
        }
        [pscustomobject]@{ Source = $source.Source; Target = $source.Target; Content = [Text.Encoding]::UTF8.GetString($bytes); Sha256 = $sha; Bytes = $bytes }
    })
    [pscustomobject]@{ Profile = $Profile; Label = $label; ReviewRequired = ($Profile -eq 'Legacy'); ReviewSha256 = $(if ($Profile -eq 'Legacy') { $files[0].Sha256 } else { $null }); Warnings = $warnings; Files = $files }
}

function Install-CssConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Cstrike, [Parameter(Mandatory)][ValidateSet('Modern','Legacy')][string]$Profile,
        [string]$AssetRoot = (Get-CssConfiguration).AssetRoot, [string]$ReviewedSha256, [string]$ConfigBackupPath, [string]$MenuBackupPath)
    $plan = Get-CssConfigPlan -Profile $Profile -AssetRoot $AssetRoot
    if ($plan.ReviewRequired -and $ReviewedSha256 -cne $plan.ReviewSha256) {
        throw 'ReviewRequired: preview the entire historical preset and warnings, then supply its exact ReviewSha256. No files changed.'
    }
    # Preflight deterministic target/backup conflicts across the entire requested profile.
    # Otherwise a stale menu backup could fail only AFTER autoexec was already replaced.
    # This does not claim a multi-file transaction against later permission/I/O/race failures.
    foreach ($asset in $plan.Files) {
        $target = Join-Path $Cstrike $asset.Target
        if ((Test-Path -LiteralPath $target) -and -not (Test-Path -LiteralPath $target -PathType Leaf)) { throw "Config target is not a file: $target. No files changed." }
        if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { continue }
        if ([Convert]::ToBase64String([IO.File]::ReadAllBytes($target)) -ceq [Convert]::ToBase64String($asset.Bytes)) { continue }
        $plannedBackup = if ($asset.Target -eq 'cfg/autoexec.cfg') { $ConfigBackupPath } else { $MenuBackupPath }
        if ($plannedBackup -and (Test-Path -LiteralPath $plannedBackup)) {
            throw "Planned backup already exists: $plannedBackup. Refresh/re-detect paths before replacing $target. No files changed."
        }
    }
    foreach ($warningText in $plan.Warnings) { Write-Warning $warningText }
    foreach ($asset in $plan.Files) {
        $target = Join-Path $Cstrike $asset.Target
        if ((Test-Path -LiteralPath $target -PathType Leaf) -and
            [Convert]::ToBase64String([IO.File]::ReadAllBytes($target)) -ceq [Convert]::ToBase64String($asset.Bytes)) {
            [pscustomobject]@{ Path = $target; Backup = $null; Profile = $Profile; Changed = $false; Status = 'Unchanged' }
            continue
        }
        $plannedBackup = if ($asset.Target -eq 'cfg/autoexec.cfg') { $ConfigBackupPath } else { $MenuBackupPath }
        $backup = Backup-CssFile -Path $target -BackupPath $plannedBackup
        Write-CssAtomicFile $target $asset.Bytes
        [pscustomobject]@{ Path = $target; Backup = $backup; Profile = $Profile; Changed = $true; Status = 'Installed' }
    }
}

function Set-CssPlayerConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Cstrike,
        [ValidateSet('Modern','Legacy')][string]$Profile,
        [string[]]$Tweaks = @(),
        [string]$AssetRoot = (Get-CssConfiguration).AssetRoot,
        [string]$ReviewedSha256,
        [string]$ConfigBackupPath,
        [AllowEmptyString()][string]$Content,
        [switch]$BackupAlreadyCreated,
        [string]$ExpectedSha256,
        [switch]$ExpectedMissing
    )
    $allowedTweaks = [ordered]@{
        'fps_max_300' = 'fps_max 300'
        'mat_vsync_off' = 'mat_vsync 0'
        'con_enable' = 'con_enable 1'
        'cl_showfps' = 'cl_showfps 1'
        'net_graph' = 'net_graph 1'
        'm_rawinput' = 'm_rawinput 1'
    }
    $unknown = @($Tweaks | Where-Object { -not $allowedTweaks.Contains($_) })
    if ($unknown.Count) { throw "Unsupported config tweak: $($unknown -join ', ')" }

    $target = Join-Path $Cstrike 'cfg/autoexec.cfg'
    $exists = Test-Path -LiteralPath $target -PathType Leaf
    if ($ExpectedMissing -and $exists) { throw 'The game config appeared after the editor loaded; reload it before saving.' }
    if ($ExpectedSha256) {
        if (-not $exists) { throw 'The game config disappeared after the editor loaded; reload it before saving.' }
        $currentHash = (Get-FileHash -LiteralPath $target -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
        if ($currentHash -cne $ExpectedSha256.ToLowerInvariant()) {
            throw 'The game config changed outside the editor; reload it before saving to avoid overwriting newer edits.'
        }
    }
    $hasContent = $PSBoundParameters.ContainsKey('Content')
    if ($Profile) {
        $plan = Get-CssConfigPlan -Profile $Profile -AssetRoot $AssetRoot
        if ($plan.ReviewRequired -and $ReviewedSha256 -cne $plan.ReviewSha256) {
            throw 'ReviewRequired: preview the entire historical preset and warnings, then supply its exact ReviewSha256. No files changed.'
        }
        if (-not $hasContent) {
            $asset = $plan.Files | Where-Object Target -CEQ 'cfg/autoexec.cfg' | Select-Object -First 1
            if (-not $asset) { throw 'Selected config profile has no autoexec.cfg.' }
            $baseText = [Text.Encoding]::UTF8.GetString($asset.Bytes)
        } else { $baseText = $Content }
    } elseif ($hasContent) {
        $baseText = $Content
    } else {
        if ($exists) {
            $bytes = [IO.File]::ReadAllBytes($target)
            if ($bytes.Length -ge 2 -and (($bytes[0] -eq 255 -and $bytes[1] -eq 254) -or
                ($bytes[0] -eq 254 -and $bytes[1] -eq 255) -or ($bytes[0] -eq 0 -and $bytes[1] -eq 0))) {
                throw 'Unsupported config encoding: UTF-16/32 is not modified.'
            }
            try { $baseText = [Text.UTF8Encoding]::new($false, $true).GetString($bytes) }
            catch { throw 'Unsupported config encoding: autoexec.cfg is not valid UTF-8; no files changed.' }
        } else { $baseText = '' }
    }
    if ($baseText.Length -gt 1000000 -or $baseText.Contains([char]0)) {
        throw 'Config text is too large or contains a null character; no files changed.'
    }

    $begin = '// BEGIN LAMATEAM LAUNCHER TWEAKS'
    $end = '// END LAMATEAM LAUNCHER TWEAKS'
    $pattern = '(?ms)^' + [regex]::Escape($begin) + '\r?\n.*?^' + [regex]::Escape($end) + '(?:\r?\n)?'
    $baseText = [regex]::Replace($baseText, $pattern, '')
    $selected = @($allowedTweaks.Keys | Where-Object { $_ -in $Tweaks })
    if ($selected.Count) {
        $newline = if ($baseText.Contains("`r`n")) { "`r`n" } else { "`n" }
        $trimmed = $baseText.TrimEnd("`r", "`n")
        $lines = @($begin) + @($selected | ForEach-Object { $allowedTweaks[$_] }) + @($end)
        $section = $lines -join $newline
        $baseText = if ($trimmed.Length) { "$trimmed$newline$newline$section$newline" } else { "$section$newline" }
    }
    try { $newBytes = [Text.UTF8Encoding]::new($false, $true).GetBytes($baseText) }
    catch { throw 'Config text is not valid UTF-16 input for UTF-8 encoding; no files changed.' }
    if ($exists -and [Convert]::ToBase64String([IO.File]::ReadAllBytes($target)) -ceq [Convert]::ToBase64String($newBytes)) {
        return [pscustomobject]@{
            Path=$target; Backup=$null; Profile=$Profile; Tweaks=$selected; Changed=$false; Status='Unchanged'
            Sha256=(Get-FileHash -LiteralPath $target -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
        }
    }
    if ($exists -and $ConfigBackupPath -and (Test-Path -LiteralPath $ConfigBackupPath) -and -not $BackupAlreadyCreated) {
        throw "Planned backup already exists: $ConfigBackupPath. Refresh/re-detect paths before replacing $target. No files changed."
    }
    if ($BackupAlreadyCreated -and $exists -and $ConfigBackupPath -and -not (Test-Path -LiteralPath $ConfigBackupPath)) {
        throw 'The editor backup is missing; reload the game config before saving.'
    }
    $backup = if ($BackupAlreadyCreated) { $null } else { Backup-CssFile -Path $target -BackupPath $ConfigBackupPath }
    Write-CssAtomicFile -Path $target -Bytes $newBytes
    [pscustomobject]@{
        Path=$target; Backup=$backup; Profile=$Profile; Tweaks=$selected; Changed=$true; Status='Installed'
        Sha256=(Get-FileHash -LiteralPath $target -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
    }
}

function Get-CssConfigStatements {
    param([string]$Text)
    # Source CFG statement boundaries, not executable PowerShell. Respect quoted alias bodies and // comments.
    $statement = [Text.StringBuilder]::new(); $quoted = $false; $comment = $false
    for ($i=0; $i -lt $Text.Length; $i++) {
        $character = $Text[$i]
        if ($comment) { if ($character -ne "`n" -and $character -ne "`r") { continue }; $comment = $false }
        if (-not $quoted -and $character -eq '/' -and $i+1 -lt $Text.Length -and $Text[$i+1] -eq '/') { $comment = $true; continue }
        if ($character -eq '"') {
            $slashes = 0
            for ($j=$i-1; $j -ge 0 -and $Text[$j] -eq '\'; $j--) { $slashes++ }
            if ($slashes % 2 -eq 0) { $quoted = -not $quoted }
        }
        if (-not $quoted -and $character -in @(';',"`r","`n")) {
            if ($statement.Length) { $statement.ToString().Trim(); [void]$statement.Clear() }
        } else { [void]$statement.Append($character) }
    }
    if ($statement.Length) { $statement.ToString().Trim() }
}

function Get-CssServerAliasPlan {
    param([string]$Path)
    $line = 'alias lama "connect 82.208.17.101:27516"'
    $original = if (Test-Path -LiteralPath $Path) { [IO.File]::ReadAllBytes($Path) } else { [byte[]]@() }
    if ($original.Length -ge 2 -and (($original[0] -eq 255 -and $original[1] -eq 254) -or
        ($original[0] -eq 254 -and $original[1] -eq 255) -or ($original[0] -eq 0 -and $original[1] -eq 0))) {
        throw 'Unsupported config encoding: UTF-16/32 is not modified.'
    }
    $text = if (Test-Path -LiteralPath $Path) { [IO.File]::ReadAllText($Path) } else { '' }
    $aliases = @(Get-CssConfigStatements $text | Where-Object { $_ -match '^\s*alias\s+"?lama"?\s+' })
    if ($aliases.Count -gt 0) {
        if (@($aliases | Where-Object { $_ -notmatch '^\s*alias\s+"?lama"?\s+"connect 82\.208\.17\.101:27516"\s*$' }).Count) { throw 'AliasConflict: existing lama alias was not overwritten.' }
        return [pscustomobject]@{ Changed = $false; Bytes = $original }
    }
    $nl = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
    $suffix = if ($text.Length -gt 0 -and -not $text.EndsWith("`n")) { $nl } else { '' }
    # Append bytes rather than re-encode the existing configuration.
    [pscustomobject]@{ Changed = $true; Bytes = [byte[]]($original + [Text.Encoding]::UTF8.GetBytes("$suffix$line$nl")) }
}

function Add-CssServerAlias {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [string]$BackupPath)
    $plan = Get-CssServerAliasPlan -Path $Path
    if (-not $plan.Changed) { return [pscustomobject]@{ Changed = $false; Backup = $null } }
    $backup = Backup-CssFile -Path $Path -BackupPath $BackupPath
    Write-CssAtomicFile -Path $Path -Bytes $plan.Bytes
    [pscustomobject]@{ Changed = $true; Backup = $backup }
}

function Test-CssMapName {
    param([AllowEmptyString()][string]$Name)
    return ($Name -cmatch '^[A-Za-z0-9$][A-Za-z0-9_$-]{0,127}$' -and $Name -notmatch '^(?i:con|prn|aux|nul|com[0-9]|lpt[0-9])$')
}

function ConvertFrom-CssMapList {
    param([Parameter(Mandatory)][string]$Text, [ValidateSet('Lines','Csv')][string]$Format = 'Lines', [string]$Column = 'map')
    $values = if ($Format -eq 'Csv') {
        # Built-in .NET parser rejects malformed quotation rather than silently accepting truncated rows.
        $parser = [Microsoft.VisualBasic.FileIO.TextFieldParser]::new([IO.StringReader]::new($Text))
        try {
            $parser.SetDelimiters(','); $parser.HasFieldsEnclosedInQuotes = $true
            $header = $parser.ReadFields()
            if (-not $header -or $Column -notin $header) { throw "Missing map column: $Column" }
            $indices = @(for ($i=0; $i -lt $header.Count; $i++) { if ($header[$i] -ieq $Column) { $i } })
            if ($indices.Count -ne 1) { throw 'Ambiguous map column' }
            while (-not $parser.EndOfData) {
                $row = $parser.ReadFields()
                if ($row.Count -ne $header.Count) { throw 'CSV row has an unexpected field count' }
                $row[$indices[0]]
            }
        } finally { $parser.Dispose() }
    } else { $Text -split '\r?\n' }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($value in $values) {
        $name = $value.Trim()
        # CSV may contain literal Source-style edge quotes in addition to CSV enclosure.
        $name = $name.Trim([char]'"')
        if (-not $name -or $name.StartsWith('#')) { continue }
        $name = $name -replace '(?i)\.bsp(?:\.bz2)?$', ''
        if (-not (Test-CssMapName $name)) { throw "Unsafe map name: $name" }
        if ($seen.Add($name)) { $name }
    }
}

function Get-CssMapUri {
    param([Parameter(Mandatory)][string]$Name, [string]$Directory = 'maps')
    if (-not (Test-CssMapName $Name)) { throw 'Unsafe map name' }
    if ($Directory -cne 'maps') { throw 'FastDL directory must be maps for the verified host layout' }
    [uri]('https://fastdl.lamateam.eu/maps/' + $Name + '.bsp.bz2')
}

function Test-CssBsp {
    param([Parameter(Mandatory)][string]$Path)
    # Source BSP header: magic, version, 64 lump descriptors, map revision.
    if (-not [IO.File]::Exists($Path)) { return $false }
    $s = [IO.File]::OpenRead($Path)
    try {
        if ($s.Length -lt 1036) { return $false }
        $r = [IO.BinaryReader]::new($s)
        if ([Text.Encoding]::ASCII.GetString($r.ReadBytes(4)) -cne 'VBSP') { return $false }
        $version = $r.ReadInt32()
        if ($version -lt 19 -or $version -gt 21) { return $false }
        for ($i = 0; $i -lt 64; $i++) {
            $offset = $r.ReadInt32(); $length = $r.ReadInt32()
            [void]$r.ReadInt32(); [void]$r.ReadInt32()
            if ($offset -lt 0 -or $length -lt 0 -or ([long]$offset + $length) -gt $s.Length) { return $false }
            if ($length -gt 0 -and $offset -lt 1036) { return $false }
        }
        return $true
    } catch { return $false } finally { $s.Dispose() }
}

. (Join-Path $PSScriptRoot 'CssCfg.Network.ps1')
. (Join-Path $PSScriptRoot 'CssCfg.Media.ps1')
. (Join-Path $PSScriptRoot 'CssCfg.Cleanup.ps1')
. (Join-Path $PSScriptRoot 'CssCfg.Process.ps1')
. (Join-Path $PSScriptRoot 'CssCfg.SteamDisplay.ps1')
. (Join-Path $PSScriptRoot 'LamaTeam.Api.ps1')

Export-ModuleMember -Function Get-CssConfiguration,Save-CssState,Read-CssState,Get-CssGameInstall,Install-CssConfig,Set-CssPlayerConfig,Add-CssServerAlias,Test-CssMapName,ConvertFrom-CssMapList,Get-CssMapUri,Test-CssBsp,Sync-CssMaps,Find-CssFfmpeg,Convert-CssValveVideo,Get-CssCleanupInspection,Invoke-CssCleanup,Get-CssProcessInspection,Invoke-CssProcessClose
Export-ModuleMember -Function Get-LamaTeamPaths,Find-LamaTeamGame,Get-LamaTeamConfigPreview,Install-LamaTeamConfig,Set-LamaTeamPlayerConfig,Save-LamaTeamConfigText,Add-LamaTeamConnect,Get-LamaTeamMaps,Sync-LamaTeamMaps,Get-LamaTeamCleanupCandidates,Apply-LamaTeamCleanup,Restore-LamaTeamCleanup,Get-LamaTeamCleanupRecovery,Convert-LamaTeamIntroVideo,Get-CssVdfApp240Section,Get-CssSteamLaunchOptionsFromText,Resolve-CssSteamUserConfig,Get-CssSteamLaunchOptions,Set-CssSteamLaunchOptions,Get-CssDisplayRefreshInfo,Set-CssDisplayRefreshRate
