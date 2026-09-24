function Get-PwxOutputSnapshot {
    param([string]$JobId)
    $job = Get-PwxJob -JobId $JobId
    if (-not $job) { throw "Trabajo inexistente: $JobId" }
    $found = Find-PwxJob -JobId $JobId
    $outputDir = Join-Path $found.JobDir 'output'
    $files = @()
    if (Test-Path -LiteralPath $outputDir) {
        foreach ($f in (Get-ChildItem -LiteralPath $outputDir -File -Recurse -ErrorAction SilentlyContinue)) {
            $rel = Get-PwxRelativePath -BasePath $outputDir -ChildPath $f.FullName
            if ($rel) {
                $files += [pscustomobject]@{
                    name   = $f.Name
                    path   = $rel
                    size   = $f.Length
                    sha256 = Get-PwxSha256 -Path $f.FullName
                    full   = $f.FullName
                }
            }
        }
    }
    return $files
}

function Invoke-PwxQa {
    param(
        [Parameter(Mandatory)][string]$JobId
    )
    $job = Get-PwxJob -JobId $JobId
    if (-not $job) { throw "Trabajo inexistente: $JobId" }
    if (-not $job.requirements) { throw "Trabajo sin requisitos: $JobId" }
    $found = Find-PwxJob -JobId $JobId
    $outputDir = Join-Path $found.JobDir 'output'

    $checks = @()
    $requiredOutput = @($job.requirements.required_output)
    if ($requiredOutput.Count -eq 0) {
        $requiredOutput = @('*')
    }
    $allOutput = @(Get-PwxOutputSnapshot -JobId $JobId)

    if (-not (Test-Path -LiteralPath $outputDir)) {
        $checks += [pscustomobject]@{ check = 'output_dir_exists'; ok = $false; detail = 'No existe carpeta output' }
    }
    else {
        $checks += [pscustomobject]@{ check = 'output_dir_exists'; ok = $true; detail = $outputDir }
        $checks += [pscustomobject]@{ check = 'output_not_empty'; ok = ($allOutput.Count -gt 0); detail = "Archivos: $($allOutput.Count)" }
        foreach ($tot in $requiredOutput) {
            $pattern = $tot
            $matched = @()
            if ($pattern -eq '*') {
                $matched = $allOutput
            }
            else {
                $matched = @($allOutput | Where-Object { $_.name -like $pattern -or $_.path -like $pattern })
            }
            $checks += [pscustomobject]@{ check = "required_output:$pattern"; ok = ($matched.Count -gt 0); detail = (($matched | ForEach-Object { $_.path }) -join ', ') }
        }
        foreach ($f in $allOutput) {
            $checks += [pscustomobject]@{ check = "file_nonempty:$($f.path)"; ok = ($f.size -gt 0); detail = "Bytes: $($f.size)" }
        }
    }

    $svc = Get-PwxService -ServiceId $job.requirements.service
    if ($svc -and $svc.contract -and $svc.contract.validators) {
        foreach ($v in @($svc.contract.validators)) {
            $cmd = Get-Command $v -ErrorAction SilentlyContinue
            if (-not $cmd) {
                $checks += [pscustomobject]@{ check = "validator_missing:$v"; ok = $false; detail = 'Validador especifico no registrado' }
            }
            else {
                $vres = & $v -JobId $JobId
                $checks += [pscustomobject]@{ check = "validator:$v"; ok = ([bool]$vres.ok); detail = $vres.detail }
            }
        }
    }

    $failed = @($checks | Where-Object { -not $_.ok })
    $verdict = if ($failed.Count -eq 0) { 'PASS' } else { 'FAIL' }
    $qa = [ordered]@{
        job_id       = $JobId
        verdict      = $verdict
        checked_at   = Get-PwxTimestamp
        checks       = $checks
        output_files = $allOutput
    }
    Set-PwxJsonFile -Path (Join-Path $found.JobDir 'qa\qa.json') -Object $qa | Out-Null
    $job.qa = $qa
    Save-PwxJob -Job $job | Out-Null
    Write-PwxLog -Component 'qa' -Message "QA para $JobId : $verdict ($failed.Count fallos)" -JobId $JobId
    return $qa
}

function Get-PwxQaResult {
    param([string]$JobId)
    $job = Get-PwxJob -JobId $JobId
    if (-not $job) { throw "Trabajo inexistente: $JobId" }
    $found = Find-PwxJob -JobId $JobId
    $qaFile = Join-Path $found.JobDir 'qa\qa.json'
    if (-not (Test-Path -LiteralPath $qaFile)) { return $null }
    return Get-PwxJsonFile -Path $qaFile
}