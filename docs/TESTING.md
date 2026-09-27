# PWX — Testing y verificación

Esta guía documenta cómo correr las distintas suites de prueba del motor PWX y qué hacer antes de
declarar un trabajo listo para entrega (READY FOR COMMIT / READY FOR DELIVERY).

## Requisitos

- PowerShell 5.1+ (Windows) o PowerShell 7.x (Linux/macOS)
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

Cada test corre en un **workspace temporal** bajo el directorio temporal del sistema (`GetTempPath()`) y se limpia al terminar. El workspace
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

## CI (GitHub Actions)

El workflow [`.github/workflows/ci.yml`](../.github/workflows/ci.yml) corre en
cada `push` y `pull_request` hacia `main`.
Es 100% gratuita: sin secretos, sin servicios externos y sin dependencias nuevas.

**Qué corre en CI (3 piernas matriz):**

| Pierna | Runner | Shell | Qué ejecuta |
| --- | --- | --- | --- |
| `linux-pwsh` | `ubuntu-latest` | `pwsh` (PS 7) | suite completa + soak corto (`-Iterations 5`) |
| `windows-pwsh` | `windows-latest` | `pwsh` (PS 7) | suite completa |
| `windows-ps51` | `windows-latest` | `powershell` (Windows PowerShell **5.1 real**) | suite completa |

- **Suite completa** = `./tests/run-tests.ps1` (unit + E2E, exactamente el mismo
  comando que en local).
- La salida se guarda con `Tee-Object` en `tests/_last-run.log` (y
  `tests/_soak-run.log` en la pierna de soak) **sin modificar el runner**; ambos
  archivos están cubiertos por el `.gitignore` (`*.log`).
- Los logs solo se suben como *artifact* (`test-logs-<pierna>`, retención 7 días)
  **cuando la pierna falla**.

**Qué NO corre por defecto:**

- Los tests *live* con Ollama (`tests/e2e/ollama-live.test.ps1`): la suite los
  detecta y muestra `SKIP` cuando no hay modelo disponible. En CI no se instala
  ni configura Ollama a propósito — por eso son opt-in y no bloquean el merge.
- No se usa ningún secreto de GitHub ni red especial: nada de SMTP real,
  APIs de pago ni servicios de terceros.

**Cómo reproducir localmente (idéntico a CI):**

```powershell
# Suite completa — misma entrada canónica que en CI (PowerShell 7; en 5.1 usa powershell)
pwsh -File ./tests/run-tests.ps1

# Con log espejo del de CI (proceso hijo + Tee, igual que el workflow)
pwsh -File ./tests/run-tests.ps1 2>&1 3>&1 4>&1 6>&1 | Tee-Object -FilePath tests/_last-run.log

# Soak corto (solo linux+pwsh en CI)
pwsh -File ./tests/soak/run-soak.ps1 -Iterations 5
```

> Nota: la suite debe lanzarse como script de entrada (`-File` o dot-source).
> Invocarla con `& ./tests/run-tests.ps1` desde una sesión en cambio de scope
> produce falsos fallos (T-E9 y prospección) por cómo resuelven los `$global:`
> de los tests — por eso el workflow la lanza como proceso hijo con `-File`.

## Buenas prácticas

- **Nunca** correr tests o soak contra el workspace del repositorio: usar siempre
  `$env:PWX_WORKSPACE` apuntando a una carpeta temporal (`Join-Path $env:TEMP ("pwx-" + <stamp>)`).
- Los nuevos tests deben ser deterministas: usar el modo plantilla (`-Model <modelo inexistente>`)
  o `-ForceJson` en requisitos, salvo que el test verifique expresamente el modo LLM.
- Antes de una entrega ejecutar la regresión completa: suite, `-OnlyE2E` y
  `run-soak.ps1 -Iterations 10`. Si algo falla, el resultado es `REWORK`.