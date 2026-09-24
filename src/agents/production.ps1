function Invoke-PwxProductionAgent {
    param(
        [Parameter(Mandatory)][string]$JobId
    )
    $job = Get-PwxJob -JobId $JobId
    if (-not $job) { throw "Trabajo inexistente: $JobId" }
    if (-not $job.requirements) { throw "Trabajo sin requisitos: $JobId" }

    if ($job.state -eq 'BLOCKED') {
        throw "JOB_BLOCKED_REQUIRES_REVIEW: el trabajo $JobId esta bloqueado; re-ejecute requisitos o desbloqueelo antes de producir."
    }
    if ($job.state -ne 'READY_FOR_PRODUCTION' -and $job.state -ne 'REWORK') {
        throw "Estado incorrecto para producir: $($job.state)"
    }

    $serviceId = $job.requirements.service
    Set-PwxJobState -JobId $JobId -To 'IN_PROGRESS' -Reason 'Inicio de produccion' -By 'production' | Out-Null

    if (-not (Test-PwxServiceImplemented -ServiceId $serviceId)) {
        Set-PwxJobState -JobId $JobId -To 'BLOCKED' -Reason "SERVICE_NOT_IMPLEMENTED:$serviceId" -By 'production' | Out-Null
        return [pscustomobject]@{
            ok    = $false
            state = 'BLOCKED'
            error = "SERVICE_NOT_IMPLEMENTED: $serviceId"
            qa    = $null
        }
    }

    Add-PwxOutputSnapshot -JobId $JobId -Reason 'run' | Out-Null

    $fn = 'Invoke-PwxService_' + ($serviceId -replace '-', '_')
    $output = & $fn -JobId $JobId

    if (-not $output.ok) {
        Set-PwxJobState -JobId $JobId -To 'BLOCKED' -Reason $output.error -By 'production' | Out-Null
        return [pscustomobject]@{
            ok    = $false
            state = 'BLOCKED'
            error = $output.error
            qa    = $null
        }
    }

    Set-PwxJobOutputVersion -JobId $JobId | Out-Null

    $qa = Invoke-PwxQa -JobId $JobId
    if ($qa.verdict -eq 'PASS') {
        Set-PwxJobState -JobId $JobId -To 'QA' -Reason 'Produccion completada, QA PASS' -By 'qa' | Out-Null
        Set-PwxJobState -JobId $JobId -To 'READY_FOR_DELIVERY' -Reason 'QA PASS' -By 'qa' | Out-Null
        return [pscustomobject]@{
            ok    = $true
            state = 'READY_FOR_DELIVERY'
            error = $null
            qa    = $qa
        }
    }
    else {
        Set-PwxJobState -JobId $JobId -To 'REWORK' -Reason 'QA FAILED' -By 'qa' | Out-Null
        return [pscustomobject]@{
            ok    = $false
            state = 'REWORK'
            error = 'QA_FAILED'
            qa    = $qa
        }
    }
}

function Resolve-PwxServiceFunction {
    param([string]$ServiceId)
    return 'Invoke-PwxService_' + ($ServiceId -replace '-', '_')
}