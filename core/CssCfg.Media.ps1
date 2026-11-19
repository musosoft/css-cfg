$script:CssFfmpegVersion = '9.0.2'
$script:CssFfmpegArchiveUri = [uri]'https://www.gyan.dev/ffmpeg/builds/packages/ffmpeg-9.0.2-essentials_build.zip'
$script:CssFfmpegArchiveSha256 = '60F467265B1E312373DBCD92200C2618A74850F98D3D078E94296BB3FA2047BA'

function Get-CssFfmpegCacheRoot([string]$CacheRoot) {
    if ($CacheRoot) { return [IO.Path]::GetFullPath($CacheRoot) }
    $local = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    if (-not $local) { throw 'Per-user application data folder is unavailable; cannot cache FFmpeg safely.' }
    Join-Path $local 'LamaTeam/CssCfg/Tools'
}

function Find-CssFfmpeg {
    param([string]$Path, [string]$CacheRoot)
    if ($Path) {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw 'FFmpeg not found' }
        return [IO.Path]::GetFullPath($Path)
    }
    $command = Get-Command ffmpeg -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { $command.Source }
    if (-not $command) {
        $cached = Join-Path (Get-CssFfmpegCacheRoot $CacheRoot) "ffmpeg-$($script:CssFfmpegVersion)/ffmpeg.exe"
        if (Test-Path -LiteralPath $cached -PathType Leaf) { return $cached }
    }
}

function Test-CssFfmpegExecutable([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw 'Cached FFmpeg executable is missing.' }
    $version = @(& $Path -hide_banner -version 2>&1)
    if ($LASTEXITCODE -ne 0 -or (($version -join "`n") -notmatch '(?im)^ffmpeg version ')) {
        throw 'FFmpeg could not start or did not identify itself as FFmpeg.'
    }
    $encoders = @(& $Path -hide_banner -encoders 2>&1)
    $encoderExit = $LASTEXITCODE
    if ($encoderExit -ne 0 -or ($encoders -join "`n") -notmatch '(?m)\blibvpx-vp9\b' -or
        ($encoders -join "`n") -notmatch '(?m)\blibvorbis\b') {
        throw 'FFmpeg is missing the required VP9 or Vorbis encoder.'
    }
    $decoders = @(& $Path -hide_banner -decoders 2>&1)
    if ($LASTEXITCODE -ne 0 -or ($decoders -join "`n") -notmatch '(?m)\bbinkvideo\b') {
        throw 'FFmpeg is missing the Bink video decoder needed for valve.bik.'
    }
    return $true
}

