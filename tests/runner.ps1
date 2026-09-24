$ErrorActionPreference = 'Stop'

if (-not $global:PwxTestsDir) {
    $global:PwxTestsDir = Split-Path -Parent $PSScriptRoot
}
if (-not $global:PwxRepoRoot) {
    $global:PwxRepoRoot = Split-Path -Parent $global:PwxTestsDir
}
[string]$global:PwxTestRoot = Join-Path $env:TEMP 'pwx-tests'
[string]$global:PwxCurrentTestWorkspace = ''

$global:PwxPassed = 0
$global:PwxFailed = 0
$global:PwxFailures = New-Object System.Collections.ArrayList
$global:PwxTestsRun = 0

function New-PwxTestWorkspace {
    $ws = Join-Path $global:PwxTestRoot ('ws-' + [guid]::NewGuid().ToString('N'))
    $global:PwxCurrentTestWorkspace = $ws
    return $ws
}

function Set-PwxTestWorkspace {
    param([string]$Path)
    $global:PwxCurrentTestWorkspace = $Path
}

function Get-PwxTestWorkspace {
    return $global:PwxCurrentTestWorkspace
}

function Assert-PwxTrue {
    param([bool]$Condition, [string]$Message = 'La condicion no se cumplio')
    if (-not $Condition) {
        throw "ASSERT FAILED: $Message"
    }
}

function Assert-PwxEqual {
    param([object]$Expected, [object]$Actual, [string]$Message = '')
    if ($Expected -ne $Actual) {
        throw "ASSERT FAILED: $Message Esperado='$Expected' Actual='$Actual'"
    }
}

function Assert-PwxNotNull {
    param([object]$Value, [string]$Message = 'Valor esperado no nulo')
    if ($null -eq $Value) {
        throw "ASSERT FAILED: $Message"
    }
}

function Assert-PwxNull {
    param([object]$Value, [string]$Message = 'Se esperaba nulo')
    if ($null -ne $Value) {
        throw "ASSERT FAILED: $Message"
    }
}

function Assert-PwxThrows {
    param(
        [scriptblock]$Body,
        [string]$Message = 'Se esperaba que lanzara excepcion'
    )
    $threw = $false
    try {
        & $Body | Out-Null
    }
    catch {
        $threw = $true
    }
    if (-not $threw) {
        throw "ASSERT FAILED: $Message (no lanzo)"
    }
}

function Run-PwxTest {
    param(
        [string]$Name,
        [scriptblock]$Body,
        [string]$File
    )
    $global:PwxTestsRun++
    $tempWs = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $tempWs
    try {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        & $Body
        $sw.Stop()
        $global:PwxPassed++
        Write-Host ("PASS  {0}  ({1} ms)" -f $Name, $sw.ElapsedMilliseconds) -ForegroundColor Green
    }
    catch {
        $global:PwxFailed++
        [void]$global:PwxFailures.Add([pscustomobject]@{
            File   = $File
            Name   = $Name
            Error  = $_.Exception.Message
        })
        Write-Host ("FAIL  {0}" -f $Name) -ForegroundColor Red
        Write-Host ("      {0}" -f $_.Exception.Message) -ForegroundColor Red
    }
    finally {
        $env:PWX_WORKSPACE = $null
    }
}

function Invoke-PwxTestLlmText {
    param(
        [string]$Prompt,
        [string]$System,
        [string]$Model,
        [double]$Temperature = 0.2
    )
    $proxy = [pscustomobject]@{
        ok       = $true
        code     = 'OK'
        content  = $Prompt
        error    = $null
    }
    return $proxy
}

function Find-PwxScriptPath {
    param([string]$Relative)
    return (Join-Path $global:PwxRepoRoot $Relative)
}

function Invoke-PwxBootstrap {
    if ($global:PwxBootstrapped) { return }
    throw 'Bootstrap no cargado: run-tests.ps1 debe cargarlo en el scope raiz'
}

Write-Host "PWX Test Harness" -ForegroundColor Cyan
Write-Host ("Repositorio: {0}" -f $global:PwxRepoRoot)
Write-Host ("Raiz de tests: {0}" -f $global:PwxTestRoot)