param([switch]$GamingMode)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic

[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:ServerAddress = '82.208.17.101:27516'
$script:ConfigPath = Join-Path $env:APPDATA 'LamaTeamSetup.json'
$script:SuspendConfigSave = $false
$script:FastDlUrl = 'http://gocasa1.fakaheda.eu/fastdl/27516/maps/'
$script:CsvUrl = 'https://docs.google.com/spreadsheets/d/e/2PACX-1vTufS4N6N-30qHu47IuYFnR8CqjM9iTTWQLQ9d4w0SxpmdI984EcnbG8D4ZAerbtKzuxtTHAlHrZpHQ/pub?output=csv'
$script:RemoteAssets = @{
    Autoexec = 'https://raw.githubusercontent.com/musosoft/css-cfg/main/autoexec.cfg'
    GameMenu = 'https://raw.githubusercontent.com/musosoft/css-cfg/main/gamemenu.res'
    Setup = 'https://raw.githubusercontent.com/musosoft/css-cfg/main/setup.ps1'
}

$script:ScriptRoot = if ($PSCommandPath) {
    Split-Path -Path $PSCommandPath -Parent
}
elseif ($MyInvocation.MyCommand.Path) {
    Split-Path -Path $MyInvocation.MyCommand.Path -Parent
}
else {
    $null
}

$script:Theme = @{
    Background = [System.Drawing.Color]::FromArgb(15, 22, 31)
    Panel = [System.Drawing.Color]::FromArgb(25, 34, 46)
    Surface = [System.Drawing.Color]::FromArgb(33, 44, 58)
    SurfaceAlt = [System.Drawing.Color]::FromArgb(40, 53, 69)
    Accent = [System.Drawing.Color]::FromArgb(0, 173, 181)
    AccentMuted = [System.Drawing.Color]::FromArgb(17, 76, 90)
    Foreground = [System.Drawing.Color]::FromArgb(238, 244, 248)
    Muted = [System.Drawing.Color]::FromArgb(162, 176, 189)
    Warning = [System.Drawing.Color]::FromArgb(245, 158, 11)
    Danger = [System.Drawing.Color]::FromArgb(220, 38, 38)
}

$script:GmConfigPath = Join-Path $env:APPDATA 'LamaTeamGamingMode.json'
$script:GmSessionPath = Join-Path $env:APPDATA 'LamaTeamGamingMode.session.json'
$script:GmSystemRoots = @(
    $env:WINDIR,
    (Join-Path $env:ProgramFiles 'WindowsApps')
) | Where-Object { $_ -and (Test-Path $_) }
$script:GmBaseProtected = @(
    'hl2','counter-strike','cs2','steam','steamservice','steamwebhelper','gameoverlayui','powershell','pwsh','cmd','conhost',
    'taskmgr','explorer','msmpeng','nissrv','securityhealthservice','searchhost','searchindexer','dwm','audiodg','sihost',
    'services','svchost','lsass','wininit','winlogon','csrss','smss','idle','system','registry','memory compression','wmiprvse'
)
$script:GmRecommendedProcesses = @('chrome','msedge','firefox','opera','brave','discord','teams','zoom','slack','telegram','whatsapp','onedrive','epicgameslauncher','epicwebhelper','riotclient','eadesktop','origin','ubisoftconnect','battle.net','agent','spotify','obs','overwolf','adobe','creative cloud','lghub','razer','corsair','icue','rustdesk','nordvpn-service','nordupdaterservice','deskflow','spacedeskservice')
$script:GmRecommendedServices = @('adobe','update','updater','edgeupdate','google','onedrive','teams','ubisoft','ea','epic','discord','corsair','razer','lghub','teamviewer','rustdesk','nordvpn','nordsec','deskflow','spacedesk')
$script:GmRecommendedTasks = @('adobe','google','edgeupdate','onedrive','teams','discord','opera','brave','dropbox','epic','ubisoft','ea','nvidia','powertoys','sophia')

function Test-EnvFlag {
    param([string]$Name)

    $value = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $false
    }

    return ($value.Trim().ToLowerInvariant() -notin @('0', 'false', 'no', 'off'))
}

$script:PreviewMode = Test-EnvFlag -Name 'LAMA_TEAM_PREVIEW'
$script:AutoInstallPreview = Test-EnvFlag -Name 'LAMA_TEAM_TEST_AUTO_INSTALL'
$script:IsBusy = $false
$script:GmScanInitialized = $false
$script:SetupForm = $null
$script:AutoCloseAfterSeconds = 0
$autoCloseValue = [Environment]::GetEnvironmentVariable('LAMA_TEAM_TEST_AUTO_CLOSE_SECONDS')
if ($autoCloseValue) {
    $parsedAutoClose = 0
    if ([int]::TryParse($autoCloseValue, [ref]$parsedAutoClose)) {
        $script:AutoCloseAfterSeconds = [math]::Max(0, $parsedAutoClose)
    }
}

function Test-IsAdministrator {
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Ensure-Administrator {
    if ($script:PreviewMode) {
        return $true
    }

    if (Test-IsAdministrator) {
        return $true
    }

    if (-not $script:PreviewMode) {
        if ($PSCommandPath -and (Test-Path $PSCommandPath)) {
            Start-Process -FilePath 'powershell.exe' -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs | Out-Null
        }
        else {
            [System.Windows.Forms.MessageBox]::Show(
                'Open PowerShell as Administrator and run the setup command again.',
                'LamaTeam Setup',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            ) | Out-Null
        }
    }

    return $false
}

function Ensure-Dir {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }
}

function Backup-File {
    param([string]$Path)

    if (Test-Path $Path) {
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        Copy-Item -Path $Path -Destination ("{0}.{1}.bak" -f $Path, $stamp) -Force
    }
}

function Read-JsonFile {
    param(
        [string]$Path,
        [hashtable]$Defaults
    )

    if (-not (Test-Path $Path)) {
        return $Defaults
    }

    try {
        $raw = Get-Content -Path $Path -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return $Defaults
        }

        return ($raw | ConvertFrom-Json -ErrorAction Stop)
    }
    catch {
        return $Defaults
    }
}

function Save-JsonFile {
    param(
        [string]$Path,
        [hashtable]$Data
    )

    $directory = Split-Path -Path $Path -Parent
    if ($directory -and -not (Test-Path $directory)) {
        New-Item -Path $directory -ItemType Directory -Force | Out-Null
    }

    try {
        $Data | ConvertTo-Json -Depth 6 | Set-Content -Path $Path -Encoding UTF8 -ErrorAction Stop
    }
    catch {
    }
}

function ConvertTo-StringArray {
    param($Value)
    if ($null -eq $Value) { return @() }
    if ($Value -is [string]) {
        if ([string]::IsNullOrWhiteSpace($Value)) { return @() }
        return @($Value)
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $values = @()
        foreach ($item in $Value) {
            if ($null -ne $item -and -not [string]::IsNullOrWhiteSpace([string]$item)) { $values += [string]$item }
        }
        return @($values)
    }
    return @([string]$Value)
}

function Get-DefaultSetupConfig {
    return @{
        InstallAutoexec = $true
        InstallMenu = $true
        InstallMaps = $true
        InstallGamingMode = $true
        ConnectAfter = $false
        LastGameRoot = $null
    }
}

function Normalize-SetupConfig {
    $defaults = Get-DefaultSetupConfig
    $data = Read-JsonFile -Path $script:ConfigPath -Defaults $defaults

    return @{
        InstallAutoexec = if ($null -ne $data.InstallAutoexec) { [bool]$data.InstallAutoexec } else { $defaults.InstallAutoexec }
        InstallMenu = if ($null -ne $data.InstallMenu) { [bool]$data.InstallMenu } else { $defaults.InstallMenu }
        InstallMaps = if ($null -ne $data.InstallMaps) { [bool]$data.InstallMaps } else { $defaults.InstallMaps }
        InstallGamingMode = if ($null -ne $data.InstallGamingMode) { [bool]$data.InstallGamingMode } else { $defaults.InstallGamingMode }
        ConnectAfter = if ($null -ne $data.ConnectAfter) { [bool]$data.ConnectAfter } else { $defaults.ConnectAfter }
        LastGameRoot = if ($data.LastGameRoot) { [string]$data.LastGameRoot } else { $null }
    }
}

function Save-SetupConfig {
    if ($script:SuspendConfigSave) {
        return
    }

    $data = @{
        InstallAutoexec = if ($script:chkAutoexec) { [bool]$script:chkAutoexec.Checked } else { $script:Config.InstallAutoexec }
        InstallMenu = if ($script:chkMenu) { [bool]$script:chkMenu.Checked } else { $script:Config.InstallMenu }
        InstallMaps = if ($script:chkMaps) { [bool]$script:chkMaps.Checked } else { $script:Config.InstallMaps }
        InstallGamingMode = if ($script:chkGamingMode) { [bool]$script:chkGamingMode.Checked } else { $script:Config.InstallGamingMode }
        ConnectAfter = if ($script:chkConnectAfter) { [bool]$script:chkConnectAfter.Checked } else { $script:Config.ConnectAfter }
        LastGameRoot = if ($script:DetectedDirs) { $script:DetectedDirs.GameRoot } else { $script:Config.LastGameRoot }
    }

    $script:Config = $data
    Save-JsonFile -Path $script:ConfigPath -Data $script:Config
}

function Get-LocalAssetPath {
    param([string]$FileName)

    if (-not $script:ScriptRoot) {
        return $null
    }

    $path = Join-Path -Path $script:ScriptRoot -ChildPath $FileName
    if (Test-Path $path) {
        return $path
    }

    return $null
}

function Download-File {
    param(
        [string]$Url,
        [string]$Destination
    )

    try {
        Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing -MaximumRedirection 5 -ErrorAction Stop
        $file = Get-Item -Path $Destination -ErrorAction SilentlyContinue
        return ($file -and $file.Length -gt 0)
    }
    catch {
        return $false
    }
}

function Copy-Or-DownloadAsset {
    param(
        [string]$LocalName,
        [string]$RemoteUrl,
        [string]$Destination
    )

    $local = Get-LocalAssetPath -FileName $LocalName
    if ($local) {
        Copy-Item -Path $local -Destination $Destination -Force
        return $true
    }

    return (Download-File -Url $RemoteUrl -Destination $Destination)
}

function Get-SteamRoot {
    $keys = @(
        'HKLM:\SOFTWARE\Wow6432Node\Valve\Steam',
        'HKLM:\SOFTWARE\Valve\Steam'
    )

    foreach ($key in $keys) {
        try {
            $path = (Get-ItemProperty -Path $key -Name InstallPath -ErrorAction Stop).InstallPath
            if ($path -and (Test-Path $path)) {
                return $path
            }
        }
        catch {
        }
    }

    foreach ($base in @(${env:ProgramFiles(x86)}, $env:ProgramFiles)) {
        if (-not $base) {
            continue
        }

        $candidate = Join-Path -Path $base -ChildPath 'Steam'
        if (Test-Path $candidate) {
            return $candidate
        }
    }

    return $null
}

function Get-SteamLibraries {
    $root = Get-SteamRoot
    if (-not $root) {
        return @()
    }

    $libraries = New-Object System.Collections.Generic.List[string]
    $vdf = Join-Path -Path $root -ChildPath 'steamapps\libraryfolders.vdf'

    if (Test-Path $vdf) {
        $content = Get-Content -Path $vdf -Raw
        foreach ($match in [regex]::Matches($content, '^\s*"\d+"\s*"([^"]+)"\s*$', 'Multiline')) {
            $path = $match.Groups[1].Value -replace '\\\\', '\'
            if ((Test-Path $path) -and (-not $libraries.Contains($path))) {
                [void]$libraries.Add($path)
            }
        }

        foreach ($match in [regex]::Matches($content, '"path"\s*"([^"]+)"', 'IgnoreCase')) {
            $path = $match.Groups[1].Value -replace '\\\\', '\'
            if ((Test-Path $path) -and (-not $libraries.Contains($path))) {
                [void]$libraries.Add($path)
            }
        }
    }

    if (-not $libraries.Contains($root)) {
        [void]$libraries.Add($root)
    }

    return @($libraries)
}

function Resolve-CSSDirsFromPath {
    param([string]$BasePath)

    if ([string]::IsNullOrWhiteSpace($BasePath) -or -not (Test-Path $BasePath)) {
        return $null
    }

    $normalized = (Resolve-Path -Path $BasePath).Path
    $leaf = Split-Path -Path $normalized -Leaf

    if ($leaf -ieq 'cstrike') {
        $gameRoot = Split-Path -Path $normalized -Parent
        $cstrike = $normalized
    }
    elseif (Test-Path (Join-Path -Path $normalized -ChildPath 'cstrike')) {
        $gameRoot = $normalized
        $cstrike = Join-Path -Path $normalized -ChildPath 'cstrike'
    }
    else {
        return $null
    }

    return @{
        GameRoot = $gameRoot
        Cstrike = $cstrike
        MapsDefault = Join-Path -Path $cstrike -ChildPath 'maps'
        MapsDownload = Join-Path -Path $cstrike -ChildPath 'download\maps'
    }
}

