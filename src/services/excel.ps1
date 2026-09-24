$ErrorActionPreference = 'Stop'

# Limites defensivos (aplicados en streaming durante el recorrido de celdas).
$PwxExcelMaxRows       = 10000
$PwxExcelMaxCols       = 400
$PwxExcelMaxCells      = 200000
$PwxExcelMaxEntryBytes = 52428800
# Timestamp fijo para TODAS las entradas ZIP escritas por Write-PwxExcelGrid.
# El determinismo binario del XLSX de salida exige que el timestamp DOS de cada
# entrada (resolucion de 2 segundos) sea constante entre ejecuciones; si usara la
# hora actual, dos escrituras del mismo grid separadas >2s darian bytes distintos.
# Usamos una constante con offset +00:00 (el escritor ZIP de .NET Framework guarda
# el reloj del DateTimeOffset, no la hora local del SO), estable entre maquinas.
[DateTimeOffset]$PwxExcelZipTimestamp = [DateTimeOffset]::new(2000, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
$PwxExcelOutputName    = 'resultado-normalizado.xlsx'
$PwxExcelSheetName     = 'Hoja1'

function Initialize-PwxExcelTypes {
    Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue | Out-Null
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue | Out-Null
}

function Test-PwxExcelZipArchivePart {
    param([System.IO.Compression.ZipArchive]$Zip, [string]$EntryName)
    foreach ($e in $Zip.Entries) {
        if ($e.FullName -eq $EntryName) { return $true }
    }
    return $false
}

function Read-PwxExcelZipEntryText {
    param([System.IO.Compression.ZipArchive]$Zip, [string]$EntryName, [long]$MaxBytes)
    $entry = $null
    foreach ($e in $Zip.Entries) {
        if ($e.FullName -eq $EntryName) { $entry = $e; break }
    }
    if ($null -eq $entry) { return $null }
    if ($entry.Length -gt $MaxBytes) {
        return [pscustomobject]@{ error = 'EXCEL_LIMITS_EXCEEDED'; detail = "Part '$EntryName' demasiado grande ($($entry.Length) bytes)" }
    }
    try {
        $stream = $entry.Open()
        try {
            $reader = New-Object System.IO.StreamReader $stream, ([System.Text.Encoding]::UTF8)
            return $reader.ReadToEnd()
        }
        finally {
            $stream.Dispose()
        }
    }
    catch {
        return [pscustomobject]@{ error = 'EXCEL_BAD_XML'; detail = "No se pudo leer '$EntryName'" }
    }
}

function ConvertFrom-PwxExcelXml {
    param([string]$Text)
    $settings = New-Object System.Xml.XmlReaderSettings
    $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $settings.MaxCharactersFromEntities = 0
    $reader = [System.Xml.XmlReader]::Create((New-Object System.IO.StringReader ($Text)), $settings)
    try {
        $doc = New-Object System.Xml.XmlDocument
        $doc.XmlResolver = $null
        $doc.Load($reader)
        return $doc
    }
    finally {
        $reader.Dispose()
    }
}

function ConvertFrom-PwxExcelColumnLetters {
    param([string]$Letters)
    $sum = 0
    foreach ($ch in $Letters.ToCharArray()) {
        $n = [int][char]$ch
        if ($ch -ge 'a' -and $ch -le 'z') { $n = [int][char]$ch - 96 }
        elseif ($ch -ge 'A' -and $ch -le 'Z') { $n = [int][char]$ch - 64 }
        else { return $null }
        $sum = ($sum * 26) + $n
    }
    if ($sum -le 0) { return $null }
    return $sum
}

function ConvertTo-PwxExcelColumnLetters {
    param([int]$N)
    $s = ''
    while ($N -gt 0) {
        $m = (($N - 1) % 26)
        $s = [char](65 + $m) + $s
        $N = [int](($N - $m) / 26)
    }
    return $s
}

function ConvertTo-PwxExcelNumberValue {
    param([double]$D)
    if ([double]::IsNaN($D) -or [double]::IsInfinity($D)) { return $null }
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $trunc = [math]::Truncate($D)
    if ($D -eq $trunc -and [math]::Abs($D) -lt [math]::Pow(2, 53)) {
        return ([long]$D).ToString($inv)
    }
    return $D.ToString('G17', $inv)
}

function ConvertTo-PwxExcelXmlText {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $Text.ToCharArray()) {
        $c = [int][char]$ch
        if (($c -eq 0x09) -or ($c -eq 0x0A) -or ($c -eq 0x0D) -or ($c -ge 0x20)) {
            [void]$sb.Append($ch)
        }
    }
    $s = $sb.ToString()
    $s = $s.Replace('&', '&amp;')
    $s = $s.Replace('<', '&lt;')
    $s = $s.Replace('>', '&gt;')
    return $s
}

