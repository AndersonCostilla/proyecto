$PwxWordMaxInputBytes = 1048576
$PwxWordOutputName = 'documento-profesional.docx'
[DateTimeOffset]$PwxWordZipTimestamp = [DateTimeOffset]::new(2000, 1, 1, 0, 0, 0, [TimeSpan]::Zero)

function Initialize-PwxWordTypes {
    Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue | Out-Null
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue | Out-Null
}

function ConvertTo-PwxWordXmlText {
    param([AllowNull()][string]$Text)
    if ($null -eq $Text) { return '' }
    return [System.Security.SecurityElement]::Escape($Text)
}

function ConvertTo-PwxWordParagraphXml {
    param(
        [Parameter(Mandatory)][string]$Text,
        [string]$Style = 'Normal'
    )
    $safe = ConvertTo-PwxWordXmlText -Text $Text
    return ('<w:p><w:pPr><w:pStyle w:val="{0}"/></w:pPr><w:r><w:t xml:space="preserve">{1}</w:t></w:r></w:p>' -f $Style, $safe)
}

function ConvertTo-PwxWordDocumentBody {
    param([Parameter(Mandatory)][string]$Text, [Parameter(Mandatory)][object]$Job)
    $paragraphs = New-Object System.Collections.ArrayList
    $lines = $Text -split "`r?`n"
    $hasMeaningfulText = $false
    foreach ($lineRaw in $lines) {
        $line = [string]$lineRaw
        $trimmed = $line.Trim()
        if (-not $trimmed) { continue }
        $style = 'Normal'
        $content = $trimmed
        if ($trimmed -match '^###\s+(.+)$') { $style = 'Heading2'; $content = $matches[1].Trim() }
        elseif ($trimmed -match '^##\s+(.+)$') { $style = 'Heading1'; $content = $matches[1].Trim() }
        elseif ($trimmed -match '^#\s+(.+)$') { $style = 'Title'; $content = $matches[1].Trim() }
        elseif ($trimmed -match '^[-*]\s+(.+)$') { $style = 'List'; $content = '• ' + $matches[1].Trim() }
        [void]$paragraphs.Add((ConvertTo-PwxWordParagraphXml -Text $content -Style $style))
        $hasMeaningfulText = $true
    }
    if (-not $hasMeaningfulText) {
        [void]$paragraphs.Add((ConvertTo-PwxWordParagraphXml -Text 'Documento profesional' -Style 'Title'))
        [void]$paragraphs.Add((ConvertTo-PwxWordParagraphXml -Text $Job.description -Style 'Normal'))
    }
    return ($paragraphs -join '')
}

function Get-PwxWordSourceText {
    param([Parameter(Mandatory)][string]$JobId)
    $found = Find-PwxJob -JobId $JobId
    if (-not $found) { throw "Trabajo inexistente: $JobId" }
    $inputDir = Join-Path $found.JobDir 'input'
    $sources = @(Get-ChildItem -LiteralPath $inputDir -File -ErrorAction SilentlyContinue | Where-Object {
        $_.Extension.ToLowerInvariant() -in @('.txt', '.md')
    })
    if ($sources.Count -gt 1) {
        return [pscustomobject]@{ ok = $false; error = 'WORD_MULTIPLE_TEXT_INPUTS'; detail = 'Adjunta un solo archivo .txt o .md para producir el documento Word.' }
    }
    if ($sources.Count -eq 1) {
        $source = $sources[0]
        if ($source.Length -gt $PwxWordMaxInputBytes) {
            return [pscustomobject]@{ ok = $false; error = 'WORD_INPUT_TOO_LARGE'; detail = "El archivo supera $PwxWordMaxInputBytes bytes." }
        }
        try {
            $text = [System.IO.File]::ReadAllText($source.FullName, [System.Text.Encoding]::UTF8)
        }
        catch {
            return [pscustomobject]@{ ok = $false; error = 'WORD_INPUT_UNREADABLE'; detail = $_.Exception.Message }
        }
        if ([string]::IsNullOrWhiteSpace($text)) {
            return [pscustomobject]@{ ok = $false; error = 'WORD_INPUT_EMPTY'; detail = 'El archivo de texto está vacío.' }
        }
        return [pscustomobject]@{ ok = $true; text = $text; source = $source.Name }
    }

    $job = Get-PwxJob -JobId $JobId
    $fallback = "# Documento profesional`n`n$($job.description)"
    if ($job.requirements -and $job.requirements.objective) {
        $fallback += "`n`n## Objetivo`n$($job.requirements.objective)"
    }
    return [pscustomobject]@{ ok = $true; text = $fallback; source = 'descripción del pedido' }
}

