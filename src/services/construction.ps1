# construction-service: computos y presupuestos de obra deterministas.
# Entrada: job/input/*.csv de partidas con columnas flexibles (es/en):
#   partida?, descripcion, unidad, cantidad, precio_unitario
# Salida: output/presupuesto.xlsx (reutiliza el escritor XLSX determinista).
# Los totales se calculan en codigo (nunca el LLM): suma de cantidades *
# precios unitarios redondeados a 2 decimales (AwayFromZero).

$ErrorActionPreference = 'Stop'

$PwxConstructionOutputName = 'presupuesto.xlsx'
$PwxConstructionMaxRows = 10000

function Initialize-PwxConstructionTypes {
    Initialize-PwxExcelTypes
}

function ConvertTo-PwxConstructionAsciiKey {
    param([string]$Header)
    $h = $Header.Normalize([System.Text.NormalizationForm]::FormD)
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $h.ToCharArray()) {
        $cat = [System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($ch)
        if ($cat -eq [System.Globalization.UnicodeCategory]::NonSpacingMark) { continue }
        [void]$sb.Append($ch)
    }
    $k = $sb.ToString().ToLowerInvariant()
    $k = $k -replace '[^a-z0-9]+', '_'
    $k = $k.Trim('_')
    return $k
}

# Mapeo determinista de encabezados -> campos canonicos.
function Get-PwxConstructionHeaderMap {
    param([string[]]$Headers)
    $rules = [ordered]@{
        descripcion = @('descripcion', 'description', 'concepto', 'detalle', 'item', 'nombre', 'obra')
        unidad      = @('unidad', 'unit', 'u', 'um', 'medida')
        cantidad    = @('cantidad', 'quantity', 'qty', 'cant', 'volumen')
        precio      = @('precio_unitario', 'precio', 'price', 'pu', 'costo_unitario', 'valor_unitario', 'valor', 'costo')
        partida     = @('partida', 'codigo', 'id', 'n', 'numero')
    }
    $map = @{}
    $keys = @()
    foreach ($h in $Headers) { $keys += (ConvertTo-PwxConstructionAsciiKey -Header $h) }

    foreach ($field in $rules.Keys) {
        $list = $rules[$field]
        # 1) coincidencia exacta
        foreach ($alias in $list) {
            for ($i = 0; $i -lt $keys.Count; $i++) {
                if ($keys[$i] -eq $alias -and -not $map.ContainsKey($i)) {
                    $map[$i] = $field
                    break
                }
            }
            if ($map.Values -contains $field) { break }
        }
        # 2) coincidencia por contenido
        if (-not ($map.Values -contains $field)) {
            foreach ($alias in $list) {
                for ($i = 0; $i -lt $keys.Count; $i++) {
                    if (-not $map.ContainsKey($i) -and $keys[$i] -match [regex]::Escape($alias)) {
                        $map[$i] = $field
                        break
                    }
                }
                if ($map.Values -contains $field) { break }
            }
        }
    }
    return $map
}

# Numero tolerante: separador decimal '.' o ',' (el ultimo separador visto es
# el decimal), miles opcionales, signo y texto monetary basico ($, COP).
function ConvertFrom-PwxConstructionNumber {
    param([string]$Raw, [string]$Field, [int]$Row)
    if ($null -eq $Raw) { $Raw = '' }
    $s = $Raw.Trim() -replace '[\s ]', ''
    $s = $s -replace '(?i)cop', ''
    $s = $s.Replace('$', '')
    if ($s -eq '') {
        throw "CONSTRUCTION_BAD_INPUT: fila $Row, campo $Field vacio"
    }
    $lastDot = $s.LastIndexOf('.')
    $lastComma = $s.LastIndexOf(',')
    if ($lastDot -ge 0 -and $lastComma -ge 0) {
        if ($lastComma -gt $lastDot) {
            # decimal con coma: quitar puntos de miles
            $s = $s.Replace('.', '').Replace(',', '.')
        }
        else {
            $s = $s.Replace(',', '')
        }
    }
    elseif ($lastComma -ge 0) {
        # solo comas: la ultima coma es decimal
        $idx = $s.LastIndexOf(',')
        $s = $s.Substring(0, $idx).Replace(',', '') + '.' + $s.Substring($idx + 1)
    }
    $v = 0.0
    if (-not [double]::TryParse($s, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$v)) {
        throw "CONSTRUCTION_BAD_INPUT: fila $Row, campo $Field no es numero: '$Raw'"
    }
    if ([double]::IsNaN($v) -or [double]::IsInfinity($v)) {
        throw "CONSTRUCTION_BAD_INPUT: fila $Row, campo $Field no es numero finito: '$Raw'"
    }
    return $v
}

