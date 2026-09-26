# data-service: limpieza y normalizacion determinista de CSV.
# Entrada: job/input/*.csv (unico). Salidas: datos-limpios.csv + informe-limpieza.txt
# Sin LLM: todas las transformaciones son reglas fijas y verificables.

$ErrorActionPreference = 'Stop'

$PwxDataOutputCleanName = 'datos-limpios.csv'
$PwxDataOutputReportName = 'informe-limpieza.txt'
$PwxDataMaxRows = 200000
$PwxDataMaxCells = 2000000
$PwxDataDelimiter = ','

# Parser CSV RFC4180 propio (comillas, comillas dobles, CRLF/LF) con
# deteccion de delimitador ( , ; ) sobre la primera linea logica.
function Read-PwxCsvTable {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        return (New-PwxServiceError -Code 'DATA_NO_INPUT' -Detail "Archivo inexistente: $Path")
    }
    $text = [System.IO.File]::ReadAllText($Path)
    if ([string]::IsNullOrWhiteSpace($text)) {
        return (New-PwxServiceError -Code 'DATA_EMPTY_INPUT' -Detail 'Archivo vacio')
    }

    # Deteccion de delimitador (ignorando comillas)
    $scan = New-Object System.Text.StringBuilder
    $inQ = $false
    foreach ($ch in $text.ToCharArray()) {
        if ($ch -eq "`n") { break }
        if ($ch -eq '"') { $inQ = -not $inQ }
        if (-not $inQ) { [void]$scan.Append($ch) }
        else { [void]$scan.Append(' ') }
    }
    $scanText = $scan.ToString()
    $delim = $PwxDataDelimiter
    if (([regex]::Matches($scanText, [regex]::Escape(';')).Count) -gt ([regex]::Matches($scanText, [regex]::Escape(',')).Count)) {
        $delim = ';'
    }

    $rows = New-Object System.Collections.ArrayList
    $row = New-Object System.Collections.ArrayList
    $field = New-Object System.Text.StringBuilder
    $inQuotes = $false
    $chars = $text.ToCharArray()
    $i = 0
    while ($i -lt $chars.Length) {
        $ch = $chars[$i]
        if ($inQuotes) {
            if ($ch -eq '"') {
                if (($i + 1) -lt $chars.Length -and $chars[$i + 1] -eq '"') {
                    [void]$field.Append('"')
                    $i += 2
                    continue
                }
                $inQuotes = $false
                $i++
                continue
            }
            [void]$field.Append($ch)
            $i++
            continue
        }
        if ($ch -eq '"' -and $field.Length -eq 0) {
            $inQuotes = $true
            $i++
            continue
        }
        if ($ch -eq $delim) {
            [void]$row.Add($field.ToString())
            [void]$field.Clear()
            $i++
            continue
        }
        if ($ch -eq "`r" -or $ch -eq "`n") {
            if ($ch -eq "`r" -and (($i + 1) -lt $chars.Length) -and $chars[$i + 1] -eq "`n") { $i += 2 }
            else { $i++ }
            [void]$row.Add($field.ToString())
            [void]$field.Clear()
            [void]$rows.Add(@($row.ToArray()))
            $row = New-Object System.Collections.ArrayList
            continue
        }
        [void]$field.Append($ch)
        $i++
    }
    if ($inQuotes) {
        return (New-PwxServiceError -Code 'DATA_BAD_CSV' -Detail 'Comilla sin cerrar')
    }
    if ($field.Length -gt 0 -or $row.Count -gt 0) {
        [void]$row.Add($field.ToString())
        [void]$rows.Add(@($row.ToArray()))
    }

    if ($rows.Count -lt 1) {
        return (New-PwxServiceError -Code 'DATA_EMPTY_INPUT' -Detail 'Sin fila de encabezados')
    }
    if ($rows.Count -gt ($PwxDataMaxRows + 1)) {
        return (New-PwxServiceError -Code 'DATA_LIMITS_EXCEEDED' -Detail "Mas de $PwxDataMaxRows filas")
    }

    $headers = @($rows[0] | ForEach-Object { [string]$_ })
    $dataRows = @()
    for ($r = 1; $r -lt $rows.Count; $r++) {
        $dataRows += , @($rows[$r] | ForEach-Object { [string]$_ })
    }
    return [pscustomobject]@{
        ok        = $true
        code      = $null
        detail    = $null
        delimiter = $delim
        headers   = $headers
        rows      = $dataRows
    }
}

