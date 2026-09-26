# Arquitectura del motor operativo PWX

## Principio rector

Separacion estricta de responsabilidades:

- **LLM (agentes)**: razonamiento, lenguaje, clasificacion y extraccion de requisitos.
- **Codigo determinista**: calculos, archivos, estados, validaciones, precios, hashes, persistencia.

El LLM jamás inventa precios, estados, IDs ni decide transiciones. Todo lo operativo es determinista; el LLM solo produce una especificacion estructurada (JSON) que el sistema valida y conforma contra el catalogo.

## Arbol de archivos

```
proyecto/
  config/
    settings.json          # modelo, Ollama, timeouts, workspace, moneda
    services.json          # catalogo: precios, addons, contratos, implementacion
  src/
    bootstrap.ps1          # carga los modulos en orden (idempotente via PwxRoot)
    core/                  # nucleo determinista, sin LLM
      config.ps1           # config con overrides por entorno
      fs.ps1               # rutas seguras (anti path traversal), JSON, sha256
      log.ps1              # log global jsonl + eventos por trabajo
      id.ps1               # IDs secuenciales C-XXXX / J-XXXX / M-XXXX
      state.ps1            # maquina de estados + transiciones validas
      store.ps1            # CRUD de clientes y trabajos en disco
      pricing.ps1          # precios y cotizaciones deterministas desde el catalogo
      payments.ps1         # solicitud de pago, comprobante y aprobación humana
      outbox.ps1           # cola de mensajes salientes (DRAFT->APPROVED->SENT)
      qa.ps1               # validacion determinista de salida (PASS/FAIL)
      delivery.ps1         # empaquetado + manifest.json + checksums.sha256
    agents/                # usa LLM local (Ollama)
      ollama.ps1           # invoca /api/tags y /api/chat, categoriza errores
      requirements.ps1     # extrae especificacion JSON, la valida y conforma
      production.ps1       # orquesta produccion + QA determinista
    services/              # servicios de entrega deterministas
      registry.ps1         # catalogo e "implementado"
      simulate.ps1         # motor determinista de prueba (genera resultado.txt)
      excel.ps1 word.ps1 pdf.ps1 data.ps1 construction.ps1   # stubs
    bin/
      pwx.ps1              # CLI (subcomandos de clientes, trabajos, servicios, pagos y outbox)
      web.ps1              # inicia el panel local de operador en 127.0.0.1
      demo.ps1             # demo completa del ciclo con Ollama real
      ollama-check.ps1     # diagnostico de Ollama y modelo
    web/
      server.ps1           # API local sin dependencias, restringida a loopback
      public/              # interfaz HTML, CSS y JavaScript del panel
  tests/
    runner.ps1             # harness propio (Assert-*, workspaces aislados)
    run-tests.ps1          # entrada: unit + E2E
    unit/core.test.ps1     # 11 tests del nucleo
    e2e/flow.test.ps1      # 3 escenarios end-to-end
  .gitignore
```

## Maquina de estados

```
NEW -> REQUIREMENTS -> READY_FOR_PRODUCTION -> IN_PROGRESS -> QA -> READY_FOR_DELIVERY -> DELIVERED -> COMPLETED
             |                  |                  |         |              |
            BLOCKED            BLOCKED           REWORK    REWORK         BLOCKED
                                      \-> BLOCKED /          \-> BLOCKED / CANCELLED en cualquier estado
```

Transiciones definidas en `src/core/state.ps1` (`$PwxStateTransitions`). `Set-PwxJobState` rechaza transiciones invalidas con excepcion.

## Flujo de un trabajo

1. `client:new` -> crea `store/clients/C-XXXX/client.json`.
2. `job:new` -> crea `store/clients/C-XXXX/jobs/J-XXXX/` con buckets `input working output qa delivery`.
3. `job:requisitos` -> agente LLM extrae la especificacion:
   - Respuesta JSON validada por `Test-PwxRequirementsSpec`.
   - Si es invalida, se intenta reparar; si persiste, el trabajo pasa a `BLOCKED`.
   - El servicio elegido se valida contra el catalogo (sino, cae a `simulate-service`).
   - Los `required_output` se conforman al **contrato** del servicio (determinista), no a lo que "imagine" el modelo.
