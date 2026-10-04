# E2E del transporte del outbox (PR-6): flujo completo, proteccion de DRAFT
# y cableado real del CLI (proceso hijo, igual que runner.test.ps1).

$script:PwxTransportCli = Join-Path (Join-Path $global:PwxRepoRoot 'src') 'bin/pwx.ps1'

Run-PwxTest -Name 'E2E outbox: new->approve->send file con adjunto, eml y eventos del job' -File 'e2e' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap

    $client = New-PwxClient -Name 'Cliente Outbox' -Contact 'outbox@correo.com'
    $job = New-PwxJob -ClientId $client.id -Service 'simulate-service' -Description 'entrega con notificacion'

    $attDir = Join-Path $ws 'entrega'
    New-PwxDirectory -Path $attDir | Out-Null
    $attPath = Join-Path $attDir 'entrega.txt'
    [System.IO.File]::WriteAllText($attPath, 'contenido de la entrega', (New-Object System.Text.UTF8Encoding($false)))

    $msg = New-PwxOutboxItem -Type 'message' -Channel 'email' -Recipient 'cliente@correo.com' -Subject 'Su entrega esta lista' -Body 'Adjuntamos el resultado.' -JobId $job.id -Attachments @($attPath)
    Assert-PwxEqual 'DRAFT' $msg.status 'nace DRAFT'

    Set-PwxOutboxStatus -Id $msg.id -Status 'APPROVED' -By 'anderson' | Out-Null
    $res = Send-PwxOutboxMessage -Id $msg.id -Transport 'file'
    Assert-PwxEqual 'SENT' $res.status 'SENT tras enviar'
    Assert-PwxTrue (Test-Path -LiteralPath $res.eml) 'eml existe'

    $raw = [System.IO.File]::ReadAllText($res.eml)
    Assert-PwxTrue ($raw -match 'multipart/mixed') 'eml multipart con adjunto'
    Assert-PwxTrue ($raw -match 'filename="entrega\.txt"') 'adjunto por nombre'
    Assert-PwxTrue ($raw -match ('Message-ID: <' + $msg.id + '@pwx\.local>')) 'Message-ID'

    $jobLog = [System.IO.File]::ReadAllText((Join-Path $ws ('logs/jobs/' + $job.id + '.jsonl')))
    Assert-PwxTrue ($jobLog -match 'send\.attempt') 'evento send.attempt en el job'
    $appLog = [System.IO.File]::ReadAllText((Join-Path $ws 'logs/app.log.jsonl'))
    Assert-PwxTrue ($appLog -match ('send\.file id=' + $msg.id)) 'send.file en el log global'

    $after = Get-PwxOutboxItem -Id $msg.id
    Assert-PwxEqual 1 $after.attempts 'un intento'
    Assert-PwxNull $after.last_error 'sin error'
}

Run-PwxTest -Name 'E2E outbox: DRAFT protegido de punta a punta (nada se envia)' -File 'e2e' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap

    $lead = New-PwxLead -Name 'Prospecto' -Email 'prospecto@correo.com' -Phone '3005558899'
    $draft = New-PwxLeadDraft -LeadId $lead.id -Channel 'email'
    Assert-PwxEqual 'DRAFT' $draft.status 'borrador de prospeccion en DRAFT'

    foreach ($t in @('file', 'mock', 'mark-only')) {
        Assert-PwxThrows { Send-PwxOutboxMessage -Id $draft.id -Transport $t } "DRAFT no se envia con $t"
    }

    $after = Get-PwxOutboxItem -Id $draft.id
    Assert-PwxEqual 'DRAFT' $after.status 'sigue DRAFT'
    Assert-PwxEqual 0 $after.attempts 'cero intentos'
    $emlDir = Join-Path (Get-PwxExportsDir) 'eml'
    Assert-PwxTrue (-not (Test-Path -LiteralPath $emlDir) -or @((Get-ChildItem -LiteralPath $emlDir -File -ErrorAction SilentlyContinue)).Count -eq 0) 'ningun eml generado'

    $logFile = Join-Path $ws 'logs/app.log.jsonl'
    $log = if (Test-Path -LiteralPath $logFile) { [System.IO.File]::ReadAllText($logFile) } else { '' }
    Assert-PwxTrue ($log -notmatch 'send\.attempt') 'el log no registra intentos de DRAFT'

    $export = Export-PwxOutboxCsv
    Assert-PwxEqual 1 $export.exported 'el DRAFT sigue exportable a CSV'
}

