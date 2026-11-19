# Network responses are data. No executable, script, or archive-selected path is ever installed.
function Receive-CssHttpsFile {
    param([uri]$Uri, [string]$Path, [long]$MaxBytes, [switch]$Catalog, [hashtable]$HttpAdapter,
        [ValidateRange(1,30)][int]$TimeoutMinutes = 5)
    if ($Uri.Scheme -cne 'https' -or $Uri.UserInfo -or -not $Uri.IsDefaultPort) { throw 'Only standard-port HTTPS is allowed' }
    $handler = $null; $client = $null
    $timeout = [TimeSpan]::FromMinutes($TimeoutMinutes)
    $deadline = [Threading.CancellationTokenSource]::new($timeout)
    if (-not $HttpAdapter) {
        $handler = [Net.Http.HttpClientHandler]::new(); $handler.AllowAutoRedirect = $false
        $handler.SslProtocols = [Security.Authentication.SslProtocols]::Tls12 -bor [Security.Authentication.SslProtocols]::Tls13
        $client = [Net.Http.HttpClient]::new($handler); $client.Timeout = $timeout
    }
    try {
        for ($hop = 0; $hop -le 5; $hop++) {
            $response = $null; $stream = $null
            try {
                if ($HttpAdapter) {
                    $data = & $HttpAdapter.Get $Uri
                    $code = [int]$data.StatusCode; $headers = $data.Headers; $stream = $data.Stream
                } else {
                    $response = $client.GetAsync($Uri, [Net.Http.HttpCompletionOption]::ResponseHeadersRead, $deadline.Token).GetAwaiter().GetResult()
                    $code = [int]$response.StatusCode
                    $headers = @{ Location = [string]$response.Headers.Location; ContentType = [string]$response.Content.Headers.ContentType; ContentLength = $response.Content.Headers.ContentLength }
                    $stream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
                }
                if ($code -in @(301,302,303,307,308)) {
                    if (-not $Catalog -or $hop -eq 5) { throw "Unexpected HTTP redirect: $code" }
                    $next = [uri]::new($Uri, [string]$headers.Location)
                    if ($next.Scheme -cne 'https' -or $next.UserInfo -or -not $next.IsDefaultPort -or
                        ($next.Host -ne 'docs.google.com' -and -not $next.Host.EndsWith('.googleusercontent.com', [StringComparison]::OrdinalIgnoreCase))) { throw 'Unsafe catalog redirect' }
                    $Uri = $next; continue
                }
                if ($code -ne 200) { throw "HTTP $code from $($Uri.Host)" }
                if ($headers.ContentLength -and [long]$headers.ContentLength -gt $MaxBytes) { throw 'Response exceeds size limit' }
                if ($Catalog -and [string]$headers.ContentType -notmatch '^(?i:text/(?:csv|plain)|application/(?:csv|octet-stream))(?:;|$)') { throw 'Catalog response is not CSV/text' }
                $output = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
                try {
                    $buffer = [byte[]]::new(65536); $total = 0L
                    while (($count = $stream.ReadAsync($buffer, 0, $buffer.Length, $deadline.Token).GetAwaiter().GetResult()) -gt 0) {
                        $total += $count
                        if ($total -gt $MaxBytes) { throw 'Response exceeds size limit' }
                        $output.Write($buffer, 0, $count)
                    }
                    if ($total -eq 0) { throw 'Empty HTTP response' }
                    $output.Flush($true)
                } finally { $output.Dispose() }
                return
            } finally {
                if ($stream) { $stream.Dispose() }
                if ($response) { $response.Dispose() }
            }
        }
        throw 'Too many redirects'
    } catch {
        if ($deadline.IsCancellationRequested) {
            throw "HTTPS download exceeded its $TimeoutMinutes-minute limit. Check the connection and retry; no game files were changed."
        }
        throw
    } finally { $deadline.Dispose(); if ($client) { $client.Dispose() }; if ($handler) { $handler.Dispose() } }
}