function Get-CSSDirs {
    $overrideRoot = [Environment]::GetEnvironmentVariable('LAMA_TEAM_TEST_GAME_ROOT')
    if ($overrideRoot) {
        $override = Resolve-CSSDirsFromPath -BasePath $overrideRoot
        if ($override) {
            return $override
        }
    }

    foreach ($library in (Get-SteamLibraries)) {
        $manifest = Join-Path -Path $library -ChildPath 'steamapps\appmanifest_240.acf'
        if (Test-Path $manifest) {
            $manifestText = Get-Content -Path $manifest -Raw
            $match = [regex]::Match($manifestText, '"installdir"\s*"([^"]+)"')
            if ($match.Success) {
                $installDir = Join-Path -Path (Join-Path -Path $library -ChildPath 'steamapps\common') -ChildPath $match.Groups[1].Value
                $resolved = Resolve-CSSDirsFromPath -BasePath $installDir
                if ($resolved) {
                    return $resolved
                }
            }
        }

        foreach ($name in @('Counter-Strike Source', 'Counter-Strike: Source')) {
            $candidate = Join-Path -Path (Join-Path -Path $library -ChildPath 'steamapps\common') -ChildPath $name
            $resolved = Resolve-CSSDirsFromPath -BasePath $candidate
            if ($resolved) {
                return $resolved
            }
        }
    }

    return $null
}

function Ensure-Extractor {
    $commands = @('7z', '7za')
    foreach ($commandName in $commands) {
        try {
            $command = Get-Command $commandName -ErrorAction SilentlyContinue
            if ($command -and (Test-Path $command.Source)) {
                return $command.Source
            }
        }
        catch {
        }
    }

    foreach ($candidate in @(
        'C:\Program Files\7-Zip\7z.exe',
        'C:\Program Files (x86)\7-Zip\7z.exe',
        'C:\Program Files\NanaZip\7z.exe',
        'C:\Program Files\NanaZip\NanaZip\7z.exe'
    )) {
        if (Test-Path $candidate) {
            return $candidate
        }
    }

    $portableDir = Join-Path -Path $env:TEMP -ChildPath 'lamateam-7zip'
    $bootstrap = Join-Path -Path $portableDir -ChildPath '7zr.exe'
    $extraArchive = Join-Path -Path $portableDir -ChildPath '7z-extra.7z'
    $portableExe = Join-Path -Path $portableDir -ChildPath '7za.exe'

    if (Test-Path $portableExe) {
        return $portableExe
    }

    Ensure-Dir -Path $portableDir

    if (-not (Test-Path $bootstrap)) {
        if (-not (Download-File -Url 'https://www.7-zip.org/a/7zr.exe' -Destination $bootstrap)) {
            throw 'Unable to download 7zr.exe.'
        }
    }

    if (-not (Test-Path $extraArchive)) {
        if (-not (Download-File -Url 'https://www.7-zip.org/a/7z2501-extra.7z' -Destination $extraArchive)) {
            throw 'Unable to download the 7-Zip extra package.'
        }
    }

    & $bootstrap 'x' '-y' ("-o{0}" -f $portableDir) $extraArchive 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $portableExe)) {
        throw 'Portable 7-Zip bootstrap failed.'
    }

    return $portableExe
}

function Test-BZip2Header {
    param([string]$Path)

    try {
        if (-not (Test-Path $Path)) {
            return $false
        }

        $stream = [System.IO.File]::OpenRead($Path)
        try {
            $header = New-Object byte[] 3
            $read = $stream.Read($header, 0, 3)
            if ($read -lt 3) {
                return $false
            }

            return ([System.Text.Encoding]::ASCII.GetString($header) -eq 'BZh')
        }
        finally {
            $stream.Dispose()
        }
    }
    catch {
        return $false
    }
}

function Expand-BZip2File {
    param(
        [string]$ArchivePath,
        [string]$DestinationDirectory,
        [string]$ExtractorPath
    )

    if (-not (Test-Path $ArchivePath)) {
        return $false
    }

    try {
        & $ExtractorPath 'e' '-y' ("-o{0}" -f $DestinationDirectory) $ArchivePath 2>$null | Out-Null
        return ($LASTEXITCODE -eq 0)
    }
    catch {
        return $false
    }
}

function Map-Exists {
    param(
        [string]$MapName,
        [hashtable]$Dirs
    )

    $defaultMap = Join-Path -Path $Dirs.MapsDefault -ChildPath ($MapName + '.bsp')
    $downloadMap = Join-Path -Path $Dirs.MapsDownload -ChildPath ($MapName + '.bsp')
    return ((Test-Path $defaultMap) -or (Test-Path $downloadMap))
}

function Get-CustomMapsFromCsv {
    $temp = [System.IO.Path]::GetTempFileName()

    try {
        Invoke-WebRequest -Uri $script:CsvUrl -OutFile $temp -UseBasicParsing -ErrorAction Stop
        $raw = Get-Content -Path $temp -Raw
        $delimiter = if ($raw -match '";"') { ';' } else { ',' }

        $parser = New-Object Microsoft.VisualBasic.FileIO.TextFieldParser($temp)
        $parser.TextFieldType = [Microsoft.VisualBasic.FileIO.FieldType]::Delimited
        $parser.SetDelimiters($delimiter)

        $header = if (-not $parser.EndOfData) { $parser.ReadFields() } else { @() }
        $mapColumn = 1
        for ($i = 0; $i -lt $header.Count; $i++) {
            if ($header[$i].Trim('" ') -ieq 'MAPA') {
                $mapColumn = $i
                break
            }
        }

        $maps = New-Object System.Collections.Generic.List[string]
        while (-not $parser.EndOfData) {
            $fields = $parser.ReadFields()
            if (-not $fields -or $fields.Count -le $mapColumn) {
                continue
            }

            $name = $fields[$mapColumn].Trim().Trim('"')
            if ([string]::IsNullOrWhiteSpace($name)) {
                continue
            }

            if ($name.EndsWith('.bsp', [System.StringComparison]::OrdinalIgnoreCase)) {
                $name = $name.Substring(0, $name.Length - 4)
            }

            if ($name -and (-not $maps.Contains($name))) {
                [void]$maps.Add($name)
            }
        }

        $parser.Close()
        return @($maps)
    }
    finally {
        Remove-Item -Path $temp -Force -ErrorAction SilentlyContinue
    }
}

function Install-GameMenu {
    param([hashtable]$Dirs)

    $resourceDir = Join-Path -Path $Dirs.Cstrike -ChildPath 'custom\lamateam\resource'
    Ensure-Dir -Path $resourceDir

    $target = Join-Path -Path $resourceDir -ChildPath 'GameMenu.res'
    Backup-File -Path $target

    return (Copy-Or-DownloadAsset -LocalName 'gamemenu.res' -RemoteUrl $script:RemoteAssets.GameMenu -Destination $target)
}

function Install-Autoexec {
    param([hashtable]$Dirs)

    $configDir = Join-Path -Path $Dirs.Cstrike -ChildPath 'cfg'
    Ensure-Dir -Path $configDir

    $target = Join-Path -Path $configDir -ChildPath 'autoexec.cfg'
    Backup-File -Path $target

    return (Copy-Or-DownloadAsset -LocalName 'autoexec.cfg' -RemoteUrl $script:RemoteAssets.Autoexec -Destination $target)
}

function Install-GamingMode {
    $destination = Join-Path -Path ([Environment]::GetFolderPath('Desktop')) -ChildPath 'LamaTeam-Setup.lnk'
    
    if ($PSCommandPath -and (Test-Path $PSCommandPath)) {
        $wshShell = New-Object -ComObject WScript.Shell
        $shortcut = $wshShell.CreateShortcut($destination)
        $shortcut.TargetPath = 'powershell.exe'
        $shortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -GamingMode"
        $shortcut.IconLocation = "$env:SystemRoot\System32\imageres.dll,15"
        $shortcut.WindowStyle = 1
        $shortcut.Save()
        return $true
    }
    
    return (Download-File -Url $script:RemoteAssets.Setup -Destination (Join-Path -Path ([Environment]::GetFolderPath('Desktop')) -ChildPath 'LamaTeam-Setup.ps1'))
}

function Sync-Maps {
    param(
        [hashtable]$Dirs,
        [scriptblock]$ProgressCallback
    )

    Ensure-Dir -Path $Dirs.MapsDownload

    $maps = Get-CustomMapsFromCsv
    if (-not $maps -or $maps.Count -eq 0) {
        throw 'The map list is empty or unavailable.'
    }

    $missing = @($maps | Where-Object { -not (Map-Exists -MapName $_ -Dirs $Dirs) })
    if ($missing.Count -eq 0) {
        Invoke-SetupProgressCallback -ProgressCallback $ProgressCallback -Percent 100 -Status 'All LamaTeam maps are already installed.'
        return @{ Downloaded = 0; Failed = 0 }
    }

    $extractor = Ensure-Extractor
    $downloaded = 0
    $failed = 0

    for ($index = 0; $index -lt $missing.Count; $index++) {
        $map = $missing[$index]
        $percent = [int](($index / [math]::Max(1, $missing.Count)) * 100)
        Invoke-SetupProgressCallback -ProgressCallback $ProgressCallback -Percent $percent -Status ("Map {0} of {1}: {2}" -f ($index + 1), $missing.Count, $map)
        Write-SetupLog -Message ("Syncing map {0}/{1}: {2}" -f ($index + 1), $missing.Count, $map)

        $archivePath = Join-Path -Path $Dirs.MapsDownload -ChildPath ($map + '.bsp.bz2')
        $mapPath = Join-Path -Path $Dirs.MapsDownload -ChildPath ($map + '.bsp')

        Remove-Item -Path $archivePath -Force -ErrorAction SilentlyContinue
        Remove-Item -Path $mapPath -Force -ErrorAction SilentlyContinue

        $archiveUrl = $script:FastDlUrl + $map + '.bsp.bz2'
        $mapUrl = $script:FastDlUrl + $map + '.bsp'

        try {
            $archiveOk = Download-File -Url $archiveUrl -Destination $archivePath
            if ($archiveOk -and (Test-BZip2Header -Path $archivePath) -and (Expand-BZip2File -ArchivePath $archivePath -DestinationDirectory $Dirs.MapsDownload -ExtractorPath $extractor) -and (Test-Path $mapPath)) {
                Remove-Item -Path $archivePath -Force -ErrorAction SilentlyContinue
                $downloaded++
                Write-SetupLog -Message ("Installed map: {0}" -f $map)
                continue
            }

            Remove-Item -Path $archivePath -Force -ErrorAction SilentlyContinue

            if ((Download-File -Url $mapUrl -Destination $mapPath) -and (Test-Path $mapPath)) {
                $downloaded++
                Write-SetupLog -Message ("Installed map: {0}" -f $map)
            }
            else {
                $failed++
                Remove-Item -Path $mapPath -Force -ErrorAction SilentlyContinue
                Write-SetupLog -Message ("Failed to install map: {0}" -f $map) -Color $script:Theme.Warning
            }
        }
        catch {
            $failed++
            Remove-Item -Path $archivePath -Force -ErrorAction SilentlyContinue
            Remove-Item -Path $mapPath -Force -ErrorAction SilentlyContinue
            Write-SetupLog -Message ("Map sync error for {0}: {1}" -f $map, $_.Exception.Message) -Color $script:Theme.Warning
        }
    }

    Invoke-SetupProgressCallback -ProgressCallback $ProgressCallback -Percent 100 -Status ('Map sync finished. Downloaded: {0}, failed: {1}.' -f $downloaded, $failed)
    return @{ Downloaded = $downloaded; Failed = $failed }
}

function Invoke-SetupProgressCallback {
    param(
        [scriptblock]$ProgressCallback,
        [int]$Percent,
        [string]$Status
    )

    if (-not $ProgressCallback) {
        return
    }

    try {
        & $ProgressCallback $Percent $Status
    }
    catch {
    }
}

function Test-UiControl {
    param([System.Windows.Forms.Control]$Control)

    return ($Control -and -not $Control.IsDisposed)
}

function Refresh-SetupUi {
    foreach ($control in @($script:lblStatus, $script:progressBar, $script:txtLog, $script:SetupForm)) {
        if (Test-UiControl -Control $control) {
            $control.Refresh()
            $control.Update()
        }
    }
}

