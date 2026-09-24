# Generador de fixtures XLSX para excel-service.
# IMPORTANTE: es un escritor INDEPENDIENTE del codigo bajo prueba
# (src/services/excel.ps1). Construye los XML a mano, usa sharedStrings
# (como Excel real) y no comparte ningun helper con el servicio.
# Correr: powershell -ExecutionPolicy Bypass -File tests\fixtures\generate-fixtures.ps1
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null

$outDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$utf8 = New-Object System.Text.UTF8Encoding($false)

function Add-ZipPart {
    param([System.IO.Compression.ZipArchive]$Zip, [string]$Name, [string]$Content)
    $entry = $Zip.CreateEntry($Name, [System.IO.Compression.CompressionLevel]::Optimal)
    $s = $entry.Open()
    try {
        $bytes = $utf8.GetBytes($Content)
        $s.Write($bytes, 0, $bytes.Length)
    }
    finally {
        $s.Dispose()
    }
}

$contentTypes = @'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/worksheets/sheet2.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/></Types>
'@
$relsRoot = @'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>
'@
$workbook1 = @'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Datos" sheetId="1" r:id="rId1"/><sheet name="Otra" sheetId="2" r:id="rId2"/></sheets></workbook>
'@
$workbookRels1 = @'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet2.xml"/></Relationships>
'@
$sharedStrings = @'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="13" uniqueCount="13"><si><t>Nombre</t></si><si><t>Valor</t></si><si><t>Codigo</t></si><si><t>FechaSerie</t></si><si><t>Producto A</t></si><si><t>Producto B</t></si><si><t>Producto C</t></si><si><t>X &amp; Y &lt;etiqueta&gt;</t></si><si><t>Gap</t></si><si><t>00123</t></si><si><t>ABC-01</t></si><si><t>007</t></si><si><t>00 11</t></si></sst>
'@
$sheet1 = @'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData><row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c><c r="C1" t="s"><v>2</v></c><c r="D1" t="s"><v>3</v></c></row><row r="2"><c r="A2" t="s"><v>4</v></c><c r="B2"><v>1234</v></c><c r="C2" t="s"><v>9</v></c><c r="D2"><v>45321</v></c></row><row r="3"><c r="A3" t="s"><v>5</v></c><c r="B3"><v>98.5</v></c><c r="C3" t="s"><v>10</v></c><c r="D3"><v>45322</v></c></row><row r="4"/><row r="5"><c r="A5" t="s"><v>6</v></c><c r="B5"><v>0</v></c><c r="C5" t="s"><v>11</v></c></row><row r="6"><c r="A6" t="s"><v>7</v></c><c r="B6"><v>2.5</v></c><c r="C6" t="s"><v>12</v></c><c r="D6"><v>45325</v></c></row><row r="7"><c r="A7" t="s"><v>8</v></c><c r="F7"><v>9</v></c></row></sheetData></worksheet>
'@
$sheet2 = @'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData><row r="1"><c r="A1" t="inlineStr"><is><t>no-se-usa</t></is></c></row></sheetData></worksheet>
'@

function New-BasicSheet {
    param([System.IO.Compression.ZipArchive]$Zip)
    Add-ZipPart -Zip $Zip -Name '[Content_Types].xml' -Content $contentTypes
    Add-ZipPart -Zip $Zip -Name '_rels/.rels' -Content $relsRoot
    Add-ZipPart -Zip $Zip -Name 'xl/workbook.xml' -Content $workbook1
    Add-ZipPart -Zip $Zip -Name 'xl/_rels/workbook.xml.rels' -Content $workbookRels1
    Add-ZipPart -Zip $Zip -Name 'xl/sharedStrings.xml' -Content $sharedStrings
    Add-ZipPart -Zip $Zip -Name 'xl/worksheets/sheet1.xml' -Content $sheet1
    Add-ZipPart -Zip $Zip -Name 'xl/worksheets/sheet2.xml' -Content $sheet2
}

# basic.xlsx: texto, numeros, texto con ceros a la izquierda, celdas vacias,
# fila vacia, columna vacia, dos hojas (se usa la primera).
$basic = Join-Path $outDir 'basic.xlsx'
if (Test-Path -LiteralPath $basic) { Remove-Item -LiteralPath $basic -Force }
$zip = [System.IO.Compression.ZipFile]::Open($basic, [System.IO.Compression.ZipArchiveMode]::Create)
try { New-BasicSheet -Zip $zip } finally { $zip.Dispose() }
Write-Host "generado: basic.xlsx"

