Run-PwxTest -Name 'construction: parseo de numeros variantes (es/en, miles, moneda)' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    Assert-PwxEqual 150000.50 (ConvertFrom-PwxConstructionNumber -Raw '150000.50' -Field 'x' -Row 1) 'decimal punto'
    Assert-PwxEqual 1234.56 (ConvertFrom-PwxConstructionNumber -Raw '1.234,56' -Field 'x' -Row 1) 'miles punto + decimal coma'
    Assert-PwxEqual 1234.56 (ConvertFrom-PwxConstructionNumber -Raw '1,234.56' -Field 'x' -Row 1) 'miles coma + decimal punto'
    Assert-PwxEqual 1.25 (ConvertFrom-PwxConstructionNumber -Raw '1,250' -Field 'x' -Row 1) 'coma suelta = decimal'
    Assert-PwxEqual 150000.5 (ConvertFrom-PwxConstructionNumber -Raw '$ 150000.50' -Field 'x' -Row 1) 'simbolo peso'
    Assert-PwxEqual 99.99 (ConvertFrom-PwxConstructionNumber -Raw 'COP 99.99' -Field 'x' -Row 1) 'prefijo COP'
    $threw = $false
    try { ConvertFrom-PwxConstructionNumber -Raw 'no-es-numero' -Field 'cantidad' -Row 7 | Out-Null }
    catch { $threw = $true; Assert-PwxTrue ($_.Exception.Message -like '*CONSTRUCTION_BAD_INPUT*') 'codigo en el mensaje' }
    Assert-PwxTrue $threw 'texto no numerico lanza error'
}

Run-PwxTest -Name 'construction: totales exactos del fixture (AwayFromZero 2 dec)' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    $path = Join-Path $global:PwxRepoRoot 'tests\fixtures\partidas.csv'
    $plan = Get-PwxConstructionPlan -Path $path
    Assert-PwxTrue $plan.ok "plan ok (detail=$($plan.detail))"
    Assert-PwxEqual 5 @($plan.lines).Count '5 partidas'
    Assert-PwxEqual 450001.50 $plan.lines[0].total 'linea 1: 3 * 150000.50'
    Assert-PwxEqual 11125000 $plan.lines[1].total 'linea 2: 12.5 * 890000'
    Assert-PwxEqual 4875.94 $plan.lines[2].total 'linea 3: 1.25 * 3900.75 redondeado'
    Assert-PwxEqual 1751761.38 $plan.lines[4].total 'linea 5: 45.5 * 38500.25 redondeado'
    Assert-PwxEqual 19091638.82 $plan.total 'total general'
}

Run-PwxTest -Name 'construction: servicio genera presupuesto.xlsx y validador PASS (determinista)' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    $client = New-PwxClient -Name 'Cliente Obra' -Contact 'o@mail.com'
    $job = New-PwxJob -ClientId $client.id -Service 'construction-service' -Description 'computo'
    $src = Join-Path $global:PwxRepoRoot 'tests\fixtures\partidas.csv'
    Add-PwxJobInputFile -JobId $job.id -SourcePath $src -TargetName 'partidas.csv' | Out-Null
    $json = @{ service = 'construction-service'; objective = 'computo de obra'; input_files = @('partidas.csv'); required_output = @('presupuesto.xlsx'); constraints = @(); missing_information = @(); acceptance_criteria = @() } | ConvertTo-Json -Depth 5
    $res = Invoke-PwxRequirementsAgent -JobId $job.id -Request 'computo' -ForceJson $json
    Assert-PwxTrue $res.ok 'requisitos ok'
    $out = Invoke-PwxService_construction_service -JobId $job.id
    Assert-PwxTrue $out.ok "servicio ok (error=$($out.error))"
    Assert-PwxEqual 19091638.82 $out.total 'total reportado'
    $v = Test-PwxConstructionOutput -JobId $job.id
    Assert-PwxTrue $v.ok "validador PASS (detail=$($v.detail))"

    # grilla: encabezados + fila TOTAL
    $found = Find-PwxJob -JobId $job.id
    $grid = Read-PwxExcelGrid -Path (Join-Path $found.JobDir 'output\presupuesto.xlsx')
    Assert-PwxTrue $grid.ok 'lectura xlsx'
    Assert-PwxEqual 7 $grid.rows '1 header + 5 partidas + TOTAL'
    Assert-PwxEqual 'Partida' $grid.cells[0][0].value 'header 1'
    Assert-PwxEqual 'TOTAL' $grid.cells[6][0].value 'fila TOTAL'
    Assert-PwxEqual '19091638.82' $grid.cells[6][5].value 'celda TOTAL'
    # determinismo
    $sha1 = Get-PwxSha256 -Path (Join-Path $found.JobDir 'output\presupuesto.xlsx')
    $out2 = Invoke-PwxService_construction_service -JobId $job.id
    Assert-PwxTrue $out2.ok 'segunda corrida ok'
    Assert-PwxEqual $sha1 (Get-PwxSha256 -Path (Join-Path $found.JobDir 'output\presupuesto.xlsx')) 'bytes deterministas'
}