function Set-SetupBusyState {
    param([bool]$Busy)

    $script:IsBusy = $Busy

    foreach ($button in @($script:btnInstall, $script:btnDetect, $script:btnBrowse, $script:btnConnect, $script:btnClose)) {
        if ($button) {
            $button.Enabled = -not $Busy
        }
    }

    if (Test-UiControl -Control $script:SetupForm) {
        $script:SetupForm.UseWaitCursor = $Busy
    }

    Refresh-SetupUi
}

function Run-Installer {
    param([hashtable]$Dirs)

    Save-SetupConfig

    $selected = @(
        if ($script:chkMaps.Checked) { 'Maps' }
        if ($script:chkMenu.Checked) { 'Menu' }
        if ($script:chkAutoexec.Checked) { 'Autoexec' }
        if ($script:chkGamingMode.Checked) { 'GamingMode' }
    )

    if ($selected.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show(
            'Select at least one install action.',
            'LamaTeam Setup',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
        return
    }

    Set-SetupBusyState -Busy $true

    try {
        Write-SetupLog -Message ('Installing into {0}' -f $Dirs.Cstrike)

        if ($script:chkAutoexec.Checked) {
            Update-SetupProgress -Percent 10 -Status 'Installing autoexec.cfg...'
            if (Install-Autoexec -Dirs $Dirs) {
                Write-SetupLog -Message 'Installed autoexec.cfg.'
            }
            else {
                Write-SetupLog -Message 'Failed to install autoexec.cfg.' -Color $script:Theme.Warning
            }
        }

        if ($script:chkMenu.Checked) {
            Update-SetupProgress -Percent 25 -Status 'Installing GameMenu.res...'
            if (Install-GameMenu -Dirs $Dirs) {
                Write-SetupLog -Message 'Installed GameMenu.res.'
            }
            else {
                Write-SetupLog -Message 'Failed to install GameMenu.res.' -Color $script:Theme.Warning
            }
        }

        if ($script:chkGamingMode.Checked) {
            Update-SetupProgress -Percent 40 -Status 'Creating LamaTeam Setup shortcut...'
            if (Install-GamingMode) {
                Write-SetupLog -Message 'Created LamaTeam Setup shortcut on the desktop.'
            }
            else {
                Write-SetupLog -Message 'Failed to create LamaTeam Setup shortcut.' -Color $script:Theme.Warning
            }
        }

        if ($script:chkMaps.Checked) {
            Update-SetupProgress -Percent 50 -Status 'Synchronizing LamaTeam maps...'
            $result = Sync-Maps -Dirs $Dirs -ProgressCallback {
                param($percent, $status)
                Update-SetupProgress -Percent (50 + [int]($percent / 2)) -Status $status
            }
            Write-SetupLog -Message ('Map sync complete. Downloaded: {0}, failed: {1}.' -f $result.Downloaded, $result.Failed)
        }

        Update-SetupProgress -Percent 100 -Status 'Setup finished.'
        Write-SetupLog -Message 'Setup completed.' -Color $script:Theme.Accent

        if ($script:chkConnectAfter.Checked) {
            Start-Process -FilePath ("steam://connect/{0}" -f $script:ServerAddress) | Out-Null
            Write-SetupLog -Message ("Connecting to {0}" -f $script:ServerAddress)
        }
    }
    catch {
        Write-SetupLog -Message ('Setup failed: {0}' -f $_.Exception.Message) -Color $script:Theme.Danger
        Update-SetupProgress -Percent 0 -Status 'Setup failed.'
    }
    finally {
        Set-SetupBusyState -Busy $false
    }
}

function Write-SetupLog {
    param(
        [string]$Message,
        [System.Drawing.Color]$Color = $script:Theme.Foreground
    )

    if (-not (Test-UiControl -Control $script:txtLog)) {
        return
    }

    $timestamp = Get-Date -Format 'HH:mm:ss'
    $script:txtLog.SelectionStart = $script:txtLog.TextLength
    $script:txtLog.SelectionLength = 0
    $script:txtLog.SelectionColor = $Color
    $entry = "[{0}] {1}{2}" -f $timestamp, $Message, [Environment]::NewLine
    $script:txtLog.AppendText($entry)
    $script:txtLog.SelectionColor = $script:Theme.Foreground
    $script:txtLog.ScrollToCaret()
    Refresh-SetupUi
}

function Update-SetupProgress {
    param(
        [int]$Percent,
        [string]$Status
    )

    if (Test-UiControl -Control $script:progressBar) {
        $script:progressBar.Style = 'Continuous'
        $script:progressBar.Value = [math]::Max(0, [math]::Min(100, $Percent))
    }

    if (Test-UiControl -Control $script:lblStatus) {
        $script:lblStatus.Text = $Status
    }

    Refresh-SetupUi
}

function Set-DetectedPath {
    param([hashtable]$Dirs)

    $script:DetectedDirs = $Dirs
    if ($Dirs) {
        $script:txtPath.Text = $Dirs.GameRoot
        $script:txtPath.SelectionStart = 0
        $script:txtPath.SelectionLength = 0
        $script:lblPathState.Text = 'Counter-Strike: Source detected and ready.'
        $script:lblPathState.ForeColor = $script:Theme.Accent
        $script:btnInstall.Enabled = $true
    }
    else {
        $script:txtPath.Text = ''
        $script:lblPathState.Text = 'Counter-Strike: Source was not found automatically.'
        $script:lblPathState.ForeColor = $script:Theme.Warning
        $script:btnInstall.Enabled = $false
    }

    Save-SetupConfig
}

function Detect-CSSInstall {
    Update-SetupProgress -Percent 0 -Status 'Detecting Counter-Strike: Source...'
    $dirs = Get-CSSDirs
    if (-not $dirs -and $script:Config.LastGameRoot) {
        $dirs = Resolve-CSSDirsFromPath -BasePath $script:Config.LastGameRoot
    }
    Set-DetectedPath -Dirs $dirs
    if ($dirs) {
        Write-SetupLog -Message ('Detected Counter-Strike: Source at {0}' -f $dirs.GameRoot)
    }
    else {
        Write-SetupLog -Message 'Automatic detection failed. Use Browse to select the game folder.' -Color $script:Theme.Warning
    }
}

function Browse-CSSInstall {
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = 'Select your Counter-Strike: Source folder or its cstrike subfolder.'
    $dialog.UseDescriptionForTitle = $true

    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $dirs = Resolve-CSSDirsFromPath -BasePath $dialog.SelectedPath
        if ($dirs) {
            Set-DetectedPath -Dirs $dirs
            Write-SetupLog -Message ('Using manually selected path: {0}' -f $dirs.GameRoot)
        }
        else {
            [System.Windows.Forms.MessageBox]::Show(
                'That folder does not look like a Counter-Strike: Source installation.',
                'LamaTeam Setup',
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            ) | Out-Null
        }
    }
}

function New-ActionButton {
    param(
        [string]$Text,
        [System.Drawing.Color]$BackColor,
        [System.Drawing.Color]$ForeColor = $script:Theme.Foreground
    )

    $button = New-Object System.Windows.Forms.Button
    $button.Text = $Text
    $button.Width = 170
    $button.Height = 42
    $button.Margin = New-Object System.Windows.Forms.Padding(0, 0, 12, 0)
    $button.FlatStyle = 'Flat'
    $button.FlatAppearance.BorderSize = 0
    $button.BackColor = $BackColor
    $button.ForeColor = $ForeColor
    $button.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 10)
    return $button
}

function New-InfoPanel {
    param(
        [string]$Title,
        [string]$Body
    )

    $panel = New-Object System.Windows.Forms.Panel
    $panel.Height = 92
    $panel.Margin = New-Object System.Windows.Forms.Padding(0, 0, 0, 12)
    $panel.BackColor = $script:Theme.Surface
    $panel.Padding = New-Object System.Windows.Forms.Padding(16)

    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.Text = $Title
    $titleLabel.AutoSize = $true
    $titleLabel.Location = New-Object System.Drawing.Point(16, 16)
    $titleLabel.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 12)
    $titleLabel.ForeColor = $script:Theme.Foreground
    $panel.Controls.Add($titleLabel)

    $bodyLabel = New-Object System.Windows.Forms.Label
    $bodyLabel.Text = $Body
    $bodyLabel.AutoSize = $true
    $bodyLabel.MaximumSize = New-Object System.Drawing.Size(420, 0)
    $bodyLabel.Location = New-Object System.Drawing.Point(16, 46)
    $bodyLabel.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    $bodyLabel.ForeColor = $script:Theme.Muted
    $panel.Controls.Add($bodyLabel)

    $syncPanelLayout = {
        param(
            [System.Windows.Forms.Panel]$InfoPanel,
            [System.Windows.Forms.Label]$InfoBodyLabel
        )

        $InfoBodyLabel.MaximumSize = New-Object System.Drawing.Size([math]::Max(180, $InfoPanel.ClientSize.Width - 32), 0)
        $InfoBodyLabel.Location = New-Object System.Drawing.Point(16, 46)
        $InfoPanel.Height = [math]::Max(92, $InfoBodyLabel.Bottom + 16)
    }

    & $syncPanelLayout $panel $bodyLabel
    $panel.Add_SizeChanged({
        param($sender, $e)
        & $syncPanelLayout $panel $bodyLabel
    }.GetNewClosure())

    return $panel
}

function Update-SetupLayout {
    if (-not $script:leftPanel -or -not $script:rightPanel) {
        return
    }

    $leftX = $script:leftPanel.Padding.Left
    $rightX = $script:rightPanel.Padding.Left
    $leftWidth = [math]::Max(280, $script:leftPanel.ClientSize.Width - $script:leftPanel.Padding.Left - $script:leftPanel.Padding.Right - 6)
    $rightWidth = [math]::Max(320, $script:rightPanel.ClientSize.Width - $script:rightPanel.Padding.Left - $script:rightPanel.Padding.Right - 6)

    if ($script:main -and $script:main.ClientSize.Width -ge 700) {
        $script:main.Panel1MinSize = 300
        $script:main.Panel2MinSize = 320
        $maxSplitter = [math]::Max($script:main.Panel1MinSize, $script:main.ClientSize.Width - $script:main.Panel2MinSize - 8)
        if ($maxSplitter -gt 0) {
            $desired = [math]::Max(390, [int]($script:main.ClientSize.Width * 0.48))
            $script:main.SplitterDistance = [math]::Min($desired, $maxSplitter)
        }
    }

    $currentLeftTop = $script:leftPanel.Padding.Top

    if ($script:pathPanel) {
        $script:pathPanel.Width = $leftWidth
        $script:pathPanel.Location = New-Object System.Drawing.Point($leftX, $currentLeftTop)
        $script:pathTitle.Location = New-Object System.Drawing.Point(16, 16)

        $pathHintWidth = [math]::Max(240, $leftWidth - 32)
        $script:pathHint.MaximumSize = New-Object System.Drawing.Size($pathHintWidth, 0)
        $script:pathHint.Location = New-Object System.Drawing.Point(16, 48)
        $script:pathHint.AutoSize = $true

        $script:txtPath.Width = $pathHintWidth
        $script:txtPath.Location = New-Object System.Drawing.Point(16, ($script:pathHint.Bottom + 10))

        $script:lblPathState.MaximumSize = New-Object System.Drawing.Size($pathHintWidth, 0)
        $script:lblPathState.AutoSize = $true
        $script:lblPathState.Location = New-Object System.Drawing.Point(16, ($script:txtPath.Bottom + 8))

        $script:pathButtons.Width = $pathHintWidth
        $script:pathButtons.Location = New-Object System.Drawing.Point(16, ($script:lblPathState.Bottom + 10))
        $buttonHeight = $script:pathButtons.GetPreferredSize((New-Object System.Drawing.Size($pathHintWidth, 0))).Height
        $script:pathButtons.Height = [math]::Max(44, $buttonHeight)

        $script:pathPanel.Height = $script:pathButtons.Bottom + 16
        $currentLeftTop = $script:pathPanel.Bottom + 12
    }

    if ($script:optionsPanel) {
        $script:optionsPanel.Width = $leftWidth
        $script:optionsPanel.Location = New-Object System.Drawing.Point($leftX, $currentLeftTop)
    }

    $currentY = 52
    foreach ($checkBox in @($script:chkAutoexec, $script:chkMenu, $script:chkMaps, $script:chkGamingMode, $script:chkConnectAfter)) {
        if ($checkBox) {
            $checkBox.AutoSize = $false
            $checkBox.Width = [math]::Max(250, $leftWidth - 34)
            $checkBox.Location = New-Object System.Drawing.Point(18, $currentY)
            $preferred = $checkBox.GetPreferredSize((New-Object System.Drawing.Size($checkBox.Width, 0)))
            $checkBox.Height = [math]::Max(32, $preferred.Height + 4)
            $currentY += $checkBox.Height + 6
        }
    }

    if ($script:optionsPanel) {
        $script:optionsPanel.Height = [math]::Max(238, $currentY + 16)
        $currentLeftTop = $script:optionsPanel.Bottom + 12
    }

    foreach ($panel in @($script:backupInfoPanel, $script:serverInfoPanel)) {
        if ($panel) {
            $panel.Width = $leftWidth
            $panel.Location = New-Object System.Drawing.Point($leftX, $currentLeftTop)
            $currentLeftTop = $panel.Bottom + 12
        }
    }

    $currentRightTop = $script:rightPanel.Padding.Top
    if ($script:infoPanel) {
        $script:infoPanel.Width = $rightWidth
        $script:infoPanel.Location = New-Object System.Drawing.Point($rightX, $currentRightTop)
        $infoBodyWidth = [math]::Max(280, $rightWidth - 32)
        $script:infoBody.MaximumSize = New-Object System.Drawing.Size($infoBodyWidth, 0)
        $script:infoBody.Location = New-Object System.Drawing.Point(16, 52)
        $script:infoBody.AutoSize = $true
        $script:infoPanel.Height = [math]::Max(148, $script:infoBody.Bottom + 16)
        $currentRightTop = $script:infoPanel.Bottom + 14
    }

    if ($script:logPanel) {
        $script:logPanel.Width = $rightWidth
        $script:logPanel.Location = New-Object System.Drawing.Point($rightX, $currentRightTop)
        $availableRightHeight = [math]::Max(260, $script:rightPanel.ClientSize.Height - $script:rightPanel.Padding.Top - $script:rightPanel.Padding.Bottom)
        $logHeight = [math]::Max(220, $availableRightHeight - ($currentRightTop - $script:rightPanel.Padding.Top))
        $script:logPanel.Height = $logHeight
        $script:txtLog.Location = New-Object System.Drawing.Point(0, 34)
        $script:txtLog.Size = New-Object System.Drawing.Size($rightWidth, [math]::Max(160, $logHeight - 34))
    }

    $script:leftPanel.AutoScrollMinSize = New-Object System.Drawing.Size(0, ($currentLeftTop + $script:leftPanel.Padding.Bottom))
    if ($script:logPanel) {
        $script:rightPanel.AutoScrollMinSize = New-Object System.Drawing.Size(0, ($script:logPanel.Bottom + $script:rightPanel.Padding.Bottom))
    }
}

