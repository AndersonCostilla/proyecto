# PWX — Motor operativo comercial local

Sistema multiagente local para gestionar servicios digitales profesionales: planillas Excel, documentos, PDF, datos y presupuestos de obra. Corre 100% en PowerShell con modelos LLM locales vía Ollama, sin APIs de IA pagas ni base de datos externa.

El sistema separa responsabilidades:

- **LLM local:** clasificación, extracción de requisitos y borradores de mensajes.
- **Código determinista:** precios, cotizaciones, estados, pagos manuales, archivos, QA, hashes y persistencia.
- **Persona responsable:** aprobación de mensajes, comprobantes y entrega final.

## Capacidades actuales

- Clientes, trabajos, archivos de entrada, eventos y estados persistidos en disco.
- Prospección local desde CSV, JSON, datos abiertos o entrada manual; sin envío automático.
- Cotización determinista en COP por servicio, volumen, complejidad, add-ons y descuento controlado.
- Solicitud de pago manual con Nequi/transferencia configurable, comprobante y aprobación humana.
- Bloqueo de producción comercial hasta que el pago esté aprobado.
- Agente local de requisitos mediante Ollama, con salida JSON validada.
- Producción, QA, versionado y entrega con `manifest.json` y SHA-256.
- Servicio Excel implementado para normalización de planillas; servicios restantes en preparación.

> El repositorio no contiene datos reales de clientes, comprobantes, números de pago ni claves. Los datos operativos se guardan en `store/`, que está ignorado por Git.

## Requisitos

