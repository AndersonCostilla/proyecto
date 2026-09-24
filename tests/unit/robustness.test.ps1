function New-PwxRobustSpec {
    param([string[]]$Constraints = @())
    return @{
        service             = 'simulate-service'
        objective           = 'soak robustez'
        input_files         = @()
        required_output     = @('resultado.txt')
        constraints         = @($Constraints)
        missing_information = @()
        acceptance_criteria = @('archivo existe')
    }
}

function Test-PwxRobustChecksums {
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

Run-PwxTest -Name 'R1: job:qa repetido es estable (PASS, hashes identicos, estado intacto)' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    $client = New-PwxClient -Name 'Cliente QA Idem'
    $job = New-PwxJob -ClientId $client.id -Service 'simulate-service'
    $json = (New-PwxRobustSpec | ConvertTo-Json -Depth 5)
    Invoke-PwxRequirementsAgent -JobId $job.id -Request 'sim' -ForceJson $json | Out-Null
    Invoke-PwxProductionAgent -JobId $job.id | Out-Null

    $qa1 = Invoke-PwxQa -JobId $job.id
    $qa2 = Invoke-PwxQa -JobId $job.id
    Assert-PwxEqual 'PASS' $qa1.verdict
    Assert-PwxEqual 'PASS' $qa2.verdict
    $h1 = @($qa1.output_files | ForEach-Object { $_.path + ':' + $_.sha256 } | Sort-Object) -join '|'
    $h2 = @($qa2.output_files | ForEach-Object { $_.path + ':' + $_.sha256 } | Sort-Object) -join '|'
    Assert-PwxEqual $h1 $h2 'Los hashes del output deben ser identicos entre QAs'
    $currentHash = (Get-PwxOutputSnapshot -JobId $job.id)[0].sha256
    Assert-PwxEqual $currentHash $qa2.output_files[0].sha256 'QA re-ejecutado refleja el hash actual'
    Assert-PwxEqual 'READY_FOR_DELIVERY' (Get-PwxJob -JobId $job.id).state
}

Run-PwxTest -Name 'R2: job:deliver repetido regenera paquete consistente (sin duplicados)' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    $client = New-PwxClient -Name 'Cliente Deliver Idem'
    $job = New-PwxJob -ClientId $client.id -Service 'simulate-service'
    $json = (New-PwxRobustSpec | ConvertTo-Json -Depth 5)
    Invoke-PwxRequirementsAgent -JobId $job.id -Request 'sim' -ForceJson $json | Out-Null
    Invoke-PwxProductionAgent -JobId $job.id | Out-Null

    $d1 = New-PwxDelivery -JobId $job.id
    $d2 = New-PwxDelivery -JobId $job.id
    Assert-PwxEqual $d1.file_count $d2.file_count 'file_count estable entre runs'
    Assert-PwxEqual 'READY_FOR_DELIVERY' (Get-PwxJob -JobId $job.id).state

    $found = Find-PwxJob -JobId $job.id
    $deliveryDir = Join-Path $found.JobDir 'delivery'
    $expected = @('checksums.sha256', 'manifest.json', 'resultado.txt') | Sort-Object
    $actual = @(Get-ChildItem -LiteralPath $deliveryDir -File | ForEach-Object { $_.Name } | Sort-Object)
    Assert-PwxEqual ($expected -join ',') ($actual -join ',') 'sin archivos duplicados ni temporales en delivery/'
    Assert-PwxTrue (Test-PwxRobustChecksums -DeliveryDir $deliveryDir) 'checksums validos tras re-deliver'

    $manifest = Get-PwxJsonFile -Path (Join-Path $deliveryDir 'manifest.json')
    Assert-PwxEqual '1' $manifest.schema_version
    $outEntry = @($manifest.outputs | Where-Object { $_.name -eq 'resultado.txt' })
    Assert-PwxTrue ($outEntry.Count -eq 1) 'manifest.outputs registra resultado.txt'
    Assert-PwxEqual (Get-PwxSha256 -Path (Join-Path $deliveryDir 'resultado.txt')) $outEntry[0].sha256 'manifest.outputs hash == archivo real'
}

