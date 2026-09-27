# Auditoría PWX — 2026-09-27

> Estado del repositorio: commit `7846e08` (merge de las dos líneas de trabajo) ·
> **109/109 tests en verde** · 28 commits · sin nada pendiente de subir.

---

## 1. Qué es el proyecto y para qué sirve

**PWX es el motor operativo local de un negocio de servicios digitales** (MindSprit /
Anderson Costilla). Toma un trabajo comercial de punta a punta:

```text
prospección de clientes → cotización → pago → requisitos (LLM) → producción
→ QA automático → paquete de entrega con huellas → aprobación humana → outbox
```

**Para qué sirve en la práctica:** que una sola persona (o un operador con panel)
pueda vender y entregar servicios digitales — planillas Excel, documentos Word, PDFs,
limpieza de datos y computos de obra — **sin APIs de pago, sin base de datos externa
y sin depender de la nube**: todo corre en la máquina local con un LLM local (Ollama).

**Principios innegociables del diseño (lo que le da valor):**

1. **Separación LLM ↔ determinismo**: el modelo solo razona, clasifica y redacta;
   precios, IDs, estados, archivos, QA y totales los calcula código verificable.
   El LLM **nunca inventa precios**.
2. **Nada sale solo**: mensajes van a `outbox` como DRAFT y un humano aprueba;
   la producción exige un pago aprobado manualmente con comprobante.
3. **Mismo input → mismos bytes**: todos los servicios son deterministas y el QA
   valida la salida contra la fuente antes de permitir `job:deliver`.
4. **100% local y gratuito**: PowerShell + Ollama; sin dependencias de terceros.

---

## 2. Lo que se ha implementado (inventario completo — nada se descarta)

### 2.1 Núcleo determinista (commits `f1cb7be` → `3b167c2`)

| Componente | Archivo | Qué hace |
|---|---|---|
| Máquina de estados | `src/core/state.ps1` | NEW → REQUIREMENTS → READY_FOR_PRODUCTION → IN_PROGRESS → QA → READY_FOR_DELIVERY → DELIVERED → COMPLETED, con BLOCKED/REWORK/CANCELLED |
| Clientes y trabajos | `src/core/store.ps1` | CRUD en disco (`store/`), IDs secuenciales C-/J-/M-/L-, entradas de trabajo por bucket (input/output/delivery), versionado |
| Precios | `src/core/pricing.ps1` | Catálogo `config/services.json`, addons (rush, etc.), descuentos con tope, **nunca** vía LLM |
| QA | `src/core/qa.ps1` | Checks deterministas: output no vacío, `required_output` por contrato, validadores por servicio, detección de cambios post-QA |
| Entrega | `src/core/delivery.ps1` | Paquete estándar `delivery/` con `manifest.json` + `checksums.sha256`, aprobación (`Approve-PwxDelivery`), re-ejecución idempotente |
| Outbox | `src/core/outbox.ps1` | Cola DRAFT → APPROVED → SENT con aprobación humana obligatoria + **export a CSV** con protección anti formula-injection |
| Registro | `src/core/log.ps1`, `id.ps1`, `fs.ps1` | Logs JSONL globales y por trabajo, rutas seguras anti path-traversal, hashes SHA256 |
| Contratos de entrega | `docs/DELIVERY_FORMAT.md` | Manifest con orden determinista de propiedades, inputs/outputs hasheados |

### 2.2 Servicios comerciales — **6/6 implementados**

| Servicio | Estado | Implementación | De quién |
|---|---|---|---|
| `excel-service` | ✅ | Lee hoja 1 con límites en streaming, reescribe XLSX determinista (ZIP timestamp fijo), QA compara grilla input vs output (734 líneas) | repo original |
| `word-service` | ✅ | Convierte `.txt`/`.md` a `.docx` profesional (`documento-profesional.docx`): títulos, encabezados, **viñetas preservadas entre codificaciones**, fallback desde la descripción del pedido; wizard guiado en el panel web | línea paralela (`2ca3740`…`877b547`) |
| `pdf-service` | ✅ | PDF 1.4 escrito a mano: xref con offsets byte-precisos, WinAnsi (acentos ES intactos), wrap y paginación; QA valida estructura **y** texto extraído contra la fuente | esta sesión (`7c69837`) |
| `data-service` | ✅ | Parser CSV RFC4180 propio, limpieza fija (dedupe, trim, emails minúsculas, filas vacías), informe de contadores; QA exige `salida == limpiar(input)` | esta sesión (`7c69837`) |
| `construction-service` | ✅ | CSV de partidas con encabezados flexibles es/en, números tolerantes (`1.234,56`, `$`, COP), redondeo AwayFromZero, `presupuesto.xlsx` con fila TOTAL; QA recalcula y compara grillas | esta sesión (`7c69837`) |
| `simulate-service` | ✅ | Motor de prueba determinista (exento de pago) | repo original |

