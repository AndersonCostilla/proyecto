function global:Get-PwxOllamaStatus {
    return [pscustomobject]@{ status = 'OK'; models = @('qwen3:8b') }
}

function global:Test-PwxModelAvailable {
    param($Model)
    return 'OK'
}

function global:Invoke-PwxOllamaChat {
    param($Prompt, $System, $Model, $FormatJson, $Temperature)
    return [pscustomobject]@{
        ok = $true
        content = "ASUNTO: Ordenar tu Excel`nCUERPO: Hola Ana, podemos ayudarte a organizar y validar tu archivo. ¿Agendamos 10 minutos?`nAnderson - MindSprit"
        error = $null
    }
}

Run-PwxTest -Name 'agente de prospección usa el adaptador Ollama y conserva salida LLM' -File 'unit' -Body {
    $ws = New-PwxTestWorkspace
    $env:PWX_WORKSPACE = $ws
    Invoke-PwxBootstrap
    $lead = New-PwxLead -Name 'Ana Prueba' -Company 'Datos SAS' -Email 'ana@example.com' -Phone '3001234567'
    $draft = Invoke-PwxProspectingDraft -LeadId $lead.id -Channel 'email'
    Assert-PwxEqual 'llm' $draft.source
    Assert-PwxEqual 'Ordenar tu Excel' $draft.subject
    Assert-PwxTrue ($draft.body -match 'Hola Ana') 'Debe conservar contenido generado por el modelo'
}

Remove-Item -Path 'function:global:Invoke-PwxOllamaChat' -ErrorAction SilentlyContinue
Remove-Item -Path 'function:global:Get-PwxOllamaStatus' -ErrorAction SilentlyContinue
Remove-Item -Path 'function:global:Test-PwxModelAvailable' -ErrorAction SilentlyContinue
