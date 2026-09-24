Run-PwxTest -Name 'E2E: import CSV (5 leads con duplicados) -> dedupe -> draft top2 -> outbox 2 DRAFT' -File 'e2e' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    [System.IO.Directory]::CreateDirectory($ws) | Out-Null

    $csv = @'
name,company,email,phone,city,department,website
Maria Lopez,Constrular S.A.S.,maria@constrular.com.co,3015551234,Bogota,Cundinamarca,constrular.com.co
Julia Perez,Constrular S.A.S.,julia@constrular.com.co,3105556789,Medellin,Antioquia,constrular.com.co
Maria Lopez,Constrular S.A.S.,maria@constrular.com.co,3015551234,Bogota,Cundinamarca,constrular.com.co
Carla Ruiz,Arquidiseno LTDA,carla@arquidiseno.co,3205551111,Cali,Valle,arquidiseno.co
Carlos Pineda,Ingestructura SL,carlos@ingestructura.com,3155552222,Bucaramanga,Santander,ingestructura.com
'@
    $csvFile = Join-Path $ws 'leads.csv'
    [System.IO.File]::WriteAllText($csvFile, $csv, (New-Object System.Text.UTF8Encoding($false)))

    $imported = Import-PwxLeadsFromCsv -Path $csvFile
    Assert-PwxEqual 5 $imported.Count 'Se importan 5 leads'
    Assert-PwxEqual 'maria@constrular.com.co' $imported[0].email 'Normaliza email'

    $dups = Invoke-PwxLeadsDedupe
    Assert-PwxEqual 2 $dups.Count 'Duplicados: Maria repetida (email) + Julia (mismo dominio constrular.com.co)'

    $updateIds = Invoke-PwxLeadsScore
    $leads = @(Get-PwxLeads | Where-Object { -not $_.duplicate_of } | Sort-Object -Descending { [int]$_.score })
    Assert-PwxTrue ($leads.Count -ge 3) '5 importados - 2 duplicados = 3 leads unicos'
    $top2 = @($leads | Select-Object -First 2)

    foreach ($l in $top2) {
        $draft = New-PwxLeadDraft -LeadId $l.id -Channel 'email'
        Assert-PwxEqual 'DRAFT' $draft.status 'Draft DRAFT no SENT'
    }

    $drafts = Get-PwxOutboxItems -Status 'DRAFT'
    Assert-PwxEqual 2 $drafts.Count 'Outbox tiene 2 DRAFT'
    $sent = Get-PwxOutboxItems -Status 'SENT'
    Assert-PwxEqual 0 $sent.Count 'Cero enviados: aprobacion humana obligatoria'

    foreach ($d in $drafts) {
        Assert-PwxTrue ($d.lead_id -ne '') 'Draft referencia un lead'
    }
}

Run-PwxTest -Name 'E2E: import JSON y socrata offline (Invoke-RestMethod mocked)' -File 'e2e' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    [System.IO.Directory]::CreateDirectory($ws) | Out-Null

    $jsonFile = Join-Path $ws 'leads.json'
    $json = @(
        @{ name = 'Oscar Diaz'; company = 'DiazCo'; email = 'oscar@diaz.co'; phone = '3011110000'; city = 'Bogota'; department = 'Cundinamarca' },
        @{ name = 'Lucia Gomez'; email = 'lucia@gomez.com' }
    ) | ConvertTo-Json -Depth 5
    [System.IO.File]::WriteAllText($jsonFile, $json, (New-Object System.Text.UTF8Encoding($false)))

    $importedJson = Import-PwxLeadsFromJson -Path $jsonFile
    Assert-PwxEqual 2 $importedJson.Count 'JSON importa 2 leads'

    function Global:Invoke-RestMethod {
        param([string]$Uri, [string]$Method, [switch]$UseBasicParsing)
        $data = @(
            @{ razon_social = 'Constructora AAA'; correo = 'info@aaa.com'; telefono = '3012223333'; ciudad = 'Barranquilla'; departamento = 'Atlantico'; pagina_web = 'aaa.com' },
            @{ nombre = 'Beta SA'; empresa = 'Beta SA'; correo_electronico = 'contacto@beta.com'; celular = '3023334444'; municipio = 'Cartagena'; departamento = 'Bolivar' }
        )
        return $data
    }

    $importedSoc = Import-PwxLeadsFromSocrata -Url 'https://www.datos.gov.co/resource/xyz.json' -Limit 10
    Assert-PwxEqual 2 $importedSoc.Count 'Socrata importa 2 leads'
    Assert-PwxEqual 'info@aaa.com' $importedSoc[0].email 'Correo mapeado'
    Assert-PwxEqual 'contacto@beta.com' $importedSoc[1].email 'Correo alternativo mapeado'

    Remove-Item function:Global:Invoke-RestMethod
}