# Pago manual verificable para trabajos comerciales.
# No realiza cobros ni valida movimientos bancarios automáticamente: conserva
# evidencia, exige revisión humana y bloquea producción hasta aprobación.

$PwxPaymentProofExtensions = @('.png', '.jpg', '.jpeg', '.pdf')
$PwxPaymentProofMaxBytes = 10485760

function Get-PwxPaymentsDir {
    $cfg = Get-PwxConfig
    $dir = Join-Path $cfg.WorkspacePath 'payments'
    New-PwxDirectory -Path $dir | Out-Null
    return $dir
}

function Get-PwxPaymentDir {
    param([Parameter(Mandatory)][string]$PaymentId)
    Assert-PwxSafeFileName -Name $PaymentId | Out-Null
    return (Join-Path (Get-PwxPaymentsDir) $PaymentId)
}

function Get-PwxPaymentFile {
    param([Parameter(Mandatory)][string]$PaymentId)
    return (Join-Path (Get-PwxPaymentDir -PaymentId $PaymentId) 'payment.json')
}

function Get-PwxPayment {
    param([Parameter(Mandatory)][string]$PaymentId)
    $file = Get-PwxPaymentFile -PaymentId $PaymentId
    if (-not (Test-Path -LiteralPath $file)) { return $null }
    return Get-PwxJsonFile -Path $file
}

function Get-PwxPaymentsForJob {
    param([Parameter(Mandatory)][string]$JobId)
    $result = @()
    foreach ($dir in (Get-ChildItem -LiteralPath (Get-PwxPaymentsDir) -Directory -ErrorAction SilentlyContinue)) {
        $payment = Get-PwxPayment -PaymentId $dir.Name
        if ($payment -and $payment.job_id -eq $JobId) { $result += $payment }
    }
    return @($result | Sort-Object requested_at, id)
}

function Get-PwxPaymentMethodsFile {
    $root = (Get-PwxConfig).Root
    if ($env:PWX_PAYMENT_METHODS_FILE) {
        return [System.IO.Path]::GetFullPath($env:PWX_PAYMENT_METHODS_FILE)
    }
    $local = Join-Path $root 'config\payment-methods.local.json'
    if (Test-Path -LiteralPath $local) { return $local }
    return (Join-Path $root 'config\payment-methods.example.json')
}

function Get-PwxPaymentMethods {
    $path = Get-PwxPaymentMethodsFile
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Falta configuración de métodos de pago: $path"
    }
    $config = Get-PwxJsonFile -Path $path
    if ($null -eq $config -or $null -eq $config.methods) {
        throw "Configuración de pagos inválida: $path"
    }
    return $config
}

function Get-PwxPaymentMethod {
    param([Parameter(Mandatory)][string]$MethodId)
    $config = Get-PwxPaymentMethods
    $prop = $config.methods.PSObject.Properties[$MethodId]
    if (-not $prop) {
        throw "Método de pago desconocido: $MethodId"
    }
    $method = $prop.Value
    if (-not [bool]$method.enabled) {
        throw "Método de pago no habilitado: $MethodId. Configure config\\payment-methods.local.json"
    }
    if ([string]::IsNullOrWhiteSpace([string]$method.recipient)) {
        throw "Método de pago sin destino configurado: $MethodId"
    }
    return [pscustomobject]@{
        id           = $MethodId
        name         = [string]$method.name
        recipient    = [string]$method.recipient
        instructions = [string]$method.instructions
        qr_path      = [string]$method.qr_path
    }
}

function Get-PwxQuoteServiceId {
    param([Parameter(Mandatory)][object]$Job)
    if ($Job.requirements -and $Job.requirements.service) {
        return [string]$Job.requirements.service
    }
    return [string]$Job.service
}

function Get-PwxActivePaymentForJob {
    param([Parameter(Mandatory)][string]$JobId)
    $payments = @(Get-PwxPaymentsForJob -JobId $JobId)
    $active = @($payments | Where-Object { $_.status -in @('REQUESTED', 'PROOF_SUBMITTED', 'APPROVED') })
    if ($active.Count -eq 0) { return $null }
    return $active[$active.Count - 1]
}

function Save-PwxPayment {
    param([Parameter(Mandatory)][object]$Payment)
    if (-not $Payment.id) { throw 'Pago sin id' }
    $allowed = @('REQUESTED', 'PROOF_SUBMITTED', 'APPROVED', 'REJECTED', 'CANCELLED')
    if ($allowed -notcontains [string]$Payment.status) {
        throw "Estado de pago inválido: $($Payment.status)"
    }
    $dir = Get-PwxPaymentDir -PaymentId $Payment.id
    New-PwxDirectory -Path $dir | Out-Null
    $Payment.updated_at = Get-PwxTimestamp
    Set-PwxJsonFile -Path (Get-PwxPaymentFile -PaymentId $Payment.id) -Object $Payment | Out-Null
    return (Get-PwxPayment -PaymentId $Payment.id)
}

