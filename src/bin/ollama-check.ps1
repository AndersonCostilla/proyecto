$ErrorActionPreference = 'Stop'
$bootstrap = Join-Path $PSScriptRoot '..\bootstrap.ps1'
. $bootstrap

$status = Get-PwxOllamaStatus
"URL: $((Get-PwxConfig).OllamaBaseUrl)"
"Estado: $($status.status)"
if ($status.status -eq 'OK') {
    "Modelos detectados:"
    foreach ($m in $status.models) { "  - $m" }
    foreach ($m in $status.models) { "  disponibilidad [$m]: $((Test-PwxModelAvailable -Model $m))" }
    $cfgModel = (Get-PwxConfig).Model
    "Modelo configurado ($cfgModel): $((Test-PwxModelAvailable -Model $cfgModel))"
}
else {
    "Ollama no disponible. Verifica que el servicio este corriendo."
    exit 2
}
exit 0