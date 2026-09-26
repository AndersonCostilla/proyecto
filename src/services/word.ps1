# word-service: genera un .docx valido (OOXML) de forma determinista.
# Entrada: archivo .txt/.md en job/input/ o, en su defecto, la especificacion
# de requisitos (objetivo + constraints). Salida: output/documento.docx.

$ErrorActionPreference = 'Stop'

$PwxWordOutputName = 'documento.docx'
$PwxWordMaxParagraphs = 20000
$PwxWordMaxEntryBytes = 52428800
# Timestamp fijo para entradas ZIP (ver comentario en excel.ps1): determinismo binario.
[DateTimeOffset]$PwxWordZipTimestamp = [DateTimeOffset]::new(2000, 1, 1, 0, 0, 0, [TimeSpan]::Zero)

function Initialize-PwxWordTypes {
    Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue | Out-Null
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue | Out-Null
}

function ConvertTo-PwxWordXmlText {
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

function Test-PwxWordZipArchivePart {
    param([System.IO.Compression.ZipArchive]$Zip, [string]$EntryName)
    foreach ($e in $Zip.Entries) {
        if ($e.FullName -eq $EntryName) { return $true }
    }
    return $false
}

function Read-PwxWordZipEntryText {
    param([System.IO.Compression.ZipArchive]$Zip, [string]$EntryName, [long]$MaxBytes)
    $entry = $null
    foreach ($e in $Zip.Entries) {
        if ($e.FullName -eq $EntryName) { $entry = $e; break }
    }
    if ($null -eq $entry) { return $null }
    if ($entry.Length -gt $MaxBytes) {
        return [pscustomobject]@{ error = 'WORD_LIMITS_EXCEEDED'; detail = "Part '$EntryName' demasiado grande ($($entry.Length) bytes)" }
    }
    $s = $entry.Open()
    try {
        $ms = New-Object System.IO.MemoryStream
        try {
            $s.CopyTo($ms)
            return [System.Text.Encoding]::UTF8.GetString($ms.ToArray())
        }
        finally { $ms.Dispose() }
    }
    finally { $s.Dispose() }
}

# Escritor determinista del .docx: partes en orden fijo, UTF-8 sin BOM,
# timestamp ZIP constante. El mismo input produce bytes identicos.
function Write-PwxWordDoc {
    param([string]$Path, [string[]]$Paragraphs)
    Initialize-PwxWordTypes

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
    [void]$sb.Append('<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>')
    foreach ($p in @($Paragraphs)) {
        if ([string]::IsNullOrEmpty($p)) {
            [void]$sb.Append('<w:p/>')
        }
        else {
            [void]$sb.Append('<w:p><w:r><w:t xml:space="preserve">')
            [void]$sb.Append((ConvertTo-PwxWordXmlText -Text $p))
            [void]$sb.Append('</w:t></w:r></w:p>')
        }
    }
    [void]$sb.Append('<w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" w:header="708" w:footer="708" w:gutter="0"/></w:sectPr>')
    [void]$sb.Append('</w:body></w:document>')

    $parts = [ordered]@{
        '[Content_Types].xml' = @'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>
'@
        '_rels/.rels' = @'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>
'@
        'word/document.xml' = $sb.ToString()
    }

    $tmp = Join-Path ([System.IO.Path]::GetDirectoryName($Path)) ('.' + ([System.IO.Path]::GetFileName($Path)) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $zip = [System.IO.Compression.ZipFile]::Open($tmp, [System.IO.Compression.ZipArchiveMode]::Create)
        try {
            foreach ($entry in $parts.Keys) {
                $e = $zip.CreateEntry($entry, [System.IO.Compression.CompressionLevel]::Optimal)
                $e.LastWriteTime = $PwxWordZipTimestamp
                $s = $e.Open()
                try {
                    $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$parts[$entry])
                    $s.Write($bytes, 0, $bytes.Length)
                }
                finally { $s.Dispose() }
            }
        }
        finally { $zip.Dispose() }
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

# Lectura del .docx: devuelve la lista de parrafos (texto de cada w:p).
function Read-PwxWordDoc {
    param([string]$Path)
    Initialize-PwxWordTypes
    $zip = $null
    try {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($Path)
    }
    catch {
        return (New-PwxServiceError -Code 'WORD_NOT_ZIP' -Detail $_.Exception.Message)
    }
    try {
        $missing = @()
        foreach ($part in @('[Content_Types].xml', '_rels/.rels', 'word/document.xml')) {
            if (-not (Test-PwxWordZipArchivePart -Zip $zip -EntryName $part)) { $missing += $part }
        }
        if ($missing.Count -gt 0) {
            return (New-PwxServiceError -Code 'WORD_MISSING_PARTS' -Detail ($missing -join ', '))
        }
        $docXml = Read-PwxWordZipEntryText -Zip $zip -EntryName 'word/document.xml' -MaxBytes $PwxWordMaxEntryBytes
        if ($null -eq $docXml) {
            return (New-PwxServiceError -Code 'WORD_MISSING_PARTS' -Detail 'word/document.xml')
        }
        if ($docXml -is [pscustomobject]) {
            return (New-PwxServiceError -Code $docXml.error -Detail $docXml.detail)
        }
        $xml = $null
        try {
            $xml = [xml]$docXml
        }
        catch {
            return (New-PwxServiceError -Code 'WORD_BAD_XML' -Detail $_.Exception.Message)
        }
        $ns = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
        $ns.AddNamespace('w', 'http://schemas.openxmlformats.org/wordprocessingml/2006/main')
        $nodes = $xml.SelectNodes('//w:body/w:p', $ns)
        $paragraphs = @()
        foreach ($node in $nodes) {
            $parts = $node.SelectNodes('.//w:t', $ns)
            $text = ''
            foreach ($t in $parts) { $text += $t.InnerText }
            $paragraphs += $text
        }
        return [pscustomobject]@{
            ok         = $true
            code       = $null
            detail     = $null
            paragraphs = $paragraphs
        }
    }
    finally {
        if ($null -ne $zip) { $zip.Dispose() }
    }
}

# Contrato del servicio: @{ ok=$true|$false; error=$null|<codigo> }
function Invoke-PwxService_word_service {
    param([string]$JobId)
    Initialize-PwxWordTypes
    try {
        $resolve = Resolve-PwxTextJobSource -JobId $JobId -CodePrefix 'WORD'
        if (-not $resolve.ok) {
            return [pscustomobject]@{ ok = $false; error = $resolve.code }
        }

        $paragraphs = if ($resolve.source -eq 'file') { @(Get-PwxTextFileParagraphs -Path $resolve.path) } else { @($resolve.paragraphs) }
        if ($paragraphs.Count -eq 0) {
            return [pscustomobject]@{ ok = $false; error = 'WORD_EMPTY_INPUT' }
        }
        if ($paragraphs.Count -gt $PwxWordMaxParagraphs) {
            return [pscustomobject]@{ ok = $false; error = 'WORD_LIMITS_EXCEEDED' }
        }

        $found = Find-PwxJob -JobId $JobId
        $outputDir = Join-Path $found.JobDir 'output'
        New-PwxDirectory -Path $outputDir | Out-Null

        $finalPath = Join-Path $outputDir $PwxWordOutputName
        Write-PwxWordDoc -Path $finalPath -Paragraphs $paragraphs

        if (-not (Test-Path -LiteralPath $finalPath)) {
            return [pscustomobject]@{ ok = $false; error = 'WORD_INTERNAL' }
        }

        Add-PwxJobFile -JobId $JobId -Bucket 'output' -Path $finalPath | Out-Null

        $sha = Get-PwxSha256 -Path $finalPath
        Add-PwxEvent -JobId $JobId -Component 'service.word' -Action 'word.generated' -Data @{
            file       = $PwxWordOutputName
            paragraphs = $paragraphs.Count
            source     = $resolve.source
            sha256     = $sha
        }
        Write-PwxLog -Component 'service.word' -Message "word-service genero $PwxWordOutputName para $JobId (parrafos=$($paragraphs.Count), fuente=$($resolve.source), sha256=$sha)" -JobId $JobId

        return [pscustomobject]@{
            ok         = $true
            error      = $null
            file       = $PwxWordOutputName
            paragraphs = $paragraphs.Count
            sha256     = $sha
        }
    }
    catch {
        Write-PwxLog -Component 'service.word' -Level 'ERROR' -Message "word-service fallo: $($_.Exception.Message)" -JobId $JobId
        return [pscustomobject]@{ ok = $false; error = 'WORD_INTERNAL' }
    }
}

# Validador QA: estructura OOXML valida + parrafos identicos a la fuente.
function Test-PwxWordOutput {
    param([string]$JobId)
    Initialize-PwxWordTypes
    try {
        $snap = @(Get-PwxOutputSnapshot -JobId $JobId)
        $out = @($snap | Where-Object { $_.name -like '*.docx' })
        if ($out.Count -eq 0) {
            return (New-PwxServiceValidation $false 'No hay archivo .docx en output/')
        }
        if ($out.Count -gt 1) {
            return (New-PwxServiceValidation $false 'Mas de un archivo .docx en output/')
        }
        $read = Read-PwxWordDoc -Path $out[0].full
        if (-not $read.ok) {
            return (New-PwxServiceValidation $false "$($read.code): $($read.detail)")
        }
        $totalChars = 0
        foreach ($p in $read.paragraphs) { $totalChars += $p.Length }
        if ($totalChars -eq 0) {
            return (New-PwxServiceValidation $false 'Documento sin texto')
        }
        $expected = Get-PwxTextExpectedParagraphs -JobId $JobId
        return (Compare-PwxParagraphSequence -Expected $expected -Actual $read.paragraphs)
    }
    catch {
        return (New-PwxServiceValidation $false "WORD_INTERNAL: $($_.Exception.Message)")
    }
}
