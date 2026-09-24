$script:ExFixtures = Join-Path $global:PwxRepoRoot 'tests\fixtures'

function New-PwxExcelTestJob {
    param(
        [string[]]$InputTargetNames,
        [string[]]$ReqInputFiles,
        [string]$TargetService = 'excel-service',
        [hashtable]$Rename = @{}
    )
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    $client = New-PwxClient -Name 'Cliente Excel' -Contact 'excel@test.local'
    $job = New-PwxJob -ClientId $client.id -Service $TargetService -Description 'planilla de prueba'
    foreach ($n in $InputTargetNames) {
        $src = Join-Path $ExFixtures $n
        $target = if ($Rename.ContainsKey($n)) { $Rename[$n] } else { $n }
        Add-PwxJobInputFile -JobId $job.id -SourcePath $src -TargetName $target | Out-Null
    }
    $spec = @{
        service             = $TargetService
        objective           = 'normalizar planilla'
        input_files         = @($ReqInputFiles)
        required_output     = @('*.xlsx')
        constraints         = @()
        missing_information = @()
        acceptance_criteria = @('archivo xlsx valido')
    }
    $res = Invoke-PwxRequirementsAgent -JobId $job.id -Request 'normalizar planilla' -ForceJson ($spec | ConvertTo-Json -Depth 5)
    if (-not $res.ok) { throw "No se pudieron extraer requisitos: $($res.error)" }
    return $job
}

function Get-PwxExcelTestOutputPath {
    param([string]$JobId)
    $found = Find-PwxJob -JobId $JobId
    return (Join-Path $found.JobDir 'output\resultado-normalizado.xlsx')
}

Run-PwxTest -Name 'T-E1: excel-service procesa un xlsx valido y QA da PASS' -File 'unit\excel' -Body {
    $job = New-PwxExcelTestJob -InputTargetNames @('basic.xlsx') -ReqInputFiles @('basic.xlsx')
    $prod = Invoke-PwxProductionAgent -JobId $job.id
    Assert-PwxTrue $prod.ok -Message 'Produccion excel debe funcionar'
    Assert-PwxEqual 'READY_FOR_DELIVERY' $prod.state

    $outPath = Get-PwxExcelTestOutputPath -JobId $job.id
    Assert-PwxTrue (Test-Path -LiteralPath $outPath) 'Debe existir resultado-normalizado.xlsx'

    $jobAfter = Get-PwxJob -JobId $job.id
    $outEntry = @($jobAfter.files.output | Where-Object { $_.name -match '^resultado-normalizado\.xlsx$' })
    Assert-PwxTrue ($outEntry.Count -eq 1) 'Archivo de salida registrado en files.output'
    Assert-PwxNotNull $outEntry[0].sha256

    $qa = Get-PwxQaResult -JobId $job.id
    Assert-PwxEqual 'PASS' $qa.verdict
    $validator = @($qa.checks | Where-Object { $_.check -eq 'validator:Test-PwxExcelOutput' })
    Assert-PwxTrue ($validator.Count -eq 1 -and $validator[0].ok) 'Validator excel del QA debe ser PASS'
}

