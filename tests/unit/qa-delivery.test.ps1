function New-PwxTestSimSpec {
    param([string]$Service = 'simulate-service', [string[]]$RequiredOutput = @('resultado.txt'), [string[]]$Constraints = @())
    return @{
        service             = $Service
        objective           = 'sim'
        input_files         = @()
        required_output     = @($RequiredOutput)
        constraints         = @($Constraints)
        missing_information = @()
        acceptance_criteria = @()
    }
}

Run-PwxTest -Name 'T1: salida anidada aprobada por QA (recursivo)' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    $client = New-PwxClient -Name 'Cliente Nested'
    $job = New-PwxJob -ClientId $client.id -Service 'simulate-service'
    $job.requirements = New-PwxTestSimSpec -RequiredOutput @('*.xlsx')
    Save-PwxJob -Job $job | Out-Null
    $found = Find-PwxJob -JobId $job.id
    New-PwxDirectory -Path (Join-Path $found.JobDir 'output\sub') | Out-Null
    $nested = Join-Path $found.JobDir 'output\sub\a.xlsx'
    [System.IO.File]::WriteAllText($nested, 'datos anidados', (New-Object System.Text.UTF8Encoding($false)))
    $qa = Invoke-PwxQa -JobId $job.id
    Assert-PwxEqual 'PASS' $qa.verdict
    $check = @($qa.checks | Where-Object { $_.check -eq 'output_not_empty' })
    Assert-PwxTrue ($check.Count -eq 1 -and $check[0].ok) 'output_not_empty debe ser recursivo'
    $req = @($qa.checks | Where-Object { $_.check -eq 'required_output:*.xlsx' })
    Assert-PwxTrue ($req.Count -eq 1 -and $req[0].ok) 'required_output debe matchear archivos anidados'
}

Run-PwxTest -Name 'C3: QA detecta salida anidada vacia como FAIL' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    $client = New-PwxClient -Name 'Cliente Nested2'
    $job = New-PwxJob -ClientId $client.id -Service 'simulate-service'
    $job.requirements = New-PwxTestSimSpec -RequiredOutput @('*.xlsx')
    Save-PwxJob -Job $job | Out-Null
    $found = Find-PwxJob -JobId $job.id
    New-PwxDirectory -Path (Join-Path $found.JobDir 'output\sub') | Out-Null
    $nested = Join-Path $found.JobDir 'output\sub\vacio.xlsx'
    [System.IO.File]::WriteAllText($nested, '', (New-Object System.Text.UTF8Encoding($false)))
    $qa = Invoke-PwxQa -JobId $job.id
    Assert-PwxEqual 'FAIL' $qa.verdict 'Archivo anidado vacio debe fallar file_nonempty'
}

Run-PwxTest -Name 'T2: modificacion posterior a QA bloquea delivery' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    $client = New-PwxClient -Name 'Cliente TOCTOU'
    $job = New-PwxJob -ClientId $client.id -Service 'simulate-service'
    $json = '{
        "service": "simulate-service",
        "objective": "sim",
        "input_files": [],
        "required_output": ["resultado.txt"],
        "constraints": [],
        "missing_information": [],
        "acceptance_criteria": ["archivo existe"]
    }'
    Invoke-PwxRequirementsAgent -JobId $job.id -Request 'sim' -ForceJson $json | Out-Null
    $prod = Invoke-PwxProductionAgent -JobId $job.id
    Assert-PwxTrue $prod.ok
    $qa = Get-PwxQaResult -JobId $job.id
    Assert-PwxEqual 'PASS' $qa.verdict
    Assert-PwxTrue ($qa.output_files.Count -ge 1) 'QA debe exponer snapshot de archivos'
    $found = Find-PwxJob -JobId $job.id
    $out = Join-Path $found.JobDir 'output\resultado.txt'
    [System.IO.File]::AppendAllText($out, 'tamper', (New-Object System.Text.UTF8Encoding($false)))
    $threw = $false
    try { New-PwxDelivery -JobId $job.id } catch { $threw = $true }
    Assert-PwxTrue $threw 'Delivery debe quedar bloqueado si el output cambio tras QA'
    $state = (Get-PwxJob -JobId $job.id).state
    Assert-PwxEqual 'READY_FOR_DELIVERY' $state 'Estado no debe corromperse al intentar entregar'
}

Run-PwxTest -Name 'C2: re-ejecutar QA autoriza el delivery de nuevo' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    $client = New-PwxClient -Name 'Cliente TOCTOU2'
    $job = New-PwxJob -ClientId $client.id -Service 'simulate-service'
    $json = '{
        "service": "simulate-service",
        "objective": "sim",
        "input_files": [],
        "required_output": ["resultado.txt"],
        "constraints": [],
        "missing_information": [],
        "acceptance_criteria": ["archivo existe"]
    }'
    Invoke-PwxRequirementsAgent -JobId $job.id -Request 'sim' -ForceJson $json | Out-Null
    Invoke-PwxProductionAgent -JobId $job.id | Out-Null
    $found = Find-PwxJob -JobId $job.id
    $out = Join-Path $found.JobDir 'output\resultado.txt'
    [System.IO.File]::AppendAllText($out, 'nuevo', (New-Object System.Text.UTF8Encoding($false)))
    $qa = Invoke-PwxQa -JobId $job.id
    Assert-PwxEqual 'PASS' $qa.verdict
    $delivery = New-PwxDelivery -JobId $job.id
    Assert-PwxTrue ($delivery.file_count -ge 1) 'Tras re-QA el delivery debe funcionar'
}

Run-PwxTest -Name 'C2: delivery normal despues de QA (sin modificacion)' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    $client = New-PwxClient -Name 'Cliente OK'
    $job = New-PwxJob -ClientId $client.id -Service 'simulate-service'
    $json = '{
        "service": "simulate-service",
        "objective": "sim",
        "input_files": [],
        "required_output": ["resultado.txt"],
        "constraints": [],
        "missing_information": [],
        "acceptance_criteria": ["archivo existe"]
    }'
    Invoke-PwxRequirementsAgent -JobId $job.id -Request 'sim' -ForceJson $json | Out-Null
    $prod = Invoke-PwxProductionAgent -JobId $job.id
    Assert-PwxTrue $prod.ok
    $delivery = New-PwxDelivery -JobId $job.id
    Assert-PwxTrue ($delivery.file_count -eq 1) 'Debe empaquetar el resultado.txt'
    Assert-PwxTrue ($delivery.output_version -ge 1) 'Manifest debe registrar la version de salida'
    Assert-PwxNotNull $delivery.qa_checked_at 'Manifest debe registrar el QA_checked_at'
}