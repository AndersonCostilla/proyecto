param(
    [Parameter(Mandatory)][string]$InputPath,
    [string]$Model = 'qwen3:8b',
    [string]$ClientName = 'Validacion Word Local',
    [string]$Title = 'Documento Word de validacion',
    [switch]$NoApproveDelivery
)

$ErrorActionPreference = 'Stop'
$script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$previousRoot = $env:PWX_ROOT
$previousWorkspace = $env:PWX_WORKSPACE
$previousModel = $env:PWX_MODEL
$previousPaymentPolicy = $env:PWX_REQUIRE_PAYMENT_BEFORE_PRODUCTION

if (-not [System.IO.Path]::IsPathRooted($InputPath)) {
    $InputPath = Join-Path (Get-Location) $InputPath
}
$InputPath = [System.IO.Path]::GetFullPath($InputPath)
if (-not (Test-Path -LiteralPath $InputPath)) { throw "InputPath no existe: $InputPath" }
if ((Get-Item -LiteralPath $InputPath).PSIsContainer) { throw 'InputPath debe ser un archivo .txt o .md' }
if ([System.IO.Path]::GetExtension($InputPath).ToLowerInvariant() -notin @('.txt', '.md')) {
    throw 'InputPath debe ser un archivo .txt o .md'
}

$baseTemp = if ($env:TEMP) { $env:TEMP } else { [System.IO.Path]::GetTempPath() }
$runRoot = Join-Path $baseTemp ('pwx-word-local-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$workspace = Join-Path $runRoot 'workspace'

try {
    $env:PWX_ROOT = $script:RepoRoot
    $env:PWX_WORKSPACE = $workspace
    $env:PWX_MODEL = $Model
    # Solo para este workspace temporal: no simula ni aprueba pagos de un pedido real.
    $env:PWX_REQUIRE_PAYMENT_BEFORE_PRODUCTION = 'false'
    . (Join-Path $script:RepoRoot 'src\bootstrap.ps1')

    $ollama = Get-PwxOllamaStatus
    $modelState = Test-PwxModelAvailable -Model $Model
    if ($ollama.status -ne 'OK' -or $modelState -ne 'OK') {
        throw "Ollama/modelo no disponible. Ollama=$($ollama.status), Modelo=$modelState"
    }

    Write-Host ''
    Write-Host 'PWX - prueba local completa de Word' -ForegroundColor Magenta
    Write-Host "Workspace temporal: $workspace" -ForegroundColor DarkGray
    Write-Host "Contenido fuente: $InputPath" -ForegroundColor DarkGray
    Write-Host "Modelo real: $Model" -ForegroundColor DarkGray

    Write-Host "`n[1/7] Cliente" -ForegroundColor Cyan
    $client = New-PwxClient -Name $ClientName -Contact 'validacion-local@pwx.test'
    Write-Host "  [OK] $($client.id)" -ForegroundColor Green

    Write-Host '[2/7] Trabajo Word' -ForegroundColor Cyan
    $job = New-PwxJob -ClientId $client.id -Service 'word-service' -Description $Title
    Write-Host "  [OK] $($job.id)" -ForegroundColor Green

    Write-Host '[3/7] Archivo de contenido' -ForegroundColor Cyan
    $targetName = [System.IO.Path]::GetFileName($InputPath)
    $entry = Add-PwxJobInputFile -JobId $job.id -SourcePath $InputPath -TargetName $targetName
    Write-Host "  [OK] $($entry.path)" -ForegroundColor Green

    Write-Host '[4/7] Requisitos con Ollama real' -ForegroundColor Cyan
    $request = @"
Selecciona obligatoriamente word-service.
Esto es una validación técnica local de un documento profesional Word.
Usa $targetName como contenido de entrada.
La entrega requerida es un archivo DOCX profesional.
Conserva títulos, subtítulos, listas y párrafos.
El documento debe ser válido y no estar vacío.
"@
    $requirements = Invoke-PwxRequirementsAgent -JobId $job.id -Request $request
    if (-not $requirements.ok) { throw "Requisitos fallaron: $($requirements.code) $($requirements.error)" }
    if ($requirements.spec.service -ne 'word-service') {
        throw "El modelo seleccionó '$($requirements.spec.service)', se esperaba word-service"
    }
    Write-Host "  [OK] state=$($requirements.state)" -ForegroundColor Green

    Write-Host '[5/7] Producción DOCX' -ForegroundColor Cyan
    $production = Invoke-PwxProductionAgent -JobId $job.id
    if (-not $production.ok) { throw "Producción falló: $($production.error) $($production.detail)" }
    Write-Host "  [OK] state=$($production.state), QA=$($production.qa.verdict)" -ForegroundColor Green

    Write-Host '[6/7] Empaquetado de entrega' -ForegroundColor Cyan
    $delivery = New-PwxDelivery -JobId $job.id
    Write-Host "  [OK] $($delivery.file_count) archivo(s)" -ForegroundColor Green

    if (-not $NoApproveDelivery) {
        Write-Host '[7/7] Aprobación de entrega de prueba' -ForegroundColor Cyan
        Approve-PwxDelivery -JobId $job.id -By 'run-word-local' | Out-Null
        Write-Host '  [OK] entregado' -ForegroundColor Green
    }

    $found = Find-PwxJob -JobId $job.id
    $output = Join-Path $found.JobDir 'delivery\documento-profesional.docx'
    $final = Get-PwxJob -JobId $job.id
    Write-Host "`n=== RESULTADO ===" -ForegroundColor Magenta
    Write-Host "Trabajo: $($job.id)"
    Write-Host "Documento: $output"
    Write-Host "Estado final: $($final.state)"
    Write-Host 'Nota: este fue un workspace temporal sin cobro ni contacto externo.' -ForegroundColor Yellow
}
finally {
    $env:PWX_ROOT = $previousRoot
    $env:PWX_WORKSPACE = $previousWorkspace
    $env:PWX_MODEL = $previousModel
    $env:PWX_REQUIRE_PAYMENT_BEFORE_PRODUCTION = $previousPaymentPolicy
}
