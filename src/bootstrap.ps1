$ErrorActionPreference = 'Stop'

function Get-PwxVersion { return '0.1.0' }

if ($env:PWX_ROOT) {
    $global:PwxRoot = $env:PWX_ROOT
}
elseif (-not $global:PwxRoot) {
    $global:PwxRoot = Split-Path -Parent $PSScriptRoot
}

$moduleFiles = @(
    'core\config.ps1',
    'core\fs.ps1',
    'core\log.ps1',
    'core\id.ps1',
    'core\state.ps1',
    'core\store.ps1',
    'core\pricing.ps1',
    'core\payments.ps1',
    'core\outbox.ps1',
    'core\leads.ps1',
    'core\qa.ps1',
    'core\delivery.ps1',
    'agents\ollama.ps1',
    'agents\requirements.ps1',
    'agents\production.ps1',
    'agents\prospecting.ps1',
    'services\registry.ps1',
    'services\simulate.ps1',
    'services\excel.ps1',
    'services\word.ps1',
    'services\pdf.ps1',
    'services\data.ps1',
    'services\construction.ps1',
    'web\server.ps1'
)

foreach ($rel in $moduleFiles) {
    $path = Join-Path $PSScriptRoot $rel
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Falta modulo: $path"
    }
    . $path
}