- Windows con PowerShell 5.1 o superior; compatible con PowerShell 7.x.
- [Ollama](https://ollama.com) corriendo en `http://localhost:11434` para usar los agentes LLM.
- Modelo local configurado por defecto: `qwen3:8b`.

Para pruebas deterministas no se necesita Ollama.

## Panel web local

Además de la CLI, ya hay un panel para operadores internos. Ejecuta:

```powershell
powershell -ExecutionPolicy Bypass -File src\bin\web.ps1
```

Luego abre `http://127.0.0.1:8787` en el mismo computador. Permite crear pedidos, cotizar, analizar requisitos, adjuntar archivos, solicitar pagos y registrar comprobantes. Consulta [docs/WEB_PANEL.md](docs/WEB_PANEL.md) para los límites de seguridad: este panel es local y no debe exponerse a Internet todavía.

## Uso rápido

```powershell
# 1. Verificar Ollama y el modelo (opcional para pruebas deterministas)
powershell -ExecutionPolicy Bypass -File src\bin\ollama-check.ps1

# 2. Ejecutar la demostración completa
powershell -ExecutionPolicy Bypass -File src\bin\demo.ps1

# 3. Consultar servicios y configuración
powershell -ExecutionPolicy Bypass -File src\bin\pwx.ps1 services:list
powershell -ExecutionPolicy Bypass -File src\bin\pwx.ps1 config:show
```

## Flujo operativo

```text
Prospecto
→ Cliente
→ Trabajo
→ Requisitos revisados
→ Cotización
→ Solicitud de pago
→ Comprobante
→ Aprobación humana
→ Producción
→ QA
→ Entrega
→ Aprobación final
```

El estado del trabajo se mantiene separado del estado del pago:

```text
NEW → REQUIREMENTS → READY_FOR_PRODUCTION → IN_PROGRESS → QA
→ READY_FOR_DELIVERY → DELIVERED → COMPLETED
```

Estados alternos: `BLOCKED`, `REWORK` y `CANCELLED`.

Los trabajos comerciales no pasan a producción si no tienen un pago aprobado. `simulate-service` está excluido para poder ejecutar demos y pruebas.

## Ejemplo de trabajo

```powershell
# Crear cliente
$c = powershell -File src\bin\pwx.ps1 client:new -Name 'Cliente Demo' -Contact 'demo@mail.com'
# Anota el ID devuelto, por ejemplo C-0001.

# Crear trabajo
powershell -File src\bin\pwx.ps1 job:new `
  -ClientId C-0001 `
  -Service excel-service `
  -Description "Normalizar una planilla de presupuesto"

# Extraer requisitos con el LLM local
powershell -File src\bin\pwx.ps1 job:requisitos `
  -JobId J-0001 `
  -Request "Normalizar el archivo, eliminar filas vacías y entregar un Excel ordenado."

# Adjuntar archivo de entrada
powershell -File src\bin\pwx.ps1 job:input `
  -JobId J-0001 `
  -Path "C:\ruta\planilla.xlsx"
```

## Cotización y pago manual

Primero configura de forma local el método de pago:

```powershell
Copy-Item config\payment-methods.example.json config\payment-methods.local.json
```

Edita el archivo local con el número Nequi, cuenta bancaria u otra instrucción real. Ese archivo está en `.gitignore` y nunca debe subirse a GitHub.

```powershell
# Calcular cotización transparente
powershell -ExecutionPolicy Bypass -File src\bin\pwx.ps1 quote:calc `
  -ServiceId excel-service `
  -Units 3 `
  -Complexity advanced `
  -Addons rush

# Crear solicitud de pago para un trabajo con requisitos completos
powershell -ExecutionPolicy Bypass -File src\bin\pwx.ps1 payment:request `
  -JobId J-0001 `
  -Method nequi `
  -Complexity standard `
  -Units 1

# Registrar comprobante y aprobarlo tras revisión humana
powershell -ExecutionPolicy Bypass -File src\bin\pwx.ps1 payment:proof `
  -JobId J-0001 `
  -Path "C:\comprobantes\pago.png" `
  -Reference "NEQUI-123456"

powershell -ExecutionPolicy Bypass -File src\bin\pwx.ps1 payment:approve `
  -JobId J-0001 `
  -By "operador"

# Ahora sí se permite producir
powershell -ExecutionPolicy Bypass -File src\bin\pwx.ps1 job:produce -JobId J-0001
```

Consulta [docs/PAYMENTS.md](docs/PAYMENTS.md) y [docs/PRICING.md](docs/PRICING.md) para el flujo, límites y políticas.

## Pruebas automatizadas

```powershell
powershell -ExecutionPolicy Bypass -File tests\run-tests.ps1
powershell -ExecutionPolicy Bypass -File tests\run-tests.ps1 -OnlyUnit
powershell -ExecutionPolicy Bypass -File tests\run-tests.ps1 -OnlyE2E
```

El harness propio no usa Pester. Las pruebas ejecutan workspaces temporales aislados en `%TEMP%\pwx-tests`, no alteran `store/` y no requieren Ollama gracias a respuestas LLM inyectadas.

Con Ollama y `qwen3:8b` activos, puedes ejecutar la verificación real de agentes:

```powershell
powershell -ExecutionPolicy Bypass -File src\bin\real-agent-check.ps1
```

Genera un reporte JSON temporal y valida requisitos LLM, prospección LLM, producción, QA y cotización sin contactar personas ni usar pagos reales.

## Servicios

| Servicio | Estado |
| --- | --- |
| `excel-service` | Implementado: validación y normalización segura de planillas `.xlsx` |
| `simulate-service` | Implementado: salida determinista para demos y pruebas |
| `word-service` | Implementado: genera documentos `.docx` profesionales desde contenido `.txt` o `.md` |
| `pdf-service` | Catálogo y cotización listos; producción pendiente |
| `data-service` | Catálogo y cotización listos; producción pendiente |
| `construction-service` | Catálogo y cotización listos; producción pendiente |

## Comandos de la CLI

```text
client:new / client:list / client:show
job:new / job:show / job:list / job:requisitos / job:input / job:produce / job:qa
job:deliver / job:approvedeliver / job:state / job:note
services:list / price:calc / quote:calc
payment:methods / payment:request / payment:show / payment:proof / payment:approve / payment:reject
web:start
lead:new / lead:import / lead:import-socrata / lead:list / lead:dedupe / lead:score / lead:draft / lead:convert
outbox:new / outbox:show / outbox:list / outbox:approve / outbox:send / outbox:export
config:show / ollama:check
```

## Configuración y seguridad

- `config/settings.json`: modelo, URL de Ollama, timeouts, workspace y moneda.
- `config/services.json`: catálogo de servicios, precios y reglas de cotización.
- `config/payment-methods.example.json`: plantilla de métodos de pago; copia local privada requerida para cobrar.
- `store/`: datos locales de clientes, trabajos, pagos, comprobantes, salidas, QA, entregas y logs.
- Variables de entorno disponibles: `PWX_ROOT`, `PWX_WORKSPACE`, `PWX_MODEL`, `PWX_OLLAMA_URL`, `PWX_OLLAMA_CONNECT_TIMEOUT`, `PWX_OLLAMA_REQUEST_TIMEOUT`, `PWX_PAYMENT_METHODS_FILE`.

## Documentación

- [Arquitectura](docs/ARCHITECTURE.md)
- [Prospección](docs/PROSPECTING.md)
- [Reglas de cotización](docs/PRICING.md)
- [Pagos manuales](docs/PAYMENTS.md)
- [Panel web local](docs/WEB_PANEL.md)
- [Servicio Word](docs/WORD_SERVICE.md)
- [Formato de entrega](docs/DELIVERY_FORMAT.md)
- [Pruebas](docs/TESTING.md)

## Alcance responsable

PWX está pensado para servicios profesionales legítimos: organización de datos, automatización, documentación corporativa, análisis, diseño y asesoría. La plataforma no debe utilizarse para producir o disimular trabajo académico que otra persona vaya a presentar como propio.