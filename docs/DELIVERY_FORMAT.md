# Formato del paquete de entrega (delivery/)

Estandar del paquete que `job:deliver` (`New-PwxDelivery`) genera para **cualquier servicio** en `store/clients/<C-XXXX>/jobs/<J-XXXX>/delivery/`.

## Estructura de `delivery/`

```
delivery/
  manifest.json        # manifest estandar (JSON, UTF-8 sin BOM)
  checksums.sha256     # resumen SHA256 de cada archivo del paquete
  <entregables>        # copia exacta de output/ (misma estructura relativa)
```

- Los entregables son una copia de `output/` tal cual (rutas relativas preservadas).
- `manifest.json` y `checksums.sha256` se generan en el mismo paso; ambos son parte del paquete auditado.
- No se incluye `checksums.sha256` dentro de sí mismo.

## `manifest.json`

Campos (orden determinista y estable de propiedades; `created_utc`/`qa.at_utc` varian por corrida, el resto es fijo):

| Campo | Tipo | Descripción |
|---|---|---|
| `schema_version` | string | Version del esquema del manifest (hoy `"1"`). |
| `job_id` | string | ID del trabajo (`J-XXXX`). |
| `client_id` | string | ID del cliente (`C-XXXX`). |
| `service` | string | Servicio ejecutado (`excel-service`, `simulate-service`, etc.). |
| `created_utc` | string | Fecha de creación del paquete, ISO-8601 UTC (termina en `Z`). |
| `inputs` | array | Entradas del trabajo. Cada item: `{ name, path, sha256, bytes }` con hashes SHA256 reales recalculados desde el archivo en el job. `path` es relativo al directorio del job (ej. `input\planilla.xlsx`). |
| `outputs` | array | Salidas entregadas. Cada item: `{ name, path, sha256, bytes }`. `sha256` coincide con el hash real del archivo copiado en `delivery/`; `path` es relativo a `output/` (= relativo a `delivery/`). |
| `qa` | object | `{ verdict, at_utc }`. `at_utc` es ISO-8601 UTC. Si `verdict != PASS`, ademas incluye `code` y `detail` (QA_NOT_PASS / QA_NOT_RUN, o los campos del QA cuando existan). |
| `notes` | array | Notas del trabajo (puede ser `[]`). |
| `output_version` | int | Version de salida del job (legacy, espejo de `$job.output_version`). |
| `file_count` | int | Cantidad de entregables (legacy, espejo de `outputs.Count`). |
| `files` | array | Lista legacy, espejo de `outputs` con formato antiguo `{ name, path, size, sha256 }` (mantenida por compatibilidad con scripts/CLI). |
| `created_at` | string | Timestamp local al empaquetar (legacy). |
| `delivered_at` | string/null | Timestamp local de la aprobacion; `null` hasta `job:approvedeliver`. |
| `qa_checked_at` | string/null | Timestamp local de la ultima corrida de QA (legacy). |
| `approved_by` | string/null | Quien aprobo la entrega; `null` hasta aprobar. |

## `checksums.sha256`

Texto UTF-8 (sin BOM, saltos de linea LF) con una linea por archivo:

```
<sha256-hex>  <relative_path>
```

- `<relative_path>` es relativo a `delivery/` (ej. `manifest.json`, `resultado-normalizado.xlsx`).
- Cubre cada archivo dentro de `delivery/`, **incluyendo** `manifest.json` y los entregables.
- Se puede verificar con `Get-FileHash` o `sha256sum -c` (en Linux/Git Bash).
- No incluye `checksums.sha256` (se excluye a sí mismo).

## Garantías

- `job:deliver` rechaza sin QA `PASS` o si el output cambió después de QA (`OUTPUT_CHANGED_SINCE_QA`), salvo `-AllowFail` (solo con `PWX_ALLOW_DELIVERY_BYPASS=1`, para tests/desarrollo).
- Las rutas en `manifest.json` y `checksums.sha256` son relativas y validadas contra el workspace (sin path traversal).
- Los hashes se calculan siempre desde los archivos reales del job al momento de empaquetar.
- Las transiciones de estado no cambian: `job:deliver` deja el trabajo en `READY_FOR_DELIVERY` y `job:approvedeliver` en `DELIVERED`.