# invalid-xml.xlsx: hoja malformada.
$invWorkbook = @'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Hoja1" sheetId="1" r:id="rId1"/></sheets></workbook>
'@
$invRels = @'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/></Relationships>
'@
$badSheet = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData><row r="1"><c r="A1"><v>'
$invXml = Join-Path $outDir 'invalid-xml.xlsx'
if (Test-Path -LiteralPath $invXml) { Remove-Item -LiteralPath $invXml -Force }
$zip = [System.IO.Compression.ZipFile]::Open($invXml, [System.IO.Compression.ZipArchiveMode]::Create)
try {
    Add-ZipPart -Zip $zip -Name '[Content_Types].xml' -Content $contentTypes
    Add-ZipPart -Zip $zip -Name '_rels/.rels' -Content $relsRoot
    Add-ZipPart -Zip $zip -Name 'xl/workbook.xml' -Content $invWorkbook
    Add-ZipPart -Zip $zip -Name 'xl/_rels/workbook.xml.rels' -Content $invRels
    Add-ZipPart -Zip $zip -Name 'xl/worksheets/sheet1.xml' -Content $badSheet
} finally { $zip.Dispose() }
Write-Host "generado: invalid-xml.xlsx"

# missing-parts.xlsx: no hay xl/workbook.xml (faltan partes obligatorias).
$missing = Join-Path $outDir 'missing-parts.xlsx'
if (Test-Path -LiteralPath $missing) { Remove-Item -LiteralPath $missing -Force }
$zip = [System.IO.Compression.ZipFile]::Open($missing, [System.IO.Compression.ZipArchiveMode]::Create)
try {
    Add-ZipPart -Zip $zip -Name '[Content_Types].xml' -Content $contentTypes
    Add-ZipPart -Zip $zip -Name '_rels/.rels' -Content $relsRoot
} finally { $zip.Dispose() }
Write-Host "generado: missing-parts.xlsx"

# empty-sheet.xlsx: hoja valida pero sin celdas con valor.
$emptyWorkbook = @'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Vacia" sheetId="1" r:id="rId1"/></sheets></workbook>
'@
$emptyRels = @'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/></Relationships>
'@
$emptySheet = @'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData/></worksheet>
'@
$empty = Join-Path $outDir 'empty-sheet.xlsx'
if (Test-Path -LiteralPath $empty) { Remove-Item -LiteralPath $empty -Force }
$zip = [System.IO.Compression.ZipFile]::Open($empty, [System.IO.Compression.ZipArchiveMode]::Create)
try {
    Add-ZipPart -Zip $zip -Name '[Content_Types].xml' -Content $contentTypes
    Add-ZipPart -Zip $zip -Name '_rels/.rels' -Content $relsRoot
    Add-ZipPart -Zip $zip -Name 'xl/workbook.xml' -Content $emptyWorkbook
    Add-ZipPart -Zip $zip -Name 'xl/_rels/workbook.xml.rels' -Content $emptyRels
    Add-ZipPart -Zip $zip -Name 'xl/worksheets/sheet1.xml' -Content $emptySheet
} finally { $zip.Dispose() }
Write-Host "generado: empty-sheet.xlsx"

# fake.txt: texto plano (en el test se renombra a .xlsx -> EXCEL_NOT_ZIP).
$fake = Join-Path $outDir 'fake.txt'
[System.IO.File]::WriteAllText($fake, 'no es un archivo ZIP valido', $utf8)
Write-Host "generado: fake.txt"

# truncated.xlsx: basic.xlsx cortado a la mitad (ZIP invalido).
$truncated = Join-Path $outDir 'truncated.xlsx'
$bytes = [System.IO.File]::ReadAllBytes($basic)
$half = [int]($bytes.Length / 2)
$out = New-Object byte[] $half
[System.Array]::Copy($bytes, $out, $half)
[System.IO.File]::WriteAllBytes($truncated, $out)
Write-Host "generado: truncated.xlsx"

Write-Host "fixtures listos en: $outDir"