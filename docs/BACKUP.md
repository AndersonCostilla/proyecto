# Backups del store (PWX)

PWX permite crear **backups verificables** del store local (100% offline y gratuito).
Un backup es un **bundle** (directorio) que contiene:

- una copia byte-a-byte del store
- un `manifest.json` (schema v1) con hashes y tamaños
- un `checksums.sha256` con hashes reproducibles

> **Estado:** `create/list/verify` (PR‑2) + `backup:restore` (PR‑3). Ver sección "Restore (PR‑3)".

---

## Objetivo

- Tener snapshots verificables del estado operativo (clientes, trabajos, pagos, outbox, logs, etc.) sin DB externa.
- Poder detectar corrupción / manipulaciones con `backup:verify`.
- Mantener determinismo: dos backups consecutivos del **mismo store** producen el mismo `content_hash` (aunque cambie el timestamp de creación).

---

## ¿Dónde se guardan?

Por defecto PWX guarda bundles en:

- `<repo>/backups/`

Se puede cambiar con la variable de entorno:

- `PWX_BACKUP_DIR` (tiene prioridad sobre el default)

Ejemplos:

### Linux / macOS (pwsh)

```bash
export PWX_BACKUP_DIR="/mnt/datos/pwx-backups"
pwsh -File src/bin/pwx.ps1 backup:create -Label diario
```

### Windows PowerShell 5.1 / pwsh

```powershell
$env:PWX_BACKUP_DIR = 'D:\pwx-backups'
pwsh -File src/bin/pwx.ps1 backup:create -Label diario
```

Nota: `backups/` está ignorado por Git (`.gitignore`) para evitar subir PII por accidente.

---

## Estructura del bundle

Cada bundle es un directorio con nombre:

```text
<UTCSTAMP>[-label]   (ej: 20260927-120501-diario)
```

Contenido:

```text
backups/<bundle>/
  manifest.json
  checksums.sha256
  store/
    ... (copia del store)
```

---

## Qué incluye / qué NO incluye

**Incluye:**

- solo el store: es decir, el workspace que PWX usa como store local (por defecto `<repo>/store/`, según `workspace` en `config/settings.json`, con precedencia de la variable `PWX_WORKSPACE`)

**No incluye:**

- `config/`
- `*.local.json` (secretos)
- dependencias / red / nube

Ojo: aunque no incluye secretos de `config/`, el store **puede contener datos sensibles** (pagos, leads, outbox, trabajos y archivos del cliente). Tratar los bundles como información privada.

---

## Comandos CLI

### `backup:create [-Label <etiqueta>]`

Crea un bundle (directorio) con:

- `store/**` copiado
- `manifest.json`
- `checksums.sha256`

Ejemplo:

```powershell
pwsh -File src/bin/pwx.ps1 backup:create -Label demo
```

Salida (JSON):

- `name`: nombre del bundle
- `path`: ruta absoluta al bundle
- `created_utc`
- `file_count`
- `total_bytes`
- `content_hash`

### `backup:list`

Lista bundles existentes (subdirectorios con `manifest.json`) en orden ordinal.

Ejemplo:

```powershell
pwsh -File src/bin/pwx.ps1 backup:list
```

Salida:

- imprime `Raiz de backups: …`
- luego una línea por bundle con `created_utc`, `name`, `archivos=`, `bytes=`, `content_hash`

### `backup:verify -Path <bundleDir>`

Valida que el bundle no esté corrupto ni incompleto:

- verifica schema (`schema_version == "1"`) y `kind`
- verifica integridad de cada archivo listado en `manifest.json`
- recalcula `content_hash` desde el bundle real
- valida `checksums.sha256` (formato + cobertura + hash)

Ejemplo:

```powershell
pwsh -File src/bin/pwx.ps1 backup:verify -Path backups/20260927-120501-demo/
```

