# Tests del transporte del outbox (PR-6).
# Convenciones: ASCII puro en el archivo (compatibilidad PS 5.1 sin BOM);
# los caracteres no-ASCII se construyen con codepoints para ser identicos
# en Windows PowerShell 5.1 (ANSI) y pwsh 7 (UTF-8).

function Get-PwxTransportTestLog {
    param([string]$Workspace)
    $logFile = Join-Path $Workspace 'logs\app.log.jsonl'
    if (-not (Test-Path -LiteralPath $logFile)) { return '' }
    return [System.IO.File]::ReadAllText($logFile)
}

function Read-PwxTransportEml {
    param([string]$Path)
    return [System.IO.File]::ReadAllText($Path)
}

function Split-PwxTransportMimePart {
    # Devuelve el contenido (base64) de una parte MIME a partir del bloque bruto
    param([string]$PartBlock)
    $pieces = $PartBlock -split "`r`n`r`n", 2
    if ($pieces.Count -lt 2) { return $null }
    $b64 = ($pieces[1] -replace "`r`n", '')
    $b64 = $b64.TrimEnd([char]0x2D) # sin tocar el cierre '--' externo (se recorta por el llamador)
    return $b64
}

Run-PwxTest -Name 'transport: mark-only envia APPROVED y marca SENT sin efectos externos' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    $msg = New-PwxOutboxItem -Type 'message' -Channel 'email' -Recipient 'cliente@correo.com' -Subject 'Listo' -Body 'Su entrega esta lista.'
    Assert-PwxEqual 'DRAFT' $msg.status
    Set-PwxOutboxStatus -Id $msg.id -Status 'APPROVED' -By 'tester' | Out-Null

    $res = Send-PwxOutboxMessage -Id $msg.id -Transport 'mark-only'
    Assert-PwxEqual $msg.id $res.id 'id en el resultado'
    Assert-PwxEqual 'SENT' $res.status 'status SENT'
    Assert-PwxEqual 'mark-only' $res.transport 'transport mark-only'
    Assert-PwxEqual 1 $res.attempts 'un intento'
    Assert-PwxEqual $false $res.forced 'no es reenvio forzado'
    Assert-PwxEqual $msg.message_id $res.message_id 'message_id preservado'
    Assert-PwxNull $res.eml 'mark-only no genera eml'

    $after = Get-PwxOutboxItem -Id $msg.id
    Assert-PwxEqual 'SENT' $after.status 'item SENT'
    Assert-PwxNotNull $after.sent_at 'sent_at establecido'
    Assert-PwxEqual 1 $after.attempts 'attempts=1 en el item'
    Assert-PwxNull $after.last_error 'sin last_error'
    Assert-PwxNotNull $after.last_attempt_at 'last_attempt_at presente'

    $emlDir = Join-Path (Get-PwxExportsDir) 'eml'
    Assert-PwxTrue (-not (Test-Path -LiteralPath $emlDir) -or @((Get-ChildItem -LiteralPath $emlDir -File -ErrorAction SilentlyContinue)).Count -eq 0) 'mark-only no escribe .eml'
}

Run-PwxTest -Name 'transport: DRAFT jamas se envia con ningun transporte' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    $msg = New-PwxOutboxItem -Type 'message' -Channel 'email' -Recipient 'cliente@correo.com' -Subject 'Borrador' -Body 'No deberia salir.'

    foreach ($t in @('file', 'mock', 'mark-only')) {
        Assert-PwxThrows { Send-PwxOutboxMessage -Id $msg.id -Transport $t } "DRAFT rechazado con transporte $t"
    }

    $after = Get-PwxOutboxItem -Id $msg.id
    Assert-PwxEqual 'DRAFT' $after.status 'sigue DRAFT'
    Assert-PwxEqual 0 $after.attempts 'ningun intento registrado'
    Assert-PwxNull $after.last_attempt_at 'sin last_attempt_at'
    $log = Get-PwxTransportTestLog -Workspace $ws
    Assert-PwxTrue ($log -notmatch 'send\.attempt') 'sin send.attempt en el log'
    $emlDir = Join-Path (Get-PwxExportsDir) 'eml'
    Assert-PwxTrue (-not (Test-Path -LiteralPath $emlDir) -or @((Get-ChildItem -LiteralPath $emlDir -File -ErrorAction SilentlyContinue)).Count -eq 0) 'sin .eml'
}

