function Write-PwxLog {
    param(
        [string]$Component,
        [string]$Message,
        [string]$Level = 'INFO',
        [string]$JobId = ''
    )
    $cfg = Get-PwxConfig
    $entry = [ordered]@{
        ts        = Get-PwxTimestamp
        level     = $Level
        component = $Component
        job_id    = $JobId
        message   = $Message
    }
    $logDir = Join-Path $cfg.WorkspacePath 'logs'
    New-PwxDirectory -Path $logDir | Out-Null
    $logFile = Join-Path $logDir 'app.log.jsonl'
    $line = ($entry | ConvertTo-Json -Compress -Depth 20)
    [System.IO.File]::AppendAllText($logFile, $line + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false)))
}

function Add-PwxEvent {
    param(
        [string]$JobId,
        [string]$Component,
        [string]$Action,
        [hashtable]$Data
    )
    if ([string]::IsNullOrWhiteSpace($JobId)) { return }
    $cfg = Get-PwxConfig
    $event = [ordered]@{
        at        = Get-PwxTimestamp
        job_id    = $JobId
        component = $Component
        action    = $Action
        data      = $Data
    }
    $logDir = Join-Path $cfg.WorkspacePath 'logs\jobs'
    New-PwxDirectory -Path $logDir | Out-Null
    $logFile = Join-Path $logDir ($JobId + '.jsonl')
    $line = ($event | ConvertTo-Json -Compress -Depth 20)
    [System.IO.File]::AppendAllText($logFile, $line + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false)))
}