function New-PwxExcelCell {
    param(
        [bool]$Empty,
        [bool]$Text,
        [string]$Value
    )
    return [pscustomobject]@{
        empty = $Empty
        text  = $Text
        value = $Value
    }
}

# Lee job/input/*.xlsx (hoja 1), normaliza la cuadricula:
# - texto (sharedStrings/inlineStr/str) se mantiene como texto (p.ej. '00123').
# - numeros se mantienen como numeros; fechas se conservan como serial numerico.
# - filas y columnas totalmente vacias se eliminan.
# Retorna: @{ ok=$true; grid; rows; cols } | @{ ok=$false; code; detail }
function Read-PwxExcelGrid {
    param([string]$Path)
    Initialize-PwxExcelTypes

    $zip = $null
    try {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($Path)
    }
    catch {
        return (New-PwxExcelErrorResult -Code 'EXCEL_NOT_ZIP' -Detail "No es un archivo ZIP valido: $($_.Exception.Message)")
    }
    try {
        foreach ($part in @('[Content_Types].xml', '_rels/.rels', 'xl/workbook.xml', 'xl/_rels/workbook.xml.rels')) {
            if (-not (Test-PwxExcelZipArchivePart -Zip $zip -EntryName $part)) {
                return (New-PwxExcelErrorResult -Code 'EXCEL_MISSING_PARTS' -Detail "Falta parte obligatoria: $part")
            }
        }

        $wbText = Read-PwxExcelZipEntryText -Zip $zip -EntryName 'xl/workbook.xml' -MaxBytes $PwxExcelMaxEntryBytes
        if ($null -eq $wbText) {
            return (New-PwxExcelErrorResult -Code 'EXCEL_MISSING_PARTS' -Detail 'Falta xl/workbook.xml')
        }
        if ($wbText -is [pscustomobject]) { return (New-PwxExcelErrorResult -Code $wbText.error -Detail $wbText.detail) }
        $wb = $null
        try { $wb = ConvertFrom-PwxExcelXml -Text $wbText }
        catch { return (New-PwxExcelErrorResult -Code 'EXCEL_BAD_XML' -Detail "workbook.xml malformado: $($_.Exception.Message)") }

        $sheets = @($wb.SelectNodes('//*[local-name()="sheet"]'))
        if ($sheets.Count -eq 0) {
            return (New-PwxExcelErrorResult -Code 'EXCEL_MISSING_PARTS' -Detail 'workbook.xml sin hojas')
        }
        $sheet = $sheets[0]
        $rid = $sheet.GetAttribute('id', 'http://schemas.openxmlformats.org/officeDocument/2006/relationships')
        if (-not $rid) {
            return (New-PwxExcelErrorResult -Code 'EXCEL_BAD_XML' -Detail 'Sin r:id en la hoja')
        }

        $relsText = Read-PwxExcelZipEntryText -Zip $zip -EntryName 'xl/_rels/workbook.xml.rels' -MaxBytes $PwxExcelMaxEntryBytes
        if ($null -eq $relsText) {
            return (New-PwxExcelErrorResult -Code 'EXCEL_MISSING_PARTS' -Detail 'Falta xl/_rels/workbook.xml.rels')
        }
        if ($relsText -is [pscustomobject]) { return (New-PwxExcelErrorResult -Code $relsText.error -Detail $relsText.detail) }
        $rels = $null
        try { $rels = ConvertFrom-PwxExcelXml -Text $relsText }
        catch { return (New-PwxExcelErrorResult -Code 'EXCEL_BAD_XML' -Detail "workbook.xml.rels malformado: $($_.Exception.Message)") }

        $target = $null
        foreach ($rel in @($rels.SelectNodes('//*[local-name()="Relationship"]'))) {
            if ($rel.GetAttribute('Id') -eq $rid) {
                $target = $rel.GetAttribute('Target')
                break
            }
        }
        if (-not $target) {
            return (New-PwxExcelErrorResult -Code 'EXCEL_BAD_XML' -Detail 'Sin Target en el workbook del sheet')
        }
        if ($target.StartsWith('/')) { $target = $target.TrimStart('/') }
        elseif (-not $target.StartsWith('xl/', [System.StringComparison]::OrdinalIgnoreCase)) { $target = 'xl/' + $target }

        $sheetEntryName = $target -replace '\\', '/'
        $sheetEntry = $null
        foreach ($e2 in $zip.Entries) {
            if ($e2.FullName -eq $sheetEntryName) { $sheetEntry = $e2; break }
        }
        if ($null -eq $sheetEntry) {
            return (New-PwxExcelErrorResult -Code 'EXCEL_MISSING_PARTS' -Detail "Falta parte de hoja: $sheetEntryName")
        }
        if ($sheetEntry.Length -gt $PwxExcelMaxEntryBytes) {
            return (New-PwxExcelErrorResult -Code 'EXCEL_LIMITS_EXCEEDED' -Detail "Part '$sheetEntryName' demasiado grande ($($sheetEntry.Length) bytes)")
        }

        $shared = @()
        if (Test-PwxExcelZipArchivePart -Zip $zip -EntryName 'xl/sharedStrings.xml') {
            $ssText = Read-PwxExcelZipEntryText -Zip $zip -EntryName 'xl/sharedStrings.xml' -MaxBytes $PwxExcelMaxEntryBytes
            if ($null -eq $ssText) {
                return (New-PwxExcelErrorResult -Code 'EXCEL_MISSING_PARTS' -Detail 'Falta xl/sharedStrings.xml referenciado')
            }
            if ($ssText -is [pscustomobject]) { return (New-PwxExcelErrorResult -Code $ssText.error -Detail $ssText.detail) }
            $ss = $null
            try { $ss = ConvertFrom-PwxExcelXml -Text $ssText }
            catch { return (New-PwxExcelErrorResult -Code 'EXCEL_BAD_XML' -Detail "sharedStrings.xml malformado: $($_.Exception.Message)") }
            foreach ($si in @($ss.SelectNodes('//*[local-name()="si"]'))) {
                $sb = New-Object System.Text.StringBuilder
                foreach ($t in @($si.SelectNodes('.//*[local-name()="t"]'))) {
                    [void]$sb.Append($t.InnerText)
                }
                $shared += $sb.ToString()
            }
        }

        # Parseeo STREAMING (M-2): la hoja se recorre con XmlReader desde el
        # stream de la entrada ZIP (sin cargar todo sheet1.xml en memoria).
        # Los limites MaxRows/MaxCols/MaxCells se aplican durante el recorrido,
        # en cuanto se registra una fila/columna con datos: los conjuntos solo
        # crecen, asi que detectar el exceso antes de terminar el archivo
        # equivale al chequeo final filas*columnas sin esperar a cargar la hoja.
        $rowSet = New-Object 'System.Collections.Generic.HashSet[int]'
        $colSet = New-Object 'System.Collections.Generic.HashSet[int]'
        $cellMap = @{}
        $sheetStream = $null
        $xr = $null
        try {
            $sheetStream = $sheetEntry.Open()
            $settings = New-Object System.Xml.XmlReaderSettings
            $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
            $settings.XmlResolver = $null
            $settings.MaxCharactersFromEntities = 0
            $xr = [System.Xml.XmlReader]::Create($sheetStream, $settings)
            # ReadOuterXml posiciona el reader en el nodo posterior a la celda;
            # tras procesarla no se vuelve a llamar Read() (evita saltar celdas).
            $needRead = $true
            while ($true) {
                if ($needRead) {
                    if (-not $xr.Read()) { break }
                }
                elseif ($xr.EOF) {
                    break
                }
                $needRead = $true
                if ($xr.NodeType -eq [System.Xml.XmlNodeType]::Element -and $xr.LocalName -eq 'c') {
                    $c = $null
                    try { $c = (ConvertFrom-PwxExcelXml -Text $xr.ReadOuterXml()).DocumentElement }
                    catch { return (New-PwxExcelErrorResult -Code 'EXCEL_BAD_XML' -Detail "Hoja malformada: $($_.Exception.Message)") }
                    $needRead = $false
                    $ref = $c.GetAttribute('r')
                    $t = $c.GetAttribute('t')
                    if (-not $ref) {
                        return (New-PwxExcelErrorResult -Code 'EXCEL_BAD_XML' -Detail 'Celda sin referencia r=')
                    }
                    $m = [regex]::Match($ref, '^([A-Za-z]+)(\d+)$')
                    if (-not $m.Success) {
                        return (New-PwxExcelErrorResult -Code 'EXCEL_BAD_XML' -Detail "Referencia de celda invalida: $ref")
                    }
                    $col = ConvertFrom-PwxExcelColumnLetters -Letters $m.Groups[1].Value
                    $row = [int]$m.Groups[2].Value
                    if ($null -eq $col -or $row -lt 1) {
                        return (New-PwxExcelErrorResult -Code 'EXCEL_BAD_XML' -Detail "Referencia de celda invalida: $ref")
                    }

                    $vNode = $null
                    $isNode = $null
                    foreach ($ch in $c.ChildNodes) {
                        if ($ch.LocalName -eq 'v') { $vNode = $ch }
                        elseif ($ch.LocalName -eq 'is') { $isNode = $ch }
                    }

                    $cell = $null
                    if ($t -eq 'inlineStr') {
                        if ($null -eq $isNode) {
                            return (New-PwxExcelErrorResult -Code 'EXCEL_BAD_XML' -Detail "Celda inlineStr sin <is> en $ref")
                        }
                        $sb = New-Object System.Text.StringBuilder
                        foreach ($t2 in @($isNode.SelectNodes('.//*[local-name()="t"]'))) {
                            [void]$sb.Append($t2.InnerText)
                        }
                        $cell = New-PwxExcelCell -Empty $false -Text $true -Value $sb.ToString()
                    }
                    elseif ($t -eq 's') {
                        if ($null -eq $vNode) {
                            return (New-PwxExcelErrorResult -Code 'EXCEL_BAD_XML' -Detail "Celda shared-string sin <v> en $ref")
                        }
                        $idx = 0
                        if (-not [int]::TryParse($vNode.InnerText, [ref]$idx)) {
                            return (New-PwxExcelErrorResult -Code 'EXCEL_BAD_XML' -Detail "Indice shared-string invalido en $ref")
                        }
                        if ($idx -lt 0 -or $idx -ge $shared.Count) {
                            return (New-PwxExcelErrorResult -Code 'EXCEL_BAD_XML' -Detail "Indice shared-string fuera de rango en $ref")
                        }
                        $cell = New-PwxExcelCell -Empty $false -Text $true -Value $shared[$idx]
                    }
                    elseif ($t -eq 'str') {
                        if ($null -eq $vNode) {
                            return (New-PwxExcelErrorResult -Code 'EXCEL_BAD_XML' -Detail "Celda str sin <v> en $ref")
                        }
                        $cell = New-PwxExcelCell -Empty $false -Text $true -Value $vNode.InnerText
                    }
                    elseif ($t -eq 'b') {
                        if ($null -eq $vNode) {
                            return (New-PwxExcelErrorResult -Code 'EXCEL_BAD_XML' -Detail "Celda booleana sin <v> en $ref")
                        }
                        $cell = New-PwxExcelCell -Empty $false -Text $true -Value $vNode.InnerText
                    }
                    elseif ($t -eq 'd' -or $t -eq 'e') {
                        if ($t -eq 'e') { continue }
                        if ($null -eq $vNode) { continue }
                        $cell = New-PwxExcelCell -Empty $false -Text $true -Value $vNode.InnerText
                    }
                    else {
                        if ($null -eq $vNode -or [string]::IsNullOrWhiteSpace($vNode.InnerText)) { continue }
                        $num = 0.0
                        $inv = [System.Globalization.CultureInfo]::InvariantCulture
                        if (-not [double]::TryParse($vNode.InnerText, [System.Globalization.NumberStyles]::Float, $inv, [ref]$num)) {
                            return (New-PwxExcelErrorResult -Code 'EXCEL_BAD_XML' -Detail "Valor numerico invalido en $ref : $($vNode.InnerText)")
                        }
                        $canon = ConvertTo-PwxExcelNumberValue -D $num
                        if ($null -eq $canon) { continue }
                        $cell = New-PwxExcelCell -Empty $false -Text $false -Value $canon
                    }

                    if ($null -ne $cell) {
                        $cellMap["$row,$col"] = $cell
                        [void]$rowSet.Add($row)
                        [void]$colSet.Add($col)
                        if ($rowSet.Count -gt $PwxExcelMaxRows) {
                            return (New-PwxExcelErrorResult -Code 'EXCEL_LIMITS_EXCEEDED' -Detail "Mas de $PwxExcelMaxRows filas con datos")
                        }
                        if ($colSet.Count -gt $PwxExcelMaxCols) {
                            return (New-PwxExcelErrorResult -Code 'EXCEL_LIMITS_EXCEEDED' -Detail "Mas de $PwxExcelMaxCols columnas con datos")
                        }
                        if ($rowSet.Count * $colSet.Count -gt $PwxExcelMaxCells) {
                            return (New-PwxExcelErrorResult -Code 'EXCEL_LIMITS_EXCEEDED' -Detail "Cuadricula supera $PwxExcelMaxCells celdas")
                        }
                    }
                }
            }
        }
        catch [System.Xml.XmlException] {
            return (New-PwxExcelErrorResult -Code 'EXCEL_BAD_XML' -Detail "Hoja malformada: $($_.Exception.Message)")
        }
        catch {
            return (New-PwxExcelErrorResult -Code 'EXCEL_BAD_XML' -Detail "No se pudo leer '$sheetEntryName'")
        }
        finally {
            if ($null -ne $xr) { $xr.Dispose() }
            if ($null -ne $sheetStream) { $sheetStream.Dispose() }
        }

        $usedCols = @( ($cellMap.Keys | ForEach-Object {
                [int](($_ -split ',')[1])
            } | Sort-Object -Unique) )
        $dataRows = @( ($cellMap.Keys | ForEach-Object {
                [int](($_ -split ',')[0])
            } | Sort-Object -Unique) )

        if ($usedCols.Count -eq 0 -or $dataRows.Count -eq 0) {
            return (New-PwxExcelErrorResult -Code 'EXCEL_EMPTY' -Detail 'La hoja no contiene celdas con valor')
        }

        $emptyCell = New-PwxExcelCell -Empty $true -Text $false -Value ''
        $matrix = New-Object System.Collections.Generic.List[object]
        foreach ($r in $dataRows) {
            $rowArr = New-Object 'object[]' $usedCols.Count
            for ($j = 0; $j -lt $usedCols.Count; $j++) {
                $origCol = $usedCols[$j]
                $key = "$r,$origCol"
                if ($cellMap.ContainsKey($key)) { $rowArr[$j] = $cellMap[$key] }
                else { $rowArr[$j] = $emptyCell }
            }
            $matrix.Add($rowArr)
        }

        return [pscustomobject]@{
            ok       = $true
            code     = $null
            detail   = $null
            rows     = $matrix.Count
            cols     = $usedCols.Count
            cells    = $matrix
        }
    }
    finally {
        if ($null -ne $zip) { $zip.Dispose() }
    }
}

