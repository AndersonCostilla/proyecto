$ErrorActionPreference = 'Stop'
$bootstrap = Join-Path $PSScriptRoot '..\bootstrap.ps1'
. $bootstrap

function Show-PwxHelp {
    Write-Host @'
PWX - Motor operativo comercial local

USO:
  pwx.ps1 <comando> [argumentos]

COMANDOS DE CLIENTE:
  client:new        -Name <nombre> [-Contact <email/tel>]
  client:list
  client:show       -ClientId <id>

COMANDOS DE TRABAJO:
  job:new           -ClientId <id> -Service <servicio> [-Description <texto>]
  job:show          -JobId <id>
  job:list          [-ClientId <id>]
  job:requisitos    -JobId <id> -Request "solicitud del cliente"
  job:input         -JobId <id> -Path <archivo> [-TargetName <nombre>]
  job:produce       -JobId <id>
  job:qa            -JobId <id>
  job:deliver       -JobId <id> [-AllowFail]  (AllowFail requiere env PWX_ALLOW_DELIVERY_BYPASS=1, solo tests/desarrollo)
  job:approvedeliver -JobId <id> [-By <quien>]
  job:state         -JobId <id> -To <ESTADO> [-Reason <motivo>]
  job:note          -JobId <id> -Note <texto>

ESTADO DEL TRABAJO
  NEW -> REQUIREMENTS -> READY_FOR_PRODUCTION -> IN_PROGRESS -> QA -> READY_FOR_DELIVERY -> DELIVERED -> COMPLETED
  Extra: BLOCKED | REWORK | CANCELLED

SERVICIOS Y COTIZACIÓN:
  services:list
  price:calc        -ServiceId <id> [-Addons rush,extra]  (precio base histórico)
  quote:calc        -ServiceId <id> [-Addons rush,extra] [-Complexity basic|standard|advanced|expert] [-Units 1] [-DiscountPct 0]

PAGOS MANUALES:
  payment:methods
  payment:request   -JobId <id> -Method <nequi|bank-transfer> [-Addons rush,extra] [-Complexity standard] [-Units 1] [-DiscountPct 0]
  payment:show      -JobId <id>
  payment:proof     -JobId <id> -Path <comprobante.png|jpg|pdf> [-Reference <referencia>]
  payment:approve   -JobId <id> [-By <operador>]
  payment:reject    -JobId <id> -Reason <motivo> [-By <operador>]

OUTBOX:
  outbox:new        -Recipient <dest> -Subject <asunto> -Body <texto> [-Type message] [-JobId <id>]
  outbox:show       -Id <msg-id>
  outbox:list       [-Status DRAFT|APPROVED|SENT]
  outbox:approve    -Id <msg-id> -By <quien>
  outbox:send       -Id <msg-id>
  outbox:export     [-Status DRAFT] [-Path <ruta>]  (exporta borradores DRAFT a workspace/exports; solo lectura, no envia)

PANEL WEB LOCAL:
  web:start         [-Port 8787]  (solo 127.0.0.1; no exponer a Internet)

SISTEMA:
  config:show
  ollama:check
  services:list
'@
    exit 0
}

function Read-PwxFlag {
    param(
        [string[]]$FlagList,
        [string]$Name
    )
    for ($i = 0; $i -lt $FlagList.Count; $i++) {
        if ($FlagList[$i] -eq $Name) {
            if (($i + 1) -lt $FlagList.Count) {
                return $FlagList[$i + 1]
            }
        }
    }
    return $null
}

function Test-PwxFlagPresent {
    param([string[]]$FlagList, [string]$Name)
    return ($FlagList -contains $Name)
}

$cmd = if ($args.Count -gt 0) { $args[0] } else { '' }
$rest = @($args[1..($args.Count - 1)])