Run-PwxTest -Name 'transport: SENT no se reenvia sin -Force' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    $msg = New-PwxOutboxItem -Type 'message' -Channel 'email' -Recipient 'cliente@correo.com' -Subject 'Uno' -Body 'Una sola vez.'
    Set-PwxOutboxStatus -Id $msg.id -Status 'APPROVED' -By 'tester' | Out-Null
    Send-PwxOutboxMessage -Id $msg.id -Transport 'mock' | Out-Null

    Assert-PwxThrows { Send-PwxOutboxMessage -Id $msg.id -Transport 'mock' } 'SENT sin -Force rechazado'
    Assert-PwxThrows { Send-PwxOutboxMessage -Id $msg.id -Transport 'file' } 'SENT sin -Force rechazado tambien con file'

    $after = Get-PwxOutboxItem -Id $msg.id
    Assert-PwxEqual 'SENT' $after.status 'sigue SENT'
    Assert-PwxEqual 1 $after.attempts 'attempts sigue en 1'
}

Run-PwxTest -Name 'transport: -Force reenvia SENT, registra send.forced y refresca sent_at' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    $msg = New-PwxOutboxItem -Type 'message' -Channel 'email' -Recipient 'cliente@correo.com' -Subject 'Reenvio' -Body 'Otra vez.'
    Set-PwxOutboxStatus -Id $msg.id -Status 'APPROVED' -By 'tester' | Out-Null
    $first = Send-PwxOutboxMessage -Id $msg.id -Transport 'file'
    Assert-PwxEqual $false $first.forced 'primer envio no es forzado'

    $res = Send-PwxOutboxMessage -Id $msg.id -Transport 'file' -Force
    Assert-PwxEqual 'SENT' $res.status 'reenvio queda SENT'
    Assert-PwxEqual 2 $res.attempts 'dos intentos'
    Assert-PwxEqual $true $res.forced 'marcado como forzado'
    Assert-PwxEqual $msg.message_id $res.message_id 'message_id estable en reenvio'
    Assert-PwxTrue (Test-Path -LiteralPath $res.eml) 'eml reescrito'
    Assert-PwxTrue (([string]$res.eml -replace '\\', '/') -like '*exports/eml/' + $msg.id + '.eml') 'nombre del eml estable'

    $after = Get-PwxOutboxItem -Id $msg.id
    Assert-PwxEqual 2 $after.attempts 'attempts=2'
    Assert-PwxTrue ($after.sent_at -ge $first.sent_at) 'sent_at refrescado'
    Assert-PwxNull $after.last_error 'last_error limpio tras exito'

    $log = Get-PwxTransportTestLog -Workspace $ws
    Assert-PwxTrue ($log -match 'send\.attempt') 'send.attempt registrado'
    Assert-PwxTrue ($log -match 'send\.forced') 'send.forced registrado'
}

Run-PwxTest -Name 'transport: file genera .eml real bajo workspace/exports/eml' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    $msg = New-PwxOutboxItem -Type 'message' -Channel 'email' -Recipient 'cliente@correo.com' -Subject 'Entrega' -Body 'Archivo listo.'
    Set-PwxOutboxStatus -Id $msg.id -Status 'APPROVED' -By 'tester' | Out-Null

    $res = Send-PwxOutboxMessage -Id $msg.id -Transport 'file'
    Assert-PwxEqual 'SENT' $res.status 'SENT tras file'
    Assert-PwxNotNull $res.eml 'eml en el resultado'
    Assert-PwxTrue (Test-Path -LiteralPath $res.eml) 'archivo .eml existe'
    $expected = (Join-Path (Get-PwxOutboxEmlDir) ($msg.id + '.eml'))
    Assert-PwxEqual $expected $res.eml 'ruta exacta <id>.eml en exports/eml'
    $bytes = [System.IO.File]::ReadAllBytes($res.eml)
    Assert-PwxTrue ($bytes.Length -gt 0) 'eml no vacio'
    Assert-PwxTrue (($bytes | Where-Object { $_ -gt 127 }).Count -eq 0) 'eml 7-bit limpio (ASCII)'
}

