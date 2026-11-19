# Exercises package resolution and the bootstrap handoff with a mocked child; never runs WinUI or HTTP.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Join-Path ([IO.Path]::GetTempPath()) ('lama-launch-tests-' + [guid]::NewGuid().ToString('N'))
$script:checks = 0
function Assert($Condition, [string]$Message) {
    if (-not $Condition) { throw "Assertion failed: $Message" }
    $script:checks++
}
try {
    [void][IO.Directory]::CreateDirectory($root)
    $launcher = Join-Path $root 'Launch-LamaTeam.ps1'
    [IO.File]::Copy((Join-Path $PSScriptRoot '../../Launch-LamaTeam.ps1'), $launcher)
    $packageFiles = @('LamaTeam.App.ps1','autoexec.cfg','gamemenu.res','core/CssCfg.Core.psd1','core/CssCfg.Core.psm1',
        'core/CssCfg.Network.ps1','core/CssCfg.Cleanup.ps1','core/CssCfg.Process.ps1','core/CssCfg.Media.ps1','core/CssCfg.SteamDisplay.ps1',
        'core/LamaTeam.Api.ps1','core/assets/Legacy-2016/autoexec.cfg')
    foreach ($file in $packageFiles) {
        $path = Join-Path $root $file
        [void][IO.Directory]::CreateDirectory((Split-Path $path -Parent))
        [IO.File]::WriteAllText($path, 'fixture only; never imported or executed')
    }
    $testModule = New-Module -ArgumentList $launcher -ScriptBlock {
        param($Source)
        $tokens=$null; $errors=$null
        $ast=[Management.Automation.Language.Parser]::ParseFile($Source,[ref]$tokens,[ref]$errors)
        if ($errors.Count) { throw ($errors | Out-String) }
        foreach ($function in $ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]},$false)) {
            Set-Item -Path ("Function:" + $function.Name) -Value $function.Body.GetScriptBlock()
        }
        $script:LamaApiBase='https://api.github.com/repos/musosoft/css-cfg'
        function Invoke-RestMethod { throw 'TEST_HTTP_BLOCKED' }
        function Invoke-WebRequest { throw 'TEST_HTTP_BLOCKED' }
        function Resolve-TestPackage {
            param([string]$Root,[string]$Pin)
            $script:LocalRoot=$Root; $script:Commit=$Pin
            Get-LamaPackageRoot
        }
        Export-ModuleMember -Function Resolve-TestPackage
    }
    $resolved = & $testModule { Resolve-TestPackage }
    Assert ($resolved -eq $root) 'direct launcher invocation resolves its adjacent complete checkout without Commit/LocalRoot'
    $resolved = & $testModule { param($root) Resolve-TestPackage -Root $root -Pin local } $root
    Assert ($resolved -eq $root) 'setup local handoff remains supported'
    $blocked=$false
    try { $null=& $testModule { Resolve-TestPackage -Pin ('a' * 40) } } catch { $blocked=$_.Exception.Message -match 'TEST_HTTP_BLOCKED' }
    Assert $blocked 'commit-pinned remote handoff does not substitute adjacent unverified local code'
    [IO.File]::Delete((Join-Path $root 'core/CssCfg.Cleanup.ps1'))
    $blocked=$false
    try { $null=& $testModule { param($root) Resolve-TestPackage -Root $root -Pin local } $root } catch { $blocked=$_.Exception.Message -match 'incomplete.*core/CssCfg.Cleanup.ps1' }
    Assert $blocked 'partial local package fails explicitly before UI dependencies, not via an invalid commit fallback'
    $text=[IO.File]::ReadAllText($launcher)
    Assert ($text.Contains('function Test-LamaAdministrator') -and $text.Contains('function Start-LamaElevated') -and $text.Contains('-Verb RunAs')) 'launcher requests Windows administrator elevation'
    Assert ($text.LastIndexOf('if (-not (Test-LamaAdministrator))') -lt $text.LastIndexOf('$packageRoot = Get-LamaPackageRoot')) 'elevation is checked before app startup'
    Assert ($text.LastIndexOf('$packageRoot = Get-LamaPackageRoot') -lt $text.LastIndexOf('    Ensure-LamaWinUIShell')) 'package preflight precedes module installation/startup'
    $bootstrap = New-Module -ArgumentList (Join-Path $PSScriptRoot '../../setup.ps1') -ScriptBlock {
        param($Source)
        $tokens=$null; $errors=$null
        $ast=[Management.Automation.Language.Parser]::ParseFile($Source,[ref]$tokens,[ref]$errors)
        if ($errors.Count) { throw ($errors | Out-String) }
        foreach ($function in $ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst]},$false)) {
            Set-Item -Path ("Function:" + $function.Name) -Value $function.Body.GetScriptBlock()
        }
        $text=[IO.File]::ReadAllText($Source)
        $script:main=[scriptblock]::Create($text.Substring($text.LastIndexOf('$launcher = $null')))
        function Get-LamaPowerShellExe { 'mock-pwsh' }
        function Start-Process {
            param($FilePath,$ArgumentList,[switch]$Wait,[switch]$PassThru,[switch]$NoNewWindow)
            $script:captured=[pscustomobject]@{Exe=$FilePath; Args=$ArgumentList; Wait=$Wait; PassThru=$PassThru; NoNewWindow=$NoNewWindow}
            if ($script:failChild) { throw 'TEST_CHILD_FAILURE' }
            [pscustomobject]@{ExitCode=0}
        }
        function Invoke-TestHandoff {
            param($Selection,[bool]$FailChild=$false,[bool]$FailSource=$false)
            $script:selection=$Selection; $script:failChild=$FailChild; $script:failSource=$FailSource; $script:captured=$null
            function Get-LamaLauncher {
                param($LocalRoot)
                if ($script:failSource) { throw 'TEST_SOURCE_NOT_VERIFIED' }
                $script:selection
            }
            $localRoot=$Selection.LocalRoot
            & $script:main
            $script:captured
        }
        Export-ModuleMember -Function Invoke-TestHandoff,Get-LamaLauncher
    }
    $localSelection = & $bootstrap { param($root) Get-LamaLauncher -LocalRoot $root } $root
    Assert ($localSelection.Commit -eq 'local' -and -not $localSelection.Temporary) 'uncommitted checkout launcher needs no release pin'
    $child = & $bootstrap { param($selection) Invoke-TestHandoff $selection } $localSelection
    Assert ($child.Args.Contains('"-ExecutionPolicy" "Bypass"')) 'development app child opts into process-only Bypass'
    Assert ($child.Args.Contains('"-LocalRoot" "' + $root + '"')) 'development child retains selected checkout'
    Assert ($child.Exe -eq 'mock-pwsh' -and $child.Wait -and $child.PassThru -and $child.NoNewWindow) 'bootstrap waits for the unelevated app child'
    Assert (Test-Path -LiteralPath $launcher) 'development launcher is not deleted'
    foreach ($failChild in @($false,$true)) {
        $temporary = Join-Path $root ('temporary launcher ' + $failChild + '.ps1')
        [IO.File]::WriteAllText($temporary, 'fixture only')
        $selection=[pscustomobject]@{Path=$temporary; Commit=('a' * 40); LocalRoot=$null; Temporary=$true}
        $child = & $bootstrap { param($selection,$fail) Invoke-TestHandoff $selection -FailChild $fail } $selection $failChild
        Assert ($child.Args.Contains('"-ExecutionPolicy" "Bypass"')) 'release app child opts into process-only Bypass'
        Assert ($child.Args.Contains('"-Commit" "' + ('a' * 40) + '"') -and -not $child.Args.Contains('-LocalRoot')) 'release child preserves immutable pin without local substitution'
        Assert (-not (Test-Path -LiteralPath $temporary)) 'temporary launcher is cleaned after child completion or launch failure'
    }
    $child = & $bootstrap { param($selection) Invoke-TestHandoff $selection -FailSource $true } $localSelection
    Assert ($null -eq $child) 'source selection/integrity failure never launches a Bypass child'
    Write-Output "PASS: $script:checks launcher checks; launcher main, WinUI and HTTP were never invoked."
} finally { Remove-Item -LiteralPath $root -Recurse -Force }
