param(
    [string]$ReportPath = ''
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$previousRoot = $env:PWX_ROOT
$previousWorkspace = $env:PWX_WORKSPACE
$runId = 'pwx-real-agent-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$baseTemp = if ($env:TEMP) { $env:TEMP } else { [System.IO.Path]::GetTempPath() }
$runRoot = Join-Path $baseTemp $runId
$workspace = Join-Path $runRoot 'workspace'

if (-not $ReportPath) { $ReportPath = Join-Path $runRoot 'real-agent-report.json' }

$report = [ordered]@{
    run_id       = $runId
    started_at    = (Get-Date).ToString('o')
    ok           = $false
    model         = $null
    workspace     = $workspace
    checks        = [ordered]@{}
    error         = $null
}

function Set-RealAgentCheck {
    param([string]$Name, [bool]$Ok, [object]$Detail)
    $report.checks[$Name] = [ordered]@{
        ok     = $Ok
        detail = $Detail
    }
    $marker = if ($Ok) { 'PASS' } else { 'FAIL' }
    $color = if ($Ok) { 'Green' } else { 'Red' }
    Write-Host ("{0}  {1}" -f $marker, $Name) -ForegroundColor $color
    if ($Detail) { Write-Host ("      {0}" -f (($Detail | Out-String).Trim())) -ForegroundColor DarkGray }
}

try {
    $env:PWX_ROOT = $root
    $env:PWX_WORKSPACE = $workspace
    . (Join-Path $root 'src\bootstrap.ps1')

    Write-Host ''
    Write-Host 'PWX — prueba real de agentes locales' -ForegroundColor Cyan
    Write-Host "Workspace aislado: $workspace" -ForegroundColor DarkGray

    $ollama = Get-PwxOllamaStatus
    if ($ollama.status -ne 'OK') {
        throw "Ollama no responde en $((Get-PwxConfig).OllamaBaseUrl). Inícialo con: ollama serve"
    }
    $model = (Get-PwxConfig).Model
    $availability = Test-PwxModelAvailable -Model $model
    if ($availability -ne 'OK') {
        throw "El modelo '$model' no está disponible ($availability). Instálalo con: ollama pull $model"
    }
    $report.model = $model
    Set-RealAgentCheck -Name 'Ollama y modelo local' -Ok $true -Detail "Modelo disponible: $model"

    $client = New-PwxClient -Name 'Cliente de validación real' -Contact 'validacion@local.test'
    $job = New-PwxJob -ClientId $client.id -Service 'simulate-service' -Description 'Demostración interna controlada para validar agentes.'
    Set-RealAgentCheck -Name 'Creación de cliente y trabajo' -Ok $true -Detail "$($client.id) / $($job.id)"

    $request = @'
Esto es una DEMOSTRACIÓN INTERNA de PWX, no un trabajo para cliente.
Selecciona obligatoriamente el servicio simulate-service. Objetivo: validar el flujo.
No hay archivos de entrada. La salida requerida debe ser resultado.txt.
Criterio de aceptación: el archivo resultado.txt existe y no está vacío.
'@
    $requirements = Invoke-PwxRequirementsAgent -JobId $job.id -Request $request
    if (-not $requirements.ok) { throw "El agente de requisitos falló: $($requirements.code) $($requirements.error)" }
    if ($requirements.spec.service -ne 'simulate-service') {
        throw "El agente de requisitos eligió '$($requirements.spec.service)' y se esperaba simulate-service para esta prueba controlada"
    }
    Set-RealAgentCheck -Name 'Agente real de requisitos' -Ok $true -Detail "Servicio: $($requirements.spec.service); estado: $($requirements.state)"

    $production = Invoke-PwxProductionAgent -JobId $job.id
    if (-not $production.ok -or $production.state -ne 'READY_FOR_DELIVERY') {
        throw "El agente de producción/QA falló: $($production.error)"
    }
    Set-RealAgentCheck -Name 'Agente de producción y QA' -Ok $true -Detail "Estado: $($production.state); QA: $($production.qa.verdict)"

    $lead = New-PwxLead -Name 'Contacto de validación' -Company 'Empresa de prueba' -Email 'contacto@validacion.test' -Phone '3001234567' -City 'Tunja' -Department 'Boyacá'
    $prospecting = Invoke-PwxProspectingDraft -LeadId $lead.id -Channel 'email'
    if ([string]::IsNullOrWhiteSpace([string]$prospecting.body)) {
        throw 'El agente de prospección no generó contenido'
    }
    $outbox = New-PwxLeadDraft -LeadId $lead.id -Channel 'email' -Subject $prospecting.subject -Body $prospecting.body
    $usedModel = ($prospecting.source -eq 'llm')
    Set-RealAgentCheck -Name 'Agente de prospección' -Ok $true -Detail "Fuente: $($prospecting.source); borrador: $($outbox.id); enviado: no"
    if (-not $usedModel) {
        Write-Host '      AVISO: se usó plantilla como respaldo; revisa Ollama si esperabas generación LLM.' -ForegroundColor Yellow
    }

    $quote = Get-PwxQuote -ServiceId 'excel-service' -Units 3 -Complexity 'advanced' -Addons @('rush') -DiscountPct 5
    if ($quote.total -le 0) { throw 'La cotización determinista produjo un total inválido' }
    Set-RealAgentCheck -Name 'Cotización determinista' -Ok $true -Detail "$($quote.total) $($quote.currency)"

    $report.ok = $true
    Write-Host ''
    Write-Host 'RESULTADO: agentes y flujo local verificados correctamente.' -ForegroundColor Green
}
catch {
    $report.error = $_.Exception.Message
    Set-RealAgentCheck -Name 'Ejecución real de agentes' -Ok $false -Detail $_.Exception.Message
    Write-Host ''
    Write-Host 'RESULTADO: la prueba real falló. Revisa el detalle del reporte.' -ForegroundColor Red
}
finally {
    $report.finished_at = (Get-Date).ToString('o')
    $reportDirectory = Split-Path -Parent $ReportPath
    if ($reportDirectory) { New-Item -ItemType Directory -Path $reportDirectory -Force | Out-Null }
    [System.IO.File]::WriteAllText($ReportPath, ($report | ConvertTo-Json -Depth 20), (New-Object System.Text.UTF8Encoding($false)))
    Write-Host ("Reporte: {0}" -f $ReportPath) -ForegroundColor Cyan
    $env:PWX_ROOT = $previousRoot
    $env:PWX_WORKSPACE = $previousWorkspace
}

if (-not $report.ok) { exit 1 }
