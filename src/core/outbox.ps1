function Get-PwxOutboxDir {
    $cfg = Get-PwxConfig
    $dir = Join-Path $cfg.WorkspacePath 'outbox'
    New-PwxDirectory -Path $dir | Out-Null
    return $dir
}

function New-PwxOutboxItem {
    param(
        [string]$Type = 'message',
        [string]$Channel = '',
        [string]$Recipient = '',
        [string]$Subject = '',
        [string]$Body = '',
        [string[]]$Attachments = @(),
        [string]$JobId = '',
        [string]$ClientId = '',
        [string]$LeadId = ''
    )
    $id = Get-PwxOutboxId
    $item = [ordered]@{
        id           = $id
        type         = $Type
        channel      = $Channel
        recipient    = $Recipient
        subject      = $Subject
        body         = $Body
        attachments  = @()
        status       = 'DRAFT'
        job_id       = $JobId
        client_id    = $ClientId
        lead_id      = $LeadId
        created_at   = Get-PwxTimestamp
        approved_by  = $null
        approved_at  = $null
        sent_at      = $null
    }
    foreach ($h in $Attachments) {
        if (Test-Path -LiteralPath $h) {
            $item.attachments += [ordered]@{
                path   = $h
                sha256 = Get-PwxSha256 -Path $h
                size   = (Get-Item -LiteralPath $h).Length
            }
        }
        else {
            $item.attachments += [ordered]@{ path = $h; sha256 = $null; size = 0 }
        }
    }
    Set-PwxJsonFile -Path (Join-Path (Get-PwxOutboxDir) ($id + '.json')) -Object $item | Out-Null
    Write-PwxLog -Component 'outbox' -Message "Mensaje creado (DRAFT): $id -> $Recipient" -JobId $JobId
    return (Get-PwxOutboxItem -Id $id)
}

function Get-PwxOutboxItem {
    param([string]$Id)
    $file = Join-Path (Get-PwxOutboxDir) ($Id + '.json')
    if (-not (Test-Path -LiteralPath $file)) { return $null }
    return Get-PwxJsonFile -Path $file
}

function Get-PwxOutboxItems {
    param([string]$Status = '')
    $result = @()
    foreach ($f in (Get-ChildItem -LiteralPath (Get-PwxOutboxDir) -Filter '*.json' -ErrorAction SilentlyContinue)) {
        $item = Get-PwxJsonFile -Path $f.FullName
        if (-not $Status -or $item.status -eq $Status) {
            $result += $item
        }
    }
    return $result
}

function Get-PwxExportsDir {
    $cfg = Get-PwxConfig
    $dir = Join-Path $cfg.WorkspacePath 'exports'
    New-PwxDirectory -Path $dir | Out-Null
    return $dir
}