function ConvertTo-PwxCsvField {
    param([string]$Value, [string]$Delimiter)
    if ($null -eq $Value) { return '' }
    $need = ($Value -match [regex]::Escape($Delimiter)) -or ($Value.Contains('"')) -or ($Value.Contains("`n")) -or ($Value.Contains("`r"))
    if ($need) { return '"' + $Value.Replace('"', '""') + '"' }
    return $Value
}

# Escritor determinista: comillas solo si hace falta, LF, UTF-8 sin BOM.
function Write-PwxCsvTable {
    param([string]$Path, [string[]]$Headers, [array]$Rows, [string]$Delimiter = $PwxDataDelimiter)
    $sb = New-Object System.Text.StringBuilder
    $hCells = @($Headers | ForEach-Object { ConvertTo-PwxCsvField -Value $_ -Delimiter $Delimiter })
    [void]$sb.Append(($hCells -join $Delimiter) + "`n")
    foreach ($r in @($Rows)) {
        $cells = @()
        foreach ($c in @($r)) { $cells += (ConvertTo-PwxCsvField -Value ([string]$c) -Delimiter $Delimiter) }
        [void]$sb.Append(($cells -join $Delimiter) + "`n")
    }
    $dir = [System.IO.Path]::GetDirectoryName($Path)
    if (-not [string]::IsNullOrEmpty($dir)) { New-PwxDirectory -Path $dir | Out-Null }
    [System.IO.File]::WriteAllText($Path, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))
}

function ConvertTo-PwxDataNormalizedHeader {
    param([string]$Header, [int]$Index)
    $h = $Header
    $h = $h -replace "[\t ]+", ' '
    $h = $h.Trim()
    if ($h -eq '') { return 'columna_' + ($Index + 1) }
    return $h
}

