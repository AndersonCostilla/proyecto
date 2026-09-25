function Get-PwxLeadsDir {
    $cfg = Get-PwxConfig
    $dir = Join-Path $cfg.WorkspacePath 'leads'
    New-PwxDirectory -Path $dir | Out-Null
    return $dir
}

function New-PwxLeadId {
    return (New-PwxSequenceId -Prefix 'L')
}

function Test-PwxValidEmail {
    param([string]$Email)
    if (-not $Email) { return $false }
    $pattern = '^[^\s@]+@[^\s@]+\.[^\s@]+$'
    return ($Email -match $pattern)
}

function Get-PwxDomainFromEmail {
    param([string]$Email)
    if (-not (Test-PwxValidEmail -Email $Email)) { return '' }
    $parts = $Email -split '@'
    if ($parts.Count -eq 2) { return $parts[1].ToLowerInvariant() }
    return ''
}

function Get-PwxDomainFromWebsite {
    param([string]$Website)
    if (-not $Website) { return '' }
    $w = $Website.Trim()
    if ($w -match '^https?://') {
        try {
            $uri = [Uri]$w
            $hostName = $uri.Host
            if ($hostName -match '^www\.') { $hostName = $hostName.Substring(4) }
            return $hostName.ToLowerInvariant()
        } catch {
            return ''
        }
    } else {
        # Try adding scheme
        try {
            $uri = [Uri]("https://$w")
            $hostName = $uri.Host
            if ($hostName -match '^www\.') { $hostName = $hostName.Substring(4) }
            return $hostName.ToLowerInvariant()
        } catch {
            return ''
        }
    }
}

function Normalize-PwxPhone {
    param([string]$Phone)
    if (-not $Phone) { return '' }
    $clean = [System.Text.RegularExpressions.Regex]::Replace($Phone, '[^\d]', '')
    return $clean
}

function Get-PwxLeadFile {
    param([string]$LeadId)
    Assert-PwxSafeFileName -Name $LeadId | Out-Null
    return (Join-Path (Get-PwxLeadsDir) ($LeadId + '.json'))
}

function Get-PwxLead {
    param([string]$LeadId)
    $file = Get-PwxLeadFile -LeadId $LeadId
    if (-not (Test-Path -LiteralPath $file)) { return $null }
    return Get-PwxJsonFile -Path $file
}

function Get-PwxLeads {
    $dir = Get-PwxLeadsDir
    $result = @()
    foreach ($f in (Get-ChildItem -LiteralPath $dir -Filter '*.json' -ErrorAction SilentlyContinue)) {
        $lead = Get-PwxJsonFile -Path $f.FullName
        if ($lead) { $result += $lead }
    }
    return $result
}

function Save-PwxLead {
    param([object]$Lead)
    if (-not $Lead.id) { throw 'Lead sin id' }
    $file = Get-PwxLeadFile -LeadId $Lead.id
    $copy = $Lead.PSObject.Copy()
    $copy.updated_at = Get-PwxTimestamp
    Set-PwxJsonFile -Path $file -Object $copy | Out-Null
    return $copy
}

function New-PwxLead {
    param(
        [string]$Name = '',
        [string]$Company = '',
        [string]$Email = '',
        [string]$Phone = '',
        [string]$City = '',
        [string]$Department = '',
        [string]$Website = '',
        [string]$Source = 'manual',
        [string]$Tags = '',
        [string]$Notes = '',
        [hashtable]$Extra = @{}
    )
    $id = New-PwxLeadId
    $emailNorm = if ($Email) { $Email.Trim().ToLowerInvariant() } else { '' }
    $domainFromEmail = Get-PwxDomainFromEmail -Email $emailNorm
    $domainFromWebsite = Get-PwxDomainFromWebsite -Website $Website
    $domain = if ($domainFromEmail) { $domainFromEmail } else { $domainFromWebsite }
    $phoneNorm = Normalize-PwxPhone -Phone $Phone
    
    $lead = [ordered]@{
        id           = $id
        name         = $Name.Trim()
        company      = $Company.Trim()
        email        = $emailNorm
        phone        = $phoneNorm
        city         = $City.Trim()
        department   = $Department.Trim()
        website      = $Website.Trim()
        domain       = $domain
        source       = $Source
        tags         = $Tags
        notes        = $Notes
        extra        = $Extra
        status       = 'NEW'
        score        = 0
        duplicate_of = $null
        created_at   = Get-PwxTimestamp
        updated_at   = Get-PwxTimestamp
        draft_id     = $null
        client_id    = $null
        job_id       = $null
    }
    Save-PwxLead -Lead $lead | Out-Null
    return $lead
}