function Expand-CssFfmpegArchive {
    param([Parameter(Mandatory)][string]$ArchivePath,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$ExpectedSha256)
    $actual = (Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA256).Hash
    if (-not $actual.Equals($ExpectedSha256, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'FFmpeg download failed its pinned SHA-256 check; it was not installed.'
    }
    $archiveStream = [IO.File]::OpenRead($ArchivePath)
    $archive = $null
    try {
        $archive = [IO.Compression.ZipArchive]::new($archiveStream, [IO.Compression.ZipArchiveMode]::Read, $false)
        $entries = @($archive.Entries | Where-Object { $_.FullName -match '(?i)(?:^|/)bin/ffmpeg\.exe$' })
        if ($entries.Count -ne 1 -or $entries[0].Length -lt 1MB -or $entries[0].Length -gt 120MB) {
            throw 'FFmpeg archive did not contain exactly one plausible bin/ffmpeg.exe.'
        }
        $input = $entries[0].Open()
        $output = [IO.File]::Open($Destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $input.CopyTo($output); $output.Flush($true) }
        finally { $input.Dispose(); $output.Dispose() }
    } finally {
        if ($archive) { $archive.Dispose() }
        $archiveStream.Dispose()
    }
    return $Destination
}

function Install-CssFfmpeg {
    param([string]$CacheRoot, [hashtable]$HttpAdapter)
    $tools = Get-CssFfmpegCacheRoot $CacheRoot
    $versionRoot = Join-Path $tools "ffmpeg-$($script:CssFfmpegVersion)"
    $target = Join-Path $versionRoot 'ffmpeg.exe'
    if (Test-Path -LiteralPath $target -PathType Leaf) {
        $null = Test-CssFfmpegExecutable $target
        return $target
    }
    if (Test-Path -LiteralPath $versionRoot) {
        throw "FFmpeg cache exists but is incomplete: $versionRoot. Nothing was overwritten."
    }
    [void][IO.Directory]::CreateDirectory($tools)
    $stage = Join-Path $tools ('.ffmpeg-' + [guid]::NewGuid().ToString('N') + '.tmp')
    [void][IO.Directory]::CreateDirectory($stage)
    try {
        $archivePath = Join-Path $stage 'ffmpeg.zip'
        Receive-CssHttpsFile -Uri $script:CssFfmpegArchiveUri -Path $archivePath -MaxBytes 128MB -HttpAdapter $HttpAdapter -TimeoutMinutes 15
        $candidate = Join-Path $stage 'ffmpeg.exe'
        $null = Expand-CssFfmpegArchive -ArchivePath $archivePath -Destination $candidate -ExpectedSha256 $script:CssFfmpegArchiveSha256
        $null = Test-CssFfmpegExecutable $candidate
        [void][IO.Directory]::CreateDirectory($versionRoot)
        [IO.File]::Move($candidate, $target)
        return $target
    } finally {
        if (Test-Path -LiteralPath $stage -PathType Container) {
            Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Resolve-CssFfmpeg {
    param([string]$Path, [string]$CacheRoot, [hashtable]$HttpAdapter)
    if ($Path) {
        try {
            $found = Find-CssFfmpeg -Path $Path
            $null = Test-CssFfmpegExecutable $found
            return $found
        } catch {
            # A PATH entry may exist but lack the codecs this conversion needs.
            # Fall through to the isolated app-local build instead of failing.
        }
    }
    $cached = Join-Path (Get-CssFfmpegCacheRoot $CacheRoot) "ffmpeg-$($script:CssFfmpegVersion)/ffmpeg.exe"
    if (Test-Path -LiteralPath $cached -PathType Leaf) {
        $null = Test-CssFfmpegExecutable $cached
        return $cached
    }
    return Install-CssFfmpeg -CacheRoot $CacheRoot -HttpAdapter $HttpAdapter
}

function Convert-CssValveVideo {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$MediaDirectory, [switch]$OptIn, [string]$FfmpegPath,
        [switch]$BackupExisting, [string]$BackupPath, [hashtable]$VideoAdapter,
        [string]$FfmpegCacheRoot, [hashtable]$HttpAdapter)
    if (-not $OptIn) { throw 'Video conversion requires explicit OptIn' }
    $source = Join-Path $MediaDirectory 'valve.bik'; $target = Join-Path $MediaDirectory 'valve.webm'
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw 'valve.bik is missing; select the media directory containing it' }
    $exists = Test-Path -LiteralPath $target
    if ($exists -and -not $BackupExisting) { throw 'valve.webm exists. Preview an explicit backup path, then opt into BackupExisting; target was not overwritten.' }
    $exe = if ($VideoAdapter) { $FfmpegPath } else { Resolve-CssFfmpeg -Path $FfmpegPath -CacheRoot $FfmpegCacheRoot -HttpAdapter $HttpAdapter }
    $temp = Join-Path $MediaDirectory "$([guid]::NewGuid().ToString('N')).webm"
    $backup = $null
    try {
        if ($VideoAdapter) { $null = & $VideoAdapter.Convert $source $temp $exe } else {
            $log = & $exe -nostdin -v error -xerror -n -i $source `
                -map '0:v:0' -map '0:a?' -fps_mode passthrough -pix_fmt yuv420p `
                -c:v libvpx-vp9 -lossless 1 -b:v 0 -crf 0 `
                -c:a libvorbis -q:a 10 -ar 44100 -ac 2 $temp 2>&1
            if ($LASTEXITCODE -ne 0) { throw "FFmpeg conversion failed (exit $LASTEXITCODE)" }
        }
        if (-not (Test-Path -LiteralPath $temp -PathType Leaf) -or (Get-Item -LiteralPath $temp).Length -lt 4) { throw 'Missing/truncated WebM output' }
        $stream = [IO.File]::OpenRead($temp)
        try { $bytes = [byte[]]::new(4); [void]$stream.Read($bytes,0,4) } finally { $stream.Dispose() }
        if ([BitConverter]::ToString($bytes) -cne '1A-45-DF-A3') { throw 'Invalid WebM EBML header' }
        if ($VideoAdapter) {
            if (-not (& $VideoAdapter.Validate $temp $exe)) { throw 'Generated WebM failed decode validation' }
        } else {
            # Validate by fully decoding the generated WebM, not just trusting a four-byte header.
            $log = & $exe -nostdin -v error -xerror -protocol_whitelist file,pipe -f webm -i $temp -map '0:v:0' -map '0:a?' -f null - 2>&1
            if ($LASTEXITCODE -ne 0) { throw "Generated WebM failed decode validation (exit $LASTEXITCODE)" }
        }
        if ($exists) { $backup = Backup-CssFile -Path $target -BackupPath $BackupPath }
        [IO.File]::Move($temp, $target, [bool]$exists)
        [pscustomobject]@{ Status = 'Converted'; Path = $target; Source = $source; Backup = $backup; ConverterPath = $exe; SourcePreserved = $true; Validated = $true }
    } finally { if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) } }
}