- Si pasa: imprime `VERIFY OK ...` y sale con exit code `0`
- Si falla: imprime `VERIFY FALLA ...` + lista de problemas y sale con exit code `1`

---

## Contrato del manifest.json (schema v1)

Ejemplo (resumen):

```json
{
  "schema_version": "1",
  "kind": "pwx-store-backup",
  "created_utc": "2026-09-27T12:00:00.0000000Z",
  "pwx_version": "…",
  "source": "store",
  "content_hash": "sha256:…",
  "file_count": 123,
  "total_bytes": 4567,
  "complete": true,
  "files": [
    { "path": "store/clients/C-0001/client.json", "sha256": "…", "bytes": 512 }
  ]
}
```

Reglas:

- `schema_version` debe ser string `"1"`. Si no, `backup:verify` falla con `BACKUP_SCHEMA_UNSUPPORTED`.
- `files[].path` usa `/` como separador y siempre empieza por `store/`.
- El orden de `files[]` es determinista (ordinal).

---

## checksums.sha256

Formato: una línea por archivo con:

```text
<sha256>␠␠<path>   (dos espacios)
```

- incluye `manifest.json` y todos los `store/...` del manifest
- termina con newline final

---

## Determinismo: ¿qué es `content_hash`?

`content_hash` es un SHA256 sobre una lista canónica (UTF‑8) de:

```text
<sha256>␠␠<path>\n
```

para cada archivo del store, ordenado por `StringComparer.Ordinal`.

- Si el store no cambia, dos backups consecutivos deben tener el mismo `content_hash`.
- Si hay 1 byte distinto, `backup:verify` debe detectar mismatch (por hash y por `content_hash`).

---

## Operación recomendada

- Para obtener snapshots "limpios", correr backups cuando PWX esté "quieto" (sin jobs corriendo).
- Guardar `PWX_BACKUP_DIR` en un disco/partición con buena durabilidad.
- **No subir bundles a GitHub.** Si se sincronizan, hacerlo bajo responsabilidad del operador (ej. disco cifrado).

---

## Códigos de error (verify)

`backup:verify` devuelve una lista de problemas en formato:

```text
BACKUP_...: detalle
```

Categorías y códigos:

| Categoría | Códigos |
| --- | --- |
| Contrato / manifest | `BACKUP_MANIFEST_MISSING`, `BACKUP_MANIFEST_INVALID`, `BACKUP_SCHEMA_UNSUPPORTED`, `BACKUP_KIND_UNSUPPORTED`, `BACKUP_INCOMPLETE`, `BACKUP_BUNDLE_NOT_FOUND` |
| Rutas | `BACKUP_PATH_UNSAFE`, `BACKUP_PATH_DUPLICADA` |
| Integridad de archivos | `BACKUP_FILE_MISSING`, `BACKUP_FILE_UNLISTED`, `BACKUP_HASH_MISMATCH`, `BACKUP_SIZE_MISMATCH` |
| Consistencia | `BACKUP_COUNT_MISMATCH`, `BACKUP_BYTES_MISMATCH`, `BACKUP_CONTENT_HASH_MISMATCH` |
| Checksums | `BACKUP_CHECKSUMS_MISSING`, `BACKUP_CHECKSUMS_FORMAT`, `BACKUP_CHECKSUMS_DUPLICADA`, `BACKUP_CHECKSUM_COVERAGE`, `BACKUP_CHECKSUM_MISMATCH` |

---

## Restore (PR‑3)

`backup:restore` devuelve el workspace/store actual a un estado respaldado, con verificación previa, preservación del store y swap por rename.

### Comando

```powershell
pwsh -File src/bin/pwx.ps1 backup:restore -Path backups/<bundle>/ [-Force]
```

- Siempre restaura al **workspace actual** (lo que devolvería `Get-PwxWorkspacePath`); no existe `-TargetWorkspace` en v1 (decisión de diseño: menos superficie, mismo funcionamiento).
- Sin errores: imprime `RESTORE OK ...` (y dónde quedó el store anterior) y sale con exit `0`.
- Cualquier guarda que falle: imprime `RESTORE FALLA ...` y sale con exit `1`.

