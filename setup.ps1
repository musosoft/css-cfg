# setup.ps1

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Get-SteamRoot { param()
  $paths = @("HKLM:\SOFTWARE\Wow6432Node\Valve\Steam","HKLM:\SOFTWARE\Valve\Steam")
  foreach ($p in $paths) {
    try {
      $v = (Get-ItemProperty -Path $p -Name InstallPath -ErrorAction Stop).InstallPath
      if ($v -and (Test-Path $v)) { return $v }
    } catch {}
  }
  $envCandidates = @(${env:ProgramFiles(x86)},$env:ProgramFiles) | ForEach-Object { if ($_){ Join-Path $_ "Steam" } }
  foreach ($c in $envCandidates) { if (Test-Path $c) { return $c } }
  return $null
}

function Get-SteamLibraries { param()
  $root = Get-SteamRoot
  if (-not $root) { return @() }
  $vdf = Join-Path $root "steamapps\libraryfolders.vdf"
  $libs = [System.Collections.Generic.List[string]]::new()
  if (Test-Path $vdf) {
    $content = Get-Content -Path $vdf -Raw
    $m1 = [regex]::Matches($content,'^\s*"\d+"\s*"([^"]+)"\s*$','Multiline')
    foreach ($m in $m1) { $path = $m.Groups[1].Value -replace '\\\\','\'; if ((Test-Path $path) -and (-not $libs.Contains($path))) { $libs.Add($path) } }
    $m2 = [regex]::Matches($content,'"path"\s*"([^"]+)"','IgnoreCase')
    foreach ($m in $m2) { $path = $m.Groups[1].Value -replace '\\\\','\'; if ((Test-Path $path) -and (-not $libs.Contains($path))) { $libs.Add($path) } }
  }
  if (-not $libs.Contains($root)) { $libs.Add($root) }
  return $libs
}

function Get-CSS-Dirs { param()
  $libs = Get-SteamLibraries
  foreach ($lib in $libs) {
    $acf = Join-Path $lib "steamapps\appmanifest_240.acf"
    if (Test-Path $acf) {
      $acfText = Get-Content -Path $acf -Raw
      $m = [regex]::Match($acfText,'"installdir"\s*"([^"]+)"')
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
  return $null
}

function Ensure-Dir { param($path) if (-not (Test-Path $path)) { New-Item -ItemType Directory -Path $path | Out-Null } }
function Safe-Backup { param($path) if (Test-Path $path) { $stamp = Get-Date -Format "yyyyMMdd-HHmmss"; Copy-Item $path "$path.$stamp.bak" -Force } }

function Download-File { param($url,$dest)
  try {
    $ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) PowerShell"
    Invoke-WebRequest -Uri $url -OutFile $dest -UserAgent $ua -MaximumRedirection 5 -UseBasicParsing -ErrorAction Stop
    $f = Get-Item $dest -ErrorAction SilentlyContinue
    if ($f -and $f.Length -gt 0) { return $true } else { return $false }
  } catch { return $false }
}

# Prefer 7z/7za on PATH (including NanaZip), then Program Files, then bootstrap 7zr+7za
function Ensure-Extractor { param()
  $cmd = $null
  try { $cmd = Get-Command 7z -ErrorAction SilentlyContinue } catch {}
  if ($cmd -and (Test-Path $cmd.Source)) { return $cmd.Source }

  try { $cmd = Get-Command 7za -ErrorAction SilentlyContinue } catch {}
  if ($cmd -and (Test-Path $cmd.Source)) { return $cmd.Source }

  $candidates = @(
    "C:\Program Files\7-Zip\7z.exe",
    "C:\Program Files (x86)\7-Zip\7z.exe",
    "C:\Program Files\NanaZip\7z.exe",
    "C:\Program Files\NanaZip\NanaZip\7z.exe"
  )
  foreach ($c in $candidates) { if (Test-Path $c) { return $c } }

  # Bootstrap portable 7za.exe via 7zr.exe + 7z-extra
  $portableDir = Join-Path $env:TEMP "lamateam-7zip"
  $sevenExe = Join-Path $portableDir "7za.exe"
  if (Test-Path $sevenExe) { return $sevenExe }

  Ensure-Dir $portableDir
  $bootstrap = Join-Path $portableDir "7zr.exe"
  $extra7z   = Join-Path $portableDir "7z-extra.7z"
  if (-not (Test-Path $bootstrap)) { if (-not (Download-File -url "https://www.7-zip.org/a/7zr.exe" -dest $bootstrap)) { throw "Failed to fetch 7zr.exe" } }
  if (-not (Test-Path $extra7z)) { if (-not (Download-File -url "https://www.7-zip.org/a/7z2501-extra.7z" -dest $extra7z)) { throw "Failed to fetch 7z2501-extra.7z" } }
  $args = @("x","-y","-bso0","-bsp0","-bse0","-o`"$portableDir`"","`"$extra7z`"")
  $p = Start-Process -FilePath $bootstrap -ArgumentList $args -NoNewWindow -PassThru -Wait
  if ($p.ExitCode -ne 0) { throw "7zr failed to extract 7z extra package" }
  $found = Get-ChildItem -Path $portableDir -Filter "7za.exe" -Recurse | Select-Object -First 1
  if (-not $found) { throw "7za.exe not found after extraction" }
  return $found.FullName
}

function Test-BZip2Header { param($path)
  try {
    if (-not (Test-Path $path)) { return $false }
    $fs = [System.IO.File]::OpenRead($path)
    try {
      $b = New-Object byte[] 3
      $read = $fs.Read($b,0,3)
      if ($read -lt 3) { return $false }
      $s = [System.Text.Encoding]::ASCII.GetString($b)
      return ($s -eq "BZh")
    } finally { $fs.Dispose() }
  } catch { return $false }
}

function Extract-BZ2 { param($bz2Path,$destDir,$seven,$slotId)
  if (-not (Test-Path $bz2Path)) { return $false }
  $outArg = "-o`"$destDir`""
  $args = @("e","-y","-bd","-bso0","-bsp0","-bse0",$outArg,"`"$bz2Path`"")
  $proc = Start-Process -FilePath $seven -ArgumentList $args -NoNewWindow -PassThru
  $t = 0
  while (-not $proc.HasExited) {
    $t = ($t + 7) % 96
    Write-Progress -Id $slotId -Activity "extracting $(Split-Path $bz2Path -Leaf)" -Status "$t%" -PercentComplete $t
    Start-Sleep -Milliseconds 200
  }
  $proc.WaitForExit()
  Write-Progress -Id $slotId -Activity "extracting $(Split-Path $bz2Path -Leaf)" -Status "finalizing" -PercentComplete 97
  return ($proc.ExitCode -eq 0)
}

function Map-Exists { param($mapName,$defaultDir,$downloadDir)
  $p1 = Join-Path $defaultDir ($mapName + ".bsp")
  $p2 = Join-Path $downloadDir ($mapName + ".bsp")
  return ((Test-Path $p1) -or (Test-Path $p2))
}

function Get-CustomMapsFromCsv { param($csvUrl)
  $tmp = New-TemporaryFile
  Invoke-WebRequest -Uri $csvUrl -OutFile $tmp -UseBasicParsing -ErrorAction Stop
  $raw = Get-Content -Path $tmp -Raw
  $delimiter = if ($raw -match '";"') { ';' } else { ',' }
  Add-Type -AssemblyName Microsoft.VisualBasic
  $parser = New-Object Microsoft.VisualBasic.FileIO.TextFieldParser($tmp)
  $parser.TextFieldType = [Microsoft.VisualBasic.FileIO.FieldType]::Delimited
  $parser.SetDelimiters($delimiter)
  $maps = [System.Collections.Generic.List[string]]::new()
  $header = $null
  if (-not $parser.EndOfData) { $header = $parser.ReadFields() }
  $bIndex = -1
  if ($header) { for ($i = 0; $i -lt $header.Count; $i++) { if ($header[$i].Trim('" ') -ieq "MAPA") { $bIndex = $i; break } } }
  if ($bIndex -eq -1) { $bIndex = 1 }
  while (-not $parser.EndOfData) {
    $f = $parser.ReadFields()
    if (-not $f) { continue }
    if ($f.Count -le $bIndex) { continue }
    $name = $f[$bIndex].Trim().Trim('"')
    if (-not $name) { continue }
    if ($name.EndsWith(".bsp",[StringComparison]::OrdinalIgnoreCase)) { $name = $name.Substring(0,$name.Length-4) }
    if ($name) { $maps.Add($name) }
  }
  $parser.Close()
  Remove-Item $tmp -Force
  return $maps | Where-Object { $_ -ne "" } | Select-Object -Unique
}

function Require-Admin { param()
  $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  if (-not $isAdmin) { Write-Host "Run PowerShell as Administrator."; return $false }
  return $true
}

function Install-GameMenu { param($cstrikeDir,$url)
  $resDir = Join-Path $cstrikeDir "resource"
  Ensure-Dir $resDir
  $target = Join-Path $resDir "GameMenu.res"
  Safe-Backup -path $target
  if (Download-File -url $url -dest $target) { Write-Host "Installed GameMenu.res" } else { Write-Host "Failed to install GameMenu.res" }
}

function Install-Autoexec { param($cstrikeDir,$midHighUrl,$lowMidUrl)
  Write-Host ""
  Write-Host "Choose autoexec preset:"
  Write-Host "1) Mid-High PC"
  Write-Host "2) Low-Mid PC"
  $choice = Read-Host "Enter 1 or 2 (default 1)"
  if ([string]::IsNullOrWhiteSpace($choice)) { $choice = "1" }
  $cfgDir = Join-Path $cstrikeDir "cfg"
  Ensure-Dir $cfgDir
  $cfgPath = Join-Path $cfgDir "autoexec.cfg"
  Safe-Backup -path $cfgPath
  if ($choice -eq "2") {
    if (Download-File -url $lowMidUrl -dest $cfgPath) { Write-Host "Installed low-mid autoexec.cfg" } else { Write-Host "Failed to install autoexec.cfg" }
  } else {
    if (Download-File -url $midHighUrl -dest $cfgPath) { Write-Host "Installed mid-high autoexec.cfg" } else { Write-Host "Failed to install autoexec.cfg" }
  }
}

function New-MapDownloadJob { param($baseUrl,$mapName,$downloadDir)
  $scriptBlock = {
    param($baseUrl,$mapName,$downloadDir)
    $ErrorActionPreference = "Stop"
    $ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) PowerShell"
    $res = [pscustomobject]@{ Map=$mapName; Kind=$null; Path=$null; Success=$false }
    try {
      $bz2 = Join-Path $downloadDir ($mapName + ".bsp.bz2")
      $bsp = Join-Path $downloadDir ($mapName + ".bsp")
      $url1 = $baseUrl + $mapName + ".bsp.bz2"
      Invoke-WebRequest -Uri $url1 -OutFile $bz2 -UserAgent $ua -MaximumRedirection 5 -UseBasicParsing
      if ((Test-Path $bz2) -and ((Get-Item $bz2).Length -gt 0)) { $res.Kind = "bz2"; $res.Path = $bz2; $res.Success = $true; return $res }
      $url2 = $baseUrl + $mapName + ".bsp"
      Invoke-WebRequest -Uri $url2 -OutFile $bsp -UserAgent $ua -MaximumRedirection 5 -UseBasicParsing
      if ((Test-Path $bsp) -and ((Get-Item $bsp).Length -gt 0)) { $res.Kind = "bsp"; $res.Path = $bsp; $res.Success = $true; return $res }
      return $res
    } catch { return $res }
  }
  return Start-Job -ScriptBlock $scriptBlock -ArgumentList $baseUrl,$mapName,$downloadDir
}

function Extract-MapInline { param($map,$dirs,$fastdlUrl,$seven,$slotId)
  $bz2 = Join-Path $dirs.MapsDownload ($map + ".bsp.bz2")
  $bsp = Join-Path $dirs.MapsDownload ($map + ".bsp")
  Write-Progress -Id $slotId -Activity $map -Status "validating" -PercentComplete 5
  $valid = Test-BZip2Header -path $bz2
  if (-not $valid) {
    if (Test-Path $bz2) { Remove-Item $bz2 -Force -ErrorAction SilentlyContinue }
    $url1 = $fastdlUrl + $map + ".bsp.bz2"
    [void](Download-File -url $url1 -dest $bz2)
    $valid = Test-BZip2Header -path $bz2
  }
  if ($valid) {
    Write-Progress -Id $slotId -Activity $map -Status "extracting" -PercentComplete 40
    $ok = Extract-BZ2 -bz2Path $bz2 -destDir $dirs.MapsDownload -seven $seven -slotId $slotId
    if ($ok) {
      if (Test-Path $bsp) { Remove-Item $bz2 -Force -ErrorAction SilentlyContinue }
      Write-Progress -Id $slotId -Activity $map -Status "done" -PercentComplete 100
      Write-Progress -Id $slotId -Completed -Activity $map
      return
    }
  }
  if (Test-Path $bz2) { Remove-Item $bz2 -Force -ErrorAction SilentlyContinue }
  $fallback = $fastdlUrl + $map + ".bsp"
  Write-Progress -Id $slotId -Activity $map -Status "fallback .bsp" -PercentComplete 60
  [void](Download-File -url $fallback -dest $bsp)
  Write-Progress -Id $slotId -Activity $map -Status "done" -PercentComplete 100
  Write-Progress -Id $slotId -Completed -Activity $map
}

function Read-YesDefault { param($prompt)
  $r = Read-Host $prompt
  if ([string]::IsNullOrWhiteSpace($r)) { return $true }
  return ($r -match '^[Yy]')
}

function Sync-Maps { param($dirs,$csvUrl,$fastdlUrl)
  Ensure-Dir $dirs.MapsDownload
  $maps = Get-CustomMapsFromCsv -csvUrl $csvUrl
  if (-not $maps -or $maps.Count -eq 0) { Write-Host "No maps found in list."; return }

  $queue = New-Object System.Collections.Generic.List[string]
  foreach ($m in $maps) { if (-not (Map-Exists -mapName $m -defaultDir $dirs.MapsDefault -downloadDir $dirs.MapsDownload)) { $queue.Add($m) } }
  if ($queue.Count -eq 0) { Write-Host "All maps already present."; return }

  $seven = Ensure-Extractor
  $throttle = 8
  $total = $queue.Count
  $nextIndex = 0
  $completed = 0
  $running = @()
  $slotBusy = @{}
  $jobToSlot = @{}
  $jobToMap  = @{}

  Write-Progress -Id 0 -Activity "Downloading maps" -Status "0 of $total" -PercentComplete 0

  function Acquire-Slot { for ($s=1; $s -le $throttle; $s++) { if (-not $slotBusy.ContainsKey($s)) { return $s } } return $null }
  function Update-ActiveBars {
    foreach ($j in $running) {
      $sid = $jobToSlot[$j.Id]
      $map = $jobToMap[$j.Id]
      $bz2 = Join-Path $dirs.MapsDownload ($map + ".bsp.bz2")
      $bsp = Join-Path $dirs.MapsDownload ($map + ".bsp")
      $path = if (Test-Path $bz2) { $bz2 } elseif (Test-Path $bsp) { $bsp } else { $null }
      if ($path) {
        $size = (Get-Item $path -ErrorAction SilentlyContinue).Length
        $mb = [Math]::Round($size/1MB,2)
        $pct = [int]([Math]::Min(99,[Math]::Max(1, $mb * 5)))
        Write-Progress -Id $sid -ParentId 0 -Activity $map -Status "$mb MB" -PercentComplete $pct
      } else {
        Write-Progress -Id $sid -ParentId 0 -Activity $map -Status "starting..." -PercentComplete 1
      }
    }
  }

  while ($completed -lt $total) {
    while (($running.Count -lt $throttle) -and ($nextIndex -lt $total)) {
      $map = $queue[$nextIndex]
      $slot = Acquire-Slot
      if ($null -eq $slot) { break }

      $bspExisting = Join-Path $dirs.MapsDownload ($map + ".bsp")
      $bz2Existing = Join-Path $dirs.MapsDownload ($map + ".bsp.bz2")

      if (Test-Path $bspExisting) {
        $completed++
        Write-Progress -Id $slot -ParentId 0 -Activity $map -Status "exists" -PercentComplete 100
        Write-Progress -Id $slot -Completed -Activity $map
        $pctAll = [int](($completed / $total) * 100)
        Write-Progress -Id 0 -Activity "Downloading maps" -Status "$completed of $total (last: $map)" -PercentComplete $pctAll
        $nextIndex++
        continue
      }

      if (Test-Path $bz2Existing) {
        $slotBusy[$slot] = $true
        Write-Progress -Id $slot -ParentId 0 -Activity $map -Status "extracting" -PercentComplete 25
        Extract-MapInline -map $map -dirs $dirs -fastdlUrl $fastdlUrl -seven $seven -slotId $slot
        $completed++
        $slotBusy.Remove($slot) | Out-Null
        $pctAll = [int](($completed / $total) * 100)
        Write-Progress -Id 0 -Activity "Downloading maps" -Status "$completed of $total (last: $map)" -PercentComplete $pctAll
        $nextIndex++
        continue
      }

      $job = New-MapDownloadJob -baseUrl $fastdlUrl -mapName $map -downloadDir $dirs.MapsDownload
      $running += $job
      $slotBusy[$slot] = $true
      $jobToSlot[$job.Id] = $slot
      $jobToMap[$job.Id]  = $map
      Write-Progress -Id $slot -ParentId 0 -Activity $map -Status "queued" -PercentComplete 0
      $nextIndex++
    }

    $done = Wait-Job -Job $running -Any -Timeout 1
    if ($done) {
      $map  = $jobToMap[$done.Id]
      $slot = $jobToSlot[$done.Id]
      $out  = Receive-Job -Job $done -ErrorAction SilentlyContinue
      Remove-Job -Job $done -Force
      $running = $running | Where-Object { $_.Id -ne $done.Id }
      $jobToMap.Remove($done.Id) | Out-Null
      $jobToSlot.Remove($done.Id) | Out-Null

      if ($out -and $out.Kind -eq "bz2") {
        Write-Progress -Id $slot -ParentId 0 -Activity $map -Status "extracting" -PercentComplete 25
        Extract-MapInline -map $map -dirs $dirs -fastdlUrl $fastdlUrl -seven $seven -slotId $slot
      } else {
        Write-Progress -Id $slot -ParentId 0 -Activity $map -Status "done" -PercentComplete 100
        Write-Progress -Id $slot -Completed -Activity $map
      }

      $completed++
      $slotBusy.Remove($slot) | Out-Null
      $pctAll = [int](($completed / $total) * 100)
      Write-Progress -Id 0 -Activity "Downloading maps" -Status "$completed of $total (last: $map)" -PercentComplete $pctAll
    } else {
      Update-ActiveBars
    }
  }

  Write-Progress -Id 0 -Completed -Activity "Downloading maps"
  Write-Host "Map synchronization complete"
}

function Install-Wizard { param($dirs,$csvUrl,$fastdlUrl,$gamemenuUrl,$autoexecMidHighUrl,$autoexecLowMidUrl)
  Write-Host ""
  Write-Host "LamaTeam setup wizard"
  Write-Host "Detected: $($dirs.Cstrike)"
  Write-Host ""
  $doMaps = Read-YesDefault "Download LamaTeam maps? [Y/n]"
  $doMenu = Read-YesDefault "Add LamaTeam to game menu? [Y/n]"
  $doCfg  = Read-YesDefault "Install autoexec.cfg? [Y/n]"
  if ($doMaps) { Sync-Maps -dirs $dirs -csvUrl $csvUrl -fastdlUrl $fastdlUrl }
  if ($doMenu) { Install-GameMenu -cstrikeDir $dirs.Cstrike -url $gamemenuUrl }
  if ($doCfg)  { Install-Autoexec -cstrikeDir $dirs.Cstrike -midHighUrl $autoexecMidHighUrl -lowMidUrl $autoexecLowMidUrl }
  Write-Host ""
  Write-Host "Done."
}

if (-not (Require-Admin)) { return }

$fastdlUrl = "http://gocasa1.fakaheda.eu/fastdl/27516/maps/"
$csvUrl = "https://docs.google.com/spreadsheets/d/e/2PACX-1vTufS4N6N-30qHu47IuYFnR8CqjM9iTTWQLQ9d4w0SxpmdI984EcnbG8D4ZAerbtKzuxtTHAlHrZpHQ/pub?output=csv"
$gamemenuUrl = "https://raw.githubusercontent.com/musosoft/css-cfg/main/gamemenu.res"
$autoexecMidHighUrl = "https://raw.githubusercontent.com/musosoft/css-cfg/main/autoexec.cfg"
$autoexecLowMidUrl  = "https://raw.githubusercontent.com/musosoft/css-cfg/master/autoexec.cfg"

$dirs = Get-CSS-Dirs
if (-not $dirs) { Write-Host "Counter-Strike: Source not found."; return }

Install-Wizard -dirs $dirs -csvUrl $csvUrl -fastdlUrl $fastdlUrl -gamemenuUrl $gamemenuUrl -autoexecMidHighUrl $autoexecMidHighUrl -autoexecLowMidUrl $autoexecLowMidUrl