function Format-PwxConstructionMoney {
    param([double]$V)
    $r = [math]::Round($V, 2, [System.MidpointRounding]::AwayFromZero)
    return $r.ToString('0.00', [System.Globalization.CultureInfo]::InvariantCulture)
}

function Format-PwxConstructionQty {
    param([double]$V)
    $r = [math]::Round($V, 4, [System.MidpointRounding]::AwayFromZero)
    if ($r -eq [math]::Truncate($r)) {
        return ([long]$r).ToString([System.Globalization.CultureInfo]::InvariantCulture)
    }
    return $r.ToString('0.####', [System.Globalization.CultureInfo]::InvariantCulture)
}

# Canon numerico identico al del lector de excel.ps1 (G17 / enteros largos),
# para que Compare-PwxExcelGrid vea strings equivalentes.
function ConvertTo-PwxConstructionCellValue {
    param([string]$Formatted)
    $v = 0.0
    if ([double]::TryParse($Formatted, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$v)) {
        return (ConvertTo-PwxExcelNumberValue -D $v)
    }
    return $Formatted
}

# Lee y calcula el plan completo del presupuesto desde el CSV de partidas.
function Get-PwxConstructionPlan {
    param([string]$Path)
    $table = Read-PwxCsvTable -Path $Path
    if (-not $table.ok) { return $table }

    $map = Get-PwxConstructionHeaderMap -Headers $table.headers
    $required = @('descripcion', 'cantidad', 'precio')
    $missing = @()
    $mapped = @($map.Values)
    foreach ($r in $required) { if ($mapped -notcontains $r) { $missing += $r } }
    if ($missing.Count -gt 0) {
        return (New-PwxServiceError -Code 'CONSTRUCTION_BAD_INPUT' -Detail ("Faltan columnas requeridas: " + ($missing -join ', ') + " (encabezados: " + (@($table.headers) -join ' | ') + ')'))
    }

    $idxDesc = -1; $idxCant = -1; $idxPrecio = -1; $idxUni = -1; $idxPart = -1
    foreach ($i in $map.Keys) {
        switch ($map[$i]) {
            'descripcion' { $idxDesc = [int]$i }
            'cantidad' { $idxCant = [int]$i }
            'precio' { $idxPrecio = [int]$i }
            'unidad' { $idxUni = [int]$i }
            'partida' { $idxPart = [int]$i }
        }
    }

    $rows = @($table.rows)
    if ($rows.Count -eq 0) {
        return (New-PwxServiceError -Code 'CONSTRUCTION_NO_ROWS' -Detail 'El CSV no tiene filas de partidas')
    }
    if ($rows.Count -gt $PwxConstructionMaxRows) {
        return (New-PwxServiceError -Code 'CONSTRUCTION_LIMITS_EXCEEDED' -Detail "Mas de $PwxConstructionMaxRows partidas")
    }

    $lines = @()
    $total = 0.0
    $rowN = 0
    foreach ($r in $rows) {
        $rowN++
        $cells = @($r)
        $get = { param($idx) if ($idx -ge 0 -and $idx -lt $cells.Count) { [string]$cells[$idx] } else { '' } }
        $desc = & $get $idxDesc
        if ([string]::IsNullOrWhiteSpace($desc)) {
            return (New-PwxServiceError -Code 'CONSTRUCTION_BAD_INPUT' -Detail "Fila $rowN sin descripcion")
        }
        $unidad = & $get $idxUni
        $partida = & $get $idxPart
        if ([string]::IsNullOrWhiteSpace($partida)) { $partida = [string]$rowN }

        $cant = ConvertFrom-PwxConstructionNumber -Raw (& $get $idxCant) -Field 'cantidad' -Row $rowN
        $precio = ConvertFrom-PwxConstructionNumber -Raw (& $get $idxPrecio) -Field 'precio_unitario' -Row $rowN
        if ($cant -le 0) {
            return (New-PwxServiceError -Code 'CONSTRUCTION_BAD_INPUT' -Detail "Fila $rowN con cantidad no positiva: $cant")
        }
        if ($precio -lt 0) {
            return (New-PwxServiceError -Code 'CONSTRUCTION_BAD_INPUT' -Detail "Fila $rowN con precio negativo: $precio")
        }
        $lineTotal = [math]::Round($cant * $precio, 2, [System.MidpointRounding]::AwayFromZero)
        $total += $lineTotal
        $lines += [pscustomobject]@{
            partida  = $partida.Trim()
            desc     = $desc.Trim()
            unidad   = $unidad.Trim()
            cantidad = $cant
            precio   = $precio
            total    = $lineTotal
        }
    }
    $total = [math]::Round($total, 2, [System.MidpointRounding]::AwayFromZero)

    return [pscustomobject]@{
        ok        = $true
        code      = $null
        detail    = $null
        delimiter = $table.delimiter
        lines     = $lines
        total     = $total
    }
}

