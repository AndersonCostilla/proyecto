# Transporte del outbox (PR-6).
#
# Flujo protegido:
#   DRAFT    -> JAMAS se envia (requiere aprobacion humana previa)
#   APPROVED -> puede enviarse
#   SENT     -> no se reenvia salvo -Force
#
# Transportes disponibles:
#   file       -> escribe un correo .eml real y 100% local en workspace/exports/eml/
#                 (se puede abrir/adjuntar en cualquier cliente de correo)
#   mock       -> simula el envio (tests/desarrollo; sin archivos ni red)
#   mark-only  -> solo transicion de estado (comportamiento historico)
#   smtp       -> RESERVADO para PR-7: hoy rechaza el envio con error claro
#
# Reglas del proyecto que este modulo respeta:
#   - cero red: ningun transporte abre conexiones (smtp ni siquiera existe aun)
#   - nada se envia sin aprobacion humana previa (estado APPROVED)
#   - cada intento queda registrado (attempts / last_attempt_at / last_error)
#     y es auditable en logs (send.attempt / send.fail / send.forced)
#   - los adjuntos se verifican con sha256 contra el hash registrado al crear
#     el mensaje (si el archivo cambio, el envio falla; nada se envia a ciegas)

# ----------------------------------------------------------------------------
# Resolucion de transporte
# ----------------------------------------------------------------------------

function Get-PwxOutboxSupportedTransports {
    return @('file', 'mock', 'mark-only', 'smtp')
}

function Get-PwxOutboxDefaultTransport {
    # Prioridad: env PWX_TRANSPORT > config/settings.json (outbox.transport) > mark-only
    if ($env:PWX_TRANSPORT) {
        $t = ([string]$env:PWX_TRANSPORT).Trim().ToLowerInvariant()
        if ($t) { return $t }
    }
    $cfg = Get-PwxConfig
    if ($cfg.OutboxTransport) {
        return ([string]$cfg.OutboxTransport).Trim().ToLowerInvariant()
    }
    return 'mark-only'
}

# ----------------------------------------------------------------------------
# Persistencia interna de items (los items son datos auditables)
# ----------------------------------------------------------------------------

function Set-PwxOutboxItemMember {
    param([object]$Item, [string]$Name, [object]$Value)
    if (@($Item.PSObject.Properties.Name) -contains $Name) {
        $Item.$Name = $Value
    }
    else {
        # Items creados por versiones anteriores (sin los campos nuevos)
        # se normalizan on-demand: nunca se pierde un mensaje por schema viejo.
        $Item | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    }
    return $Item
}

function Save-PwxOutboxItem {
    param([object]$Item)
    Set-PwxJsonFile -Path (Join-Path (Get-PwxOutboxDir) ([string]$Item.id + '.json')) -Object $Item | Out-Null
    return (Get-PwxOutboxItem -Id ([string]$Item.id))
}

# ----------------------------------------------------------------------------
# Construccion del .eml (RFC 5322 / MIME, 100% local)
# ----------------------------------------------------------------------------

function Get-PwxOutboxEmlDir {
    $dir = Join-Path (Get-PwxExportsDir) 'eml'
    New-PwxDirectory -Path $dir | Out-Null
    return $dir
}

function Convert-PwxHeaderSafe {
    # Un header nunca puede contener CR/LF (header injection) ni comillas.
    param([string]$Value)
    $s = [string]$Value
    $s = $s -replace "`r", ''
    $s = $s -replace "`n", ''
    $s = $s -replace '"', ''
    return $s
}

function Convert-PwxHeaderWord {
    # Asunto no-ASCII -> encoded-word UTF-8 base64 (=?UTF-8?B?...?=)
    param([string]$Value)
    $s = Convert-PwxHeaderSafe -Value $Value
    $hasNonAscii = $false
    foreach ($ch in $s.ToCharArray()) {
        if ([int]$ch -gt 127) { $hasNonAscii = $true; break }
    }
    if ($hasNonAscii) {
        return ('=?UTF-8?B?' + [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($s)) + '?=')
    }
    return $s
}

