Run-PwxTest -Name 'pdf: estructura valida, xref con offsets reales y determinismo' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    $dir = New-PwxDirectory -Path (Join-Path $ws 'out')
    $paras = @('Propuesta económica para la obra', 'Linea de cuerpo normal.', ('Relleno para multiplas lineas. ' * 40))
    $p1 = Join-Path $dir 'a.pdf'
    Write-PwxPdfDocument -Path $p1 -Paragraphs $paras
    Assert-PwxTrue (Test-Path -LiteralPath $p1) 'pdf creado'
    $bytes = [System.IO.File]::ReadAllBytes($p1)
    $text = [System.Text.Encoding]::GetEncoding(28591).GetString($bytes)
    Assert-PwxTrue $text.StartsWith('%PDF-1.4') 'cabecera PDF-1.4'
    Assert-PwxTrue ($text.TrimEnd() -like '*%%EOF') 'cierra con %%EOF'
    Assert-PwxTrue ($text -match '/Type /Page\b') 'contiene paginas'

    # offsets de xref reales
    Assert-PwxTrue ($text -match 'startxref\s+(\d+)\s+%%EOF\s*$') 'startxref presente'
    $xr = [int]$Matches[1]
    Assert-PwxTrue $text.Substring($xr).StartsWith('xref') 'startxref apunta a xref'
    $lines = @($text.Substring($xr) -split "`n")
    Assert-PwxTrue ($lines[1] -match '^0 (\d+)$') 'cabecera xref'
    $total = [int]$Matches[1]
    $entries = @($lines | Select-Object -Skip 2 -First $total)
    for ($n = 1; $n -lt $total; $n++) {
        $e = $entries[$n]
        Assert-PwxTrue ($e -match '^(\d{10}) \d{5} n $') "entrada xref $n con formato"
        $off = [int]$Matches[1]
        Assert-PwxTrue $text.Substring($off).StartsWith("$n 0 obj") "offset $n apunta al objeto $n"
    }

    # determinismo byte a byte
    $p2 = Join-Path $dir 'b.pdf'
    Write-PwxPdfDocument -Path $p2 -Paragraphs $paras
    Assert-PwxEqual (Get-PwxSha256 -Path $p1) (Get-PwxSha256 -Path $p2) 'bytes deterministas'
}

Run-PwxTest -Name 'pdf: servicio + validador PASS y lectura de texto extraido' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    $client = New-PwxClient -Name 'Cliente PDF' -Contact 'p@mail.com'
    $job = New-PwxJob -ClientId $client.id -Service 'pdf-service' -Description 'propuesta'
    $src = Join-Path $ws 'entrada.txt'
    [System.IO.File]::WriteAllText($src, "Propuesta economica nro 1`nDetalle de trabajos con acentuacion: gestión, plazos y costos.`n", (New-Object System.Text.UTF8Encoding($false)))
    Add-PwxJobInputFile -JobId $job.id -SourcePath $src -TargetName 'entrada.txt' | Out-Null
    $json = @{ service = 'pdf-service'; objective = 'propuesta en pdf'; input_files = @('entrada.txt'); required_output = @('documento.pdf'); constraints = @(); missing_information = @(); acceptance_criteria = @() } | ConvertTo-Json -Depth 5
    $res = Invoke-PwxRequirementsAgent -JobId $job.id -Request 'propuesta' -ForceJson $json
    Assert-PwxTrue $res.ok 'requisitos ok'
    $out = Invoke-PwxService_pdf_service -JobId $job.id
    Assert-PwxTrue $out.ok "servicio ok (error=$($out.error))"
    $v = Test-PwxPdfOutput -JobId $job.id
    Assert-PwxTrue $v.ok "validador PASS (detail=$($v.detail))"
    # el texto extraido refleja el input (con acentos via WinAnsi)
    $found = Find-PwxJob -JobId $job.id
    $extracted = Read-PwxPdfText -Path (Join-Path $found.JobDir 'output\documento.pdf')
    Assert-PwxTrue (($extracted -join ' ') -like '*gestión*') 'acentos preservados en el PDF'
}

Run-PwxTest -Name 'pdf: validador falla con cabecera rota y con %%EOF ausente' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    $client = New-PwxClient -Name 'Cliente PDF QA' -Contact 'pq@mail.com'
    $job = New-PwxJob -ClientId $client.id -Service 'pdf-service' -Description 'qa'
    $json = @{ service = 'pdf-service'; objective = 'doc'; input_files = @(); required_output = @('documento.pdf'); constraints = @(); missing_information = @(); acceptance_criteria = @() } | ConvertTo-Json -Depth 5
    Invoke-PwxRequirementsAgent -JobId $job.id -Request 'x' -ForceJson $json | Out-Null
    $out = Invoke-PwxService_pdf_service -JobId $job.id
    Assert-PwxTrue $out.ok 'generacion inicial ok'
    $found = Find-PwxJob -JobId $job.id
    $file = Join-Path $found.JobDir 'output\documento.pdf'
    $text = [System.IO.File]::ReadAllText($file, [System.Text.Encoding]::GetEncoding(28591))

    # cortar el %%EOF
    $cut = $text -replace '(?s)%%EOF\s*$', ''
    [System.IO.File]::WriteAllText($file, $cut, [System.Text.Encoding]::GetEncoding(28591))
    $v1 = Test-PwxPdfOutput -JobId $job.id
    Assert-PwxTrue (-not $v1.ok) 'sin %%EOF debe dar FAIL'
    Assert-PwxTrue ($v1.detail -like '*EOF*') 'detalle menciona EOF'

    # cabecera rota
    [System.IO.File]::WriteAllText($file, 'PDF falso sin estructura', (New-Object System.Text.UTF8Encoding($false)))
    $v2 = Test-PwxPdfOutput -JobId $job.id
    Assert-PwxTrue (-not $v2.ok) 'cabecera invalida debe dar FAIL'
    Assert-PwxTrue ($v2.detail -like '*Cabecera*') 'detalle menciona cabecera'
}

Run-PwxTest -Name 'pdf: transliteracion WinAnsi es determinista y cubre espanol' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    Assert-PwxEqual 'gestión ñ á' (ConvertTo-PwxPdfText -Text 'gestión ñ á') 'acentos latin1 intactos'
    Assert-PwxEqual 'texto - comillas' (ConvertTo-PwxPdfText -Text 'texto – comillas') 'en dash -> guion'
    Assert-PwxEqual 'a' (ConvertTo-PwxPdfText -Text 'ā') 'diacritico de latin extendido quitado'
    Assert-PwxEqual '?' (ConvertTo-PwxPdfText -Text '中') 'fuera de winansi -> ?'
    Assert-PwxEqual (ConvertTo-PwxPdfText -Text 'Ünïcödé!') (ConvertTo-PwxPdfText -Text 'Ünïcödé!') 'transformacion estable'
}
