# PWX — Fase 7: "Operable a diario con riesgo bajo" (plan por PR)

> ✅ **PLAN HISTÓRICO — COMPLETADO (con desvío documentado)** — La Fase 7 se cerró
> como PR-1…PR-6 (CI, Backup/Restore, Auth del panel, transporte del outbox).
> Desvío respecto al plan: PR-6 implementó el transporte gratuito `file`
> (correo `.eml` 100% local) en lugar de SMTP; SMTP queda opcional post-v1.0.
> Las cifras de este documento (base `a2481b2`, suite 109/109, "4 huecos")
> corresponden al estado de 2026-09-27 y **no al actual**. Estado vigente:
> [docs/RELEASE_V1.md](../RELEASE_V1.md).

> Tech Lead / Maintainer · 2026-09-27 · base: `a2481b2` · suite 109/109 ✅
> Alcance: (1) CI GitHub Actions · (2) Backup/Restore del `store/` ·
> (3) Autenticación del panel web · (4) Transporte SMTP del outbox.
> Nada de lo existente se descarta; los 4 principios innegociables se mantienen.

---

## 0. Supuestos (en lugar de preguntas)

1. **CI**: el repo usa el plan gratuito (público o free tier); sin secretos en CI.
2. **Usuarios del panel**: v1 se siembra a mano en `config/web.local.json`
   (no hay registro/CRUD de usuarios en UI todavía).
3. **SMTP**: relay genérico RFC (Gmail con contraseña de aplicación, Mailgun,
   SMTP local). No se testea contra servidor real en CI (opt-in manual, como Ollama).

---

## 1. Roadmap por PR

| PR | Nombre | Alcance | Riesgo | Depende de | "Listo" cuando |
|----|--------|---------|--------|------------|----------------|
| **PR-1** | `ci: github actions (linux+windows+ps51)` | `.github/workflows/ci.yml`, badge README, TESTING.md | Muy bajo (sin cambios de src) | — | Checks verdes en push/PR; las 3 piernas corren la suite |
| **PR-2** | `feat(backup): create+verify` | `src/core/backup.ps1` (create/verify), CLI `backup:create/list/verify`, tests unit, `.gitignore backups/` | Bajo (no escribe sobre store) | — | Backup verificable; suite verde |
| **PR-3** | `feat(backup): restore roundtrip` | `Restore-PwxBackup`, CLI `backup:restore`, E2E roundtrip, `docs/BACKUP.md` | **Medio** (escritor destructivo) | PR-2 | Roundtrip E2E verde; guardas antidestrucción probadas |
| **PR-4** | `feat(auth): núcleo + hashing + config` | `src/core/auth.ps1`, `config/web.example.json`, CLI `web:hash`, unit tests | Bajo (servidor intacto) | — | Hash/verify/sesiones puros testeados |
| **PR-5** | `feat(web): login + middleware + deny-start` | `src/web/server.ps1`, `src/bin/web.ps1`, `app.js` (login UI), E2E web-auth, docs | **Medio** (rompe panel si falla) | PR-4 | Sin config → arranque negado; con config → login exige sesión; suite verde |
| **PR-6** | `feat(outbox): seam de transporte + file/mock` | `src/core/transport.ps1`, campos outbox, CLI `outbox:send` rework, unit tests | Medio (cambia CLI) | — | DRAFT jamás envía; SENT no se reenvía sin `-Force`; tests existentes verdes |
| **PR-7** | `feat(outbox): transporte SMTP` | `Send-PwxSmtpTransport`, `config/smtp.local.json`, docs OUTBOX | Medio (secretos) | PR-6 | Password solo por env/local; logs sin secretos (test) |
| **PR-8** | `docs: ADR + release` | `docs/DECISIONS.md`, `SECURITY.md`, README/AUDITORIA, bump `Get-PwxVersion` → `0.2.0` | Nulo | PR-1..7 | Checklist §6 completa |

Regla transversal: **cada PR mantiene la suite completa en verde** (hoy 109, crece
con los tests nuevos). Si PR-1 revela fallos en la pierna Windows 5.1, se arregla
en `PR-1b` antes de seguir (no se salta).

---

## 2. Diseño y contratos

### 2.1 CI con GitHub Actions (ADR-0001)

**Decisiones**
- **Una sola pieza `.github/workflows/ci.yml` con 3 jobs matriz**: `linux-pwsh`
  (ubuntu-latest), `windows-pwsh` (windows-latest), `windows-ps51`
  (windows-latest, `shell: powershell`). *Por qué:* valida exactamente los dos
  entornos comprometidos (pwsh 7.x multiplataforma y PS 5.1 real, no simulado).
- **Sin instalación de PowerShell**: pwsh ya viene en los runners de GitHub y
  `powershell` 5.1 también en Windows. *Por qué:* cero dependencias, CI idéntico
  a una máquina real.