# Pipeline de limpieza (determinista, sin LLM):
# 1) encabezados: trim + colapso de espacios + dedupe (sufijo _2, _3...)
# 2) celdas: trim + colapso de espacios internos
# 3) columnas de correo: valor en minusculas
# 4) filas 100% vacias -> fuera
# 5) duplicados exactos (tras normalizar) -> fuera (se conserva la primera)
function Invoke-PwxDataCleanTable {
    param([string[]]$Headers, [array]$Rows)

    $cleanHeaders = @()
    $seenHeader = @{}
    for ($i = 0; $i -lt $Headers.Count; $i++) {
        $h = ConvertTo-PwxDataNormalizedHeader -Header $Headers[$i] -Index $i
        $key = $h.ToLowerInvariant()
        if ($seenHeader.ContainsKey($key)) {
            $n = $seenHeader[$key] + 1
            $seenHeader[$key] = $n
            $candidate = $h + '_' + $n
            while ($seenHeader.ContainsKey($candidate.ToLowerInvariant())) {
                $n++
                $candidate = $h + '_' + $n
            }
            $h = $candidate
            $seenHeader[$h.ToLowerInvariant()] = 1
        }
        else {
            $seenHeader[$key] = 1
        }
        $cleanHeaders += $h
    }

    $emailCols = @()
    for ($i = 0; $i -lt $cleanHeaders.Count; $i++) {
        if ($cleanHeaders[$i] -match '(?i)mail|correo') { $emailCols += $i }
    }

    $outRows = @()
    $seenRow = @{}
    $duplicates = 0
    $empties = 0
    $padded = 0
    foreach ($raw in @($Rows)) {
        $cells = @()
        $rowArr = @($raw)
        $colCount = $cleanHeaders.Count
        if ($rowArr.Count -ne $colCount) { $padded++ }
        for ($i = 0; $i -lt $colCount; $i++) {
            $v = ''
            if ($i -lt $rowArr.Count) { $v = [string]$rowArr[$i] }
            $v = $v -replace "[\t   ]+", ' '
            $v = $v.Trim()
            if (($emailCols -contains $i) -and $v -ne '') { $v = $v.ToLowerInvariant() }
            $cells += $v
        }
        $allEmpty = $true
        foreach ($c in $cells) { if ($c -ne '') { $allEmpty = $false; break } }
        if ($allEmpty) { $empties++; continue }
        $key = $cells -join [char]31
        if ($seenRow.ContainsKey($key)) { $duplicates++; continue }
        $seenRow[$key] = $true
        $outRows += , @($cells)
    }

    if ($outRows.Count -gt $PwxDataMaxRows) {
        return (New-PwxServiceError -Code 'DATA_LIMITS_EXCEEDED' -Detail "Mas de $PwxDataMaxRows filas tras limpiar")
    }

    return [pscustomobject]@{
        ok          = $true
        code        = $null
        detail      = $null
        headers     = @($cleanHeaders)
        rows        = $outRows
        rows_in     = @($Rows).Count
        rows_out    = $outRows.Count
        duplicates  = $duplicates
        empties     = $empties
        padded      = $padded
    }
}

function New-PwxDataReportText {
    param($JobId, $Delimiter, $Clean)
    $lines = @(
        'informe de limpieza de datos'
        ('job: ' + $JobId)
        ('delimitador_entrada: ' + $Delimiter)
        ('columnas: ' + $Clean.headers.Count)
        ('filas_entrada: ' + $Clean.rows_in)
        ('filas_salida: ' + $Clean.rows_out)
        ('duplicadas_removidas: ' + $Clean.duplicates)
        ('vacias_removidas: ' + $Clean.empties)
        ('filas_ajustadas: ' + $Clean.padded)
    )
    return ($lines -join "`n") + "`n"
}