function Save-ControlScreenshot {
    param(
        [System.Windows.Forms.Control]$Control,
        [string]$Path
    )

    if (-not $Control -or [string]::IsNullOrWhiteSpace($Path)) {
        return
    }

    $directory = Split-Path -Path $Path -Parent
    if ($directory -and -not (Test-Path $directory)) {
        New-Item -Path $directory -ItemType Directory -Force | Out-Null
    }

    $bitmap = New-Object System.Drawing.Bitmap($Control.Width, $Control.Height)
    try {
        $Control.DrawToBitmap($bitmap, (New-Object System.Drawing.Rectangle(0, 0, $Control.Width, $Control.Height)))
        $bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    }
    finally {
        $bitmap.Dispose()
    }
}

function Get-DefaultGmConfig {
    return @{
        ProcessSelections = @()
        ServiceSelections = @()
        TaskSelections = @()
        EnabledTweaks = @('Power', 'Network', 'GameDvr', 'Dns')
        AutoConnect = $true
        ExtraProtectedProcesses = @()
    }
}

function Get-DefaultGmSession {
    return @{
        Active = $false
        CreatedAt = $null
        AppliedTweaks = @()
        StoppedServices = @()
        DisabledTasks = @()
        PreviousPowerScheme = $null
        NetworkOriginal = @{
            NetworkThrottlingIndex = @{ Exists = $false; Value = $null }
            SystemResponsiveness = @{ Exists = $false; Value = $null }
        }
        GameDvrOriginal = @{
            GameDVR_Enabled = @{ Exists = $false; Value = $null }
            AppCaptureEnabled = @{ Exists = $false; Value = $null }
        }
    }
}

function Normalize-GmConfig {
    $defaults = Get-DefaultGmConfig
    $data = Read-JsonFile -Path $script:GmConfigPath -Defaults $defaults
    return @{
        ProcessSelections = ConvertTo-StringArray $data.ProcessSelections
        ServiceSelections = ConvertTo-StringArray $data.ServiceSelections
        TaskSelections = ConvertTo-StringArray $data.TaskSelections
        EnabledTweaks = if ((ConvertTo-StringArray $data.EnabledTweaks).Count -gt 0) { ConvertTo-StringArray $data.EnabledTweaks } else { $defaults.EnabledTweaks }
        AutoConnect = if ($null -ne $data.AutoConnect) { [bool]$data.AutoConnect } else { $defaults.AutoConnect }
        ExtraProtectedProcesses = @()
    }
}

function Normalize-GmSession {
    $defaults = Get-DefaultGmSession
    $data = Read-JsonFile -Path $script:GmSessionPath -Defaults $defaults
    $network = if ($data.NetworkOriginal) { $data.NetworkOriginal } else { $defaults.NetworkOriginal }
    $gameDvr = if ($data.GameDvrOriginal) { $data.GameDvrOriginal } else { $defaults.GameDvrOriginal }
    return @{
        Active = [bool]$data.Active
        CreatedAt = $data.CreatedAt
        AppliedTweaks = ConvertTo-StringArray $data.AppliedTweaks
        StoppedServices = ConvertTo-StringArray $data.StoppedServices
        DisabledTasks = ConvertTo-StringArray $data.DisabledTasks
        PreviousPowerScheme = if ($data.PreviousPowerScheme) { [string]$data.PreviousPowerScheme } else { $null }
        NetworkOriginal = @{
            NetworkThrottlingIndex = @{ Exists = [bool]$network.NetworkThrottlingIndex.Exists; Value = $network.NetworkThrottlingIndex.Value }
            SystemResponsiveness = @{ Exists = [bool]$network.SystemResponsiveness.Exists; Value = $network.SystemResponsiveness.Value }
        }
        GameDvrOriginal = @{
            GameDVR_Enabled = @{ Exists = [bool]$gameDvr.GameDVR_Enabled.Exists; Value = $gameDvr.GameDVR_Enabled.Value }
            AppCaptureEnabled = @{ Exists = [bool]$gameDvr.AppCaptureEnabled.Exists; Value = $gameDvr.AppCaptureEnabled.Value }
        }
    }
}

function Get-GmProtectedPatterns {
    return @($script:GmBaseProtected | Sort-Object -Unique)
}

function Test-GmMatchAny {
    param([string]$Text, [string[]]$Patterns)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    $normalized = $Text.ToLowerInvariant()
    foreach ($pattern in $Patterns) {
        if (-not [string]::IsNullOrWhiteSpace($pattern) -and $normalized -like "*$($pattern.ToLowerInvariant())*") { return $true }
    }
    return $false
}