- **Ollama opt-in por diseño**: no se configura endpoint; la suite ya hace
  `SKIP` automático de `ollama-live` cuando no hay modelo (comportamiento
  actual verificado). Se expone `workflow_dispatch` con input
  `run_ollama_live` (futuro) y jamás corre en push/PR. *Por qué:* restricción
  obligatoria + reproducibilidad.
- **Soak corto como paso aparte** (`-Iterations 5`, ~25 s) solo en linux-pwsh.
  *Por qué:* detecta corrupción acumulativa sin inflar el tiempo de PR.
- **Artefactos solo en fallo**: se sube `tests/_last-run.log` (nuevo redirect
  en el workflow, no en el runner) si el job falla. *Por qué:* debug sin
  exponer store ni secretos.
- **Pinning**: `actions/checkout` fijado a tag mayor `@v4` con comentario para
  pasar a SHA completa; `concurrency` con `cancel-in-progress` en PRs.
  *Por qué:* equilibrio seguridad/legibilidad en repo personal; sin secretos
  el riesgo de supply-chain es bajo.

**Workflow (estructura)**
```yaml
name: ci
on:
  push: { branches: [main] }
  pull_request: { branches: [main] }
  workflow_dispatch:
    inputs: { run_ollama_live: { type: boolean, default: false } }
concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}
jobs:
  test:
    strategy:
      fail-fast: false
      matrix:
        include:
          - { os: ubuntu-latest,  shell: pwsh }
          - { os: windows-latest, shell: pwsh }
          - { os: windows-latest, shell: powershell }   # PS 5.1 real
    runs-on: ${{ matrix.os }}
    defaults: { run: { shell: ${{ matrix.shell }} } }
    steps:
      - uses: actions/checkout@v4
      - name: Suite completa (unit + e2e)
        run: ./tests/run-tests.ps1        # sin -Only*: igual que local
      - name: Soak corto (solo linux+pwsh)
        if: matrix.os == 'ubuntu-latest' && matrix.shell == 'pwsh'
        run: ./tests/soak/run-soak.ps1 -Iterations 5
  # badge: ![ci](https://github.com/AndersonCostilla/proyecto/actions/workflows/ci.yml/badge.svg)
```

**Aceptación**
- [ ] Push y PR muestran 3 checks; los 3 en verde.
- [ ] `windows-ps51` corre con `powershell` (se ve en el log `$PSVersionTable.PSVersion` = 5.1).
- [ ] Ningún job requiere secretos ni red especial.
- [ ] Badge en README apunta al workflow.
- [ ] Un test roto en cualquier pierna bloquea el merge (rama protegida, si se activa).

**Riesgos / mitigación**
- *Diferencias de locale/TZ en runners* → la suite ya es determinista (fechas
  ISO string, invariant culture); si algo falla se arregla en PR-1b, no se
  desactiva la pierna.
- *Windows 2× minutos del plan* → irrelevante en plan gratuito de repo público;
  si el repo es privado, se elimina la pierna `windows-pwsh` dejando 5.1 (decisión documentada en ADR).
- *Downtime de GitHub Actions* → badge queda rojo sin que el repo esté roto;
  `workflow_dispatch` permite re-ejecución manual.

---

### 2.2 Backup/Restore del `store/` (ADR-0002)

**Decisiones**
- **CLI primero** (`backup:create|list|verify|restore`) + módulo
  `src/core/backup.ps1` cargado por bootstrap. *Por qué:* mismo patrón que el
  resto del sistema; usable por humanos, scripts y (mañana) por el panel.
- **Bundle = copia plana + `manifest.json` + `checksums.sha256`**, mismo estilo
  que `delivery/` (reutiliza `Get-PwxSha256`, `Set-PwxJsonFile` con
  `-DateKind String`, orden ordinal de rutas). *Por qué:* un formato ya
  auditado y testeado en el repo.
- **`content_hash` reproducible**: sha256 de la lista canónica
  `"sha256  ruta/relativa\n"` ordenada ordinalmente (sin fechas). Dos backups
  de un store idéntico ⇒ mismo `content_hash`, aunque difiera `created_utc`.
  *Por qué:* satisface "reproducible en lo posible" sin sacrificar auditoría.
- **Copia estable con reintento**: por archivo, si mtime/tamaño cambian entre
  lectura y copia → reintento (máx 3); si persiste → `complete: false` en el
  manifiesto. *Por qué:* el store puede mutar durante un respaldo; el manifiesto
  lo declara en vez de mentir.