### Qué hace (orden de las guardas)

1. **`BACKUP_RESTORE_BUNDLE_DENTRO_DEL_STORE`**: el bundle NO puede estar dentro del workspace/store (el swap por rename rompería el path a mitad de proceso). Aborta antes de tocar nada — por eso `PWX_BACKUP_DIR` debe quedar fuera del store.
2. `backup:verify` del bundle debe pasar (**`BACKUP_RESTORE_VERIFY_FAILED`** si no; el workspace queda intacto).
3. Si el workspace existe y no está vacío → exige `-Force` (**`BACKUP_RESTORE_FORCE_REQUIRED`**).
4. Copia `<bundle>/store/**` a un tmp hermano `<workspace>.restore-tmp-<UTCSTAMP>` (mismo parent ⇒ mismo volumen) y re-verifica el sha256 de cada archivo contra el manifest (**`BACKUP_RESTORE_STAGING_FAILED`** si algo falla: el store original queda intacto y el tmp puede quedar para inspección).
5. Si había datos: mueve el workspace a `<workspace>.pre-restore-<UTCSTAMP>` (**nunca se borra automáticamente**; vacío no se preserva porque no hay datos).
6. Renombra el tmp → workspace (swap). Si ese rename falla: **`BACKUP_RESTORE_SWAP_FAILED`** con rollback best-effort (devuelve el pre-restore a su lugar).

Durante todo el proceso no se escribe ningún log ni archivo dentro del workspace: el store final contiene **exactamente** los bytes del bundle.

### Qué queda en disco

- `<workspace>.pre-restore-<UTCSTAMP>` — el store anterior completo (solo si había datos y `-Force`).
- `<workspace>.restore-tmp-<UTCSTAMP>` — solo persiste si el proceso falló **antes** del swap; el store original sigue vigente.

### Cómo recuperar si se corta a mitad

| Situación | Estado | Recuperación |
| --- | --- | --- |
| Falla antes del swap (staging) | store original intacto; existe el tmp | inspeccionar y borrar el `*.restore-tmp-*` a mano (o repetir el restore) |
| Falla el rename tmp → workspace | `BACKUP_RESTORE_SWAP_FAILED`: intenta rollback automático | si el rollback no pudo: renombrar manualmente `*.pre-restore-*` (estado previo) o `*.restore-tmp-*` (estado nuevo) hacia el workspace |
| Restore OK | store nuevo + `*.pre-restore-*` conservado | revisar y, cuando ya no se necesite, borrar el pre-restore **a mano** |

**Nunca** borrar un `*.pre-restore-*` sin revisarlo: es tu única copia del estado previo.

### Códigos de error (restore)

| Código | Cuándo |
| --- | --- |
| `BACKUP_RESTORE_BUNDLE_DENTRO_DEL_STORE` | el bundle está dentro del workspace/store |
| `BACKUP_RESTORE_VERIFY_FAILED` | `backup:verify` del bundle no pasó |
| `BACKUP_RESTORE_FORCE_REQUIRED` | workspace no vacío y sin `-Force` |
| `BACKUP_RESTORE_STAGING_FAILED` | error copiando/validando el tmp (store intacto) |
| `BACKUP_RESTORE_SWAP_FAILED` | el rename falló; rollback best-effort |

### Ejemplo completo

```powershell
pwsh -File src/bin/pwx.ps1 backup:create -Label diario
# ...algo se perdio del store...
pwsh -File src/bin/pwx.ps1 backup:list
pwsh -File src/bin/pwx.ps1 backup:restore -Path backups/20260927-120501-diario/ -Force
# RESTORE OK  workspace=...  archivos=123  bytes=4567  sha256:...
# Store anterior preservado en: .../store.pre-restore-20260927-130000
```
