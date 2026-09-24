function Get-PwxRegisteredServices {
    $catalog = Get-PwxServiceCatalog
    $result = @()
    foreach ($id in (Get-PwxServiceIds)) {
        $svc = Get-PwxService -ServiceId $id
        $result += [pscustomobject]@{
            id          = $id
            name        = $svc.name
            base_price  = $svc.basePrice
            implemented = Test-PwxServiceImplemented -ServiceId $id
        }
    }
    return $result
}

function Test-PwxServiceImplemented {
    param([string]$ServiceId)
    $svc = Get-PwxService -ServiceId $ServiceId
    if (-not $svc) { return $false }
    return ([bool]$svc.implemented)
}