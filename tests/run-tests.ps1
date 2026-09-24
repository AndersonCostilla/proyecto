param(
    [switch]$OnlyUnit,
    [switch]$OnlyE2E
)

$ErrorActionPreference = 'Stop'

[string]$global:PwxTestsDir = Join-Path $PSScriptRoot ''
[string]$global:PwxRepoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'runner.ps1')

$global:PwxBootstrapped = $false
[string]$global:PwxRoot = $global:PwxRepoRoot
$env:PWX_ROOT = $global:PwxRepoRoot
. (Join-Path $global:PwxRepoRoot 'src\bootstrap.ps1')
$global:PwxBootstrapped = $true

$unitTests = @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'unit') -Filter '*.test.ps1' -ErrorAction SilentlyContinue)
$e2eTests = @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'e2e') -Filter '*.test.ps1' -ErrorAction SilentlyContinue)

$toRun = @()
if (-not $OnlyUnit -and -not $OnlyE2E) {
    $toRun = $unitTests + $e2eTests
}
elseif ($OnlyUnit) {
    $toRun = $unitTests
}
elseif ($OnlyE2E) {
    $toRun = $e2eTests
}

foreach ($file in $toRun) {
    . $file.FullName
}

Write-Host ""
Write-Host ("RESULTADOS: {0} pasados, {1} fallidos, {2} total" -f $global:PwxPassed, $global:PwxFailed, $global:PwxTestsRun) -ForegroundColor Cyan
if ($global:PwxFailed -gt 0) {
    Write-Host "FALLIDOS:" -ForegroundColor Red
    foreach ($f in $global:PwxFailures) {
        Write-Host ("  - {0} :: {1}" -f $f.Name, $f.Error) -ForegroundColor Red
    }
    exit 1
}
exit 0