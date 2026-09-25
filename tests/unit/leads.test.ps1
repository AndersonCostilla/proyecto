Run-PwxTest -Name 'crear lead, guardar y cargar con normalizacion' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    $lead = New-PwxLead -Name 'Ana Torres' -Company 'Torres SAS' -Email '  ANA@Torres.com ' -Phone '+57 (300) 123-4567' -City 'Bogota' -Department 'Cundinamarca' -Website 'https://www.torres.com/'
    Assert-PwxTrue ($lead.id -like 'L-*') 'ID de lead'
    Assert-PwxEqual 'ana@torres.com' $lead.email 'Email normalizado a lowercase'
    Assert-PwxEqual '573001234567' $lead.phone 'Telefono solo digitos'
    Assert-PwxEqual 'torres.com' $lead.domain 'Dominio desde website'
    $file = Join-Path $ws ('leads\' + $lead.id + '.json')
    Assert-PwxTrue (Test-Path -LiteralPath $file) 'lead.json debe existir'
    $loaded = Get-PwxLead -LeadId $lead.id
    Assert-PwxEqual $lead.email $loaded.email
    Assert-PwxEqual 'NEW' $loaded.status
}

Run-PwxTest -Name 'dedupe por email/phone/domain marca duplicados' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    $a = New-PwxLead -Name 'A' -Email 'dup@corp.com' -Phone '3001112233' -Website 'corp.com'
    $b = New-PwxLead -Name 'B' -Email 'dup@corp.com'
    $c = New-PwxLead -Name 'C' -Phone '3001112233'
    $d = New-PwxLead -Name 'D' -Website 'corp.com'
    $e = New-PwxLead -Name 'E' -Email 'otro@mail.com'
    $dups = Invoke-PwxLeadsDedupe
    Assert-PwxEqual 3 $dups.Count 'Deben marcarse B,C,D como duplicados'
    $canonical = Get-PwxLead -LeadId $a.id
    Assert-PwxNull $canonical.duplicate_of 'Canonico no es duplicado'
    foreach ($dupId in $dups) {
        $dup = Get-PwxLead -LeadId $dupId
        Assert-PwxEqual $a.id $dup.duplicate_of "Dup $dupId apunta al canonico $($a.id)"
    }
    $e2 = Get-PwxLead -LeadId $e.id
    Assert-PwxNull $e2.duplicate_of 'Lead sin claves compartidas no es duplicado'
}

Run-PwxTest -Name 'score determinista estable y pesado' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    $r=New-PwxLead -Name 'R' -Company 'RC' -Email 'r@rc.com' -Phone '3119998877' -Website 'rc.com' -City 'Cali'
    $s1 = Get-PwxLeadScore -Lead $r
    $s2 = Get-PwxLeadScore -Lead $r
    Assert-PwxEqual $s1 $s2 'Score debe ser estable entre llamadas'
    Assert-PwxEqual 90 $s1 'name10+company15+email25+phone20+website10+city10 = 90'
    $partial = New-PwxLead -Name 'Solo'
    Assert-PwxEqual 10 (Get-PwxLeadScore -Lead $partial) 'Solo nombre = 10'
    $empty = New-PwxLead
    Assert-PwxEqual 0 (Get-PwxLeadScore -Lead $empty) 'Vacio = 0'
}

Run-PwxTest -Name 'leads duplicados reciben score 0' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    $a = New-PwxLead -Name 'A' -Email 'x@x.com' -Company 'XC' -Phone '3005556677'
    $b = New-PwxLead -Name 'B' -Email 'x@x.com'
    Invoke-PwxLeadsDedupe
    Invoke-PwxLeadsScore | Out-Null
    $can = Get-PwxLead -LeadId $a.id
    $dup = Get-PwxLead -LeadId $b.id
    Assert-PwxTrue ($can.score -gt 0) 'Canonico conserva score'
    Assert-PwxEqual 0 $dup.score 'Duplicado score 0'
}

Run-PwxTest -Name 'lead:draft crea outbox DRAFT (nunca SENT)' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    $lead = New-PwxLead -Name 'Juan' -Company 'JuanCo' -Email 'juan@juancp.com'
    $draft = New-PwxLeadDraft -LeadId $lead.id -Channel 'email'
    Assert-PwxEqual 'DRAFT' $draft.status 'Draft debe estar en DRAFT'
    Assert-PwxEqual $lead.email $draft.recipient 'Destinatario es el email del lead'
    Assert-PwxEqual $lead.id $draft.lead_id 'Outbox referencia al lead'
    Assert-PwxTrue ($draft.subject -ne '') 'Subject del borrador'
    Assert-PwxTrue ($draft.body -ne '') 'Body del borrador'
    $after = Get-PwxLead -LeadId $lead.id
    Assert-PwxEqual 'DRAFTED' $after.status 'Lead pasa a DRAFTED'
    Assert-PwxEqual $draft.id $after.draft_id 'Lead guarda referencia al draft'
    $all = Get-PwxOutboxItems -Status 'SENT'
    Assert-PwxEqual 0 $all.Count 'No debe haber mensajes SENT'
    Assert-PwxNull $draft.sent_at 'No debe haber sent_at'
}