function New-PwxConstructionGrid {
    param($Plan)
    $header = @(
        (New-PwxExcelCell -Empty $false -Text $true -Value 'Partida')
        (New-PwxExcelCell -Empty $false -Text $true -Value 'Descripcion')
        (New-PwxExcelCell -Empty $false -Text $true -Value 'Unidad')
        (New-PwxExcelCell -Empty $false -Text $true -Value 'Cantidad')
        (New-PwxExcelCell -Empty $false -Text $true -Value 'Precio unitario (COP)')
        (New-PwxExcelCell -Empty $false -Text $true -Value 'Total (COP)')
    )
    $gridRows = @(, $header)
    foreach ($ln in @($Plan.lines)) {
        $gridRows += , @(
            (New-PwxExcelCell -Empty $false -Text $true -Value $ln.partida)
            (New-PwxExcelCell -Empty $false -Text $true -Value $ln.desc)
            (New-PwxExcelCell -Empty $false -Text $true -Value $ln.unidad)
            (New-PwxExcelCell -Empty $false -Text $false -Value (ConvertTo-PwxConstructionCellValue -Formatted (Format-PwxConstructionQty -V $ln.cantidad)))
            (New-PwxExcelCell -Empty $false -Text $false -Value (ConvertTo-PwxConstructionCellValue -Formatted (Format-PwxConstructionMoney -V $ln.precio)))
            (New-PwxExcelCell -Empty $false -Text $false -Value (ConvertTo-PwxConstructionCellValue -Formatted (Format-PwxConstructionMoney -V $ln.total)))
        )
    }
    $gridRows += , @(
        (New-PwxExcelCell -Empty $false -Text $true -Value 'TOTAL')
        (New-PwxExcelCell -Empty $true -Text $false -Value '')
        (New-PwxExcelCell -Empty $true -Text $false -Value '')
        (New-PwxExcelCell -Empty $true -Text $false -Value '')
        (New-PwxExcelCell -Empty $true -Text $false -Value '')
        (New-PwxExcelCell -Empty $false -Text $false -Value (ConvertTo-PwxConstructionCellValue -Formatted (Format-PwxConstructionMoney -V $Plan.total)))
    )
    return [pscustomobject]@{
        cells = $gridRows
        rows  = $gridRows.Count
        cols  = 6
    }
}

function Resolve-PwxConstructionInputFile {
    param([string]$JobId)
    $found = Find-PwxJob -JobId $JobId
    if (-not $found) { return (New-PwxServiceError -Code 'CONSTRUCTION_INTERNAL' -Detail "Job inexistente: $JobId") }
    $inputDir = Join-Path $found.JobDir 'input'
    if (-not (Test-Path -LiteralPath $inputDir)) {
        return (New-PwxServiceError -Code 'CONSTRUCTION_NO_INPUT' -Detail 'Sin carpeta input')
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
        catch { return (New-PwxServiceError -Code 'CONSTRUCTION_BAD_INPUT' -Detail "Nombre de input del requisito invalido: $name") }
        $candidatePath = Join-Path $inputDir $name
        $safeCandidate = Assert-PwxSafeWorkspacePath -WorkspacePath $found.JobDir -Path $candidatePath
        if (Test-Path -LiteralPath $safeCandidate -PathType Leaf) { $chosen = $safeCandidate }
    }

    if ($null -eq $chosen -and $files.Count -eq 1) { $chosen = $files[0].FullName }
    elseif ($null -eq $chosen -and $files.Count -gt 1) {
        return (New-PwxServiceError -Code 'CONSTRUCTION_MULTIPLE_INPUTS' -Detail ("Varios archivos en input sin unico candidato en requisitos: " + (($files | ForEach-Object { $_.Name }) -join ', ')))
    }
    if ($null -eq $chosen) {
        return (New-PwxServiceError -Code 'CONSTRUCTION_NO_INPUT' -Detail 'No hay archivo de entrada en job/input/')
    }
    if ([System.IO.Path]::GetExtension($chosen) -notmatch '^\.csv$') {
        return (New-PwxServiceError -Code 'CONSTRUCTION_UNSUPPORTED_FORMAT' -Detail ("Formato no soportado: " + [System.IO.Path]::GetExtension($chosen)))
    }
    return [pscustomobject]@{ ok = $true; code = $null; detail = $null; path = $chosen }
}

