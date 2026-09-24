function Invoke-PwxService_data_service {
    param([string]$JobId)
    Write-PwxLog -Component 'service.data' -Level 'WARN' -Message "Servicio data-service no implementado (stub)" -JobId $JobId
    Add-PwxEvent -JobId $JobId -Component 'service.data' -Action 'not_implemented' -Data @{}
    return [pscustomobject]@{
        ok    = $false
        error = 'SERVICE_NOT_IMPLEMENTED'
    }
}