- **Restore atómico y no destructivo**: (1) `verify` obligatorio previo,
  (2) materializar en `store.restore-tmp-<ts>`, (3) mover store actual a
  `store.pre-restore-<ts>` (¡nunca borrar!), (4) renombrar tmp → store.
  Store destino no vacío exige `-Force`. *Por qué:* el riesgo #1 de esta
 功能 es perder datos en un restore fallido.
- **Ubicación por fuera del store**: `<raíz>/backups/` (gitignored),
  configurable `backup.dir` en `settings.json` + env `PWX_BACKUP_DIR`.
  *Por qué:* un backup dentro de `store/` se respaldaría a sí mismo; dentro del
  repo pero gitignoreado evita subir PII a GitHub.

**Contrato — `manifest.json` del bundle (schema v1)**
```json
{
  "schema_version": "1",
  "kind": "pwx-store-backup",
  "created_utc": "2026-09-27T12:00:00.0000000Z",
  "pwx_version": "0.1.0",
  "source": "store",
  "content_hash": "sha256:...",
  "file_count": 142,
  "total_bytes": 918273,
  "complete": true,
  "files": [
    { "path": "clients/C-0001/client.json", "sha256": "...", "bytes": 512 }
  ]
}
```
- `checksums.sha256`: líneas `<sha64>  <path>` (dos espacios), sin autoincluirse.
- **Versionado**: `schema_version` string `"1"` (misma convención que el
  manifest de delivery). `Test-PwxBackupBundle` rechaza cualquier versión
  distinta de `"1"` con `BACKUP_SCHEMA_UNSUPPORTED` (futuros v2 = código nuevo,
  no compatibilidad a ciegas).
- **Orden de `files[]`**: rutas con `Sort-Object -CaseSensitive` (igual que
  delivery) → manifest determinista dada la misma entrada.

**Funciones (estructura)**
```powershell
# src/core/backup.ps1
function Get-PwxBackupRootDir            # settings.backup.dir | PWX_BACKUP_DIR | <root>/backups
function Copy-PwxBackupFileStable        # copia con verificación mtime/tamaño + reintentos
function New-PwxBackup [-Label]          # crea backups/<UTCts>[-label]/ + manifest + checksums
function Test-PwxBackupBundle -Path      # { ok, problems[], manifest } verificación total
function Get-PwxBackupList               # inventario de bundles
function Restore-PwxBackup -Path [-TargetStore] [-Force]  # verify→tmp→swap (pre-restore)
function Get-PwxBackupContentHash        # hash canónico reproducible
```
CLI en `src/bin/pwx.ps1`: `backup:create [-Label x]`, `backup:list`,
`backup:verify -Path <dir>`, `backup:restore -Path <dir> [-Force]`
(restore imprime la ruta del `store.pre-restore-` generado).

**Aceptación**
- [ ] `backup:create` sobre store con clientes/trabajos → bundle con
  `file_count` = archivos reales y `verify` en OK.
- [ ] Mutar 1 byte del bundle → `verify` falla nombrando el archivo.
- [ ] Roundtrip: backup → destrozar store → `restore` → hashes de todo el
  store idénticos al snapshot previo y la app opera (GET clientes OK).
- [ ] `restore` sin `-Force` sobre store no vacío → error, store intacto.
- [ ] `restore` con bundle corrupto → error ANTES de tocar el store.
- [ ] Store preexistente nunca desaparece: queda `store.pre-restore-*`.
- [ ] Dos backups consecutivos de store sin cambios → mismo `content_hash`.

**Tests (plan)**
- `tests/unit/backup.test.ps1`: create+verify happy path; tampered byte;
  archivo faltante en bundle; manifiesto JSON inválido; `schema_version: "9"`;
  `content_hash` estable entre dos corridas; `Copy-PwxBackupFileStable`
  reintenta (simulado con mtimes); store vacío (solo `_meta`); rutas con
  espacios/acentos; archivo 0 bytes.
- `tests/e2e/backup-restore.test.ps1`: roundtrip completo con app operando
  post-restore; guardas (`-Force`, verify previo); conservación `pre-restore`.

**Docs**: `docs/BACKUP.md` (nuevo), README (comandos), `ARCHITECTURE.md`
(árbol + módulo), `TESTING.md` (tests nuevos).

**Riesgos / mitigación**
- *Restore destructivo* → tmp+swap+pre-restore+verify previo (arriba).
- *PII en backups (pagos, outbox)* → `backups/` gitignored, SECURITY.md
  recomienda cifrado de disco/ruta fuera del repo; **nunca** subir bundles a CI.
- *Store mutando durante backup* → reintentos + `complete:false` + doc
  "respaldar con el panel cerrado".
- *Interrupción a mitad de restore* → swap por `Rename-Item` en mismo volumen;
  si cae, queda tmp+pre-restore y doc explica cómo recuperar.

---

### 2.3 Autenticación del panel web (ADR-0003)