function Test-GmPathInSystemRoot {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    foreach ($root in $script:GmSystemRoots) {
        if ($Path.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Get-GmBackgroundProcessScan {
    $protectedPatterns = Get-GmProtectedPatterns
    $sessionId = (Get-Process -Id $PID).SessionId
    $samples = @()
    foreach ($process in Get-Process | Sort-Object -Property WorkingSet64 -Descending) {
        if ($process.Id -eq $PID) { continue }
        if ($process.SessionId -ne $sessionId -and $process.MainWindowHandle -eq 0) { continue }
        if (Test-GmMatchAny -Text $process.ProcessName -Patterns $protectedPatterns) { continue }
        $path = $null
        try { $path = $process.Path } catch { $path = $null }
        if ($path -and (Test-GmPathInSystemRoot -Path $path)) { continue }
        if (-not $path -and [string]::IsNullOrWhiteSpace($process.MainWindowTitle)) { continue }
        $samples += [pscustomobject]@{
            Key = $process.ProcessName
            Name = $process.ProcessName
            WorkingSet = [int64]$process.WorkingSet64
            WindowTitle = $process.MainWindowTitle
            Path = $path
            NotRecommended = -not (Test-GmMatchAny -Text $process.ProcessName -Patterns $script:GmRecommendedProcesses)
        }
    }
    $grouped = foreach ($group in ($samples | Group-Object -Property Key)) {
        $firstWindow = $group.Group | Where-Object { -not [string]::IsNullOrWhiteSpace($_.WindowTitle) } | Select-Object -First 1
        $firstPath = $group.Group | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Path) } | Select-Object -First 1
        $memory = ($group.Group | Measure-Object -Property WorkingSet -Sum).Sum
        [pscustomobject]@{
            Key = $group.Name
            Name = $group.Name
            Count = $group.Count
            MemoryMb = [math]::Round(($memory / 1MB), 1)
            Details = if ($firstWindow) { $firstWindow.WindowTitle } elseif ($firstPath) { $firstPath.Path } else { 'Background process' }
            NotRecommended = [bool]($group.Group | Where-Object { $_.NotRecommended } | Select-Object -First 1)
        }
    }
    return @($grouped | Sort-Object @{ Expression = 'NotRecommended'; Descending = $false }, @{ Expression = 'MemoryMb'; Descending = $true }, Name)
}

function Get-GmServiceScan {
    $protectedPatterns = Get-GmProtectedPatterns
    $services = @()
    
    $rawServices = @()
    try {
        $rawServices = @(Get-CimInstance -ClassName Win32_Service -Filter "State='Running'" -ErrorAction Stop)
    }
    catch {
        try {
            $rawServices = @(Get-WmiObject -Class Win32_Service -Filter "State='Running'" -ErrorAction Stop)
        }
        catch {
            Write-SetupLog -Message ("Service scan failed: {0}" -f $_.Exception.Message) -Color $script:Theme.Warning
            return @()
        }
    }

    foreach ($service in $rawServices) {
        if (-not $service.AcceptStop) { continue }
        if (Test-GmMatchAny -Text $service.Name -Patterns $protectedPatterns) { continue }
        if (Test-GmMatchAny -Text $service.DisplayName -Patterns $protectedPatterns) { continue }
        $binaryPath = $service.PathName
        if ($binaryPath -match '^"([^"]+)"') { $binaryPath = $matches[1] }
        elseif ($binaryPath -match '^([^\s]+)') { $binaryPath = $matches[1] }
        if ($binaryPath -and (Test-GmPathInSystemRoot -Path $binaryPath)) { continue }
        $services += [pscustomobject]@{
            Key = $service.Name
            Name = $service.Name
            DisplayName = $service.DisplayName
            Startup = $service.StartMode
            NotRecommended = -not ((Test-GmMatchAny -Text $service.Name -Patterns $script:GmRecommendedServices) -or (Test-GmMatchAny -Text $service.DisplayName -Patterns $script:GmRecommendedServices))
        }
    }
    return @($services | Sort-Object @{ Expression = 'NotRecommended'; Descending = $false }, Name)
}

function Get-GmTaskKey { param($Task) return '{0}{1}' -f $Task.TaskPath, $Task.TaskName }
function Split-GmTaskKey {
    param([string]$Key)
    $lastSlash = $Key.LastIndexOf('\')
    if ($lastSlash -lt 0) { return @{ TaskPath = '\'; TaskName = $Key } }
    return @{ TaskPath = if ($lastSlash -eq 0) { '\' } else { $Key.Substring(0, $lastSlash + 1) }; TaskName = $Key.Substring($lastSlash + 1) }
}

function Get-GmTaskScan {
    $tasks = @()
    if (-not (Get-Command Get-ScheduledTask -ErrorAction SilentlyContinue)) {
        Write-SetupLog -Message 'Task scan skipped: Get-ScheduledTask not available.' -Color $script:Theme.Muted
        return @()
    }
    
    $rawTasks = @()
    try {
        $rawTasks = @(Get-ScheduledTask | Where-Object { $_.State -ne 'Disabled' })
    }
    catch {
        Write-SetupLog -Message ("Task scan failed: {0}" -f $_.Exception.Message) -Color $script:Theme.Warning
        return @()
    }

    foreach ($task in $rawTasks) {
        if ($task.TaskPath -like '\Microsoft\*') { continue }
        $execute = $null
        try { $execute = ($task.Actions | Where-Object { $_.Execute } | Select-Object -First 1).Execute } catch { }
        if ($execute -and (Test-GmPathInSystemRoot -Path $execute) -and -not (Test-GmMatchAny -Text $task.TaskName -Patterns $script:GmRecommendedTasks)) { continue }
        $tasks += [pscustomobject]@{
            Key = Get-GmTaskKey -Task $task
            Name = $task.TaskName
            TaskPath = $task.TaskPath
            State = [string]$task.State
            NotRecommended = -not ((Test-GmMatchAny -Text $task.TaskName -Patterns $script:GmRecommendedTasks) -or (Test-GmMatchAny -Text $task.TaskPath -Patterns $script:GmRecommendedTasks))
        }
    }
    return @($tasks | Sort-Object @{ Expression = 'NotRecommended'; Descending = $false }, TaskPath, Name)
}

function Get-GmCheckedKeys {
    param([System.Windows.Forms.ListView]$ListView)
    if (-not $ListView) { return @() }
    $keys = @()
    foreach ($item in $ListView.Items) { if ($item.Checked) { $keys += [string]$item.Tag } }
    return @($keys)
}

function Save-GmConfigFromUi {
    $script:GmConfig = @{
        ProcessSelections = Get-GmCheckedKeys -ListView $script:lvKill
        ServiceSelections = Get-GmCheckedKeys -ListView $script:lvGmServices
        TaskSelections = Get-GmCheckedKeys -ListView $script:lvGmTasks
        EnabledTweaks = @(
            if ($script:chkGmPower.Checked) { 'Power' }
            if ($script:chkGmNetwork.Checked) { 'Network' }
            if ($script:chkGmGameDvr.Checked) { 'GameDvr' }
            if ($script:chkGmDns.Checked) { 'Dns' }
        )
        AutoConnect = $script:chkGmAutoConnect.Checked
        ExtraProtectedProcesses = @()
    }
    Save-JsonFile -Path $script:GmConfigPath -Data $script:GmConfig
}

function New-GmListView {
    $listView = New-Object System.Windows.Forms.ListView
    $listView.Dock = 'Fill'
    $listView.View = 'Details'
    $listView.CheckBoxes = $true
    $listView.FullRowSelect = $true
    $listView.HideSelection = $false
    $listView.BackColor = $script:Theme.Surface
    $listView.ForeColor = $script:Theme.Foreground
    $listView.BorderStyle = 'None'
    $listView.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    return $listView
}

class ListViewItemComparer : System.Collections.IComparer {
    [int]$Column
    [bool]$Ascending

    ListViewItemComparer([int]$column, [bool]$ascending) {
        $this.Column = $column
        $this.Ascending = $ascending
    }

    [int] Compare([object]$x, [object]$y) {
        $leftItem = $x
        $rightItem = $y
        $leftText = if ($this.Column -lt $leftItem.SubItems.Count) { [string]$leftItem.SubItems[$this.Column].Text } else { '' }
        $rightText = if ($this.Column -lt $rightItem.SubItems.Count) { [string]$rightItem.SubItems[$this.Column].Text } else { '' }

        $leftNumber = 0.0
        $rightNumber = 0.0
        if ([double]::TryParse($leftText, [ref]$leftNumber) -and [double]::TryParse($rightText, [ref]$rightNumber)) {
            $result = [System.Math]::Sign($leftNumber - $rightNumber)
        }
        else {
            $result = [string]::Compare($leftText, $rightText, $true)
        }

        if (-not $this.Ascending) {
            $result = -$result
        }
        return $result
    }
}

function Enable-ListViewSorting {
    param([System.Windows.Forms.ListView]$ListView)
    if (-not $ListView) { return }
    $ListView.Tag = @{ SortColumn = -1; SortAscending = $true }
    $ListView.Add_ColumnClick({
        param($sender, $e)
        $state = $sender.Tag
        if (-not ($state -is [hashtable])) {
            $state = @{ SortColumn = -1; SortAscending = $true }
        }
        if ($state.SortColumn -eq $e.Column) {
            $state.SortAscending = -not [bool]$state.SortAscending
        }
        else {
            $state.SortColumn = [int]$e.Column
            $state.SortAscending = $true
        }
        $sender.ListViewItemSorter = [ListViewItemComparer]::new([int]$state.SortColumn, [bool]$state.SortAscending)
        $sender.Sort()
        $sender.Tag = $state
    })
}

function Set-GmResponsiveColumns {
    param([System.Windows.Forms.ListView]$ListView, [int[]]$BaseWidths, [int[]]$MinimumWidths)
    if (-not $ListView -or $ListView.Columns.Count -ne $BaseWidths.Count -or $BaseWidths.Count -ne $MinimumWidths.Count) { return }
    $availableWidth = [math]::Max(120, $ListView.ClientSize.Width - 8)
    $baseTotal = ($BaseWidths | Measure-Object -Sum).Sum
    $assigned = 0
    for ($index = 0; $index -lt $ListView.Columns.Count; $index++) {
        $column = $ListView.Columns[$index]
        if ($index -eq ($ListView.Columns.Count - 1)) {
            $column.Width = [math]::Max($MinimumWidths[$index], $availableWidth - $assigned)
            continue
        }
        $width = [int][math]::Round(($availableWidth * $BaseWidths[$index]) / $baseTotal)
        $width = [math]::Max($MinimumWidths[$index], $width)
        $column.Width = $width
        $assigned += $width
    }
}

function Set-GmListSelections {
    param([System.Windows.Forms.ListView]$ListView, [string[]]$SelectedKeys)
    if (-not $ListView) { return }
    foreach ($item in $ListView.Items) { $item.Checked = $SelectedKeys -contains [string]$item.Tag }
}

function Set-GmListChecked {
    param(
        [System.Windows.Forms.ListView]$ListView,
        [string]$Mode
    )
    if (-not $ListView) { return }
    $ListView.BeginUpdate()
    foreach ($item in $ListView.Items) {
        switch ($Mode) {
            'All' { $item.Checked = $true }
            'None' { $item.Checked = $false }
            'Safe' { $item.Checked = ($item.BackColor -eq $script:Theme.AccentMuted) }
        }
    }
    $ListView.EndUpdate()
}

function Refresh-GmScan {
    try {
        if ($script:GmScanInitialized) {
            Save-GmConfigFromUi
        }
        $processes = Get-GmBackgroundProcessScan
        $services = Get-GmServiceScan
        $tasks = Get-GmTaskScan
        
        Write-SetupLog -Message ("Scan found: {0} processes, {1} services, {2} tasks." -f $processes.Count, $services.Count, $tasks.Count)

        $script:lvKill.BeginUpdate()
        $script:lvKill.Items.Clear()
        foreach ($entry in $processes) {
            $item = New-Object System.Windows.Forms.ListViewItem($entry.Name)
            [void]$item.SubItems.Add([string]$entry.Count)
            [void]$item.SubItems.Add(('{0:N1}' -f $entry.MemoryMb))
            [void]$item.SubItems.Add($entry.Details)
            $item.Tag = $entry.Key
            if (-not $entry.NotRecommended) { $item.BackColor = $script:Theme.AccentMuted }
            [void]$script:lvKill.Items.Add($item)
        }
        Set-GmListSelections -ListView $script:lvKill -SelectedKeys $script:GmConfig.ProcessSelections
        $script:lvKill.EndUpdate()

        $script:lvGmServices.BeginUpdate()
        $script:lvGmServices.Items.Clear()
        foreach ($entry in $services) {
            $item = New-Object System.Windows.Forms.ListViewItem($entry.Name)
            [void]$item.SubItems.Add($entry.DisplayName)
            [void]$item.SubItems.Add($entry.Startup)
            [void]$item.SubItems.Add($(if ($entry.NotRecommended) { 'Not Recommended' } else { 'Safe' }))
            $item.Tag = $entry.Key
            if (-not $entry.NotRecommended) { $item.BackColor = $script:Theme.AccentMuted }
            [void]$script:lvGmServices.Items.Add($item)
        }
        Set-GmListSelections -ListView $script:lvGmServices -SelectedKeys $script:GmConfig.ServiceSelections
        $script:lvGmServices.EndUpdate()

        $script:lvGmTasks.BeginUpdate()
        $script:lvGmTasks.Items.Clear()
        foreach ($entry in $tasks) {
            $item = New-Object System.Windows.Forms.ListViewItem($entry.Name)
            [void]$item.SubItems.Add($entry.TaskPath)
            [void]$item.SubItems.Add($entry.State)
            [void]$item.SubItems.Add($(if ($entry.NotRecommended) { 'Not Recommended' } else { 'Safe' }))
            $item.Tag = $entry.Key
            if (-not $entry.NotRecommended) { $item.BackColor = $script:Theme.AccentMuted }
            [void]$script:lvGmTasks.Items.Add($item)
        }
        Set-GmListSelections -ListView $script:lvGmTasks -SelectedKeys $script:GmConfig.TaskSelections
        $script:lvGmTasks.EndUpdate()

        $script:GmScanInitialized = $true
        Write-SetupLog -Message 'Gaming scan refreshed.'
    }
    catch {
        Write-SetupLog -Message ('Gaming scan failed: {0}' -f $_.Exception.Message) -Color $script:Theme.Warning
    }
}

function Invoke-GmKillSelected {
    $names = Get-GmCheckedKeys -ListView $script:lvKill
    if (-not $names.Count) { Write-SetupLog -Message 'No kill targets selected.' -Color $script:Theme.Warning; return }
    $stopped = 0
    foreach ($name in $names) {
        foreach ($process in (Get-Process -Name $name -ErrorAction SilentlyContinue)) {
            try { Stop-Process -Id $process.Id -Force -ErrorAction Stop; $stopped++ } catch { }
        }
    }
    Write-SetupLog -Message ("Stopped {0} process instances." -f $stopped)
    Refresh-GmScan
}

function Invoke-GmStopServices {
    $services = Get-GmCheckedKeys -ListView $script:lvGmServices
    if (-not $services.Count) { Write-SetupLog -Message 'No services selected.' -Color $script:Theme.Warning; return }
    $session = Normalize-GmSession
    foreach ($serviceName in $services) {
        try {
            Stop-Service -Name $serviceName -Force -ErrorAction Stop
            if ($session.StoppedServices -notcontains $serviceName) { $session.StoppedServices += $serviceName }
        }
        catch { Write-SetupLog -Message ("Failed to stop service {0}." -f $serviceName) -Color $script:Theme.Warning }
    }
    Save-JsonFile -Path $script:GmSessionPath -Data $session
    Write-SetupLog -Message ("Processed {0} selected services." -f $services.Count)
    Refresh-GmScan
}

function Invoke-GmDisableTasks {
    $keys = Get-GmCheckedKeys -ListView $script:lvGmTasks
    if (-not $keys.Count) { Write-SetupLog -Message 'No tasks selected.' -Color $script:Theme.Warning; return }
    $session = Normalize-GmSession
    foreach ($key in $keys) {
        $parts = Split-GmTaskKey -Key $key
        try {
            Disable-ScheduledTask -TaskPath $parts.TaskPath -TaskName $parts.TaskName -ErrorAction Stop | Out-Null
            if ($session.DisabledTasks -notcontains $key) { $session.DisabledTasks += $key }
        }
        catch { Write-SetupLog -Message ("Failed to disable task {0}." -f $key) -Color $script:Theme.Warning }
    }
    Save-JsonFile -Path $script:GmSessionPath -Data $session
    Write-SetupLog -Message ("Processed {0} selected tasks." -f $keys.Count)
    Refresh-GmScan
}

function Get-RegistryValueState {
    param([string]$Path,[string]$Name)
    try {
        $property = Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop
        return @{ Exists = $true; Value = $property.$Name }
    } catch { return @{ Exists = $false; Value = $null } }
}
function Set-RegistryValueState {
    param([string]$Path,[string]$Name,[hashtable]$State)
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    if ($State.Exists) { Set-ItemProperty -Path $Path -Name $Name -Value $State.Value -Force }
    else { Remove-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue }
}

function Apply-GmTweaks {
    $session = Normalize-GmSession
    if ($session.Active) { Write-SetupLog -Message 'Gaming session already active.' -Color $script:Theme.Warning; return }
    $session.Active = $true
    $session.CreatedAt = (Get-Date).ToString('o')
    $session.AppliedTweaks = @()
    if ($script:chkGmPower.Checked) {
        $currentScheme = $null
        try { $line = (powercfg /getactivescheme | Select-Object -First 1); if ($line -match '([A-Fa-f0-9-]{36})') { $currentScheme = $matches[1] } } catch { }
        $session.PreviousPowerScheme = $currentScheme
        powercfg /setactive SCHEME_MIN | Out-Null
        $session.AppliedTweaks += 'Power'
    }
    if ($script:chkGmNetwork.Checked) {
        $path = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
        $session.NetworkOriginal.NetworkThrottlingIndex = Get-RegistryValueState -Path $path -Name 'NetworkThrottlingIndex'
        $session.NetworkOriginal.SystemResponsiveness = Get-RegistryValueState -Path $path -Name 'SystemResponsiveness'
        New-ItemProperty -Path $path -Name 'NetworkThrottlingIndex' -Value 4294967295 -PropertyType DWord -Force | Out-Null
        New-ItemProperty -Path $path -Name 'SystemResponsiveness' -Value 0 -PropertyType DWord -Force | Out-Null
        $session.AppliedTweaks += 'Network'
    }
    if ($script:chkGmGameDvr.Checked) {
        $storePath = 'HKCU:\System\GameConfigStore'
        $dvrPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR'
        $session.GameDvrOriginal.GameDVR_Enabled = Get-RegistryValueState -Path $storePath -Name 'GameDVR_Enabled'
        $session.GameDvrOriginal.AppCaptureEnabled = Get-RegistryValueState -Path $dvrPath -Name 'AppCaptureEnabled'
        New-ItemProperty -Path $storePath -Name 'GameDVR_Enabled' -Value 0 -PropertyType DWord -Force | Out-Null
        New-ItemProperty -Path $dvrPath -Name 'AppCaptureEnabled' -Value 0 -PropertyType DWord -Force | Out-Null
        $session.AppliedTweaks += 'GameDvr'
    }
    if ($script:chkGmDns.Checked) { ipconfig /flushdns | Out-Null; $session.AppliedTweaks += 'Dns' }
    Save-JsonFile -Path $script:GmSessionPath -Data $session
    Write-SetupLog -Message 'Gaming tweaks applied.'
    if ($script:chkGmAutoConnect.Checked) { Start-Process -FilePath ("steam://connect/{0}" -f $script:ServerAddress) | Out-Null }
}

function Restore-GmSession {
    $session = Normalize-GmSession
    if (-not $session.Active) { Write-SetupLog -Message 'No active gaming session found.' -Color $script:Theme.Warning; return }
    foreach ($serviceName in $session.StoppedServices) { try { Start-Service -Name $serviceName -ErrorAction Stop } catch { } }
    foreach ($taskKey in $session.DisabledTasks) {
        $parts = Split-GmTaskKey -Key $taskKey
        try { Enable-ScheduledTask -TaskPath $parts.TaskPath -TaskName $parts.TaskName -ErrorAction Stop | Out-Null } catch { }
    }
    if ($session.PreviousPowerScheme -and $session.AppliedTweaks -contains 'Power') { try { powercfg /setactive $session.PreviousPowerScheme | Out-Null } catch { } }
    if ($session.AppliedTweaks -contains 'Network') {
        $path = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
        Set-RegistryValueState -Path $path -Name 'NetworkThrottlingIndex' -State $session.NetworkOriginal.NetworkThrottlingIndex
        Set-RegistryValueState -Path $path -Name 'SystemResponsiveness' -State $session.NetworkOriginal.SystemResponsiveness
    }
    if ($session.AppliedTweaks -contains 'GameDvr') {
        Set-RegistryValueState -Path 'HKCU:\System\GameConfigStore' -Name 'GameDVR_Enabled' -State $session.GameDvrOriginal.GameDVR_Enabled
        Set-RegistryValueState -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' -Name 'AppCaptureEnabled' -State $session.GameDvrOriginal.AppCaptureEnabled
    }
    Save-JsonFile -Path $script:GmSessionPath -Data (Get-DefaultGmSession)
    Write-SetupLog -Message 'Gaming session restored.'
    Refresh-GmScan
}

if (-not (Ensure-Administrator)) {
    return
}

$script:Config = Normalize-SetupConfig
$script:DetectedDirs = $null

$setupForm = New-Object System.Windows.Forms.Form
$setupForm.Text = 'LamaTeam CS:S Setup Pro'
$setupForm.Width = 1180
$setupForm.Height = 820
$setupForm.MinimumSize = New-Object System.Drawing.Size(780, 560)
$setupForm.StartPosition = 'CenterScreen'
$setupForm.BackColor = $script:Theme.Background
$setupForm.ForeColor = $script:Theme.Foreground
$setupForm.Font = New-Object System.Drawing.Font('Segoe UI', 10)
$script:SetupForm = $setupForm

$root = New-Object System.Windows.Forms.TableLayoutPanel
$root.Dock = 'Fill'
$root.BackColor = $script:Theme.Background
$root.ColumnCount = 1
$root.RowCount = 2
$root.Margin = New-Object System.Windows.Forms.Padding(0)
[void]$root.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 118)))
[void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
$setupForm.Controls.Add($root)

$header = New-Object System.Windows.Forms.Panel
$header.Dock = 'Fill'
$header.BackColor = $script:Theme.Panel
$header.Margin = New-Object System.Windows.Forms.Padding(0)
$root.Controls.Add($header, 0, 0)

$title = New-Object System.Windows.Forms.Label
$title.Text = 'LamaTeam CS:S Setup Pro'
$title.Location = New-Object System.Drawing.Point(28, 22)
$title.AutoSize = $true
$title.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 26)
$title.ForeColor = $script:Theme.Foreground
$header.Controls.Add($title)

$subtitle = New-Object System.Windows.Forms.Label
$subtitle.Text = 'Modern one-pass installer for autoexec, menu shortcut, map sync, and LamaTeam Setup.'
$subtitle.Location = New-Object System.Drawing.Point(30, 70)
$subtitle.AutoSize = $true
$subtitle.Font = New-Object System.Drawing.Font('Segoe UI', 11)
$subtitle.ForeColor = $script:Theme.Muted
$header.Controls.Add($subtitle)

$topTabs = New-Object System.Windows.Forms.TabControl
$topTabs.Dock = 'Fill'
$topTabs.BackColor = $script:Theme.Panel
$topTabs.Padding = New-Object System.Drawing.Point(16, 8)
$topTabs.Margin = New-Object System.Windows.Forms.Padding(0)
$root.Controls.Add($topTabs, 0, 1)

$setupTab = New-Object System.Windows.Forms.TabPage
$setupTab.Text = 'Setup'
$setupTab.BackColor = $script:Theme.Background
$topTabs.TabPages.Add($setupTab)

$killTab = New-Object System.Windows.Forms.TabPage
$killTab.Text = 'Kill'
$killTab.BackColor = $script:Theme.Background
$topTabs.TabPages.Add($killTab)

$servicesTab = New-Object System.Windows.Forms.TabPage
$servicesTab.Text = 'Services'
$servicesTab.BackColor = $script:Theme.Background
$topTabs.TabPages.Add($servicesTab)

$tasksTab = New-Object System.Windows.Forms.TabPage
$tasksTab.Text = 'Tasks'
$tasksTab.BackColor = $script:Theme.Background
$topTabs.TabPages.Add($tasksTab)

$tweaksTab = New-Object System.Windows.Forms.TabPage
$tweaksTab.Text = 'Tweaks'
$tweaksTab.BackColor = $script:Theme.Background
$topTabs.TabPages.Add($tweaksTab)

$setupLayout = New-Object System.Windows.Forms.TableLayoutPanel
$setupLayout.Dock = 'Fill'
$setupLayout.ColumnCount = 1
$setupLayout.RowCount = 3
[void]$setupLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$setupLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
[void]$setupLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 44)))
$setupTab.Controls.Add($setupLayout)