Run-PwxTest -Name 'T-E1b: la cuadricula se normaliza (ceros a la izquierda, filas/cols vacias, hoja1)' -File 'unit\excel' -Body {
    $job = New-PwxExcelTestJob -InputTargetNames @('basic.xlsx') -ReqInputFiles @('basic.xlsx')
    Invoke-PwxProductionAgent -JobId $job.id | Out-Null
    $outPath = Get-PwxExcelTestOutputPath -JobId $job.id
    $g = Read-PwxExcelGrid -Path $outPath
    Assert-PwxTrue $g.ok
    Assert-PwxEqual 6 $g.rows -Message 'Fila vacia eliminada'
    Assert-PwxEqual 5 $g.cols -Message 'Columna vacia (E) eliminada'

    $c01 = $g.cells[0][0]; $c02 = $g.cells[1][0]
    Assert-PwxTrue ($c01.text -and $c01.value -eq 'Nombre') 'Header texto'
    Assert-PwxTrue ($c02.text -and $c02.value -eq 'Producto A') 'Celda texto preservada'

    $cB2 = $g.cells[1][1]
    Assert-PwxTrue ((-not $cB2.text) -and $cB2.value -eq '1234') 'Numero preservado como numero'

    $cC2 = $g.cells[1][2]
    Assert-PwxTrue ($cC2.text -and $cC2.value -eq '00123') 'Cero a la izquierda NO se convierte en 123'

    $cC4 = $g.cells[3][2]
    Assert-PwxTrue ($cC4.text -and $cC4.value -eq '007') 'Cero a la izquierda en fila tras fila vacia'

    $cD5 = $g.cells[4][3]
    Assert-PwxTrue ((-not $cD5.text) -and $cD5.value -eq '45325') 'Fecha conservada como serial numerico'

    $cF6 = $g.cells[5][4]
    Assert-PwxTrue ((-not $cF6.text) -and $cF6.value -eq '9') 'Columna F compactada tras columna vacia E'

    $hasHoja2 = $false
    for ($i = 0; $i -lt $g.rows; $i++) {
        for ($j = 0; $j -lt $g.cols; $j++) {
            $c = $g.cells[$i][$j]
            if (-not $c.empty -and $c.value -eq 'no-se-usa') { $hasHoja2 = $true }
        }
    }
    Assert-PwxTrue (-not $hasHoja2) 'Solo se usa la hoja 1'

    $esc = $g.cells[4][0]
    Assert-PwxTrue ($esc.text -and $esc.value -eq 'X & Y <etiqueta>') 'Escapado XML texto preservado'
}

Run-PwxTest -Name 'T-E2: .txt renombrado .xlsx -> EXCEL_NOT_ZIP y BLOCKED' -File 'unit\excel' -Body {
    $job = New-PwxExcelTestJob -InputTargetNames @('fake.txt') -ReqInputFiles @('fake.xlsx') -Rename @{ 'fake.txt' = 'fake.xlsx' }
    $prod = Invoke-PwxProductionAgent -JobId $job.id
    Assert-PwxTrue (-not $prod.ok) 'Debe fallar'
    Assert-PwxEqual 'EXCEL_NOT_ZIP' $prod.error
    Assert-PwxEqual 'BLOCKED' $prod.state
    Assert-PwxEqual 'BLOCKED' (Get-PwxJob -JobId $job.id).state
}

Run-PwxTest -Name 'T-E3: zip truncado / XML roto / partes faltantes -> errores tipificados y BLOCKED' -File 'unit\excel' -Body {
    $pairs = @(
        @{ fixture = 'truncated.xlsx';   code = 'EXCEL_NOT_ZIP' }
        @{ fixture = 'invalid-xml.xlsx'; code = 'EXCEL_BAD_XML' }
        @{ fixture = 'missing-parts.xlsx'; code = 'EXCEL_MISSING_PARTS' }
    )
    foreach ($p in $pairs) {
        $job = New-PwxExcelTestJob -InputTargetNames @($p.fixture) -ReqInputFiles @($p.fixture)
        $prod = Invoke-PwxProductionAgent -JobId $job.id
        Assert-PwxTrue (-not $prod.ok) "Debe fallar: $($p.fixture)"
        Assert-PwxEqual $p.code $prod.error "Codigo para $($p.fixture)"
        Assert-PwxEqual 'BLOCKED' (Get-PwxJob -JobId $job.id).state "$($p.fixture) debe quedar BLOCKED"
    }
}

Run-PwxTest -Name 'T-E4: sin input -> EXCEL_NO_INPUT; dos inputs -> EXCEL_MULTIPLE_INPUTS' -File 'unit\excel' -Body {
    $job1 = New-PwxExcelTestJob -InputTargetNames @() -ReqInputFiles @()
    $prod1 = Invoke-PwxProductionAgent -JobId $job1.id
    Assert-PwxEqual 'EXCEL_NO_INPUT' $prod1.error
    Assert-PwxEqual 'BLOCKED' $prod1.state

    $job2 = New-PwxExcelTestJob -InputTargetNames @('basic.xlsx', 'empty-sheet.xlsx') -ReqInputFiles @()
    $prod2 = Invoke-PwxProductionAgent -JobId $job2.id
    Assert-PwxEqual 'EXCEL_MULTIPLE_INPUTS' $prod2.error
    Assert-PwxEqual 'BLOCKED' $prod2.state
}