function Resolve-PwxDataInputFile {
    param([string]$JobId)
    $found = Find-PwxJob -JobId $JobId
    if (-not $found) { return (New-PwxServiceError -Code 'DATA_INTERNAL' -Detail "Job inexistente: $JobId") }
    $inputDir = Join-Path $found.JobDir 'input'
    if (-not (Test-Path -LiteralPath $inputDir)) {
        return (New-PwxServiceError -Code 'DATA_NO_INPUT' -Detail 'Sin carpeta input')
    }
    $files = @(Get-ChildItem -LiteralPath $inputDir -File -ErrorAction SilentlyContinue)

    $job = Get-PwxJob -JobId $JobId
    $candidates = @()
    if ($job.requirements -and $job.requirements.input_files) {
        $candidates = @($job.requirements.input_files | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }

    $chosen = $null
    if ($candidates.Count -eq 1) {
        $name = [string]$candidates[0]
        try { Assert-PwxSafeFileName -Name $name | Out-Null }
        catch { return (New-PwxServiceError -Code 'DATA_BAD_INPUT' -Detail "Nombre de input del requisito invalido: $name") }
        $candidatePath = Join-Path $inputDir $name
        $safeCandidate = Assert-PwxSafeWorkspacePath -WorkspacePath $found.JobDir -Path $candidatePath
        if (Test-Path -LiteralPath $safeCandidate -PathType Leaf) { $chosen = $safeCandidate }
    }

    if ($null -eq $chosen -and $files.Count -eq 1) { $chosen = $files[0].FullName }
    elseif ($null -eq $chosen -and $files.Count -gt 1) {
        return (New-PwxServiceError -Code 'DATA_MULTIPLE_INPUTS' -Detail ("Varios archivos en input sin unico candidato en requisitos: " + (($files | ForEach-Object { $_.Name }) -join ', ')))
    }
    if ($null -eq $chosen) {
        return (New-PwxServiceError -Code 'DATA_NO_INPUT' -Detail 'No hay archivo de entrada en job/input/')
    }
    if ([System.IO.Path]::GetExtension($chosen) -notmatch '^\.csv$') {
        return (New-PwxServiceError -Code 'DATA_UNSUPPORTED_FORMAT' -Detail ("Formato no soportado: " + [System.IO.Path]::GetExtension($chosen)))
    }
    return [pscustomobject]@{ ok = $true; code = $null; detail = $null; path = $chosen }
}

# Contrato del servicio: @{ ok=$true|$false; error=$null|<codigo> }
function Invoke-PwxService_data_service {
    param([string]$JobId)
    try {
        $resolve = Resolve-PwxDataInputFile -JobId $JobId
        if (-not $resolve.ok) {
            return [pscustomobject]@{ ok = $false; error = $resolve.code }
        }

        $table = Read-PwxCsvTable -Path $resolve.path
        if (-not $table.ok) {
            return [pscustomobject]@{ ok = $false; error = $table.code }
        }
        if (@($table.headers).Count -eq 0) {
            return [pscustomobject]@{ ok = $false; error = 'DATA_EMPTY_INPUT' }
        }

        $clean = Invoke-PwxDataCleanTable -Headers $table.headers -Rows $table.rows
        if (-not $clean.ok) {
            return [pscustomobject]@{ ok = $false; error = $clean.code }
        }

        $found = Find-PwxJob -JobId $JobId
        $outputDir = Join-Path $found.JobDir 'output'
        New-PwxDirectory -Path $outputDir | Out-Null

        $cleanPath = Join-Path $outputDir $PwxDataOutputCleanName
        Write-PwxCsvTable -Path $cleanPath -Headers $clean.headers -Rows $clean.rows -Delimiter ','
        $reportPath = Join-Path $outputDir $PwxDataOutputReportName
        [System.IO.File]::WriteAllText($reportPath, (New-PwxDataReportText -JobId $JobId -Delimiter $table.delimiter -Clean $clean), (New-Object System.Text.UTF8Encoding($false)))

        if (-not (Test-Path -LiteralPath $cleanPath) -or -not (Test-Path -LiteralPath $reportPath)) {
            return [pscustomobject]@{ ok = $false; error = 'DATA_INTERNAL' }
        }

        Add-PwxJobFile -JobId $JobId -Bucket 'output' -Path $cleanPath | Out-Null
        Add-PwxJobFile -JobId $JobId -Bucket 'output' -Path $reportPath | Out-Null

        $sha = Get-PwxSha256 -Path $cleanPath
        Add-PwxEvent -JobId $JobId -Component 'service.data' -Action 'data.cleaned' -Data @{
            files      = @($PwxDataOutputCleanName, $PwxDataOutputReportName)
            rows_in    = $clean.rows_in
            rows_out   = $clean.rows_out
            duplicates = $clean.duplicates
            empties    = $clean.empties
            sha256     = $sha
        }
        Write-PwxLog -Component 'service.data' -Message "data-service genero $($clean.rows_out) filas para $JobId (entrada=$($clean.rows_in), dup=$($clean.duplicates), vacias=$($clean.empties), sha256=$sha)" -JobId $JobId

        return [pscustomobject]@{
            ok       = $true
            error    = $null
            files    = @($PwxDataOutputCleanName, $PwxDataOutputReportName)
            rows_in  = $clean.rows_in
            rows_out = $clean.rows_out
            sha256   = $sha
        }
    }
    catch {
        Write-PwxLog -Component 'service.data' -Level 'ERROR' -Message "data-service fallo: $($_.Exception.Message)" -JobId $JobId
        return [pscustomobject]@{ ok = $false; error = 'DATA_INTERNAL' }
    }
}

# Validador QA: la salida debe ser exactamente limpiar(input); informe consistente.
function Test-PwxDataOutput {
    param([string]$JobId)
    try {
        $snap = @(Get-PwxOutputSnapshot -JobId $JobId)
        $cleanOut = @($snap | Where-Object { $_.name -eq $PwxDataOutputCleanName })
        $reportOut = @($snap | Where-Object { $_.name -eq $PwxDataOutputReportName })
        if ($cleanOut.Count -ne 1) { return (New-PwxServiceValidation $false "Se esperaba exactamente 1 $PwxDataOutputCleanName en output/") }
        if ($reportOut.Count -ne 1) { return (New-PwxServiceValidation $false "Se esperaba exactamente 1 $PwxDataOutputReportName en output/") }

        $resolve = Resolve-PwxDataInputFile -JobId $JobId
        if (-not $resolve.ok) {
            return (New-PwxServiceValidation $false "$($resolve.code): $($resolve.detail)")
        }

        $table = Read-PwxCsvTable -Path $resolve.path
        if (-not $table.ok) {
            return (New-PwxServiceValidation $false "$($table.code): $($table.detail)")
        }
        $clean = Invoke-PwxDataCleanTable -Headers $table.headers -Rows $table.rows
        if (-not $clean.ok) {
            return (New-PwxServiceValidation $false "$($clean.code): $($clean.detail)")
        }

        $actual = Read-PwxCsvTable -Path $cleanOut[0].full
        if (-not $actual.ok) {
            return (New-PwxServiceValidation $false "Salida ilegible: $($actual.code)")
        }
        if (@($actual.headers).Count -ne @($clean.headers).Count) {
            return (New-PwxServiceValidation $false 'Encabezados con distinta cantidad')
        }
        for ($i = 0; $i -lt $clean.headers.Count; $i++) {
            if (-not [string]::Equals($clean.headers[$i], $actual.headers[$i], [System.StringComparison]::Ordinal)) {
                return (New-PwxServiceValidation $false "Encabezado $i distinto: '$($clean.headers[$i])' vs '$($actual.headers[$i])'")
            }
        }
        if (@($actual.rows).Count -ne @($clean.rows).Count) {
            return (New-PwxServiceValidation $false ("Filas distintas: esperado " + @($clean.rows).Count + ", obtenido " + @($actual.rows).Count))
        }
        for ($r = 0; $r -lt $clean.rows.Count; $r++) {
            $er = @($clean.rows[$r])
            $ar = @($actual.rows[$r])
            if ($er.Count -ne $ar.Count) {
                return (New-PwxServiceValidation $false "Fila $r con distinta cantidad de columnas")
            }
            for ($c = 0; $c -lt $er.Count; $c++) {
                if (-not [string]::Equals($er[$c], $ar[$c], [System.StringComparison]::Ordinal)) {
                    return (New-PwxServiceValidation $false "Fila $r col $c distinta: '$($er[$c])' vs '$($ar[$c])'")
                }
            }
        }

        $report = [System.IO.File]::ReadAllText($reportOut[0].full)
        if ($report -notmatch ('filas_salida: ' + $clean.rows_out + "`n")) {
            return (New-PwxServiceValidation $false 'Informe no coincide con filas_salida real')
        }
        if ($report -notmatch ('filas_entrada: ' + $clean.rows_in + "`n")) {
            return (New-PwxServiceValidation $false 'Informe no coincide con filas_entrada real')
        }
        return (New-PwxServiceValidation $true ("Salida == limpiar(input); filas=" + $clean.rows_out))
    }
    catch {
        return (New-PwxServiceValidation $false "DATA_INTERNAL: $($_.Exception.Message)")
    }
}