Run-PwxTest -Name 'transport: eml con cabeceras RFC minimas y message_id estable' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    $msg = New-PwxOutboxItem -Type 'message' -Channel 'email' -Recipient 'cliente@correo.com' -Subject 'Cabeceras' -Body 'Cuerpo.'
    Set-PwxOutboxStatus -Id $msg.id -Status 'APPROVED' -By 'tester' | Out-Null
    $res = Send-PwxOutboxMessage -Id $msg.id -Transport 'file'

    $raw = Read-PwxTransportEml -Path $res.eml
    Assert-PwxTrue ($raw -match ('(?m)^Message-ID: <' + $msg.id + '@pwx\.local>\r?$')) 'Message-ID determinista'
    Assert-PwxTrue ($raw -match '(?m)^Date: .+') 'Date presente'
    Assert-PwxTrue ($raw -match '(?m)^From: PWX Local <pwx@localhost>\r?$') 'From presente'
    Assert-PwxTrue ($raw -match '(?m)^To: cliente@correo\.com\r?$') 'To igual al destinatario'
    Assert-PwxTrue ($raw -match '(?m)^Subject: Cabeceras\r?$') 'Subject literal (ASCII)'
    Assert-PwxTrue ($raw -match '(?m)^MIME-Version: 1\.0\r?$') 'MIME-Version'
    Assert-PwxTrue ($raw -match ('(?m)^X-Pwx-Outbox-Id: ' + $msg.id + '\r?$')) 'X-Pwx-Outbox-Id'
    Assert-PwxTrue ($raw -match '(?m)^X-Pwx-Channel: email\r?$') 'X-Pwx-Channel'
    Assert-PwxTrue ($raw -match '(?m)^X-Pwx-Transport: file\r?$') 'X-Pwx-Transport'
    Assert-PwxTrue ($raw -match '(?m)^Content-Type: text/plain; charset=utf-8\r?$') 'Content-Type single-part'
    Assert-PwxTrue ($raw -match '(?m)^Content-Transfer-Encoding: base64\r?$') 'CTE base64'
    Assert-PwxTrue ($raw -notmatch 'Bcc:') 'sin Bcc inyectado'
}

Run-PwxTest -Name 'transport: eml codifica el body en base64 UTF-8 exacto' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    # acentos y emoji via codepoints: identico en PS 5.1 y pwsh 7
    $body = 'Hola, gracias por su compra.' + [char]0x00E1 + [char]0x00E9 + [char]0x00ED + [char]0x00F3 + [char]0x00FA + [char]0x00F1 + ' ' + [char]::ConvertFromUtf32(0x1F680) + "`nSegunda linea con, comas y `"comillas`"."
    $msg = New-PwxOutboxItem -Type 'message' -Channel 'email' -Recipient 'cliente@correo.com' -Subject 'Cuerpo' -Body $body
    Set-PwxOutboxStatus -Id $msg.id -Status 'APPROVED' -By 'tester' | Out-Null
    $res = Send-PwxOutboxMessage -Id $msg.id -Transport 'file'

    $raw = Read-PwxTransportEml -Path $res.eml
    $pieces = $raw -split "`r`n`r`n", 2
    Assert-PwxEqual 2 $pieces.Count 'headers y cuerpo separados'
    $b64 = ($pieces[1] -replace "`r`n", '').Trim()
    $decoded = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64))
    Assert-PwxEqual $body $decoded 'body decodifica exacto (UTF-8 base64)'
    # lineas base64 de a 76 caracteres (formato MIME)
    $bodyLines = @(($pieces[1] -split "`r`n") | Where-Object { $_ -ne '' })
    foreach ($line in $bodyLines) {
        Assert-PwxTrue ($line.Length -le 76) 'linea base64 <= 76 chars'
    }
}

Run-PwxTest -Name 'transport: asunto no-ASCII viaja como encoded-word UTF-8' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    $subject = 'Confirmaci' + [char]0x00F3 + 'n de entrega ' + [char]0x00D1
    $msg = New-PwxOutboxItem -Type 'message' -Channel 'email' -Recipient 'cliente@correo.com' -Subject $subject -Body 'ok'
    Set-PwxOutboxStatus -Id $msg.id -Status 'APPROVED' -By 'tester' | Out-Null
    $res = Send-PwxOutboxMessage -Id $msg.id -Transport 'file'

    $raw = Read-PwxTransportEml -Path $res.eml
    $m = [regex]::Match($raw, '(?m)^Subject: =\?UTF-8\?B\?([A-Za-z0-9+/=]+)\?=')
    Assert-PwxTrue $m.Success 'Subject como encoded-word'
    $decoded = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($m.Groups[1].Value))
    Assert-PwxEqual $subject $decoded 'subject decodifica exacto'
    # cabeceras sin CR/LF crudo: nada de header injection
    Assert-PwxTrue ($raw -notmatch "(?m)^Bcc:") 'sin Bcc inyectado via subject'
}

Run-PwxTest -Name 'transport: subject con saltos de linea no inyecta cabeceras' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    $evil = "Pago enviado`r`nBcc: atacante@mal.com`nX-Evil: 1"
    $msg = New-PwxOutboxItem -Type 'message' -Channel 'email' -Recipient 'cliente@correo.com' -Subject $evil -Body 'cuerpo'
    Set-PwxOutboxStatus -Id $msg.id -Status 'APPROVED' -By 'tester' | Out-Null
    $res = Send-PwxOutboxMessage -Id $msg.id -Transport 'file'

    $raw = Read-PwxTransportEml -Path $res.eml
    Assert-PwxTrue ($raw -notmatch '(?m)^Bcc:') 'Bcc eliminado'
    Assert-PwxTrue ($raw -notmatch '(?m)^X-Evil:') 'cabecera inyectada eliminada'
    Assert-PwxTrue ($raw -match '(?m)^To: cliente@correo\.com') 'To intacto'
}

