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

Run-PwxTest -Name 'PAQUETE: manifest.json estandar y checksums.sha256 tras deliver' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    $client = New-PwxClient -Name 'Cliente Paquete'
    $job = New-PwxJob -ClientId $client.id -Service 'simulate-service'
    $json = (New-PwxTestSimSpec -RequiredOutput @('resultado.txt') | ConvertTo-Json -Depth 5)
    Invoke-PwxRequirementsAgent -JobId $job.id -Request 'sim' -ForceJson $json | Out-Null
    Invoke-PwxProductionAgent -JobId $job.id | Out-Null
    New-PwxDelivery -JobId $job.id | Out-Null

    $found = Find-PwxJob -JobId $job.id
    $deliveryDir = Join-Path $found.JobDir 'delivery'
    $manifestPath = Join-Path $deliveryDir 'manifest.json'
    $checksumsPath = Join-Path $deliveryDir 'checksums.sha256'
    Assert-PwxTrue (Test-Path -LiteralPath $manifestPath) 'manifest.json debe existir'
    Assert-PwxTrue (Test-Path -LiteralPath $checksumsPath) 'checksums.sha256 debe existir'

    $manifest = Get-PwxJsonFile -Path $manifestPath
    Assert-PwxEqual '1' $manifest.schema_version
    Assert-PwxEqual $job.id $manifest.job_id
    Assert-PwxEqual $client.id $manifest.client_id
    Assert-PwxEqual 'simulate-service' $manifest.service
    Assert-PwxTrue ($manifest.created_utc -match 'Z$') 'created_utc debe ser ISO-8601 UTC'
    Assert-PwxTrue ($manifest.inputs -is [System.Array]) 'inputs debe ser una lista'
    Assert-PwxEqual 'PASS' $manifest.qa.verdict 'QA en manifest debe ser PASS'
    Assert-PwxTrue ($manifest.qa.at_utc -match 'Z$') 'qa.at_utc debe ser ISO-8601 UTC'
    Assert-PwxNull $manifest.delivered_at 'delivered_at nulo hasta aprobar'

    $outEntry = @($manifest.outputs | Where-Object { $_.name -eq 'resultado.txt' })
    Assert-PwxTrue ($outEntry.Count -eq 1) 'outputs registra resultado.txt'
    Assert-PwxEqual (Get-PwxSha256 -Path (Join-Path $deliveryDir 'resultado.txt')) $outEntry[0].sha256 'manifest.outputs sha256 coincide con el archivo real'

    $cks = [System.IO.File]::ReadAllText($checksumsPath)
    $byPath = @{}
    foreach ($l in @($cks -split "`n" | Where-Object { $_ })) {
        if ($l -match '^([0-9A-Fa-f]{64})  (.+)$') { $byPath[$matches[2]] = $matches[1] }
    }
    Assert-PwxTrue ($byPath.ContainsKey('manifest.json')) 'checksums incluye manifest.json'
    Assert-PwxEqual (Get-PwxSha256 -Path $manifestPath) $byPath['manifest.json'] 'checksums sha256 == manifest.json real'
    Assert-PwxTrue ($byPath.ContainsKey('resultado.txt')) 'checksums incluye el entregable'
    Assert-PwxEqual (Get-PwxSha256 -Path (Join-Path $deliveryDir 'resultado.txt')) $byPath['resultado.txt'] 'checksums sha256 == entregable real'

    Approve-PwxDelivery -JobId $job.id -By 'tester'
    $manifestApproved = Get-PwxJsonFile -Path $manifestPath
    Assert-PwxEqual $manifest.created_utc $manifestApproved.created_utc 'created_utc no debe cambiar al aprobar'
    Assert-PwxNotNull $manifestApproved.delivered_at 'delivered_at se fija al aprobar'
    Assert-PwxEqual 'tester' $manifestApproved.approved_by 'approved_by se registra al aprobar'
    $byPathAfter = @{}
    foreach ($l in @([System.IO.File]::ReadAllText($checksumsPath) -split "`n" | Where-Object { $_ })) {
        if ($l -match '^([0-9A-Fa-f]{64})  (.+)$') { $byPathAfter[$matches[2]] = $matches[1] }
    }
    Assert-PwxTrue ($byPathAfter.ContainsKey('manifest.json')) 'checksums tras aprobar incluye manifest.json'
    Assert-PwxEqual (Get-PwxSha256 -Path $manifestPath) $byPathAfter['manifest.json'] 'checksums regenerado tras aprobar == manifest.json real'
    Assert-PwxEqual (Get-PwxSha256 -Path (Join-Path $deliveryDir 'resultado.txt')) $byPathAfter['resultado.txt'] 'checksums tras aprobar == entregable real'
}

