function Invoke-PwxService_simulate_service {
    param([string]$JobId)
    $job = Get-PwxJob -JobId $JobId
    if (-not $job) { throw "Trabajo inexistente: $JobId" }
    $jobDir = (Find-PwxJob -JobId $JobId).JobDir
    $outputDir = Join-Path $jobDir 'output'

    $content = @(
        "Trabajo: $JobId"
        "Cliente: $($job.client_id)"
        "Servicio: simulate-service"
        "Objetivo: $($job.requirements.objective)"
        "Generado: $((Get-PwxTimestamp))"
    ) -join [Environment]::NewLine

    $constraints = @($job.requirements.constraints)
    $emptyOutput = $false
    foreach ($c in $constraints) {
        if ($c -eq 'PWX_TEST_EMPTY_OUTPUT') { $emptyOutput = $true }
    }

    New-PwxDirectory -Path $outputDir | Out-Null
    $file = Join-Path $outputDir 'resultado.txt'
    if ($emptyOutput) {
        [System.IO.File]::WriteAllText($file, '', (New-Object System.Text.UTF8Encoding($false)))
    }
    else {
        [System.IO.File]::WriteAllText($file, $content, (New-Object System.Text.UTF8Encoding($false)))
    }
    Add-PwxJobFile -JobId $JobId -Bucket 'output' -Path $file | Out-Null
    Write-PwxLog -Component 'service.simulate' -Message "Salida simulada creada para $JobId" -JobId $JobId
    return [pscustomobject]@{
        ok    = $true
        error = $null
    }
}