function Invoke-PwxService_excel_service {
    param([string]$JobId)
    Write-PwxLog -Component 'service.excel' -Level 'WARN' -Message "Servicio excel-service no implementado (stub)" -JobId $JobId
    Add-PwxEvent -JobId $JobId -Component 'service.excel' -Action 'not_implemented' -Data @{}
    return [pscustomobject]@{
        ok    = $false
        error = 'SERVICE_NOT_IMPLEMENTED'
    }
}