function Set-PwxLeadStatus {
    param([string]$LeadId, [string]$Status)
    $lead = Get-PwxLead -LeadId $LeadId
    if (-not $lead) { throw "Lead inexistente: $LeadId" }
    $valid = @('NEW','QUALIFIED','DRAFTED','APPROVED_FOR_CONTACT','CONTACTED','CONVERTED','DISMISSED')
    if ($valid -notcontains $Status) { throw "Estado de lead invalido: $Status" }
    $lead.status = $Status
    Save-PwxLead -Lead $lead | Out-Null
    return $lead
}

function Get-PwxLeadCanonicalKey {
    param([object]$Lead)
    $keys = @()
    if ($Lead.email) { $keys += "email:$($Lead.email)" }
    if ($Lead.phone -and $Lead.phone.Length -gt 5) { $keys += "phone:$($Lead.phone)" }
    if ($Lead.domain) { $keys += "domain:$($Lead.domain)" }
    return $keys
}

function Invoke-PwxLeadsDedupe {
    $leads = @(Get-PwxLeads | Sort-Object { $_.id })
    $canonical = @{}
    $duplicates = @()
    foreach ($lead in $leads) {
        $keys = Get-PwxLeadCanonicalKey -Lead $lead
        $isDuplicate = $false
        foreach ($k in $keys) {
            if ($canonical.ContainsKey($k)) {
                $isDuplicate = $true
                $canonicalId = $canonical[$k]
                if ($canonicalId -ne $lead.duplicate_of) {
                    $lead.duplicate_of = $canonicalId
                    Save-PwxLead -Lead $lead | Out-Null
                }
                break
            }
        }
        if ($isDuplicate) {
            $duplicates += $lead.id
        } else {
            foreach ($k in $keys) {
                if (-not $canonical.ContainsKey($k)) {
                    $canonical[$k] = $lead.id
                }
            }
        }
    }
    return $duplicates
}

function Get-PwxLeadScore {
    param([object]$Lead)
    $score = 0
    if ($Lead.name) { $score += 10 }
    if ($Lead.company) { $score += 15 }
    if ($Lead.email -and (Test-PwxValidEmail -Email $Lead.email)) { $score += 25 }
    if ($Lead.phone -and $Lead.phone.Length -ge 8) { $score += 20 }
    if ($Lead.website -or $Lead.domain) { $score += 10 }
    if ($Lead.city -or $Lead.department) { $score += 10 }
    if ($Lead.duplicate_of) { $score = 0 } # No score for duplicates
    return $score
}

function Invoke-PwxLeadsScore {
    $leads = Get-PwxLeads
    $updated = @()
    foreach ($lead in $leads) {
        $s = Get-PwxLeadScore -Lead $lead
        if ($s -ne $lead.score) {
            $lead.score = $s
            Save-PwxLead -Lead $lead | Out-Null
            $updated += $lead.id
        }
    }
    return $updated
}

function Get-PwxFirstValue {
    param([object[]]$Values)
    foreach ($v in $Values) {
        if ($null -ne $v -and ([string]$v).Trim()) { return ([string]$v).Trim() }
    }
    return ''
}

function Import-PwxLeadsFromCsv {
    param([string]$Path, [string]$Map = $null)
    if (-not (Test-Path -LiteralPath $Path)) { throw "Archivo inexistente: $Path" }
    
    $rows = Import-Csv -LiteralPath $Path -Encoding UTF8
    $imported = @()
    foreach ($r in $rows) {
        $name = Get-PwxFirstValue -Values @($r.Name, $r.Nombre, $r.name, $r.nombre)
        $company = Get-PwxFirstValue -Values @($r.Company, $r.Empresa, $r.company, $r.empresa)
        $email = Get-PwxFirstValue -Values @($r.Email, $r.Correo, $r.email, $r.correo)
        $phone = Get-PwxFirstValue -Values @($r.Phone, $r.Telefono, $r.phone, $r.telefono)
        $city = Get-PwxFirstValue -Values @($r.City, $r.Ciudad, $r.city, $r.ciudad)
        $department = Get-PwxFirstValue -Values @($r.Department, $r.Departamento, $r.department, $r.departamento)
        $website = Get-PwxFirstValue -Values @($r.Website, $r.Web, $r.URL, $r.website, $r.web, $r.url)
        $notes = Get-PwxFirstValue -Values @($r.Notes, $r.Notas, $r.notes, $r.notas)
        
        $lead = New-PwxLead -Name $name -Company $company -Email $email -Phone $phone -City $city -Department $department -Website $website -Source "csv:$([System.IO.Path]::GetFileName($Path))" -Notes $notes
        $imported += $lead
    }
    return $imported
}

