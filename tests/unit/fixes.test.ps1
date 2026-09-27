$global:PwxSimSpec = @{
    service             = 'simulate-service'
    objective           = 'sim'
    input_files         = @()
    required_output     = @('resultado.txt')
    constraints         = @()
    missing_information = @()
    acceptance_criteria = @()
}

Run-PwxTest -Name 'T3: requisitos repetidos son idempotentes' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    $client = New-PwxClient -Name 'Cliente Idem'
    $job = New-PwxJob -ClientId $client.id -Service 'simulate-service'
    $res1 = Invoke-PwxRequirementsAgent -JobId $job.id -Request 'sim' -ForceJson ($global:PwxSimSpec | ConvertTo-Json -Depth 5)
    Assert-PwxTrue $res1.ok
    Assert-PwxEqual 'READY_FOR_PRODUCTION' (Get-PwxJob -JobId $job.id).state
    $res2 = Invoke-PwxRequirementsAgent -JobId $job.id -Request 'sim v2' -ForceJson ($global:PwxSimSpec | ConvertTo-Json -Depth 5)
    Assert-PwxTrue $res2.ok 'Segunda ejecucion no debe fallar'
    $after = Get-PwxJob -JobId $job.id
    Assert-PwxEqual 'READY_FOR_PRODUCTION' $after.state 'Estado debe mantenerse coherente'
}

Run-PwxTest -Name 'T4: aprobacion de delivery repetida es no-op' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    $client = New-PwxClient -Name 'Cliente Idem2'
    $job = New-PwxJob -ClientId $client.id -Service 'simulate-service'
    Invoke-PwxRequirementsAgent -JobId $job.id -Request 'sim' -ForceJson ($global:PwxSimSpec | ConvertTo-Json -Depth 5) | Out-Null
    Invoke-PwxProductionAgent -JobId $job.id | Out-Null
    New-PwxDelivery -JobId $job.id | Out-Null
    Approve-PwxDelivery -JobId $job.id -By 'tester'
    Assert-PwxEqual 'DELIVERED' (Get-PwxJob -JobId $job.id).state
    Approve-PwxDelivery -JobId $job.id -By 'tester' | Out-Null
    Assert-PwxEqual 'DELIVERED' (Get-PwxJob -JobId $job.id).state 'Segunda aprobacion no debe romper el flujo'
}

Run-PwxTest -Name 'T5: produccion sobre BLOCKED devuelve error sin corromper estado' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    $client = New-PwxClient -Name 'Cliente BlockProd'
    $job = New-PwxJob -ClientId $client.id -Service 'simulate-service'
    Invoke-PwxRequirementsAgent -JobId $job.id -Request 'x' -ForceJson 'not json' | Out-Null
    Assert-PwxEqual 'BLOCKED' (Get-PwxJob -JobId $job.id).state
    $threw = $false
    try { Invoke-PwxProductionAgent -JobId $job.id } catch { $threw = $true }
    Assert-PwxTrue $threw 'Producir sobre BLOCKED debe lanzar JOB_BLOCKED_REQUIRES_REVIEW'
    Assert-PwxEqual 'BLOCKED' (Get-PwxJob -JobId $job.id).state 'Estado debe permanecer BLOCKED'
}

Run-PwxTest -Name 'T6: descuento fuera de politica rechazado' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    Assert-PwxThrows { Get-PwxDiscountAmount -ServiceId 'excel-service' -DiscountPct 50 }
    Assert-PwxThrows { Get-PwxDiscountAmount -ServiceId 'excel-service' -DiscountPct -5 }
    $ok = Get-PwxDiscountAmount -ServiceId 'excel-service' -DiscountPct 5
    Assert-PwxTrue ($ok.total -gt 0) 'Descuento permitido debe devolver total positivo'
    Assert-PwxEqual (($ok.subtotal * 0.05) -as [double]) $ok.discount_amount -Message 'Monto de descuento correcto'
}