Run-PwxTest -Name 'transport: eml adjunta archivos como MIME base64 con sha256' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    $attDir = Join-Path $ws 'adjuntos'
    New-PwxDirectory -Path $attDir | Out-Null
    $attPath = Join-Path $attDir 'contrato.txt'
    $attContent = 'contenido del adjunto: presupuesto final 2026 con acentos ' + [char]0x00E1 + [char]0x00F1
    [System.IO.File]::WriteAllText($attPath, $attContent, (New-Object System.Text.UTF8Encoding($false)))
    $expectedHash = (Get-PwxSha256 -Path $attPath)

    $msg = New-PwxOutboxItem -Type 'message' -Channel 'email' -Recipient 'cliente@correo.com' -Subject 'Con adjunto' -Body 'Ver adjunto.' -Attachments @($attPath)
    Assert-PwxEqual 1 @($msg.attachments).Count 'adjunto registrado'
    Assert-PwxEqual $expectedHash $msg.attachments[0].sha256 'sha256 registrado al crear'
    Set-PwxOutboxStatus -Id $msg.id -Status 'APPROVED' -By 'tester' | Out-Null
    $res = Send-PwxOutboxMessage -Id $msg.id -Transport 'file'

    $raw = Read-PwxTransportEml -Path $res.eml
    Assert-PwxTrue ($raw -match '(?m)^Content-Type: multipart/mixed; boundary="') 'multipart/mixed'
    $boundary = [regex]::Match($raw, 'boundary="([^"]+)"').Groups[1].Value
    Assert-PwxTrue ($boundary -ne '') 'boundary presente'
    Assert-PwxTrue ($raw -match 'filename="contrato\.txt"') 'filename del adjunto'
    Assert-PwxTrue ($raw -match ('(?m)^X-Pwx-Sha256: ' + $expectedHash + '\r?$')) 'sha256 del adjunto en el eml'

    # decodificar la parte adjunta y comparar bytes
    $segments = $raw -split ('--' + [regex]::Escape($boundary))
    Assert-PwxTrue ($segments.Count -ge 4) 'prologo + 2 partes + cierre'
    $attBlock = $segments[2]
    $attPieces = $attBlock -split "`r`n`r`n", 2
    Assert-PwxEqual 2 $attPieces.Count 'bloque adjunto con headers y contenido'
    $b64 = ($attPieces[1] -replace "`r`n", '')
    $b64 = $b64 -replace '-+$', ''
    $decoded = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64.Trim()))
    Assert-PwxEqual $attContent $decoded 'contenido del adjunto decodifica exacto'
}

