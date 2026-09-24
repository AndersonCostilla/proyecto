function Get-PwxOllamaStatus {
    $cfg = Get-PwxConfig
    try {
        $r = Invoke-RestMethod -Uri ($cfg.OllamaBaseUrl + '/api/tags') -Method Get -TimeoutSec $cfg.ConnectTimeoutSec
        $models = @($r.models | ForEach-Object { $_.name })
        return [pscustomobject]@{
            status = 'OK'
            models = $models
        }
    }
    catch {
        return [pscustomobject]@{
            status = 'OLLAMA_OFFLINE'
            models = @()
        }
    }
}

function Test-PwxModelAvailable {
    param([string]$Model = '')
    if (-not $Model) { $Model = (Get-PwxConfig).Model }
    $status = Get-PwxOllamaStatus
    if ($status.status -ne 'OK') {
        return 'OLLAMA_OFFLINE'
    }
    $exact = $status.models -contains $Model
    if ($exact) { return 'OK' }
    $withTag = $status.models -contains ($Model + ':latest')
    if ($withTag) { return 'OK' }
    foreach ($m in $status.models) {
        if ($m -like ($Model + ':*')) { return 'OK' }
    }
    return 'MODEL_NOT_FOUND'
}

function Add-PwxOllamaSystemMessage {
    param([string]$Content, [hashtable]$Msg)
    return $Msg
}

function Invoke-PwxOllamaChat {
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [string]$System = 'Eres un asistente de un sistema comercial local.',
        [string]$Model = '',
        [bool]$FormatJson = $false,
        [double]$Temperature = 0.2
    )
    if (-not $Model) { $Model = (Get-PwxConfig).Model }

    $availability = Test-PwxModelAvailable -Model $Model
    if ($availability -ne 'OK') {
        return [pscustomobject]@{
            ok       = $false
            code     = $availability
            content  = $null
            error    = "Modelo no disponible: $availability"
        }
    }

    $cfg = Get-PwxConfig
    $body = [ordered]@{
        model    = $Model
        stream   = $false
        messages = @(
            @{ role = 'system'; content = $System },
            @{ role = 'user'; content = $Prompt }
        )
        options  = @{ temperature = $Temperature }
    }
    if ($FormatJson) {
        $body.format = 'json'
    }

    try {
        $resp = Invoke-RestMethod -Uri ($cfg.OllamaBaseUrl + '/api/chat') -Method Post `
            -ContentType 'application/json' -Body ($body | ConvertTo-Json -Depth 20) `
            -TimeoutSec $cfg.RequestTimeoutSec
        if ($null -eq $resp.message -or [string]::IsNullOrWhiteSpace($resp.message.content)) {
            return [pscustomobject]@{
                ok      = $false
                code    = 'MODEL_INVALID_RESPONSE'
                content = $null
                error   = 'Respuesta vacia del modelo'
            }
        }
        return [pscustomobject]@{
            ok      = $true
            code    = 'OK'
            content = $resp.message.content
            error   = $null
        }
    }
    catch {
        $code = 'MODEL_ERROR'
        if ($_.Exception -is [System.Net.WebException]) {
            $status = 0
            try { $status = [int]$_.Exception.Response.StatusCode } catch { $status = 0 }
            if ($status -eq 404) { $code = 'MODEL_NOT_FOUND' }
            elseif ($status -eq 400) { $code = 'MODEL_ERROR' }
            elseif ($status -ge 500 -and $status -lt 600) { $code = 'MODEL_ERROR' }
            elseif ($_.Exception.Message -match 'timed out|Timeout') { $code = 'MODEL_TIMEOUT' }
            else { $code = 'OLLAMA_OFFLINE' }
        }
        elseif ($_.Exception.Message -match 'timed out|Timeout') {
            $code = 'MODEL_TIMEOUT'
        }
        return [pscustomobject]@{
            ok      = $false
            code    = $code
            content = $null
            error   = $_.Exception.Message
        }
    }
}

function ConvertFrom-PwxOllamaJson {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $trimmed = $Text.Trim()
    try {
        return ($trimmed | ConvertFrom-Json)
    }
    catch {
        $start = $trimmed.IndexOf('{')
        $end = $trimmed.LastIndexOf('}')
        if ($start -ge 0 -and $end -gt $start) {
            $candidate = $trimmed.Substring($start, $end - $start + 1)
            try {
                return ($candidate | ConvertFrom-Json)
            }
            catch {
                return $null
            }
        }
        return $null
    }
}