Run-PwxTest -Name 'PAQUETE: inputs con sha256 real en manifest.json' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    $client = New-PwxClient -Name 'Cliente Paquete Inputs'
    $job = New-PwxJob -ClientId $client.id -Service 'simulate-service'
    $inFile = Join-Path $ws ('entrada-' + [guid]::NewGuid().ToString('N') + '.txt')
    [System.IO.File]::WriteAllText($inFile, 'contenido de entrada para el paquete', (New-Object System.Text.UTF8Encoding($false)))
    Add-PwxJobInputFile -JobId $job.id -SourcePath $inFile -TargetName 'datos.txt' | Out-Null

    $json = (New-PwxTestSimSpec -RequiredOutput @('resultado.txt') | ConvertTo-Json -Depth 5)
    Invoke-PwxRequirementsAgent -JobId $job.id -Request 'sim' -ForceJson $json | Out-Null
    Invoke-PwxProductionAgent -JobId $job.id | Out-Null
    New-PwxDelivery -JobId $job.id | Out-Null

    $manifest = Get-PwxJsonFile -Path (Join-Path (Find-PwxJob -JobId $job.id).JobDir 'delivery\manifest.json')
    $inEntry = @($manifest.inputs | Where-Object { $_.name -eq 'datos.txt' })
    Assert-PwxTrue ($inEntry.Count -eq 1) 'manifest.inputs registra datos.txt'
    Assert-PwxEqual (Get-PwxSha256 -Path $inFile) $inEntry[0].sha256 'input sha256 coincide con el hash real'
    Assert-PwxEqual ([long](Get-Item -LiteralPath $inFile).Length) ([long]$inEntry[0].bytes) 'input bytes coincide con el tamano real'
}

Run-PwxTest -Name 'PAQUETE: manifest con orden determinista de propiedades' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    $manifestPaths = @()
    foreach ($i in 1..2) {
        $client = New-PwxClient -Name ("Cliente Orden " + $i)
        $job = New-PwxJob -ClientId $client.id -Service 'simulate-service'
        $json = (New-PwxTestSimSpec -RequiredOutput @('resultado.txt') | ConvertTo-Json -Depth 5)
        Invoke-PwxRequirementsAgent -JobId $job.id -Request 'sim' -ForceJson $json | Out-Null
        Invoke-PwxProductionAgent -JobId $job.id | Out-Null
        New-PwxDelivery -JobId $job.id | Out-Null
        $manifestPaths += (Join-Path (Find-PwxJob -JobId $job.id).JobDir 'delivery\manifest.json')
    }
    $raw1 = [System.IO.File]::ReadAllText($manifestPaths[0])
    $raw2 = [System.IO.File]::ReadAllText($manifestPaths[1])
    $seq1 = @([regex]::Matches($raw1, '"([A-Za-z_][A-Za-z0-9_]*)"\s*:') | ForEach-Object { $_.Groups[1].Value })
    $seq2 = @([regex]::Matches($raw2, '"([A-Za-z_][A-Za-z0-9_]*)"\s*:') | ForEach-Object { $_.Groups[1].Value })
    Assert-PwxEqual ($seq1 -join ',') ($seq2 -join ',') 'Secuencia de claves identica entre dos manifests'

    $order = @('schema_version','job_id','client_id','service','created_utc','inputs','outputs','qa','notes','output_version','file_count','files','created_at','delivered_at','qa_checked_at','approved_by')
    $prev = -1
    foreach ($k in $order) {
        $idx = $raw1.IndexOf('"' + $k + '"')
        Assert-PwxTrue ($idx -gt $prev) ("Clave top-level '" + $k + "' debe aparecer en orden determinista")
        $prev = $idx
    }

    Assert-PwxTrue ($raw1 -match '"outputs"\s*:\s*\[[\s\S]*?"name"[\s\S]*?"path"[\s\S]*?"sha256"[\s\S]*?"bytes"') 'Salidas usan el orden name,path,sha256,bytes'
}