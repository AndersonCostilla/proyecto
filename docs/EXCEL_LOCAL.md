# Excel Local Run (Fase 3)

Ejecución automática del flujo completo de `excel-service` en local con **un solo comando**:

```
client:new -> job:new(excel-service) -> job:requisitos -> job:input(xlsx) -> job:produce -> job:qa -> job:deliver -> job:approvedeliver
```

## Comando

Desde la raíz del repositorio (Windows PowerShell):

```powershell
powershell -ExecutionPolicy Bypass -File src\bin\run-excel-local.ps1
```

Al terminar imprime:

```
clientId: C-0001
jobId: J-0001
output entregado: C:\Users\...\store\clients\C-0001\jobs\J-0001\delivery\resultado-normalizado.xlsx
estado final: DELIVERED
```

## Parámetros

| Parámetro | Default | Descripción |
|---|---|---|
| `-InputPath` | `tests/fixtures/basic.xlsx` | Ruta del archivo `.xlsx` a normalizar (relativa a la raíz del repo o absoluta). |
| `-Model` | `qwen3:8b` | Modelo Ollama a usar (se propaga vía `PWX_MODEL`). |
| `-ClientName` | `LocalDemo` | Nombre del cliente creado para el run. |
| `-Title` | `Excel Local Run` | Descripción del trabajo y objetivo. |
| `-NoApproveDelivery` | `switch`, default `false` | Si se pasa `-NoApproveDelivery`, se detiene en `READY_FOR_DELIVERY` sin aprobar. Por defecto (sin el switch) aprueba y termina en `DELIVERED`. |

Ejemplos:

```powershell
# Otra planilla
powershell -ExecutionPolicy Bypass -File src\bin\run-excel-local.ps1 -InputPath C:\ruta\planilla.xlsx

# Sin aprobación automática
powershell -ExecutionPolicy Bypass -File src\bin\run-excel-local.ps1 -NoApproveDelivery
```

El script **no modifica** `src/services/excel.ps1`, ni las dependencias del repo, ni toca outbox / pagos / prospección.

## Prerequisitos

- [Ollama](https://ollama.com) **opcional**. Si está corriendo en `http://localhost:11434` y el modelo configurado (`qwen3:8b` por defecto) está disponible, los requisitos se extraen con el LLM.
- Si Ollama no está disponible (o el modelo no está descargado), el script cae automáticamente al **modo plantilla (ForceJson)** que ya soporta el repo (`Invoke-PwxRequirementsAgent -ForceJson`, el mismo mecanismo de `src/bin/demo.ps1` y de los tests). No se requiere red ni modelo: requisitos válidos sin LLM.
- No hay otras dependencias. Solo PowerShell 5.1+ (Windows).

## Cómo funciona

- Reutiliza el CLI existente `src\bin\pwx.ps1` subproceso por subproceso para cada paso del flujo.
- Detecta Ollama con `Get-PwxOllamaStatus` / `Test-PwxModelAvailable`; si no hay disponibilidad, genera requisitos con plantilla determinista para `excel-service`.
- Garantiza que el servicio en requisitos sea `excel-service` (si el LLM clasifica distinto, lo fuerza).
- Adjunta el `.xlsx` como `planilla.xlsx`, produce `resultado-normalizado.xlsx`, corre QA (validador `Test-PwxExcelOutput`), empaqueta en `delivery/` y aprueba hasta `DELIVERED`.

## Estado esperado

- Flujo con aprobación automática (por defecto): estado final **DELIVERED** (exit 0).
- Con `-NoApproveDelivery`: estado final **READY_FOR_DELIVERY** (exit 0).
- Cualquier fallo intermedio imprime el error y termina con exit code != 0.