function Import-PwxLeadsFromJson {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "Archivo inexistente: $Path" }
    $data = Get-PwxJsonFile -Path $Path
    $imported = @()
    if ($data -is [array]) {
        foreach ($item in $data) {
            $lead = New-PwxLead -Name $item.name -Company $item.company -Email $item.email -Phone $item.phone -City $item.city -Department $item.department -Website $item.website -Source "json:$([System.IO.Path]::GetFileName($Path))" -Notes $item.notes -Tags $item.tags -Extra $item.extra
            $imported += $lead
        }
    } else {
        $lead = New-PwxLead -Name $data.name -Company $data.company -Email $data.email -Phone $data.phone -City $data.city -Department $data.department -Website $data.website -Source "json:$([System.IO.Path]::GetFileName($Path))" -Notes $data.notes -Tags $data.tags -Extra $data.extra
        $imported += $lead
    }
    return $imported
}

function Import-PwxLeadsFromSocrata {
    param(
        [Parameter(Mandatory)][string]$Url,
        [int]$Limit = 200,
        [string]$Map = $null
    )
    try {
        $response = Invoke-RestMethod -Uri $Url -Method Get -UseBasicParsing
    } catch {
        throw "Error consultando Socrata: $($_.Exception.Message)"
    }
    
    $imported = @()
    $count = 0
    if ($response -is [array]) {
        foreach ($item in $response) {
            if ($count -ge $Limit) { break }
            $name = Get-PwxFirstValue -Values @($item.nombre, $item.name, $item.razon_social, $item.razonsocial)
            $company = Get-PwxFirstValue -Values @($item.empresa, $item.company, $item.nombre_empresa)
            $email = Get-PwxFirstValue -Values @($item.correo, $item.email, $item.correo_electronico)
            $phone = Get-PwxFirstValue -Values @($item.telefono, $item.phone, $item.celular)
            $city = Get-PwxFirstValue -Values @($item.ciudad, $item.city, $item.municipio)
            $department = Get-PwxFirstValue -Values @($item.departamento, $item.department)
            $website = Get-PwxFirstValue -Values @($item.web, $item.website, $item.pagina_web)
            $notes = Get-PwxFirstValue -Values @($item.descripcion, $item.notes)
            
            $lead = New-PwxLead -Name $name -Company $company -Email $email -Phone $phone -City $city -Department $department -Website $website -Source "socrata:$Url" -Notes $notes
            $imported += $lead
            $count++
        }
    }
    return $imported
}

function New-PwxLeadDraft {
    param(
        [Parameter(Mandatory)][string]$LeadId,
        [string]$Channel = 'email',
        [string]$Subject = '',
        [string]$Body = ''
    )
    $lead = Get-PwxLead -LeadId $LeadId
    if (-not $lead) { throw "Lead inexistente: $LeadId" }
    if ($lead.duplicate_of) { throw "No se puede generar borrador para lead duplicado: $LeadId" }
    
    # Recipient por canal: email -> lead.email; whatsapp -> lead.phone (solo digitos).
    # Validar ANTES de crear cualquier outbox item.
    $channelLower = $Channel.ToLowerInvariant()
    if ($channelLower -eq 'whatsapp') {
        $recipient = Normalize-PwxPhone -Phone $lead.phone
        if (-not $recipient) {
            throw "El lead $LeadId no tiene telefono para el canal whatsapp; no se creo ningun mensaje en outbox"
        }
    }
    else {
        $recipient = $lead.email
        if (-not $recipient) {
            throw "El lead $LeadId no tiene email para el canal email; no se creo ningun mensaje en outbox"
        }
    }
    
    # If no subject/body provided, use prospecting agent
    if (-not $Subject -or -not $Body) {
        $prospect = Invoke-PwxProspectingDraft -LeadId $LeadId -Channel $channelLower
        if (-not $Subject) { $Subject = $prospect.subject }
        if (-not $Body) { $Body = $prospect.body }
    }
    
    $item = New-PwxOutboxItem -Type 'message' -Channel $channelLower -Recipient $recipient -Subject $Subject -Body $Body -LeadId $LeadId
    $lead.draft_id = $item.id
    $lead.status = 'DRAFTED'
    Save-PwxLead -Lead $lead | Out-Null
    return $item
}

function Convert-PwxLeadToClient {
    param(
        [Parameter(Mandatory)][string]$LeadId,
        [string]$Name = '',
        [string]$Contact = ''
    )
    $lead = Get-PwxLead -LeadId $LeadId
    if (-not $lead) { throw "Lead inexistente: $LeadId" }
    if ($lead.duplicate_of) { throw "No se puede convertir lead duplicado: $LeadId" }
    
    $clientName = if ($Name) { $Name } else { if ($lead.company) { $lead.company } else { $lead.name } }
    $clientContact = if ($Contact) { $Contact } else { if ($lead.email) { $lead.email } else { $lead.phone } }
    
    $client = New-PwxClient -Name $clientName -Contact $clientContact
    $lead.status = 'CONVERTED'
    $lead.client_id = $client.id
    Save-PwxLead -Lead $lead | Out-Null
    return $client
}
