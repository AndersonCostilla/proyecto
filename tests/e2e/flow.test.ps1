Run-PwxTest -Name 'E2E: ciclo completo cliente->trabajo->requisitos->produccion->qa->delivery' -File 'e2e' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap

    $client = New-PwxClient -Name 'Cliente E2E' -Contact 'e2e@mail.com'
    Assert-PwxNotNull $client

    $request = 'Organizar los datos de un presupuesto.'
    $job = New-PwxJob -ClientId $client.id -Service 'simulate-service' -Description $request
    Assert-PwxEqual 'NEW' $job.state

    $json = '{
        "service": "simulate-service",
        "objective": "organizar presupuesto",
        "input_files": [],
        "required_output": ["resultado.txt"],
        "constraints": [],
        "missing_information": [],
        "acceptance_criteria": ["archivo existe"]
    }'
    $res = Invoke-PwxRequirementsAgent -JobId $job.id -Request $request -ForceJson $json
    Assert-PwxTrue $res.ok
    Assert-PwxEqual 'simulate-service' $res.spec.service

    $jobReqs = Get-PwxJob -JobId $job.id
    Assert-PwxEqual 'READY_FOR_PRODUCTION' $jobReqs.state
    Assert-PwxNotNull $jobReqs.requirements

    $prod = Invoke-PwxProductionAgent -JobId $job.id
    Assert-PwxTrue $prod.ok -Message 'Produccion simulada debe funcionar'
    Assert-PwxEqual 'READY_FOR_DELIVERY' $prod.state

    $qa = Get-PwxQaResult -JobId $job.id
    Assert-PwxEqual 'PASS' $qa.verdict

    $delivery = New-PwxDelivery -JobId $job.id
    Assert-PwxTrue ($delivery.file_count -ge 1) 'Debe haber al menos un archivo'
    $deliveryDir = Join-Path $ws ('clients\' + $client.id + '\jobs\' + $job.id + '\delivery')
    Assert-PwxTrue (Test-Path -LiteralPath (Join-Path $deliveryDir 'manifest.json')) 'manifest.json debe existir'
    Assert-PwxTrue (Test-Path -LiteralPath (Join-Path $deliveryDir 'checksums.sha256')) 'checksums.sha256 debe existir'

    $msg = New-PwxOutboxItem -Recipient 'e2e@mail.com' -Subject 'Listo' -Body 'Entregado.' -JobId $job.id
    Assert-PwxEqual 'DRAFT' $msg.status

    Approve-PwxDelivery -JobId $job.id -By 'tester'
    $final = Get-PwxJob -JobId $job.id
    Assert-PwxEqual 'DELIVERED' $final.state
}

Run-PwxTest -Name 'E2E: QA fallido lleva a REWORK' -File 'e2e' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap

    $client = New-PwxClient -Name 'Cliente Rework'
    $job = New-PwxJob -ClientId $client.id -Service 'simulate-service'
    $json = '{
        "service": "simulate-service",
        "objective": "sim con salida vacia que debe fallar QA",
        "input_files": [],
        "required_output": ["resultado.txt"],
        "constraints": ["PWX_TEST_EMPTY_OUTPUT"],
        "missing_information": [],
        "acceptance_criteria": []
    }'
    Invoke-PwxRequirementsAgent -JobId $job.id -Request 'sim' -ForceJson $json | Out-Null
    $prod = Invoke-PwxProductionAgent -JobId $job.id
    Assert-PwxTrue (-not $prod.ok) 'Debe fallar QA'
    Assert-PwxEqual 'REWORK' $prod.state
    $jobAfter = Get-PwxJob -JobId $job.id
    Assert-PwxEqual 'REWORK' $jobAfter.state
}

Run-PwxTest -Name 'E2E: login/json malo deja el trabajo en BLOCKED' -File 'e2e' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap

    $client = New-PwxClient -Name 'Cliente Blocked'
    $job = New-PwxJob -ClientId $client.id -Service 'simulate-service'
    $res = Invoke-PwxRequirementsAgent -JobId $job.id -Request 'x' -ForceJson 'not json'
    Assert-PwxTrue (-not $res.ok)
    $jobAfter = Get-PwxJob -JobId $job.id
    Assert-PwxEqual 'BLOCKED' $jobAfter.state
}