Run-PwxTest -Name 'T-E5: hoja sin celdas con valor -> EXCEL_EMPTY' -File 'unit\excel' -Body {
    $job = New-PwxExcelTestJob -InputTargetNames @('empty-sheet.xlsx') -ReqInputFiles @('empty-sheet.xlsx')
    $prod = Invoke-PwxProductionAgent -JobId $job.id
    Assert-PwxEqual 'EXCEL_EMPTY' $prod.error
    Assert-PwxEqual 'BLOCKED' $prod.state
}

Run-PwxTest -Name 'T-E6: determinismo, rework y versionado' -File 'unit\excel' -Body {
    $job = New-PwxExcelTestJob -InputTargetNames @('basic.xlsx') -ReqInputFiles @('basic.xlsx')
    $p1 = Invoke-PwxProductionAgent -JobId $job.id
    Assert-PwxTrue $p1.ok
    $outPath = Get-PwxExcelTestOutputPath -JobId $job.id
    $sha1 = Get-PwxSha256 -Path $outPath

    Set-PwxJobState -JobId $job.id -To 'BLOCKED' -Reason 'revision' | Out-Null
    Set-PwxJobState -JobId $job.id -To 'REQUIREMENTS' -Reason 'revision' | Out-Null
    $spec = @{
        service = 'excel-service'; objective = 'normalizar planilla'
        input_files = @('basic.xlsx'); required_output = @('*.xlsx')
        constraints = @(); missing_information = @(); acceptance_criteria = @()
    }
    Invoke-PwxRequirementsAgent -JobId $job.id -Request 'normalizar' -ForceJson ($spec | ConvertTo-Json -Depth 5) | Out-Null
    $p2 = Invoke-PwxProductionAgent -JobId $job.id
    Assert-PwxTrue $p2.ok

    $sha2 = Get-PwxSha256 -Path $outPath
    Assert-PwxEqual $sha1 $sha2 -Message 'Mismo input -> mismo SHA256 (determinismo binario: el writer fija los timestamps DOS de las entradas ZIP)'

    $jobAfter = Get-PwxJob -JobId $job.id
    Assert-PwxEqual 2 ([int]$jobAfter.output_version) 'output_version debe incrementarse tras rework'

    $found = Find-PwxJob -JobId $job.id
    $v1file = Join-Path $found.JobDir 'versions\v1\resultado-normalizado.xlsx'
    Assert-PwxTrue (Test-Path -LiteralPath $v1file) 'versions/v1 debe preservar la version anterior'
}

Run-PwxTest -Name 'T-E7: output corrompido despues de producir -> QA FAIL (nunca PASS)' -File 'unit\excel' -Body {
    $job = New-PwxExcelTestJob -InputTargetNames @('basic.xlsx') -ReqInputFiles @('basic.xlsx')
    $prod = Invoke-PwxProductionAgent -JobId $job.id
    Assert-PwxTrue $prod.ok
    $outPath = Get-PwxExcelTestOutputPath -JobId $job.id
    Assert-PwxTrue (Test-Path -LiteralPath $outPath)

    $bytes = [System.IO.File]::ReadAllBytes($outPath)
    $keep = [int]($bytes.Length * 0.8)
    [System.IO.File]::WriteAllBytes($outPath, $bytes[0..($keep - 1)])
    Assert-PwxTrue ((Get-Item -LiteralPath $outPath).Length -gt 0) 'Archivo corrupto sigue teniendo bytes'

    $qa = Invoke-PwxQa -JobId $job.id
    Assert-PwxEqual 'FAIL' $qa.verdict -Message 'QA debe fallar con output corrompido'
    $validator = @($qa.checks | Where-Object { $_.check -eq 'validator:Test-PwxExcelOutput' })
    Assert-PwxTrue ($validator.Count -eq 1 -and (-not $validator[0].ok)) 'Validator excel debe marcar la corrupcion'
}

