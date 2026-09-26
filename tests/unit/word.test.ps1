Run-PwxTest -Name 'word-service genera un docx válido desde contenido profesional' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap

    $client = New-PwxClient -Name 'Cliente Word' -Contact 'word@example.com'
    $job = New-PwxJob -ClientId $client.id -Service 'word-service' -Description 'Propuesta comercial de prueba'
    $source = Join-Path $ws 'propuesta.md'
    @'
# Propuesta comercial

## Objetivo
Organizar una propuesta clara para el cliente.

## Alcance
- Normalización de la información.
- Entrega de documento profesional.

## Cierre
Gracias por considerar nuestra propuesta.
'@ | Set-Content -LiteralPath $source -Encoding UTF8
    Add-PwxJobInputFile -JobId $job.id -SourcePath $source | Out-Null

    $json = '{
      "service": "word-service",
      "objective": "Crear una propuesta comercial profesional",
      "input_files": ["propuesta.md"],
      "required_output": ["*.docx"],
      "constraints": [],
      "missing_information": [],
      "acceptance_criteria": ["Documento Word válido"]
    }'
    $requirements = Invoke-PwxRequirementsAgent -JobId $job.id -Request 'Crear propuesta comercial' -ForceJson $json
    Assert-PwxTrue $requirements.ok

    $production = Invoke-PwxProductionAgent -JobId $job.id
    Assert-PwxTrue $production.ok 'Word debe producirse correctamente'
    Assert-PwxEqual 'READY_FOR_DELIVERY' $production.state
    Assert-PwxEqual 'PASS' $production.qa.verdict

    $validator = Test-PwxWordOutput -JobId $job.id
    Assert-PwxTrue $validator.ok $validator.detail
    $outputDir = Join-Path $ws ('clients\' + $client.id + '\jobs\' + $job.id + '\output')
    $docx = Get-ChildItem -LiteralPath $outputDir -Filter '*.docx' -File
    Assert-PwxEqual 1 @($docx).Count
    Assert-PwxTrue ($docx[0].Length -gt 0) 'El documento Word no puede estar vacío'
    Initialize-PwxWordTypes
    $zip = [System.IO.Compression.ZipFile]::OpenRead($docx[0].FullName)
    try {
        $entry = $zip.Entries | Where-Object { $_.FullName -eq 'word/document.xml' } | Select-Object -First 1
        $reader = New-Object System.IO.StreamReader($entry.Open(), [System.Text.Encoding]::UTF8)
        try { $documentXml = $reader.ReadToEnd() }
        finally { $reader.Dispose() }
        Assert-PwxTrue ($documentXml -match '&#x2022;') 'Las viñetas deben usar entidad XML segura'
        Assert-PwxTrue ($documentXml -notmatch 'â€¢') 'No debe escribir viñetas mal codificadas'
    }
    finally { $zip.Dispose() }
}
