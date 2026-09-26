# pdf-service: genera un PDF 1.4 valido de forma determinista (sin dependencias).
# Entrada: archivo .txt/.md en job/input/ o, en su defecto, la especificacion
# de requisitos. Salida: output/documento.pdf
#
# El PDF se construye como texto Latin-1 (1 char = 1 byte) para poder calcular
# los offsets de la xref con exactitud de byte. El texto se translitera a
# WinAnsi-compatible (acentos espanoles OK; tipografia Unicode -> equivalente ASCII).

$ErrorActionPreference = 'Stop'

$PwxPdfOutputName = 'documento.pdf'
$PwxPdfMaxEntryChars = 52428800
$PwxPdfPageWidth = 595   # A4
$PwxPdfPageHeight = 842
$PwxPdfMargin = 50
$PwxPdfBodySize = 10
$PwxPdfBodyLeading = 14
$PwxPdfTitleSize = 14
$PwxPdfTitleLeading = 20
$PwxPdfBodyMaxChars = 95
$PwxPdfTitleMaxChars = 70

# Translitera a texto WinAnsi-compatible (chars <= 0xFF) de forma determinista.
function ConvertTo-PwxPdfText {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $Text.ToCharArray()) {
        $c = [int]$ch
        if ($c -lt 0x20 -or $c -eq 0x7F) {
            [void]$sb.Append(' ')
            continue
        }
        if ($c -ge 0x20 -and $c -le 0x7E) {
            [void]$sb.Append($ch)
            continue
        }
        if ($c -ge 0xA0 -and $c -le 0xFF) {
            # Latin1/WinAnsi comparten estas posiciones (acentos espanoles incluidos)
            [void]$sb.Append($ch)
            continue
        }
        # WinAnsi 0x80-0x9F: euros y comillas tipograficas comunes
        if ($c -eq 0x20AC) { [void]$sb.Append([char]0x80); continue }   # euro
        if ($c -eq 0x2013 -or $c -eq 0x2014) { [void]$sb.Append('-'); continue }  # dashes
        if ($c -eq 0x2018 -or $c -eq 0x2019) { [void]$sb.Append("'"); continue }
        if ($c -eq 0x201C -or $c -eq 0x201D) { [void]$sb.Append('"'); continue }
        if ($c -eq 0x2026) { [void]$sb.Append('...'); continue }
        # Ultimo recurso: quitar diacriticos; si no es ASCII, '?'
        $dec = $ch.ToString().Normalize([System.Text.NormalizationForm]::FormD)
        $mapped = ''
        $ok = $true
        foreach ($d in $dec.ToCharArray()) {
            $cat = [System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($d)
            if ($cat -eq [System.Globalization.UnicodeCategory]::NonSpacingMark) { continue }
            if ([int]$d -gt 0x7E) { $ok = $false; break }
            $mapped += $d
        }
        if ($ok -and $mapped -ne '') { [void]$sb.Append($mapped) }
        else { [void]$sb.Append('?') }
    }
    return $sb.ToString()
}

# Escapa un literal PDF: ( ) \
function ConvertTo-PwxPdfLiteral {
    param([string]$Text)
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $Text.ToCharArray()) {
        if ($ch -eq '(' -or $ch -eq ')' -or $ch -eq '\') { [void]$sb.Append('\') }
        [void]$sb.Append($ch)
    }
    return $sb.ToString()
}

# Word-wrap determinista: parte por espacios; palabras mas largas que el
# limite van solas en su linea (sin partir, para no alterar el contenido).
function Split-PwxPdfWrap {
    param([string]$Text, [int]$MaxChars)
    $t = $Text.Trim()
    if ($t -eq '') { return @() }
    if ($t.Length -le $MaxChars) { return @($t) }
    $words = @($t -split '\s+' | Where-Object { $_ -ne '' })
    $lines = @()
    $cur = ''
    foreach ($w in $words) {
        if ($cur -eq '') {
            $cur = $w
        }
        elseif (($cur.Length + 1 + $w.Length) -le $MaxChars) {
            $cur = $cur + ' ' + $w
        }
        else {
            $lines += $cur
            $cur = $w
        }
    }
    if ($cur -ne '') { $lines += $cur }
    return @($lines)
}

