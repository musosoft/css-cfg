# --- Sync-CS-Maps.ps1 ---

# Require elevation to write under Program Files (x86)
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  Write-Warning "Run this script as Administrator to write to Program Files (x86)."
  if ($Host.Name -eq "ConsoleHost") {
    Write-Host "Press any key to exit..."
    [System.Console]::ReadKey($true) | Out-Null
  }
  return
}

$FastDL_URL = "http://gocasa1.fakaheda.eu/fastdl/27516/maps/"
$CsvUrl = "https://docs.google.com/spreadsheets/d/e/2PACX-1vTufS4N6N-30qHu47IuYFnR8CqjM9iTTWQLQ9d4w0SxpmdI984EcnbG8D4ZAerbtKzuxtTHAlHrZpHQ/pub?output=csv"
$SevenZipUrl = "https://www.7-zip.org/a/7zr.exe"

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# --- Steam CSS detection ---
function Get-SteamRoot {
  $paths = @(
    "HKLM:\SOFTWARE\Wow6432Node\Valve\Steam",
    "HKLM:\SOFTWARE\Valve\Steam"
  )
  foreach ($p in $paths) {
    try {
      $v = (Get-ItemProperty -Path $p -Name InstallPath -ErrorAction Stop).InstallPath
      if ($v -and (Test-Path $v)) { return $v }
    } catch {}
  }
  throw "Steam InstallPath not found"
}

function Get-SteamLibraries {
  $root = Get-SteamRoot
  $vdf = Join-Path $root "steamapps\libraryfolders.vdf"
  $libs = [System.Collections.Generic.List[string]]::new()
  if (Test-Path $vdf) {
    $content = Get-Content -Path $vdf -Raw
    $matches = [regex]::Matches($content, '^\s*"\d+"\s*"([^"]+)"\s*$', 'Multiline')
    foreach ($m in $matches) {
      $path = $m.Groups[1].Value -replace '\\\\','\'
      if (Test-Path $path) { $libs.Add($path) }
    }
  }
  if (-not $libs.Contains($root)) { $libs.Add($root) }
  return $libs
}

function Get-CSS-Dirs {
  $libs = Get-SteamLibraries
  foreach ($lib in $libs) {
    $acf = Join-Path $lib "steamapps\appmanifest_240.acf"
    if (Test-Path $acf) {
      $acfText = Get-Content -Path $acf -Raw
      $m = [regex]::Match($acfText, '"installdir"\s*"([^"]+)"')
      if ($m.Success) {
        $installdir = $m.Groups[1].Value
        $gameDir = Join-Path (Join-Path $lib "steamapps\common") $installdir
        $cstrike = Join-Path $gameDir "cstrike"
        $mapsDefault = Join-Path $cstrike "maps"
        $mapsDownload = Join-Path $cstrike "download\maps"
        return @{ Cstrike = $cstrike; MapsDefault = $mapsDefault; MapsDownload = $mapsDownload }
      }
    }
  }
  throw "Counter-Strike Source not found in any Steam library"
}

function Ensure-Dir { param($p) if (-not (Test-Path $p)) { New-Item -ItemType Directory -Path $p | Out-Null } }

# --- 7z helper ---
function Find-Or-Install7z {
  $candidates = @(
    "C:\Program Files\7-Zip\7z.exe",
    "C:\Program Files (x86)\7-Zip\7z.exe"
  )
  foreach ($c in $candidates) { if (Test-Path $c) { return $c } }
  $target = Join-Path $env:TEMP "7zr.exe"
  if (-not (Test-Path $target)) {
    Write-Host "Downloading portable 7zr.exe"
    Invoke-WebRequest -Uri $SevenZipUrl -OutFile $target -UseBasicParsing -ErrorAction Stop
  }
  return $target
}

function Extract-BZ2 { param($bz2Path,$destDir)
  if (-not (Test-Path $bz2Path)) { return $false }
  $seven = Find-Or-Install7z
  $outArg = "-o`"$destDir`""
  $args = @("e","-y",$outArg,"`"$bz2Path`"")
  $p = Start-Process -FilePath $seven -ArgumentList $args -NoNewWindow -PassThru -Wait
  return ($p.ExitCode -eq 0)
}