**Decisiones**
- **Deny-by-default en el arranque**: si `config/web.local.json` no existe o es
  inválido (0 usuarios, hash ilegible) → `Start-PwxWebServer` **lanza
  `AUTH_NOT_CONFIGURED` y no escucha**. Única exención: flag `-Dev`
  (`web:start -Dev` / `web.ps1 -Dev`) que arranca SIN auth **solo** con
  banner WARNING en consola + evento `web.dev_mode` en log + respuesta
  `X-Pwx-Auth: dev-mode`. *Por qué:* restricción explícita del brief; el modo
  peligroso tiene que ser ruidoso e intencional.
- **Sesiones en memoria** (hashtable token → `{user,role,expires}`), cookie
  `pwx_session` con `HttpOnly; SameSite=Strict; Path=/`, TTL 480 min con
  renovación al usar. *Por qué:* nada de estado persistente que filtrar;
  reinicio del panel = sesión nueva; TTL corto acota robo de cookie local.
- **Password hashing sin dependencias**: PBKDF2 con formato
  `pbkdf2-sha256$<iter>$<salt-b64>$<hash-b64>` vía
  `Rfc2898DeriveBytes(..., HashAlgorithmName.SHA256)` (120.000 iter,
  salt 16B, key 32B). *Por qué:* disponible en PS 5.1 (≥4.7.2) y pwsh 7;
  nada que instalar; iteraciones parametrizables para future-proofing.
- **Middleware como función pura** `Get-PwxWebAuthDecision -Path -Method
  -Cookie -Config → {allowed, user, role, code}` testeable sin sockets;
  el server solo la invoca. Rutas públicas: `POST /api/login`, `GET /`,
  `/app.js`, `/styles.css`. *Por qué:* la lógica de seguridad se prueba
  exhaustivamente sin levantar HttpListener.
- **Roles `operator` | `admin`** con enforcement real desde el día 1 en las
  rutas admin: `GET /api/admin/sessions`, `POST /api/admin/sessions/revoke`.
  Todo lo demás (pagos, entregas, word) = `operator`. *Por qué:* "mínimo
  operator/admin" sin inventar más superficie de la que existe.
- **CSRF + brute-force baratos**: mutaciones exigen header `X-Pwx-Panel: 1`
  (lo manda el `app.js`); login con contador 10 fallos/15 min → lockout
  in-memory + 500 ms de delay; mensaje de error idéntico para usuario
  inexistente y password malo. *Por qué:* localhost no es riesgo cero
  (DNS-rebinding,OtherTabs) y el costo es ~20 líneas.

**Contrato — `config/web.local.json` (schema v1)**
```json
{
  "schema_version": "1",
  "auth": {
    "enabled": true,
    "sessionTtlMinutes": 480,
    "users": [
      {
        "id": "anderson",
        "name": "Anderson",
        "role": "admin",
        "passwordHash": "pbkdf2-sha256$120000$c2FsdA==$aGFzaA=="
      }
    ]
  }
}
```
- `config/web.example.json` (nuevo): idéntico con `"passwordHash":
  "REEMPLAZA"` y `enabled: false` de ejemplo — **cero secretos**.
- Generación del hash: CLI nuevo `web:hash -Password '...'` (imprime la línea
  completa; no deja password en argv de otros comandos — doc advierte del
  historial de shell).
- **Versionado**: `schema_version` `"1"`; loader rechaza otras con
  `WEB_CONFIG_UNSUPPORTED`. Roles validados contra enum `operator|admin`.

**Contrato — API de sesión**
| Ruta | Req | Éxito | Errores |
|---|---|---|---|
| `POST /api/login` `{user,password}` | pública | `200 {user,role,expiresAt}` + cookie | `401 AUTH_INVALID_CREDENTIALS`, `429 AUTH_LOCKED` |
| `POST /api/logout` | sesión | `200 {ok}` + borra cookie | `401 AUTH_REQUIRED` |
| `GET /api/session` | sesión | `200 {user,role,expiresAt,devMode}` | `401 SESSION_EXPIRED` |
| resto `/api/*` | sesión + header `X-Pwx-Panel: 1` en mutaciones | actual | `401 AUTH_REQUIRED / SESSION_EXPIRED`, `403 CSRF_HEADER_MISSING / FORBIDDEN_ROLE` |

**Aceptación**
- [ ] Sin `web.local.json` y sin `-Dev`: el proceso sale con código ≠0 y
  mensaje `AUTH_NOT_CONFIGURED` con instrucciones; el puerto NO queda abierto.
- [ ] Con `-Dev`: arranca, banner WARNING visible, evento en log, API responde
  `X-Pwx-Auth: dev-mode`.
- [ ] Con config válida: sin cookie → `401` en `/api/dashboard`; login correcto
  → acceso; logout → `401`.
