#Requires -Version 7.4
param(
    [string]$Commit,
    [string]$LocalRoot
)

$ErrorActionPreference = 'Stop'
$script:LamaModuleVersion = '0.14.0'
$script:LamaApiBase = 'https://api.github.com/repos/musosoft/css-cfg'
$script:LamaRawBase = 'https://raw.githubusercontent.com/musosoft/css-cfg'

function Get-LamaGitBlobHash {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    $prefix = [Text.Encoding]::ASCII.GetBytes(('blob {0}' -f $Bytes.Length) + [char]0)
    $data = [byte[]]::new($prefix.Length + $Bytes.Length)
    [Buffer]::BlockCopy($prefix, 0, $data, 0, $prefix.Length)
    [Buffer]::BlockCopy($Bytes, 0, $data, $prefix.Length, $Bytes.Length)
    $sha = [Security.Cryptography.SHA1]::Create()
    try { return ([Convert]::ToHexString($sha.ComputeHash($data))).ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Get-LamaPackageRoot {
    $files = @(
        'LamaTeam.App.ps1', 'autoexec.cfg', 'gamemenu.res',
        'core/CssCfg.Core.psd1', 'core/CssCfg.Core.psm1',
        'core/CssCfg.Network.ps1', 'core/CssCfg.Cleanup.ps1', 'core/CssCfg.Process.ps1',
        'core/CssCfg.Media.ps1', 'core/CssCfg.SteamDisplay.ps1', 'core/LamaTeam.Api.ps1',
        'core/assets/Legacy-2016/autoexec.cfg'
    )
    # Direct invocation from a checkout should work without setup.ps1 supplying -LocalRoot.
    # A commit-pinned remote handoff must never silently switch to adjacent local code.
    $candidateRoot = $LocalRoot
    if (-not $candidateRoot -and -not $Commit -and $PSScriptRoot -and
        (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'LamaTeam.App.ps1') -PathType Leaf)) { $candidateRoot = $PSScriptRoot }
    if ($candidateRoot) {
        $candidateRoot = [IO.Path]::GetFullPath($candidateRoot)
        $missing = @($files | Where-Object { -not (Test-Path -LiteralPath (Join-Path $candidateRoot $_) -PathType Leaf) })
        if ($missing.Count) { throw "Local app package is incomplete: $($missing -join ', '). Restore the checkout files and retry; no remote fallback was loaded." }
        Write-Host 'Using local app files from the checkout.'
        return $candidateRoot
    }

    if ($Commit -notmatch '^[0-9a-f]{40}$') { throw 'The setup launcher did not provide a valid immutable GitHub commit.' }
    $headers = @{ 'User-Agent' = 'LamaTeam-CS-S-Setup'; 'Accept' = 'application/vnd.github+json' }
    $treeReply = Invoke-RestMethod -Uri ($script:LamaApiBase + '/git/trees/' + $Commit + '?recursive=1') -Headers $headers -Method Get -TimeoutSec 30
    if ($treeReply.truncated) { throw 'GitHub file manifest was truncated; setup stopped without loading partial app files.' }
    $cacheRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) ('LamaTeam/CssCfg/' + $Commit)
    if (Test-Path -LiteralPath $cacheRoot -PathType Container) {
        foreach ($relative in $files) {
            $entry = $treeReply.tree | Where-Object { $_.path -ceq $relative -and $_.type -ceq 'blob' } | Select-Object -First 1
            $cached = Join-Path $cacheRoot ($relative -replace '/', [IO.Path]::DirectorySeparatorChar)
            if (-not $entry -or -not (Test-Path -LiteralPath $cached -PathType Leaf) -or
                (Get-LamaGitBlobHash ([IO.File]::ReadAllBytes($cached)) -cne $entry.sha)) {
                throw 'Cached app files failed Git blob integrity validation. Nothing was overwritten; clear the LamaTeam app cache manually and retry.'
            }
        }
        return $cacheRoot
    }

    $stage = $cacheRoot + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    [void][IO.Directory]::CreateDirectory($stage)
    try {
        foreach ($relative in $files) {
            $entry = $treeReply.tree | Where-Object { $_.path -ceq $relative -and $_.type -ceq 'blob' } | Select-Object -First 1
            if (-not $entry) { throw ("Required app asset missing from commit {0}: {1}" -f $Commit, $relative) }
            if ([long]$entry.size -le 0 -or [long]$entry.size -gt 5000000) { throw ("Unexpected asset size in repository manifest: {0}" -f $relative) }
            $destination = Join-Path $stage ($relative -replace '/', [IO.Path]::DirectorySeparatorChar)
            [void][IO.Directory]::CreateDirectory((Split-Path -Parent $destination))
            $uri = '{0}/{1}/{2}' -f $script:LamaRawBase, $Commit, $relative
            Invoke-WebRequest -Uri $uri -OutFile ($destination + '.part') -Method Get -UseBasicParsing -MaximumRedirection 0 -TimeoutSec 60
            $bytes = [IO.File]::ReadAllBytes($destination + '.part')
            if ($bytes.Length -ne [long]$entry.size -or (Get-LamaGitBlobHash $bytes) -cne $entry.sha) {
                throw ("Downloaded asset failed Git blob integrity validation: {0}" -f $relative)
            }
            [IO.File]::Move($destination + '.part', $destination)
        }
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $cacheRoot))
        [IO.Directory]::Move($stage, $cacheRoot)
        return $cacheRoot
    } catch {
        if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
        throw
    }
}

