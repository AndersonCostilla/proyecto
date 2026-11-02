# PWX v1.0 LOCAL — Notas de release

> Estado de referencia: PR-1…PR-6 fusionados en `main` · suite 158+ tests en
> verde · CI 3 piernas (linux-pwsh, windows-pwsh, windows-ps51) · soak 5/5.
> Este documento define qué es **PWX v1.0 LOCAL** y qué queda fuera.

---

## Alcance de v1.0 LOCAL

PWX v1.0 es el sistema operativo local del negocio de servicios digitales
(MindSprit / Anderson Costilla): una sola persona opera el ciclo comercial
completo desde su computador.

```text
prospección → cliente → cotización → pago manual → requisitos (LLM local)
→ producción → QA determinista → paquete de entrega → aprobación humana
→ outbox → transporte file (.eml local) → cierre
```

Incluye:

- Máquina de estados completa con transiciones validadas.
- 6 servicios deterministas: Excel, Word, PDF, Data/CSV, Construction, Simulate.
- Prospección de leads (importación, dedupe, scoring, borradores, conversión).
- Cotización y precios deterministas desde catálogo (el LLM nunca decide precios).
- Pagos manuales con comprobante y aprobación humana.
- QA determinista + delivery con `manifest.json` y `checksums.sha256`.
- Outbox `DRAFT → APPROVED → SENT` con aprobación humana obligatoria.
- Transportes: **`file`** (correo `.eml` 100% local, el recomendado de v1.0),
  `mock` (simulación) y `mark-only` (default, solo transición de estado).
- Backup/Restore verificables del store (bundles con SHA-256 y content_hash).
- Panel web local con autenticación (PBKDF2, sesiones, CSRF, roles admin/operator).
- CLI completo con validación de flags (typos → `UNKNOWN_FLAG`, nunca silencio).
- Integración Ollama opcional con fallback determinista.

## Requisitos

- Windows con PowerShell 5.1+ **o** Linux/macOS con PowerShell 7.5+.
  (La suite oficial se corrobora en: pwsh 7 Linux, pwsh 7 Windows y
  Windows PowerShell 5.1 real.)
- Sin base de datos externa: el store es JSON local.
- Sin APIs de pago, sin nube, sin secretos obligatorios.
- Opcional: Ollama local (`http://localhost:11434`) con el modelo configurado.

## Qué es opcional

| Componente | Sin él, PWX… |
|---|---|
| Ollama / LLM local | opera en modo plantilla (requisitos por plantilla, sin redacción LLM) |
| Panel web (`web:start`) | todo funciona por CLI |
| Auth del panel (`config/web.local.json`) | el panel no arranca sin config válida (deny-start) o usa `-Dev` explícito |
| `config/payment-methods.local.json` | no se pueden cobrar (los comandos de pago lo exigen) |
| Transporte `file` | con `mark-only`/`mock` el outbox sigue auditando estados |
| SMTP | **fuera de v1.0**; `file` ya resuelve el envío sin red |

## Qué queda post-v1 (no retrasa v1.0)

- SMTP real (PR-7 futuro) y cualquier canal WhatsApp/pasarela automática.
- Panel: outbox/leads/backups en la UI (hoy solo CLI), dashboard operativo.
- Excel multihoja/fórmulas, data JSON/XLSX, APU de construcción.
- PDFs con branding, documentos Word mejorados.
- Instalador, backups programados, licencia del repositorio, smoke test interactivo.

## Comandos principales

```text
lead:new / lead:import / lead:score / lead:draft / lead:convert
client:new / job:new / job:requisitos / job:produce / job:qa / job:deliver / job:approvedeliver
quote:calc / payment:request / payment:proof / payment:approve
outbox:new [-Attachments <rutas>] / outbox:approve / outbox:send [-Transport file|mock|mark-only|smtp] [-Force]
backup:create / backup:list / backup:verify / backup:restore
web:start / web:hash / config:show / ollama:check
```

Ayuda completa: `pwsh -File src/bin/pwx.ps1` (sin argumentos).

## Garantías de seguridad (invariantes de v1.0)

1. **Nada sale solo**: `DRAFT` jamás se envía; todo envío exige aprobación humana.
2. **`SENT` no se reenvía** sin `-Force`, y todo reenvío queda auditado (`send.forced`).
3. **Cero red**: ningún transporte abre conexiones (SMTP ni existe en v1.0).
4. **El LLM no decide** precios, estados, totales ni QA; todo es código determinista.
5. **Path traversal bloqueado** en toda escritura y en los adjuntos del outbox.
6. **Integridad verificable**: delivery y adjuntos con SHA-256; backups con
   content_hash y detección de corrupción; restore atómico y no destructivo.
7. **Panel local solamente** (loopback), con deny-start, sesiones, CSRF y roles.
8. **Mismo input → mismos bytes** en los 6 servicios (QA valida contra la fuente).
9. **CLI estricto**: flags desconocidos o typos fallan con `UNKNOWN_FLAG` (exit 1).
10. **Sin secretos en el repo**: todo credential vive en `*.local.json` (gitignored).

## Estado de tests y CI

- Suite determinista sin Pester: `tests/run-tests.ps1` (unit + e2e), 158+ tests.
- Soak de estabilidad: `tests/soak/run-soak.ps1 -Iterations 5`.
- CI GitHub Actions gratuito, 3 piernas: `linux-pwsh`, `windows-pwsh`,
  `windows-ps51` (Windows PowerShell 5.1 real). Verde en `main`.
- Ollama-live: opt-in manual (no se corre en CI).
- Contrato CLI: `tests/unit/cli-contract.test.ps1` + `tests/e2e/cli-contract.test.ps1`
  blindan la ayuda y el parser contra deriva (flags, addons, comandos).
