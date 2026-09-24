function New-PwxDelivery {
    param(
        [Parameter(Mandatory)][string]$JobId,
        [switch]$AllowFail
    )
    if ($AllowFail -and $env:PWX_ALLOW_DELIVERY_BYPASS -ne '1') {
        throw "-AllowFail solo disponible con PWX_ALLOW_DELIVERY_BYPASS=1 (tests/desarrollo)."
    }
    $job = Get-PwxJob -JobId $JobId
    if (-not $job) { throw "Trabajo inexistente: $JobId" }
    $qa = Get-PwxQaResult -JobId $JobId
    if (-not $AllowFail) {
        if (-not $qa -or $qa.verdict -ne 'PASS') {
            throw "QA no aprobado para $JobId (verdict: $($qa.verdict))."
        }
        $approvedSnapshot = @($qa.output_files)
        $currentSnapshot = @(Get-PwxOutputSnapshot -JobId $JobId)
        $changed = @()
        if ($approvedSnapshot.Count -ne $currentSnapshot.Count) {
            $changed += "conjunto de archivos distinto (QA=$($approvedSnapshot.Count), actual=$($currentSnapshot.Count))"
        }
        foreach ($c in $currentSnapshot) {
            $match = @($approvedSnapshot | Where-Object { $_.path -eq $c.path })
            if ($match.Count -eq 0) {
                $changed += "archivo nuevo no inspeccionado por QA: $($c.path)"
            }
            elseif ($match[0].sha256 -ne $c.sha256) {
                $changed += "archivo modificado tras QA: $($c.path)"
            }
        }
        foreach ($a in $approvedSnapshot) {
            $still = @($currentSnapshot | Where-Object { $_.path -eq $a.path })
            if ($still.Count -eq 0) {
                $changed += "archivo eliminado tras QA: $($a.path)"
            }
        }
        if ($changed.Count -gt 0) {
            throw "OUTPUT_CHANGED_SINCE_QA: $($changed -join '; '). Re-ejecutar QA antes de entregar."
        }
    }
    $found = Find-PwxJob -JobId $JobId
    $outputDir = Join-Path $found.JobDir 'output'
    $deliveryDir = Join-Path $found.JobDir 'delivery'
    if (-not (Test-Path -LiteralPath $outputDir)) {
        throw "No existe carpeta output para $JobId"
    }
    if (Test-Path -LiteralPath $deliveryDir) {
        Remove-Item -LiteralPath $deliveryDir -Recurse -Force
    }
    New-PwxDirectory -Path $deliveryDir | Out-Null
    $files = @(Get-ChildItem -LiteralPath $outputDir -File -Recurse -ErrorAction SilentlyContinue)
    $manifest = @()
    foreach ($f in $files) {
        $rel = Get-PwxRelativePath -BasePath $outputDir -ChildPath $f.FullName
        $dest = Join-Path $deliveryDir $rel
        $destParent = Split-Path -Parent $dest
        New-PwxDirectory -Path $destParent | Out-Null
        Copy-Item -LiteralPath $f.FullName -Destination $dest -Force
        $manifest += [ordered]@{
            name   = ([System.IO.Path]::GetFileName($f.FullName))
            path   = $rel
            size   = $f.Length
            sha256 = Get-PwxSha256 -Path $f.FullName
        }
    }
    $deliveryManifest = [ordered]@{
        job_id         = $JobId
        created_at     = Get-PwxTimestamp
        delivered_at   = $null
        file_count     = $manifest.Count
        files          = $manifest
        output_version = (Get-PwxJobOutputVersion -JobId $JobId)
        qa_checked_at  = if ($qa) { $qa.checked_at } else { $null }
        approved_by    = $null
    }
    Set-PwxJsonFile -Path (Join-Path $deliveryDir 'delivery_manifest.json') -Object $deliveryManifest | Out-Null
    $job.delivery_manifest = $deliveryManifest
    $job.qa = Get-PwxQaResult -JobId $JobId
    Save-PwxJob -Job $job | Out-Null
    Write-PwxLog -Component 'delivery' -Message "Paquete de entrega creado para $JobId ($($manifest.Count) archivos)" -JobId $JobId
    if ($job.state -ne 'READY_FOR_DELIVERY') {
        Set-PwxJobState -JobId $JobId -To 'READY_FOR_DELIVERY' -Reason 'Delivery empaquetado' | Out-Null
    }
    return (Get-PwxDeliveryManifest -JobId $JobId)
}

function Get-PwxDeliveryManifest {
    param([string]$JobId)
    $job = Get-PwxJob -JobId $JobId
    if (-not $job) { throw "Trabajo inexistente: $JobId" }
    $found = Find-PwxJob -JobId $JobId
    $file = Join-Path $found.JobDir 'delivery\delivery_manifest.json'
    if (-not (Test-Path -LiteralPath $file)) { return $null }
    return Get-PwxJsonFile -Path $file
}

function Approve-PwxDelivery {
    param([string]$JobId, [string]$By = 'humano')
    $job = Get-PwxJob -JobId $JobId
    if (-not $job) { throw "Trabajo inexistente: $JobId" }
    $manifest = Get-PwxDeliveryManifest -JobId $JobId
    if (-not $manifest) { throw "No hay delivery para aprobar: $JobId" }
    if ($job.state -eq 'DELIVERED' -or $manifest.delivered_at) {
        Write-PwxLog -Component 'delivery' -Message "Entrega ya aprobada (no-op) para $JobId" -JobId $JobId
        return $manifest
    }
    $manifest.delivered_at = Get-PwxTimestamp
    $manifest.approved_by = $By
    $found = Find-PwxJob -JobId $JobId
    Set-PwxJsonFile -Path (Join-Path $found.JobDir 'delivery\delivery_manifest.json') -Object $manifest | Out-Null
    $job.delivery_manifest = $manifest
    Save-PwxJob -Job $job | Out-Null
    Write-PwxLog -Component 'delivery' -Message "Entrega aprobada por $By para $JobId" -JobId $JobId
    Set-PwxJobState -JobId $JobId -To 'DELIVERED' -Reason "Entrega aprobada por $By" | Out-Null
}