function Convert-PwxBase64Wrapped {
    # Base64 en lineas de 76 caracteres (formato MIME clasico)
    param([string]$Base64)
    $b = [string]$Base64
    if (-not $b) { return '' }
    $sb = New-Object System.Text.StringBuilder
    $i = 0
    while ($i -lt $b.Length) {
        $len = [Math]::Min(76, $b.Length - $i)
        [void]$sb.Append($b.Substring($i, $len))
        $i += $len
        if ($i -lt $b.Length) { [void]$sb.Append("`r`n") }
    }
    return $sb.ToString()
}

function Get-PwxEmlBoundary {
    # Boundary determinista derivado del mensaje. Contiene '_' y '-' (caracteres
    # que NO existen en el alfabeto base64), por lo que nunca puede colisionar
    # con el contenido codificado de las partes.
    param([object]$Item)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes(([string]$Item.id + '|' + [string]$Item.message_id))
        $hex = ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
    return ('=_pwx_' + $hex.Substring(0, 32))
}

function Convert-PwxOutboxItemToEml {
    param(
        [object]$Item,
        [string]$DateRfc1123
    )
    $crlf = "`r`n"
    $sb = New-Object System.Text.StringBuilder

    if ([string]::IsNullOrWhiteSpace([string]$Item.recipient)) {
        throw "TRANSPORT_NO_RECIPIENT: el mensaje $($Item.id) no tiene destinatario; el modo file escribe un correo real"
    }

    # Adjuntos: verificar existencia y sha256 ANTES de construir nada
    $parts = @()
    foreach ($att in @($Item.attachments)) {
        if ($null -eq $att) { continue }
        $path = [string]$att.path
        if (-not (Test-Path -LiteralPath $path)) {
            throw "TRANSPORT_ATTACHMENT_MISSING: adjunto inexistente para $($Item.id): $path"
        }
        $currentHash = Get-PwxSha256 -Path $path
        if ($att.sha256 -and ([string]$att.sha256).ToUpperInvariant() -ne $currentHash.ToUpperInvariant()) {
            throw "TRANSPORT_ATTACHMENT_HASH_MISMATCH: el adjunto cambio desde que se registro el mensaje: $path"
        }
        $bytes = [System.IO.File]::ReadAllBytes($path)
        $parts += [pscustomobject]@{
            file_name = [System.IO.Path]::GetFileName($path)
            sha256    = $currentHash
            base64    = [Convert]::ToBase64String($bytes)
        }
    }

    $bodyB64 = Convert-PwxBase64Wrapped -Base64 ([Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes([string]$Item.body)))

    [void]$sb.Append('Message-ID: ' + (Convert-PwxHeaderSafe -Value ([string]$Item.message_id)) + $crlf)
    [void]$sb.Append('Date: ' + $DateRfc1123 + $crlf)
    [void]$sb.Append('From: PWX Local <pwx@localhost>' + $crlf)
    [void]$sb.Append('To: ' + (Convert-PwxHeaderSafe -Value ([string]$Item.recipient)) + $crlf)
    [void]$sb.Append('Subject: ' + (Convert-PwxHeaderWord -Value ([string]$Item.subject)) + $crlf)
    [void]$sb.Append('MIME-Version: 1.0' + $crlf)
    [void]$sb.Append('X-Pwx-Outbox-Id: ' + (Convert-PwxHeaderSafe -Value ([string]$Item.id)) + $crlf)
    if ($Item.channel) {
        [void]$sb.Append('X-Pwx-Channel: ' + (Convert-PwxHeaderSafe -Value ([string]$Item.channel)) + $crlf)
    }
    [void]$sb.Append('X-Pwx-Transport: file' + $crlf)

    if ($parts.Count -gt 0) {
        $boundary = Get-PwxEmlBoundary -Item $Item
        [void]$sb.Append('Content-Type: multipart/mixed; boundary="' + $boundary + '"' + $crlf)
        [void]$sb.Append($crlf)
        [void]$sb.Append('This is a multi-part message in MIME format.' + $crlf)
        [void]$sb.Append('--' + $boundary + $crlf)
        [void]$sb.Append('Content-Type: text/plain; charset=utf-8' + $crlf)
        [void]$sb.Append('Content-Transfer-Encoding: base64' + $crlf)
        [void]$sb.Append($crlf)
        [void]$sb.Append($bodyB64 + $crlf)
        foreach ($p in $parts) {
            [void]$sb.Append('--' + $boundary + $crlf)
            [void]$sb.Append('Content-Type: application/octet-stream; name="' + (Convert-PwxHeaderSafe -Value $p.file_name) + '"' + $crlf)
            [void]$sb.Append('Content-Transfer-Encoding: base64' + $crlf)
            [void]$sb.Append('Content-Disposition: attachment; filename="' + (Convert-PwxHeaderSafe -Value $p.file_name) + '"' + $crlf)
            [void]$sb.Append('X-Pwx-Sha256: ' + $p.sha256 + $crlf)
            [void]$sb.Append($crlf)
            [void]$sb.Append((Convert-PwxBase64Wrapped -Base64 $p.base64) + $crlf)
        }
        [void]$sb.Append('--' + $boundary + '--' + $crlf)
    }
    else {
        [void]$sb.Append('Content-Type: text/plain; charset=utf-8' + $crlf)
        [void]$sb.Append('Content-Transfer-Encoding: base64' + $crlf)
        [void]$sb.Append($crlf)
        [void]$sb.Append($bodyB64 + $crlf)
    }

    return $sb.ToString()
}

