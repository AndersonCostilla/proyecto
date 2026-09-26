# E2E de los 4 servicios implementados: ciclo completo
# cliente -> requisitos (ForceJson, sin Ollama) -> produccion -> QA -> entrega -> aprobacion.

function Invoke-PwxE2EServiceCycle {
    param(
        [string]$Service,
        [string]$Fixture,       # archivo de input (o '' si no aplica)
        [string]$TargetName,
        [string[]]$InputFiles,  # input_files del spec
        [string[]]$RequiredOutput,
        [string]$DeliveredFile
    )
    $client = New-PwxClient -Name "Cliente E2E $Service" -Contact 'e2e@mail.com'
    $job = New-PwxJob -ClientId $client.id -Service $Service -Description "ciclo $Service"
    Assert-PwxEqual 'NEW' $job.state 'estado inicial NEW'

    if ($Fixture) {
        $src = Join-Path $global:PwxRepoRoot ("tests\fixtures\" + $Fixture)
        Add-PwxJobInputFile -JobId $job.id -SourcePath $src -TargetName $TargetName | Out-Null
    }

    $json = @{
        service             = $Service
        objective           = "objetivo e2e de $Service"
        input_files         = $InputFiles
        required_output     = $RequiredOutput
        constraints         = @()
        missing_information = @()
        acceptance_criteria = @('salida valida')
    } | ConvertTo-Json -Depth 5

    $res = Invoke-PwxRequirementsAgent -JobId $job.id -Request 'solicitud e2e' -ForceJson $json
    Assert-PwxTrue $res.ok 'requisitos ok'
    Assert-PwxEqual $Service $res.spec.service 'servicio del spec'
    Assert-PwxEqual 'READY_FOR_PRODUCTION' (Get-PwxJob -JobId $job.id).state 'listo para produccion'

    $prod = Invoke-PwxProductionAgent -JobId $job.id
    Assert-PwxTrue $prod.ok "produccion ok (error=$($prod.error))"
    Assert-PwxEqual 'READY_FOR_DELIVERY' $prod.state 'produccion + QA PASS'

    $qa = Get-PwxQaResult -JobId $job.id
    Assert-PwxEqual 'PASS' $qa.verdict 'QA PASS'
    $validator = @($qa.checks | Where-Object { $_.check -like 'validator:Test-Pwx*' })
    Assert-PwxEqual 1 $validator.Count 'exactamente un validador de servicio'
    Assert-PwxTrue $validator[0].ok 'validador de servicio PASS'

    $delivery = New-PwxDelivery -JobId $job.id
    Assert-PwxNotNull $delivery 'delivery creado'
    $found = Find-PwxJob -JobId $job.id
    Assert-PwxTrue (Test-Path -LiteralPath (Join-Path $found.JobDir ("delivery\" + $DeliveredFile))) 'entregable en delivery/'
    $manifest = Get-PwxJsonFile -Path (Join-Path $found.JobDir 'delivery\manifest.json')
    Assert-PwxEqual $Service $manifest.service 'manifest.service'
    Assert-PwxEqual 'PASS' $manifest.qa.verdict 'manifest QA PASS'

    Approve-PwxDelivery -JobId $job.id -By 'tester'
    Assert-PwxEqual 'DELIVERED' (Get-PwxJob -JobId $job.id).state 'estado final DELIVERED'
}

Run-PwxTest -Name 'E2E: word-service ciclo completo hasta DELIVERED' -File 'e2e\services' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    Invoke-PwxE2EServiceCycle -Service 'word-service' -Fixture 'muestra.txt' -TargetName 'entrada.txt' -InputFiles @('entrada.txt') -RequiredOutput @('documento.docx') -DeliveredFile 'documento.docx'
}

Run-PwxTest -Name 'E2E: pdf-service ciclo completo hasta DELIVERED' -File 'e2e\services' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    Invoke-PwxE2EServiceCycle -Service 'pdf-service' -Fixture 'muestra.txt' -TargetName 'entrada.txt' -InputFiles @('entrada.txt') -RequiredOutput @('documento.pdf') -DeliveredFile 'documento.pdf'
}

Run-PwxTest -Name 'E2E: data-service ciclo completo hasta DELIVERED' -File 'e2e\services' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    Invoke-PwxE2EServiceCycle -Service 'data-service' -Fixture 'datos-sucios.csv' -TargetName 'base.csv' -InputFiles @('base.csv') -RequiredOutput @('datos-limpios.csv', 'informe-limpieza.txt') -DeliveredFile 'datos-limpios.csv'
}

Run-PwxTest -Name 'E2E: construction-service ciclo completo hasta DELIVERED' -File 'e2e\services' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    Invoke-PwxE2EServiceCycle -Service 'construction-service' -Fixture 'partidas.csv' -TargetName 'partidas.csv' -InputFiles @('partidas.csv') -RequiredOutput @('presupuesto.xlsx') -DeliveredFile 'presupuesto.xlsx'
}

Run-PwxTest -Name 'E2E: word-service sin input tambien llega a DELIVERED (desde spec)' -File 'e2e\services' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    Invoke-PwxE2EServiceCycle -Service 'word-service' -Fixture '' -TargetName '' -InputFiles @() -RequiredOutput @('documento.docx') -DeliveredFile 'documento.docx'
}
