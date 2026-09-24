function New-PwxRequirementsSpec {
    param(
        [string]$Service = 'simulate-service',
        [string]$Objective = '',
        [string[]]$RequiredOutput = @('resultado.txt')
    )
    $emptySpec = [ordered]@{
        service              = $Service
        objective            = $Objective
        input_files          = @()
        required_output      = $RequiredOutput
        constraints          = @()
        missing_information   = @()
        acceptance_criteria  = @()
    }
    return $emptySpec
}

function Test-PwxRequirementsSpec {
    param([object]$Spec)
    if ($null -eq $Spec) { return $false }
    $props = @('service','objective','input_files','required_output','constraints','missing_information','acceptance_criteria')
    foreach ($p in $props) {
        if ($null -eq $Spec.PSObject.Properties[$p]) { return $false }
    }
    if ([string]::IsNullOrWhiteSpace([string]$Spec.service)) { return $false }
    if ([string]::IsNullOrWhiteSpace([string]$Spec.objective)) { return $false }
    if ($Spec.required_output -isnot [System.Array]) { return $false }
    if ($Spec.input_files -isnot [System.Array]) { return $false }
    return $true
}

function Repair-PwxRequirementsSpec {
    param([object]$Spec)
    if (Test-PwxRequirementsSpec -Spec $Spec) { return $Spec }
    $specText = ($Spec | ConvertTo-Json -Depth 20)
    $candidates = @()
    $candidates += $specText
    $candidates += $specText -replace "'", '"'
    foreach ($c in $candidates) {
        $parsed = ConvertFrom-PwxOllamaJson -Text $c
        if (Test-PwxRequirementsSpec -Spec $parsed) { return $parsed }
    }
    return $null
}

function Conform-PwxRequirementsSpec {
    param([object]$Spec)
    $svc = Get-PwxService -ServiceId $Spec.service
    if ($svc -and $svc.contract -and $svc.contract.output) {
        $Spec.required_output = @($svc.contract.output)
    }
    return $Spec
}

function Invoke-PwxRequirementsAgent {
    param(
        [Parameter(Mandatory)][string]$JobId,
        [Parameter(Mandatory)][string]$Request,
        [string]$ForceJson = ''
    )
    $job = Get-PwxJob -JobId $JobId
    if (-not $job) { throw "Trabajo inexistente: $JobId" }

    switch ($job.state) {
        'NEW' {
            Set-PwxJobState -JobId $JobId -To 'REQUIREMENTS' -Reason 'Solicitud de requisitos' -By 'requirements' | Out-Null
        }
        'BLOCKED' {
            Set-PwxJobState -JobId $JobId -To 'REQUIREMENTS' -Reason 'Reintento de requisitos' -By 'requirements' | Out-Null
        }
        'REQUIREMENTS' {
            # re-ejecucion idempotente: ya esta en curso
        }
        'READY_FOR_PRODUCTION' {
            # re-ejecucion idempotente: reextraer requisitos
        }
        default {
            throw "JOB_NOT_ELIGIBLE_FOR_REQUIREMENTS: estado $($job.state) no permite obtener requisitos"
        }
    }
    $job = Get-PwxJob -JobId $JobId

    $system = @'
Eres el agente de requisitos de un sistema comercial local que produce trabajos digitales.
Recibes la solicitud del cliente y debes producir una especificacion estructurada en JSON.
Devuelve SOLO el JSON, sin comentarios ni texto adicional.

Estructura obligatoria:
{
  "service": "id del servicio",
  "objective": "objetivo en una frase",
  "input_files": ["nombres de archivos si se mencionan, sino []"],
  "required_output": ["patrones de archivos esperados, ej: '*.xlsx', 'resultado.txt'"],
  "constraints": ["condiciones del cliente"],
  "missing_information": ["informacion que falta"],
  "acceptance_criteria": ["criterios verificables"]
}
Servicios disponibles (usa exactamente uno):
- excel-service: planillas Excel
- word-service: documentos de texto
- pdf-service: documentos PDF
- data-service: limpieza y transformacion de datos
- construction-service: computos y presupuestos de construccion
- simulate-service: demostracion interna
No inventes precios. Solo clasifica la solicitud.
'@

    $prompt = "Solicitud del cliente:`n---`n$Request`n---`nExtrae la especificacion JSON."

    if ($ForceJson) {
        $spec = ConvertFrom-PwxOllamaJson -Text $ForceJson
        $parsedOk = Test-PwxRequirementsSpec -Spec $spec
        if (-not $parsedOk) {
            Set-PwxJobState -JobId $JobId -To 'BLOCKED' -Reason 'MODEL_INVALID_RESPONSE' -By 'requirements' | Out-Null
            return [pscustomobject]@{
                ok        = $false
                code      = 'MODEL_INVALID_RESPONSE'
                spec      = $null
                state     = 'BLOCKED'
                error     = 'ForceJson invalido'
            }
        }
    }
    else {
        $result = Invoke-PwxOllamaChat -Prompt $prompt -System $system -FormatJson $true -Temperature 0.1

        if (-not $result.ok) {
            Set-PwxJobState -JobId $JobId -To 'BLOCKED' -Reason $result.code -By 'requirements' | Out-Null
            return [pscustomobject]@{
                ok        = $false
                code      = $result.code
                spec      = $null
                state     = 'BLOCKED'
                error     = $result.error
            }
        }

        $spec = ConvertFrom-PwxOllamaJson -Text $result.content
        if (-not (Test-PwxRequirementsSpec -Spec $spec)) {
            $spec = Repair-PwxRequirementsSpec -Spec $spec
        }
        if (-not (Test-PwxRequirementsSpec -Spec $spec)) {
            Set-PwxJobState -JobId $JobId -To 'BLOCKED' -Reason 'MODEL_INVALID_RESPONSE' -By 'requirements' | Out-Null
            return [pscustomobject]@{
                ok        = $false
                code      = 'MODEL_INVALID_RESPONSE'
                spec      = $null
                state     = 'BLOCKED'
                error     = 'El modelo devolvio JSON invalido y no se pudo reparar'
            }
        }
    }

    $validService = (Get-PwxServiceIds -ErrorAction SilentlyContinue)
    if ($null -eq $validService -or ($validService | Where-Object { $_ -eq $spec.service }).Count -eq 0) {
        Set-PwxJobState -JobId $JobId -To 'BLOCKED' -Reason "SERVICE_NOT_IN_CATALOG:$($spec.service)" -By 'requirements' | Out-Null
        return [pscustomobject]@{
            ok    = $false
            code  = 'SERVICE_NOT_IN_CATALOG'
            spec  = $null
            state = 'BLOCKED'
            error = "SERVICE_NOT_IN_CATALOG: $($spec.service)"
        }
    }

    $spec = Conform-PwxRequirementsSpec -Spec $spec

    $job.requirements = $spec
    Save-PwxJob -Job $job | Out-Null
    Add-PwxEvent -JobId $JobId -Component 'requirements' -Action 'requirements.extracted' -Data @{ service = $spec.service }
    $jobAfter = Get-PwxJob -JobId $JobId
    if ($jobAfter.state -ne 'READY_FOR_PRODUCTION') {
        Set-PwxJobState -JobId $JobId -To 'READY_FOR_PRODUCTION' -Reason 'Requisitos extraidos' -By 'requirements' | Out-Null
    }
    return [pscustomobject]@{
        ok    = $true
        code  = 'OK'
        spec  = $spec
        state = 'READY_FOR_PRODUCTION'
        error = $null
    }
}