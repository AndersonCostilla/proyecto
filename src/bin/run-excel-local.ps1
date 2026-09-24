param(
    [string]$InputPath = 'tests/fixtures/basic.xlsx',
    [string]$Model = 'qwen3:8b',
    [string]$ClientName = 'LocalDemo',
    [string]$Title = 'Excel Local Run',
    [switch]$NoApproveDelivery
)

$ErrorActionPreference = 'Stop'

$script:RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$script:PwxCli = Join-Path $PSScriptRoot 'pwx.ps1'

. (Join-Path $PSScriptRoot '..\bootstrap.ps1')

$env:PWX_MODEL = $Model

function Invoke-PwxCli {
    param([string[]]$CliArgs)
    $raw = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $script:PwxCli @CliArgs 2>&1)
    $errors = @($raw | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] })
    $text = @($raw | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] })
    return [pscustomobject]@{
        ExitCode = [int]$LASTEXITCODE
        Output   = (($text -join "`n") -replace "`r", '').Trim()
        Errors   = $errors
    }
}

function Invoke-PwxCliOk {
    param([string[]]$CliArgs)
    $res = Invoke-PwxCli -CliArgs $CliArgs
    if ($res.ExitCode -ne 0) {
        $detail = @($res.Errors | ForEach-Object { $_.Exception.Message })
        throw "Fallo en '$($CliArgs[0])': $($detail -join ' | ')"
    }
    return $res
}

if (-not [System.IO.Path]::IsPathRooted($InputPath)) {
    $InputPath = Join-Path $script:RepoRoot $InputPath
}
$InputPath = [System.IO.Path]::GetFullPath($InputPath)
if (-not (Test-Path -LiteralPath $InputPath)) {
    throw "InputPath no existe: $InputPath"
}
if ([System.IO.Path]::GetExtension($InputPath) -ne '.xlsx') {
    throw "InputPath debe ser un archivo .xlsx: $InputPath"
}

$cfg = Get-PwxConfig
$llm = Get-PwxOllamaStatus
$modelState = Test-PwxModelAvailable -Model $Model
$useLlm = ($modelState -eq 'OK')

Write-Host "PWX: Excel local run (client -> job -> requisitos -> input -> produce -> qa -> deliver -> approvedeliver)" -ForegroundColor Magenta
Write-Host ("Workspace: {0}" -f $cfg.WorkspacePath)
Write-Host ("Input: {0}" -f $InputPath)
Write-Host ("Modelo: {0}  ->  {1}" -f $Model, $modelState)
Write-Host ("Ollama: {0}" -f $llm.status)
Write-Host ("Modo requisitos: {0}" -f ($(if ($useLlm) { 'LLM' } else { 'mock/plantilla (ForceJson)' })))

$request = 'Normalizar esta planilla Excel de precios.'

Write-Host "`n[1/8] Cliente" -ForegroundColor Cyan
$res = Invoke-PwxCliOk -CliArgs @('client:new', '-Name', $ClientName)
$client = ConvertFrom-Json -InputObject $res.Output
$clientId = $client.id
Write-Host ("  [OK] clientId=$clientId") -ForegroundColor Green

Write-Host "[2/8] Trabajo (excel-service)" -ForegroundColor Cyan
$res = Invoke-PwxCliOk -CliArgs @('job:new', '-ClientId', $clientId, '-Service', 'excel-service', '-Description', $Title)
$job = ConvertFrom-Json -InputObject $res.Output
$jobId = $job.id
Write-Host ("  [OK] jobId=$jobId state=$($job.state)") -ForegroundColor Green