Run-PwxTest -Name 'T7: servicio inexistente queda en BLOCKED (sin fallback silencioso)' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    $client = New-PwxClient -Name 'Cliente Inv'
    $job = New-PwxJob -ClientId $client.id -Service 'simulate-service'
    $spec = $global:PwxSimSpec.Clone()
    $spec.service = 'servicio-inventado'
    $res = Invoke-PwxRequirementsAgent -JobId $job.id -Request 'x' -ForceJson ($spec | ConvertTo-Json -Depth 5)
    Assert-PwxTrue (-not $res.ok) 'Debe fallar'
    Assert-PwxEqual 'SERVICE_NOT_IN_CATALOG' $res.code
    Assert-PwxEqual 'BLOCKED' $res.state
    Assert-PwxEqual 'BLOCKED' (Get-PwxJob -JobId $job.id).state
}

Run-PwxTest -Name 'T8: estado invalido al guardar es rechazado' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    $client = New-PwxClient -Name 'Cliente State'
    $job = New-PwxJob -ClientId $client.id -Service 'simulate-service'
    Assert-PwxEqual 'NEW' $job.state
    $t1 = Get-PwxJob -JobId $job.id
    $t1.state = 'COMPLETELY_INVALID'
    Assert-PwxThrows { Save-PwxJob -Job $t1 } 'Estado inexistente debe rechazarse'
    $t2 = Get-PwxJob -JobId $job.id
    $t2.state = 'COMPLETED'
    Assert-PwxThrows { Save-PwxJob -Job $t2 } 'NEW->COMPLETED ilegal debe rechazarse'
    $t3 = Get-PwxJob -JobId $job.id
    Save-PwxJob -Job $t3 | Out-Null
    Assert-PwxEqual 'NEW' (Get-PwxJob -JobId $job.id).state 'Guardado sin cambio de estado debe seguir funcionando'
}

Run-PwxTest -Name 'T9: precio persistido al crear el trabajo' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    $client = New-PwxClient -Name 'Cliente Price'
    $job = New-PwxJob -ClientId $client.id -Service 'excel-service'
    Assert-PwxNotNull $job.price 'El precio no debe ser null para servicio conocido'
    Assert-PwxEqual 'excel-service' $job.price.service_id
    Assert-PwxEqual 64000.0 ([double]$job.price.base_price)
    Assert-PwxEqual 'COP' $job.price.currency
    $calc = Get-PwxPrice -ServiceId 'excel-service'
    Assert-PwxEqual $calc.subtotal ([double]$job.price.subtotal)
    Assert-PwxEqual 'catalog' $job.price.source 'El precio debe venir del catalogo, no del LLM'
}

Run-PwxTest -Name 'T12: versionado preserva la version anterior tras regenerar' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    $client = New-PwxClient -Name 'Cliente Vers'
    $job = New-PwxJob -ClientId $client.id -Service 'simulate-service'
    Invoke-PwxRequirementsAgent -JobId $job.id -Request 'sim' -ForceJson ($global:PwxSimSpec | ConvertTo-Json -Depth 5) | Out-Null
    $prod1 = Invoke-PwxProductionAgent -JobId $job.id
    Assert-PwxTrue $prod1.ok
    $after1 = Get-PwxJob -JobId $job.id
    $v1 = [int]$after1.output_version
    Assert-PwxTrue ($v1 -ge 1) 'Primera produccion debe generar version >= 1'
    Set-PwxJobState -JobId $job.id -To 'BLOCKED' -Reason 'revision' | Out-Null
    Set-PwxJobState -JobId $job.id -To 'REQUIREMENTS' -Reason 'revision' | Out-Null
    Invoke-PwxRequirementsAgent -JobId $job.id -Request 'sim' -ForceJson ($global:PwxSimSpec | ConvertTo-Json -Depth 5) | Out-Null
    $prod2 = Invoke-PwxProductionAgent -JobId $job.id
    Assert-PwxTrue $prod2.ok
    $after2 = Get-PwxJob -JobId $job.id
    Assert-PwxTrue ([int]$after2.output_version -gt $v1) 'Version debe incrementarse al regenerar'
    Assert-PwxTrue ($after2.versions.Count -ge 1) 'Debe existir snapshot de la version anterior'
    $found = Find-PwxJob -JobId $job.id
    $archived = Join-Path $found.JobDir ('versions\v' + $v1)
    Assert-PwxTrue (Test-Path -LiteralPath (Join-Path $archived 'resultado.txt')) 'Version anterior preservada en versions/v1'
    $delivery = New-PwxDelivery -JobId $job.id
    Assert-PwxEqual ([int]$after2.output_version) ([int]$delivery.output_version) 'Manifest debe indicar la version entregada'
}