function New-PwxPaymentRequest {
    param(
        [Parameter(Mandatory)][string]$JobId,
        [Parameter(Mandatory)][string]$Method,
        [string[]]$Addons = @(),
        [string]$Complexity = 'standard',
        [int]$Units = 1,
        [double]$DiscountPct = 0
    )
    $job = Get-PwxJob -JobId $JobId
    if (-not $job) { throw "Trabajo inexistente: $JobId" }
    if ($job.state -in @('CANCELLED', 'COMPLETED', 'DELIVERED')) {
        throw "No se puede solicitar pago para un trabajo en estado $($job.state)"
    }
    if (-not $job.requirements) {
        throw 'Primero complete y revise los requisitos antes de solicitar el pago'
    }
    $serviceId = Get-PwxQuoteServiceId -Job $job
    $service = Get-PwxService -ServiceId $serviceId
    if (-not $service) { throw "Servicio desconocido para cotización: $serviceId" }
    if (-not $service.requiresPayment) {
        throw "El servicio $serviceId no requiere pago previo"
    }
    $active = Get-PwxActivePaymentForJob -JobId $JobId
    if ($active) {
        throw "Ya existe un pago activo $($active.id) con estado $($active.status) para $JobId"
    }
    $paymentMethod = Get-PwxPaymentMethod -MethodId $Method
    $quote = Get-PwxQuote -ServiceId $serviceId -Addons $Addons -Complexity $Complexity -Units $Units -DiscountPct $DiscountPct
    $paymentId = Get-PwxPaymentId
    $quoteId = Get-PwxQuoteId
    $now = Get-PwxTimestamp
    $payment = [ordered]@{
        id               = $paymentId
        job_id           = $JobId
        client_id        = $job.client_id
        status           = 'REQUESTED'
        quote            = [ordered]@{
            id           = $quoteId
            service_id   = $quote.service_id
            service_name = $quote.service_name
            currency     = $quote.currency
            amount       = $quote.total
            detail       = $quote
            issued_at    = $now
        }
        method           = [ordered]@{
            id           = $paymentMethod.id
            name         = $paymentMethod.name
            recipient    = $paymentMethod.recipient
            instructions = $paymentMethod.instructions
            qr_path      = $paymentMethod.qr_path
        }
        proof            = $null
        requested_at     = $now
        reviewed_at      = $null
        reviewed_by      = $null
        review_reason    = $null
        created_at       = $now
        updated_at       = $now
    }
    Save-PwxPayment -Payment $payment | Out-Null
    $job | Add-Member -NotePropertyName payment_id -NotePropertyValue $paymentId -Force
    Save-PwxJob -Job $job | Out-Null
    Add-PwxEvent -JobId $JobId -Component 'payments' -Action 'payment.requested' -Data @{ payment_id = $paymentId; quote_id = $quoteId; amount = $quote.total; currency = $quote.currency; method = $Method }
    Write-PwxLog -Component 'payments' -Message "Pago solicitado: $paymentId para $JobId por $($quote.total) $($quote.currency)" -JobId $JobId
    return (Get-PwxPayment -PaymentId $paymentId)
}

