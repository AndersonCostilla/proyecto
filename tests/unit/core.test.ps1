Run-PwxTest -Name 'config carga workspace y modelo' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    $cfg = Get-PwxConfig
    Assert-PwxTrue ($cfg.WorkspacePath -eq $ws) 'Workspace debe respetar env PWX_WORKSPACE'
    Assert-PwxNotNull $cfg.Model 'Modelo requerido'
    Assert-PwxTrue ($cfg.RequestTimeoutSec -gt 0) 'Timeout debe ser positivo'
}

Run-PwxTest -Name 'crear cliente crea archivo' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    $client = New-PwxClient -Name 'Cliente A' -Contact 'a@mail.com'
    Assert-PwxTrue ($client.id -like 'C-*') 'ID de cliente'
    $file = Join-Path $ws ('clients\' + $client.id + '\client.json')
    Assert-PwxTrue (Test-Path -LiteralPath $file) 'client.json debe existir'
    $loaded = Get-PwxClient -ClientId $client.id
    Assert-PwxEqual 'Cliente A' $loaded.name
}

Run-PwxTest -Name 'crear trabajo con servicio desconocido falla' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    $client = New-PwxClient -Name 'Cliente B'
    Assert-PwxThrows { New-PwxJob -ClientId $client.id -Service 'no-existe' }
}

Run-PwxTest -Name 'transiciones de estado validas e invalidas' -File 'unit' -Body {
    Invoke-PwxBootstrap
    Assert-PwxTrue (Test-PwxTransition -From 'NEW' -To 'REQUIREMENTS') 'NEW->REQUIREMENTS'
    Assert-PwxTrue (Test-PwxTransition -From 'REQUIREMENTS' -To 'READY_FOR_PRODUCTION') 'REQUIREMENTS->READY_FOR_PRODUCTION'
    Assert-PwxTrue (Test-PwxTransition -From 'IN_PROGRESS' -To 'QA') 'IN_PROGRESS->QA'
    Assert-PwxTrue (Test-PwxTransition -From 'QA' -To 'REWORK') 'QA->REWORK'
    Assert-PwxTrue (Test-PwxTransition -From 'QA' -To 'READY_FOR_DELIVERY') 'QA->READY_FOR_DELIVERY'
    Assert-PwxTrue (-not (Test-PwxTransition -From 'NEW' -To 'COMPLETED')) 'NEW->COMPLETED directo'
    Assert-PwxTrue (-not (Test-PwxTransition -From 'READY_FOR_DELIVERY' -To 'COMPLETED')) 'READY_FOR_DELIVERY->COMPLETED'
}

Run-PwxTest -Name 'path traversal bloqueado' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    Assert-PwxThrows { Assert-PwxSafeWorkspacePath -WorkspacePath $ws -Path 'C:\Windows\system32' } 'Ruta externa'
    Assert-PwxThrows { Assert-PwxSafeWorkspacePath -WorkspacePath $ws -Path '..\..\secret' } 'Traversal relativo'
    $ok = Assert-PwxSafeWorkspacePath -WorkspacePath $ws -Path (Join-Path $ws 'foo.txt')
    Assert-PwxTrue ($null -ne $ok)
    Assert-PwxThrows { Assert-PwxSafeFileName -Name 'a\b.txt' }
    Assert-PwxTrue ((Assert-PwxSafeFileName -Name 'archivo ok.xlsx') -eq 'archivo ok.xlsx')
}

Run-PwxTest -Name 'precios deterministas y descuentos' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    $p1 = Get-PwxPrice -ServiceId 'excel-service'
    $p2 = Get-PwxPrice -ServiceId 'excel-service'
    Assert-PwxEqual $p1.subtotal $p2.subtotal 'Precio debe ser determinista'
    Assert-PwxTrue ($p1.base_price -gt 0) 'Base price'
    $withAddon = Get-PwxPrice -ServiceId 'excel-service' -Addons @('rush')
    Assert-PwxTrue ($withAddon.subtotal -gt $p1.subtotal) 'Addon incrementa precio'
    Assert-PwxThrows { Get-PwxPrice -ServiceId 'excel-service' -Addons @('no-existe') } 'Addon desconocido'
    Assert-PwxTrue (Test-PwxDiscountAllowed -ServiceId 'excel-service' -DiscountPct 5) 'Descuento permitido'
    Assert-PwxTrue (-not (Test-PwxDiscountAllowed -ServiceId 'excel-service' -DiscountPct 50)) 'Descuento prohibido'
}

