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
  job:produce       -JobId <id>
  job:qa            -JobId <id>
  job:deliver       -JobId <id> [-AllowFail]  (AllowFail requiere env PWX_ALLOW_DELIVERY_BYPASS=1, solo tests/desarrollo)
  job:approvedeliver -JobId <id> [-By <quien>]
  job:state         -JobId <id> -To <ESTADO> [-Reason <motivo>]
  job:note          -JobId <id> -Note <texto>

ESTADO DEL TRABAJO
  NEW -> REQUIREMENTS -> READY_FOR_PRODUCTION -> IN_PROGRESS -> QA -> READY_FOR_DELIVERY -> DELIVERED -> COMPLETED
  Extra: BLOCKED | REWORK | CANCELLED

SERVICIOS:
  services:list
  price:calc        -ServiceId <id> [-Addons rush,extra]

OUTBOX:
  outbox:new        -Recipient <dest> -Subject <asunto> -Body <texto> [-Type message] [-JobId <id>]
  outbox:show       -Id <msg-id>
  outbox:list       [-Status DRAFT|APPROVED|SENT]
  outbox:approve    -Id <msg-id> -By <quien>
  outbox:send       -Id <msg-id>

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