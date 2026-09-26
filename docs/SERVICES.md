# Servicios del catalogo — contratos de entrada, salida y QA

Todos los servicios son **deterministas**: mismo input -> mismos bytes de salida.
Ninguno depende del LLM; el modelo solo participa en requisitos (clasificacion y texto).
El QA valida la salida contra la fuente **antes** de permitir `job:deliver`.

| Servicio | Entrada (`job/input/`) | Salida (`job/output/`) | Validador QA |
| --- | --- | --- | --- |
| `simulate-service` | ninguna | `resultado.txt` | (checks genericos) |
| `excel-service` | `*.xlsx` (unico) | `resultado-normalizado.xlsx` | `Test-PwxExcelOutput` |
| `word-service` | `*.txt` / `*.md` (opcional) | `documento.docx` | `Test-PwxWordOutput` |
| `pdf-service` | `*.txt` / `*.md` (opcional) | `documento.pdf` | `Test-PwxPdfOutput` |
| `data-service` | `*.csv` (unico) | `datos-limpios.csv` + `informe-limpieza.txt` | `Test-PwxDataOutput` |
| `construction-service` | `*.csv` (unico) | `presupuesto.xlsx` | `Test-PwxConstructionOutput` |

## Resolucion de entrada (comun)

1. Si `requirements.input_files` tiene un unico nombre y existe en `job/input/` -> ese archivo.
2. Si no hay candidato y `job/input/` tiene exactamente 1 archivo -> ese.
3. Varias entradas sin candidato unico -> error `*_MULTIPLE_INPUTS` (los servicios de texto
   admiten un unico `.txt`/`.md` si la eleccion es inequívoca).
4. Extension no soportada -> `*_UNSUPPORTED_FORMAT`.

`word-service` y `pdf-service` ademas tienen **fallback a la solicitud**: sin ningun archivo,
generan el documento desde `requirements.objective` (titulo) + `requirements.constraints`
(como viñetas). Los demas servicios exigen archivo de entrada.

## simulate-service

Genera `resultado.txt` con datos del trabajo. Sirve para probar el ciclo completo sin
entradas reales. El constraint `PWX_TEST_EMPTY_OUTPUT` produce un archivo vacio (para
ejercitar QA negativo).

## excel-service

- Lee la hoja 1 del `.xlsx` de entrada (streaming con limites: 10k filas, 400 cols,
  200k celdas, 50MB por parte ZIP).
- Reescribe la grilla normalizada en `resultado-normalizado.xlsx` con escritor propio
  (ZIP con timestamp fijo -> bytes deterministas).
- QA: lee entrada y salida, exige grilla identica (filas, columnas, tipos y valores).

## word-service

- Escritor OOXML propio: `[Content_Types].xml`, `_rels/.rels`, `word/document.xml`
  (orden fijo, UTF-8 sin BOM, timestamp ZIP fijo).
- Un parrafo de entrada = un `<w:p>`; texto escapado XML; lineas vacias preservadas.
- QA: estructura valida + **secuencia de parrafos identica** (igualdad ordinal) a la fuente.

## pdf-service

- PDF 1.4 escrito a mano: Catalog/Pages/2 fuentes Helvetica (WinAnsi), A4, wrap por
  palabras (titulo 14pt, cuerpo 10pt), paginacion automatica.
- Texto transliterado a WinAnsi-compatible: acentos espanoles intactos; tipografia
  Unicode -> equivalente ASCII; fuera de rango -> `?`.
- offsets de xref calculados byte a byte (texto ensamblado como Latin-1).
- QA: cabecera/`%%EOF`, `/Count` == paginas reales, **cada offset de xref apunta a
  `N 0 obj`**, y el texto extraido (`Tj`) linea a linea == fuente transformada.

## data-service

- Parser CSV RFC4180 propio (comillas, comillas dobles, CRLF/LF), deteccion de
  delimitador `,`/`;` en la primera linea.
- Limpieza fija: encabezados (trim + colapso de espacios + dedupe con sufijo `_2`),
  celdas (trim + colapso), columnas de correo en minusculas, filas 100% vacias fuera,
  duplicados exactos fuera (se conserva la primera).
- Salida: `datos-limpios.csv` (escritor propio: comillas solo si hace falta, LF,
  UTF-8 sin BOM) + `informe-limpieza.txt` con contadores exactos.
- QA: `salida == limpiar(input)` celda a celda + contadores del informe reales.
- Errores: `DATA_NO_INPUT`, `DATA_UNSUPPORTED_FORMAT`, `DATA_MULTIPLE_INPUTS`,
  `DATA_EMPTY_INPUT`, `DATA_BAD_CSV`, `DATA_LIMITS_EXCEEDED`.

## construction-service

- Entrada CSV con columnas flexibles (es/en, mayusculas/acentos indiferentes):
  `descripcion` (obligatoria), `cantidad`, `precio_unitario` (obligatorias),
  `unidad`, `partida` (opcionales). Alias aceptados: `description`, `concepto`,
  `quantity`, `price`, `pu`, `valor`, etc.
- Numeros tolerantes: `1.234,56` / `1,234.56` / `1,250` / `$ 150000.50` / `COP 99.99`
  (el ultimo separador visto es el decimal).
- Calculo: total de linea = `Round(cantidad * precio, 2, AwayFromZero)`; total general =
  suma de totales de linea (redondeo final igual). El LLM nunca interviene.
- Salida: `presupuesto.xlsx` (columnas Partida/Descripcion/Unidad/Cantidad/Precio/
  Total + fila `TOTAL`), usando el escritor XLSX determinista.
- QA: **recalcula el plan desde el input** y exige identidad de grilla
  (`Compare-PwxExcelGrid`).
- Errores: `CONSTRUCTION_NO_INPUT`, `CONSTRUCTION_UNSUPPORTED_FORMAT`,
  `CONSTRUCTION_MULTIPLE_INPUTS`, `CONSTRUCTION_BAD_INPUT` (columnas faltantes,
  numeros invalidos, cantidad <= 0), `CONSTRUCTION_NO_ROWS`.

## Contrato de cada servicio en `config/services.json`

```json
"contract": {
  "output": ["patron1", "patron2"],   // required_output conformado en requisitos
  "validators": ["Test-PwxXxxOutput"] // invocados por QA con -JobId; retornan {ok, detail}
}
```

`implemented: false` en el catalogo hace que produccion deje el trabajo en `BLOCKED`
con `SERVICE_NOT_IMPLEMENTED` (hoy los 6 estan en `true`).

## Codigos de error de servicios de texto

`WORD_*` / `PDF_*`: `NO_INPUT`, `EMPTY_INPUT`, `MULTIPLE_INPUTS`, `UNSUPPORTED_FORMAT`,
`BAD_INPUT` (nombre de candidato invalido), `NOT_ZIP`/`BAD_XML`/`MISSING_PARTS` (docx),
`LIMITS_EXCEEDED`, `INTERNAL`.
