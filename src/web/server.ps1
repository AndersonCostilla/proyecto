# Servidor web local para operadores de PWX.
# Por diseño escucha solo en loopback: no debe exponerse a Internet sin
# autenticación, HTTPS, control de roles y una revisión de seguridad.

function Get-PwxWebPublicRoot {
    $root = (Get-PwxConfig).Root
    return (Join-Path $root 'src\web\public')
}

function ConvertTo-PwxWebJsonBytes {
    param([object]$Object)
    $text = $Object | ConvertTo-Json -Depth 20
    return [System.Text.Encoding]::UTF8.GetBytes($text)
}

function Send-PwxWebJson {
    param(
        [Parameter(Mandatory)][System.Net.HttpListenerContext]$Context,
        [Parameter(Mandatory)][object]$Object,
        [int]$StatusCode = 200
    )
    $bytes = ConvertTo-PwxWebJsonBytes -Object $Object
    $Context.Response.StatusCode = $StatusCode
    $Context.Response.ContentType = 'application/json; charset=utf-8'
    $Context.Response.ContentEncoding = [System.Text.Encoding]::UTF8
    $Context.Response.ContentLength64 = $bytes.Length
    $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Context.Response.Close()
}

function Send-PwxWebError {
    param(
        [Parameter(Mandatory)][System.Net.HttpListenerContext]$Context,
        [Parameter(Mandatory)][string]$Code,
        [Parameter(Mandatory)][string]$Message,
        [int]$StatusCode = 400
    )
    Send-PwxWebJson -Context $Context -StatusCode $StatusCode -Object ([ordered]@{
        ok      = $false
        code    = $Code
        message = $Message
    })
}

function Send-PwxWebFile {
    param(
        [Parameter(Mandatory)][System.Net.HttpListenerContext]$Context,
        [Parameter(Mandatory)][string]$Path,
        [string]$ContentType
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        Send-PwxWebError -Context $Context -Code 'NOT_FOUND' -Message 'Archivo no encontrado' -StatusCode 404
        return
    }
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $Context.Response.StatusCode = 200
    $Context.Response.ContentType = $ContentType
    $Context.Response.ContentLength64 = $bytes.Length
    $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Context.Response.Close()
}

function Get-PwxWebRequestJson {
    param([Parameter(Mandatory)][System.Net.HttpListenerRequest]$Request)
    if ($Request.ContentLength64 -gt 15728640) {
        throw 'La solicitud supera el límite de 15 MB'
    }
    $reader = New-Object System.IO.StreamReader($Request.InputStream, $Request.ContentEncoding)
    try {
        $text = $reader.ReadToEnd()
    }
    finally {
        $reader.Dispose()
    }
    if ([string]::IsNullOrWhiteSpace($text)) { return [pscustomobject]@{} }
    try {
        return ($text | ConvertFrom-Json)
    }
    catch {
        throw 'El cuerpo de la solicitud no contiene JSON válido'
    }
}

function Get-PwxWebQueryValue {
    param([Parameter(Mandatory)][System.Net.HttpListenerRequest]$Request, [Parameter(Mandatory)][string]$Name)
    $query = [string]$Request.Url.Query
    if ($query.StartsWith('?')) { $query = $query.Substring(1) }
    foreach ($pair in $query.Split('&', [System.StringSplitOptions]::RemoveEmptyEntries)) {
        $parts = $pair.Split('=', 2)
        $key = [System.Uri]::UnescapeDataString($parts[0].Replace('+', ' '))
        if ($key -eq $Name) {
            if ($parts.Count -eq 1) { return '' }
            return [System.Uri]::UnescapeDataString($parts[1].Replace('+', ' '))
        }
    }
    return ''
}

function Get-PwxWebString {
    param([object]$Object, [string]$Property)
    if ($null -eq $Object) { return '' }
    $prop = $Object.PSObject.Properties[$Property]
    if (-not $prop -or $null -eq $prop.Value) { return '' }
    return [string]$prop.Value
}

