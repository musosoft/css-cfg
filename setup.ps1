param()

# Windows PowerShell 5.1-compatible consent bootstrap for the WinUIShell app.
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$script:LamaMinimumPowerShell = [version]'7.4.0'
$script:LamaWingetVersion = '7.4.22.0'
$script:LamaApiBase = 'https://api.github.com/repos/musosoft/css-cfg'
$script:LamaRawBase = 'https://raw.githubusercontent.com/musosoft/css-cfg'

function Test-LamaPowerShell7 {
    return ([version]$PSVersionTable.PSVersion -ge $script:LamaMinimumPowerShell)
}

function Get-LamaGitBlobHash {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    $prefix = [Text.Encoding]::ASCII.GetBytes(('blob {0}' -f $Bytes.Length) + [char]0)
    $data = New-Object byte[] ($prefix.Length + $Bytes.Length)
    [Buffer]::BlockCopy($prefix, 0, $data, 0, $prefix.Length)
    [Buffer]::BlockCopy($Bytes, 0, $data, $prefix.Length, $Bytes.Length)
    $sha = [Security.Cryptography.SHA1]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($data))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Get-LamaLauncher {
    param([string]$LocalRoot)
    if ($LocalRoot -and (Test-Path -LiteralPath (Join-Path $LocalRoot 'Launch-LamaTeam.ps1') -PathType Leaf)) {
        return [pscustomobject]@{ Path = (Join-Path $LocalRoot 'Launch-LamaTeam.ps1'); Commit = 'local'; LocalRoot = $LocalRoot; Temporary = $false }
    }

    $headers = @{ 'User-Agent' = 'LamaTeam-CS-S-Setup'; 'Accept' = 'application/vnd.github+json' }
    $commitReply = Invoke-RestMethod -Uri ($script:LamaApiBase + '/commits/main') -Headers $headers -Method Get -TimeoutSec 30
    $commit = [string]$commitReply.sha
    if ($commit -notmatch '^[0-9a-f]{40}$') { throw 'GitHub returned an invalid css-cfg commit identifier.' }
    $tree = Invoke-RestMethod -Uri ($script:LamaApiBase + '/git/trees/' + $commit + '?recursive=1') -Headers $headers -Method Get -TimeoutSec 30
    if ($tree.truncated) { throw 'GitHub file manifest was truncated; no launcher was downloaded.' }
    $entry = $tree.tree | Where-Object { $_.path -ceq 'Launch-LamaTeam.ps1' -and $_.type -ceq 'blob' } | Select-Object -First 1
    if (-not $entry -or [long]$entry.size -le 0 -or [long]$entry.size -gt 1000000) { throw 'The commit has no valid app launcher.' }

    $path = Join-Path ([IO.Path]::GetTempPath()) ('LamaTeamLauncher-' + [guid]::NewGuid().ToString('N') + '.ps1')
    try {
        $uri = '{0}/{1}/Launch-LamaTeam.ps1' -f $script:LamaRawBase, $commit
        Invoke-WebRequest -Uri $uri -OutFile ($path + '.part') -Method Get -UseBasicParsing -MaximumRedirection 0 -TimeoutSec 60
        $bytes = [IO.File]::ReadAllBytes($path + '.part')
        if ($bytes.Length -ne [long]$entry.size -or (Get-LamaGitBlobHash $bytes) -cne $entry.sha) {
            throw 'The launcher failed GitHub commit-tree integrity validation.'
        }
        [IO.File]::Move($path + '.part', $path)
        return [pscustomobject]@{ Path = $path; Commit = $commit; LocalRoot = $null; Temporary = $true }
    } catch {
        Remove-Item -LiteralPath ($path + '.part') -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        throw
    }
}

function Get-LamaPowerShellExe {
    $candidates = @()
    if ($env:ProgramFiles) { $candidates += (Join-Path $env:ProgramFiles 'PowerShell/7/pwsh.exe') }
    if (${env:ProgramFiles(x86)}) { $candidates += (Join-Path ${env:ProgramFiles(x86)} 'PowerShell/7/pwsh.exe') }
    foreach ($command in (Get-Command pwsh -CommandType Application -All -ErrorAction SilentlyContinue)) { $candidates += $command.Source }
    foreach ($candidate in ($candidates | Select-Object -Unique)) {
        if (-not $candidate -or -not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        try {
            $versionText = & $candidate -NoLogo -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' 2>$null
            $parsed = [version]'0.0'
            if ([version]::TryParse(([string]$versionText).Trim(), [ref]$parsed) -and $parsed -ge $script:LamaMinimumPowerShell) {
                return $candidate
            }
        } catch { }
    }
    return $null
}

function Invoke-LamaLauncher {
    param([Parameter(Mandatory)]$Launcher, [Parameter(Mandatory)][string]$PowerShellExe)
    # Only called after Get-LamaLauncher selects the explicit development checkout
    # or verifies the immutable release launcher. Package hashes are still checked
    # by that launcher before importing app scripts. Bypass is child-process only:
    # it also covers package imports/dot-sourcing from a UNC checkout, not the
    # initial trust prompt when setup.ps1 itself is invoked directly over UNC.
    $childArgs = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Launcher.Path, '-Commit', $Launcher.Commit)
    if ($Launcher.LocalRoot) { $childArgs += @('-LocalRoot', $Launcher.LocalRoot) }
    $quotedArgs = foreach ($arg in $childArgs) { '"' + ([string]$arg).Replace('"', '\"') + '"' }
    $child = Start-Process -FilePath $PowerShellExe -ArgumentList ($quotedArgs -join ' ') -Wait -PassThru -NoNewWindow
    if ($child.ExitCode -ne 0) { Write-Host ("LamaTeam launcher returned exit code {0}. Review its error and retry." -f $child.ExitCode) -ForegroundColor Yellow }
}

