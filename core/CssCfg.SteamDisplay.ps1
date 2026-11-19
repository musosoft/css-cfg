# Steam app 240 launch-options persistence and safe display-rate selection.
# Importing this file has no Windows, filesystem, or process side effects.
function Get-CssVdfTokens {
    param([Parameter(Mandatory)][string]$Text)
    foreach ($match in [regex]::Matches($Text, '(?m)//[^\r\n]*|"(?:\\.|[^"\\])*"|[{}]')) {
        if ($match.Value.StartsWith('//')) { continue }
        $value = $match.Value
        if ($value.StartsWith('"')) {
            $value = [regex]::Replace($value.Substring(1, $value.Length - 2), '\\(.)', '$1')
            [pscustomobject]@{ Kind = 'String'; Value = $value; Index = $match.Index; Length = $match.Length }
        } elseif ($value -eq '{') {
            [pscustomobject]@{ Kind = 'Open'; Value = $null; Index = $match.Index; Length = 1 }
        } else {
            [pscustomobject]@{ Kind = 'Close'; Value = $null; Index = $match.Index; Length = 1 }
        }
    }
}

function Get-CssVdfApp240Section {
    param([Parameter(Mandatory)][string]$Text)
    $tokens = @(Get-CssVdfTokens $Text)
    $stack = [Collections.Generic.List[string]]::new()
    $appsClose = $null
    $appOpen = $null
    $appClose = $null
    $launchValue = $null
    for ($i = 0; $i -lt $tokens.Count; $i++) {
        $token = $tokens[$i]
        if ($token.Kind -eq 'Close') {
            if ($stack.Count -ge 2 -and $stack[$stack.Count - 1] -eq '240' -and $stack[$stack.Count - 2] -eq 'apps') {
                $appClose = $i
            }
            if ($stack.Count -ge 1 -and $stack[$stack.Count - 1] -eq 'apps') { $appsClose = $i }
            if ($stack.Count) { $stack.RemoveAt($stack.Count - 1) }
            continue
        }
        if ($token.Kind -ne 'String' -or $i + 1 -ge $tokens.Count) { continue }
        $next = $tokens[$i + 1]
        if ($next.Kind -eq 'Open') {
            if ($stack.Count -ge 1 -and $stack[$stack.Count - 1] -eq 'apps' -and $token.Value -eq '240') {
                if ($null -ne $appOpen) { throw 'Steam config contains duplicate app 240 sections.' }
                $appOpen = $i + 1
            }
            $stack.Add([string]$token.Value)
            $i++
            continue
        }
        if ($token.Value -eq 'LaunchOptions' -and $stack.Count -ge 2 -and
            $stack[$stack.Count - 1] -eq '240' -and $stack[$stack.Count - 2] -eq 'apps' -and
            $next.Kind -eq 'String') {
            if ($null -ne $launchValue) { throw 'Steam config contains duplicate app 240 LaunchOptions values.' }
            $launchValue = $i + 1
            $i++
        } else {
            $i++
        }
    }
    [pscustomobject]@{ Tokens = $tokens; AppsClose = $appsClose; AppOpen = $appOpen; AppClose = $appClose; LaunchValue = $launchValue }
}

function Get-CssSteamLaunchOptionsFromText {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Text)
    $section = Get-CssVdfApp240Section $Text
    $value = if ($null -ne $section.LaunchValue) { [string]$section.Tokens[$section.LaunchValue].Value } else { '' }
    [pscustomobject]@{
        Options = $value
        Exists = ($null -ne $section.AppOpen)
        AppsClose = $section.AppsClose
        AppOpen = $section.AppOpen
        AppClose = $section.AppClose
        LaunchValue = $section.LaunchValue
        Tokens = $section.Tokens
    }
}