### 2.3 Comercial: cotizaciones y cobro manual (línea paralela, `286f987`, `7a2a874`)

- **`quote:calc`**: cotización determinista con niveles de complejidad
  (basic/standard/advanced/expert), unidades, addons y descuento con tope
  (`docs/PRICING.md`, precios reducidos: excel 64.000, word 48.000, pdf 40.000,
  data 96.000, construction 160.000 COP).
- **Flujo de pago manual** (`src/core/payments.ps1`, `docs/PAYMENTS.md`):
  `REQUESTED → PROOF_SUBMITTED → APPROVED/REJECTED` con snapshot inmutable de la
  cotización y comprobante adjunto. **La producción queda bloqueada**
  (`PAYMENT_REQUIRED`) hasta que un operador apruebe el pago.
- Métodos de pago en archivo privado `config/payment-methods.local.json`
  (plantilla `payment-methods.example.json`), override por entorno.

### 2.4 Prospección gratis (Fase 6, `eda0c17` → `c632cf5`)

- Hub de **leads** (`lead:*`): import CSV/JSON, **ingesta Socrata** (datos.gov.co),
  alta manual, dedupe por email/teléfono/dominio, scoring determinista (0–100),
  estados NEW→…→CONVERTED, conversión lead→cliente.
- **Borradores** email/WhatsApp con plantillas y perfil de marca (MindSprit),
  receptor correcto por canal, nunca se envía solo → todo va al outbox DRAFT.
- Agente de prospección con Ollama real (`b113b7b`) con plantillas deterministas de respaldo.

### 2.5 Panel web local (`0a9827d`, `622a471`, `877b547` — 1.135 líneas)

- Servidor PowerShell en `127.0.0.1:8787` (`src/web/server.ps1` + UI HTML/CSS/JS).
- Operaciones end-to-end desde el navegador: crear pedidos, cotizar, analizar
  requisitos, adjuntar archivos, solicitar pagos, registrar comprobantes,
  y el **wizard de redacción Word** (preguntas autorizadas → borrador Markdown
  con Ollama → producción).
- Alcance declarado: operadores internos, **no exponer a Internet** (`docs/WEB_PANEL.md`).

### 2.6 Integración LLM (Ollama)

- Cliente Ollama con categorización de errores y reintentos (`881bfad`):
  OLLAMA_OFFLINE / MODEL_NOT_FOUND / MODEL_ERROR / MODEL_TIMEOUT.
- Agentes: requisitos (JSON validado + conformado contra catálogo), producción
  (orquesta servicio + QA), prospección.
- **`real-agent-check.ps1`** (`7a2a874`, `d450ad5`): verificación real de todos
  los agentes contra Ollama sin tocar personas ni pagos reales.
- Sin Ollama todo funciona con `-ForceJson` (determinismo para tests/CI).

### 2.7 Calidad y pruebas — **109/109 ✅**

| Tipo | Archivos | Cobertura |
|---|---|---|
| Unit (16) | core, fs, excel, word, pdf, data, construction, leads, ollama, outbox-export, payments, prospecting-agent, qa-delivery, robustness, fixes, web | cada componente con asserts propios |
| E2E (6) | flow, excel-flow, services-flow (5 ciclos completos a DELIVERED), leads, runner, ollama-live (opt-in) | ciclo cliente→…→DELIVERED con entrega verificada |
| Soak | `tests/soak/run-soak.ps1` | entregas consecutivas sin corrupción |
| Runner propio | sin Pester | workspaces aislados en temp, inyección LLM |

- **Multiplataforma**: arreglo de la suite para PowerShell 7 en Linux/macOS
  (`d224854`: GetTempPath, `-DateKind String`, `Get-PwxShellExe`, separadores).
  Probado en pwsh 7.6.6 Linux; compatible con Windows PowerShell 5.1.

### 2.8 Documentación (11 guías)

`README` (completo), `ARCHITECTURE`, **`SERVICES`** (contratos por servicio — nueva),
`DELIVERY_FORMAT`, `EXCEL_LOCAL`, `PROSPECTING`, `TESTING`, `PRICING`, `PAYMENTS`,
`WEB_PANEL`, `WORD_SERVICE` + `examples/informe-tecnico-plan-negocio-ejemplo.md`.

### 2.9 Integración de las dos líneas (esta sesión)

- Merge `7846e08`: resolvió 5 conflictos (word, precios, README, arquitectura,
  servicios) **sin descartar nada** — tu word/panel/pagos intactos, mis
  pdf/data/construction y cross-platform encima, suite combinada en verde.