Run-PwxTest -Name 'outbox requiere aprobacion para enviar' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    $msg = New-PwxOutboxItem -Recipient 'c@mail.com' -Subject 'Hola' -Body 'Test'
    Assert-PwxEqual 'DRAFT' $msg.status
    Assert-PwxThrows { Set-PwxOutboxStatus -Id $msg.id -Status 'SENT' } 'No puede enviarse sin aprobar'
    $approved = Set-PwxOutboxStatus -Id $msg.id -Status 'APPROVED' -By 'operador'
    Assert-PwxEqual 'APPROVED' $approved.status
    Assert-PwxEqual 'operador' $approved.approved_by
    $sent = Set-PwxOutboxStatus -Id $msg.id -Status 'SENT'
    Assert-PwxEqual 'SENT' $sent.status
    Assert-PwxNotNull $sent.sent_at
}

Run-PwxTest -Name 'trabajo inexistente devuelve null' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    $job = Get-PwxJob -JobId 'J-9999'
    Assert-PwxNull $job
}

Run-PwxTest -Name 'detectar JSON invalido del modelo' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    $client = New-PwxClient -Name 'Cliente C'
    $job = New-PwxJob -ClientId $client.id -Service 'simulate-service'
    Assert-PwxEqual 'NEW' $job.state
    $result = Invoke-PwxRequirementsAgent -JobId $job.id -Request 'test' -ForceJson '{esto no es json'
    Assert-PwxTrue (-not $result.ok) 'Debe fallar'
    Assert-PwxEqual 'MODEL_INVALID_RESPONSE' $result.code
}

Run-PwxTest -Name 'JSON valido se acepta y extrae requisitos' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    $client = New-PwxClient -Name 'Cliente D'
    $job = New-PwxJob -ClientId $client.id -Service 'simulate-service'
    $json = '{
        "service": "excel-service",
        "objective": "organizar presupuesto",
        "input_files": ["presupuesto.xlsx"],
        "required_output": ["*.xlsx"],
        "constraints": ["usar pesos"],
        "missing_information": [],
        "acceptance_criteria": ["hoja con totales"]
    }'
    $result = Invoke-PwxRequirementsAgent -JobId $job.id -Request 'test' -ForceJson $json
    Assert-PwxTrue $result.ok 'Debe ser ok'
    Assert-PwxEqual 'excel-service' $result.spec.service
    $after = Get-PwxJob -JobId $job.id
    Assert-PwxNotNull $after.requirements
}

Run-PwxTest -Name 'flujo completo requiere QA antes de delivery' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    $client = New-PwxClient -Name 'Demo'
    $job = New-PwxJob -ClientId $client.id -Service 'simulate-service'
    $json = '{
        "service": "simulate-service",
        "objective": "sim",
        "input_files": [],
        "required_output": ["resultado.txt"],
        "constraints": [],
        "missing_information": [],
        "acceptance_criteria": ["archivo existe"]
    }'
    Invoke-PwxRequirementsAgent -JobId $job.id -Request 'sim' -ForceJson $json | Out-Null
    Assert-PwxThrows { New-PwxDelivery -JobId $job.id } 'No debe empaquetar sin QA'
    $result = Invoke-PwxProductionAgent -JobId $job.id
    Assert-PwxTrue $result.ok -Message 'Produccion simulada debe ser ok'
    $jobAfter = Get-PwxJob -JobId $job.id
    Assert-PwxEqual 'READY_FOR_DELIVERY' $jobAfter.state
    $delivery = New-PwxDelivery -JobId $job.id
    Assert-PwxNotNull $delivery
    Approve-PwxDelivery -JobId $job.id -By 'test'
    $final = Get-PwxJob -JobId $job.id
    Assert-PwxEqual 'DELIVERED' $final.state
}