$main = New-Object System.Windows.Forms.SplitContainer
$main.Dock = 'Fill'
$main.FixedPanel = 'Panel1'
$main.BackColor = $script:Theme.Background
$main.Margin = New-Object System.Windows.Forms.Padding(0)
$script:main = $main
$setupLayout.Controls.Add($main, 0, 0)

$leftPanel = New-Object System.Windows.Forms.Panel
$leftPanel.Dock = 'Fill'
$leftPanel.Padding = New-Object System.Windows.Forms.Padding(20, 18, 12, 12)
$leftPanel.BackColor = $script:Theme.Background
$leftPanel.AutoScroll = $true
$script:leftPanel = $leftPanel
$main.Panel1.Controls.Add($leftPanel)

$rightPanel = New-Object System.Windows.Forms.Panel
$rightPanel.Dock = 'Fill'
$rightPanel.Padding = New-Object System.Windows.Forms.Padding(12, 18, 20, 12)
$rightPanel.BackColor = $script:Theme.Background
$rightPanel.AutoScroll = $true
$script:rightPanel = $rightPanel
$main.Panel2.Controls.Add($rightPanel)

$pathPanel = New-Object System.Windows.Forms.Panel
$pathPanel.Height = 178
$pathPanel.BackColor = $script:Theme.Surface
$pathPanel.Padding = New-Object System.Windows.Forms.Padding(16)
$script:pathPanel = $pathPanel
$leftPanel.Controls.Add($pathPanel)

$pathTitle = New-Object System.Windows.Forms.Label
$pathTitle.Text = 'Game Path'
$pathTitle.AutoSize = $true
$pathTitle.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 13)
$pathTitle.ForeColor = $script:Theme.Foreground
$script:pathTitle = $pathTitle
$pathPanel.Controls.Add($pathTitle)

$pathHint = New-Object System.Windows.Forms.Label
$pathHint.Text = 'The installer tries to detect Counter-Strike: Source from your Steam libraries. You can browse manually if needed.'
$pathHint.AutoSize = $true
$pathHint.Font = New-Object System.Drawing.Font('Segoe UI', 10)
$pathHint.ForeColor = $script:Theme.Muted
$script:pathHint = $pathHint
$pathPanel.Controls.Add($pathHint)

$script:txtPath = New-Object System.Windows.Forms.TextBox
$script:txtPath.Height = 28
$script:txtPath.ReadOnly = $true
$script:txtPath.BackColor = $script:Theme.SurfaceAlt
$script:txtPath.ForeColor = $script:Theme.Foreground
$script:txtPath.BorderStyle = 'FixedSingle'
$pathPanel.Controls.Add($script:txtPath)

$script:lblPathState = New-Object System.Windows.Forms.Label
$script:lblPathState.AutoSize = $true
$script:lblPathState.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$script:lblPathState.ForeColor = $script:Theme.Muted
$pathPanel.Controls.Add($script:lblPathState)

$pathButtons = New-Object System.Windows.Forms.FlowLayoutPanel
$pathButtons.Height = 44
$pathButtons.WrapContents = $true
$pathButtons.AutoSize = $true
$pathButtons.AutoSizeMode = 'GrowAndShrink'
$pathButtons.Padding = New-Object System.Windows.Forms.Padding(0)
$script:pathButtons = $pathButtons
$pathPanel.Controls.Add($pathButtons)

$script:btnDetect = New-ActionButton -Text 'Detect Again' -BackColor $script:Theme.AccentMuted
$script:btnDetect.Width = 140
$script:btnDetect.Add_Click({ Detect-CSSInstall })
$pathButtons.Controls.Add($script:btnDetect)

$script:btnBrowse = New-ActionButton -Text 'Browse' -BackColor $script:Theme.SurfaceAlt
$script:btnBrowse.Width = 110
$script:btnBrowse.Add_Click({ Browse-CSSInstall })
$pathButtons.Controls.Add($script:btnBrowse)

$optionsPanel = New-Object System.Windows.Forms.Panel
$optionsPanel.Height = 238
$optionsPanel.BackColor = $script:Theme.Surface
$optionsPanel.Padding = New-Object System.Windows.Forms.Padding(16)
$optionsPanel.Margin = New-Object System.Windows.Forms.Padding(0, 12, 0, 0)
$script:optionsPanel = $optionsPanel
$leftPanel.Controls.Add($optionsPanel)

$optionsTitle = New-Object System.Windows.Forms.Label
$optionsTitle.Text = 'Install Options'
$optionsTitle.AutoSize = $true
$optionsTitle.Location = New-Object System.Drawing.Point(16, 16)
$optionsTitle.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 13)
$optionsTitle.ForeColor = $script:Theme.Foreground
$optionsPanel.Controls.Add($optionsTitle)

$script:chkAutoexec = New-Object System.Windows.Forms.CheckBox
$script:chkAutoexec.Text = 'Install LamaTeam autoexec.cfg'
$script:chkAutoexec.Location = New-Object System.Drawing.Point(18, 52)
$script:chkAutoexec.AutoSize = $false
$script:chkAutoexec.Checked = $script:Config.InstallAutoexec
$script:chkAutoexec.ForeColor = $script:Theme.Foreground
$script:chkAutoexec.Font = New-Object System.Drawing.Font('Segoe UI', 10)
$optionsPanel.Controls.Add($script:chkAutoexec)

$script:chkMenu = New-Object System.Windows.Forms.CheckBox
$script:chkMenu.Text = 'Add the LamaTeam menu shortcut'
$script:chkMenu.Location = New-Object System.Drawing.Point(18, 84)
$script:chkMenu.AutoSize = $false
$script:chkMenu.Checked = $script:Config.InstallMenu
$script:chkMenu.ForeColor = $script:Theme.Foreground
$script:chkMenu.Font = New-Object System.Drawing.Font('Segoe UI', 10)
$optionsPanel.Controls.Add($script:chkMenu)

