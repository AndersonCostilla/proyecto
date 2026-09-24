function Invoke-PwxService_construction_service {
    param([string]$JobId)
    Write-PwxLog -Component 'service.construction' -Level 'WARN' -Message "Servicio construction-service no implementado (stub)" -JobId $JobId
    Add-PwxEvent -JobId $JobId -Component 'service.construction' -Action 'not_implemented' -Data @{}
    return [pscustomobject]@{
        ok    = $false
        error = 'SERVICE_NOT_IMPLEMENTED'
    }
}