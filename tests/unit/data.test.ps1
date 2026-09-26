Run-PwxTest -Name 'data: limpieza determinista (dedupe, trim, emails, vacias, columnas)' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    $headers = @('Nombre ', ' Email ', 'Ciudad', 'Ciudad')
    $rows = @(
        , @('  Juan  Perez ', '  JUAN@MAIL.COM ', 'Bogotá')
        , @('Juan Perez', 'juan@mail.com', 'Bogotá')
        , @('Maria', '', 'Tunja')
        , @('   ', '  ', '')
        , @('Ana', 'ana@x.co', 'Medellín')
    )
    $clean = Invoke-PwxDataCleanTable -Headers $headers -Rows $rows
    Assert-PwxTrue $clean.ok 'limpieza ok'
    Assert-PwxEqual ('Nombre|Email|Ciudad|Ciudad_2') ($clean.headers -join '|') 'headers normalizados + dedupe'
    Assert-PwxEqual 5 $clean.rows_in 'filas entrada'
    Assert-PwxEqual 3 $clean.rows_out 'filas salida (Juan, Maria, Ana)'
    Assert-PwxEqual 1 $clean.duplicates '1 duplicada'
    Assert-PwxEqual 1 $clean.empties '1 vacia'
    Assert-PwxEqual 'Juan Perez' $clean.rows[0][0] 'trim de espacios'
    Assert-PwxEqual 'juan@mail.com' $clean.rows[0][1] 'email en minusculas'
}

Run-PwxTest -Name 'data: roundtrip CSV con comas, comillas y saltos dentro de campos' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    $dir = New-PwxDirectory -Path (Join-Path $ws 'out')
    $headers = @('campo', 'nota')
    $rows = @(, @('simple', 'sin dramas'))
    $rows += , @('con, coma', 'dijo "hola" y chao')
    $rows += , @('con salto', "linea1`nlinea2")
    $path = Join-Path $dir 'r.csv'
    Write-PwxCsvTable -Path $path -Headers $headers -Rows $rows
    $back = Read-PwxCsvTable -Path $path
    Assert-PwxTrue $back.ok 'relectura ok'
    Assert-PwxEqual 'campo' $back.headers[0] 'header 1'
    Assert-PwxEqual 'con, coma' $back.rows[1][0] 'coma dentro de campo'
    Assert-PwxEqual 'dijo "hola" y chao' $back.rows[1][1] 'comillas escapadas'
    Assert-PwxEqual "linea1`nlinea2" $back.rows[2][1] 'salto de linea dentro de campo'
    # determinismo
    $path2 = Join-Path $dir 'r2.csv'
    Write-PwxCsvTable -Path $path2 -Headers $headers -Rows $rows
    Assert-PwxEqual (Get-PwxSha256 -Path $path) (Get-PwxSha256 -Path $path2) 'bytes deterministas'
}

Run-PwxTest -Name 'data: servicio genera salida + informe y validador PASS' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    $client = New-PwxClient -Name 'Cliente Data' -Contact 'd@mail.com'
    $job = New-PwxJob -ClientId $client.id -Service 'data-service' -Description 'limpieza'
    $src = Join-Path $global:PwxRepoRoot 'tests\fixtures\datos-sucios.csv'
    Add-PwxJobInputFile -JobId $job.id -SourcePath $src -TargetName 'base.csv' | Out-Null
    $json = @{ service = 'data-service'; objective = 'limpiar base de contactos'; input_files = @('base.csv'); required_output = @('datos-limpios.csv', 'informe-limpieza.txt'); constraints = @(); missing_information = @(); acceptance_criteria = @() } | ConvertTo-Json -Depth 5
    $res = Invoke-PwxRequirementsAgent -JobId $job.id -Request 'limpiar' -ForceJson $json
    Assert-PwxTrue $res.ok 'requisitos ok'
    $out = Invoke-PwxService_data_service -JobId $job.id
    Assert-PwxTrue $out.ok "servicio ok (error=$($out.error))"
    Assert-PwxEqual 6 $out.rows_in '6 filas de entrada'
    Assert-PwxEqual 3 $out.rows_out '3 filas tras limpiar'
    $v = Test-PwxDataOutput -JobId $job.id
    Assert-PwxTrue $v.ok "validador PASS (detail=$($v.detail))"
    $found = Find-PwxJob -JobId $job.id
    $report = [System.IO.File]::ReadAllText((Join-Path $found.JobDir 'output\informe-limpieza.txt'))
    Assert-PwxTrue ($report -match 'duplicadas_removidas: 2') 'informe: 2 duplicadas (Juan y Carlos)'
    Assert-PwxTrue ($report -match 'vacias_removidas: 1') 'informe: 1 fila vacia'
}

Run-PwxTest -Name 'data: validador falla si la salida fue alterada' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    $client = New-PwxClient -Name 'Cliente Data QA' -Contact 'dq@mail.com'
    $job = New-PwxJob -ClientId $client.id -Service 'data-service' -Description 'qa'
    $src = Join-Path $global:PwxRepoRoot 'tests\fixtures\datos-sucios.csv'
    Add-PwxJobInputFile -JobId $job.id -SourcePath $src -TargetName 'base.csv' | Out-Null
    $json = @{ service = 'data-service'; objective = 'limpiar'; input_files = @('base.csv'); required_output = @('datos-limpios.csv', 'informe-limpieza.txt'); constraints = @(); missing_information = @(); acceptance_criteria = @() } | ConvertTo-Json -Depth 5
    Invoke-PwxRequirementsAgent -JobId $job.id -Request 'limpiar' -ForceJson $json | Out-Null
    $out = Invoke-PwxService_data_service -JobId $job.id
    Assert-PwxTrue $out.ok 'generacion inicial ok'
    $found = Find-PwxJob -JobId $job.id
    $cleanPath = Join-Path $found.JobDir 'output\datos-limpios.csv'

    # inyectar un duplicado de vuelta
    $t = Read-PwxCsvTable -Path $cleanPath
    $rows = @($t.rows)
    $rows += , @($t.rows[0][0], $t.rows[0][1], $t.rows[0][2])
    Write-PwxCsvTable -Path $cleanPath -Headers $t.headers -Rows $rows
    $v = Test-PwxDataOutput -JobId $job.id
    Assert-PwxTrue (-not $v.ok) 'salida alterada debe dar FAIL'
    Assert-PwxTrue ($v.detail -match 'distintas|duplicad|distinta') 'detalle de diferencia'
}