switch ($cmd) {
    'client:new' {
        $name = Read-PwxFlag -FlagList $rest -Name '-Name'
        $contact = Read-PwxFlag -FlagList $rest -Name '-Contact'
        if (-not $name) { throw 'Falta -Name' }
        $client = New-PwxClient -Name $name -Contact $contact
        $client | ConvertTo-Json -Depth 5
        exit 0
    }
    'client:list' {
        $clients = Get-PwxClients
        if ($clients.Count -eq 0) { Write-Host '(sin clientes)' }
        else { $clients | ForEach-Object { "{0}  {1}  {2}" -f $_.id, $_.name, $_.contact } }
        exit 0
    }
    'client:show' {
        $id = Read-PwxFlag -FlagList $rest -Name '-ClientId'
        if (-not $id) { throw 'Falta -ClientId' }
        $client = Get-PwxClient -ClientId $id
        if (-not $client) { throw "Cliente inexistente: $id" }
        $client | ConvertTo-Json -Depth 5
        exit 0
    }
    'job:new' {
        $clientId = Read-PwxFlag -FlagList $rest -Name '-ClientId'
        $service = Read-PwxFlag -FlagList $rest -Name '-Service'
        $desc = Read-PwxFlag -FlagList $rest -Name '-Description'
        if (-not $clientId) { throw 'Falta -ClientId' }
        if (-not $service) { throw 'Falta -Service' }
        $job = New-PwxJob -ClientId $clientId -Service $service -Description $desc
        $job | ConvertTo-Json -Depth 6
        exit 0
    }
    'job:show' {
        $id = Read-PwxFlag -FlagList $rest -Name '-JobId'
        if (-not $id) { throw 'Falta -JobId' }
        $job = Get-PwxJob -JobId $id
        if (-not $job) { throw "Trabajo inexistente: $id" }
        $job | ConvertTo-Json -Depth 8
        exit 0
    }
    'job:list' {
        $clientId = Read-PwxFlag -FlagList $rest -Name '-ClientId'
        if ($clientId) { $jobs = Get-PwxJobs -ClientId $clientId } else {
            $jobs = @()
            foreach ($c in (Get-PwxClients)) { $jobs += Get-PwxJobs -ClientId $c.id }
        }
        if ($jobs.Count -eq 0) { Write-Host '(sin trabajos)' }
        else { $jobs | ForEach-Object { "{0}  {1}  {2}  {3}" -f $_.id, $_.client_id, $_.state, $_.service } }
        exit 0
    }
    'job:requisitos' {
        $id = Read-PwxFlag -FlagList $rest -Name '-JobId'
        $request = Read-PwxFlag -FlagList $rest -Name '-Request'
        if (-not $id) { throw 'Falta -JobId' }
        if (-not $request) { throw 'Falta -Request' }
        $result = Invoke-PwxRequirementsAgent -JobId $id -Request $request
        $result | ConvertTo-Json -Depth 8
        exit 0
    }
    'job:produce' {
        $id = Read-PwxFlag -FlagList $rest -Name '-JobId'
        if (-not $id) { throw 'Falta -JobId' }
        $result = Invoke-PwxProductionAgent -JobId $id
        $result | ConvertTo-Json -Depth 5
        exit 0
    }
    'job:input' {
        $id = Read-PwxFlag -FlagList $rest -Name '-JobId'
        $path = Read-PwxFlag -FlagList $rest -Name '-Path'
        $targetName = Read-PwxFlag -FlagList $rest -Name '-TargetName'
        if (-not $id) { throw 'Falta -JobId' }
        if (-not $path) { throw 'Falta -Path' }
        $entry = Add-PwxJobInputFile -JobId $id -SourcePath $path -TargetName $targetName
        $entry | ConvertTo-Json -Depth 5
        exit 0
    }
    'job:qa' {
        $id = Read-PwxFlag -FlagList $rest -Name '-JobId'
        if (-not $id) { throw 'Falta -JobId' }
        $result = Invoke-PwxQa -JobId $id
        $result | ConvertTo-Json -Depth 6
        exit 0
    }
    'job:deliver' {
        $id = Read-PwxFlag -FlagList $rest -Name '-JobId'
        if (-not $id) { throw 'Falta -JobId' }
        $allow = Test-PwxFlagPresent -FlagList $rest -Name '-AllowFail'
        $result = New-PwxDelivery -JobId $id -AllowFail:$allow
        $result | ConvertTo-Json -Depth 6
        exit 0
    }
    'job:approvedeliver' {
        $id = Read-PwxFlag -FlagList $rest -Name '-JobId'
        $by = Read-PwxFlag -FlagList $rest -Name '-By'
        if (-not $id) { throw 'Falta -JobId' }
        Approve-PwxDelivery -JobId $id -By $by
        Write-Host "Entrega aprobada para $id"
        exit 0
    }
    'job:state' {
        $id = Read-PwxFlag -FlagList $rest -Name '-JobId'
        $to = Read-PwxFlag -FlagList $rest -Name '-To'
        $reason = Read-PwxFlag -FlagList $rest -Name '-Reason'
        if (-not $id) { throw 'Falta -JobId' }
        if (-not $to) { throw 'Falta -To' }
        $job = Set-PwxJobState -JobId $id -To $to -Reason $reason
        $job | ConvertTo-Json -Depth 5
        exit 0
    }
    'job:note' {
        $id = Read-PwxFlag -FlagList $rest -Name '-JobId'
        $note = Read-PwxFlag -FlagList $rest -Name '-Note'
        if (-not $id) { throw 'Falta -JobId' }
        if (-not $note) { throw 'Falta -Note' }
        Add-PwxJobNote -JobId $id -Note $note
        Write-Host "Nota agregada a $id"
        exit 0
    }
    'services:list' {
        Get-PwxRegisteredServices | ForEach-Object {
            "{0}  {1}  prebase={2}  implementado={3}" -f $_.id, $_.name, $_.base_price, $_.implemented
        }
        exit 0
    }
    'price:calc' {
        $serviceId = Read-PwxFlag -FlagList $rest -Name '-ServiceId'
        $addonsRaw = Read-PwxFlag -FlagList $rest -Name '-Addons'
        if (-not $serviceId) { throw 'Falta -ServiceId' }
        $addons = @()
        if ($addonsRaw) { $addons = @($addonsRaw -split ',') }
        $price = Get-PwxPrice -ServiceId $serviceId -Addons $addons
        $price | ConvertTo-Json -Depth 5
        exit 0
    }
    'quote:calc' {
        $serviceId = Read-PwxFlag -FlagList $rest -Name '-ServiceId'
        $addonsRaw = Read-PwxFlag -FlagList $rest -Name '-Addons'
        $complexity = Read-PwxFlag -FlagList $rest -Name '-Complexity'
        $unitsRaw = Read-PwxFlag -FlagList $rest -Name '-Units'
        $discountRaw = Read-PwxFlag -FlagList $rest -Name '-DiscountPct'
        if (-not $serviceId) { throw 'Falta -ServiceId' }
        if (-not $complexity) { $complexity = 'standard' }
        $addons = @()
        if ($addonsRaw) { $addons = @($addonsRaw -split ',') }
        $units = 1
        if ($unitsRaw) { $units = [int]$unitsRaw }
        $discountPct = 0.0
        if ($discountRaw) { $discountPct = [double]$discountRaw }
        $quote = Get-PwxQuote -ServiceId $serviceId -Addons $addons -Complexity $complexity -Units $units -DiscountPct $discountPct
        $quote | ConvertTo-Json -Depth 6
        exit 0
    }
    'payment:methods' {
        $methods = Get-PwxPaymentMethods
        $methods | ConvertTo-Json -Depth 5
        exit 0
    }
    'payment:request' {
        $jobId = Read-PwxFlag -FlagList $rest -Name '-JobId'
        $method = Read-PwxFlag -FlagList $rest -Name '-Method'
        $addonsRaw = Read-PwxFlag -FlagList $rest -Name '-Addons'
        $complexity = Read-PwxFlag -FlagList $rest -Name '-Complexity'
        $unitsRaw = Read-PwxFlag -FlagList $rest -Name '-Units'
        $discountRaw = Read-PwxFlag -FlagList $rest -Name '-DiscountPct'
        if (-not $jobId) { throw 'Falta -JobId' }
        if (-not $method) { throw 'Falta -Method' }
        if (-not $complexity) { $complexity = 'standard' }
        $addons = @()
        if ($addonsRaw) { $addons = @($addonsRaw -split ',') }
        $units = 1
        if ($unitsRaw) { $units = [int]$unitsRaw }
        $discountPct = 0.0
        if ($discountRaw) { $discountPct = [double]$discountRaw }
        $payment = New-PwxPaymentRequest -JobId $jobId -Method $method -Addons $addons -Complexity $complexity -Units $units -DiscountPct $discountPct
        $payment | ConvertTo-Json -Depth 10
        exit 0
    }
    'payment:show' {
        $jobId = Read-PwxFlag -FlagList $rest -Name '-JobId'
        if (-not $jobId) { throw 'Falta -JobId' }
        $payments = Get-PwxPaymentsForJob -JobId $jobId
        if ($payments.Count -eq 0) { Write-Host '(sin pagos)' }
        else { $payments | ConvertTo-Json -Depth 10 }
        exit 0
    }
    'payment:proof' {
        $jobId = Read-PwxFlag -FlagList $rest -Name '-JobId'
        $path = Read-PwxFlag -FlagList $rest -Name '-Path'
        $reference = Read-PwxFlag -FlagList $rest -Name '-Reference'
        if (-not $jobId) { throw 'Falta -JobId' }
        if (-not $path) { throw 'Falta -Path' }
        $payment = Submit-PwxPaymentProof -JobId $jobId -Path $path -Reference $reference
        $payment | ConvertTo-Json -Depth 10
        exit 0
    }
    'payment:approve' {
        $jobId = Read-PwxFlag -FlagList $rest -Name '-JobId'
        $by = Read-PwxFlag -FlagList $rest -Name '-By'
        if (-not $jobId) { throw 'Falta -JobId' }
        $payment = Approve-PwxPayment -JobId $jobId -By $by
        $payment | ConvertTo-Json -Depth 10
        exit 0
    }
    'payment:reject' {
        $jobId = Read-PwxFlag -FlagList $rest -Name '-JobId'
        $reason = Read-PwxFlag -FlagList $rest -Name '-Reason'
        $by = Read-PwxFlag -FlagList $rest -Name '-By'
        if (-not $jobId) { throw 'Falta -JobId' }
        if (-not $reason) { throw 'Falta -Reason' }
        $payment = Reject-PwxPayment -JobId $jobId -Reason $reason -By $by
        $payment | ConvertTo-Json -Depth 10
        exit 0
    }
    'outbox:new' {
        $recipient = Read-PwxFlag -FlagList $rest -Name '-Recipient'
        $subject = Read-PwxFlag -FlagList $rest -Name '-Subject'
        $body = Read-PwxFlag -FlagList $rest -Name '-Body'
        $type = Read-PwxFlag -FlagList $rest -Name '-Type'
        $jobId = Read-PwxFlag -FlagList $rest -Name '-JobId'
        if (-not $recipient) { throw 'Falta -Recipient' }
        if (-not $subject) { throw 'Falta -Subject' }
        if (-not $body) { throw 'Falta -Body' }
        $item = New-PwxOutboxItem -Recipient $recipient -Subject $subject -Body $body -Type $type -JobId $jobId
        $item | ConvertTo-Json -Depth 6
        exit 0
    }
    'outbox:show' {
        $id = Read-PwxFlag -FlagList $rest -Name '-Id'
        if (-not $id) { throw 'Falta -Id' }
        $item = Get-PwxOutboxItem -Id $id
        if (-not $item) { throw "Mensaje inexistente: $id" }
        $item | ConvertTo-Json -Depth 6
        exit 0
    }
    'outbox:list' {
        $status = Read-PwxFlag -FlagList $rest -Name '-Status'
        $items = Get-PwxOutboxItems -Status $status
        if ($items.Count -eq 0) { Write-Host '(sin mensajes)' }
        else { $items | ForEach-Object { "{0}  {1}  {2}  ->  {3}" -f $_.id, $_.status, $_.type, $_.recipient } }
        exit 0
    }
    'outbox:approve' {
        $id = Read-PwxFlag -FlagList $rest -Name '-Id'
        $by = Read-PwxFlag -FlagList $rest -Name '-By'
        if (-not $id) { throw 'Falta -Id' }
        $item = Set-PwxOutboxStatus -Id $id -Status 'APPROVED' -By $by
        $item | ConvertTo-Json -Depth 6
        exit 0
    }
    'outbox:send' {
        $id = Read-PwxFlag -FlagList $rest -Name '-Id'
        if (-not $id) { throw 'Falta -Id' }
        $item = Set-PwxOutboxStatus -Id $id -Status 'SENT'
        $item | ConvertTo-Json -Depth 6
        exit 0
    }
    'outbox:export' {
        $status = Read-PwxFlag -FlagList $rest -Name '-Status'
        $path = Read-PwxFlag -FlagList $rest -Name '-Path'
        if (-not $status) { $status = 'DRAFT' }
        if ($status -ne 'DRAFT') { throw 'outbox:export solo exporta mensajes en estado DRAFT' }
        $result = Export-PwxOutboxCsv -Path $path
        Write-Host ("Archivo: {0}" -f $result.path)
        Write-Host ("Exportados: {0}" -f $result.exported)
        Write-Host ("Omitidos: {0}" -f $result.omitted.count)
        foreach ($o in $result.omitted.items) {
            Write-Host ("  {0}: {1}" -f $o.id, $o.reason)
        }
        exit 0
    }
    'lead:new' {
        $name = Read-PwxFlag -FlagList $rest -Name '-Name'
        $company = Read-PwxFlag -FlagList $rest -Name '-Company'
        $email = Read-PwxFlag -FlagList $rest -Name '-Email'
        $phone = Read-PwxFlag -FlagList $rest -Name '-Phone'
        $city = Read-PwxFlag -FlagList $rest -Name '-City'
        $department = Read-PwxFlag -FlagList $rest -Name '-Department'
        $website = Read-PwxFlag -FlagList $rest -Name '-Website'
        $lead = New-PwxLead -Name $name -Company $company -Email $email -Phone $phone -City $city -Department $department -Website $website
        $lead | ConvertTo-Json -Depth 5
        exit 0
    }
    'lead:import' {
        $path = Read-PwxFlag -FlagList $rest -Name '-Path'
        if (-not $path) { throw 'Falta -Path' }
        $ext = [System.IO.Path]::GetExtension($path).ToLowerInvariant()
        if ($ext -eq '.csv') {
            $result = Import-PwxLeadsFromCsv -Path $path
        } elseif ($ext -eq '.json') {
            $result = Import-PwxLeadsFromJson -Path $path
        } else {
            throw 'Formato no soportado. Use .csv o .json'
        }
        $result | ConvertTo-Json -Depth 5
        exit 0
    }
    'lead:import-socrata' {
        $url = Read-PwxFlag -FlagList $rest -Name '-Url'
        $limit = Read-PwxFlag -FlagList $rest -Name '-Limit'
        $map = Read-PwxFlag -FlagList $rest -Name '-Map'
        if (-not $url) { throw 'Falta -Url' }
        $lim = 200
        if ($limit) { [int]::TryParse($limit, [ref]$lim) | Out-Null }
        $result = Import-PwxLeadsFromSocrata -Url $url -Limit $lim -Map $map
        $result | ConvertTo-Json -Depth 5
        exit 0
    }
    'lead:list' {
        $leads = Get-PwxLeads
        if ($leads.Count -eq 0) { Write-Host '(sin leads)' }
        else { $leads | ForEach-Object { "{0}  {1}  {2}  {3}  s={4}" -f $_.id, $_.status, $_.name, $_.company, $_.score } }
        exit 0
    }
    'lead:dedupe' {
        $updated = Invoke-PwxLeadsDedupe
        @{ updated = $updated } | ConvertTo-Json -Depth 3
        exit 0
    }
    'lead:score' {
        $updated = Invoke-PwxLeadsScore
        @{ updated = $updated } | ConvertTo-Json -Depth 3
        exit 0
    }
    'lead:draft' {
        $leadId = Read-PwxFlag -FlagList $rest -Name '-LeadId'
        $channel = Read-PwxFlag -FlagList $rest -Name '-Channel'
        if (-not $channel) { $channel = 'email' }
        if (-not $leadId) { throw 'Falta -LeadId' }
        $result = New-PwxLeadDraft -LeadId $leadId -Channel $channel
        $result | ConvertTo-Json -Depth 6
        exit 0
    }
    'lead:convert' {
        $leadId = Read-PwxFlag -FlagList $rest -Name '-LeadId'
        if (-not $leadId) { throw 'Falta -LeadId' }
        $result = Convert-PwxLeadToClient -LeadId $leadId
        $result | ConvertTo-Json -Depth 5
        exit 0
    }
    'web:start' {
        $portRaw = Read-PwxFlag -FlagList $rest -Name '-Port'
        $port = 8787
        if ($portRaw) { $port = [int]$portRaw }
        Start-PwxWebServer -Port $port
        exit 0
    }
    'config:show' {
        Get-PwxConfig | ConvertTo-Json -Depth 5
        exit 0
    }
    'ollama:check' {
        $status = Get-PwxOllamaStatus
        "ollama: $($status.status)"
        foreach ($m in $status.models) { "  modelo: $m  ->  $((Test-PwxModelAvailable -Model $m))" }
        $model = (Get-PwxConfig).Model
        "modelo config: $model  ->  $((Test-PwxModelAvailable -Model $model))"
        exit 0
    }
    default {
        Show-PwxHelp
    }
}