# Outbox y transporte (PWX)

El outbox es la cola de mensajes salientes de PWX. Nada se envía solo: cada
mensaje nace en `DRAFT`, un humano lo aprueba, y solo entonces puede enviarse
con un **transporte**. Desde PR-6 existe un transporte real y 100% gratuito:
`file`, que escribe un correo `.eml` completamente local.

> **Estado:** `new/show/list/approve/export` (original) + `Send-PwxOutboxMessage`
> con transportes `file | mock | mark-only` (PR-6). `smtp` queda **reservado
> para PR-7** y hoy se rechaza con error claro.

---

## Objetivo

- Enviar notificaciones/entregas al cliente sin depender de APIs pagas ni nube.
- Mantener la regla del proyecto: **nada sale sin aprobación humana**.
- Tener trazabilidad completa de cada intento de envío (`attempts`,
  `last_error`, `last_attempt_at`) y logs auditables (`send.attempt`,
  `send.fail`, `send.forced`).
- Cero red: ningún transporte abre conexiones (ni siquiera `smtp`, que aún no
  existe).

---

## Ciclo de vida del mensaje

```text
DRAFT ──(humano: outbox:approve)──> APPROVED ──(Send-PwxOutboxMessage)──> SENT
                                          │
                                          └── fallo del transporte ──> sigue APPROVED
                                                                          (nunca SENT a ciegas)
```

| Estado    | Significado                                    | ¿Se puede enviar?                |
|-----------|------------------------------------------------|----------------------------------|
| `DRAFT`   | Borrador creado por PWX o por el operador      | **Jamás** (error explícito)      |
| `APPROVED`| Un humano lo aprobó para envío                 | Sí, con cualquier transporte     |
| `SENT`    | Ya fue enviado por un transporte               | No, salvo `-Force` (reenvío)     |

Invariantes (también válidos con `-Force`):

- Un `DRAFT` **jamás** se envía con ningún transporte.
- Un fallo de transporte **no** cambia el estado del mensaje.
- Los reenvíos con `-Force` se marcan como `send.forced` en el log.

---

## Transportes

| Transporte   | Qué hace                                                        | Red | Archivos |
|--------------|-----------------------------------------------------------------|-----|----------|
| `file`       | Escribe un correo `.eml` real en `workspace/exports/eml/`       | No  | `.eml`   |
| `mock`       | Simula el envío (tests/desarrollo)                              | No  | No       |
| `mark-only`  | Solo transiciona `APPROVED -> SENT` (comportamiento histórico)  | No  | No       |
| `smtp`       | **Reservado PR-7**: hoy lanza `TRANSPORT_SMTP_NOT_IMPLEMENTED`  | —   | —        |

### `file`: correo `.eml` 100% local (transporte gratuito por defecto recomendado)

Genera un archivo de correo estándar (RFC 5322 + MIME) por mensaje:

- Ruta: `<workspace>/exports/eml/M-NNNN.eml` (un archivo por mensaje, nombre
  determinista basado en el id).
- Cabeceras: `Message-ID`, `Date`, `From`, `To`, `Subject`, `MIME-Version`,
  `X-Pwx-Outbox-Id`, `X-Pwx-Channel`, `X-Pwx-Transport`.
- Asuntos con caracteres no-ASCII viajan como *encoded-word* `=?UTF-8?B?...?=`.
- El cuerpo viaja como `text/plain; charset=utf-8`, `Content-Transfer-Encoding:
  base64` (reproducible byte a byte en cualquier plataforma).
- Los adjuntos del mensaje se incluyen como partes MIME `base64` con su
  `X-Pwx-Sha256`.
- **Verificación de adjuntos**: al enviar, cada adjunto se re-hashea y se
  compara con el `sha256` registrado cuando se creó el mensaje. Si el archivo
  cambió o desapareció, el envío falla (`send.fail`) y el mensaje se queda en
  `APPROVED`.

Puedes abrir el `.eml` con cualquier cliente de correo (Outlook, Thunderbird,
Mail, Gmail web) o adjuntarlo/reenviarlo manualmente: PWX nunca abre una
conexión por ti.

### `mock`

Ejecuta todo el ciclo (intento, transición, logs) sin escribir el `.eml`.
Ideal para tests y para ensayar flujos sin generar archivos.

### `mark-only`

Comportamiento histórico del outbox: transiciona `APPROVED -> SENT` sin ningún
efecto externo. Es el **default** para no cambiar el comportamiento de
instalaciones existentes.

### `smtp` (reservado para PR-7)

- Hoy `outbox:send -Transport smtp` falla con `TRANSPORT_SMTP_NOT_IMPLEMENTED`
  **antes** de intentar nada (cero red, cero dependencias).
- El formato previsto está documentado en `config/smtp.example.json`
  (copia privada: `config/smtp.local.json`, gitignored; password vía variable
  de entorno `PWX_SMTP_PASSWORD`).
- PWX seguirá funcionando sin SMTP: `file` ya resuelve el transporte gratis.

---

## Comandos

```text
outbox:new      -Recipient <dest> -Subject <asunto> -Body <texto> [-Type message] [-JobId <id>] [-Attachments <rutas>]
outbox:show     -Id <msg-id>
outbox:list     [-Status DRAFT|APPROVED|SENT]
outbox:approve  -Id <msg-id> -By <quien>
outbox:send     -Id <msg-id> [-Transport file|mock|mark-only|smtp] [-Force]
outbox:export   [-Path <ruta>]   (exporta DRAFT a CSV; solo lectura, no envía)
```

