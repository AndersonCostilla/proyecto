# Host de proceso para los tests E2E del panel (PR-5).
# Arranca Start-PwxWebServer en un proceso propio para que cada test hable
# por HTTP real en loopback y las sesiones vivan aisladas por proceso.
param(
    [Parameter(Mandatory)][int]$Port,
    [switch]$DevMode
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$bootstrap = Join-Path (Join-Path $repoRoot 'src') 'bootstrap.ps1'
. $bootstrap
Start-PwxWebServer -Port $Port -DevMode:$DevMode