function Write-PwxOutboxEml {
    param([object]$Item)
    $dir = Get-PwxOutboxEmlDir
    $fileName = ([string]$Item.id) + '.eml'
    # El id viene del secuenciador (M-NNNN), pero se valida por defensa en profundidad
    Assert-PwxSafeFileName -Name $fileName | Out-Null
    $target = Assert-PwxSafeWorkspacePath -WorkspacePath (Get-PwxExportsDir) -Path (Join-Path $dir $fileName)

    $eml = Convert-PwxOutboxItemToEml -Item $Item -DateRfc1123 ([DateTime]::UtcNow.ToString('R', [System.Globalization.CultureInfo]::InvariantCulture))

    # Escritura atomica (tmp + replace), UTF-8 sin BOM, igual que el resto del store
    $parent = Split-Path -Parent $target
    New-PwxDirectory -Path $parent | Out-Null
    $tmp = Join-Path $parent ('.' + (Split-Path -Leaf $target) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    $bytes = @()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($eml)
        $stream = [System.IO.File]::Create($tmp)
        try {
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush($true)
        }
        finally {
            $stream.Dispose()
        }
        if (Test-Path -LiteralPath $target) {
            $bak = Join-Path $parent ('.' + (Split-Path -Leaf $target) + '.' + [guid]::NewGuid().ToString('N') + '.bak')
            [System.IO.File]::Replace($tmp, $target, $bak)
            Remove-Item -LiteralPath $bak -Force -ErrorAction SilentlyContinue | Out-Null
        }
        else {
            [System.IO.File]::Move($tmp, $target)
        }
    }
    catch {
        if (Test-Path -LiteralPath $tmp) {
            Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue | Out-Null
        }
        throw
    }

    Write-PwxLog -Component 'transport' -Message ("send.file id={0} eml={1} bytes={2}" -f $Item.id, $target, $bytes.Length)
    return $target
}

# ----------------------------------------------------------------------------
# Envio
# ----------------------------------------------------------------------------

