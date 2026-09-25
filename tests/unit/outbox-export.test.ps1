Run-PwxTest -Name 'export CSV valido con email y whatsapp' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    $lead = New-PwxLead -Name 'Ana' -Company 'AnaCo' -Email 'ana@anaco.co' -Phone '+57 (300) 555 8899'
    $e = New-PwxLeadDraft -LeadId $lead.id -Channel 'email'
    $w = New-PwxLeadDraft -LeadId $lead.id -Channel 'whatsapp'
    $res = Export-PwxOutboxCsv
    Assert-PwxEqual 2 $res.exported 'Se exportan 2 borradores'
    Assert-PwxEqual 0 $res.omitted.count 'No hay omitidos'
    Assert-PwxTrue (Test-Path -LiteralPath $res.path) 'El archivo CSV existe'
    Assert-PwxTrue ($res.path -like '*exports\outbox-drafts-*.csv') 'Nombre por defecto bajo workspace/exports'
    $rows = @(Import-Csv -LiteralPath $res.path -Encoding UTF8)
    Assert-PwxEqual 2 $rows.Count 'Dos filas'
    Assert-PwxEqual $e.id $rows[0].id 'Primer id'
    Assert-PwxEqual 'email' $rows[0].channel 'Canal email'
    Assert-PwxEqual $e.recipient $rows[0].recipient 'Recipient email'
    Assert-PwxEqual $w.id $rows[1].id 'Segundo id'
    Assert-PwxEqual 'whatsapp' $rows[1].channel 'Canal whatsapp'
    Assert-PwxEqual $w.recipient $rows[1].recipient 'Recipient whatsapp (digitos)'
    Assert-PwxEqual 'DRAFT' $rows[0].status 'Status DRAFT'
    Assert-PwxEqual $e.lead_id $rows[0].lead_id 'lead_id preservado'
    Assert-PwxTrue ($rows[0].created_at -ne '') 'created_at presente'
}

Run-PwxTest -Name 'export omite borradores sin destinatario o incompatibles sin modificar' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    $sinDest = New-PwxOutboxItem -Type 'message' -Channel 'email' -Recipient '' -Subject 'x' -Body 'y'
    $emailInvalido = New-PwxOutboxItem -Type 'message' -Channel 'email' -Recipient '12345' -Subject 'x' -Body 'y'
    $waNoDigitos = New-PwxOutboxItem -Type 'message' -Channel 'whatsapp' -Recipient 'abc@mail.com' -Subject 'x' -Body 'y'
    $good = New-PwxOutboxItem -Type 'message' -Channel 'email' -Recipient 'ok@mail.com' -Subject 'S' -Body 'B'
    $res = Export-PwxOutboxCsv
    Assert-PwxEqual 1 $res.exported 'Solo el valido se exporta'
    Assert-PwxEqual 3 $res.omitted.count 'Tres omitidos'
    $om = @($res.omitted.items)
    Assert-PwxTrue (($om.id) -contains $sinDest.id) 'Sin destinatario omitido'
    Assert-PwxTrue (($om.id) -contains $emailInvalido.id) 'Email invalido omitido'
    Assert-PwxTrue (($om.id) -contains $waNoDigitos.id) 'Whatsapp sin digitos omitido'
    $r1 = @($om | Where-Object { $_.id -eq $sinDest.id } | Select-Object -First 1).reason
    $r2 = @($om | Where-Object { $_.id -eq $emailInvalido.id } | Select-Object -First 1).reason
    $r3 = @($om | Where-Object { $_.id -eq $waNoDigitos.id } | Select-Object -First 1).reason
    Assert-PwxEqual 'sin destinatario' $r1 'Motivo sin destinatario'
    Assert-PwxEqual 'canal email requiere un email valido' $r2 'Motivo email invalido'
    Assert-PwxEqual 'canal whatsapp requiere telefono de solo digitos' $r3 'Motivo whatsapp invalido'
    $rows = @(Import-Csv -LiteralPath $res.path -Encoding UTF8)
    Assert-PwxEqual 1 $rows.Count 'Una sola fila en archivo'
    Assert-PwxEqual $good.id $rows[0].id 'Solo el bueno en archivo'
    $reloaded = Get-PwxOutboxItem -Id $sinDest.id
    Assert-PwxEqual 'DRAFT' $reloaded.status 'Omitido sigue DRAFT'
    Assert-PwxNull $reloaded.sent_at 'Omitido sin sent_at'
}