- [ ] Password incorrecto y usuario inexistente → mismo `401` (sin enumeración).
- [ ] 11 intentos fallidos → `429 AUTH_LOCKED` (y se libera al TTL).
- [ ] Sesión expirada → `401 SESSION_EXPIRED`.
- [ ] POST sin header `X-Pwx-Panel` → `403 CSRF_HEADER_MISSING`.
- [ ] `role: operator` en ruta admin → `403 FORBIDDEN_ROLE`.
- [ ] Ningún test/log contiene el password en claro.

**Tests (plan)**
- `tests/unit/auth.test.ps1`: hash→verify roundtrip; hash incorrecto falla;
  formato inválido rechazado; config inválida (0 users, role malo, schema 9);
  sesiones: crear/obtener/expirar/TTL sweep/logout; lockout 10+1 y reset del
  contador; `Get-PwxWebAuthDecision` matriz completa (rutas públicas,
  mutación sin header, cookie expirada, roles).
- `tests/e2e/web-auth.test.ps1` (patrón de `tests/unit/web.test.ps1` con
  HttpListener real en puerto efímero): deny-start; flujo login→session→
  logout; lockout; dev-mode headers; ROLE admin vs operator.

**Docs**: `SECURITY.md` (nuevo), `WEB_PANEL.md` (sección Autenticación),
README, `DECISIONS.md` ADR-0003.

**Riesgos / mitigación**
- *Olvidar -Dev en producción LAN* → bind loopback ya forzado + banner + log;
  SECURITY.md prohíbe exponer sin TLS.
- *Password en argv de `web:hash`* → doc: usar `Read-Host -AsSecureString`
  interactivo (modo interactivo del CLI) o variable de entorno; el comando
  acepta `-Password` solo para tests.
- *Sesiones se pierden al reiniciar* → aceptado y documentado (re-login).
- *Hash SHA256 no disponible en .NET Framework viejo* → PR-5 incluye prueba de
  smoke en la pierna `windows-ps51` de CI (si falla, fallback a
  `pbkdf2-sha1$` documentado en ADR-0003b).

---

### 2.4 Transporte real del outbox — SMTP (ADR-0004)

**Decisiones**
- **El transporte va DEBAJO de la máquina de estados existente**: se conserva
  `Set-PwxOutboxStatus` intacto (DRAFT→APPROVED→SENT, SENT inmutable — ya
  probado en `core.test.ps1`). La nueva orquestación `Send-PwxOutboxMessage`
  exige `status -eq 'APPROVED'` antes de tocar red. *Por qué:* principio #2
  sin reescribir lo que funciona; DRAFT jamás llega al socket.
- **Sin nuevo estado `FAILED`**: si el envío falla, el ítem **sigue APPROVED**
  y acumula `attempts`, `last_error`, `last_attempt_at`. Reintento = volver a
  llamar `outbox:send`. *Por qué:* añadir estados rompe transiciones/tests
  existentes; el brief pide idempotencia, no más máquina.
- **Transportes enchufables** (`mode`): `off` (default: error claro
  `TRANSPORT_NOT_CONFIGURED`), `file` (escribe `.eml` en
  `workspace/exports/eml/` — dry-run real y puente de tests E2E), `smtp`
  (System.Net.Mail), `mock` (tests). *Por qué:* sin dependencias, degrada
  bien, E2E posible sin servidor SMTP (igual que Ollama en tests).
- **Idempotencia operativa**: pre-check de estado + evento `send.attempt`
  (con `message_id`) escrito ANTES de la red + solo se marca SENT tras
  `ok=true` del transporte. Reenvío de SENT solo con `-Force` (se registra
  `send.forced`, `attempts++`, `sent_at` original se conserva). *Por qué:*
  cubre la ventana crash "enviado pero no marcado" con evidencia en log;
  Message-ID estable ayuda a detectar duplicados.
- **`message_id` propio**: `<M-XXXX.<sha256(body|to)[:16]>@pwx.local>`,
  seteado como header `Message-Id` (best-effort, envuelto en try) y siempre
  como `X-Pwx-Message-Id`; se persiste en el ítem. *Por qué:* SmtpClient no
  expone el ID del servidor; necesitamos correlación propia determinista.
- **Secretos**: password solo en `config/smtp.local.json` (gitignored) o —
  preferido — referenciada por `passwordEnv` (ej. `PWX_SMTP_PASSWORD`).
  `smtp.example.json` con `password: null`. *Por qué:* regla de secretos
  obligatoria; precedente `payment-methods.local.json`.

