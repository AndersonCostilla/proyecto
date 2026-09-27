Run-PwxTest -Name 'cotizacion calcula volumen complejidad addons y descuento' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap

    $quote = Get-PwxQuote -ServiceId 'excel-service' -Units 3 -Complexity 'advanced' -Addons @('rush') -DiscountPct 5
    Assert-PwxEqual 'excel-service' $quote.service_id
    Assert-PwxEqual 3 $quote.units
    Assert-PwxEqual 2 $quote.extra_units
    Assert-PwxEqual 'advanced' $quote.complexity
    Assert-PwxTrue ($quote.volume_total -gt 0) 'Las unidades extra deben aumentar el valor'
    Assert-PwxTrue ($quote.complexity_amount -gt 0) 'La complejidad avanzada debe aumentar el valor'
    Assert-PwxTrue ($quote.addons_total -gt 0) 'El addon debe aumentar el valor'
    Assert-PwxTrue ($quote.discount_amount -gt 0) 'El descuento permitido debe aplicarse'
    Assert-PwxTrue ($quote.total -gt 0) 'El total debe ser positivo'
    Assert-PwxThrows { Get-PwxQuote -ServiceId 'excel-service' -Complexity 'imposible' } 'Complejidad inexistente'
    Assert-PwxThrows { Get-PwxQuote -ServiceId 'excel-service' -Units 0 } 'Unidades inválidas'
}

Run-PwxTest -Name 'pago manual bloquea produccion hasta comprobante aprobado' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    New-PwxDirectory -Path $ws | Out-Null
    $methodsFile = Join-Path $ws 'payment-methods.test.json'
    @'
{
  "currency": "COP",
  "methods": {
    "nequi": {
      "name": "Nequi de prueba",
      "enabled": true,
      "recipient": "3001234567",
      "instructions": "Paga el valor exacto usando el ID del trabajo.",
      "qr_path": ""
    }
  }
}
'@ | Set-Content -LiteralPath $methodsFile -Encoding UTF8
    $env:PWX_PAYMENT_METHODS_FILE = $methodsFile
    $env:PWX_REQUIRE_PAYMENT_BEFORE_PRODUCTION = 'true'
    try {
        Invoke-PwxBootstrap
        $client = New-PwxClient -Name 'Cliente Pago' -Contact 'pago@mail.com'
        $job = New-PwxJob -ClientId $client.id -Service 'excel-service' -Description 'Planilla comercial'
        $json = '{
          "service": "excel-service",
          "objective": "normalizar planilla comercial",
          "input_files": ["origen.xlsx"],
          "required_output": ["*.xlsx"],
          "constraints": [],
          "missing_information": [],
          "acceptance_criteria": ["archivo xlsx valido"]
        }'
        $requirements = Invoke-PwxRequirementsAgent -JobId $job.id -Request 'Normalizar una planilla comercial' -ForceJson $json
        Assert-PwxTrue $requirements.ok
        Assert-PwxEqual 'READY_FOR_PRODUCTION' $requirements.state

        $beforePayment = Invoke-PwxProductionAgent -JobId $job.id
        Assert-PwxTrue (-not $beforePayment.ok) 'No debe producir sin pago'
        Assert-PwxEqual 'PAYMENT_REQUIRED' $beforePayment.error

        $payment = New-PwxPaymentRequest -JobId $job.id -Method 'nequi' -Units 2 -Complexity 'standard'
        Assert-PwxEqual 'REQUESTED' $payment.status
        Assert-PwxTrue (-not (Test-PwxPaymentConfirmed -JobId $job.id)) 'El pago solicitado aún no está aprobado'
        Assert-PwxThrows { Approve-PwxPayment -JobId $job.id -By 'revisor' } 'No se aprueba sin comprobante'

        $proof = Join-Path $ws 'comprobante.png'
        [System.IO.File]::WriteAllBytes($proof, [byte[]](1,2,3,4))
        $submitted = Submit-PwxPaymentProof -JobId $job.id -Path $proof -Reference 'NEQUI-TEST-1'
        Assert-PwxEqual 'PROOF_SUBMITTED' $submitted.status
        Assert-PwxNotNull $submitted.proof.sha256
        Assert-PwxTrue ($submitted.proof.path -like 'proof*') 'El comprobante debe copiarse dentro del pago'

        $approved = Approve-PwxPayment -JobId $job.id -By 'revisor'
        Assert-PwxEqual 'APPROVED' $approved.status
        Assert-PwxEqual 'revisor' $approved.reviewed_by
        Assert-PwxTrue (Test-PwxPaymentConfirmed -JobId $job.id) 'El pago aprobado habilita producción'
    }
    finally {
        $env:PWX_PAYMENT_METHODS_FILE = $null
        $env:PWX_REQUIRE_PAYMENT_BEFORE_PRODUCTION = 'false'
    }
}

Run-PwxTest -Name 'solicitud de pago exige requisitos y método configurado' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    $env:PWX_PAYMENT_METHODS_FILE = $null
    Invoke-PwxBootstrap
    $client = New-PwxClient -Name 'Cliente Sin Configuración'
    $job = New-PwxJob -ClientId $client.id -Service 'excel-service'
    Assert-PwxThrows { New-PwxPaymentRequest -JobId $job.id -Method 'nequi' } 'Debe exigir requisitos antes de cobrar'
}
