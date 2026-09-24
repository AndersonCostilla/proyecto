function Invoke-PwxService_pdf_service {
    param([string]$JobId)
    Write-PwxLog -Component 'service.pdf' -Level 'WARN' -Message "Servicio pdf-service no implementado (stub)" -JobId $JobId
    Add-PwxEvent -JobId $JobId -Component 'service.pdf' -Action 'not_implemented' -Data @{}
    return [pscustomobject]@{
        ok    = $false
        error = 'SERVICE_NOT_IMPLEMENTED'
    }
}