function Send-PwxOutboxMessage {
    # Envia un mensaje APPROVED (o reenvia uno SENT con -Force) usando el
    # transporte indicado. Devuelve un resultado auditable; ante cualquier
    # fallo lanza y el mensaje QUEDA en su estado anterior (nunca SENT a ciegas).
    param(
        [Parameter(Mandatory = $true)]
        [string]$Id,
        [string]$Transport = '',
        [switch]$Force
    )

    $item = Get-PwxOutboxItem -Id $Id
    if (-not $item) { throw "Mensaje inexistente: $Id" }

    # Items legacy (anteriores a PR-6, sin message_id): se normalizan on-demand
    if (-not $item.message_id) {
        Set-PwxOutboxItemMember -Item $item -Name 'message_id' -Value (('<{0}@pwx.local>' -f $Id)) | Out-Null
        Save-PwxOutboxItem -Item $item | Out-Null
    }

    $transportName = if ($Transport) { ([string]$Transport).Trim().ToLowerInvariant() } else { Get-PwxOutboxDefaultTransport }
    if ((Get-PwxOutboxSupportedTransports) -notcontains $transportName) {
        throw ("Transporte no soportado: {0} (validos: {1})" -f $transportName, ((Get-PwxOutboxSupportedTransports) -join ', '))
    }

    if ($item.status -eq 'DRAFT') {
        throw "Mensaje $Id esta en DRAFT: requiere aprobacion humana (outbox:approve) antes de enviar"
    }
    if ($item.status -ne 'APPROVED' -and $item.status -ne 'SENT') {
        throw "Estado no enviable para $Id : $($item.status)"
    }
    $forced = $false
    if ($item.status -eq 'SENT') {
        if (-not $Force) {
            throw "Mensaje $Id ya fue SENT: use -Force para reenviarlo"
        }
        $forced = $true
    }

    # 1) Registrar el intento ANTES de intentar el transporte
    $attempts = 0
    if ($null -ne $item.attempts) { $attempts = [int]$item.attempts }
    $attempts++
    Set-PwxOutboxItemMember -Item $item -Name 'attempts' -Value $attempts | Out-Null
    Set-PwxOutboxItemMember -Item $item -Name 'last_attempt_at' -Value (Get-PwxTimestamp) | Out-Null
    Set-PwxOutboxItemMember -Item $item -Name 'last_error' -Value $null | Out-Null
    Save-PwxOutboxItem -Item $item | Out-Null

    Write-PwxLog -Component 'transport' -Message ("send.attempt id={0} transport={1} attempt={2} forced={3}" -f $Id, $transportName, $attempts, $forced)
    if ($item.job_id) {
        Add-PwxEvent -JobId ([string]$item.job_id) -Component 'transport' -Action 'send.attempt' -Data @{
            id = $Id; transport = $transportName; attempt = $attempts; forced = $forced
        }
    }

    # 2) Ejecutar el transporte (o fallar sin cambiar el estado)
    $emlPath = $null
    try {
        switch ($transportName) {
            'file' {
                $emlPath = Write-PwxOutboxEml -Item $item
            }
            'mock' {
                Write-PwxLog -Component 'transport' -Message ("send.mock id={0} (envio simulado: sin red, sin archivos)" -f $Id)
            }
            'mark-only' {
                # Solo transicion de estado: comportamiento historico del outbox
            }
            'smtp' {
                throw 'TRANSPORT_SMTP_NOT_IMPLEMENTED: smtp esta reservado para PR-7; use file (eml local), mock o mark-only'
            }
        }
    }
    catch {
        $fresh = Get-PwxOutboxItem -Id $Id
        if ($fresh) {
            Set-PwxOutboxItemMember -Item $fresh -Name 'last_error' -Value ([string]$_.Exception.Message) | Out-Null
            Save-PwxOutboxItem -Item $fresh | Out-Null
        }
        Write-PwxLog -Component 'transport' -Level 'ERROR' -Message ("send.fail id={0} transport={1} attempt={2} error={3}" -f $Id, $transportName, $attempts, $_.Exception.Message)
        if ($item.job_id) {
            Add-PwxEvent -JobId ([string]$item.job_id) -Component 'transport' -Action 'send.fail' -Data @{
                id = $Id; transport = $transportName; attempt = $attempts; error = [string]$_.Exception.Message
            }
        }
        throw
    }

    # 3) Transicion a SENT (o refresco de reenvio forzado)
    if ($forced) {
        $fresh = Get-PwxOutboxItem -Id $Id
        Set-PwxOutboxItemMember -Item $fresh -Name 'sent_at' -Value (Get-PwxTimestamp) | Out-Null
        Save-PwxOutboxItem -Item $fresh | Out-Null
        Write-PwxLog -Component 'transport' -Message ("send.forced id={0} transport={1} attempt={2}" -f $Id, $transportName, $attempts)
        if ($item.job_id) {
            Add-PwxEvent -JobId ([string]$item.job_id) -Component 'transport' -Action 'send.forced' -Data @{
                id = $Id; transport = $transportName; attempt = $attempts
            }
        }
    }
    else {
        Set-PwxOutboxStatus -Id $Id -Status 'SENT' | Out-Null
    }

    $final = Get-PwxOutboxItem -Id $Id
    return [ordered]@{
        id         = $Id
        status     = $final.status
        transport  = $transportName
        attempts   = [int]$final.attempts
        forced     = $forced
        message_id = $final.message_id
        eml        = $emlPath
        sent_at    = $final.sent_at
    }
}
