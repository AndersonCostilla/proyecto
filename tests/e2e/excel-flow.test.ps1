$script:ExFixtures = Join-Path $global:PwxRepoRoot 'tests\fixtures'

Run-PwxTest -Name 'E2E: excel-service ciclo completo hasta DELIVERED con verificacion de entrega' -File 'e2e\excel' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap

    $client = New-PwxClient -Name 'Cliente Excel E2E' -Contact 'e2e@mail.com'
    $job = New-PwxJob -ClientId $client.id -Service 'excel-service' -Description 'Planilla de precios'
    Assert-PwxEqual 'NEW' $job.state

    Add-PwxJobInputFile -JobId $job.id -SourcePath (Join-Path $ExFixtures 'basic.xlsx') -TargetName 'planilla.xlsx' | Out-Null

    $json = @{
        service = 'excel-service'
        objective = 'normalizar planilla de precios'
        input_files = @('planilla.xlsx')
        required_output = @('*.xlsx')
        constraints = @()
        missing_information = @()
        acceptance_criteria = @('xlsx valido')
    } | ConvertTo-Json -Depth 5

    $res = Invoke-PwxRequirementsAgent -JobId $job.id -Request 'normalizar planilla de precios' -ForceJson $json
    Assert-PwxTrue $res.ok
    Assert-PwxEqual 'excel-service' $res.spec.service
    Assert-PwxEqual 'READY_FOR_PRODUCTION' (Get-PwxJob -JobId $job.id).state

    $prod = Invoke-PwxProductionAgent -JobId $job.id
    Assert-PwxTrue $prod.ok -Message 'Produccion excel debe funcionar'
    Assert-PwxEqual 'READY_FOR_DELIVERY' $prod.state

    $qa = Get-PwxQaResult -JobId $job.id
    Assert-PwxEqual 'PASS' $qa.verdict
    $validator = @($qa.checks | Where-Object { $_.check -eq 'validator:Test-PwxExcelOutput' })
    Assert-PwxTrue ($validator.Count -eq 1 -and $validator[0].ok) 'Validator excel PASS en el QA'

    $jobBefore = Get-PwxJob -JobId $job.id
    $outputVersion = [int]$jobBefore.output_version

    $delivery = New-PwxDelivery -JobId $job.id
    Assert-PwxEqual $outputVersion ([int]$delivery.output_version) 'Manifest refleja la output_version'

    $found = Find-PwxJob -JobId $job.id
    $outPath = Join-Path $found.JobDir 'output\resultado-normalizado.xlsx'
    $deliveredPath = Join-Path $found.JobDir 'delivery\resultado-normalizado.xlsx'
    Assert-PwxTrue (Test-Path -LiteralPath $deliveredPath) 'Archivo entregado en delivery/'

    $manifestEntry = @($delivery.files | Where-Object { $_.name -eq 'resultado-normalizado.xlsx' })
    Assert-PwxTrue ($manifestEntry.Count -eq 1) 'Manifest registra el xlsx'
    Assert-PwxEqual (Get-PwxSha256 -Path $outPath) $manifestEntry[0].sha256 'manifest sha256 == hash del archivo de salida'

    $manifestPath = Join-Path $found.JobDir 'delivery\manifest.json'
    $manifest = Get-PwxJsonFile -Path $manifestPath
    Assert-PwxEqual '1' $manifest.schema_version
    Assert-PwxEqual $job.id $manifest.job_id
    Assert-PwxEqual $client.id $manifest.client_id
    Assert-PwxEqual 'excel-service' $manifest.service
    Assert-PwxEqual 'PASS' $manifest.qa.verdict
    $stdEntry = @($manifest.outputs | Where-Object { $_.name -eq 'resultado-normalizado.xlsx' })
    Assert-PwxTrue ($stdEntry.Count -eq 1) 'manifest.outputs registra el xlsx'
    Assert-PwxEqual (Get-PwxSha256 -Path $outPath) $stdEntry[0].sha256 'manifest.outputs sha256 == hash real'

    $checksumsPath = Join-Path $found.JobDir 'delivery\checksums.sha256'
    Assert-PwxTrue (Test-Path -LiteralPath $checksumsPath) 'checksums.sha256 debe existir'
    $cks = [System.IO.File]::ReadAllText($checksumsPath)
    Assert-PwxTrue ($cks -match ([regex]::Escape('manifest.json'))) 'checksums incluye manifest.json'
    Assert-PwxTrue ($cks -match ([regex]::Escape('resultado-normalizado.xlsx'))) 'checksums incluye el entregable'

    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue | Out-Null
    $zip = $null
    try { $zip = [System.IO.Compression.ZipFile]::OpenRead($deliveredPath) }
    catch {}
    Assert-PwxNotNull $zip 'El archivo entregado debe volver a abrirse como ZIP'
    if ($zip) { $zip.Dispose() }

    Approve-PwxDelivery -JobId $job.id -By 'tester'
    Assert-PwxEqual 'DELIVERED' (Get-PwxJob -JobId $job.id).state
}