function Get-PwxWebInt {
    param([object]$Object, [string]$Property, [int]$Default = 1)
    $raw = Get-PwxWebString -Object $Object -Property $Property
    if (-not $raw) { return $Default }
    $value = 0
    if (-not [int]::TryParse($raw, [ref]$value)) { throw "El campo $Property debe ser un número entero" }
    return $value
}

function Get-PwxWebDouble {
    param([object]$Object, [string]$Property, [double]$Default = 0)
    $raw = Get-PwxWebString -Object $Object -Property $Property
    if (-not $raw) { return $Default }
    $value = 0.0
    if (-not [double]::TryParse($raw, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$value)) {
        throw "El campo $Property debe ser numérico"
    }
    return $value
}

function Get-PwxWebStringArray {
    param([object]$Object, [string]$Property)
    if ($null -eq $Object) { return @() }
    $prop = $Object.PSObject.Properties[$Property]
    if (-not $prop -or $null -eq $prop.Value) { return @() }
    return @($prop.Value | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function ConvertFrom-PwxWebBase64 {
    param([string]$Base64, [int]$MaxBytes)
    if ([string]::IsNullOrWhiteSpace($Base64)) { throw 'Archivo vacío' }
    try {
        $bytes = [System.Convert]::FromBase64String($Base64)
    }
    catch {
        throw 'El archivo recibido no está codificado correctamente'
    }
    if ($bytes.Length -eq 0) { throw 'Archivo vacío' }
    if ($bytes.Length -gt $MaxBytes) { throw "El archivo supera el límite de $MaxBytes bytes" }
    return $bytes
}

function Write-PwxWebTemporaryFile {
    param(
        [Parameter(Mandatory)][string]$FileName,
        [Parameter(Mandatory)][byte[]]$Bytes
    )
    if ([string]::IsNullOrWhiteSpace($FileName)) { throw 'El archivo debe tener nombre' }
    if ($FileName -match '[\\/:*?"<>|]') { throw 'Nombre de archivo inválido' }
    Assert-PwxSafeFileName -Name $FileName | Out-Null
    $dir = Join-Path (Get-PwxWorkspacePath) '_web_uploads'
    New-PwxDirectory -Path $dir | Out-Null
    $name = ([guid]::NewGuid().ToString('N')) + '-' + $FileName
    $target = Assert-PwxSafeWorkspacePath -WorkspacePath (Get-PwxWorkspacePath) -Path (Join-Path $dir $name)
    [System.IO.File]::WriteAllBytes($target, $Bytes)
    return $target
}

function Add-PwxWebJobInput {
    param([Parameter(Mandatory)][string]$JobId, [Parameter(Mandatory)][object]$Payload)
    $fileName = Get-PwxWebString -Object $Payload -Property 'fileName'
    $base64 = Get-PwxWebString -Object $Payload -Property 'contentBase64'
    $bytes = ConvertFrom-PwxWebBase64 -Base64 $base64 -MaxBytes 26214400
    $temp = Write-PwxWebTemporaryFile -FileName $fileName -Bytes $bytes
    try {
        return Add-PwxJobInputFile -JobId $JobId -SourcePath $temp -TargetName $fileName
    }
    finally {
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
    }
}

# Browser-only Word validation is deliberately separate from commercial jobs.
# It always uses a new temporary workspace and never creates a payment request.
$script:PwxWebWordTestMaxBytes = 1048576
$script:PwxWebWordTestRuns = @{}

function Get-PwxWebWordTestInput {
    param([Parameter(Mandatory)][object]$Payload)
    $fileName = Get-PwxWebString -Object $Payload -Property 'fileName'
    $extension = [System.IO.Path]::GetExtension($fileName).ToLowerInvariant()
    if ($extension -notin @('.md', '.txt')) {
        throw 'La prueba Word solo acepta un archivo .md o .txt en UTF-8'
    }
    Assert-PwxSafeFileName -Name $fileName | Out-Null
    $bytes = ConvertFrom-PwxWebBase64 -Base64 (Get-PwxWebString -Object $Payload -Property 'contentBase64') -MaxBytes $script:PwxWebWordTestMaxBytes
    return [pscustomobject]@{
        file_name = $fileName
        bytes     = $bytes
        title     = (Get-PwxWebString -Object $Payload -Property 'title').Trim()
    }
}

function Clear-PwxWebExpiredWordTests {
    $cutoff = (Get-Date).AddHours(-24)
    foreach ($runId in @($script:PwxWebWordTestRuns.Keys)) {
        $run = $script:PwxWebWordTestRuns[$runId]
        if ([datetime]$run.created_at -lt $cutoff) {
            Remove-Item -LiteralPath $run.root -Recurse -Force -ErrorAction SilentlyContinue
            $script:PwxWebWordTestRuns.Remove($runId)
        }
    }
}

function Invoke-PwxWebWordTest {
    param([Parameter(Mandatory)][object]$Payload)
    Clear-PwxWebExpiredWordTests
    $wordInput = Get-PwxWebWordTestInput -Payload $Payload
    $runId = [guid]::NewGuid().ToString('N')
    $baseTemp = if ($env:TEMP) { $env:TEMP } else { [System.IO.Path]::GetTempPath() }
    $runRoot = Join-Path $baseTemp ('pwx-word-web-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + $runId.Substring(0, 8))
    $workspace = Join-Path $runRoot 'workspace'
    $sourcePath = Join-Path $runRoot $wordInput.file_name
    $previousWorkspace = $env:PWX_WORKSPACE
    $previousPaymentPolicy = $env:PWX_REQUIRE_PAYMENT_BEFORE_PRODUCTION

    try {
        New-Item -ItemType Directory -Path $runRoot -Force | Out-Null
        [System.IO.File]::WriteAllBytes($sourcePath, $wordInput.bytes)
        # This change is scoped to this request and this temporary workspace only.
        $env:PWX_WORKSPACE = $workspace
        $env:PWX_REQUIRE_PAYMENT_BEFORE_PRODUCTION = 'false'

        $ollama = Get-PwxOllamaStatus
        $model = (Get-PwxConfig).Model
        $modelState = Test-PwxModelAvailable -Model $model
        if ($ollama.status -ne 'OK' -or $modelState -ne 'OK') {
            throw "Ollama/modelo no disponible. Ollama=$($ollama.status), Modelo=$modelState"
        }

        $client = New-PwxClient -Name 'Validacion Word Web' -Contact 'validacion-web@pwx.test'
        $title = if ($wordInput.title) { $wordInput.title.Substring(0, [Math]::Min(200, $wordInput.title.Length)) } else { 'Documento Word de validacion web' }
        $job = New-PwxJob -ClientId $client.id -Service 'word-service' -Description $title
        Add-PwxJobInputFile -JobId $job.id -SourcePath $sourcePath -TargetName $wordInput.file_name | Out-Null

        $requirementsRequest = @"
Selecciona obligatoriamente word-service.
Esto es una validacion tecnica local y aislada de un documento profesional Word.
Usa $($wordInput.file_name) como contenido de entrada.
La entrega requerida es un archivo DOCX profesional.
Conserva titulos, subtitulos, listas y parrafos.
El documento debe ser valido y no estar vacio.
"@
        $requirements = Invoke-PwxRequirementsAgent -JobId $job.id -Request $requirementsRequest
        if (-not $requirements.ok) { throw "Requisitos fallaron: $($requirements.code) $($requirements.error)" }
        if ($requirements.spec.service -ne 'word-service') {
            throw "El modelo selecciono '$($requirements.spec.service)', se esperaba word-service"
        }

        $production = Invoke-PwxProductionAgent -JobId $job.id
        if (-not $production.ok) { throw "Produccion fallo: $($production.error) $($production.detail)" }
        $delivery = New-PwxDelivery -JobId $job.id
        Approve-PwxDelivery -JobId $job.id -By 'web-word-test' | Out-Null
        $found = Find-PwxJob -JobId $job.id
        $outputPath = Join-Path $found.JobDir 'delivery\documento-profesional.docx'
        if (-not (Test-Path -LiteralPath $outputPath)) { throw 'No se encontro el documento Word de prueba' }

        $script:PwxWebWordTestRuns[$runId] = [pscustomobject]@{
            root       = $runRoot
            output_path = $outputPath
            created_at = Get-Date
        }
        return [ordered]@{
            run_id       = $runId
            state        = (Get-PwxJob -JobId $job.id).state
            qa           = $production.qa.verdict
            file_count   = $delivery.file_count
            download_url = "/api/word-tests/$runId/download"
            expires_at   = (Get-Date).AddHours(24).ToString('o')
        }
    }
    catch {
        Remove-Item -LiteralPath $runRoot -Recurse -Force -ErrorAction SilentlyContinue
        throw
    }
    finally {
        $env:PWX_WORKSPACE = $previousWorkspace
        $env:PWX_REQUIRE_PAYMENT_BEFORE_PRODUCTION = $previousPaymentPolicy
    }
}

function Send-PwxWebWordTestDownload {
    param([Parameter(Mandatory)][System.Net.HttpListenerContext]$Context, [Parameter(Mandatory)][string]$RunId)
    Clear-PwxWebExpiredWordTests
    if (-not $script:PwxWebWordTestRuns.ContainsKey($RunId)) {
        Send-PwxWebError -Context $Context -Code 'NOT_FOUND' -Message 'La prueba no existe o ya vencio' -StatusCode 404
        return
    }
    $run = $script:PwxWebWordTestRuns[$RunId]
    if (-not (Test-Path -LiteralPath $run.output_path)) {
        Send-PwxWebError -Context $Context -Code 'NOT_FOUND' -Message 'El documento temporal ya no esta disponible' -StatusCode 404
        return
    }
    $bytes = [System.IO.File]::ReadAllBytes($run.output_path)
    $Context.Response.StatusCode = 200
    $Context.Response.ContentType = 'application/vnd.openxmlformats-officedocument.wordprocessingml.document'
    $Context.Response.AddHeader('Content-Disposition', 'attachment; filename="documento-profesional.docx"')
    $Context.Response.ContentLength64 = $bytes.Length
    $Context.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Context.Response.Close()
}

function Add-PwxWebPaymentProof {
    param([Parameter(Mandatory)][string]$JobId, [Parameter(Mandatory)][object]$Payload)
    $fileName = Get-PwxWebString -Object $Payload -Property 'fileName'
    $base64 = Get-PwxWebString -Object $Payload -Property 'contentBase64'
    $reference = Get-PwxWebString -Object $Payload -Property 'reference'
    $bytes = ConvertFrom-PwxWebBase64 -Base64 $base64 -MaxBytes $PwxPaymentProofMaxBytes
    $temp = Write-PwxWebTemporaryFile -FileName $fileName -Bytes $bytes
    try {
        return Submit-PwxPaymentProof -JobId $JobId -Path $temp -Reference $reference
    }
    finally {
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
    }
}

function Get-PwxWebJobs {
    $clients = @{}
    foreach ($client in @(Get-PwxClients)) { $clients[$client.id] = $client }
    $jobs = @()
    foreach ($clientId in @($clients.Keys)) {
        foreach ($job in @(Get-PwxJobs -ClientId $clientId)) {
            $payment = $null
            if ($job.payment_id) { $payment = Get-PwxPayment -PaymentId ([string]$job.payment_id) }
            $jobs += [ordered]@{
                id             = $job.id
                client_id      = $job.client_id
                client_name    = $clients[$job.client_id].name
                service        = $job.service
                description    = $job.description
                state          = $job.state
                created_at     = $job.created_at
                updated_at     = $job.updated_at
                payment_status = if ($payment) { $payment.status } else { 'NOT_REQUESTED' }
                payment_id     = if ($payment) { $payment.id } else { $null }
                price          = $job.price
            }
        }
    }
    return @($jobs | Sort-Object updated_at -Descending)
}

function Get-PwxWebDashboard {
    $jobs = @(Get-PwxWebJobs)
    $payments = @()
    foreach ($job in $jobs) {
        if ($job.payment_id) { $payments += $job.payment_status }
    }
    return [ordered]@{
        clients = @(Get-PwxClients).Count
        jobs = $jobs.Count
        ready_for_production = @($jobs | Where-Object { $_.state -eq 'READY_FOR_PRODUCTION' }).Count
        pending_payment = @($payments | Where-Object { $_ -in @('REQUESTED', 'PROOF_SUBMITTED') }).Count
        delivered = @($jobs | Where-Object { $_.state -eq 'DELIVERED' }).Count
    }
}

function Invoke-PwxWebApi {
    param([Parameter(Mandatory)][System.Net.HttpListenerContext]$Context, [Parameter(Mandatory)][string]$Path)
    $request = $Context.Request
    $method = $request.HttpMethod.ToUpperInvariant()
    try {
        if ($method -eq 'GET' -and $Path -match '^/api/word-tests/([A-Za-z0-9]+)/download$') {
            Send-PwxWebWordTestDownload -Context $Context -RunId $matches[1]
            return
        }
        if ($method -eq 'POST' -and $Path -eq '/api/word-tests') {
            $body = Get-PwxWebRequestJson -Request $request
            $test = Invoke-PwxWebWordTest -Payload $body
            Send-PwxWebJson -Context $Context -Object ([ordered]@{ ok = $true; test = $test }) -StatusCode 201
            return
        }
        if ($method -eq 'GET' -and $Path -eq '/api/dashboard') {
            Send-PwxWebJson -Context $Context -Object ([ordered]@{ ok = $true; dashboard = Get-PwxWebDashboard })
            return
        }
        if ($method -eq 'GET' -and $Path -eq '/api/services') {
            $services = @(Get-PwxRegisteredServices | ForEach-Object {
                $full = Get-PwxService -ServiceId $_.id
                [ordered]@{
                    id = $_.id; name = $_.name; description = $full.description; base_price = $_.base_price
                    implemented = $_.implemented; requires_payment = $full.requiresPayment; pricing = $full.pricing; addons = $full.addons
                }
            })
            Send-PwxWebJson -Context $Context -Object ([ordered]@{ ok = $true; services = $services })
            return
        }
        if ($method -eq 'GET' -and $Path -eq '/api/clients') {
            Send-PwxWebJson -Context $Context -Object ([ordered]@{ ok = $true; clients = @(Get-PwxClients | Sort-Object name) })
            return
        }
        if ($method -eq 'GET' -and $Path -eq '/api/jobs') {
            Send-PwxWebJson -Context $Context -Object ([ordered]@{ ok = $true; jobs = Get-PwxWebJobs })
            return
        }
        if ($method -eq 'GET' -and $Path -eq '/api/payments') {
            $jobId = Get-PwxWebQueryValue -Request $request -Name 'jobId'
            if (-not $jobId) { throw 'Falta jobId' }
            Send-PwxWebJson -Context $Context -Object ([ordered]@{ ok = $true; payments = @(Get-PwxPaymentsForJob -JobId $jobId) })
            return
        }
        if ($method -eq 'POST' -and $Path -eq '/api/clients') {
            $body = Get-PwxWebRequestJson -Request $request
            $name = Get-PwxWebString -Object $body -Property 'name'
            $contact = Get-PwxWebString -Object $body -Property 'contact'
            if ([string]::IsNullOrWhiteSpace($name)) { throw 'El nombre del cliente es obligatorio' }
            $client = New-PwxClient -Name $name -Contact $contact
            Send-PwxWebJson -Context $Context -Object ([ordered]@{ ok = $true; client = $client }) -StatusCode 201
            return
        }
        if ($method -eq 'POST' -and $Path -eq '/api/requests') {
            $body = Get-PwxWebRequestJson -Request $request
            $clientId = Get-PwxWebString -Object $body -Property 'clientId'
            if (-not $clientId) {
                $name = Get-PwxWebString -Object $body -Property 'clientName'
                $contact = Get-PwxWebString -Object $body -Property 'contact'
                if (-not $name) { throw 'Seleccione un cliente o escriba su nombre' }
                $clientId = (New-PwxClient -Name $name -Contact $contact).id
            }
            $service = Get-PwxWebString -Object $body -Property 'service'
            $description = Get-PwxWebString -Object $body -Property 'description'
            if (-not $service) { throw 'Seleccione un servicio' }
            if (-not $description) { throw 'Describa la solicitud' }
            $job = New-PwxJob -ClientId $clientId -Service $service -Description $description
            Send-PwxWebJson -Context $Context -Object ([ordered]@{ ok = $true; job = $job }) -StatusCode 201
            return
        }
        if ($method -eq 'POST' -and $Path -eq '/api/quotes') {
            $body = Get-PwxWebRequestJson -Request $request
            $service = Get-PwxWebString -Object $body -Property 'serviceId'
            if (-not $service) { throw 'Falta serviceId' }
            $quote = Get-PwxQuote -ServiceId $service -Addons (Get-PwxWebStringArray -Object $body -Property 'addons') -Complexity (Get-PwxWebString -Object $body -Property 'complexity') -Units (Get-PwxWebInt -Object $body -Property 'units' -Default 1) -DiscountPct (Get-PwxWebDouble -Object $body -Property 'discountPct' -Default 0)
            Send-PwxWebJson -Context $Context -Object ([ordered]@{ ok = $true; quote = $quote })
            return
        }
        if ($method -eq 'POST' -and $Path -match '^/api/jobs/([^/]+)/requirements$') {
            $jobId = [System.Uri]::UnescapeDataString($matches[1])
            $body = Get-PwxWebRequestJson -Request $request
            $requestText = Get-PwxWebString -Object $body -Property 'request'
            if (-not $requestText) { throw 'La solicitud de requisitos es obligatoria' }
            $result = Invoke-PwxRequirementsAgent -JobId $jobId -Request $requestText
            $status = if ($result.ok) { 200 } else { 422 }
            Send-PwxWebJson -Context $Context -Object $result -StatusCode $status
            return
        }
        if ($method -eq 'POST' -and $Path -match '^/api/jobs/([^/]+)/input$') {
            $jobId = [System.Uri]::UnescapeDataString($matches[1])
            $body = Get-PwxWebRequestJson -Request $request
            $entry = Add-PwxWebJobInput -JobId $jobId -Payload $body
            Send-PwxWebJson -Context $Context -Object ([ordered]@{ ok = $true; input = $entry }) -StatusCode 201
            return
        }
        if ($method -eq 'POST' -and $Path -eq '/api/payments/request') {
            $body = Get-PwxWebRequestJson -Request $request
            $jobId = Get-PwxWebString -Object $body -Property 'jobId'
            $payment = New-PwxPaymentRequest -JobId $jobId -Method (Get-PwxWebString -Object $body -Property 'method') -Addons (Get-PwxWebStringArray -Object $body -Property 'addons') -Complexity (Get-PwxWebString -Object $body -Property 'complexity') -Units (Get-PwxWebInt -Object $body -Property 'units' -Default 1) -DiscountPct (Get-PwxWebDouble -Object $body -Property 'discountPct' -Default 0)
            Send-PwxWebJson -Context $Context -Object ([ordered]@{ ok = $true; payment = $payment }) -StatusCode 201
            return
        }
        if ($method -eq 'POST' -and $Path -eq '/api/payments/proof') {
            $body = Get-PwxWebRequestJson -Request $request
            $jobId = Get-PwxWebString -Object $body -Property 'jobId'
            $payment = Add-PwxWebPaymentProof -JobId $jobId -Payload $body
            Send-PwxWebJson -Context $Context -Object ([ordered]@{ ok = $true; payment = $payment })
            return
        }
        if ($method -eq 'POST' -and $Path -eq '/api/payments/approve') {
            $body = Get-PwxWebRequestJson -Request $request
            $payment = Approve-PwxPayment -JobId (Get-PwxWebString -Object $body -Property 'jobId') -By (Get-PwxWebString -Object $body -Property 'by')
            Send-PwxWebJson -Context $Context -Object ([ordered]@{ ok = $true; payment = $payment })
            return
        }
        Send-PwxWebError -Context $Context -Code 'NOT_FOUND' -Message 'Ruta de API no encontrada' -StatusCode 404
    }
    catch {
        Write-PwxLog -Component 'web' -Message ("API $method $Path falló: " + $_.Exception.Message)
        Send-PwxWebError -Context $Context -Code 'REQUEST_FAILED' -Message $_.Exception.Message -StatusCode 422
    }
}

function Start-PwxWebServer {
    param(
        [int]$Port = 8787,
        [string]$BindAddress = '127.0.0.1'
    )
    if ($Port -lt 1024 -or $Port -gt 65535) { throw 'El puerto debe estar entre 1024 y 65535' }
    if ($BindAddress -notin @('127.0.0.1', 'localhost')) { throw 'Por seguridad, el servidor web solo permite 127.0.0.1 o localhost' }
    $publicRoot = Get-PwxWebPublicRoot
    if (-not (Test-Path -LiteralPath $publicRoot)) { throw "No existe la interfaz web: $publicRoot" }
    $prefix = "http://${BindAddress}:$Port/"
    $listener = New-Object System.Net.HttpListener
    $listener.Prefixes.Add($prefix)
    try {
        $listener.Start()
    }
    catch {
        throw "No se pudo iniciar $prefix. Compruebe que el puerto esté libre. Detalle: $($_.Exception.Message)"
    }
    Write-Host ''
    Write-Host 'PWX Panel local iniciado' -ForegroundColor Green
    Write-Host "Abra $prefix en el navegador" -ForegroundColor Cyan
    Write-Host 'Presione Ctrl+C para detenerlo.' -ForegroundColor Yellow
    try {
        while ($listener.IsListening) {
            $context = $listener.GetContext()
            $path = [System.Uri]::UnescapeDataString($context.Request.Url.AbsolutePath)
            if ($path.StartsWith('/api/')) {
                Invoke-PwxWebApi -Context $context -Path $path
                continue
            }
            if ($context.Request.HttpMethod.ToUpperInvariant() -ne 'GET') {
                Send-PwxWebError -Context $context -Code 'METHOD_NOT_ALLOWED' -Message 'Método no permitido' -StatusCode 405
                continue
            }
            $relative = if ($path -eq '/') { 'index.html' } else { $path.TrimStart('/') }
            if ($relative -match '(^|[\\/])\.\.([\\/]|$)') {
                Send-PwxWebError -Context $context -Code 'INVALID_PATH' -Message 'Ruta no permitida' -StatusCode 400
                continue
            }
            $file = [System.IO.Path]::GetFullPath((Join-Path $publicRoot $relative))
            $safe = Assert-PwxSafeWorkspacePath -WorkspacePath $publicRoot -Path $file
            $extension = [System.IO.Path]::GetExtension($safe).ToLowerInvariant()
            $contentType = switch ($extension) {
                '.html' { 'text/html; charset=utf-8' }
                '.css'  { 'text/css; charset=utf-8' }
                '.js'   { 'application/javascript; charset=utf-8' }
                '.svg'  { 'image/svg+xml' }
                default { 'application/octet-stream' }
            }
            Send-PwxWebFile -Context $context -Path $safe -ContentType $contentType
        }
    }
    finally {
        if ($listener) { $listener.Stop(); $listener.Close() }
    }
}
