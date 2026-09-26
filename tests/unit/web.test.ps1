Run-PwxTest -Name 'panel web tiene archivos públicos y convierte archivos base64 seguros' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap

    Assert-PwxTrue (Test-Path -LiteralPath (Join-Path (Get-PwxWebPublicRoot) 'index.html')) 'Debe existir index.html'
    Assert-PwxTrue (Test-Path -LiteralPath (Join-Path (Get-PwxWebPublicRoot) 'app.js')) 'Debe existir app.js'
    Assert-PwxEqual 'valor' (Get-PwxWebString -Object ([pscustomobject]@{ field = 'valor' }) -Property 'field')
    Assert-PwxEqual 3 (Get-PwxWebInt -Object ([pscustomobject]@{ units = '3' }) -Property 'units')
    Assert-PwxThrows { ConvertFrom-PwxWebBase64 -Base64 '***' -MaxBytes 10 } 'Base64 inválido debe rechazarse'

    $client = New-PwxClient -Name 'Cliente Web'
    $job = New-PwxJob -ClientId $client.id -Service 'simulate-service'
    $payload = [pscustomobject]@{
        fileName = 'guia.txt'
        contentBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('guia desde navegador'))
    }
    $entry = Add-PwxWebJobInput -JobId $job.id -Payload $payload
    Assert-PwxEqual 'guia.txt' $entry.name
    Assert-PwxTrue ($entry.path -like 'input*') 'El archivo debe quedar en el bucket input'
    Assert-PwxThrows {
        Write-PwxWebTemporaryFile -FileName '..\secreto.txt' -Bytes ([byte[]](1))
    } 'El nombre de archivo no puede hacer traversal'

    $wordPayload = [pscustomobject]@{
        fileName = 'informe.md'
        contentBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('# Informe'))
        title = 'Prueba web'
    }
    $wordInput = Get-PwxWebWordTestInput -Payload $wordPayload
    Assert-PwxEqual 'informe.md' $wordInput.file_name
    Assert-PwxEqual 'Prueba web' $wordInput.title
    Assert-PwxThrows {
        Get-PwxWebWordTestInput -Payload ([pscustomobject]@{ fileName = 'salida.docx'; contentBase64 = $wordPayload.contentBase64 }) | Out-Null
    } 'La prueba Word solo debe aceptar Markdown o texto'
}
