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