**Contrato — `config/smtp.local.json` (schema v1)**
```json
{
  "schema_version": "1",
  "mode": "smtp",
  "host": "smtp.ejemplo.com",
  "port": 587,
  "useSsl": true,
  "timeoutSeconds": 20,
  "from": "PWX <avisos@dominio.com>",
  "auth": {
    "username": "avisos@dominio.com",
    "passwordEnv": "PWX_SMTP_PASSWORD",
    "password": null
  }
}
```
- Loader: `PWX_SMTP_CONFIG_FILE` > `config/smtp.local.json`; ausente → modo
  `off`. `passwordEnv` tiene prioridad sobre `password`. Schema `"1"` estricto.
- Override de modo en tests: `$env:PWX_TRANSPORT_MODE = 'mock'|'file'`.

**Contrato — campos outbox (aditivos, sin romper items viejos)**
```json
{
  "transport": "smtp|file|mock|mark-only",
  "message_id": "<M-0001.abcd1234ef567890@pwx.local>",
  "attempts": 1,
  "last_attempt_at": "2026-09-27T...Z",
  "last_error": null
}
```
Items existentes siguen legibles (campos ausentes = null/0 al leer).

**Funciones**
```powershell
# src/core/transport.ps1 (nuevo)
function Get-PwxSmtpConfig                # resolución de config + password (env > file)
function New-PwxTransportResult           # @{ok; transport; message_id; error}
function Send-PwxMockTransport            # ok o throw controlado (PWX_TRANSPORT_MOCK=fail)
function Send-PwxFileTransport            # .eml RFC822 mínimo en exports/eml/
function Send-PwxSmtpTransport            # MailMessage+SmtpClient; subject RFC2047 UTF-8
function Send-PwxOutboxMessage -Id [-Force] [-MarkOnly]
# outbox.ps1: New-PwxOutboxItem gana los campos nuevos (null/0)
# pwx.ps1: outbox:send rework → Send-PwxOutboxMessage (imprime JSON resultado)
```
CLI: `outbox:send -Id <id> [-Force] [-MarkOnly]` (sin comando nuevo;
`outbox:retry` no existe porque reintentar = `outbox:send`).

**Aceptación**
- [ ] `outbox:send` sobre DRAFT → error `OUTBOX_NOT_APPROVED`, archivo NO tocado, cero conexión de red.
- [ ] Sobre APPROVED con `mode: off` → `TRANSPORT_NOT_CONFIGURED` y sigue APPROVED.
- [ ] Con `mode: file` → `.eml` creado con destinatario/asunto/cuerpo correctos y ítem → SENT con receipt completo.
- [ ] Segundo `outbox:send` sobre SENT → `OUTBOX_ALREADY_SENT` (sin `-Force`).
- [ ] `-Force` sobre SENT → reenvía, `attempts++`, evento `send.forced`, `sent_at` original conservado.
- [ ] Transporte que falla (`mock fail`) → ítem **sigue APPROVED**, `last_error` poblado, log `send.fail`, y al reintentar con mock ok → SENT.
- [ ] Tests: log de send **no contiene** password ni `PWX_SMTP_PASSWORD` valor.
- [ ] Config ausente → mensaje accionable (crear smtp.local.json / exportar env).

**Tests (plan)**
- `tests/unit/transport.test.ps1`: resolución config (env > file > off);
  schema inválido rechazado; construcción de MailMessage (subject RFC2047 con
  acentos, From, headers X-Pwx-Message-Id); `.eml` file-transport parseable
  (remitente, destinatario, subject decodificado); mock ok/fail; password nunca
  en resultado ni en log (búsqueda de la cadena secret en salida de logs del test).
- `tests/unit/outbox-send.test.ps1`: matriz de aceptación anterior completa
  (DRAFT/APPROVED/SENT/Force/fail/retry), campos aditivos compatibles con item
  viejo (JSON sin campos → default correctos), transiciones de estado intactas
  (reusa asserts estilo `core.test.ps1`).
- **No hay E2E SMTP real en CI** (opt-in manual documentado en OUTBOX.md,
  análogo a `ollama-live`): `tests/e2e/smtp-live.test.ps1` se omite salvo
  `PWX_SMTP_LIVE=1` con relay configurado.

**Docs**: `docs/OUTBOX.md` (nuevo: flujo, estados, transportes, live-test),
`SECURITY.md` (secretos), README (flags), `ARCHITECTURE.md` (outbox flow).

**Riesgos / mitigación**
- *Reenvío accidental* → guardas en orquestador (no solo en estados) + `-Force`
  explícito + log `send.forced` auditable.
- *Crash entre SMTP-ok y marcado SENT* → log `send.attempt` previo con
  `message_id`; doc describe el caso y el chequeo manual (`outbox:show` +
  revisión de buzón); riesgo aceptado y documentado (sin API de dedupe).
- *Password filtrada en logs/excepciones* → SmtpClient exceptions no incluyen
  credenciales (test de regresión verifica); logger con lista de redacción.