# Lineas de salida (titulo + cuerpo) ya transliteradas y con wrap.
# El validador QA reconstruye esta misma lista desde la fuente y la compara.
function Get-PwxPdfLineList {
    param([string[]]$Paragraphs)
    $lines = @()
    $first = $true
    foreach ($p in @($Paragraphs)) {
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        $text = ConvertTo-PwxPdfText -Text $p
        if ($first) {
            foreach ($l in (Split-PwxPdfWrap -Text $text -MaxChars $PwxPdfTitleMaxChars)) {
                $lines += [pscustomobject]@{ text = $l; font = 'F2'; size = $PwxPdfTitleSize; leading = $PwxPdfTitleLeading }
            }
            $first = $false
        }
        else {
            foreach ($l in (Split-PwxPdfWrap -Text $text -MaxChars $PwxPdfBodyMaxChars)) {
                $lines += [pscustomobject]@{ text = $l; font = 'F1'; size = $PwxPdfBodySize; leading = $PwxPdfBodyLeading }
            }
        }
    }
    return @($lines)
}

function Write-PwxPdfDocument {
    param([string]$Path, [string[]]$Paragraphs)

    $lines = Get-PwxPdfLineList -Paragraphs $Paragraphs
    if ($lines.Count -eq 0) { throw 'PDF_EMPTY_INPUT' }

    # Paginacion determinista
    $pages = New-Object System.Collections.ArrayList
    $current = New-Object System.Collections.ArrayList
    $y = $PwxPdfPageHeight - $PwxPdfMargin
    foreach ($ln in $lines) {
        $h = [int]$ln.leading
        if (($y - $h) -lt $PwxPdfMargin -and $current.Count -gt 0) {
            [void]$pages.Add(@($current.ToArray()))
            $current = New-Object System.Collections.ArrayList
            $y = $PwxPdfPageHeight - $PwxPdfMargin
        }
        [void]$current.Add($ln)
        $y -= $h
    }
    if ($current.Count -gt 0) { [void]$pages.Add(@($current.ToArray())) }
    if ($pages.Count -eq 0) { throw 'PDF_EMPTY_INPUT' }

    # Contenido de cada pagina (stream)
    $contents = @()
    foreach ($page in $pages) {
        $sbC = New-Object System.Text.StringBuilder
        $py = $PwxPdfPageHeight - $PwxPdfMargin
        foreach ($ln in $page) {
            [void]$sbC.Append('BT /' + $ln.font + ' ' + $ln.size + ' Tf 1 0 0 1 ' + $PwxPdfMargin + ' ' + $py + ' Tm (' + (ConvertTo-PwxPdfLiteral -Text $ln.text) + ") Tj ET`n")
            $py -= [int]$ln.leading
        }
        $contents += $sbC.ToString()
    }

    # Objetos: 1 Catalog, 2 Pages, 3 F1, 4 F2, luego (5+2i) Page y (6+2i) Contents
    $kids = @()
    for ($i = 0; $i -lt $pages.Count; $i++) { $kids += ('{0} 0 R' -f (5 + 2 * $i)) }

    $objects = @()
    $objects += '<< /Type /Catalog /Pages 2 0 R >>'
    $objects += ('<< /Type /Pages /Kids [' + ($kids -join ' ') + '] /Count ' + $pages.Count + ' >>')
    $objects += '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>'
    $objects += '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>'
    for ($i = 0; $i -lt $pages.Count; $i++) {
        $pageObjNum = 5 + 2 * $i
        $contentObjNum = 6 + 2 * $i
        $objects += ('<< /Type /Page /Parent 2 0 R /MediaBox [0 0 ' + $PwxPdfPageWidth + ' ' + $PwxPdfPageHeight + '] /Resources << /Font << /F1 3 0 R /F2 4 0 R >> >> /Contents ' + $contentObjNum + ' 0 R >>')
        $stream = $contents[$i]
        $objects += ('<< /Length ' + $stream.Length + " >>`nstream`n" + $stream + 'endstream')
    }

    # Ensamblado con offsets de byte exactos (1 char Latin-1 = 1 byte)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("%PDF-1.4`n")
    [void]$sb.Append('%' + [char]0xE2 + [char]0xE3 + [char]0xD3 + [char]0xD3 + "`n")

    $offsets = New-Object int[] ($objects.Count + 1)
    for ($n = 1; $n -le $objects.Count; $n++) {
        $offsets[$n] = $sb.Length
        [void]$sb.Append("$n 0 obj`n")
        [void]$sb.Append($objects[$n - 1])
        [void]$sb.Append("`nendobj`n")
    }

    $xrefOffset = $sb.Length
    [void]$sb.Append("xref`n")
    [void]$sb.Append('0 ' + ($objects.Count + 1) + "`n")
    [void]$sb.Append('0000000000 65535 f ' + "`n")
    for ($n = 1; $n -le $objects.Count; $n++) {
        [void]$sb.Append(('{0:d10} {1:d5} n ' -f $offsets[$n], 0) + "`n")
    }
    [void]$sb.Append('trailer' + "`n")
    [void]$sb.Append('<< /Size ' + ($objects.Count + 1) + ' /Root 1 0 R >>' + "`n")
    [void]$sb.Append('startxref' + "`n")
    [void]$sb.Append("$xrefOffset`n")
    [void]$sb.Append('%%EOF' + "`n")

    $bytes = [System.Text.Encoding]::GetEncoding(28591).GetBytes($sb.ToString())
    $tmp = Join-Path ([System.IO.Path]::GetDirectoryName($Path)) ('.' + ([System.IO.Path]::GetFileName($Path)) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [System.IO.File]::WriteAllBytes($tmp, $bytes)
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

# Extrae las lineas Tj del PDF (orden de lectura) para comparacion del QA.
function Read-PwxPdfText {
    param([string]$Path)
    $text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::GetEncoding(28591))
    $pattern = '\((?<t>(?:\\[\\()]|[^\\()])*)\)\s*Tj'
    $out = @()
    foreach ($m in [regex]::Matches($text, $pattern)) {
        $t = $m.Groups['t'].Value
        $t = [regex]::Replace($t, '\\([\\()])', '$1')
        $out += $t
    }
    return @($out)
}

# Contrato del servicio: @{ ok=$true|$false; error=$null|<codigo> }
function Invoke-PwxService_pdf_service {
    param([string]$JobId)
    try {
        $resolve = Resolve-PwxTextJobSource -JobId $JobId -CodePrefix 'PDF'
        if (-not $resolve.ok) {
            return [pscustomobject]@{ ok = $false; error = $resolve.code }
        }

        $paragraphs = if ($resolve.source -eq 'file') { @(Get-PwxTextFileParagraphs -Path $resolve.path) } else { @($resolve.paragraphs) }
        if (-not (@($paragraphs | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count -gt 0)) {
            return [pscustomobject]@{ ok = $false; error = 'PDF_EMPTY_INPUT' }
        }

        $found = Find-PwxJob -JobId $JobId
        $outputDir = Join-Path $found.JobDir 'output'
        New-PwxDirectory -Path $outputDir | Out-Null

        $finalPath = Join-Path $outputDir $PwxPdfOutputName
        Write-PwxPdfDocument -Path $finalPath -Paragraphs $paragraphs

        if (-not (Test-Path -LiteralPath $finalPath)) {
            return [pscustomobject]@{ ok = $false; error = 'PDF_INTERNAL' }
        }

        Add-PwxJobFile -JobId $JobId -Bucket 'output' -Path $finalPath | Out-Null

        $sha = Get-PwxSha256 -Path $finalPath
        Add-PwxEvent -JobId $JobId -Component 'service.pdf' -Action 'pdf.generated' -Data @{
            file   = $PwxPdfOutputName
            source = $resolve.source
            sha256 = $sha
        }
        Write-PwxLog -Component 'service.pdf' -Message "pdf-service genero $PwxPdfOutputName para $JobId (fuente=$($resolve.source), sha256=$sha)" -JobId $JobId

        return [pscustomobject]@{
            ok     = $true
            error  = $null
            file   = $PwxPdfOutputName
            sha256 = $sha
        }
    }
    catch {
        Write-PwxLog -Component 'service.pdf' -Level 'ERROR' -Message "pdf-service fallo: $($_.Exception.Message)" -JobId $JobId
        return [pscustomobject]@{ ok = $false; error = 'PDF_INTERNAL' }
    }
}

# Validador QA: estructura PDF (xref con offsets reales) + texto igual a la fuente.
function Test-PwxPdfOutput {
    param([string]$JobId)
    try {
        $snap = @(Get-PwxOutputSnapshot -JobId $JobId)
        $out = @($snap | Where-Object { $_.name -like '*.pdf' })
        if ($out.Count -eq 0) {
            return (New-PwxServiceValidation $false 'No hay archivo .pdf en output/')
        }
        if ($out.Count -gt 1) {
            return (New-PwxServiceValidation $false 'Mas de un archivo .pdf en output/')
        }
        $path = $out[0].full
        $text = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::GetEncoding(28591))

        if (-not $text.StartsWith('%PDF-1.4')) {
            return (New-PwxServiceValidation $false 'Cabecera %PDF-1.4 ausente')
        }
        if ($text.TrimEnd() -notlike '*%%EOF') {
            return (New-PwxServiceValidation $false 'Cierre %%EOF ausente')
        }
        if ($text -notmatch '/Type /Catalog') {
            return (New-PwxServiceValidation $false 'Sin objeto Catalog')
        }
        $pageMatches = [regex]::Matches($text, '/Type /Page\b')
        if ($pageMatches.Count -eq 0) {
            return (New-PwxServiceValidation $false 'Sin paginas')
        }
        if ($text -notmatch '/Count (\d+)') {
            return (New-PwxServiceValidation $false 'Pages sin /Count')
        }
        $count = [int]$Matches[1]
        if ($count -ne $pageMatches.Count) {
            return (New-PwxServiceValidation $false ("/Count " + $count + " no coincide con paginas reales " + $pageMatches.Count))
        }

        # Integridad de xref: cada offset debe apuntar a "N 0 obj"
        if ($text -notmatch 'startxref\s+(\d+)\s+%%EOF\s*$') {
            return (New-PwxServiceValidation $false 'startxref/%%EOF invalidos')
        }
        $xr = [int]$Matches[1]
        if ($xr -le 0 -or $xr -ge $text.Length -or -not $text.Substring($xr).StartsWith('xref')) {
            return (New-PwxServiceValidation $false "startxref ($xr) no apunta a la tabla xref")
        }
        $xrefBody = $text.Substring($xr)
        $lines = @($xrefBody -split "`n")
        if ($lines.Count -lt 3 -or $lines[1] -notmatch '^0 (\d+)$') {
            return (New-PwxServiceValidation $false 'Cabecera de xref invalida')
        }
        $total = [int]$Matches[1]
        $entryLines = @($lines | Select-Object -Skip 2 -First $total)
        if ($entryLines.Count -ne $total) {
            return (New-PwxServiceValidation $false 'xref truncada')
        }
        for ($n = 1; $n -lt $total; $n++) {
            $entry = $entryLines[$n]
            if ($entry -notmatch '^(\d{10}) (\d{5}) n $') {
                return (New-PwxServiceValidation $false "Entrada xref $n con formato invalido")
            }
            $off = [int]$Matches[1]
            if ($off -le 0 -or $off -ge $text.Length) {
                return (New-PwxServiceValidation $false "Offset fuera de rango para objeto $n")
            }
            $marker = "$n 0 obj"
            if (-not $text.Substring($off).StartsWith($marker)) {
                return (New-PwxServiceValidation $false ("Offset de objeto " + $n + " no apunta a '" + $marker + "'"))
            }
        }

        # Texto identico a la fuente (linea a linea, misma transformacion)
        $actual = Read-PwxPdfText -Path $path
        $expectedLines = Get-PwxPdfLineList -Paragraphs (Get-PwxTextExpectedParagraphs -JobId $JobId)
        $expectedText = @($expectedLines | ForEach-Object { $_.text })
        return (Compare-PwxParagraphSequence -Expected $expectedText -Actual $actual)
    }
    catch {
        return (New-PwxServiceValidation $false "PDF_INTERNAL: $($_.Exception.Message)")
    }
}
