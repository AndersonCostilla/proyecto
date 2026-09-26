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