# Escribe la cuadricula normalizada como XLSX valido en Path.
# Determinismo binario (M-1): todas las entradas ZIP se crean con el mismo
# LastWriteTime constante ($PwxExcelZipTimestamp), de modo que mismo grid da
# exactamente los mismos bytes y, por lo tanto, el mismo SHA256 entre ejecuciones.
function Write-PwxExcelGrid {
    param([string]$Path, [object]$Grid)
    Initialize-PwxExcelTypes
    $colCount = [int]$Grid.cols

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
    [void]$sb.Append('<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>')
    for ($ri = 0; $ri -lt $Grid.cells.Count; $ri++) {
        $row = $Grid.cells[$ri]
        $rowN = $ri + 1
        $rowXml = New-Object System.Text.StringBuilder
        $hasCell = $false
        for ($j = 0; $j -lt $colCount; $j++) {
            $c = $row[$j]
            if ($null -eq $c -or $c.empty) { continue }
            $hasCell = $true
            $ref = (ConvertTo-PwxExcelColumnLetters -N ($j + 1)) + $rowN
            if ($c.text) {
                [void]$rowXml.Append('<c r="' + $ref + '" t="inlineStr"><is><t xml:space="preserve">' + (ConvertTo-PwxExcelXmlText -Text $c.value) + '</t></is></c>')
            }
            else {
                [void]$rowXml.Append('<c r="' + $ref + '"><v>' + $c.value + '</v></c>')
            }
        }
        if ($hasCell) {
            [void]$sb.Append('<row r="' + $rowN + '">')
            [void]$sb.Append($rowXml.ToString())
            [void]$sb.Append('</row>')
        }
    }
    [void]$sb.Append('</sheetData></worksheet>')

    $parts = [ordered]@{
        '[Content_Types].xml' = @'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/></Types>
'@
        '_rels/.rels' = @'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>
'@
        'xl/workbook.xml' = @'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="_PLACEHOLDER_SHEET_" sheetId="1" r:id="rId1"/></sheets></workbook>
'@.Replace('_PLACEHOLDER_SHEET_', $PwxExcelSheetName)
        'xl/_rels/workbook.xml.rels' = @'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/></Relationships>
'@
        'xl/worksheets/sheet1.xml' = $sb.ToString()
    }

    $tmp = Join-Path ([System.IO.Path]::GetDirectoryName($Path)) ('.' + ([System.IO.Path]::GetFileName($Path)) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $zip = [System.IO.Compression.ZipFile]::Open($tmp, [System.IO.Compression.ZipArchiveMode]::Create)
        try {
            foreach ($entry in $parts.Keys) {
                $e = $zip.CreateEntry($entry, [System.IO.Compression.CompressionLevel]::Optimal)
                $e.LastWriteTime = $PwxExcelZipTimestamp
                $s = $e.Open()
                try {
                    $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$parts[$entry])
                    $s.Write($bytes, 0, $bytes.Length)
                }
                finally {
                    $s.Dispose()
                }
            }
        }
        finally {
            $zip.Dispose()
        }
        if (Test-Path -LiteralPath $Path) {
            Remove-Item -LiteralPath $Path -Force
        }
        [System.IO.File]::Move($tmp, $Path)
    }
    catch {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        throw
    }
}