function Install-LamaPowerShell7 {
    param([string]$LocalRoot)
    $winget = Get-Command winget -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $winget) {
        Write-Host 'PowerShell 7.4+ is required. Microsoft WinGet (App Installer) was not found.' -ForegroundColor Yellow
        Write-Host 'Install PowerShell from Microsoft, then rerun the setup command:'
        Write-Host 'https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-windows'
        return $false
    }

    Write-Host 'This graphical app uses WinUIShell 0.14.0 (MIT-licensed; prototype) and requires PowerShell 7.4+.'
    Write-Host ("Install Microsoft PowerShell {0} using WinGet? Its official MSI is machine-wide and Windows may request administrator approval (UAC). The LamaTeam app requests UAC elevation before opening." -f $script:LamaWingetVersion)
    $answer = Read-Host 'Type Y to install and continue, or N to cancel'
    if ($answer -notmatch '^(?i:y|yes)$') {
        Write-Host 'Setup cancelled. No installer was started.' -ForegroundColor Yellow
        return $false
    }

    $launcher = Get-LamaLauncher -LocalRoot $LocalRoot
    $arguments = @(
        'install', '--id', 'Microsoft.PowerShell', '--exact', '--source', 'winget',
        '--version', $script:LamaWingetVersion,
        '--accept-source-agreements', '--accept-package-agreements', '--silent'
    )
    Write-Host 'Installing Microsoft.PowerShell. WinGet validates the signed manifest installer hash.'
    $process = Start-Process -FilePath $winget.Source -ArgumentList $arguments -Wait -PassThru -NoNewWindow
    if ($process.ExitCode -ne 0) {
        if ($launcher.Temporary) { Remove-Item -LiteralPath $launcher.Path -Force -ErrorAction SilentlyContinue }
        Write-Host ("PowerShell installation did not complete (WinGet exit {0}). No app or game files were changed. Check UAC/WinGet and retry." -f $process.ExitCode) -ForegroundColor Red
        return $false
    }

    $pwsh = Get-LamaPowerShellExe
    if (-not $pwsh) {
        if ($launcher.Temporary) { Remove-Item -LiteralPath $launcher.Path -Force -ErrorAction SilentlyContinue }
        Write-Host 'WinGet reported success, but PowerShell 7.4+ was not found. Open a new session or use the Microsoft install link and rerun.' -ForegroundColor Red
        return $false
    }

    try {
        Invoke-LamaLauncher -Launcher $launcher -PowerShellExe $pwsh
    } finally {
        if ($launcher.Temporary) { Remove-Item -LiteralPath $launcher.Path -Force -ErrorAction SilentlyContinue }
    }
    return $true
}

$localRoot = $null
if ($PSCommandPath -and [IO.Path]::GetFileName($PSCommandPath) -ieq 'setup.ps1') {
    $localRoot = Split-Path -Parent $PSCommandPath
}
if (-not (Test-LamaPowerShell7)) {
    try { if (-not (Install-LamaPowerShell7 -LocalRoot $localRoot)) { return } }
    catch { Write-Host ("PowerShell setup failed: {0}" -f $_.Exception.Message) -ForegroundColor Red }
    return
}

$launcher = $null
try {
    $launcher = Get-LamaLauncher -LocalRoot $localRoot
    $pwsh = Get-LamaPowerShellExe
    if (-not $pwsh) { throw 'PowerShell 7.4+ executable was not found. Open a new PowerShell session and retry.' }
    Invoke-LamaLauncher -Launcher $launcher -PowerShellExe $pwsh
} catch {
    Write-Host ("LamaTeam setup could not start: {0}" -f $_.Exception.Message) -ForegroundColor Red
    Write-Host 'No fallback framework was launched. Review the message, check network/module requirements, and retry.' -ForegroundColor Yellow
} finally {
    if ($launcher -and $launcher.Temporary) { Remove-Item -LiteralPath $launcher.Path -Force -ErrorAction SilentlyContinue }
}
