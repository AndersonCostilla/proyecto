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
        contract       = $svc.contract
        maxDiscountPct = [double]$svc.rules.maxDiscountPct
        addons         = $svc.addons
        requiresPayment = if ($null -eq $svc.requiresPayment) { $true } else { [bool]$svc.requiresPayment }
        pricing        = $svc.pricing
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
function Get-PwxPricingComplexityMultiplier {
    param(
        [Parameter(Mandatory)][object]$Service,
        [string]$Complexity = 'standard'
    )
    $level = $Complexity.ToLowerInvariant().Trim()
    if ([string]::IsNullOrWhiteSpace($level)) { $level = 'standard' }
    if ($null -eq $Service.pricing -or $null -eq $Service.pricing.complexity) {
        if ($level -eq 'standard') { return [pscustomobject]@{ level = 'standard'; multiplier = 1.0 } }
        throw "El servicio $($Service.id) no define complejidad '$level'"
    }
    $prop = $Service.pricing.complexity.PSObject.Properties[$level]
    if (-not $prop) {
        $valid = @($Service.pricing.complexity.PSObject.Properties | ForEach-Object { $_.Name }) -join ', '
        throw "Complejidad desconocida '$level' para $($Service.id). Permitidas: $valid"
    }
    $multiplier = [double]$prop.Value
    if ($multiplier -le 0) { throw "Multiplicador de complejidad inválido para '$level'" }
    return [pscustomobject]@{ level = $level; multiplier = $multiplier }
}

function Get-PwxQuote {
    param(
        [Parameter(Mandatory)][string]$ServiceId,
        [string[]]$Addons = @(),
        [string]$Complexity = 'standard',
        [int]$Units = 1,
        [double]$DiscountPct = 0
    )
    if ($Units -lt 1) { throw 'La cantidad de unidades debe ser al menos 1' }
    $svc = Get-PwxService -ServiceId $ServiceId
    if (-not $svc) { throw "Servicio desconocido en el catálogo: $ServiceId" }
    if ($DiscountPct -lt 0 -or -not (Test-PwxDiscountAllowed -ServiceId $ServiceId -DiscountPct $DiscountPct)) {
        throw "Descuento fuera de política para '$ServiceId': $DiscountPct % (máximo $($svc.maxDiscountPct) %)"
    }
    $complexityInfo = Get-PwxPricingComplexityMultiplier -Service $svc -Complexity $Complexity
    $includedUnits = 1
    $extraUnitPrice = 0.0
    $unitLabel = 'unidad'
    if ($svc.pricing) {
        if ($null -ne $svc.pricing.includedUnits) { $includedUnits = [int]$svc.pricing.includedUnits }
        if ($null -ne $svc.pricing.extraUnitPrice) { $extraUnitPrice = [double]$svc.pricing.extraUnitPrice }
        if ($svc.pricing.unitLabel) { $unitLabel = [string]$svc.pricing.unitLabel }
    }
    if ($includedUnits -lt 1) { $includedUnits = 1 }
    if ($extraUnitPrice -lt 0) { throw "Precio por unidad adicional inválido en $ServiceId" }

    $extraUnits = [math]::Max(0, $Units - $includedUnits)
    $volumeTotal = [math]::Round($extraUnits * $extraUnitPrice, 2)
    $workSubtotal = [math]::Round($svc.basePrice + $volumeTotal, 2)
    $complexityAmount = [math]::Round($workSubtotal * ($complexityInfo.multiplier - 1), 2)

    $addonTotal = 0.0
    $addonDetail = @()
    foreach ($addonId in $Addons) {
        $prop = $svc.addons.PSObject.Properties[$addonId]
        if (-not $prop) { throw "Addon desconocido '$addonId' para servicio '$ServiceId'" }
        $addonPrice = [double]$prop.Value.price
        $addonTotal += $addonPrice
        $addonDetail += [pscustomobject]@{ id = $addonId; name = $prop.Value.name; price = [math]::Round($addonPrice, 2) }
    }
    $subtotal = [math]::Round($workSubtotal + $complexityAmount + $addonTotal, 2)
    $discountAmount = [math]::Round($subtotal * ($DiscountPct / 100.0), 2)
    $total = [math]::Round($subtotal - $discountAmount, 2)
    if ($total -lt 0) { throw 'La cotización no puede ser negativa' }

    return [pscustomobject]@{
        service_id          = $ServiceId
        service_name        = $svc.name
        currency            = (Get-PwxConfig).Currency
        base_price          = [math]::Round($svc.basePrice, 2)
        units               = $Units
        included_units      = $includedUnits
        extra_units         = $extraUnits
        unit_label          = $unitLabel
        extra_unit_price    = [math]::Round($extraUnitPrice, 2)
        volume_total        = $volumeTotal
        complexity          = $complexityInfo.level
        complexity_multiplier = $complexityInfo.multiplier
        complexity_amount   = $complexityAmount
        addons              = $addonDetail
        addons_total        = [math]::Round($addonTotal, 2)
        subtotal            = $subtotal
        discount_pct        = $DiscountPct
        discount_amount     = $discountAmount
        total               = $total
        estimated_hours     = $svc.estimatedHours
        min_margin_pct      = $svc.minMarginPct
        max_discount_pct    = $svc.maxDiscountPct
    }
}