function Resolve-CssSteamUserConfig {
    [CmdletBinding()]
    param([string]$SteamRoot)
    if (-not $SteamRoot) {
        foreach ($key in @('HKCU:\Software\Valve\Steam','HKLM:\SOFTWARE\Wow6432Node\Valve\Steam','HKLM:\SOFTWARE\Valve\Steam')) {
            try {
                $entry = Get-ItemProperty -LiteralPath $key -ErrorAction Stop
                foreach ($property in @('SteamPath','InstallPath')) {
                    if ($entry.$property -and (Test-Path -LiteralPath $entry.$property -PathType Container)) {
                        $SteamRoot = [string]$entry.$property
                        break
                    }
                }
            } catch { }
            if ($SteamRoot) { break }
        }
    }
    if (-not $SteamRoot -or -not (Test-Path -LiteralPath $SteamRoot -PathType Container)) {
        throw 'Steam installation folder could not be located.'
    }
    $userData = Join-Path $SteamRoot 'userdata'
    $configs = @(
        Get-ChildItem -LiteralPath $userData -Directory -ErrorAction SilentlyContinue |
            ForEach-Object { Join-Path $_.FullName 'config/localconfig.vdf' } |
            Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }
    )
    if (-not $configs.Count) { throw 'No Steam user localconfig.vdf was found.' }
    if ($configs.Count -eq 1) { return [IO.Path]::GetFullPath($configs[0]) }

    $activeAccount = $null
    $loginUsers = Join-Path $SteamRoot 'config/loginusers.vdf'
    if (Test-Path -LiteralPath $loginUsers -PathType Leaf) {
        $loginText = [IO.File]::ReadAllText($loginUsers)
        $match = [regex]::Match($loginText, '(?s)"(?<steamid>765\d{14})"\s*\{(?:(?!\}).)*?"MostRecent"\s*"1"')
        if ($match.Success) {
            try { $activeAccount = ([uint64]$match.Groups['steamid'].Value - [uint64]76561197960265728).ToString() } catch { }
        }
    }
    if ($activeAccount) {
        $activeConfig = Join-Path $userData "$activeAccount/config/localconfig.vdf"
        if (Test-Path -LiteralPath $activeConfig -PathType Leaf) { return [IO.Path]::GetFullPath($activeConfig) }
    }
    throw 'Multiple Steam accounts were found and the active account could not be identified safely.'
}

function Get-CssSteamLaunchOptions {
    [CmdletBinding()]
    param([string]$SteamRoot, [string]$ConfigPath)
    if (-not $ConfigPath) { $ConfigPath = Resolve-CssSteamUserConfig -SteamRoot $SteamRoot }
    $bytes = [IO.File]::ReadAllBytes($ConfigPath)
    if ($bytes.Length -ge 2 -and (($bytes[0] -eq 255 -and $bytes[1] -eq 254) -or ($bytes[0] -eq 254 -and $bytes[1] -eq 255))) {
        throw 'Steam config uses unsupported UTF-16 encoding; no changes were made.'
    }
    $text = [IO.File]::ReadAllText($ConfigPath)
    $parsed = Get-CssSteamLaunchOptionsFromText $text
    [pscustomobject]@{ ConfigPath = [IO.Path]::GetFullPath($ConfigPath); Options = $parsed.Options }
}