Run-PwxTest -Name 'hotfix: draft email y whatsapp usan recipient correcto por canal' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    $lead = New-PwxLead -Name 'Ana' -Company 'AnaCo' -Email 'ana@anaco.co' -Phone '+57 (301) 555 8899'
    $emailDraft = New-PwxLeadDraft -LeadId $lead.id -Channel 'email'
    Assert-PwxEqual 'email' $emailDraft.channel 'Canal email'
    Assert-PwxEqual $lead.email $emailDraft.recipient 'email -> recipient = email del lead'
    $waDraft = New-PwxLeadDraft -LeadId $lead.id -Channel 'whatsapp'
    Assert-PwxEqual 'whatsapp' $waDraft.channel 'Canal whatsapp'
    Assert-PwxEqual '573015558899' $waDraft.recipient 'whatsapp -> recipient = phone (solo digitos)'
    Assert-PwxTrue ($waDraft.recipient -ne $lead.email) 'whatsapp recipient NO es el email'
    Assert-PwxEqual $lead.id $waDraft.lead_id 'lead_id preservado en whatsapp'
    Assert-PwxEqual 'DRAFT' $waDraft.status 'Whatsapp sigue siendo DRAFT'
}

Run-PwxTest -Name 'hotfix: draft whatsapp sin phone falla y no crea outbox' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    $lead = New-PwxLead -Name 'SinPhone' -Email 'sinphone@no.com'
    $before = @(Get-PwxOutboxItems).Count
    Assert-PwxThrows { New-PwxLeadDraft -LeadId $lead.id -Channel 'whatsapp' } 'Debe fallar sin phone para whatsapp'
    $after = @(Get-PwxOutboxItems).Count
    Assert-PwxEqual $before $after 'NO se debe crear ningun outbox item'
    $still = Get-PwxLead -LeadId $lead.id
    Assert-PwxEqual 'NEW' $still.status 'Lead no debe cambiar de estado'
    Assert-PwxNull $still.draft_id 'Lead no debe tener draft_id'
}

Run-PwxTest -Name 'hotfix: draft email sin email falla y no crea outbox' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    $lead = New-PwxLead -Name 'SinEmail' -Phone '3005551122'
    $before = @(Get-PwxOutboxItems).Count
    Assert-PwxThrows { New-PwxLeadDraft -LeadId $lead.id -Channel 'email' } 'Debe fallar sin email para canal email'
    $after = @(Get-PwxOutboxItems).Count
    Assert-PwxEqual $before $after 'NO se debe crear ningun outbox item'
}

Run-PwxTest -Name 'hotfix: body usa MindSprit/Anderson y no a lead.company como remitente' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    $lead = New-PwxLead -Name 'Carla' -Company 'Constrular SAS' -Email 'carla@constrular.com.co' -Phone '3004445566'
    $emailDraft = New-PwxLeadDraft -LeadId $lead.id -Channel 'email'
    Assert-PwxTrue ($emailDraft.body.Contains('MindSprit')) 'email body menciona la marca MindSprit'
    Assert-PwxTrue ($emailDraft.body.Contains('Anderson')) 'email body firmado por Anderson'
    Assert-PwxTrue ($emailDraft.subject.Contains('MindSprit')) 'subject menciona la marca'
    Assert-PwxTrue (-not $emailDraft.body.Contains('desde Constrular SAS')) 'email body no usa lead.company como remitente'
    Assert-PwxTrue ($emailDraft.body.Contains('Constrular SAS')) 'email body si puede citar a Constrular solo como contexto'
    $waDraft = New-PwxLeadDraft -LeadId $lead.id -Channel 'whatsapp'
    Assert-PwxTrue ($waDraft.body.Contains('MindSprit')) 'whatsapp body menciona la marca'
    Assert-PwxTrue (-not $waDraft.body.Contains('Soy de Constrular SAS')) 'whatsapp no dice "soy de <empresa del lead>"'
    Assert-PwxTrue (-not $waDraft.body.Contains('desde Constrular SAS')) 'whatsapp no usa lead.company como remitente'
    $all = Get-PwxOutboxItems -Status 'SENT'
    Assert-PwxEqual 0 $all.Count 'Nada enviado'
}

Run-PwxTest -Name 'convertir lead a cliente vincula lead->client' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    $lead = New-PwxLead -Name 'Pepe' -Company 'Pepe LTDA' -Email 'pepe@pepe.com'
    $client = Convert-PwxLeadToClient -LeadId $lead.id
    Assert-PwxTrue ($client.id -like 'C-*') 'Se crea cliente'
    Assert-PwxEqual 'Pepe LTDA' $client.name 'Cliente usa company del lead'
    $after = Get-PwxLead -LeadId $lead.id
    Assert-PwxEqual 'CONVERTED' $after.status 'Lead pasa a CONVERTED'
    Assert-PwxEqual $client.id $after.client_id 'Vinculo lead->client'
}

Run-PwxTest -Name 'no se puede generar draft de lead duplicado' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    $a = New-PwxLead -Name 'A' -Email 'dup@x.com'
    $b = New-PwxLead -Name 'B' -Email 'dup@x.com'
    Invoke-PwxLeadsDedupe | Out-Null
    Assert-PwxThrows { New-PwxLeadDraft -LeadId $b.id -Channel 'email' } 'No debe generar draft de duplicado'
    Assert-PwxThrows { Convert-PwxLeadToClient -LeadId $b.id } 'No debe convertir duplicado'
}