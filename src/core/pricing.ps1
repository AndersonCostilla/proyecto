function Get-PwxServiceCatalog {
    $cfg = Get-PwxConfig
    $catalog = Get-PwxJsonFile -Path $cfg.ServiceCatalogPath
    if (-not $catalog) {
        throw "Catalogo de servicios vacio o inexistente: $($cfg.ServiceCatalogPath)"
    }
    return $catalog
}

function Get-PwxService {
    param([string]$ServiceId)
    $catalog = Get-PwxServiceCatalog
    $prop = $catalog.services.PSObject.Properties[$ServiceId]
    if (-not $prop) {
        return $null
    }
    $svc = $prop.Value
    return [pscustomobject]@{
        id            = $ServiceId
        name          = $svc.name
        description   = $svc.description
        basePrice     = [double]$svc.basePrice
        estimatedHours = [double]$svc.estimatedHours
        minMarginPct  = [double]$svc.minMarginPct
        implemented   = [bool]$svc.implemented
        contract      = $svc.contract
        maxDiscountPct = [double]$svc.rules.maxDiscountPct
        addons        = $svc.addons
    }
}

function Get-PwxServiceIds {
    $catalog = Get-PwxServiceCatalog
    $ids = @()
    foreach ($p in $catalog.services.PSObject.Properties) {
        $ids += $p.Name
    }
    return $ids
}

function Get-PwxPrice {
    param(
        [Parameter(Mandatory)][string]$ServiceId,
        [string[]]$Addons = @()
    )
    $svc = Get-PwxService -ServiceId $ServiceId
    if (-not $svc) {
        throw "Servicio desconocido en el catalogo: $ServiceId"
    }
    $added = 0.0
    $addonDetail = @()
    foreach ($a in $Addons) {
        $ap = $svc.addons.PSObject.Properties[$a]
        if (-not $ap) {
            throw "Addon desconocido '$a' para servicio '$ServiceId'"
        }
        $price = [double]$ap.Value.price
        $added += $price
        $addonDetail += [pscustomobject]@{ id = $a; name = $ap.Value.name; price = $price }
    }
    $subtotal = $svc.basePrice + $added
    $cost = $svc.estimatedHours * 0.0
    $marginPct = 100.0
    if ($subtotal -gt 0) {
        $marginPct = [math]::Round((($subtotal - $cost) / $subtotal) * 100, 1)
    }
    return [pscustomobject]@{
        service_id      = $ServiceId
        service_name    = $svc.name
        currency        = (Get-PwxConfig).Currency
        base_price      = [math]::Round($svc.basePrice, 2)
        addons          = $addonDetail
        addons_total    = [math]::Round($added, 2)
        subtotal        = [math]::Round($subtotal, 2)
        estimated_hours = $svc.estimatedHours
        margin_pct      = $marginPct
        min_margin_pct  = $svc.minMarginPct
        max_discount_pct = $svc.maxDiscountPct
        discount_candidate = $svc.maxDiscountPct
    }
}

function Test-PwxDiscountAllowed {
    param([string]$ServiceId, [double]$DiscountPct)
    $svc = Get-PwxService -ServiceId $ServiceId
    if (-not $svc) { throw "Servicio desconocido: $ServiceId" }
    if ($DiscountPct -lt 0) { return $false }
    return ($DiscountPct -le $svc.maxDiscountPct)
}

function Get-PwxDiscountAmount {
    param([string]$ServiceId, [double]$DiscountPct, [string[]]$Addons = @())
    $svc = Get-PwxService -ServiceId $ServiceId
    if (-not $svc) { throw "Servicio desconocido: $ServiceId" }
    if (-not (Test-PwxDiscountAllowed -ServiceId $ServiceId -DiscountPct $DiscountPct)) {
        throw "Descuento fuera de politica para '$ServiceId': $DiscountPct % (maximo $($svc.maxDiscountPct) %)"
    }
    $price = Get-PwxPrice -ServiceId $ServiceId -Addons $Addons
    $amount = [math]::Round($price.subtotal * ($DiscountPct / 100.0), 2)
    $total = [math]::Round($price.subtotal - $amount, 2)
    if ($total -lt 0) {
        throw "Descuento produce precio negativo para '$ServiceId': total $total"
    }
    return [pscustomobject]@{
        subtotal        = $price.subtotal
        discount_pct    = $DiscountPct
        discount_amount = $amount
        total           = $total
    }
}