# --- Map list from Google Sheet ---
function Get-CustomMapsFromCsv { param($csvUrl)
  $tmp = New-TemporaryFile
  Invoke-WebRequest -Uri $csvUrl -OutFile $tmp -UseBasicParsing -ErrorAction Stop
  $raw = Get-Content -Path $tmp -Raw
  if ($raw -match '";"') { $delimiter = ';' } else { $delimiter = ',' }
  Add-Type -AssemblyName Microsoft.VisualBasic
  $parser = New-Object Microsoft.VisualBasic.FileIO.TextFieldParser($tmp)
  $parser.TextFieldType = [Microsoft.VisualBasic.FileIO.FieldType]::Delimited
  $parser.SetDelimiters($delimiter)
  $maps = [System.Collections.Generic.List[string]]::new()
  $header = $null
  if (-not $parser.EndOfData) { $header = $parser.ReadFields() }
  $bIndex = -1
  if ($header) {
    for ($i=0; $i -lt $header.Count; $i++) {
      if ($header[$i].Trim('" ') -ieq "MAPA") { $bIndex = $i; break }
    }
  }
  if ($bIndex -eq -1) { $bIndex = 1 }
  while (-not $parser.EndOfData) {
    $f = $parser.ReadFields()
    if (-not $f) { continue }
    if ($f.Count -le $bIndex) { continue }
    $name = $f[$bIndex].Trim().Trim('"')
    if (-not $name) { continue }
    if ($name.EndsWith(".bsp",[StringComparison]::OrdinalIgnoreCase)) {
      $name = $name.Substring(0,$name.Length-4)
    }
    if ($name) { $maps.Add($name) }
  }
  $parser.Close()
  Remove-Item $tmp -Force
  return $maps | Where-Object { $_ -ne "" } | Select-Object -Unique
}

# --- File I/O helpers ---
function Download-File { param($url,$dest)
  try {
    Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing -ErrorAction Stop
    $f = Get-Item $dest -ErrorAction SilentlyContinue
    return ($f -and $f.Length -gt 0)
  } catch { return $false }
}

function Map-Exists { param($mapName,$defaultDir,$downloadDir)
  $p1 = Join-Path $defaultDir ($mapName + ".bsp")
  $p2 = Join-Path $downloadDir ($mapName + ".bsp")
  return ((Test-Path $p1) -or (Test-Path $p2))
}

# --- Download logic ---
function Try-Download-Map { param($baseUrl,$mapName,$dirs)
  $downloadDir = $dirs.MapsDownload
  $defaultDir = $dirs.MapsDefault

  if (Map-Exists -mapName $mapName -defaultDir $defaultDir -downloadDir $downloadDir) {
    Write-Host "Skip. Already exists: $mapName.bsp"
    return $null
  }

  $bz2 = Join-Path $downloadDir ($mapName + ".bsp.bz2")
  $bsp = Join-Path $downloadDir ($mapName + ".bsp")

  if ($mapName.Contains('$')) {
    $url = $baseUrl + $mapName + ".bsp"
    Write-Host "Downloading $url"
    if (Download-File -url $url -dest $bsp) {
      Write-Host "OK $mapName.bsp (direct)"
      return @{ Kind = "bsp"; Path = $bsp }
    }
    Write-Host "Skip. Download failed for $mapName.bsp"
    return $null
  }

  $url1 = $baseUrl + $mapName + ".bsp.bz2"
  Write-Host "Downloading $url1"
  if (Download-File -url $url1 -dest $bz2) {
    return @{ Kind = "bz2"; Path = $bz2 }
  }

  $url2 = $baseUrl + $mapName + ".bsp"
  Write-Host "Downloading $url2"
  if (Download-File -url $url2 -dest $bsp) {
    Write-Host "OK $mapName.bsp (direct)"
    return @{ Kind = "bsp"; Path = $bsp }
  }

  Write-Host "Skip. Download failed for $mapName"
  return $null
}

function Place-Map { param($MapName,$Dirs)
  $result = Try-Download-Map -baseUrl $FastDL_URL -mapName $MapName -dirs $Dirs
  if ($null -eq $result) { return }
  if ($result.Kind -eq "bz2") {
    Write-Host "Extracting `"$($result.Path)`""
    if (-not (Extract-BZ2 -bz2Path $result.Path -destDir $Dirs.MapsDownload)) {
      Write-Host "Skip. Extract failed for $MapName.bsp.bz2"
      return
    }
    $bsp = Join-Path $Dirs.MapsDownload ($MapName + ".bsp")
    if (Test-Path $bsp) { Remove-Item $result.Path -Force -ErrorAction SilentlyContinue }
    Write-Host "OK $MapName.bsp"
  }
}

# --- Run ---
$dirs = Get-CSS-Dirs
Ensure-Dir $dirs.MapsDownload

$CustomMaps = Get-CustomMapsFromCsv -csvUrl $CsvUrl

foreach ($m in $CustomMaps) {
  Place-Map -MapName $m -Dirs $dirs
}

Write-Host "Map synchronization complete"