Run-PwxTest -Name 'transport: adjunto faltante o modificado falla el envio sin cambiar estado' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    $attDir = Join-Path $ws 'adj'
    New-PwxDirectory -Path $attDir | Out-Null
    $attA = Join-Path $attDir 'a.txt'
    $attB = Join-Path $attDir 'b.txt'
    [System.IO.File]::WriteAllText($attA, 'AAAA', (New-Object System.Text.UTF8Encoding($false)))
    [System.IO.File]::WriteAllText($attB, 'BBBB', (New-Object System.Text.UTF8Encoding($false)))

    # faltante
    $m1 = New-PwxOutboxItem -Type 'message' -Channel 'email' -Recipient 'x@y.com' -Subject 's' -Body 'b' -Attachments @($attA)
    Set-PwxOutboxStatus -Id $m1.id -Status 'APPROVED' -By 't' | Out-Null
    Remove-Item -LiteralPath $attA -Force
    Assert-PwxThrows { Send-PwxOutboxMessage -Id $m1.id -Transport 'file' } 'adjunto faltante rechazado'
    $after1 = Get-PwxOutboxItem -Id $m1.id
    Assert-PwxEqual 'APPROVED' $after1.status 'falta: sigue APPROVED'
    Assert-PwxEqual 1 $after1.attempts 'falta: intento registrado'
    Assert-PwxTrue (([string]$after1.last_error) -match 'TRANSPORT_ATTACHMENT_MISSING') 'falta: last_error especifico'

    # modificado (sha256 distinto)
    $m2 = New-PwxOutboxItem -Type 'message' -Channel 'email' -Recipient 'x@y.com' -Subject 's' -Body 'b' -Attachments @($attB)
    Set-PwxOutboxStatus -Id $m2.id -Status 'APPROVED' -By 't' | Out-Null
    [System.IO.File]::WriteAllText($attB, 'BBBB-MODIFICADO', (New-Object System.Text.UTF8Encoding($false)))
    Assert-PwxThrows { Send-PwxOutboxMessage -Id $m2.id -Transport 'file' } 'adjunto modificado rechazado'
    $after2 = Get-PwxOutboxItem -Id $m2.id
    Assert-PwxEqual 'APPROVED' $after2.status 'modif: sigue APPROVED'
    Assert-PwxTrue (([string]$after2.last_error) -match 'TRANSPORT_ATTACHMENT_HASH_MISMATCH') 'modif: last_error especifico'

    # ningun eml se escribio
    $emlDir = Get-PwxOutboxEmlDir
    Assert-PwxTrue (@((Get-ChildItem -LiteralPath $emlDir -File -ErrorAction SilentlyContinue)).Count -eq 0) 'sin eml tras fallos'
    $log = Get-PwxTransportTestLog -Workspace $ws
    Assert-PwxTrue ($log -match 'send\.fail') 'send.fail registrado'
}

Run-PwxTest -Name 'transport: file exige destinatario (TRANSPORT_NO_RECIPIENT)' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    $msg = New-PwxOutboxItem -Type 'message' -Channel 'email' -Recipient '' -Subject 's' -Body 'b'
    Set-PwxOutboxStatus -Id $msg.id -Status 'APPROVED' -By 't' | Out-Null
    Assert-PwxThrows { Send-PwxOutboxMessage -Id $msg.id -Transport 'file' } 'sin destinatario rechazado'
    $after = Get-PwxOutboxItem -Id $msg.id
    Assert-PwxEqual 'APPROVED' $after.status 'sigue APPROVED'
    Assert-PwxTrue (([string]$after.last_error) -match 'TRANSPORT_NO_RECIPIENT') 'last_error especifico'
    # mark-only si lo permite (no produce artefacto externo)
    $res = Send-PwxOutboxMessage -Id $msg.id -Transport 'mark-only'
    Assert-PwxEqual 'SENT' $res.status 'mark-only sin destinatario permitido'
}