Ejemplo completo con transporte `file`:

```bash
pwsh -File src/bin/pwx.ps1 outbox:new -Recipient cliente@correo.com -Subject "Entrega lista" -Body "Su archivo esta listo."
pwsh -File src/bin/pwx.ps1 outbox:approve -Id M-0001 -By anderson
pwsh -File src/bin/pwx.ps1 outbox:send -Id M-0001 -Transport file
# -> escribe store/exports/eml/M-0001.eml y marca M-0001 como SENT
```

Reenvío explícito de un mensaje ya enviado:

```bash
pwsh -File src/bin/pwx.ps1 outbox:send -Id M-0001 -Transport file -Force
```

---

## Configuración del transporte por defecto

Prioridad (de mayor a menor):

1. Flag `-Transport` del comando `outbox:send`.
2. Variable de entorno `PWX_TRANSPORT`.
3. `config/settings.json` → `"outbox": { "transport": "..." }`.
4. `mark-only` (fallback seguro).

`config/settings.json`:

```json
{
  "outbox": {
    "transport": "mark-only"
  }
}
```

Ejemplos:

### Linux / macOS (pwsh)

```bash
export PWX_TRANSPORT=file
pwsh -File src/bin/pwx.ps1 outbox:send -Id M-0001
```

### Windows PowerShell 5.1 / pwsh

```powershell
$env:PWX_TRANSPORT = 'file'
powershell -File src\bin\pwx.ps1 outbox:send -Id M-0001
```

---

## Campos del mensaje (`store/outbox/M-NNNN.json`)

| Campo             | Desde    | Significado                                            |
|-------------------|----------|--------------------------------------------------------|
| `id`              | original | Id secuencial `M-NNNN`                                 |
| `status`          | original | `DRAFT` / `APPROVED` / `SENT`                          |
| `message_id`      | PR-6     | `<M-NNNN@pwx.local>`: identificador estable del mensaje (el mismo que viaja en la cabecera `Message-ID` del `.eml`) |
| `attempts`        | PR-6     | Número de intentos de envío registrados                |
| `last_attempt_at` | PR-6     | Timestamp del último intento                           |
| `last_error`      | PR-6     | Último error de transporte (`null` tras un envío exitoso) |
| `approved_by/at`  | original | Quién y cuándo aprobó                                  |
| `sent_at`         | original | Cuándo pasó a `SENT` (se refresca en reenvíos `-Force`)|
| `attachments[]`   | original | `path` + `sha256` + `size` verificados al enviar       |

**Compatibilidad:** los mensajes creados por versiones anteriores (sin los
campos nuevos) siguen siendo enviables; los campos se normalizan on-demand.

---

## Eventos y auditoría

Cada envío queda registrado en dos sitios:

- `store/logs/app.log.jsonl` — componente `transport`:
  - `send.attempt id=M-0001 transport=file attempt=1 forced=False`
  - `send.file id=M-0001 eml=<ruta> bytes=N`
  - `send.mock id=M-0001 (...)`
  - `send.fail id=M-0001 transport=smtp attempt=1 error=...` (nivel `ERROR`)
  - `send.forced id=M-0001 transport=file attempt=2`
- `store/logs/jobs/J-NNNN.jsonl` — si el mensaje tiene `job_id`, los mismos
  eventos quedan asociados al trabajo (`send.attempt`, `send.fail`,
  `send.forced`).

---

## Invariantes de seguridad

- `DRAFT` **jamás** se envía; la transición requiere `outbox:approve` humano.
- `SENT` no se reenvía salvo `-Force`, y todo reenvío queda marcado
  (`send.forced`).
- Un fallo de transporte deja el mensaje en su estado anterior y registra
  `last_error`: nunca hay `SENT` a ciegas.
- Cero red: ningún transporte abre conexiones.
- Los adjuntos se verifican con SHA-256 contra el registro original.
- El `.eml` solo puede escribirse dentro de `workspace/exports/eml/`
  (`Assert-PwxSafeWorkspacePath` + `Assert-PwxSafeFileName`: path traversal
  bloqueado).
- Las cabeceras del `.eml` se sanean contra *header injection* (CR/LF y
  comillas eliminados; asuntos no-ASCII viajan como encoded-word).

---

## Errores

| Mensaje / código                            | Causa                                             |
|---------------------------------------------|---------------------------------------------------|
| `Mensaje inexistente: <id>`                 | El id no existe en el outbox                      |
| `Transporte no soportado: <x>`              | `-Transport` inválido                             |
| `Mensaje <id> esta en DRAFT: requiere aprobacion humana` | Intento de enviar sin aprobar       |
| `Mensaje <id> ya fue SENT: use -Force`      | Reenvío sin `-Force`                              |
| `TRANSPORT_SMTP_NOT_IMPLEMENTED`            | `smtp` reservado PR-7                             |
| `TRANSPORT_NO_RECIPIENT`                    | `file` exige destinatario para escribir el correo |
| `TRANSPORT_ATTACHMENT_MISSING`              | Un adjunto ya no existe                           |
| `TRANSPORT_ATTACHMENT_HASH_MISMATCH`        | Un adjunto cambió desde su registro (sha256)      |

---

## Limitaciones conocidas

- No hay envío real por SMTP/WhatsApp: `file` produce el `.eml` listo para que
  un humano lo envíe desde su propio correo (decisión de diseño: gratis,
  offline, auditable). SMTP opcional llegará en PR-7.
- El `.eml` no sale de la máquina por sí solo.
- `outbox:export` sigue siendo solo para `DRAFT` (sin cambios).