Run-PwxTest -Name 'E2E CLI: outbox:send -Transport file via proceso hijo' -File 'e2e' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap

    $raw = @(& (Get-PwxShellExe) -NoProfile -ExecutionPolicy Bypass -File $script:PwxTransportCli outbox:new -Recipient 'cli@correo.com' -Subject 'Desde CLI' -Body 'Enviado por el CLI.' 2>&1)
    $exit = [int]$LASTEXITCODE
    $all = (($raw -join "`n") -replace "`r", '')
    Assert-PwxEqual 0 $exit 'outbox:new exit 0'
    $msgId = $null
    if ($all -match '"id":\s*"(M-\d+)"') { $msgId = $Matches[1] }
    Assert-PwxNotNull $msgId 'id del mensaje en la salida del CLI'

    $raw2 = @(& (Get-PwxShellExe) -NoProfile -ExecutionPolicy Bypass -File $script:PwxTransportCli outbox:approve -Id $msgId -By tester 2>&1)
    Assert-PwxEqual 0 ([int]$LASTEXITCODE) 'outbox:approve exit 0'

    $raw3 = @(& (Get-PwxShellExe) -NoProfile -ExecutionPolicy Bypass -File $script:PwxTransportCli outbox:send -Id $msgId -Transport file 2>&1)
    $exit3 = [int]$LASTEXITCODE
    $all3 = (($raw3 -join "`n") -replace "`r", '')
    Assert-PwxEqual 0 $exit3 'outbox:send exit 0'
    Assert-PwxTrue ($all3 -match '"status":\s*"SENT"') 'resultado SENT en stdout'
    Assert-PwxTrue ($all3 -match '"transport":\s*"file"') 'transporte file en stdout'

    $after = Get-PwxOutboxItem -Id $msgId
    Assert-PwxEqual 'SENT' $after.status 'estado persistido'
    Assert-PwxEqual 1 $after.attempts 'un intento via CLI'
    $emlPath = Join-Path (Get-PwxOutboxEmlDir) ($msgId + '.eml')
    Assert-PwxTrue (Test-Path -LiteralPath $emlPath) 'eml creado por el CLI'
    Assert-PwxTrue ([System.IO.File]::ReadAllText($emlPath) -match 'To: cli@correo\.com') 'eml con destinatario correcto'
}

Run-PwxTest -Name 'E2E CLI: outbox:send rechaza DRAFT, transporte invalido y smtp (exit 1)' -File 'e2e' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap

    $raw = @(& (Get-PwxShellExe) -NoProfile -ExecutionPolicy Bypass -File $script:PwxTransportCli outbox:new -Recipient 'cli2@correo.com' -Subject 'S' -Body 'B' 2>&1)
    $all = (($raw -join "`n") -replace "`r", '')
    $msgId = $null
    if ($all -match '"id":\s*"(M-\d+)"') { $msgId = $Matches[1] }
    Assert-PwxNotNull $msgId 'id creado'

    # DRAFT: rechazado con exit 1 y sin tocar el mensaje
    $bad1 = @(& (Get-PwxShellExe) -NoProfile -ExecutionPolicy Bypass -File $script:PwxTransportCli outbox:send -Id $msgId -Transport file 2>&1)
    $bad1All = (($bad1 -join "`n") -replace "`r", '')
    Assert-PwxEqual 1 ([int]$LASTEXITCODE) 'DRAFT rechazado exit 1'
    Assert-PwxTrue ($bad1All -match 'SEND FALLA') 'mensaje de fallo del CLI'
    Assert-PwxTrue ($bad1All -match 'DRAFT') 'explica que requiere aprobacion'
    $after1 = Get-PwxOutboxItem -Id $msgId
    Assert-PwxEqual 'DRAFT' $after1.status 'sigue DRAFT'
    Assert-PwxEqual 0 $after1.attempts 'sin intentos'

    # transporte invalido: rechazado antes de intentar
    $bad2 = @(& (Get-PwxShellExe) -NoProfile -ExecutionPolicy Bypass -File $script:PwxTransportCli outbox:send -Id $msgId -Transport gmail 2>&1)
    Assert-PwxEqual 1 ([int]$LASTEXITCODE) 'transporte invalido exit 1'
    Assert-PwxTrue (((($bad2 -join "`n") -replace "`r", '')) -match 'Transporte no soportado') 'explica transporte invalido'

    # smtp reservado: aprueba e intenta smtp -> fallo controlado, queda APPROVED
    $null = @(& (Get-PwxShellExe) -NoProfile -ExecutionPolicy Bypass -File $script:PwxTransportCli outbox:approve -Id $msgId -By tester 2>&1)
    $bad3 = @(& (Get-PwxShellExe) -NoProfile -ExecutionPolicy Bypass -File $script:PwxTransportCli outbox:send -Id $msgId -Transport smtp 2>&1)
    $bad3All = (($bad3 -join "`n") -replace "`r", '')
    Assert-PwxEqual 1 ([int]$LASTEXITCODE) 'smtp exit 1'
    Assert-PwxTrue ($bad3All -match 'PR-7') 'menciona PR-7'
    $after3 = Get-PwxOutboxItem -Id $msgId
    Assert-PwxEqual 'APPROVED' $after3.status 'smtp no cambia el estado'
    Assert-PwxEqual 1 $after3.attempts 'intento de smtp registrado'
    Assert-PwxTrue (([string]$after3.last_error) -match 'TRANSPORT_SMTP_NOT_IMPLEMENTED') 'last_error registrado'
}