function Test-LamaAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try {
        $principal = [Security.Principal.WindowsPrincipal]::new($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } finally { $identity.Dispose() }
}

function Start-LamaElevated {
    $pwsh = (Get-Process -Id $PID -ErrorAction Stop).Path
    if (-not $pwsh) { throw 'PowerShell executable path could not be determined for elevation.' }
    $childArgs = @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$PSCommandPath)
    if ($Commit) { $childArgs += @('-Commit',$Commit) }
    if ($LocalRoot) { $childArgs += @('-LocalRoot',$LocalRoot) }
    $quotedArgs = foreach ($arg in $childArgs) { '"' + ([string]$arg).Replace('"','\"') + '"' }
    $child = Start-Process -FilePath $pwsh -ArgumentList ($quotedArgs -join ' ') -Verb RunAs -Wait -PassThru
    if ($child.ExitCode -ne 0) { throw "Administrator launcher returned exit code $($child.ExitCode)." }
}

function Ensure-LamaWinUIShell {
    $module = Get-Module -ListAvailable WinUIShell | Where-Object { $_.Version -eq [version]$script:LamaModuleVersion } | Select-Object -First 1
    if ($module) { return }

    Write-Host 'WinUIShell 0.14.0 is MIT-licensed, about 17 MB, and is still marked as a prototype. It will be installed for the current user from PowerShell Gallery.'
    $answer = Read-Host 'Type Y to install WinUIShell 0.14.0 and continue, or N to cancel'
    if ($answer -notmatch '^(?i:y|yes)$') { throw 'WinUIShell installation cancelled. No game or system files were changed.' }

    if (Get-Command Install-PSResource -ErrorAction SilentlyContinue) {
        Install-PSResource -Name WinUIShell -Version $script:LamaModuleVersion -Scope CurrentUser -Repository PSGallery -TrustRepository -ErrorAction Stop
    } elseif (Get-Command Install-Module -ErrorAction SilentlyContinue) {
        Install-Module -Name WinUIShell -RequiredVersion $script:LamaModuleVersion -Scope CurrentUser -Repository PSGallery -Force -Confirm:$false -ErrorAction Stop
    } else {
        throw 'PowerShellGet/PSResourceGet is unavailable. Install WinUIShell 0.14.0 from https://www.powershellgallery.com/packages/WinUIShell/0.14.0 and rerun.'
    }
    $module = Get-Module -ListAvailable WinUIShell | Where-Object { $_.Version -eq [version]$script:LamaModuleVersion } | Select-Object -First 1
    if (-not $module) { throw 'WinUIShell installation did not provide the pinned 0.14.0 module. No fallback framework was used.' }
}

try {
    if (-not (Test-LamaAdministrator)) {
        Start-LamaElevated
        return
    }
    $packageRoot = Get-LamaPackageRoot
    Ensure-LamaWinUIShell
    Import-Module WinUIShell -RequiredVersion $script:LamaModuleVersion -ErrorAction Stop
    Import-Module (Join-Path $packageRoot 'core/CssCfg.Core.psd1') -Force -ErrorAction Stop
    . (Join-Path $packageRoot 'LamaTeam.App.ps1')
    Start-LamaTeamApp
} catch {
    Write-Host ("LamaTeam Setup could not start: {0}" -f $_.Exception.Message) -ForegroundColor Red
    Write-Host 'No fallback UI was launched. Review the message, check network/module requirements, and retry.' -ForegroundColor Yellow
    throw
}
