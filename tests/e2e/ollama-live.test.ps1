Run-PwxTest -Name 'E2E (integracion): Ollama real si esta disponible (si no, se omite)' -File 'e2e' -Body {
    $status = Get-PwxOllamaStatus
    if ($status.status -ne 'OK') {
        Write-Host '  SKIP: Ollama no disponible - la suite normal no depende de Ollama.'
        return
    }
    $model = (Get-PwxConfig).Model
    $avail = Test-PwxModelAvailable -Model $model
    if ($avail -ne 'OK') {
        Write-Host "  SKIP: modelo '$model' no disponible - la suite normal no depende de Ollama."
        return
    }
    $res = Invoke-PwxOllamaChat -Prompt 'Responde unicamente: OK' -FormatJson $false -Temperature 0
    Assert-PwxTrue $res.ok "Chat real deberia funcionar con Ollama (error: $($res.error))"
}