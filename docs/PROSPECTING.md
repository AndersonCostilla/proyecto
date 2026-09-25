# PROSPECTING - Prospección GRATIS (FASE 6)

Sistema de prospección 100% local y gratis. Cumple estrictamente con reglas de seguridad: NO envía mensajes automáticamente, solo crea ítems en OUTBOX con estado DRAFT.

## Reglas de Seguridad

- **NO enviar mensajes externos automáticamente.** El sistema nunca ejecuta envío automático.
- **Solo crear OUTBOX items en estado DRAFT.** Todos los borradores van a OUTBOX con status=DRAFT.
- **Aprobación humana obligatoria.** Se requiere aprobación manual antes de cualquier envío.

## Fuentes GRATIS (MVP)

### 1) Importación universal desde CSV/JSON
```powershell
.\src\bin\pwx.ps1 lead:import -Path <file.csv|file.json>
```

Columnas soportadas (flexibles, nombres en español/inglés):
- CSV: Name/nombre, Company/empresa, Email/correo, Phone/telefono, City/ciudad, Department/departamento, Website/web/url, Notes/notas
- JSON: { name, company, email, phone, city, department, website, tags, notes, extra }

### 2) Ingesta desde Open Data Socrata (datos.gov.co)
```powershell
.\src\bin\pwx.ps1 lead:import-socrata -Url <dataset endpoint> -Limit 200 -Map <mapping.json>
```

- Funciona con cualquier endpoint Socrata abierto (sin token)
- Usa `Invoke-RestMethod` (sin scraping)
- Mapeo flexible de campos comunes: nombre, empresa, correo, teléfono, ciudad, departamento, web

### 3) Entrada manual
```powershell
.\src\bin\pwx.ps1 lead:new -Name "Juan Pérez" -Company "ACME" -Email "juan@acme.com" -Phone "+57 300 123 4567" -City "Bogotá" -Department "Cundinamarca" -Website "acme.com"
```

## Arquitectura

### Core: `src/core/leads.ps1`
- `New-PwxLeadId()` - Genera IDs L-0001, L-0002...
- `New-PwxLead()` - Crea lead con normalización
- Normalización: email lowercase, teléfono solo dígitos, dominio desde website/email
- `Invoke-PwxLeadsDedupe()` - Dedupe por email/phone/domain. Marca duplicados con `duplicate_of` apuntando al lead canónico (menor ID)
- `Get-PwxLeadScore()` - Scoring determinista (sin LLM): +10 nombre, +15 empresa, +25 email válido, +20 teléfono (>=8 dígitos), +10 website/dominio, +10 ciudad/departamento. Duplicados = score 0
- Estados: NEW, QUALIFIED, DRAFTED, APPROVED_FOR_CONTACT, CONTACTED, CONVERTED, DISMISSED

### Agent: `src/agents/prospecting.ps1`
- Si Ollama/modelo disponible: genera "razón de encaje" + borrador (email/whatsapp)
- Si no hay LLM: usa plantillas deterministas en `config/prospecting.templates.json`

### Perfil de marca / firma: `config/prospecting.profile.json`
Se configura quién firma los borradores (nunca la empresa del prospecto):
- `brand_name`: "MindSprit"
- `sender_name`: "Anderson"
- `sender_role`: "Equipo MindSprit"
- `value_prop`: propuesta de valor de una línea
- `cta`: llamada a la acción (ej: "¿Te parece si lo revisamos 10 min esta semana?")

Regla de branding: los borradores se firman con `sender_name` + `brand_name`. La empresa del lead (`lead.company`) solo puede aparecer como contexto del mensaje (ej: "Vi a Constrular SAS..."), NUNCA como remitente.

### Recipient por canal (lead:draft)
- **Canal `email`**: recipient = `lead.email` (obligatorio). Si el lead no tiene email → error claro y NO se crea nada en outbox.
- **Canal `whatsapp`**: recipient = `lead.phone` (solo dígitos, sin `+57`). Si el lead no tiene teléfono → error claro y NO se crea nada en outbox.
- Ambos canales mantienen `lead_id` en el item de outbox y todo queda en estado **DRAFT** (nunca se envía automáticamente).

### Integración OUTBOX
- `lead:draft` crea `outbox:new` en estado DRAFT con subject/body y metadata (leadId, channel)
- **NO envía**. Requiere aprobación humana (`outbox:approve` + `outbox:send`)

### Integración Clientes/Trabajos
- `lead:convert -LeadId L-XXXX` crea `client:new` con nombre/empresa y registra vínculo (lead.client_id, status CONVERTED)

## Comandos CLI

```powershell
# Manual
.\src\bin\pwx.ps1 lead:new -Name ... -Company ... -Email ... -Phone ... -City ... -Department ... -Website ...

# Importación
.\src\bin\pwx.ps1 lead:import -Path archivo.csv
.\src\bin\pwx.ps1 lead:import -Path archivo.json
.\src\bin\pwx.ps1 lead:import-socrata -Url <endpoint> -Limit 200

# Gestión
.\src\bin\pwx.ps1 lead:list
.\src\bin\pwx.ps1 lead:dedupe
.\src\bin\pwx.ps1 lead:score

# Prospección (local, sin envío)
.\src\bin\pwx.ps1 lead:draft -LeadId L-0001 [-Channel email|whatsapp]
.\src\bin\pwx.ps1 lead:convert -LeadId L-0001
```

Nota: `-Channel whatsapp` usa `lead.phone` (solo dígitos) como recipient; `-Channel email` usa `lead.email`. Si el dato requerido falta, el comando falla con un error claro y NO crea ningún mensaje en outbox.

## Flujo recomendado

1. **Importar**: `lead:import` o `lead:import-socrata` o `lead:new`
2. **Deduplicar**: `lead:dedupe` - identifica y marca duplicados (canonical vs duplicate_of)
3. **Puntuar**: `lead:score` - asigna score determinista
4. **Generar borradores**: `lead:draft` - crea OUTBOX items DRAFT (con templates o LLM si disponible)
5. **Revisar OUTBOX**: `outbox:list -Status DRAFT` - revisar todos los borradores
6. **Aprobar manualmente**: `outbox:approve -Id M-XXXX -By "humano"` (opcional)
7. **Enviar SOLO cuando aprobado**: `outbox:send -Id M-XXXX` (requiere aprobación previa)

## Restricciones

- Sin dependencias nuevas
- No scraping masivo
- No toca excel-service
- 100% local, sin llamadas externas (excepto Socrata API público con Invoke-RestMethod)
- Sin envío automático - aprobación humana obligatoria
