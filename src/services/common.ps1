# Utilidades compartidas entre servicios (resolucion de entrada, resultados).
# Cargado por bootstrap antes que los servicios.

function New-PwxServiceError {
    param([string]$Code, [string]$Detail = '')
    if ([string]::IsNullOrWhiteSpace($Detail)) {
        return [pscustomobject]@{ ok = $false; code = $Code; detail = $null }
    }
    return [pscustomobject]@{ ok = $false; code = $Code; detail = $Detail }
}

function New-PwxServiceValidation {
    param([bool]$Ok, [string]$Detail = '')
    return [pscustomobject]@{ ok = $Ok; detail = $Detail }
}

# Lineas de un archivo de texto (.txt/.md) como lista de parrafos.
# Separa por LF/CRLF conservando lineas vacias intermedias.
function Get-PwxTextFileParagraphs {
    param([Parameter(Mandatory)][string]$Path)
    $text = [System.IO.File]::ReadAllText($Path)
    $text = $text -replace "`r`n", "`n" -replace "`r", "`n"
    if ($text -eq '') { return @() }
    return @($text -split "`n")
}

# Parrafos deterministas desde la especificacion de requisitos:
# objetivo como primer parrafo + constraints como viñetas "- ".
function Get-PwxTextSpecParagraphs {
    param($Job)
    $paragraphs = @()
    if ($Job -and $Job.requirements) {
        $objective = [string]$Job.requirements.objective
        if (-not [string]::IsNullOrWhiteSpace($objective)) {
            $paragraphs += $objective.Trim()
        }
        foreach ($c in @($Job.requirements.constraints)) {
            $cs = [string]$c
            if (-not [string]::IsNullOrWhiteSpace($cs)) {
                $paragraphs += ('- ' + $cs.Trim())
            }
        }
    }
    return @($paragraphs)
}

# Resolucion de entrada para servicios de texto (word/pdf):
# 1. requirements.input_files == 1 y existe en job/input/ -> ese.
# 2. Sin candidato y job/input/ tiene 1 archivo -> ese; varios -> unico .txt/.md si lo hay.
# 3. Sin archivo de entrada -> fallback a la especificacion (objetivo + constraints).
# Extensiones aceptadas: .txt .md (solo cuando hay archivo).
function Resolve-PwxTextJobSource {
    param(
        [Parameter(Mandatory)][string]$JobId,
        [Parameter(Mandatory)][string]$CodePrefix
    )
    $found = Find-PwxJob -JobId $JobId
    if (-not $found) {
        return (New-PwxServiceError -Code ("${CodePrefix}_INTERNAL") -Detail "Job inexistente: $JobId")
    }
    $inputDir = Join-Path $found.JobDir 'input'
    $files = @()
    if (Test-Path -LiteralPath $inputDir) {
        $files = @(Get-ChildItem -LiteralPath $inputDir -File -ErrorAction SilentlyContinue)
    }

    $job = Get-PwxJob -JobId $JobId
    $candidates = @()
    if ($job.requirements -and $job.requirements.input_files) {
        $candidates = @($job.requirements.input_files | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }

    $chosen = $null
    if ($candidates.Count -eq 1) {
        $name = [string]$candidates[0]
        try {
            Assert-PwxSafeFileName -Name $name | Out-Null
        }
        catch {
            return (New-PwxServiceError -Code ("${CodePrefix}_BAD_INPUT") -Detail "Nombre de input del requisito invalido: $name")
        }
        $candidatePath = Join-Path $inputDir $name
        $safeCandidate = Assert-PwxSafeWorkspacePath -WorkspacePath $found.JobDir -Path $candidatePath
        if (Test-Path -LiteralPath $safeCandidate -PathType Leaf) {
            $chosen = $safeCandidate
        }
    }

    if ($null -eq $chosen -and $files.Count -eq 1) {
        $chosen = $files[0].FullName
    }
    elseif ($null -eq $chosen -and $files.Count -gt 1) {
        $textFiles = @($files | Where-Object { $_.Extension -match '^(\.txt|\.md)$' } | Sort-Object -Property Name)
        if ($textFiles.Count -eq 1) {
            $chosen = $textFiles[0].FullName
        }
        else {
            return (New-PwxServiceError -Code ("${CodePrefix}_MULTIPLE_INPUTS") -Detail ("Varios archivos en input sin unico candidato en requisitos: " + (($files | ForEach-Object { $_.Name }) -join ', ')))
        }
    }

    if ($null -eq $chosen) {
        $paragraphs = Get-PwxTextSpecParagraphs -Job $job
        if ($paragraphs.Count -eq 0) {
            return (New-PwxServiceError -Code ("${CodePrefix}_NO_INPUT") -Detail 'Sin archivo de entrada ni objetivo en requisitos')
        }
        return [pscustomobject]@{
            ok         = $true
            code       = $null
            detail     = $null
            path       = $null
            source     = 'spec'
            paragraphs = $paragraphs
        }
    }

    if ([System.IO.Path]::GetExtension($chosen) -notmatch '^(\.txt|\.md)$') {
        return (New-PwxServiceError -Code ("${CodePrefix}_UNSUPPORTED_FORMAT") -Detail ("Formato no soportado: " + [System.IO.Path]::GetExtension($chosen)))
    }
    return [pscustomobject]@{
        ok         = $true
        code       = $null
        detail     = $null
        path       = $chosen
        source     = 'file'
        paragraphs = $null
    }
}

# Parrafos esperados para el QA de word/pdf (mismo camino que el servicio).
# Devuelve $null si la fuente ya no esta disponible.
function Get-PwxTextExpectedParagraphs {
    param([Parameter(Mandatory)][string]$JobId)
    $r = Resolve-PwxTextJobSource -JobId $JobId -CodePrefix 'TEXT'
    if (-not $r.ok) { return $null }
    if ($r.source -eq 'file') {
        return @(Get-PwxTextFileParagraphs -Path $r.path)
    }
    return @($r.paragraphs)
}

# Compra secuencias de parrafos con igualdad ordinal (sin normalizar).
function Compare-PwxParagraphSequence {
    param([string[]]$Expected, [string[]]$Actual)
    if ($null -eq $Expected) {
        return (New-PwxServiceValidation $false 'Fuente esperada no disponible para comparar')
    }
    if ($null -eq $Actual) {
        return (New-PwxServiceValidation $false 'Salida sin parrafos legibles')
    }
    if ($Expected.Count -ne $Actual.Count) {
        return (New-PwxServiceValidation $false ("Parrafos distintos: esperado " + $Expected.Count + ", obtenido " + $Actual.Count))
    }
    for ($i = 0; $i -lt $Expected.Count; $i++) {
        if (-not [string]::Equals($Expected[$i], $Actual[$i], [System.StringComparison]::Ordinal)) {
            $e = $Expected[$i]; $a = $Actual[$i]
            if ($e.Length -gt 60) { $e = $e.Substring(0, 60) + '...' }
            if ($a.Length -gt 60) { $a = $a.Substring(0, 60) + '...' }
            return (New-PwxServiceValidation $false ("Parrafo $i distinto: esperado '$e', obtenido '$a'"))
        }
    }
    return (New-PwxServiceValidation $true ("Parrafos identicos (" + $Expected.Count + ")"))
}