Write-Host "[3/8] Requisitos" -ForegroundColor Cyan
$spec = $null
if ($useLlm) {
    $res = Invoke-PwxCli -CliArgs @('job:requisitos', '-JobId', $jobId, '-Request', $request)
    if ($res.ExitCode -eq 0 -and $res.Output) {
        $req = ConvertFrom-Json -InputObject $res.Output
        if ($req.ok) { $spec = $req.spec }
    }
}
$mode = 'LLM'
if (-not $spec) {
    $mode = 'mock/plantilla (ForceJson)'
    Write-Host "  [WARN] LLM no disponible o fallo; uso de plantilla sin LLM." -ForegroundColor Yellow
    $template = @{
        service             = 'excel-service'
        objective           = $Title
        input_files         = @('planilla.xlsx')
        required_output     = @('*.xlsx')
        constraints         = @()
        missing_information = @()
        acceptance_criteria = @('archivo xlsx valido y normalizado')
    } | ConvertTo-Json -Depth 5
    $mock = Invoke-PwxRequirementsAgent -JobId $jobId -Request $request -ForceJson $template
    if (-not $mock.ok) {
        throw "Requisitos en modo plantilla fallaron: $($mock.error) ($($mock.code))"
    }
    $spec = $mock.spec
}
$jobCur = Get-PwxJob -JobId $jobId
if ($jobCur.requirements.service -ne 'excel-service') {
    Write-Host ("  [WARN] Requisitos apuntan a '{0}'; se fuerza excel-service." -f $jobCur.requirements.service) -ForegroundColor Yellow
    $jobCur.requirements.service = 'excel-service'
    $jobCur.requirements.required_output = @('*.xlsx')
    Save-PwxJob -Job $jobCur | Out-Null
}
Write-Host ("  [OK] requisitos ($mode) service=$($spec.service) state=READY_FOR_PRODUCTION") -ForegroundColor Green

Write-Host "[4/8] Input (xlsx)" -ForegroundColor Cyan
$res = Invoke-PwxCliOk -CliArgs @('job:input', '-JobId', $jobId, '-Path', $InputPath, '-TargetName', 'planilla.xlsx')
$entry = ConvertFrom-Json -InputObject $res.Output
Write-Host ("  [OK] input -> {0}" -f $entry.path) -ForegroundColor Green

Write-Host "[5/8] Produccion (excel-service)" -ForegroundColor Cyan
$res = Invoke-PwxCliOk -CliArgs @('job:produce', '-JobId', $jobId)
$prod = ConvertFrom-Json -InputObject $res.Output
if (-not $prod.ok) {
    throw "Produccion fallo: $($prod.error)"
}
Write-Host ("  [OK] produce -> $($prod.state)") -ForegroundColor Green

Write-Host "[6/8] QA" -ForegroundColor Cyan
$res = Invoke-PwxCliOk -CliArgs @('job:qa', '-JobId', $jobId)
$qa = ConvertFrom-Json -InputObject $res.Output
Write-Host ("  [OK] qa -> verdict=$($qa.verdict)") -ForegroundColor Green

Write-Host "[7/8] Delivery (empaquetado)" -ForegroundColor Cyan
$res = Invoke-PwxCliOk -CliArgs @('job:deliver', '-JobId', $jobId)
$manifest = ConvertFrom-Json -InputObject $res.Output
Write-Host ("  [OK] deliver -> {0} archivo(s) empaquetado(s)" -f $manifest.file_count) -ForegroundColor Green

if (-not $NoApproveDelivery) {
    Write-Host "[8/8] Aprobacion de entrega" -ForegroundColor Cyan
    Invoke-PwxCliOk -CliArgs @('job:approvedeliver', '-JobId', $jobId, '-By', 'run-excel-local') | Out-Null
    Write-Host "  [OK] approvedeliver" -ForegroundColor Green
}

$final = Get-PwxJob -JobId $jobId
$found = Find-PwxJob -JobId $jobId
$deliveryManifest = Get-PwxDeliveryManifest -JobId $jobId
$outPath = 'N/A'
if ($deliveryManifest -and $deliveryManifest.files.Count -gt 0) {
    $outPath = Join-Path (Join-Path $found.JobDir 'delivery') $deliveryManifest.files[0].path
}

Write-Host "`n=== RESULTADO ===" -ForegroundColor Magenta
Write-Host "clientId: $clientId"
Write-Host "jobId: $jobId"
Write-Host "output entregado: $outPath"
Write-Host "estado final: $($final.state)"

if (-not $NoApproveDelivery -and $final.state -ne 'DELIVERED') {
    Write-Host ("ADVERTENCIA: estado final es {0}, se esperaba DELIVERED" -f $final.state) -ForegroundColor Yellow
    exit 1
}

if ($NoApproveDelivery -and $final.state -ne 'READY_FOR_DELIVERY') {
    Write-Host ("ADVERTENCIA: estado final es {0}, se esperaba READY_FOR_DELIVERY (aprobacion desactivada)" -f $final.state) -ForegroundColor Yellow
    exit 1
}

exit 0