function Compare-PwxExcelGrid {
    param([object]$A, [object]$B)
    if ($A.rows -ne $B.rows) {
        return (New-PwxExcelErrorResult -Code 'EXCEL_MISMATCH' -Detail "Filas distintas: $($A.rows) vs $($B.rows)")
    }
    if ($A.cols -ne $B.cols) {
        return (New-PwxExcelErrorResult -Code 'EXCEL_MISMATCH' -Detail "Columnas distintas: $($A.cols) vs $($B.cols)")
    }
    $aCells = $A.cells
    $bCells = $B.cells
    for ($i = 0; $i -lt $A.rows; $i++) {
        $ra = $aCells[$i]
        $rb = $bCells[$i]
        for ($j = 0; $j -lt $A.cols; $j++) {
            $ca = $ra[$j]
            $cb = $rb[$j]
            if ($ca.empty -ne $cb.empty) {
                return (New-PwxExcelErrorResult -Code 'EXCEL_MISMATCH' -Detail "Celda f$($i+1)c$($j+1) vacia/no-vacia distinta")
            }
            if (-not $ca.empty) {
                if ($ca.text -ne $cb.text) {
                    return (New-PwxExcelErrorResult -Code 'EXCEL_MISMATCH' -Detail "Celda f$($i+1)c$($j+1) tipo texto/numero distinto")
                }
                if ($ca.value -ne $cb.value) {
                    return (New-PwxExcelErrorResult -Code 'EXCEL_MISMATCH' -Detail "Celda f$($i+1)c$($j+1) valor distinto: '$($ca.value)' vs '$($cb.value)'")
                }
            }
        }
    }
    return [pscustomobject]@{ ok = $true; code = $null; detail = $null }
}