function Set-CssSteamLaunchOptions {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ConfigPath, [Parameter(Mandatory)][AllowEmptyString()][string]$Options,
        [string]$BackupDirectory)
    if ($Options.Length -gt 256 -or $Options -match '[^\x20-\x7E]') {
        throw 'Steam launch options exceed 256 printable ASCII characters.'
    }
    $bytes = [IO.File]::ReadAllBytes($ConfigPath)
    if ($bytes.Length -ge 2 -and (($bytes[0] -eq 255 -and $bytes[1] -eq 254) -or ($bytes[0] -eq 254 -and $bytes[1] -eq 255))) {
        throw 'Steam config uses unsupported UTF-16 encoding; no changes were made.'
    }
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191)
    $encoding = [Text.UTF8Encoding]::new($hasBom)
    $text = $encoding.GetString($bytes)
    $parsed = Get-CssSteamLaunchOptionsFromText $text
    if ($parsed.Options -ceq $Options) { return [pscustomobject]@{ Changed = $false; Backup = $null; ConfigPath = [IO.Path]::GetFullPath($ConfigPath) } }

    $escaped = $Options.Replace('\', '\\').Replace('"', '\"')
    $section = Get-CssVdfApp240Section $text
    $newline = if ($text.Contains("`r`n")) { "`r`n" } else { "`n" }
    if ($null -ne $section.LaunchValue) {
        $token = $section.Tokens[$section.LaunchValue]
        $text = $text.Remove($token.Index, $token.Length).Insert($token.Index, "`"$escaped`"")
    } elseif ($null -ne $section.AppClose) {
        $closeToken = $section.Tokens[$section.AppClose]
        $appToken = $section.Tokens[$section.AppOpen - 1]
        $lineStart = $text.LastIndexOf("`n", $appToken.Index)
        $prefix = $text.Substring($lineStart + 1, $appToken.Index - $lineStart - 1)
        $indent = [regex]::Match($prefix, '^[ \t]*').Value
        $insert = "$newline$indent`t`"LaunchOptions`"`t`t`"$escaped`"$newline$indent"
        $text = $text.Insert($closeToken.Index, $insert)
    } elseif ($null -ne $section.AppsClose) {
        $closeToken = $section.Tokens[$section.AppsClose]
        $insert = "$newline`t`t`"240`"$newline`t`t{$newline`t`t`t`"LaunchOptions`"`t`t`"$escaped`"$newline`t`t}"
        $text = $text.Insert($closeToken.Index, $insert)
    } else {
        throw 'Steam config has no apps section; no changes were made.'
    }

    $backupRoot = if ($BackupDirectory) { $BackupDirectory } else { Split-Path -Parent $ConfigPath }
    [void][IO.Directory]::CreateDirectory($backupRoot)
    $backupPath = Join-Path $backupRoot ('localconfig-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffZ') + '-' + [guid]::NewGuid().ToString('N') + '.vdf.bak')
    [IO.File]::Copy($ConfigPath, $backupPath, $false)
    try {
        Write-CssAtomicFile -Path $ConfigPath -Bytes $encoding.GetBytes($text)
        $verified = Get-CssSteamLaunchOptions -ConfigPath $ConfigPath
        if ($verified.Options -cne $Options) { throw 'Steam launch options did not verify after writing.' }
    } catch {
        [IO.File]::Copy($backupPath, $ConfigPath, $true)
        throw
    }
    [pscustomobject]@{ Changed = $true; Backup = $backupPath; ConfigPath = [IO.Path]::GetFullPath($ConfigPath) }
}

if (-not ('CssCfgDisplayNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

[StructLayout(LayoutKind.Sequential)]
public struct CssCfgPointL { public int X; public int Y; }

[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
public struct CssCfgDevMode {
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string dmDeviceName;
    public short dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra;
    public int dmFields;
    public int dmPositionX, dmPositionY, dmDisplayOrientation, dmDisplayFixedOutput;
    public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string dmFormName;
    public short dmLogPixels;
    public int dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency;
    public int dmICMMethod, dmICMIntent, dmMediaType, dmDitherType, dmReserved1, dmReserved2;
    public int dmPanningWidth, dmPanningHeight;
}

[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
public struct CssCfgDisplayDevice {
    public int cb;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string DeviceName;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string DeviceString;
    public int StateFlags;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string DeviceID;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string DeviceKey;
}

public static class CssCfgDisplayNative {
    [DllImport("user32.dll", CharSet=CharSet.Unicode, EntryPoint="EnumDisplayDevicesW")]
    public static extern bool EnumDisplayDevices(string device, uint index, ref CssCfgDisplayDevice display, uint flags);
    [DllImport("user32.dll", CharSet=CharSet.Unicode, EntryPoint="EnumDisplaySettingsExW")]
    public static extern bool EnumDisplaySettings(string device, int mode, ref CssCfgDevMode devMode, uint flags);
    [DllImport("user32.dll", CharSet=CharSet.Unicode, EntryPoint="ChangeDisplaySettingsExW")]
    public static extern int ChangeDisplaySettings(string device, ref CssCfgDevMode devMode, IntPtr hwnd, uint flags, IntPtr param);
}
'@
}

function Get-CssDisplayRefreshInfo {
    [CmdletBinding()]
    param()
    if (-not $IsWindows) { throw 'Display refresh-rate inspection is only supported on Windows.' }
    $attached = 0x1; $primary = 0x4; $test = 0x2
    $size = [Runtime.InteropServices.Marshal]::SizeOf([type][CssCfgDevMode])
    $displaySize = [Runtime.InteropServices.Marshal]::SizeOf([type][CssCfgDisplayDevice])
    for ($i = 0; $i -lt 32; $i++) {
        $device = [CssCfgDisplayDevice]::new(); $device.cb = $displaySize
        if (-not [CssCfgDisplayNative]::EnumDisplayDevices($null, [uint32]$i, [ref]$device, 0)) { break }
        if (($device.StateFlags -band $attached) -eq 0) { continue }
        $current = [CssCfgDevMode]::new(); $current.dmSize = [int16]$size
        if (-not [CssCfgDisplayNative]::EnumDisplaySettings($device.DeviceName, -1, [ref]$current, 0)) { continue }
        $best = $null
        for ($modeIndex = 0; $modeIndex -lt 4096; $modeIndex++) {
            $mode = [CssCfgDevMode]::new(); $mode.dmSize = [int16]$size
            if (-not [CssCfgDisplayNative]::EnumDisplaySettings($device.DeviceName, $modeIndex, [ref]$mode, 0)) { break }
            if ($mode.dmPelsWidth -ne $current.dmPelsWidth -or $mode.dmPelsHeight -ne $current.dmPelsHeight -or
                $mode.dmBitsPerPel -ne $current.dmBitsPerPel -or $mode.dmDisplayOrientation -ne $current.dmDisplayOrientation -or
                $mode.dmDisplayFrequency -le 0) { continue }
            if ($null -eq $best -or $mode.dmDisplayFrequency -gt $best.dmDisplayFrequency) { $best = $mode }
        }
        $maxHz = if ($best) { [int]$best.dmDisplayFrequency } else { [int]$current.dmDisplayFrequency }
        $supported = $false
        if ($best) { $supported = ([CssCfgDisplayNative]::ChangeDisplaySettings($device.DeviceName, [ref]$best, [IntPtr]::Zero, $test, [IntPtr]::Zero) -eq 0) }
        [pscustomobject]@{
            DeviceName = [string]$device.DeviceName; DisplayName = [string]$device.DeviceString
            IsPrimary = (($device.StateFlags -band $primary) -ne 0)
            Width = [int]$current.dmPelsWidth; Height = [int]$current.dmPelsHeight
            CurrentHz = [int]$current.dmDisplayFrequency; MaxHz = $maxHz
            Available = ($supported -and $maxHz -ge $current.dmDisplayFrequency)
        }
    }
}

function Set-CssDisplayRefreshRate {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DeviceName, [Parameter(Mandatory)][ValidateRange(1,1000)][int]$RefreshRate)
    if (-not $IsWindows) { throw 'Display refresh-rate changes are only supported on Windows.' }
    $info = @(Get-CssDisplayRefreshInfo | Where-Object DeviceName -CEQ $DeviceName)
    if ($info.Count -ne 1 -or -not $info[0].Available -or $info[0].MaxHz -ne $RefreshRate) {
        throw 'The selected monitor or its maximum refresh rate changed; no display setting was applied.'
    }
    if ($info[0].CurrentHz -eq $RefreshRate) { return [pscustomobject]@{ Changed=$false; CurrentHz=$RefreshRate; MaxHz=$RefreshRate } }
    $size = [Runtime.InteropServices.Marshal]::SizeOf([type][CssCfgDevMode])
    $mode = [CssCfgDevMode]::new(); $mode.dmSize = [int16]$size
    if (-not [CssCfgDisplayNative]::EnumDisplaySettings($DeviceName, -1, [ref]$mode, 0)) { throw 'Current display mode could not be re-read.' }
    $mode.dmDisplayFrequency = $RefreshRate
    $mode.dmFields = 0x00400000
    if ([CssCfgDisplayNative]::ChangeDisplaySettings($DeviceName, [ref]$mode, [IntPtr]::Zero, 0x2, [IntPtr]::Zero) -ne 0) {
        throw 'Windows rejected the maximum refresh rate during its test; no display setting was changed.'
    }
    $result = [CssCfgDisplayNative]::ChangeDisplaySettings($DeviceName, [ref]$mode, [IntPtr]::Zero, 0x1, [IntPtr]::Zero)
    if ($result -ne 0) { throw "Windows could not apply the selected refresh rate (display result $result)." }
    $after = [CssCfgDevMode]::new(); $after.dmSize = [int16]$size
    if (-not [CssCfgDisplayNative]::EnumDisplaySettings($DeviceName, -1, [ref]$after, 0) -or $after.dmDisplayFrequency -ne $RefreshRate) {
        throw 'The new monitor refresh rate could not be verified.'
    }
    [pscustomobject]@{ Changed=$true; CurrentHz=[int]$after.dmDisplayFrequency; MaxHz=$RefreshRate }
}