function Convert-PwxCsvCell {
    param([object]$Value)
    $s = if ($null -eq $Value) { '' } else { [string]$Value }
    $trimmed = $s.TrimStart(' ', "`t", "`r", "`n")
    if ($trimmed.Length -gt 0) {
        $first = $trimmed[0]
        if ($first -eq '=' -or $first -eq '+' -or $first -eq '-' -or $first -eq '@') {
            $s = '''' + $s
        }
    }
    if ($s.IndexOf(',') -ge 0 -or $s.IndexOf('"') -ge 0 -or $s.IndexOf("`n") -ge 0 -or $s.IndexOf("`r") -ge 0) {
        $s = '"' + ($s.Replace('"', '""')) + '"'
    }
    return $s
}

function Test-PwxOutboxRecipientCompatible {
    param([object]$Item, [ref]$Reason)
    $recipient = [string]$Item.recipient
    if (-not $recipient.Trim()) {
        $Reason.Value = 'sin destinatario'
        return $false
    }
    $ch = ([string]$Item.channel).ToLowerInvariant()
    if ($ch -eq 'email') {
        if ($recipient -notmatch '^[^\s@]+@[^\s@]+\.[^\s@]+$') {
            $Reason.Value = 'canal email requiere un email valido'
            return $false
        }
    }
    elseif ($ch -eq 'whatsapp') {
        if ($recipient -notmatch '^\d+$') {
            $Reason.Value = 'canal whatsapp requiere telefono de solo digitos'
            return $false
        }
    }
    $Reason.Value = ''
    return $true
}

function Get-PwxNewExportFileName {
    param([string]$ExportsDir)
    $base = 'outbox-drafts-' + (Get-Date -Format 'yyyyMMdd-HHmmss-ffffff')
    $candidate = Join-Path $ExportsDir ($base + '.csv')
    $n = 1
    while (Test-Path -LiteralPath $candidate) {
        $candidate = Join-Path $ExportsDir ($base + '-' + $n + '.csv')
        $n++
    }
    return $candidate
}

function Export-PwxOutboxCsv {
    param([string]$Path = '')
    $items = @(Get-PwxOutboxItems -Status 'DRAFT')
    $exported = New-Object System.Collections.ArrayList
    $omitted = New-Object System.Collections.ArrayList

    foreach ($item in $items) {
        $reason = ''
        $reasonRef = [ref]$reason
        if (-not (Test-PwxOutboxRecipientCompatible -Item $item -Reason $reasonRef)) {
            [void]$omitted.Add([ordered]@{ id = $item.id; reason = $reasonRef.Value })
            continue
        }
        [void]$exported.Add([ordered]@{
            id         = $item.id
            channel    = $item.channel
            recipient  = $item.recipient
            subject    = $item.subject
            body       = $item.body
            lead_id    = $item.lead_id
            status     = $item.status
            created_at = $item.created_at
        })
    }

    $exportsDir = Get-PwxExportsDir

    $fullPath = ''
    if ($Path) {
        if ([System.IO.Path]::IsPathRooted($Path)) {
            $fullPath = [System.IO.Path]::GetFullPath($Path)
        }
        else {
            $fullPath = [System.IO.Path]::GetFullPath((Join-Path $exportsDir $Path))
        }
        $fullPath = Assert-PwxSafeWorkspacePath -WorkspacePath $exportsDir -Path $fullPath
        if (Test-Path -LiteralPath $fullPath) {
            throw "El archivo ya existe; no se sobrescribe: $fullPath"
        }
    }
    else {
        $fullPath = Get-PwxNewExportFileName -ExportsDir $exportsDir
    }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('id,channel,recipient,subject,body,lead_id,status,created_at')
    foreach ($row in $exported) {
        $cells = @($row.id, $row.channel, $row.recipient, $row.subject, $row.body, $row.lead_id, $row.status, $row.created_at)
        $line = @($cells | ForEach-Object { Convert-PwxCsvCell -Value $_ }) -join ','
        [void]$sb.AppendLine($line)
    }

    $parent = Split-Path -Parent $fullPath
    New-PwxDirectory -Path $parent | Out-Null
    $enc = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllText($fullPath, $sb.ToString(), $enc)
    Write-PwxLog -Component 'outbox' -Message "Exportados $($exported.Count) DRAFT a $fullPath (omitidos $($omitted.Count))"

    return [ordered]@{
        path     = $fullPath
        exported = $exported.Count
        omitted  = [ordered]@{
            count = $omitted.Count
            items = $omitted
        }
    }
}

function Set-PwxOutboxStatus {
    param([string]$Id, [string]$Status, [string]$By = '')
    $item = Get-PwxOutboxItem -Id $Id
    if (-not $item) { throw "Mensaje inexistente: $Id" }
    $valid = $true
    if ($item.status -eq 'SENT') { $valid = $false }

    if ($Status -eq 'APPROVED') {
        if ($item.status -ne 'DRAFT') { $valid = $false }
        if ($valid) {
            $item.approved_by = if ($By) { $By } else { 'humano' }
            $item.approved_at = Get-PwxTimestamp
        }
    }
    elseif ($Status -eq 'SENT') {
        if ($item.status -ne 'APPROVED') { $valid = $false }
        if ($valid) {
            $item.sent_at = Get-PwxTimestamp
        }
    }
    elseif ($Status -eq 'DRAFT') {
        $item.approved_by = $null
        $item.approved_at = $null
        $item.sent_at = $null
    }
    else {
        $valid = $false
    }

    if (-not $valid) {
        throw "Transicion de outbox invalida: $($item.status) -> $Status"
    }
    $item.status = $Status
    Set-PwxJsonFile -Path (Join-Path (Get-PwxOutboxDir) ($Id + '.json')) -Object $item | Out-Null
    Write-PwxLog -Component 'outbox' -Message "Mensaje $Id -> $Status" -JobId $item.job_id
    return (Get-PwxOutboxItem -Id $Id)
}