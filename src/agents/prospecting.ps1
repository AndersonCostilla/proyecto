function Get-PwxProspectingTemplates {
    $root = (Get-PwxConfig).Root
    $path = Join-Path $root 'config\prospecting.templates.json'
    if (-not (Test-Path -LiteralPath $path)) {
        return [ordered]@{
            email = [ordered]@{
                subject = 'Contacto'
                body = 'Hola {{name}}, gracias por tu tiempo.'
            }
            whatsapp = [ordered]@{
                body = 'Hola {{name}}, gracias por tu tiempo.'
            }
        }
    }
    return Get-PwxJsonFile -Path $path
}

function Replace-PwxTemplateVars {
    param([string]$Text, [object]$Lead)
    if (-not $Text) { return $Text }
    $result = $Text
    $result = $result.Replace('{{name}}', $Lead.name)
    $result = $result.Replace('{{company}}', $Lead.company)
    $result = $result.Replace('{{email}}', $Lead.email)
    $result = $result.Replace('{{phone}}', $Lead.phone)
    $result = $result.Replace('{{city}}', $Lead.city)
    $result = $result.Replace('{{department}}', $Lead.department)
    $result = $result.Replace('{{website}}', $Lead.website)
    $result = $result.Replace('{{domain}}', $Lead.domain)
    return $result
}

function Invoke-PwxProspectingDraft {
    param(
        [Parameter(Mandatory)][string]$LeadId,
        [string]$Channel = 'email'
    )
    $lead = Get-PwxLead -LeadId $LeadId
    if (-not $lead) { throw "Lead inexistente: $LeadId" }
    
    $templates = Get-PwxProspectingTemplates
    $channelLower = $Channel.ToLowerInvariant()
    
    # Try to use LLM if available
    try {
        $ollamaStatus = Get-PwxOllamaStatus
        if ($ollamaStatus.status -eq 'available') {
            $model = (Get-PwxConfig).Model
            if (Test-PwxModelAvailable -Model $model) {
                $prompt = @"
Genera un borrador de contacto profesional y respetuoso para el siguiente lead:

Lead:
- Nombre: $($lead.name)
- Empresa: $($lead.company)
- Email: $($lead.email)
- Teléfono: $($lead.phone)
- Ciudad: $($lead.city)
- Departamento: $($lead.department)
- Website: $($lead.website)
- Dominio: $($lead.domain)

Canal: $channelLower

Requisitos:
- 100% local, sin enviar mensajes
- No agresivo
- Personalizado (usar nombre/empresa si existen)
- Respetuoso y profesional
- Máximo 2-3 líneas para WhatsApp, breve para email
- Devuelve solo el contenido (sin explicaciones)

Para EMAIL: devuelve en formato:
ASUNTO: <asunto>
CUERPO: <cuerpo>

Para WHATSAPP: devuelve solo el mensaje.

Respuesta:
"@
                $resp = Invoke-PwxOllamaGenerate -Model $model -Prompt $prompt -TimeoutSec 120
                if ($resp -and $resp.response) {
                    $text = $resp.response.Trim()
                    if ($channelLower -eq 'email') {
                        if ($text -match 'ASUNTO:\s*(.+?)(\n|CUERPO:)') {
                            $subject = $matches[1].Trim()
                        }
                        if ($text -match 'CUERPO:\s*(.+)') {
                            $body = $matches[1].Trim()
                            # Remove any trailing markers
                            $body = $body -replace '\n.*$', ''
                        } else {
                            # Fallback split by lines
                            $lines = $text -split '\n'
                            if ($lines.Count -gt 1) {
                                $subject = $lines[0] -replace '^ASUNTO:\s*', ''
                                $body = ($lines[1..($lines.Count-1)] -join "`n").Trim()
                            }
                        }
                        if ($subject -and $body) {
                            return [ordered]@{ subject = $subject; body = $body; source = 'llm' }
                        }
                    } else {
                        return [ordered]@{ subject = ''; body = $text; source = 'llm' }
                    }
                }
            }
        }
    } catch {
        # Fall back to templates if LLM fails
    }
    
    # Deterministic fallback using templates
    if ($channelLower -eq 'email') {
        $tpl = $templates.email
        $subject = Replace-PwxTemplateVars -Text $tpl.subject -Lead $lead
        $body = Replace-PwxTemplateVars -Text $tpl.body -Lead $lead
        return [ordered]@{ subject = $subject; body = $body; source = 'template' }
    } else {
        $tpl = $templates.whatsapp
        $body = Replace-PwxTemplateVars -Text $tpl.body -Lead $lead
        return [ordered]@{ subject = ''; body = $body; source = 'template' }
    }
}
