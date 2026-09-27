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

function Get-PwxOllamaErrorInfo {
    param([object]$ErrorRecord)
    $status = 0
    $detail = ''
    $exception = $ErrorRecord.Exception

    try {
        if ($exception -and $exception.Response -and $exception.Response.StatusCode) {
            $status = [int]$exception.Response.StatusCode
        }
    }
    catch { }
    try {
        if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) {
            $detail = [string]$ErrorRecord.ErrorDetails.Message
        }
    }
    catch { }
    try {
        if (-not $detail -and $exception -and $exception.Message) {
            $detail = [string]$exception.Message
        }
    }
    catch { }
    return [pscustomobject]@{ status = $status; detail = $detail }
}

function Invoke-PwxOllamaChatRequest {
    param(
        [Parameter(Mandatory)][object]$Body,
        [Parameter(Mandatory)][object]$Config
    )
    return Invoke-RestMethod -Uri ($Config.OllamaBaseUrl + '/api/chat') -Method Post `
        -ContentType 'application/json' -Body ($Body | ConvertTo-Json -Depth 20) `
        -TimeoutSec $Config.RequestTimeoutSec
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
    if ($FormatJson) { $body.format = 'json' }

    $resp = $null
    $failure = $null
    $formatFallback = $false
    try {
        $resp = Invoke-PwxOllamaChatRequest -Body $body -Config $cfg
    }
    catch {
        $failure = $_
    }

    # Algunas versiones o modelos de Ollama rechazan format=json con HTTP 400.
    # Se reintenta una única vez sin ese parámetro; el llamador sigue validando
    # el JSON recibido, por lo que nunca se acepta texto libre como especificación.
    if ($failure -and $FormatJson) {
        $firstInfo = Get-PwxOllamaErrorInfo -ErrorRecord $failure
        if ($firstInfo.status -eq 400) {
            [void]$body.Remove('format')
            try {
                $resp = Invoke-PwxOllamaChatRequest -Body $body -Config $cfg
                $failure = $null
                $formatFallback = $true
            }
            catch {
                $failure = $_
            }
        }
    }

    if ($failure) {
        $info = Get-PwxOllamaErrorInfo -ErrorRecord $failure
        $code = 'MODEL_ERROR'
        if ($info.status -eq 404) { $code = 'MODEL_NOT_FOUND' }
        elseif ($info.status -eq 400) { $code = 'MODEL_ERROR' }
        elseif ($info.status -ge 500 -and $info.status -lt 600) { $code = 'MODEL_ERROR' }
        elseif ($info.detail -match 'timed out|Timeout') { $code = 'MODEL_TIMEOUT' }
        elseif ($failure.Exception -is [System.Net.WebException]) { $code = 'OLLAMA_OFFLINE' }
        $errorText = if ($info.detail) { "Ollama HTTP $($info.status): $($info.detail)" } else { 'Error sin detalle al invocar Ollama' }
        return [pscustomobject]@{
            ok       = $false
            code     = $code
            content  = $null
            error    = $errorText
            format_fallback = $formatFallback
        }
    }

    if ($null -eq $resp.message -or [string]::IsNullOrWhiteSpace($resp.message.content)) {
        return [pscustomobject]@{
            ok      = $false
            code    = 'MODEL_INVALID_RESPONSE'
            content = $null
            error   = 'Respuesta vacia del modelo'
            format_fallback = $formatFallback
        }
    }
    return [pscustomobject]@{
        ok      = $true
        code    = 'OK'
        content = $resp.message.content
        error   = $null
        format_fallback = $formatFallback
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