- *PS 5.1: SmtpClient obsoleto-pero-soportado* → misma API en ambas versiones;
  pierna 5.1 de CI lo cubre con mode `file` (unit) — el path SMTP real solo se
  ejercita manualmente (documentado).
- *Subject/acentos mal codificados* → RFC2047 encode + test con `ñ/á`.

---

## 3. Lista de cambios por archivo

### PR-1
| Archivo | Acción | Contenido |
|---|---|---|
| `.github/workflows/ci.yml` | crear | workflow §2.1 |
| `README.md` | editar | badge + sección "CI" (1 párrafo) |
| `docs/TESTING.md` | editar | subsección "CI (GitHub Actions)": qué corre, qué no (Ollama), cómo reproducir |

### PR-2 / PR-3
| Archivo | Acción | Contenido |
|---|---|---|
| `src/core/backup.ps1` | crear | funciones §2.2 |
| `src/bootstrap.ps1` | editar | `'core\backup.ps1'` tras `delivery.ps1` |
| `src/bin/pwx.ps1` | editar | usage + casos `backup:create/list/verify/restore` |
| `config/settings.json` | editar | `"backup": { "dir": "backups" }` (default) |
| `.gitignore` | editar | `backups/` |
| `tests/unit/backup.test.ps1` | crear | casos §2.2 |
| `tests/e2e/backup-restore.test.ps1` | crear | roundtrip + guardas |
| `docs/BACKUP.md` | crear | uso, formato, recuperación post-crash |

### PR-4 / PR-5
| Archivo | Acción | Contenido |
|---|---|---|
| `src/core/auth.ps1` | crear | hash/verify, config, sesiones, `Get-PwxWebAuthDecision`, lockout |
| `src/bootstrap.ps1` | editar | `'core\auth.ps1'` |
| `config/web.example.json` | crear | schema §2.3 sin secretos |
| `src/bin/pwx.ps1` | editar | `web:hash`, `web:start [-Dev]` |
| `src/bin/web.ps1` | editar | `-Dev` switch + gate de arranque |
| `src/web/server.ps1` | editar | gate en `Start-PwxWebServer` (tras validar BindAddress); middleware `Get-PwxWebAuthDecision` en el dispatcher (~L766); rutas `/api/login`, `/api/logout`, `/api/session`, `/api/admin/sessions*`; header `X-Pwx-Auth` |
| `src/web/public/app.js` | editar | overlay de login, `X-Pwx-Panel` en POSTs, whoami + logout, badge de rol |
| `src/web/public/index.html` | editar | markup login/overlay |
| `tests/unit/auth.test.ps1` | crear | casos §2.3 |
| `tests/e2e/web-auth.test.ps1` | crear | casos §2.3 |

### PR-6 / PR-7
| Archivo | Acción | Contenido |
|---|---|---|
| `src/core/transport.ps1` | crear | funciones §2.4 |
| `src/bootstrap.ps1` | editar | `'core\transport.ps1'` |
| `src/core/outbox.ps1` | editar | campos aditivos en `New-PwxOutboxItem`; `Set-PwxOutboxSendReceipt` |
| `src/bin/pwx.ps1` | editar | `outbox:send` → `Send-PwxOutboxMessage` (flags `-Force/-MarkOnly`) |
| `config/smtp.example.json` | crear | schema §2.4 `mode:"off"` |
| `.gitignore` | editar | `config/smtp.local.json` |
| `tests/unit/transport.test.ps1` | crear | casos §2.4 |
| `tests/unit/outbox-send.test.ps1` | crear | matriz de aceptación |
| `tests/unit/core.test.ps1` | revisar | solo si el rework toca algo (esperado: sin cambios — tests usan `Set-PwxOutboxStatus` directo) |

### PR-8
| Archivo | Acción |
|---|---|
| `docs/DECISIONS.md` | crear — ADR-0001..0004 (contexto/decisión/consecuencias) |
| `docs/SECURITY.md` | crear — secretos, roles, backup-PII, "no exponer panel" |
| `docs/OUTBOX.md` | crear — ver §2.4 |
| `README.md`, `docs/ARCHITECTURE.md`, `docs/WEB_PANEL.md`, `docs/TESTING.md`, `docs/AUDITORIA.md` | editar (sección 5) |
| `src/core/config.ps1` | `Get-PwxVersion` → `0.2.0` |

---

## 4. Nuevos tests a agregar (resumen ejecutivo)