function Add-PwxWordZipTextEntry {
    param(
        [Parameter(Mandatory)][System.IO.Compression.ZipArchive]$Zip,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Content
    )
    $entry = $Zip.CreateEntry($Name, [System.IO.Compression.CompressionLevel]::Optimal)
    $entry.LastWriteTime = $PwxWordZipTimestamp
    $stream = $entry.Open()
    try {
        $writer = New-Object System.IO.StreamWriter($stream, (New-Object System.Text.UTF8Encoding($false)))
        try { $writer.Write($Content) }
        finally { $writer.Dispose() }
    }
    finally { $stream.Dispose() }
}

function Write-PwxWordDocument {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$BodyXml,
        [Parameter(Mandatory)][string]$Title
    )
    Initialize-PwxWordTypes
    $parent = Split-Path -Parent $Path
    New-PwxDirectory -Path $parent | Out-Null
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
    $file = [System.IO.File]::Open($Path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::ReadWrite)
    try {
        $zip = New-Object System.IO.Compression.ZipArchive($file, [System.IO.Compression.ZipArchiveMode]::Create, $true)
        try {
            $contentTypes = @'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
  <Default Extension="xml" ContentType="application/xml"/>
  <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
  <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>
  <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>
  <Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>
</Types>
'@
            $rootRels = @'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
  <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>
  <Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/>
</Relationships>
'@
            $documentRels = @'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
</Relationships>
'@
            $styles = @'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
  <w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Aptos" w:hAnsi="Aptos"/><w:sz w:val="22"/></w:rPr></w:rPrDefault></w:docDefaults>
  <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style>
  <w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/><w:basedOn w:val="Normal"/><w:rPr><w:b/><w:sz w:val="36"/><w:color w:val="24243A"/></w:rPr><w:pPr><w:spacing w:after="240"/></w:pPr></w:style>
  <w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="Heading 1"/><w:basedOn w:val="Normal"/><w:rPr><w:b/><w:sz w:val="28"/><w:color w:val="4F46C8"/></w:rPr><w:pPr><w:spacing w:before="220" w:after="120"/></w:pPr></w:style>
  <w:style w:type="paragraph" w:styleId="Heading2"><w:name w:val="Heading 2"/><w:basedOn w:val="Normal"/><w:rPr><w:b/><w:sz w:val="24"/><w:color w:val="50566B"/></w:rPr><w:pPr><w:spacing w:before="160" w:after="80"/></w:pPr></w:style>
  <w:style w:type="paragraph" w:styleId="List"><w:name w:val="List"/><w:basedOn w:val="Normal"/><w:pPr><w:ind w:left="360" w:hanging="180"/><w:spacing w:after="60"/></w:pPr></w:style>
</w:styles>
'@
            $safeTitle = ConvertTo-PwxWordXmlText -Text $Title
            $document = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>{0}<w:sectPr><w:pgSz w:w="12240" w:h="15840"/><w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440"/></w:sectPr></w:body></w:document>' -f $BodyXml)
            $timestamp = '2000-01-01T00:00:00Z'
            $core = ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?><cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:dcmitype="http://purl.org/dc/dcmitype/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"><dc:title>{0}</dc:title><dc:creator>PWX</dc:creator><cp:lastModifiedBy>PWX</cp:lastModifiedBy><dcterms:created xsi:type="dcterms:W3CDTF">{1}</dcterms:created><dcterms:modified xsi:type="dcterms:W3CDTF">{1}</dcterms:modified></cp:coreProperties>' -f $safeTitle, $timestamp)
            $app = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties" xmlns:vt="http://schemas.openxmlformats.org/officeDocument/2006/docPropsVTypes"><Application>PWX</Application></Properties>'
            Add-PwxWordZipTextEntry -Zip $zip -Name '[Content_Types].xml' -Content $contentTypes
            Add-PwxWordZipTextEntry -Zip $zip -Name '_rels/.rels' -Content $rootRels
            Add-PwxWordZipTextEntry -Zip $zip -Name 'word/document.xml' -Content $document
            Add-PwxWordZipTextEntry -Zip $zip -Name 'word/_rels/document.xml.rels' -Content $documentRels
            Add-PwxWordZipTextEntry -Zip $zip -Name 'word/styles.xml' -Content $styles
            Add-PwxWordZipTextEntry -Zip $zip -Name 'docProps/core.xml' -Content $core
            Add-PwxWordZipTextEntry -Zip $zip -Name 'docProps/app.xml' -Content $app
        }
        finally { $zip.Dispose() }
    }
    finally { $file.Dispose() }
}

