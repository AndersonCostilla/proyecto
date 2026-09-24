function Invoke-PwxService_word_service {
    param([string]$JobId)
    Write-PwxLog -Component 'service.word' -Level 'WARN' -Message "Servicio word-service no implementado (stub)" -JobId $JobId
    Add-PwxEvent -JobId $JobId -Component 'service.word' -Action 'not_implemented' -Data @{}
    return [pscustomobject]@{
        ok    = $false
        error = 'SERVICE_NOT_IMPLEMENTED'
    }
}