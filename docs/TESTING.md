# PWX — Testing y verificación

Esta guía documenta cómo correr las distintas suites de prueba del motor PWX y qué hacer antes de
declarar un trabajo listo para entrega (READY FOR COMMIT / READY FOR DELIVERY).

## Requisitos

- Windows con PowerShell
- Repositorio clonado en la corriente raíz (los tests asumen que se ejecutan desde `tests/`)
- (Opcional) Ollama local en `http://localhost:11434` con el modelo de configuración
  (default `qwen3:8b`). Si no está disponible, los tests se ejecutan en modo plantilla (sin LLM).

## Estructura de tests

| Ruta                    | Contenido                                                        |
| ----------------------- | ---------------------------------------------------------------- |
| `tests/unit/*.test.ps1` | Tests unitarios por componente (core, excel, qa, delivery, fs…) |
| `tests/e2e/*.test.ps1`  | Tests de flujo completo (job completo + runners)                |
| `tests/soak/run-soak.ps1` | Prueba de estrés/robustez (muchas entregas consecutivas)      |
| `tests/runner.ps1`      | Harness de asserts y utilidades compartidas                     |

Cada test corre en un **workspace temporal** bajo `$env:TEMP` y se limpia al terminar. El workspace
del repositorio (`store/`, según `config/settings.json`) nunca se toca durante los tests.

## Suites

### Suite completa

```powershell
powershell -ExecutionPolicy Bypass -File tests\run-tests.ps1
```

Corre todos los tests unitarios (`tests/unit`) y E2E (`tests/e2e`). Al final imprime el conteo
`PASS/FAIL`. Salida esperada: todos `PASS`.

### Solo unitarios / solo E2E

```powershell
powershell -ExecutionPolicy Bypass -File tests\run-tests.ps1 -OnlyUnit
powershell -ExecutionPolicy Bypass -File tests\run-tests.ps1 -OnlyE2E
```

### Prueba real de agentes con Ollama

Cuando Ollama y el modelo configurado estén activos, ejecuta esta prueba explícita:

```powershell
powershell -ExecutionPolicy Bypass -File src\\bin\\real-agent-check.ps1
```

La prueba usa un workspace temporal aislado y verifica con el modelo local real:

- El agente de requisitos y su JSON estructurado.
- El flujo de producción y QA con `simulate-service`.
- El agente de prospección generado por el LLM, sin enviar mensajes externos.
- La cotización determinista con los precios vigentes.

Si prospección cae a una plantilla de respaldo, la prueba real falla deliberadamente: el sistema productivo conserva ese respaldo, pero esta verificación debe confirmar el uso real del modelo.

Al final deja un reporte JSON en `%TEMP%\\pwx-real-agent-...\\real-agent-report.json`. Si falla, el script termina con código `1` y reporta el componente que necesita revisión. Esta prueba no usa clientes ni pagos reales.

### Soak (estrés)

```powershell
powershell -ExecutionPolicy Bypass -File tests\soak\run-soak.ps1 -Iterations 20
```

Ejecuta el flujo Excel completo (`src/bin/run-excel-local.ps1`) N veces en un workspace temporal
solo (`pwx-soak-<fecha>`), alternando modo LLM y modo plantilla, y aprobando explícitamente ~30% de
las entregas. Por cada iteración valida:

- Código de salida `0` del runner.
- Estado final correcto (`DELIVERED` o `READY_FOR_DELIVERY` antes de aprobar).
- Existencia de `delivery/manifest.json` y `delivery/checksums.sha256`.
- Que todas las líneas de `checksums.sha256` coincidan con los archivos reales empaquetados.

Parámetros:

| Parámetro      | Default                  | Descripción                                  |
| -------------- | ------------------------ | -------------------------------------------- |
| `-Iterations`  | `20`                     | Cantidad de entregas a ejecutar.             |
| `-InputPath`   | `tests/fixtures/basic.xlsx` | Archivo de entrada del flujo Excel.      |
| `-Model`       | (modelo de config)       | Modelo LLM a intentar en modo LLM.           |
| `-Cleanup`     | off                      | Borra el workspace temporal al terminar (`-Cleanup`). |

El workspace temporal se deja intacto por defecto para auditoría, y la ruta se imprime al final.

## Buenas prácticas

- **Nunca** correr tests o soak contra el workspace del repositorio: usar siempre
  `$env:PWX_WORKSPACE` apuntando a una carpeta temporal (`Join-Path $env:TEMP ("pwx-" + <stamp>)`).
- Los nuevos tests deben ser deterministas: usar el modo plantilla (`-Model <modelo inexistente>`)
  o `-ForceJson` en requisitos, salvo que el test verifique expresamente el modo LLM.
- Antes de una entrega ejecutar la regresión completa: suite, `-OnlyE2E` y
  `run-soak.ps1 -Iterations 10`. Si algo falla, el resultado es `REWORK`.