$script:chkMaps = New-Object System.Windows.Forms.CheckBox
$script:chkMaps.Text = 'Download missing LamaTeam maps before joining'
$script:chkMaps.Location = New-Object System.Drawing.Point(18, 116)
$script:chkMaps.AutoSize = $false
$script:chkMaps.Checked = $script:Config.InstallMaps
$script:chkMaps.ForeColor = $script:Theme.Foreground
$script:chkMaps.Font = New-Object System.Drawing.Font('Segoe UI', 10)
$optionsPanel.Controls.Add($script:chkMaps)

$script:chkGamingMode = New-Object System.Windows.Forms.CheckBox
$script:chkGamingMode.Text = 'Create a LamaTeam Setup shortcut on the desktop'
$script:chkGamingMode.Location = New-Object System.Drawing.Point(18, 148)
$script:chkGamingMode.AutoSize = $false
$script:chkGamingMode.Checked = $script:Config.InstallGamingMode
$script:chkGamingMode.ForeColor = $script:Theme.Foreground
$script:chkGamingMode.Font = New-Object System.Drawing.Font('Segoe UI', 10)
$optionsPanel.Controls.Add($script:chkGamingMode)

$script:chkConnectAfter = New-Object System.Windows.Forms.CheckBox
$script:chkConnectAfter.Text = 'Connect to the server after setup finishes'
$script:chkConnectAfter.Location = New-Object System.Drawing.Point(18, 180)
$script:chkConnectAfter.AutoSize = $false
$script:chkConnectAfter.Checked = $script:Config.ConnectAfter
$script:chkConnectAfter.ForeColor = $script:Theme.Foreground
$script:chkConnectAfter.Font = New-Object System.Drawing.Font('Segoe UI', 10)
$optionsPanel.Controls.Add($script:chkConnectAfter)

$backupInfoPanel = New-InfoPanel -Title 'Backups' -Body 'Existing files are copied to timestamped .bak files before the installer overwrites them.'
$serverInfoPanel = New-InfoPanel -Title 'Server Connect' -Body ("Direct connect target: {0}" -f $script:ServerAddress)
$script:backupInfoPanel = $backupInfoPanel
$script:serverInfoPanel = $serverInfoPanel
$leftPanel.Controls.Add($backupInfoPanel)
$leftPanel.Controls.Add($serverInfoPanel)

$infoPanel = New-Object System.Windows.Forms.Panel
$infoPanel.Height = 148
$infoPanel.BackColor = $script:Theme.Surface
$infoPanel.Padding = New-Object System.Windows.Forms.Padding(16)
$script:infoPanel = $infoPanel
$rightPanel.Controls.Add($infoPanel)

$infoTitle = New-Object System.Windows.Forms.Label
$infoTitle.Text = 'What This Installer Does'
$infoTitle.AutoSize = $true
$infoTitle.Location = New-Object System.Drawing.Point(16, 16)
$infoTitle.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 13)
$infoTitle.ForeColor = $script:Theme.Foreground
$script:infoTitle = $infoTitle
$infoPanel.Controls.Add($infoTitle)

$infoBody = New-Object System.Windows.Forms.Label
$infoBody.Text = "1. Detects Counter-Strike: Source in your Steam libraries.`r`n2. Installs the autoexec and menu entry from this repo or the GitHub raw fallback.`r`n3. Downloads only the missing LamaTeam maps.`r`n4. Optionally creates a desktop shortcut to LamaTeam Setup."
$infoBody.AutoSize = $true
$infoBody.Font = New-Object System.Drawing.Font('Segoe UI', 10)
$infoBody.ForeColor = $script:Theme.Muted
$script:infoBody = $infoBody
$infoPanel.Controls.Add($infoBody)

$logPanel = New-Object System.Windows.Forms.Panel
$logPanel.BackColor = $script:Theme.Background
$script:logPanel = $logPanel
$rightPanel.Controls.Add($logPanel)

$logTitle = New-Object System.Windows.Forms.Label
$logTitle.Text = 'Install Log'
$logTitle.AutoSize = $true
$logTitle.Location = New-Object System.Drawing.Point(0, 0)
$logTitle.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 12)
$logTitle.ForeColor = $script:Theme.Foreground
$script:logTitle = $logTitle
$logPanel.Controls.Add($logTitle)

$script:txtLog = New-Object System.Windows.Forms.RichTextBox
$script:txtLog.BackColor = $script:Theme.Surface
$script:txtLog.ForeColor = $script:Theme.Foreground
$script:txtLog.BorderStyle = 'None'
$script:txtLog.ReadOnly = $true
$script:txtLog.Font = New-Object System.Drawing.Font('Cascadia Mono', 9)
$logPanel.Controls.Add($script:txtLog)

$actions = New-Object System.Windows.Forms.FlowLayoutPanel
$actions.Dock = 'Fill'
$actions.AutoSize = $true
$actions.AutoSizeMode = 'GrowAndShrink'
$actions.Padding = New-Object System.Windows.Forms.Padding(20, 12, 20, 12)
$actions.WrapContents = $true
$actions.BackColor = $script:Theme.Panel
$actions.Margin = New-Object System.Windows.Forms.Padding(0)
$setupLayout.Controls.Add($actions, 0, 1)

$script:btnInstall = New-ActionButton -Text 'Install Selected' -BackColor $script:Theme.Accent
$script:btnInstall.Width = 190
$script:btnInstall.Enabled = $false
$script:btnInstall.Add_Click({
    if ($script:DetectedDirs) {
        Run-Installer -Dirs $script:DetectedDirs
    }
})
$actions.Controls.Add($script:btnInstall)

$btnConnect = New-ActionButton -Text 'Connect to Server' -BackColor $script:Theme.SurfaceAlt
$btnConnect.Width = 170
$btnConnect.Add_Click({
    Start-Process -FilePath ("steam://connect/{0}" -f $script:ServerAddress) | Out-Null
    Write-SetupLog -Message ("Connecting to {0}" -f $script:ServerAddress)
})
$script:btnConnect = $btnConnect
$actions.Controls.Add($btnConnect)

$btnClose = New-ActionButton -Text 'Close' -BackColor $script:Theme.SurfaceAlt
$btnClose.Width = 100
$btnClose.Add_Click({ $setupForm.Close() })
$script:btnClose = $btnClose
$actions.Controls.Add($btnClose)

$statusPanel = New-Object System.Windows.Forms.Panel
$statusPanel.Dock = 'Fill'
$statusPanel.Padding = New-Object System.Windows.Forms.Padding(20, 10, 20, 10)
$statusPanel.BackColor = $script:Theme.Background
$statusPanel.Margin = New-Object System.Windows.Forms.Padding(0)
$setupLayout.Controls.Add($statusPanel, 0, 2)

$script:progressBar = New-Object System.Windows.Forms.ProgressBar
$script:progressBar.Dock = 'Right'
$script:progressBar.Width = 240
$script:progressBar.Style = 'Continuous'
$statusPanel.Controls.Add($script:progressBar)

$script:lblStatus = New-Object System.Windows.Forms.Label
$script:lblStatus.Dock = 'Fill'
$script:lblStatus.Font = New-Object System.Drawing.Font('Segoe UI', 9)
$script:lblStatus.ForeColor = $script:Theme.Muted
$script:lblStatus.Text = 'Ready. Detect Counter-Strike: Source and choose what to install.'
$statusPanel.Controls.Add($script:lblStatus)

$script:GmConfig = Normalize-GmConfig
$script:GmSession = Normalize-GmSession

$killLayout = New-Object System.Windows.Forms.TableLayoutPanel
$killLayout.Dock = 'Fill'
$killLayout.ColumnCount = 1
$killLayout.RowCount = 2
[void]$killLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$killLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 54)))
$killTab.Controls.Add($killLayout)

$script:lvKill = New-GmListView
[void]$script:lvKill.Columns.Add('Process', 220)
[void]$script:lvKill.Columns.Add('Count', 90)
[void]$script:lvKill.Columns.Add('Memory MB', 120)
[void]$script:lvKill.Columns.Add('Details', 540)
Enable-ListViewSorting -ListView $script:lvKill
$killLayout.Controls.Add($script:lvKill, 0, 0)

$killActions = New-Object System.Windows.Forms.FlowLayoutPanel
$killActions.Dock = 'Fill'
$killActions.Padding = New-Object System.Windows.Forms.Padding(10, 8, 10, 8)
$killActions.WrapContents = $true
$killActions.BackColor = $script:Theme.Panel
$killLayout.Controls.Add($killActions, 0, 1)

$btnKillRefresh = New-ActionButton -Text 'Refresh' -BackColor $script:Theme.SurfaceAlt
$btnKillRefresh.Width = 90
$btnKillRefresh.Add_Click({ Refresh-GmScan })
$killActions.Controls.Add($btnKillRefresh)

$btnKillRec = New-ActionButton -Text 'Select Safe' -BackColor $script:Theme.AccentMuted
$btnKillRec.Width = 160
$btnKillRec.Add_Click({ Set-GmListChecked -ListView $script:lvKill -Mode 'Safe' })
$killActions.Controls.Add($btnKillRec)

$btnKillAll = New-ActionButton -Text 'All' -BackColor $script:Theme.SurfaceAlt
$btnKillAll.Width = 60
$btnKillAll.Add_Click({ Set-GmListChecked -ListView $script:lvKill -Mode 'All' })
$killActions.Controls.Add($btnKillAll)

$btnKillNone = New-ActionButton -Text 'None' -BackColor $script:Theme.SurfaceAlt
$btnKillNone.Width = 60
$btnKillNone.Add_Click({ Set-GmListChecked -ListView $script:lvKill -Mode 'None' })
$killActions.Controls.Add($btnKillNone)

$btnKillSelected = New-ActionButton -Text 'Close Selected' -BackColor $script:Theme.Warning -ForeColor ([System.Drawing.Color]::Black)
$btnKillSelected.Width = 130
$btnKillSelected.Add_Click({ Invoke-GmKillSelected })
$killActions.Controls.Add($btnKillSelected)

$servicesLayout = New-Object System.Windows.Forms.TableLayoutPanel
$servicesLayout.Dock = 'Fill'
$servicesLayout.ColumnCount = 1
$servicesLayout.RowCount = 2
[void]$servicesLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$servicesLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 54)))
$servicesTab.Controls.Add($servicesLayout)

$script:lvGmServices = New-GmListView
[void]$script:lvGmServices.Columns.Add('Service', 220)
[void]$script:lvGmServices.Columns.Add('Display Name', 300)
[void]$script:lvGmServices.Columns.Add('Startup', 120)
[void]$script:lvGmServices.Columns.Add('Not Recommended', 220)
Enable-ListViewSorting -ListView $script:lvGmServices
$servicesLayout.Controls.Add($script:lvGmServices, 0, 0)

$servicesActions = New-Object System.Windows.Forms.FlowLayoutPanel
$servicesActions.Dock = 'Fill'
$servicesActions.Padding = New-Object System.Windows.Forms.Padding(10, 8, 10, 8)
$servicesActions.BackColor = $script:Theme.Panel
$servicesLayout.Controls.Add($servicesActions, 0, 1)

$btnServicesRefresh = New-ActionButton -Text 'Refresh' -BackColor $script:Theme.SurfaceAlt
$btnServicesRefresh.Width = 90
$btnServicesRefresh.Add_Click({ Refresh-GmScan })
$servicesActions.Controls.Add($btnServicesRefresh)

$btnServicesRec = New-ActionButton -Text 'Select Safe' -BackColor $script:Theme.AccentMuted
$btnServicesRec.Width = 160
$btnServicesRec.Add_Click({ Set-GmListChecked -ListView $script:lvGmServices -Mode 'Safe' })
$servicesActions.Controls.Add($btnServicesRec)

$btnServicesAll = New-ActionButton -Text 'All' -BackColor $script:Theme.SurfaceAlt
$btnServicesAll.Width = 60
$btnServicesAll.Add_Click({ Set-GmListChecked -ListView $script:lvGmServices -Mode 'All' })
$servicesActions.Controls.Add($btnServicesAll)

$btnServicesNone = New-ActionButton -Text 'None' -BackColor $script:Theme.SurfaceAlt
$btnServicesNone.Width = 60
$btnServicesNone.Add_Click({ Set-GmListChecked -ListView $script:lvGmServices -Mode 'None' })
$servicesActions.Controls.Add($btnServicesNone)

$btnStopServices = New-ActionButton -Text 'Stop Selected' -BackColor $script:Theme.Accent
$btnStopServices.Width = 130
$btnStopServices.Add_Click({ Invoke-GmStopServices })
$servicesActions.Controls.Add($btnStopServices)