function ConvertFrom-CssCatalogText {
    param([string]$Text)
    $parser = [Microsoft.VisualBasic.FileIO.TextFieldParser]::new([IO.StringReader]::new($Text))
    $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $accepted = [Collections.Generic.List[string]]::new()
    $skipped = 0
    try {
        $parser.SetDelimiters(','); $parser.HasFieldsEnclosedInQuotes = $true
        $header = $parser.ReadFields()
        if (-not $header) { throw 'Empty map catalog' }
        $indices = @(for ($i=0; $i -lt $header.Count; $i++) {
            if ($header[$i].Trim() -match '^(?i:map|maps|map name|mapname|mapa|nazov mapy|názov mapy)$') { $i }
        })
        if ($indices.Count -ne 1) { throw 'Catalog needs exactly one recognized map-name column' }
        $rowNumber = 1
        while (-not $parser.EndOfData) {
            $row = $parser.ReadFields(); $rowNumber++
            if ($row.Count -ne $header.Count) { throw "Malformed catalog field count on row $rowNumber" }
            $name = $row[$indices[0]].Trim()
            # Strip edge quote characters only; never reinterpret a filename as a price/placeholder.
            $name = $name.Trim([char]'"')
            if (-not $name) { $skipped++; continue }
            # The published sheet appends UMC fragments with a map key in column 0 and
            # min_players/max_players in columns 1/3. These are not map-list rows.
            if ($indices[0] -eq 1 -and $row.Count -ge 5 -and $name -ceq 'min_players' -and
                (Test-CssMapName ($row[0].Trim().Trim([char]'"'))) -and $row[3].Trim().Trim([char]'"') -ceq 'max_players') { $skipped++; continue }
            $name = $name -replace '(?i)\.bsp(?:\.bz2)?$', ''
            if (-not (Test-CssMapName $name)) { throw "Unsafe map name on catalog row ${rowNumber}: $name" }
            if ($names.Add($name)) { $accepted.Add($name) }
        }
    } finally { $parser.Dispose() }
    if ($accepted.Count -eq 0) { throw 'Empty/invalid map catalog: no safe map entries remain after known non-map rows were skipped' }
    if ($skipped) { Write-Warning "Skipped $skipped empty or structurally identified UMC footer rows. Map names, including dollar-prefixed names, are never classified as prices/placeholders." }
    $accepted.ToArray()
}

function Get-CssMapCatalog {
    param([hashtable]$HttpAdapter)
    $temp = Join-Path ([IO.Path]::GetTempPath()) ("css-catalog-$([guid]::NewGuid().ToString('N')).csv")
    try {
        Receive-CssHttpsFile -Uri (Get-CssConfiguration).CatalogUri -Path $temp -MaxBytes 4MB -Catalog -HttpAdapter $HttpAdapter
        $text = [Text.UTF8Encoding]::new($false, $true).GetString([IO.File]::ReadAllBytes($temp)).TrimStart([char]0xFEFF)
        if ($text -match '^\s*<' -or $text.Contains([char]0)) { throw 'Invalid CSV catalog' }
        $names = @(ConvertFrom-CssCatalogText -Text $text)
        if ($names.Count -eq 0) { throw 'Empty map catalog; nothing was synchronized' }
        $names
    } finally { if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) } }
}

function Find-CssExtractor {
    foreach ($name in @('7z','7za','7zz','bzip2')) {
        $command = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($command) { return [pscustomobject]@{ Path = $command.Source; Kind = $(if ($name -eq 'bzip2') { 'bzip2' } else { '7zip' }) } }
    }
    foreach ($root in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if ($root) {
            $path = Join-Path $root '7-Zip/7z.exe'
            if (Test-Path -LiteralPath $path -PathType Leaf) { return [pscustomobject]@{ Path = $path; Kind = '7zip' } }
        }
    }
}