Run-PwxTest -Name 'transport: smtp reservado PR-7 rechazado con send.fail' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    $msg = New-PwxOutboxItem -Type 'message' -Channel 'email' -Recipient 'cliente@correo.com' -Subject 's' -Body 'b'
    Set-PwxOutboxStatus -Id $msg.id -Status 'APPROVED' -By 't' | Out-Null
    Assert-PwxThrows { Send-PwxOutboxMessage -Id $msg.id -Transport 'smtp' } 'smtp rechazado'

    $after = Get-PwxOutboxItem -Id $msg.id
    Assert-PwxEqual 'APPROVED' $after.status 'sigue APPROVED (nada enviado)'
    Assert-PwxEqual 1 $after.attempts 'intento registrado'
    Assert-PwxTrue (([string]$after.last_error) -match 'TRANSPORT_SMTP_NOT_IMPLEMENTED') 'last_error explicito'
    Assert-PwxTrue (([string]$after.last_error) -match 'PR-7') 'menciona PR-7'
    $log = Get-PwxTransportTestLog -Workspace $ws
    Assert-PwxTrue ($log -match 'send\.fail id=' + $msg.id + ' transport=smtp') 'send.fail de smtp en log'
    # y el mensaje sigue siendo enviable por file despues del fallo
    $res = Send-PwxOutboxMessage -Id $msg.id -Transport 'file'
    Assert-PwxEqual 'SENT' $res.status 'file funciona tras fallo smtp'
    Assert-PwxEqual 2 $res.attempts 'segundo intento'
    $final = Get-PwxOutboxItem -Id $msg.id
    Assert-PwxNull $final.last_error 'last_error limpio tras exito'
}

Run-PwxTest -Name 'transport: nombre de transporte invalido rechazado antes de intentar' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    $msg = New-PwxOutboxItem -Type 'message' -Channel 'email' -Recipient 'cliente@correo.com' -Subject 's' -Body 'b'
    Set-PwxOutboxStatus -Id $msg.id -Status 'APPROVED' -By 't' | Out-Null
    foreach ($bad in @('gmail', 'carrier-pigeon', 'SMTPX')) {
        Assert-PwxThrows { Send-PwxOutboxMessage -Id $msg.id -Transport $bad } "transporte invalido rechazado: '$bad'"
    }
    $after = Get-PwxOutboxItem -Id $msg.id
    Assert-PwxEqual 'APPROVED' $after.status 'sigue APPROVED'
    Assert-PwxEqual 0 $after.attempts 'cero intentos (rechazo previo)'
    Assert-PwxNull $after.last_attempt_at 'sin last_attempt_at'
}

Run-PwxTest -Name 'transport: mensaje inexistente rechazado' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    Assert-PwxThrows { Send-PwxOutboxMessage -Id 'M-9999' -Transport 'file' } 'id inexistente'
    Assert-PwxThrows { Send-PwxOutboxMessage -Id 'M-9999' } 'id inexistente sin transporte explicito'
}

Run-PwxTest -Name 'transport: env PWX_TRANSPORT define el transporte por defecto' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    $prev = $env:PWX_TRANSPORT
    try {
        $env:PWX_TRANSPORT = 'file'
        $msg = New-PwxOutboxItem -Type 'message' -Channel 'email' -Recipient 'cliente@correo.com' -Subject 's' -Body 'b'
        Set-PwxOutboxStatus -Id $msg.id -Status 'APPROVED' -By 't' | Out-Null
        $res = Send-PwxOutboxMessage -Id $msg.id
        Assert-PwxEqual 'file' $res.transport 'transporte tomado del env'
        Assert-PwxTrue (Test-Path -LiteralPath $res.eml) 'eml creado via env'
        $log = Get-PwxTransportTestLog -Workspace $ws
        Assert-PwxTrue ($log -match ('send\.attempt id=' + $msg.id + ' transport=file')) 'log con transport=file'
    }
    finally {
        if ($null -ne $prev) { $env:PWX_TRANSPORT = $prev } else { Remove-Item Env:\PWX_TRANSPORT -ErrorAction SilentlyContinue }
    }
}

Run-PwxTest -Name 'transport: default seguro sin env ni flag (mark-only)' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    $msg = New-PwxOutboxItem -Type 'message' -Channel 'email' -Recipient 'cliente@correo.com' -Subject 's' -Body 'b'
    Set-PwxOutboxStatus -Id $msg.id -Status 'APPROVED' -By 't' | Out-Null
    $res = Send-PwxOutboxMessage -Id $msg.id
    Assert-PwxEqual 'mark-only' $res.transport 'default mark-only (settings.json / fallback)'
    Assert-PwxNull $res.eml 'sin eml en default'
    $log = Get-PwxTransportTestLog -Workspace $ws
    Assert-PwxTrue ($log -match ('send\.attempt id=' + $msg.id + ' transport=mark-only')) 'log con transport=mark-only'
}