$tasksLayout = New-Object System.Windows.Forms.TableLayoutPanel
$tasksLayout.Dock = 'Fill'
$tasksLayout.ColumnCount = 1
$tasksLayout.RowCount = 2
[void]$tasksLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$tasksLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 54)))
$tasksTab.Controls.Add($tasksLayout)

$script:lvGmTasks = New-GmListView
[void]$script:lvGmTasks.Columns.Add('Task', 260)
[void]$script:lvGmTasks.Columns.Add('Path', 360)
[void]$script:lvGmTasks.Columns.Add('State', 120)
[void]$script:lvGmTasks.Columns.Add('Not Recommended', 200)
Enable-ListViewSorting -ListView $script:lvGmTasks
$tasksLayout.Controls.Add($script:lvGmTasks, 0, 0)

$tasksActions = New-Object System.Windows.Forms.FlowLayoutPanel
$tasksActions.Dock = 'Fill'
$tasksActions.Padding = New-Object System.Windows.Forms.Padding(10, 8, 10, 8)
$tasksActions.BackColor = $script:Theme.Panel
$tasksLayout.Controls.Add($tasksActions, 0, 1)

$btnTasksRefresh = New-ActionButton -Text 'Refresh' -BackColor $script:Theme.SurfaceAlt
$btnTasksRefresh.Width = 90
$btnTasksRefresh.Add_Click({ Refresh-GmScan })
$tasksActions.Controls.Add($btnTasksRefresh)

$btnTasksRec = New-ActionButton -Text 'Select Safe' -BackColor $script:Theme.AccentMuted
$btnTasksRec.Width = 160
$btnTasksRec.Add_Click({ Set-GmListChecked -ListView $script:lvGmTasks -Mode 'Safe' })
$tasksActions.Controls.Add($btnTasksRec)

$btnTasksAll = New-ActionButton -Text 'All' -BackColor $script:Theme.SurfaceAlt
$btnTasksAll.Width = 60
$btnTasksAll.Add_Click({ Set-GmListChecked -ListView $script:lvGmTasks -Mode 'All' })
$tasksActions.Controls.Add($btnTasksAll)

$btnTasksNone = New-ActionButton -Text 'None' -BackColor $script:Theme.SurfaceAlt
$btnTasksNone.Width = 60
$btnTasksNone.Add_Click({ Set-GmListChecked -ListView $script:lvGmTasks -Mode 'None' })
$tasksActions.Controls.Add($btnTasksNone)

$btnDisableTasks = New-ActionButton -Text 'Disable Selected' -BackColor $script:Theme.Accent
$btnDisableTasks.Width = 130
$btnDisableTasks.Add_Click({ Invoke-GmDisableTasks })
$tasksActions.Controls.Add($btnDisableTasks)

$tweaksLayout = New-Object System.Windows.Forms.TableLayoutPanel
$tweaksLayout.Dock = 'Fill'
$tweaksLayout.ColumnCount = 1
$tweaksLayout.RowCount = 2
[void]$tweaksLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$tweaksLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 60)))
$tweaksTab.Controls.Add($tweaksLayout)

$tweaksPanel = New-Object System.Windows.Forms.Panel
$tweaksPanel.Dock = 'Fill'
$tweaksPanel.BackColor = $script:Theme.Surface
$tweaksPanel.Padding = New-Object System.Windows.Forms.Padding(20, 18, 20, 18)
$tweaksLayout.Controls.Add($tweaksPanel, 0, 0)

$script:chkGmPower = New-Object System.Windows.Forms.CheckBox
$script:chkGmPower.Text = 'Switch to a LamaTeam Setup power scheme'
$script:chkGmPower.AutoSize = $true
$script:chkGmPower.Location = New-Object System.Drawing.Point(16, 18)
$script:chkGmPower.Checked = $script:GmConfig.EnabledTweaks -contains 'Power'
$script:chkGmPower.ForeColor = $script:Theme.Foreground
$tweaksPanel.Controls.Add($script:chkGmPower)

$script:chkGmNetwork = New-Object System.Windows.Forms.CheckBox
$script:chkGmNetwork.Text = 'Apply low-latency network registry values'
$script:chkGmNetwork.AutoSize = $true
$script:chkGmNetwork.Location = New-Object System.Drawing.Point(16, 48)
$script:chkGmNetwork.Checked = $script:GmConfig.EnabledTweaks -contains 'Network'
$script:chkGmNetwork.ForeColor = $script:Theme.Foreground
$tweaksPanel.Controls.Add($script:chkGmNetwork)

$script:chkGmGameDvr = New-Object System.Windows.Forms.CheckBox
$script:chkGmGameDvr.Text = 'Disable Xbox Game DVR capture overhead'
$script:chkGmGameDvr.AutoSize = $true
$script:chkGmGameDvr.Location = New-Object System.Drawing.Point(16, 78)
$script:chkGmGameDvr.Checked = $script:GmConfig.EnabledTweaks -contains 'GameDvr'
$script:chkGmGameDvr.ForeColor = $script:Theme.Foreground
$tweaksPanel.Controls.Add($script:chkGmGameDvr)

$script:chkGmDns = New-Object System.Windows.Forms.CheckBox
$script:chkGmDns.Text = 'Flush DNS cache before joining'
$script:chkGmDns.AutoSize = $true
$script:chkGmDns.Location = New-Object System.Drawing.Point(16, 108)
$script:chkGmDns.Checked = $script:GmConfig.EnabledTweaks -contains 'Dns'
$script:chkGmDns.ForeColor = $script:Theme.Foreground
$tweaksPanel.Controls.Add($script:chkGmDns)

$script:chkGmAutoConnect = New-Object System.Windows.Forms.CheckBox
$script:chkGmAutoConnect.Text = ("Connect to {0} after apply" -f $script:ServerAddress)
$script:chkGmAutoConnect.AutoSize = $true
$script:chkGmAutoConnect.Location = New-Object System.Drawing.Point(16, 138)
$script:chkGmAutoConnect.Checked = [bool]$script:GmConfig.AutoConnect
$script:chkGmAutoConnect.ForeColor = $script:Theme.Foreground
$tweaksPanel.Controls.Add($script:chkGmAutoConnect)

$tweaksActions = New-Object System.Windows.Forms.FlowLayoutPanel
$tweaksActions.Dock = 'Fill'
$tweaksActions.Padding = New-Object System.Windows.Forms.Padding(10, 8, 10, 8)
$tweaksActions.BackColor = $script:Theme.Panel
$tweaksLayout.Controls.Add($tweaksActions, 0, 1)

$btnTweaksRefresh = New-ActionButton -Text 'Refresh' -BackColor $script:Theme.SurfaceAlt
$btnTweaksRefresh.Width = 110
$btnTweaksRefresh.Add_Click({ Refresh-GmScan })
$tweaksActions.Controls.Add($btnTweaksRefresh)

$btnApplyTweaks = New-ActionButton -Text 'Apply LamaTeam Setup' -BackColor $script:Theme.Accent
$btnApplyTweaks.Width = 180
$btnApplyTweaks.Add_Click({ Apply-GmTweaks })
$tweaksActions.Controls.Add($btnApplyTweaks)

$btnRestoreTweaks = New-ActionButton -Text 'Restore Session' -BackColor $script:Theme.SurfaceAlt
$btnRestoreTweaks.Width = 150
$btnRestoreTweaks.Add_Click({ Restore-GmSession })
$tweaksActions.Controls.Add($btnRestoreTweaks)

$script:chkAutoexec.Add_CheckedChanged({ Save-SetupConfig })
$script:chkMenu.Add_CheckedChanged({ Save-SetupConfig })
$script:chkMaps.Add_CheckedChanged({ Save-SetupConfig })
$script:chkGamingMode.Add_CheckedChanged({ Save-SetupConfig })
$script:chkConnectAfter.Add_CheckedChanged({ Save-SetupConfig })
$script:chkGmPower.Add_CheckedChanged({ Save-GmConfigFromUi })
$script:chkGmNetwork.Add_CheckedChanged({ Save-GmConfigFromUi })
$script:chkGmGameDvr.Add_CheckedChanged({ Save-GmConfigFromUi })
$script:chkGmDns.Add_CheckedChanged({ Save-GmConfigFromUi })
$script:chkGmAutoConnect.Add_CheckedChanged({ Save-GmConfigFromUi })

$applyResponsiveColumns = {
    Set-GmResponsiveColumns -ListView $script:lvKill -BaseWidths @(230, 90, 120, 560) -MinimumWidths @(150, 70, 90, 180)
    Set-GmResponsiveColumns -ListView $script:lvGmServices -BaseWidths @(220, 320, 120, 220) -MinimumWidths @(130, 170, 90, 120)
    Set-GmResponsiveColumns -ListView $script:lvGmTasks -BaseWidths @(260, 360, 120, 200) -MinimumWidths @(140, 180, 80, 120)
}

$setupForm.Add_SizeChanged({
    Update-SetupLayout
    & $applyResponsiveColumns
})
$setupForm.Add_Shown({
        Update-SetupLayout
        & $applyResponsiveColumns
        Refresh-GmScan
        
        $script:lvKill.Add_Resize({ & $applyResponsiveColumns })
        $script:lvGmServices.Add_Resize({ & $applyResponsiveColumns })
        $script:lvGmTasks.Add_Resize({ & $applyResponsiveColumns })

    $screenDir = [Environment]::GetEnvironmentVariable('LAMA_TEAM_SCREENSHOT_DIR')
    if ($screenDir) {
        $screenTimer = New-Object System.Windows.Forms.Timer
        $screenTimer.Interval = 2000
        $screenTimer.Add_Tick({
            param($sender, $e)
            $sender.Stop()
            $sender.Dispose()
            try {
                $waitUntil = (Get-Date).AddSeconds(6)
                do {
                    Refresh-GmScan
                    [System.Windows.Forms.Application]::DoEvents()
                    if ($script:lvGmServices.Items.Count -gt 0 -or $script:lvGmTasks.Items.Count -gt 0) { break }
                    Start-Sleep -Milliseconds 300
                } while ((Get-Date) -lt $waitUntil)

                $tabsToCapture = @(
                    @{ Name = 'setup-tab.png'; Tab = $setupTab },
                    @{ Name = 'kill-tab.png'; Tab = $killTab },
                    @{ Name = 'services-tab.png'; Tab = $servicesTab },
                    @{ Name = 'tasks-tab.png'; Tab = $tasksTab },
                    @{ Name = 'tweaks-tab.png'; Tab = $tweaksTab }
                )
                foreach ($entry in $tabsToCapture) {
                    $topTabs.SelectedTab = $entry.Tab
                    [System.Windows.Forms.Application]::DoEvents()
                    Start-Sleep -Milliseconds 400
                    Save-ControlScreenshot -Control $setupForm -Path (Join-Path $screenDir $entry.Name)
                }
                $topTabs.SelectedTab = $setupTab
                Write-SetupLog -Message ('Saved UI screenshots to: {0}' -f $screenDir)
            }
            catch {
                Write-SetupLog -Message ('Failed to save UI screenshots: {0}' -f $_.Exception.Message) -Color $script:Theme.Warning
            }
        })
        $screenTimer.Start()
    }

    if ($script:AutoInstallPreview -and $script:DetectedDirs) {
        $installTimer = New-Object System.Windows.Forms.Timer
        $installTimer.Interval = 450
        $installTimer.Add_Tick({
            param($sender, $e)
            $sender.Stop()
            $sender.Dispose()
            Run-Installer -Dirs $script:DetectedDirs
        })
        $installTimer.Start()
    }

    if ($PSBoundParameters['GamingMode']) {
        $topTabs.SelectedTab = $killTab
        $main.Visible = $false
        $actions.Visible = $false
        $statusPanel.Visible = $false
        $setupForm.Text = 'LamaTeam Setup Pro'
    }

    if ($script:AutoCloseAfterSeconds -gt 0) {
        $closeTimer = New-Object System.Windows.Forms.Timer
        $closeTimer.Interval = $script:AutoCloseAfterSeconds * 1000
        $closeTimer.Add_Tick({
            param($sender, $e)
            $sender.Stop()
            $sender.Dispose()
            if (-not $script:IsBusy) {
                $setupForm.Close()
            }
        })
        $closeTimer.Start()
    }
})
$setupForm.Add_FormClosing({
    param($sender, $e)

    if ($script:IsBusy) {
        $e.Cancel = $true
        Write-SetupLog -Message 'Wait for setup to finish before closing this window.' -Color $script:Theme.Warning
        return
    }

    if ($script:GmScanInitialized) {
        Save-GmConfigFromUi
    }
    Save-SetupConfig
})
Update-SetupLayout
Write-SetupLog -Message 'Ready. Starting automatic detection.'
Detect-CSSInstall

[void]$setupForm.ShowDialog()