# Contrato del servicio: @{ ok=$true|$false; error=$null|<codigo> }
function Invoke-PwxService_construction_service {
    param([string]$JobId)
    Initialize-PwxConstructionTypes
    try {
        $resolve = Resolve-PwxConstructionInputFile -JobId $JobId
        if (-not $resolve.ok) {
            return [pscustomobject]@{ ok = $false; error = $resolve.code }
        }

        $plan = Get-PwxConstructionPlan -Path $resolve.path
        if (-not $plan.ok) {
            return [pscustomobject]@{ ok = $false; error = $plan.code }
        }

        $found = Find-PwxJob -JobId $JobId
        $outputDir = Join-Path $found.JobDir 'output'
        New-PwxDirectory -Path $outputDir | Out-Null

        $finalPath = Join-Path $outputDir $PwxConstructionOutputName
        $grid = New-PwxConstructionGrid -Plan $plan
        Write-PwxExcelGrid -Path $finalPath -Grid $grid

        if (-not (Test-Path -LiteralPath $finalPath)) {
            return [pscustomobject]@{ ok = $false; error = 'CONSTRUCTION_INTERNAL' }
        }

        Add-PwxJobFile -JobId $JobId -Bucket 'output' -Path $finalPath | Out-Null

        $sha = Get-PwxSha256 -Path $finalPath
        Add-PwxEvent -JobId $JobId -Component 'service.construction' -Action 'construction.generated' -Data @{
            file   = $PwxConstructionOutputName
            lines  = @($plan.lines).Count
            total  = $plan.total
            sha256 = $sha
        }
        Write-PwxLog -Component 'service.construction' -Message "construction-service genero $PwxConstructionOutputName para $JobId (partidas=$(@($plan.lines).Count), total=$($plan.total), sha256=$sha)" -JobId $JobId

        return [pscustomobject]@{
            ok     = $true
            error  = $null
            file   = $PwxConstructionOutputName
            lines  = @($plan.lines).Count
            total  = $plan.total
            sha256 = $sha
        }
    }
    catch {
        Write-PwxLog -Component 'service.construction' -Level 'ERROR' -Message "construction-service fallo: $($_.Exception.Message)" -JobId $JobId
        if ($_.Exception.Message -match '^CONSTRUCTION_BAD_INPUT') {
            return [pscustomobject]@{ ok = $false; error = 'CONSTRUCTION_BAD_INPUT' }
        }
        return [pscustomobject]@{ ok = $false; error = 'CONSTRUCTION_INTERNAL' }
    }
}

# Validador QA: recalcula el plan desde el input y exige identidad de grilla.
function Test-PwxConstructionOutput {
    param([string]$JobId)
    Initialize-PwxConstructionTypes
    try {
        $snap = @(Get-PwxOutputSnapshot -JobId $JobId)
        $out = @($snap | Where-Object { $_.name -like '*.xlsx' })
        if ($out.Count -eq 0) {
            return (New-PwxServiceValidation $false 'No hay archivo .xlsx en output/')
        }
        if ($out.Count -gt 1) {
            return (New-PwxServiceValidation $false 'Mas de un archivo .xlsx en output/')
        }
        $read = Read-PwxExcelGrid -Path $out[0].full
        if (-not $read.ok) {
            return (New-PwxServiceValidation $false "$($read.code): $($read.detail)")
        }

        $resolve = Resolve-PwxConstructionInputFile -JobId $JobId
        if (-not $resolve.ok) {
            return (New-PwxServiceValidation $false "$($resolve.code): $($resolve.detail)")
        }
        $plan = Get-PwxConstructionPlan -Path $resolve.path
        if (-not $plan.ok) {
            return (New-PwxServiceValidation $false "$($plan.code): $($plan.detail)")
        }
        $expected = New-PwxConstructionGrid -Plan $plan

        $cmp = Compare-PwxExcelGrid -A $expected -B $read
        if (-not $cmp.ok) {
            return (New-PwxServiceValidation $false "$($cmp.code): $($cmp.detail)")
        }
        return (New-PwxServiceValidation $true ("Presupuesto recalculado coincide; total=" + (Format-PwxConstructionMoney -V $plan.total)))
    }
    catch {
        return (New-PwxServiceValidation $false "CONSTRUCTION_INTERNAL: $($_.Exception.Message)")
    }
}
