Run-PwxTest -Name 'word: roundtrip docx conserva parrafos (acentos, XML, lineas vacias) y es determinista' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    $dir = New-PwxDirectory -Path (Join-Path $ws 'out')
    $paras = @(
        'Informe con acentos: áéíóúñ Ñ'
        'Texto con <etiquetas> & "comillas" y ''apostrofes'''
        ''
        'Linea despues de vacia'
    )
    $p1 = Join-Path $dir 'a.docx'
    Write-PwxWordDoc -Path $p1 -Paragraphs $paras
    Assert-PwxTrue (Test-Path -LiteralPath $p1) 'docx creado'
    $read = Read-PwxWordDoc -Path $p1
    Assert-PwxTrue $read.ok 'lectura ok'
    Assert-PwxEqual $paras.Count $read.paragraphs.Count 'mismo conteo de parrafos'
    for ($i = 0; $i -lt $paras.Count; $i++) {
        Assert-PwxEqual $paras[$i] $read.paragraphs[$i] "parrafo $i identico"
    }
    # determinismo: segunda escritura -> bytes identicos
    $p2 = Join-Path $dir 'b.docx'
    Write-PwxWordDoc -Path $p2 -Paragraphs $paras
    Assert-PwxEqual (Get-PwxSha256 -Path $p1) (Get-PwxSha256 -Path $p2) 'bytes deterministas'
}

Run-PwxTest -Name 'word: servicio con input .txt genera documento.docx y validador PASS' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    $client = New-PwxClient -Name 'Cliente Word' -Contact 'w@mail.com'
    $job = New-PwxJob -ClientId $client.id -Service 'word-service' -Description 'documento'
    $src = Join-Path $ws 'entrada.txt'
    [System.IO.File]::WriteAllText($src, "Titulo del documento`nCuerpo con contenido & datos.`n", (New-Object System.Text.UTF8Encoding($false)))
    Add-PwxJobInputFile -JobId $job.id -SourcePath $src -TargetName 'entrada.txt' | Out-Null
    $json = @{ service = 'word-service'; objective = 'redactar documento'; input_files = @('entrada.txt'); required_output = @('documento.docx'); constraints = @(); missing_information = @(); acceptance_criteria = @() } | ConvertTo-Json -Depth 5
    $res = Invoke-PwxRequirementsAgent -JobId $job.id -Request 'documento' -ForceJson $json
    Assert-PwxTrue $res.ok 'requisitos ok'
    $out = Invoke-PwxService_word_service -JobId $job.id
    Assert-PwxTrue $out.ok "servicio ok (error=$($out.error))"
    Assert-PwxEqual 'documento.docx' $out.file 'nombre de salida'
    $found = Find-PwxJob -JobId $job.id
    Assert-PwxTrue (Test-Path -LiteralPath (Join-Path $found.JobDir 'output\documento.docx')) 'archivo en output/'
    $v = Test-PwxWordOutput -JobId $job.id
    Assert-PwxTrue $v.ok "validador PASS (detail=$($v.detail))"
}

Run-PwxTest -Name 'word: sin input usa el objetivo de requisitos (fallback spec)' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    $client = New-PwxClient -Name 'Cliente Word Spec' -Contact 'ws@mail.com'
    $job = New-PwxJob -ClientId $client.id -Service 'word-service' -Description 'sin archivo'
    $json = @{ service = 'word-service'; objective = 'Resumen ejecutivo del proyecto'; input_files = @(); required_output = @('documento.docx'); constraints = @('Extencion maxima de 2 paginas'); missing_information = @(); acceptance_criteria = @() } | ConvertTo-Json -Depth 5
    $res = Invoke-PwxRequirementsAgent -JobId $job.id -Request 'resumen' -ForceJson $json
    Assert-PwxTrue $res.ok 'requisitos ok'
    $out = Invoke-PwxService_word_service -JobId $job.id
    Assert-PwxTrue $out.ok "servicio ok (error=$($out.error))"
    $v = Test-PwxWordOutput -JobId $job.id
    Assert-PwxTrue $v.ok "validador PASS (detail=$($v.detail))"
    $read = Read-PwxWordDoc -Path (Join-Path (Find-PwxJob -JobId $job.id).JobDir 'output\documento.docx')
    Assert-PwxTrue ($read.paragraphs -contains 'Resumen ejecutivo del proyecto') 'primer parrafo = objetivo'
    Assert-PwxTrue ($read.paragraphs -contains '- Extencion maxima de 2 paginas') 'constraint como vineta'
}

Run-PwxTest -Name 'word: validador falla con docx corrupto y con texto alterado' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    $client = New-PwxClient -Name 'Cliente Word QA' -Contact 'wq@mail.com'
    $job = New-PwxJob -ClientId $client.id -Service 'word-service' -Description 'qa'
    $json = @{ service = 'word-service'; objective = 'Doc de prueba'; input_files = @(); required_output = @('documento.docx'); constraints = @(); missing_information = @(); acceptance_criteria = @() } | ConvertTo-Json -Depth 5
    Invoke-PwxRequirementsAgent -JobId $job.id -Request 'x' -ForceJson $json | Out-Null
    $out = Invoke-PwxService_word_service -JobId $job.id
    Assert-PwxTrue $out.ok 'generacion inicial ok'
    $found = Find-PwxJob -JobId $job.id
    $file = Join-Path $found.JobDir 'output\documento.docx'

    # texto alterado -> mismatch
    $read = Read-PwxWordDoc -Path $file
    $tampered = @($read.paragraphs)
    $tampered[0] = 'TEXTO ALTERADO'
    Write-PwxWordDoc -Path $file -Paragraphs $tampered
    $v1 = Test-PwxWordOutput -JobId $job.id
    Assert-PwxTrue (-not $v1.ok) 'alterar texto debe dar FAIL'
    Assert-PwxTrue ($v1.detail -match 'distinto') 'detalle indica parrafo distinto'

    # corrupto -> estructura invalida
    [System.IO.File]::WriteAllText($file, 'esto no es un zip', (New-Object System.Text.UTF8Encoding($false)))
    $v2 = Test-PwxWordOutput -JobId $job.id
    Assert-PwxTrue (-not $v2.ok) 'zip invalido debe dar FAIL'
    Assert-PwxTrue ($v2.detail -match 'WORD_NOT_ZIP') 'codigo WORD_NOT_ZIP'
}