Run-PwxTest -Name 'construction: errores de entrada (columnas faltantes, cantidad <= 0)' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    $dir = New-PwxDirectory -Path (Join-Path $ws 'src')

    # sin columna precio
    $bad1 = Join-Path $dir 'sin-precio.csv'
    [System.IO.File]::WriteAllText($bad1, "descripcion,unidad,cantidad`nZapata,und,3`n", (New-Object System.Text.UTF8Encoding($false)))
    $plan1 = Get-PwxConstructionPlan -Path $bad1
    Assert-PwxTrue (-not $plan1.ok) 'falta precio -> error'
    Assert-PwxEqual 'CONSTRUCTION_BAD_INPUT' $plan1.code 'codigo BAD_INPUT'
    Assert-PwxTrue ($plan1.detail -like '*precio*') 'detalle menciona la columna faltante'

    # cantidad negativa
    $bad2 = Join-Path $dir 'negativa.csv'
    [System.IO.File]::WriteAllText($bad2, "descripcion,unidad,cantidad,precio`nZapata,und,-3,100`n", (New-Object System.Text.UTF8Encoding($false)))
    $plan2 = Get-PwxConstructionPlan -Path $bad2
    Assert-PwxTrue (-not $plan2.ok) 'cantidad negativa -> error'
    Assert-PwxTrue ($plan2.detail -like '*positiva*') 'detalle menciona cantidad no positiva'

    # servicio devuelve el codigo correcto (sin excepcion fuera del contrato)
    $client = New-PwxClient -Name 'Cliente Obra Mal' -Contact 'om@mail.com'
    $job = New-PwxJob -ClientId $client.id -Service 'construction-service' -Description 'mal'
    Add-PwxJobInputFile -JobId $job.id -SourcePath $bad2 -TargetName 'partidas.csv' | Out-Null
    $json = @{ service = 'construction-service'; objective = 'x'; input_files = @('partidas.csv'); required_output = @('presupuesto.xlsx'); constraints = @(); missing_information = @(); acceptance_criteria = @() } | ConvertTo-Json -Depth 5
    Invoke-PwxRequirementsAgent -JobId $job.id -Request 'x' -ForceJson $json | Out-Null
    $out = Invoke-PwxService_construction_service -JobId $job.id
    Assert-PwxTrue (-not $out.ok) 'servicio no ok'
    Assert-PwxEqual 'CONSTRUCTION_BAD_INPUT' $out.error 'error de contrato CONSTRUCTION_BAD_INPUT'
}

Run-PwxTest -Name 'construction: validador falla si el xlsx fue alterado' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    $client = New-PwxClient -Name 'Cliente Obra QA' -Contact 'oq@mail.com'
    $job = New-PwxJob -ClientId $client.id -Service 'construction-service' -Description 'qa'
    $src = Join-Path $global:PwxRepoRoot 'tests\fixtures\partidas.csv'
    Add-PwxJobInputFile -JobId $job.id -SourcePath $src -TargetName 'partidas.csv' | Out-Null
    $json = @{ service = 'construction-service'; objective = 'x'; input_files = @('partidas.csv'); required_output = @('presupuesto.xlsx'); constraints = @(); missing_information = @(); acceptance_criteria = @() } | ConvertTo-Json -Depth 5
    Invoke-PwxRequirementsAgent -JobId $job.id -Request 'x' -ForceJson $json | Out-Null
    $out = Invoke-PwxService_construction_service -JobId $job.id
    Assert-PwxTrue $out.ok 'generacion inicial ok'
    $found = Find-PwxJob -JobId $job.id
    $file = Join-Path $found.JobDir 'output\presupuesto.xlsx'

    $grid = Read-PwxExcelGrid -Path $file
    $cells = @()
    foreach ($row in $grid.cells) {
        $newRow = @()
        foreach ($c in $row) {
            if (-not $c.empty -and -not $c.text -and $c.value -eq '19091638.82') {
                $newRow += (New-PwxExcelCell -Empty $false -Text $false -Value '9999999999')
            }
            else { $newRow += $c }
        }
        $cells += , @($newRow)
    }
    $tampered = [pscustomobject]@{ cells = $cells; rows = $grid.rows; cols = $grid.cols }
    Write-PwxExcelGrid -Path $file -Grid $tampered

    $v = Test-PwxConstructionOutput -JobId $job.id
    Assert-PwxTrue (-not $v.ok) 'xlsx alterado debe dar FAIL'
}