Run-PwxTest -Name 'T-E8: output == normalizacion del input (celda a celda)' -File 'unit\excel' -Body {
    $job = New-PwxExcelTestJob -InputTargetNames @('basic.xlsx') -ReqInputFiles @('basic.xlsx')
    $prod = Invoke-PwxProductionAgent -JobId $job.id
    Assert-PwxTrue $prod.ok

    $inPath = Join-Path (Find-PwxJob -JobId $job.id).JobDir 'input\basic.xlsx'
    $outPath = Get-PwxExcelTestOutputPath -JobId $job.id
    $gIn = Read-PwxExcelGrid -Path $inPath
    $gOut = Read-PwxExcelGrid -Path $outPath
    Assert-PwxTrue $gIn.ok
    Assert-PwxTrue $gOut.ok
    $cmp = Compare-PwxExcelGrid -A $gIn -B $gOut
    Assert-PwxTrue $cmp.ok -Message "La grilla de salida debe ser identica a la normalizacion del input: $($cmp.detail)"
}

Run-PwxTest -Name 'T-E9: limites defensivos devuelven EXCEL_LIMITS_EXCEEDED' -File 'unit\excel' -Body {
    $originalMaxRows = $global:PwxExcelMaxRows
    $originalMaxCols = $global:PwxExcelMaxCols
    $originalMaxCells = $global:PwxExcelMaxCells
    try {
        $global:PwxExcelMaxRows = 2
        $global:PwxExcelMaxCols = 2
        $r = Read-PwxExcelGrid -Path (Join-Path $ExFixtures 'basic.xlsx')
        Assert-PwxEqual 'EXCEL_LIMITS_EXCEEDED' $r.code 'basic.xlsx (6 filas) debe exceder el limite temporal de 2 filas'
    }
    finally {
        $global:PwxExcelMaxRows = $originalMaxRows
        $global:PwxExcelMaxCols = $originalMaxCols
        $global:PwxExcelMaxCells = $originalMaxCells
    }

    try {
        $global:PwxExcelMaxRows = $originalMaxRows
        $global:PwxExcelMaxCols = 2
        $global:PwxExcelMaxCells = $originalMaxCells
        $r = Read-PwxExcelGrid -Path (Join-Path $ExFixtures 'basic.xlsx')
        Assert-PwxEqual 'EXCEL_LIMITS_EXCEEDED' $r.code 'basic.xlsx (5 columnas) debe exceder el limite temporal de 2 columnas'
    }
    finally {
        $global:PwxExcelMaxRows = $originalMaxRows
        $global:PwxExcelMaxCols = $originalMaxCols
        $global:PwxExcelMaxCells = $originalMaxCells
    }

    try {
        $global:PwxExcelMaxRows = $originalMaxRows
        $global:PwxExcelMaxCols = $originalMaxCols
        $global:PwxExcelMaxCells = 10
        $r = Read-PwxExcelGrid -Path (Join-Path $ExFixtures 'basic.xlsx')
        Assert-PwxEqual 'EXCEL_LIMITS_EXCEEDED' $r.code 'basic.xlsx (30 celdas) debe exceder el limite temporal de 10 celdas'
    }
    finally {
        $global:PwxExcelMaxRows = $originalMaxRows
        $global:PwxExcelMaxCols = $originalMaxCols
        $global:PwxExcelMaxCells = $originalMaxCells
    }

    $r2 = Read-PwxExcelGrid -Path (Join-Path $ExFixtures 'basic.xlsx')
    Assert-PwxTrue $r2.ok 'Restaurando limites el archivo normal debe seguir leyendose'
}

Run-PwxTest -Name 'T-E10: M-1 determinismo binario: mismo grid -> mismo SHA256 pese a separacion temporal (>2s)' -File 'unit\excel' -Body {
    $g = Read-PwxExcelGrid -Path (Join-Path $ExFixtures 'basic.xlsx')
    Assert-PwxTrue $g.ok
    $dir = Join-Path (Get-PwxTestWorkspace) 'm1'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $a = Join-Path $dir 'a.xlsx'
    $b = Join-Path $dir 'b.xlsx'
    Write-PwxExcelGrid -Path $a -Grid $g
    Start-Sleep -Seconds 3
    Write-PwxExcelGrid -Path $b -Grid $g
    $shaA = Get-PwxSha256 -Path $a
    $shaB = Get-PwxSha256 -Path $b
    Assert-PwxEqual $shaA $shaB 'Mismo grid -> mismo SHA256 (determinismo binario: timestamps DOS de las entradas ZIP fijos)'
}