# Resolucion determinista del input:
# 1. requirements.input_files == 1 y existe ese archivo en job/input/ -> ese.
# 2. Si no, y job/input/ contiene exactamente 1 archivo -> ese.
# 3. Varios -> EXCEL_MULTIPLE_INPUTS. Ninguno -> EXCEL_NO_INPUT.
# 4. No .xlsx -> EXCEL_UNSUPPORTED_FORMAT.
function Resolve-PwxExcelInputFile {
    param([string]$JobId)
    $found = Find-PwxJob -JobId $JobId
    if (-not $found) { return (New-PwxExcelErrorResult -Code 'EXCEL_INTERNAL' -Detail "Job inexistente: $JobId") }
    $inputDir = Join-Path $found.JobDir 'input'
    if (-not (Test-Path -LiteralPath $inputDir)) {
        return (New-PwxExcelErrorResult -Code 'EXCEL_NO_INPUT' -Detail 'Sin carpeta input')
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
        try {
            Assert-PwxSafeFileName -Name $name | Out-Null
        }
        catch {
            return (New-PwxExcelErrorResult -Code 'EXCEL_BAD_XML' -Detail "Nombre de input del requisito invalido: $name")
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
        return (New-PwxExcelErrorResult -Code 'EXCEL_MULTIPLE_INPUTS' -Detail ("Varios archivos en input sin unico candidato en requisitos: " + (($files | ForEach-Object { $_.Name }) -join ', ')))
    }

    if ($null -eq $chosen) {
        return (New-PwxExcelErrorResult -Code 'EXCEL_NO_INPUT' -Detail 'No hay archivo de entrada en job/input/')
    }

    if ([System.IO.Path]::GetExtension($chosen) -notmatch '^\.xlsx$') {
        return (New-PwxExcelErrorResult -Code 'EXCEL_UNSUPPORTED_FORMAT' -Detail ("Formato no soportado: " + [System.IO.Path]::GetExtension($chosen)))
    }
    return [pscustomobject]@{ ok = $true; code = $null; detail = $null; path = $chosen }
}

function New-PwxExcelErrorResult {
    param([string]$Code, [string]$Detail = '')
    if ([string]::IsNullOrWhiteSpace($Detail)) {
        return [pscustomobject]@{ ok = $false; code = $Code; detail = $null }
    }
    return [pscustomobject]@{ ok = $false; code = $Code; detail = $Detail }
}

function New-PwxExcelValidationResult {
    param([bool]$Ok, [string]$Detail = '')
    return [pscustomobject]@{ ok = $Ok; detail = $Detail }
}

# Contrato del servicio: @{ ok=$true|$false; error=$null|<codigo> }
function Invoke-PwxService_excel_service {
    param([string]$JobId)
    Initialize-PwxExcelTypes
    try {
        $resolve = Resolve-PwxExcelInputFile -JobId $JobId
        if (-not $resolve.ok) {
            return (New-PwxExcelServiceFailure -JobId $JobId -Code $resolve.code -Detail $resolve.detail)
        }

        $read = Read-PwxExcelGrid -Path $resolve.path
        if (-not $read.ok) {
            return (New-PwxExcelServiceFailure -JobId $JobId -Code $read.code -Detail $read.detail)
        }

        $found = Find-PwxJob -JobId $JobId
        $outputDir = Join-Path $found.JobDir 'output'
        New-PwxDirectory -Path $outputDir | Out-Null

        $finalPath = Join-Path $outputDir $PwxExcelOutputName
        Write-PwxExcelGrid -Path $finalPath -Grid $read

        if (-not (Test-Path -LiteralPath $finalPath)) {
            return (New-PwxExcelServiceFailure -JobId $JobId -Code 'EXCEL_INTERNAL' -Detail 'No se pudo generar el archivo de salida')
        }

        Add-PwxJobFile -JobId $JobId -Bucket 'output' -Path $finalPath | Out-Null

        $sha = Get-PwxSha256 -Path $finalPath
        Add-PwxEvent -JobId $JobId -Component 'service.excel' -Action 'excel.generated' -Data @{
            file = $PwxExcelOutputName
            rows = $read.rows
            cols = $read.cols
            sha256 = $sha
        }
        Write-PwxLog -Component 'service.excel' -Message "excel-service genero $PwxExcelOutputName para $JobId (filas=$($read.rows), cols=$($read.cols), sha256=$sha)" -JobId $JobId

        return [pscustomobject]@{
            ok      = $true
            error   = $null
            file    = $PwxExcelOutputName
            rows    = $read.rows
            cols    = $read.cols
            sha256  = $sha
        }
    }
    catch {
        return (New-PwxExcelServiceFailure -JobId $JobId -Code 'EXCEL_INTERNAL' -Detail $_.Exception.Message)
    }
}

function New-PwxExcelServiceFailure {
    param([string]$JobId, [string]$Code, [string]$Detail = '')
    Add-PwxEvent -JobId $JobId -Component 'service.excel' -Action 'excel.failed' -Data @{ error = $Code; detail = $Detail }
    Write-PwxLog -Component 'service.excel' -Level 'WARN' -Message "excel-service fallo para ${JobId}: $Code $($Detail)" -JobId $JobId
    return [pscustomobject]@{
        ok      = $false
        error   = $Code
        detail  = $Detail
    }
}

# Validador de QA especifico de excel-service.
# Reabre el XLSX de salida, verifica estructura, renormaliza el input y el output
# y los compara celda a celda. Nunca da PASS a un archivo corrupto o que no
# corresponda al input. Retorna @{ ok=$true|$false; detail="..." }.
function Test-PwxExcelOutput {
    param([string]$JobId)
    Initialize-PwxExcelTypes
    try {
        $snap = @(Get-PwxOutputSnapshot -JobId $JobId)
        $out = @($snap | Where-Object { $_.name -like '*.xlsx' })
        if ($out.Count -eq 0) {
            return (New-PwxExcelValidationResult $false 'No hay archivo .xlsx en output/')
        }
        if ($out.Count -gt 1) {
            return (New-PwxExcelValidationResult $false 'Mas de un archivo .xlsx en output/')
        }
        $outPath = $out[0].full

        $zip = $null
        try {
            $zip = [System.IO.Compression.ZipFile]::OpenRead($outPath)
        }
        catch {
            return (New-PwxExcelValidationResult $false "EXCEL_NOT_ZIP: $($_.Exception.Message)")
        }
        try {
            $missing = @()
            foreach ($part in @('[Content_Types].xml', '_rels/.rels', 'xl/workbook.xml', 'xl/_rels/workbook.xml.rels', 'xl/worksheets/sheet1.xml')) {
                if (-not (Test-PwxExcelZipArchivePart -Zip $zip -EntryName $part)) {
                    $missing += $part
                }
            }
            if ($missing.Count -gt 0) {
                return (New-PwxExcelValidationResult $false ("EXCEL_MISSING_PARTS: " + ($missing -join ', ')))
            }
            foreach ($part in @('[Content_Types].xml', 'xl/workbook.xml', 'xl/_rels/workbook.xml.rels', 'xl/worksheets/sheet1.xml')) {
                $pt = Read-PwxExcelZipEntryText -Zip $zip -EntryName $part -MaxBytes $PwxExcelMaxEntryBytes
                if ($null -eq $pt) {
                    return (New-PwxExcelValidationResult $false "EXCEL_MISSING_PARTS: $part")
                }
                if ($pt -is [pscustomobject]) {
                    return (New-PwxExcelValidationResult $false "$($pt.error): $($pt.detail)")
                }
                try { ConvertFrom-PwxExcelXml -Text $pt | Out-Null }
                catch { return (New-PwxExcelValidationResult $false "EXCEL_BAD_XML: $part no esta bien formado") }
            }
        }
        finally {
            $zip.Dispose()
        }

        $readOut = Read-PwxExcelGrid -Path $outPath
        if (-not $readOut.ok) {
            return (New-PwxExcelValidationResult $false "$($readOut.code): $($readOut.detail)")
        }

        $inRes = Resolve-PwxExcelInputFile -JobId $JobId
        if (-not $inRes.ok) {
            return (New-PwxExcelValidationResult $false "EXCEL_NO_INPUT: el input ya no esta disponible para comparar ($($inRes.code))")
        }
        $readIn = Read-PwxExcelGrid -Path $inRes.path
        if (-not $readIn.ok) {
            return (New-PwxExcelValidationResult $false "$($readIn.code): $($readIn.detail)")
        }

        $cmp = Compare-PwxExcelGrid -A $readIn -B $readOut
        if (-not $cmp.ok) {
            return (New-PwxExcelValidationResult $false "EXCEL_MISMATCH: output no corresponde al input normalizado ($($cmp.detail))")
        }

        $sha = Get-PwxSha256 -Path $outPath
        return (New-PwxExcelValidationResult $true "filas=$($readOut.rows), cols=$($readOut.cols), sha256=$sha")
    }
    catch {
        return (New-PwxExcelValidationResult $false "EXCEL_INTERNAL: $($_.Exception.Message)")
    }
}