function Test-PwxWordOutput {
    param([Parameter(Mandatory)][string]$JobId)
    $found = Find-PwxJob -JobId $JobId
    if (-not $found) { return [pscustomobject]@{ ok = $false; detail = "Trabajo inexistente: $JobId" } }
    $output = Join-Path $found.JobDir 'output'
    $files = @(Get-ChildItem -LiteralPath $output -File -Filter '*.docx' -ErrorAction SilentlyContinue)
    if ($files.Count -ne 1) { return [pscustomobject]@{ ok = $false; detail = 'Se esperaba exactamente un archivo .docx de salida.' } }
    Initialize-PwxWordTypes
    $zip = $null
    try {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($files[0].FullName)
        $required = @('[Content_Types].xml', '_rels/.rels', 'word/document.xml', 'word/styles.xml')
        foreach ($name in $required) {
            if (-not ($zip.Entries | Where-Object { $_.FullName -eq $name })) {
                return [pscustomobject]@{ ok = $false; detail = "El documento Word no contiene $name" }
            }
        }
        $entry = $zip.Entries | Where-Object { $_.FullName -eq 'word/document.xml' } | Select-Object -First 1
        $stream = $entry.Open()
        try {
            $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)
            try { $xmlText = $reader.ReadToEnd() }
            finally { $reader.Dispose() }
        }
        finally { $stream.Dispose() }
        [xml]$xml = $xmlText
        $textNodes = @($xml.SelectNodes('//*[local-name()="t"]'))
        if ($textNodes.Count -eq 0) { return [pscustomobject]@{ ok = $false; detail = 'El documento Word no contiene texto.' } }
        return [pscustomobject]@{ ok = $true; detail = "$($files[0].Name): $($textNodes.Count) nodos de texto" }
    }
    catch {
        return [pscustomobject]@{ ok = $false; detail = "DOCX inválido: $($_.Exception.Message)" }
    }
    finally {
        if ($zip) { $zip.Dispose() }
    }
}

function Invoke-PwxService_word_service {
    param([Parameter(Mandatory)][string]$JobId)
    $job = Get-PwxJob -JobId $JobId
    if (-not $job) { return [pscustomobject]@{ ok = $false; error = 'JOB_NOT_FOUND' } }
    $source = Get-PwxWordSourceText -JobId $JobId
    if (-not $source.ok) {
        Write-PwxLog -Component 'service.word' -Level 'WARN' -Message "Word no producido: $($source.error)" -JobId $JobId
        return [pscustomobject]@{ ok = $false; error = $source.error; detail = $source.detail }
    }
    $found = Find-PwxJob -JobId $JobId
    $output = Assert-PwxSafeWorkspacePath -WorkspacePath $found.JobDir -Path (Join-Path $found.JobDir ('output\' + $PwxWordOutputName))
    try {
        $body = ConvertTo-PwxWordDocumentBody -Text $source.text -Job $job
        $title = if ($job.requirements -and $job.requirements.objective) { [string]$job.requirements.objective } else { 'Documento profesional' }
        Write-PwxWordDocument -Path $output -BodyXml $body -Title $title
        Add-PwxJobFile -JobId $JobId -Bucket 'output' -Path $output | Out-Null
        Write-PwxLog -Component 'service.word' -Message "Documento Word producido desde $($source.source)" -JobId $JobId
        Add-PwxEvent -JobId $JobId -Component 'service.word' -Action 'document.produced' -Data @{ source = $source.source; output = $PwxWordOutputName }
        return [pscustomobject]@{ ok = $true; output = $output; source = $source.source }
    }
    catch {
        Write-PwxLog -Component 'service.word' -Level 'ERROR' -Message "Error produciendo Word: $($_.Exception.Message)" -JobId $JobId
        return [pscustomobject]@{ ok = $false; error = 'WORD_WRITE_FAILED'; detail = $_.Exception.Message }
    }
}