4. `payment:request` -> crea una cotización determinista después de requisitos completos. Elige método local configurado, guarda el importe y deja el pago en `REQUESTED`.
5. `payment:proof` -> copia el comprobante permitido (`.png`, `.jpg`, `.jpeg` o `.pdf`) al workspace, calcula su SHA-256 y mueve el pago a `PROOF_SUBMITTED`.
6. `payment:approve` / `payment:reject` -> una persona revisa el comprobante. Los servicios comerciales no inician producción hasta que su pago tenga estado `APPROVED`.
7. `job:produce` -> agente de produccion:
   - rechaza con `PAYMENT_REQUIRED` cuando el cobro previo es obligatorio y no está aprobado.
   - `READY_FOR_PRODUCTION -> IN_PROGRESS` solo tras validar el pago.
   - Invoca la funcion determinista del servicio (`Invoke-PwxService_<id>`).
   - Si el servicio no esta implementado -> `BLOCKED` con `SERVICE_NOT_IMPLEMENTED`.
   - Ejecuta QA determinista (`Invoke-PwxQa`): carpeta de salida, no vacia, patrones requeridos, archivos no vacios.
   - QA PASS -> `QA -> READY_FOR_DELIVERY`; QA FAIL -> `REWORK`.
8. `job:deliver` -> copia `output/` a `delivery/` y escribe `delivery/manifest.json` (estandar) + `delivery/checksums.sha256` con sha256 por archivo (ver `docs/DELIVERY_FORMAT.md`). Rechaza sin QA PASS (o `-AllowFail` en pruebas).
9. `job:approvedeliver` -> `READY_FOR_DELIVERY -> DELIVERED` (aprobacion humana).
10. `outbox:new/approve/send` -> mensajes de notificacion con transiciones validadas; nunca se "envian" sin aprobacion.

## Errores de Ollama

El adaptador categoriza: `OLLAMA_OFFLINE`, `MODEL_NOT_FOUND`, `MODEL_TIMEOUT`, `MODEL_INVALID_RESPONSE`, `MODEL_ERROR`. Ante un fallo de modelo, los agentes dejan el trabajo en `BLOCKED` (no en un estado intermedio inconsistente).

## Seguridad de archivos

- `Assert-PwxSafeFileName`: prohibe separadores y `..`.
- `Assert-PwxSafeWorkspacePath`: toda escritura debe quedar dentro del workspace; rutas externas lanzan excepcion.
- `Get-PwxSha256` para integridad de entregas.

## Persistencia

- Workspace por defecto `store/` (override con `PWX_WORKSPACE`).
- Formato JSON UTF-8 sin BOM.
- Logs: `store/logs/app.log.jsonl` (global) y `store/logs/jobs/J-XXXX.jsonl` (eventos por trabajo).
- Secuencias de IDs en `store/_meta/sequences.json`.

## Tests

Sin Pester ni dependencias. `tests/runner.ps1` provee `Run-PwxTest`, `Assert-Pwx*`, workspaces temporales aislados por test, y inyeccion de respuestas LLM (`-ForceJson`) para no depender de Ollama en CI.

## Limitaciones conocidas

- `excel-service`, `word-service` y `simulate-service` están implementados. PDF, limpieza de datos y construcción aún devuelven `SERVICE_NOT_IMPLEMENTED` al intentar producir.
- El cobro es local y manual: no hay conexión automática con Nequi, bancos, QR dinámicos ni facturación electrónica. Un humano debe revisar cada comprobante.
- No hay envío real por email/WhatsApp; el outbox persiste estados (DRAFT/APPROVED/SENT) sin transport.
- No hay autorización por rol ni multiusuario; las aprobaciones aún son campos de texto auditables.
- El LLM local puede producir especificaciones imperfectas; siempre pasan por validación y conformación determinista.