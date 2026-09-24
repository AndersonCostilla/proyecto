# PWX - Motor operativo comercial local

Sistema multiagente local para procesar trabajos comerciales digitales (planillas, documentos, PDF, datos, presupuestos de obra). Corre 100% en PowerShell con modelos LLM locales vía Ollama. Sin APIs de pago, sin base de datos externa, sin dependencias de terceros.

## Requisitos

- Windows con PowerShell 5.1 o superior (compatible con PowerShell 7.x)
- [Ollama](https://ollama.com) corriendo en `http://localhost:11434`
- Modelo LLM local (configurado por defecto: `qwen3:8b`)

## Uso rápido

```powershell
# 1. Verificar que Ollama y el modelo esten disponibles
powershell -ExecutionPolicy Bypass -File src\bin\ollama-check.ps1

# 2. Demo completa del ciclo (cliente -> trabajo -> requisitos LLM -> produccion -> QA -> entrega -> outbox)
powershell -ExecutionPolicy Bypass -File src\bin\demo.ps1

# 3. CLI operativa
powershell -ExecutionPolicy Bypass -File src\bin\pwx.ps1 config:show
powershell -ExecutionPolicy Bypass -File src\bin\pwx.ps1 services:list
```

## Ejemplo de flujo con la CLI

```powershell
# Crear cliente
$c = powershell -File src\bin\pwx.ps1 client:new -Name 'Cliente Demo' -Contact 'demo@mail.com'
# (anota el ID devuelto, ej: C-0001)

# Crear trabajo
powershell -File src\bin\pwx.ps1 job:new -ClientId C-0001 -Service simulate-service -Description "Informe demo"
# (anota el ID, ej: J-0001)

# Extraer requisitos con el LLM local
powershell -File src\bin\pwx.ps1 job:requisitos -JobId J-0001 -Request "Simula la generacion de un informe comercial"

# Producir (ejecuta el servicio y QA determinista)
powershell -File src\bin\pwx.ps1 job:produce -JobId J-0001

# Empaquetar y aprobar la entrega
powershell -File src\bin\pwx.ps1 job:deliver -JobId J-0001
powershell -File src\bin\pwx.ps1 job:approvedeliver -JobId J-0001 -By operador
```

Los datos se guardan en `store/` (gitignore): clientes, trabajos, requisitos, salidas, QA, manifestos de entrega, cola de mensajes salientes (outbox) y logs.

## Pruebas automatizadas

```powershell
powershell -ExecutionPolicy Bypass -File tests\run-tests.ps1        # unitarias + E2E
powershell -ExecutionPolicy Bypass -File tests\run-tests.ps1 -OnlyUnit
powershell -ExecutionPolicy Bypass -File tests\run-tests.ps1 -OnlyE2E
```

Harness propio sin dependencias (no usa Pester). Los tests usan workspaces temporales aislados en `%TEMP%\pwx-tests` y no tocan Ollama (inyeccion determinista de respuestas).

## Comandos de la CLI

```
client:new / client:list / client:show
job:new / job:show / job:list / job:requisitos / job:produce / job:qa
job:deliver / job:approvedeliver / job:state / job:note
services:list / price:calc
outbox:new / outbox:show / outbox:list / outbox:approve / outbox:send
config:show / ollama:check
```

## Configuracion

- `config/settings.json`: modelo, URL de Ollama, timeouts, workspace, moneda.
- `config/services.json`: catalogo de servicios (precios, addons, contratos de salida, si estan implementados).
- Variables de entorno override: `PWX_ROOT`, `PWX_WORKSPACE`, `PWX_MODEL`, `PWX_OLLAMA_URL`, `PWX_OLLAMA_CONNECT_TIMEOUT`, `PWX_OLLAMA_REQUEST_TIMEOUT`.

## Arquitectura

Ver [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Estado de los servicios

| Servicio | Estado |
| --- | --- |
| simulate-service | Implementado (salida determinista de prueba) |
| excel-service / word-service / pdf-service / data-service / construction-service | Stubs (retornan `SERVICE_NOT_IMPLEMENTED`) |

Los precios siempre se calculan de forma determinista desde el catalogo; el LLM nunca inventa precios.