| Archivo | # aprox | Casos borde clave |
|---|---|---|
| `unit/backup.test.ps1` | 10 | byte alterado; manifiesto ilegible; schema≠1; store vacío; 0 bytes; rutas raras; content_hash estable |
| `e2e/backup-restore.test.ps1` | 2 | roundtrip con app operando; restore sin `-Force`; pre-restore conservado |
| `unit/auth.test.ps1` | 12 | hash roundtrip; config inválida (0 users/role malo/schema 9); sesión expirada; lockout 10+1; matriz de decisiones |
| `e2e/web-auth.test.ps1` | 6 | deny-start; login→logout; 401 sin cookie; 403 CSRF; 403 rol; dev-mode banner/header |
| `unit/transport.test.ps1` | 9 | config precedence env>file>off; RFC2047 con acentos; `.eml` parseable; password ausente en logs |
| `unit/outbox-send.test.ps1` | 10 | DRAFT jamás; SENT sin `-Force`; fail mantiene APPROVED; retry→SENT; item viejo compatible; `-Force` auditable |
| **Total** | **≈49** | suite 109 → ≈158 |

Todos con el runner actual (`Run-PwxTest`, workspaces aislados, `-ForceJson`,
sin Ollama, sin red).

---

## 5. Docs a actualizar

| Doc | Cambio |
|---|---|
| `README.md` | badge CI; comandos `backup:*`, `web:hash`, `outbox:send` flags; nota de seguridad del panel |
| `docs/TESTING.md` | sección CI (3 piernas, Ollama opt-in, soak) |
| `docs/BACKUP.md` | **nuevo**: crear/verificar/restaurar, formato, recuperación ante crash |
| `docs/WEB_PANEL.md` | Autenticación: config, `-Dev`, roles, cookies, CSRF |
| `docs/OUTBOX.md` | **nuevo**: transporte, modos, idempotencia, testeo live manual |
| `docs/SECURITY.md` | **nuevo**: modelo de secretos (`*.local.json`+env), roles, PII en backups, "no exponer sin TLS" |
| `docs/DECISIONS.md` | **nuevo**: ADR-0001 CI, 0002 backup, 0003 auth, 0004 SMTP |
| `docs/ARCHITECTURE.md` | árbol con `backup/auth/transport.ps1`; flujo outbox con transporte; gate del panel |
| `docs/AUDITORIA.md` | marcar ítems 1-4 de "qué falta" como resueltos en 0.2.0 |
| `.opencode/agents/*.md` | solo si se mencionan comandos nuevos (revisión rápida) |

---

## 6. Checklist final de release (v0.2.0)

**Código**
- [ ] PR-1..PR-8 mergeados en `main`, cada uno con suite verde en su momento
- [ ] Suite final local: `pwsh -File tests/run-tests.ps1` → **100% PASS (≈158)**
- [ ] `tests/soak/run-soak.ps1 -Iterations 5` → 5/5
- [ ] `Get-PwxVersion` = `0.2.0`

**CI**
- [ ] 3 checks verdes en el último commit de `main`
- [ ] Badge README actualizado y en verde
- [ ] Confirmado en logs: pierna `windows-ps51` corre PowerShell 5.1

**Seguridad (antes de tocar nada en red)**
- [ ] `git ls-files | grep -E '\.local\.json$|\.env$|password|secret'` → vacío
- [ ] Búsqueda de secretos en todo el historial (`git log -p | grep -i password`) → sin valores reales
- [ ] `web.local.json`, `smtp.local.json` presentes en `.gitignore`
- [ ] Smoke manual del panel: sin config → **no arranca**; con config → login/logout/roles OK
- [ ] Smoke `-Dev` → warning visible y evento en log

**Backup**
- [ ] `backup:create` → `backup:verify` → OK en store real
- [ ] Restauración de prueba completa en store de juguete (roundtrip E2E ya lo hace, repetir manual en store real con datos de ejemplo)

**Outbox/SMTP**
- [ ] `mode: file` → `.eml` correcto (abrir en cliente de correo)
- [ ] SMTP real manual (opt-in): 1 mensaje APPROVED → llega, ítem SENT, receipt completo
- [ ] Verificado: DRAFT no envía; logs sin password

**Docs y cierre**
- [ ] Los 4 ADR escritos y referenciados desde ARCHITECTURE/README
- [ ] AUDITORIA.md actualizado
- [ ] Tag `v0.2.0` + nota de release en GitHub (resumen de los 4 hitos)
- [ ] Rama principal sin trabajo sin push (revisar `git status`)

---

### Nota de secuenciamiento

Puede avanzarse en paralelo **PR-2/3 (backup)** con **PR-4/5 (auth)** — no se
solapan. PR-6/7 (outbox) es independiente pero conviene **después de PR-1**
para que la suite corra en CI desde el primer cambio de transporte. PR-8 al final.
Tiempo estimado: PR-1 (0.5 h) · PR-2/3 (3-4 h) · PR-4/5 (4-5 h) · PR-6/7 (3-4 h)
· PR-8 (1 h).
