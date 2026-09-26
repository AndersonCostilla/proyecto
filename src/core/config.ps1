function Get-PwxConfig {
    $root = if ($global:PwxRoot) { $global:PwxRoot } else { throw 'PwxRoot no definido: ejecuta bootstrap.ps1' }
    $settingsPath = Join-Path $root 'config\settings.json'
    if (-not (Test-Path -LiteralPath $settingsPath)) {
        throw "Falta config\settings.json"
    }
    $cfg = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json

    $workspace = $cfg.workspace
    if ($env:PWX_WORKSPACE) { $workspace = $env:PWX_WORKSPACE }
    if (-not [System.IO.Path]::IsPathRooted($workspace)) {
        $workspace = Join-Path $root $workspace
    }

    $model = $cfg.model
    if ($env:PWX_MODEL) { $model = $env:PWX_MODEL }

    $baseUrl = $cfg.ollama.baseUrl
    if ($env:PWX_OLLAMA_URL) { $baseUrl = $env:PWX_OLLAMA_URL }

    $connectTimeout = [int]$cfg.ollama.connectTimeoutSeconds
    if ($env:PWX_OLLAMA_CONNECT_TIMEOUT) { $connectTimeout = [int]$env:PWX_OLLAMA_CONNECT_TIMEOUT }
    $requestTimeout = [int]$cfg.ollama.requestTimeoutSeconds
    if ($env:PWX_OLLAMA_REQUEST_TIMEOUT) { $requestTimeout = [int]$env:PWX_OLLAMA_REQUEST_TIMEOUT }

    $catalogPath = $cfg.serviceCatalogFile
    if (-not [System.IO.Path]::IsPathRooted($catalogPath)) {
        $catalogPath = Join-Path $root $catalogPath
    }

    $requirePayment = $true
    if ($cfg.payments -and $null -ne $cfg.payments.requireApprovalBeforeProduction) {
        $requirePayment = [bool]$cfg.payments.requireApprovalBeforeProduction
    }
    if ($env:PWX_REQUIRE_PAYMENT_BEFORE_PRODUCTION) {
        $rawPaymentPolicy = $env:PWX_REQUIRE_PAYMENT_BEFORE_PRODUCTION.Trim().ToLowerInvariant()
        if ($rawPaymentPolicy -in @('0', 'false', 'no', 'off')) { $requirePayment = $false }
        elseif ($rawPaymentPolicy -in @('1', 'true', 'yes', 'on')) { $requirePayment = $true }
        else { throw "PWX_REQUIRE_PAYMENT_BEFORE_PRODUCTION inválido: $env:PWX_REQUIRE_PAYMENT_BEFORE_PRODUCTION" }
    }

    return [pscustomobject]@{
        Root               = $root
        WorkspacePath      = [System.IO.Path]::GetFullPath($workspace)
        Model              = $model
        OllamaBaseUrl      = $baseUrl
        ConnectTimeoutSec  = $connectTimeout
        RequestTimeoutSec  = $requestTimeout
        Currency           = $cfg.currency
        LogLevel           = $cfg.logLevel
        ServiceCatalogPath = $catalogPath
        RequirePaymentBeforeProduction = $requirePayment
    }
}

function Get-PwxTimestamp {
    return (Get-Date).ToString('o')
}