function Expand-CssBzip {
    param([string]$Archive, [string]$Output, $Extractor, [long]$MaxBytes = 1GB)
    # -so/-c streams ONE bz2 payload, ignoring archived names. No archive directory extraction.
    $arguments = if ($Extractor.Kind -eq '7zip') { @('x','-so','-bd','-y','--',$Archive) } else { @('-d','-c','--',$Archive) }
    $info = [Diagnostics.ProcessStartInfo]::new(); $info.FileName = $Extractor.Path; $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true; $info.CreateNoWindow = $true
    foreach ($argument in $arguments) { $info.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new(); $process.StartInfo = $info
    $deadline = [Threading.CancellationTokenSource]::new([TimeSpan]::FromMinutes(5))
    $outputStream = $null
    try {
        if (-not $process.Start()) { throw 'Could not start installed extractor' }
        $stderr = $process.StandardError.BaseStream.CopyToAsync([IO.Stream]::Null)
        $outputStream = [IO.File]::Open($Output, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $buffer = [byte[]]::new(65536); $total = 0L
        while (($count = $process.StandardOutput.BaseStream.ReadAsync($buffer, 0, $buffer.Length, $deadline.Token).GetAwaiter().GetResult()) -gt 0) {
            $total += $count
            if ($total -gt $MaxBytes) { throw 'Decompressed BSP exceeds 1 GiB limit' }
            $outputStream.Write($buffer, 0, $count)
        }
        $outputStream.Flush($true)
        if (-not $process.WaitForExit(300000)) { throw 'Extractor did not exit in time; close its helper process manually if necessary. No process was force-terminated.' }
        $null = $stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw "Installed extractor failed (exit $($process.ExitCode)); archive may be corrupt" }
    } finally {
        if ($outputStream) { $outputStream.Dispose() }
        # Never force-terminate a process. Closing the pipe lets the extractor detect a broken pipe.
        $process.Dispose()
        $deadline.Dispose()
    }
}

function Sync-CssMaps {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Names, [Parameter(Mandatory)][string]$Destination,
        [string]$FastDlDirectory = 'maps', [string[]]$ExistingDirectories = @(), [scriptblock]$Progress,
        [scriptblock]$Downloader, [scriptblock]$Decompressor, [scriptblock]$ExtractorDiscovery, [hashtable]$HttpAdapter)
    if ($Names.Count -eq 0) { throw 'Empty map selection/catalog; nothing was synchronized' }
    $index = 0
    foreach ($name in $Names) {
        $work = $null; $status = 'Failed'; $errorText = $null
        try {
            $uri = Get-CssMapUri $name $FastDlDirectory
            $valid = $false
            foreach ($dir in (@($Destination) + $ExistingDirectories)) {
                if (Test-CssBsp (Join-Path $dir "$name.bsp")) { $valid = $true; break }
            }
            if ($valid) { $status = 'Skipped' } else {
                $extractor = if ($ExtractorDiscovery) { & $ExtractorDiscovery } else { Find-CssExtractor }
                if (-not $extractor) { throw 'MissingExtractor: install 7-Zip or bzip2 separately and retry. No executable will be downloaded.' }
                [void][IO.Directory]::CreateDirectory($Destination)
                $work = Join-Path $Destination ('.css-map-' + [guid]::NewGuid().ToString('N'))
                [void][IO.Directory]::CreateDirectory($work)
                $archive = Join-Path $work "$name.bsp.bz2"; $bsp = Join-Path $work "$name.bsp"
                if ($Downloader) { $null = & $Downloader $uri $archive 512MB } else {
                    Receive-CssHttpsFile -Uri $uri -Path $archive -MaxBytes 512MB -HttpAdapter $HttpAdapter
                }
                $inputStream = [IO.File]::OpenRead($archive)
                try { $header = [byte[]]::new(4); $read = $inputStream.Read($header,0,4) } finally { $inputStream.Dispose() }
                if ((Get-Item -LiteralPath $archive).Length -gt 512MB -or $read -ne 4 -or
                    [Text.Encoding]::ASCII.GetString($header,0,3) -cne 'BZh' -or $header[3] -lt 49 -or $header[3] -gt 57) { throw 'Invalid BZip2 archive' }
                if ($Decompressor) { $null = & $Decompressor $archive $bsp $extractor 1GB } else { Expand-CssBzip $archive $bsp $extractor }
                if ((Get-Item -LiteralPath $bsp).Length -gt 1GB -or -not (Test-CssBsp $bsp)) { throw 'Decompressed file is not a valid Source BSP' }
                $target = Join-Path $Destination "$name.bsp"
                # Recheck after download to preserve a valid file installed by another caller meanwhile.
                if (Test-CssBsp $target) { $status = 'Skipped' } else { [IO.File]::Move($bsp, $target, $true); $status = 'Installed' }
            }
        } catch { $errorText = $_.Exception.Message } finally {
            if ($work -and [IO.Directory]::Exists($work)) { [IO.Directory]::Delete($work, $true) }
        }
        $index++
        $result = [pscustomobject]@{ Name = $name; Status = $status; Error = $errorText; Completed = $index; Total = $Names.Count }
        if ($Progress) { try { $null = & $Progress $result } catch { Write-Warning "Progress callback failed: $($_.Exception.Message)" } }
        $result
    }
}