---

## 3. Dónde vamos (dirección actual)

El proyecto dejó de ser "un motor CLI" y se convirtió en **una plataforma de
operaciones local con cara de negocio**:

1. **Vender** (prospección → cotización → cobro manual) ✅ base hecha
2. **Producir** (6 servicios + LLM) ✅ base hecha
3. **Entregar** (QA + manifiesto + aprobación) ✅ base hecha
4. **Operar desde el panel** ✅ fase 1 hecha (local, sin usuarios)
5. **Comunicarse** ❌ solo borradores (falta transporte real)

La propia documentación marca el rumbo: pasarela de pago real *después*
(adaptador + webhooks verificados) y el panel *después* de tener seguridad
(roles/HTTPS) antes de exponerlo.

---

## 4. Qué falta (deuda y pendientes, por prioridad)

### 🔴 Alto valor / bloqueantes para crecer

1. **Transporte real del outbox** — hoy solo exporta CSV. Falta un adaptador
   SMTP (Gmail/con correo propio) o WhatsApp Business API **que respete el
   contrato actual**: solo enviar items APPROVED, jamás DRAFT.
2. **Sin respaldo del `store/`** — todo vive en disco local; un fallo del disco
   pierde clientes, trabajos, pagos y logs. Falta backup automático (y opcional
   sincronización cifrada).
3. **Panel sin autenticación** — bind a 127.0.0.1 y sin login. Antes de cualquier
   exposición (incluso en LAN) faltan: usuario/contraseña o token, roles
   (operador vs admin) y HTTPS.
4. **CI/CD ausente** — los 109 tests se corren a mano. Un GitHub Actions que
   ejecute `tests/run-tests.ps1` en cada push (Linux + Windows) blindaría la
   rama `main`.

### 🟡 Valor medio / siguientes pasos de producto

5. **Pagos: verificación semi-automática** — hoy el comprobante lo aprueba una
   persona a ciegas. Falta: referencia obligatoria, validación de formato,
   y luego adaptador Nequi/banco con webhook (como indica `PAYMENTS.md`).
6. **Riqueza de formatos** — PDF: sin imágenes, tablas, colores de marca ni
   encabezados/pie con logo; Word: estilos básicos (sin plantillas Visuales
   MindSprit); Excel: solo hoja 1 y sin fórmulas.
7. **construction-service: alcance contable** — hoy totales por partida y gran
   total. El catálogo ya ofrece addon `apv` (Análisis de Precios Unitarios)
   que el servicio **aún no calcula**; tampoco respeta formatos normativos
   (ej. Norma 24 de valuación de obras).
8. **data-service: solo CSV** — sin JSON/Excel como entrada ni export enriquecido
   (informe HTML, estadísticas de columnas, detección de tipos).
9. **Auditoría visible** — los eventos JSONL existen pero no hay vista de
   historial/auditoría en el panel.

### 🟢 Bajo perfil / higiene

10. Duplicado `services:list` en la ayuda de la CLI (cosmético).
11. Docs de panel/word aún dicen "Windows PowerShell" (funcionan en pwsh 7,
    igual que el resto, pero el texto no se actualizó).
12. i18n: todo hardcodeado en español (correcto para el negocio actual).
13. Empaquetar instalador o módulo PowerShell para distribuir sin clonar el repo.
14. `real-agent-check` y E2E Ollama son opt-in: no corren en CI sin modelo.

---

## 5. Métricas de la auditoría

| Métrica | Valor |
|---|---|
| Commits | 28 |
| Código fuente (`src/`) | ~6.825 líneas PowerShell + 1.135 web |
| Tests (`tests/`) | ~2.987 líneas · 22 archivos |
| Suite | **109/109 PASS** (pwsh 7.6.6) |
| Servicios implementados | **6/6** |
| Comandos CLI | ~40 |
| Documentos | 11 guías + ejemplo |
| Dependencias externas de ejecución | PowerShell + Ollama (opcional para tests) |
| Última verificación | 2026-09-27, commit `7846e08` |

---

## 6. Veredicto

- **Solidez**: alta — arquitectura con responsabilidades separadas, QA que
  valida contra la fuente, entrega con huellas, 109 tests y doble línea de
  desarrollo ya integrada sin pérdidas.
- **Completitud funcional**: el ciclo completo del negocio está cerrado
  excepto el **envío real de mensajes** y el **respaldo de datos**, que son
  los dos agujeros críticos.
- **Siguiente hito recomendado, en orden**: (1) CI con GitHub Actions,
  (2) backup del `store/`, (3) autenticación del panel, (4) transporte SMTP
  del outbox. Con esos cuatro, PWX pasa de "motor local excelente" a
  "sistema operable a diario con riesgo bajo".
