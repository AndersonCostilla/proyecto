function ConvertTo-PwxUtc {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    try {
        $dt = [datetime]::Parse($Value, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
        return $dt.ToUniversalTime().ToString('o')
    }
    catch {
        return ([DateTime]::UtcNow).ToString('o')
    }
}

function Get-PwxUtcTimestamp {
    return ([DateTime]::UtcNow).ToString('o')
}

function Write-PwxChecksums {
    param([string]$DeliveryDir)
    $cksumLines = @()
    foreach ($f in (Get-ChildItem -LiteralPath $DeliveryDir -File -Recurse | Sort-Object -Property FullName -CaseSensitive:$false)) {
        $rel = Get-PwxRelativePath -BasePath $DeliveryDir -ChildPath $f.FullName
        if ($rel -and $rel -ne 'checksums.sha256') {
            $cksumLines += ('{0}  {1}' -f (Get-PwxSha256 -Path $f.FullName), $rel)
        }
    }
    [System.IO.File]::WriteAllText((Join-Path $DeliveryDir 'checksums.sha256'), (($cksumLines -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding($false)))
}

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
    foreach ($f in $files) {
        $rel = Get-PwxRelativePath -BasePath $outputDir -ChildPath $f.FullName
        $dest = Join-Path $deliveryDir $rel
        $destParent = Split-Path -Parent $dest
        New-PwxDirectory -Path $destParent | Out-Null
        Copy-Item -LiteralPath $f.FullName -Destination $dest -Force
    }

    $snapshot = @(Get-PwxOutputSnapshot -JobId $JobId | Sort-Object -Property path -CaseSensitive:$false)
    $outputList = @()
    $deliverables = @()
    foreach ($o in $snapshot) {
        $outputList += [ordered]@{
            name   = $o.name
            path   = $o.path
            sha256 = $o.sha256
            bytes  = $o.size
        }
        $deliverables += [ordered]@{
            name   = $o.name
            path   = $o.path
            size   = $o.size
            sha256 = $o.sha256
        }
    }

    $inputList = @()
    foreach ($in in @($job.files.input)) {
        $inFull = Join-Path $found.JobDir $in.path
        try { $inFull = Assert-PwxSafeWorkspacePath -WorkspacePath $found.JobDir -Path $inFull } catch { continue }
        if (-not (Test-Path -LiteralPath $inFull)) { continue }
        $inputList += [ordered]@{
            name   = $in.name
            path   = (Get-PwxRelativePath -BasePath $found.JobDir -ChildPath $inFull)
            sha256 = Get-PwxSha256 -Path $inFull
            bytes  = (Get-Item -LiteralPath $inFull).Length
        }
    }
    $inputList = @($inputList | Sort-Object -Property name -CaseSensitive:$false)

    $qaSection = [ordered]@{}
    $qaSection.verdict = if ($qa) { $qa.verdict } else { 'NONE' }
    $qaSection.at_utc = if ($qa) { ConvertTo-PwxUtc -Value $qa.checked_at } else { $null }
    if ((-not $qa) -or $qa.verdict -ne 'PASS') {
        $qaSection.code = if ($qa) { 'QA_NOT_PASS' } else { 'QA_NOT_RUN' }
        if ($qa -and $qa.code) { $qaSection.code = $qa.code }
        $qaSection.detail = 'Delivery AllowFail sin QA PASS'
        if ($qa) {
            $failDetails = @($qa.checks | Where-Object { -not $_.ok } | ForEach-Object { $_.detail } | Where-Object { $_ })
            $qaSection.detail = if ($qa.detail) { $qa.detail } else { ($failDetails -join '; ') }
        }
    }

    $deliveryManifest = [ordered]@{
        schema_version = '1'
        job_id         = $JobId
        client_id      = $found.ClientId
        service        = $job.service
        created_utc    = Get-PwxUtcTimestamp
        inputs         = $inputList
        outputs        = $outputList
        qa             = $qaSection
        notes          = @($job.notes)
        output_version = (Get-PwxJobOutputVersion -JobId $JobId)
        file_count     = $deliverables.Count
        files          = $deliverables
        created_at     = Get-PwxTimestamp
        delivered_at   = $null
        qa_checked_at  = if ($qa) { $qa.checked_at } else { $null }
        approved_by    = $null
    }
    Set-PwxJsonFile -Path (Join-Path $deliveryDir 'manifest.json') -Object $deliveryManifest | Out-Null

    Write-PwxChecksums -DeliveryDir $deliveryDir

    $job.delivery_manifest = $deliveryManifest
    $job.qa = Get-PwxQaResult -JobId $JobId
    Save-PwxJob -Job $job | Out-Null
    Write-PwxLog -Component 'delivery' -Message "Paquete de entrega creado para $JobId ($($deliverables.Count) archivos, manifest.json + checksums.sha256)" -JobId $JobId
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
    $file = Join-Path $found.JobDir 'delivery\manifest.json'
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
    Set-PwxJsonFile -Path (Join-Path $found.JobDir 'delivery\manifest.json') -Object $manifest | Out-Null
    Write-PwxChecksums -DeliveryDir (Join-Path $found.JobDir 'delivery')
    $job.delivery_manifest = $manifest
    Save-PwxJob -Job $job | Out-Null
    Write-PwxLog -Component 'delivery' -Message "Entrega aprobada por $By para $JobId" -JobId $JobId
    Set-PwxJobState -JobId $JobId -To 'DELIVERED' -Reason "Entrega aprobada por $By" | Out-Null
}