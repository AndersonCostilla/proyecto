param(
    [int]$Iterations = 20,
    [switch]$Cleanup,
    [string]$InputPath = 'tests/fixtures/basic.xlsx',
    [string]$Model = ''
)

$ErrorActionPreference = 'Stop'

$script:SoakRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$script:RunnerCli = Join-Path $script:SoakRoot 'src\bin\run-excel-local.ps1'
$script:PwxCli = Join-Path $script:SoakRoot 'src\bin\pwx.ps1'
$script:FakeModel = 'pwx-soak-modelo-inexistente'

if (-not [System.IO.Path]::IsPathRooted($InputPath)) {
    $InputPath = Join-Path $script:SoakRoot $InputPath
}
$InputPath = [System.IO.Path]::GetFullPath($InputPath)
if (-not (Test-Path -LiteralPath $InputPath)) {
    throw "InputPath no existe: $InputPath"
}

$ws = Join-Path $env:TEMP ("pwx-soak-" + (Get-Date -Format "yyyyMMdd-HHmmss"))
$env:PWX_WORKSPACE = $ws
$env:PWX_ROOT = $script:SoakRoot
. (Join-Path $script:SoakRoot 'src\bootstrap.ps1')
New-PwxDirectory -Path $ws | Out-Null

if (-not $Model) { $Model = (Get-PwxConfig).Model }
$modelOk = (Test-PwxModelAvailable -Model $Model) -eq 'OK'

Write-Host "=== PWX SOAK ===" -ForegroundColor Magenta
Write-Host ("Iteraciones: {0}" -f $Iterations)
Write-Host ("Workspace temporal: {0}" -f $ws)
Write-Host ("Input: {0}" -f $InputPath)
Write-Host ("Modelo LLM: {0}  ->  {1}" -f $Model, (Test-PwxModelAvailable -Model $Model))
Write-Host ("Cleanup al final: {0}" -f $Cleanup)

function Invoke-PwxSoakRun {
    param(
        [string]$InputFile,
        [string]$ModelName,
        [string]$ClientName,
        [bool]$NoApprove
    )
    $cliArgs = @('-InputPath', $InputFile, '-Model', $ModelName, '-ClientName', $ClientName)
    if ($NoApprove) { $cliArgs += '-NoApproveDelivery' }
    $raw = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $script:RunnerCli @cliArgs 2>&1)
    return [pscustomobject]@{
        ExitCode = [int]$LASTEXITCODE
        Output   = (($raw -join "`n") -replace "`r", '')
    }
}

function Approve-PwxSoakJob {
    param([string]$JobId)
    & powershell -NoProfile -ExecutionPolicy Bypass -File $script:PwxCli job:approvedeliver -JobId $JobId -By soak 2>&1 | Out-Null
    return [int]$LASTEXITCODE
}

function Test-PwxSoakChecksums {
    param([string]$DeliveryDir)
    $cPath = Join-Path $DeliveryDir 'checksums.sha256'
    if (-not (Test-Path -LiteralPath $cPath)) { return $false }
    $count = 0
    foreach ($line in (Get-Content -LiteralPath $cPath)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -notmatch '^([0-9A-Fa-f]{64})  (.+)$') { return $false }
        $real = Join-Path $DeliveryDir $Matches[2]
        if (-not (Test-Path -LiteralPath $real)) { return $false }
        if ((Get-FileHash -LiteralPath $real -Algorithm SHA256).Hash -ine $Matches[1]) { return $false }
        $count++
    }
    return ($count -gt 0)
}

$total = 0
$okCount = 0
$failures = New-Object System.Collections.ArrayList

for ($i = 1; $i -le $Iterations; $i++) {
    $total++
    $useLlm = ($modelOk -and ($i % 2 -eq 1))
    $modelName = if ($useLlm) { $Model } else { $script:FakeModel }
    $noApprove = (($i - 1) % 10) -lt 3
    $clientName = 'Soak-' + ('{0:000}' -f $i)

    $errs = @()
    $run = Invoke-PwxSoakRun -InputFile $InputPath -ModelName $modelName -ClientName $clientName -NoApprove $noApprove

    if ($run.ExitCode -ne 0) { $errs += "exit=$($run.ExitCode)" }

    $jobId = $null
    if ($run.Output -match '(?m)^\s*jobId:\s*(J-\d+)\s*$') { $jobId = $Matches[1] }
    if (-not $jobId) { $errs += 'sin jobId en salida' }

    $state = $null
    if ($jobId) {
        $job = Get-PwxJob -JobId $jobId
        if (-not $job) {
            $errs += "job inexistente $jobId"
        }
        else {
            $state = $job.state
            $expectedPre = if ($noApprove) { 'READY_FOR_DELIVERY' } else { 'DELIVERED' }
            if ($state -ne $expectedPre) { $errs += "estado=$state esperado=$expectedPre" }
        }
        $found = Find-PwxJob -JobId $jobId
        if ($found) {
            $deliveryDir = Join-Path $found.JobDir 'delivery'
            if (-not (Test-Path -LiteralPath (Join-Path $deliveryDir 'manifest.json'))) { $errs += 'sin manifest.json' }
            if (-not (Test-Path -LiteralPath (Join-Path $deliveryDir 'checksums.sha256'))) { $errs += 'sin checksums.sha256' }
            elseif (-not (Test-PwxSoakChecksums -DeliveryDir $deliveryDir)) { $errs += 'checksums invalidas' }
        }
        else {
            $errs += "no se ubico job $jobId"
        }
    }

    $finalState = $state
    if ($noApprove -and -not $errs) {
        $apExit = Approve-PwxSoakJob -JobId $jobId
        if ($apExit -ne 0) {
            $errs += "aprobacion exit=$apExit"
        }
        else {
            $finalState = (Get-PwxJob -JobId $jobId).state
            if ($finalState -ne 'DELIVERED') { $errs += "estado tras aprobar=$finalState esperado=DELIVERED" }
        }
    }

    $ok = ($errs.Count -eq 0)
    if ($ok) { $okCount++ } else { [void]$failures.Add([pscustomobject]@{ i = $i; errors = ($errs -join '; ') }) }

    Write-Host ("[{0}/{1}] modelo={2} noApprove={3} exit={4} estado={5} -> {6}{7}" -f $i, $Iterations, $modelName, $noApprove, $run.ExitCode, $finalState, $(if ($ok) { 'OK' } else { 'FAIL' }), $(if ($ok) { '' } else { ' :: ' + ($errs -join '; ') }))
}

Write-Host ""
Write-Host ("=== RESULTADO SOAK: {0}/{1} ok, {2} fallos ===" -f $okCount, $total, ($total - $okCount)) -ForegroundColor Magenta
Write-Host ("Workspace: {0}" -f $ws)
foreach ($f in $failures) {
    Write-Host ("  iter {0}: {1}" -f $f.i, $f.errors) -ForegroundColor Red
}

if ($Cleanup) {
    Write-Host ("Limpiando workspace {0}" -f $ws)
    Remove-Item -LiteralPath $ws -Recurse -Force -ErrorAction SilentlyContinue
}

if ($okCount -ne $total) {
    exit 1
}
exit 0