function Submit-PwxPaymentProof {
    param(
        [Parameter(Mandatory)][string]$JobId,
        [Parameter(Mandatory)][string]$Path,
        [string]$Reference = ''
    )
    $payment = Get-PwxActivePaymentForJob -JobId $JobId
    if (-not $payment) { throw "No existe pago activo para $JobId" }
    if ($payment.status -ne 'REQUESTED') {
        throw "El pago $($payment.id) no acepta comprobantes en estado $($payment.status)"
    }
    if (-not (Test-Path -LiteralPath $Path)) { throw "Comprobante inexistente: $Path" }
    $item = Get-Item -LiteralPath $Path
    if ($item.PSIsContainer) { throw 'El comprobante debe ser un archivo, no una carpeta' }
    if ($item.Length -le 0) { throw 'El comprobante no puede estar vacío' }
    if ($item.Length -gt $PwxPaymentProofMaxBytes) { throw "El comprobante supera el límite de $PwxPaymentProofMaxBytes bytes" }
    $extension = [System.IO.Path]::GetExtension($item.Name).ToLowerInvariant()
    if ($PwxPaymentProofExtensions -notcontains $extension) {
        throw "Formato de comprobante no permitido: $extension. Permitidos: $($PwxPaymentProofExtensions -join ', ')"
    }
    $proofDir = Join-Path (Get-PwxPaymentDir -PaymentId $payment.id) 'proof'
    New-PwxDirectory -Path $proofDir | Out-Null
    $targetName = 'comprobante' + $extension
    $target = Assert-PwxSafeWorkspacePath -WorkspacePath (Get-PwxPaymentDir -PaymentId $payment.id) -Path (Join-Path $proofDir $targetName)
    Copy-Item -LiteralPath $item.FullName -Destination $target -Force
    $payment.proof = [ordered]@{
        original_name = $item.Name
        path          = ('proof\' + $targetName)
        size          = (Get-Item -LiteralPath $target).Length
        sha256        = Get-PwxSha256 -Path $target
        reference     = $Reference
        submitted_at  = Get-PwxTimestamp
    }
    $payment.status = 'PROOF_SUBMITTED'
    Save-PwxPayment -Payment $payment | Out-Null
    Add-PwxEvent -JobId $JobId -Component 'payments' -Action 'payment.proof_submitted' -Data @{ payment_id = $payment.id; reference = $Reference }
    Write-PwxLog -Component 'payments' -Message "Comprobante recibido: $($payment.id) para $JobId" -JobId $JobId
    return (Get-PwxPayment -PaymentId $payment.id)
}

function Approve-PwxPayment {
    param(
        [Parameter(Mandatory)][string]$JobId,
        [string]$By = 'operador'
    )
    $payment = Get-PwxActivePaymentForJob -JobId $JobId
    if (-not $payment) { throw "No existe pago activo para $JobId" }
    if ($payment.status -ne 'PROOF_SUBMITTED') {
        throw "El pago $($payment.id) debe tener comprobante antes de aprobarse"
    }
    $payment.status = 'APPROVED'
    $payment.reviewed_at = Get-PwxTimestamp
    $payment.reviewed_by = if ($By) { $By } else { 'operador' }
    $payment.review_reason = 'Comprobante aprobado manualmente'
    Save-PwxPayment -Payment $payment | Out-Null
    Add-PwxEvent -JobId $JobId -Component 'payments' -Action 'payment.approved' -Data @{ payment_id = $payment.id; by = $payment.reviewed_by; amount = $payment.quote.amount }
    Write-PwxLog -Component 'payments' -Message "Pago aprobado: $($payment.id) para $JobId por $($payment.reviewed_by)" -JobId $JobId
    return (Get-PwxPayment -PaymentId $payment.id)
}

function Reject-PwxPayment {
    param(
        [Parameter(Mandatory)][string]$JobId,
        [Parameter(Mandatory)][string]$Reason,
        [string]$By = 'operador'
    )
    $payment = Get-PwxActivePaymentForJob -JobId $JobId
    if (-not $payment) { throw "No existe pago activo para $JobId" }
    if ($payment.status -notin @('REQUESTED', 'PROOF_SUBMITTED')) {
        throw "El pago $($payment.id) no se puede rechazar en estado $($payment.status)"
    }
    if ([string]::IsNullOrWhiteSpace($Reason)) { throw 'El rechazo requiere una razón' }
    $payment.status = 'REJECTED'
    $payment.reviewed_at = Get-PwxTimestamp
    $payment.reviewed_by = if ($By) { $By } else { 'operador' }
    $payment.review_reason = $Reason
    Save-PwxPayment -Payment $payment | Out-Null
    Add-PwxEvent -JobId $JobId -Component 'payments' -Action 'payment.rejected' -Data @{ payment_id = $payment.id; by = $payment.reviewed_by; reason = $Reason }
    Write-PwxLog -Component 'payments' -Message "Pago rechazado: $($payment.id) para $JobId" -JobId $JobId
    return (Get-PwxPayment -PaymentId $payment.id)
}

function Test-PwxPaymentConfirmed {
    param([Parameter(Mandatory)][string]$JobId)
    $job = Get-PwxJob -JobId $JobId
    if (-not $job) { throw "Trabajo inexistente: $JobId" }
    if (-not (Get-PwxConfig).RequirePaymentBeforeProduction) { return $true }
    $serviceId = Get-PwxQuoteServiceId -Job $job
    $service = Get-PwxService -ServiceId $serviceId
    if ($service -and -not $service.requiresPayment) { return $true }
    if (-not $job.payment_id) { return $false }
    $payment = Get-PwxPayment -PaymentId ([string]$job.payment_id)
    return ($payment -and $payment.status -eq 'APPROVED')
}

function Assert-PwxPaymentConfirmed {
    param([Parameter(Mandatory)][string]$JobId)
    if (-not (Test-PwxPaymentConfirmed -JobId $JobId)) {
        throw "PAYMENT_REQUIRED: el trabajo $JobId requiere un pago aprobado antes de producción"
    }
    return $true
}
