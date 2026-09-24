$ErrorActionPreference = 'Stop'
$bootstrap = Join-Path $PSScriptRoot '..\bootstrap.ps1'
. $bootstrap

function Show-PwxStep {
    param([string]$Text)
    Write-Host ("`n=== {0} ===" -f $Text) -ForegroundColor Cyan
}

function Show-PwxOk {
    param([string]$Text)
    Write-Host ("  [OK] {0}" -f $Text) -ForegroundColor Green
}

Write-Host "DEMO: Motor operativo local PWX" -ForegroundColor Magenta
Write-Host ("Workspace: {0}" -f (Get-PwxConfig).WorkspacePath)
Write-Host ("Modelo LLM: {0}" -f (Get-PwxConfig).Model)

Show-PwxStep '1. Cliente'
$client = New-PwxClient -Name 'Cliente Demostracion' -Contact 'demo@mail.com'
Show-PwxOk "Cliente $($client.id)"

Show-PwxStep '2. Trabajo'
$request = 'Simula la generacion de un informe comercial a partir de datos de un presupuesto.'
$job = New-PwxJob -ClientId $client.id -Service 'simulate-service' -Description $request
Show-PwxOk "Trabajo $($job.id) estado=$($job.state)"

Show-PwxStep '3. Requisitos (agente LLM -> qwen3:8b)'
$res = Invoke-PwxRequirementsAgent -JobId $job.id -Request $request
if (-not $res.ok) {
    Write-Host ("  [WARN] {0} ({1})" -f $res.error, $res.code) -ForegroundColor Yellow
    Write-Host "  Se usara ForceJson para continuar la demo."
    $json = '{"service":"simulate-service","objective":"generar informe","input_files":[],"required_output":["resultado.txt"],"constraints":[],"missing_information":[],"acceptance_criteria":["archivo existe"]}'
    $res = Invoke-PwxRequirementsAgent -JobId $job.id -Request $request -ForceJson $json
}
Show-PwxOk "Servicio en requisitos: $($res.spec.service)"
Show-PwxOk "Estado tras requisitos: $($res.state)"

if (-not (Test-PwxServiceImplemented -ServiceId $res.spec.service)) {
    Write-Host ("  [WARN] El servicio '{0}' no esta implementado en esta fase. Se usa simulate-service para demostrar el ciclo completo." -f $res.spec.service) -ForegroundColor Yellow
    $jobCurrent = Get-PwxJob -JobId $job.id
    $jobCurrent.requirements.service = 'simulate-service'
    Save-PwxJob -Job $jobCurrent | Out-Null
    Get-PwxJob -JobId $job.id | Out-Null
}

Show-PwxStep '4. Precio (determinista)'
$svcId = (Get-PwxJob -JobId $job.id).requirements.service
$price = Get-PwxPrice -ServiceId $svcId
Show-PwxOk ("Precio base {0}: {1:N0} COP" -f $price.service_id, $price.base_price)
Show-PwxOk ("Subtotal: {0:N0} COP  margen={1}%" -f $price.subtotal, $price.margin_pct)

Show-PwxStep '5. Produccion (servicio + QA determinista)'
$prod = Invoke-PwxProductionAgent -JobId $job.id
if (-not $prod.ok) { throw "Produccion fallida: $($prod.error)" }
Show-PwxOk "Estado: $($prod.state)"

Show-PwxStep '6. Veredicto QA'
$qa = Get-PwxQaResult -JobId $job.id
Show-PwxOk "Veredicto: $($qa.verdict)  (checks: $($qa.checks.Count))"

Show-PwxStep '7. Empaquetado de entrega'
$manifest = New-PwxDelivery -JobId $job.id
Show-PwxOk ("Archivos empaquetados: {0}" -f $manifest.file_count)

Show-PwxStep '8. Generar mensaje OUTBOX'
$msg = New-PwxOutboxItem -Recipient $client.contact -Subject "Entrega lista: $($job.id)" -Body "Tu trabajo $($job.id) esta listo." -JobId $job.id -ClientId $client.id
Show-PwxOk ("Mensaje {0} creado (DRAFT)" -f $msg.id)

Show-PwxStep '9. Aprobacion humana del envío'
$approved = Set-PwxOutboxStatus -Id $msg.id -Status 'APPROVED' -By 'operador'
Show-PwxOk "Aprobado por $($approved.approved_by)"

Show-PwxStep '10. Marcar entregado'
Approve-PwxDelivery -JobId $job.id -By 'operador'
$finalJob = Get-PwxJob -JobId $job.id
Show-PwxOk "Estado final trabajo: $($finalJob.state)"

Write-Host "`n=== RESUMEN FINAL ===" -ForegroundColor Magenta
$finalJob | ConvertTo-Json -Depth 6
Write-Host "`nMensajes outbox:"
Get-PwxOutboxItems -Status 'APPROVED' | ForEach-Object { "  {0}  {1}  ->  {2}" -f $_.id, $_.status, $_.recipient }
Write-Host ("`nDemo completa. Duración total registrada en {0}" -f (Join-Path (Get-PwxConfig).WorkspacePath 'logs'))