Run-PwxTest -Name 'R3: job:produce repetido sobre READY_FOR_DELIVERY tiene error determinista y no corrompe' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    $client = New-PwxClient -Name 'Cliente Produce Idem'
    $job = New-PwxJob -ClientId $client.id -Service 'simulate-service'
    $json = (New-PwxRobustSpec | ConvertTo-Json -Depth 5)
    Invoke-PwxRequirementsAgent -JobId $job.id -Request 'sim' -ForceJson $json | Out-Null
    $prod = Invoke-PwxProductionAgent -JobId $job.id
    Assert-PwxTrue $prod.ok
    Assert-PwxEqual 'READY_FOR_DELIVERY' (Get-PwxJob -JobId $job.id).state

    $threw = $false
    $msg = ''
    try { Invoke-PwxProductionAgent -JobId $job.id } catch { $threw = $true; $msg = $_.Exception.Message }
    Assert-PwxTrue $threw 'Re-producir en READY_FOR_DELIVERY debe lanzar'
    Assert-PwxTrue ($msg -match 'Estado incorrecto para producir') 'Mensaje de error claro'
    Assert-PwxEqual 'READY_FOR_DELIVERY' (Get-PwxJob -JobId $job.id).state 'No debe corromper el estado'

    New-PwxDelivery -JobId $job.id | Out-Null
    Assert-PwxEqual 'READY_FOR_DELIVERY' (Get-PwxJob -JobId $job.id).state 'Sigue siendo entregable'
}

Run-PwxTest -Name 'R4: recovery: re-ejecutar job:produce desde REWORK llega a READY_FOR_DELIVERY' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    $client = New-PwxClient -Name 'Cliente Recovery'
    $job = New-PwxJob -ClientId $client.id -Service 'simulate-service'
    $json = (New-PwxRobustSpec -Constraints @('PWX_TEST_EMPTY_OUTPUT') | ConvertTo-Json -Depth 5)
    Invoke-PwxRequirementsAgent -JobId $job.id -Request 'sim' -ForceJson $json | Out-Null

    $prod1 = Invoke-PwxProductionAgent -JobId $job.id
    Assert-PwxTrue (-not $prod1.ok) 'Salida vacia debe fallar QA'
    Assert-PwxEqual 'REWORK' (Get-PwxJob -JobId $job.id).state

    $job = Get-PwxJob -JobId $job.id
    $job.requirements.constraints = @()
    Save-PwxJob -Job $job | Out-Null

    $prod2 = Invoke-PwxProductionAgent -JobId $job.id
    Assert-PwxTrue $prod2.ok 'Tras corregir, producir debe volver a pasar'
    Assert-PwxEqual 'READY_FOR_DELIVERY' $prod2.state

    $delivery = New-PwxDelivery -JobId $job.id
    Assert-PwxTrue ($delivery.file_count -ge 1) 'Recuperado y entregable'
}

Run-PwxTest -Name 'R5: output cambiado post-QA bloquea delivery con OUTPUT_CHANGED_SINCE_QA' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    $client = New-PwxClient -Name 'Cliente TOCTOU Msg'
    $job = New-PwxJob -ClientId $client.id -Service 'simulate-service'
    $json = (New-PwxRobustSpec | ConvertTo-Json -Depth 5)
    Invoke-PwxRequirementsAgent -JobId $job.id -Request 'sim' -ForceJson $json | Out-Null
    Invoke-PwxProductionAgent -JobId $job.id | Out-Null

    $found = Find-PwxJob -JobId $job.id
    [System.IO.File]::AppendAllText((Join-Path $found.JobDir 'output\resultado.txt'), 'tamper', (New-Object System.Text.UTF8Encoding($false)))

    $msg = ''
    try { New-PwxDelivery -JobId $job.id } catch { $msg = $_.Exception.Message }
    Assert-PwxTrue ($msg -match 'OUTPUT_CHANGED_SINCE_QA') "Debe fallar con OUTPUT_CHANGED_SINCE_QA (msg: $msg)"
    Assert-PwxEqual 'READY_FOR_DELIVERY' (Get-PwxJob -JobId $job.id).state 'Estado intacto tras el rechazo'
}

Run-PwxTest -Name 'R6: job:approvedeliver repetido es no-op y mantiene DELIVERED' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    $client = New-PwxClient -Name 'Cliente Aprob Idem'
    $job = New-PwxJob -ClientId $client.id -Service 'simulate-service'
    $json = (New-PwxRobustSpec | ConvertTo-Json -Depth 5)
    Invoke-PwxRequirementsAgent -JobId $job.id -Request 'sim' -ForceJson $json | Out-Null
    Invoke-PwxProductionAgent -JobId $job.id | Out-Null
    New-PwxDelivery -JobId $job.id | Out-Null

    Approve-PwxDelivery -JobId $job.id -By 'tester'
    Assert-PwxEqual 'DELIVERED' (Get-PwxJob -JobId $job.id).state
    Approve-PwxDelivery -JobId $job.id -By 'tester2'
    Assert-PwxEqual 'DELIVERED' (Get-PwxJob -JobId $job.id).state 'Segunda aprobacion no rompe'
    $manifest = Get-PwxDeliveryManifest -JobId $job.id
    Assert-PwxEqual 'tester' $manifest.approved_by 'approved_by no debe cambiar en no-op'
    Assert-PwxNotNull $manifest.delivered_at
}