Run-PwxTest -Name 'export preserva comas comillas y saltos de linea en body' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    $body = "Hola,`nesto tiene, comas `"cita`"`ny un salto`nfin."
    $item = New-PwxOutboxItem -Type 'message' -Channel 'email' -Recipient 'ok@mail.com' -Subject 'suj,eto' -Body $body
    $res = Export-PwxOutboxCsv -Path 'con-comas.csv'
    Assert-PwxTrue ($res.path -like '*exports\con-comas.csv') 'Path relativo dentro de exports'
    $rows = @(Import-Csv -LiteralPath $res.path -Encoding UTF8)
    Assert-PwxEqual 1 $rows.Count 'Una fila'
    Assert-PwxEqual $item.recipient $rows[0].recipient 'Recipient'
    Assert-PwxEqual $item.subject $rows[0].subject 'Subject con coma'
    Assert-PwxEqual $item.body $rows[0].body 'Body con comas/saltos/citas intacto'
}

Run-PwxTest -Name 'export protege celdas contra formula injection' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    $subjects = @('=CMD', '+cmd()', '-cmd', '@cmd', ' =sum(A1)', "`n@indirect()")
    foreach ($s in $subjects) {
        $m = New-PwxOutboxItem -Type 'message' -Channel 'email' -Recipient 'ok@mail.com' -Subject $s -Body 'texto normal'
    }
    $res = Export-PwxOutboxCsv -Path 'formulas.csv'
    Assert-PwxEqual 6 $res.exported 'Seis exportados con proteccion'
    $rows = @(Import-Csv -LiteralPath $res.path -Encoding UTF8)
    Assert-PwxEqual 6 $rows.Count 'Seis filas'
    foreach ($s in $subjects) {
        $expected = "'" + $s
        $found = @($rows | Where-Object { $_.subject -eq $expected } | Select-Object -First 1)
        Assert-PwxEqual 1 $found.Count "Celda protegida con apostrofo: ($s)"
    }
    $raw = [System.IO.File]::ReadAllText($res.path, [System.Text.Encoding]::UTF8)
    foreach ($s in $subjects) {
        $trimmed = $s.TrimStart(' ', "`t", "`r", "`n")
        Assert-PwxTrue (-not $raw.Contains(',' + $trimmed)) "Sin formula cruda en celda: ($s)"
    }
}

Run-PwxTest -Name 'export no cambia status ni sent_at de ningun mensaje' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    $lead = New-PwxLead -Name 'Ana' -Email 'ana@anaco.co' -Phone '3005558899'
    $e = New-PwxLeadDraft -LeadId $lead.id -Channel 'email'
    $w = New-PwxLeadDraft -LeadId $lead.id -Channel 'whatsapp'
    $bad = New-PwxOutboxItem -Type 'message' -Channel 'email' -Recipient '' -Subject 'x' -Body 'y'
    Export-PwxOutboxCsv | Out-Null
    foreach ($id in @($e.id, $w.id, $bad.id)) {
        $m = Get-PwxOutboxItem -Id $id
        Assert-PwxEqual 'DRAFT' $m.status "Status intacto: $id"
        Assert-PwxNull $m.sent_at "sent_at intacto: $id"
        Assert-PwxNull $m.approved_at "approved_at intacto: $id"
    }
    $sent = Get-PwxOutboxItems -Status 'SENT'
    Assert-PwxEqual 0 $sent.Count 'No hay SENT'
    $approved = Get-PwxOutboxItems -Status 'APPROVED'
    Assert-PwxEqual 0 $approved.Count 'No hay APPROVED'
}

Run-PwxTest -Name 'export no sobrescribe archivos existentes y rechaza rutas inseguras' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    $m = New-PwxOutboxItem -Type 'message' -Channel 'email' -Recipient 'ok@mail.com' -Subject 'S' -Body 'B'
    $r1 = Export-PwxOutboxCsv
    $r2 = Export-PwxOutboxCsv
    Assert-PwxTrue ($r1.path -ne $r2.path) 'No se reusa el mismo archivo'
    Assert-PwxTrue (Test-Path -LiteralPath $r1.path) 'Primer archivo intacto'
    Assert-PwxTrue (Test-Path -LiteralPath $r2.path) 'Segundo archivo creado'
    Assert-PwxThrows { Export-PwxOutboxCsv -Path '..\evil.csv' } 'Traversal rechazado'
    $outside = Join-Path $ws 'outside.csv'
    Assert-PwxThrows { Export-PwxOutboxCsv -Path $outside } 'Ruta absoluta fuera de exports rechazada'
    Assert-PwxThrows { Export-PwxOutboxCsv -Path '..\..\secret\evil.csv' } 'Traversal profundo rechazado'
    Export-PwxOutboxCsv -Path 'existe.csv' | Out-Null
    Assert-PwxThrows { Export-PwxOutboxCsv -Path 'existe.csv' } 'Sobrescritura rechazada'
}
