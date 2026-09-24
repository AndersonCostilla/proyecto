$script:RunnerCli = Join-Path $global:PwxRepoRoot 'src\bin\run-excel-local.ps1'
$script:RunnerFixture = Join-Path $global:PwxRepoRoot 'tests\fixtures\basic.xlsx'

function Test-PwxRunnerChecksums {
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

Run-PwxTest -Name 'Runner: run-excel-local.ps1 entrega en workspace temporal (manifest + checksums validos)' -File 'e2e\runner' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap

    $raw = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $script:RunnerCli -InputPath $script:RunnerFixture -Model 'pwx-no-such-model-runner' -ClientName 'RunnerE2E' 2>&1)
    $exit = [int]$LASTEXITCODE
    Assert-PwxEqual 0 $exit 'run-excel-local debe terminar con exit 0'

    $all = (($raw -join "`n") -replace "`r", '')
    $jobId = $null
    if ($all -match '(?m)^\s*jobId:\s*(J-\d+)\s*$') { $jobId = $Matches[1] }
    Assert-PwxNotNull $jobId 'Debe imprimir un jobId'
    Assert-PwxTrue ($all -match '(?m)^\s*estado final:\s*DELIVERED\s*$') 'Debe terminar DELIVERED'

    $job = Get-PwxJob -JobId $jobId
    Assert-PwxEqual 'DELIVERED' $job.state
    $found = Find-PwxJob -JobId $jobId
    Assert-PwxNotNull $found

    $deliveryDir = Join-Path $found.JobDir 'delivery'
    Assert-PwxTrue (Test-Path -LiteralPath (Join-Path $deliveryDir 'manifest.json')) 'Debe existir manifest.json'
    Assert-PwxTrue (Test-Path -LiteralPath (Join-Path $deliveryDir 'checksums.sha256')) 'Debe existir checksums.sha256'
    Assert-PwxTrue (Test-PwxRunnerChecksums -DeliveryDir $deliveryDir) 'checksums validos contra los archivos reales'

    $manifest = Get-PwxJsonFile -Path (Join-Path $deliveryDir 'manifest.json')
    Assert-PwxEqual '1' $manifest.schema_version
    Assert-PwxTrue ($manifest.outputs.Count -ge 1) 'manifest.outputs no vacio'
    Assert-PwxEqual (Test-Path -LiteralPath (Join-Path $deliveryDir $manifest.outputs[0].path)) ${true} 'output entregado existe en delivery/'
}