Run-PwxTest -Name 'transport: items legacy sin campos nuevos se normalizan on-demand' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    $msg = New-PwxOutboxItem -Type 'message' -Channel 'email' -Recipient 'legacy@correo.com' -Subject 'viejo' -Body 'schema anterior'
    # simular un item creado por una version anterior: quitar los campos PR-6
    $itemPath = Join-Path (Get-PwxOutboxDir) ($msg.id + '.json')
    $legacy = Get-PwxJsonFile -Path $itemPath
    foreach ($p in @('message_id', 'attempts', 'last_error', 'last_attempt_at')) {
        $legacy.PSObject.Properties.Remove($p)
    }
    Set-PwxJsonFile -Path $itemPath -Object $legacy | Out-Null
    $reloaded = Get-PwxOutboxItem -Id $msg.id
    Assert-PwxTrue (-not ($reloaded.PSObject.Properties.Name -contains 'attempts')) 'legacy sin attempts'

    Set-PwxOutboxStatus -Id $msg.id -Status 'APPROVED' -By 't' | Out-Null
    $res = Send-PwxOutboxMessage -Id $msg.id -Transport 'mark-only'
    Assert-PwxEqual 'SENT' $res.status 'legacy enviable'
    Assert-PwxEqual 1 $res.attempts 'attempts parte de 0'
    Assert-PwxEqual ('<' + $msg.id + '@pwx.local>') $res.message_id 'message_id normalizado'

    $after = Get-PwxOutboxItem -Id $msg.id
    Assert-PwxEqual 1 $after.attempts 'attempts persistido'
    Assert-PwxNotNull $after.message_id 'message_id persistido'
}

Run-PwxTest -Name 'transport: send.attempt/send.fail/send.forced en app.log.jsonl y eventos del job' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    $client = New-PwxClient -Name 'Cliente Transport' -Contact 'transport@correo.com'
    $job = New-PwxJob -ClientId $client.id -Service 'simulate-service' -Description 'evento de transporte'
    $msg = New-PwxOutboxItem -Type 'message' -Channel 'email' -Recipient 'cliente@correo.com' -Subject 's' -Body 'b' -JobId $job.id
    Set-PwxOutboxStatus -Id $msg.id -Status 'APPROVED' -By 't' | Out-Null

    # fallo (smtp) -> exito (file) -> reenvio forzado (file)
    Assert-PwxThrows { Send-PwxOutboxMessage -Id $msg.id -Transport 'smtp' }
    Send-PwxOutboxMessage -Id $msg.id -Transport 'file' | Out-Null
    Send-PwxOutboxMessage -Id $msg.id -Transport 'file' -Force | Out-Null

    $log = Get-PwxTransportTestLog -Workspace $ws
    Assert-PwxTrue ($log -match ('send\.attempt id=' + $msg.id + ' transport=smtp attempt=1')) 'attempt smtp'
    Assert-PwxTrue ($log -match ('send\.fail id=' + $msg.id + ' transport=smtp')) 'fail smtp'
    Assert-PwxTrue ($log -match ('send\.attempt id=' + $msg.id + ' transport=file attempt=2')) 'attempt file'
    Assert-PwxTrue ($log -match ('send\.file id=' + $msg.id)) 'send.file'
    Assert-PwxTrue ($log -match ('send\.forced id=' + $msg.id + ' transport=file attempt=3')) 'forced'

    $jobLogPath = Join-Path $ws ('logs\jobs\' + $job.id + '.jsonl')
    Assert-PwxTrue (Test-Path -LiteralPath $jobLogPath) 'log de eventos del job existe'
    $jobLog = [System.IO.File]::ReadAllText($jobLogPath)
    Assert-PwxTrue ($jobLog -match 'send\.attempt') 'evento send.attempt en el job'
    Assert-PwxTrue ($jobLog -match 'send\.fail') 'evento send.fail en el job'
    Assert-PwxTrue ($jobLog -match 'send\.forced') 'evento send.forced en el job'

    $after = Get-PwxOutboxItem -Id $msg.id
    Assert-PwxEqual 3 $after.attempts 'tres intentos totales'
    Assert-PwxEqual 'SENT' $after.status 'SENT al final'
}
