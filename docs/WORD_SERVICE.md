# Servicio Word (`word-service`)

El servicio Word genera un documento `.docx` profesional sin necesitar Microsoft Word, Office ni una API de pago. Produce un archivo OpenXML compatible con Microsoft Word, LibreOffice y lectores estándar de DOCX.

## Alcance actual

El servicio convierte contenido proporcionado por el cliente en un documento con estilos profesionales básicos:

- Título con `# `.
- Encabezado principal con `## `.
- Encabezado secundario con `### `.
- Viñeta con `- ` o `* `.
- Párrafos normales en las demás líneas.

Está pensado para propuestas, informes, minutas, cartas, documentación interna y otros documentos profesionales legítimos.

> La producción de Word da formato al contenido proporcionado y al alcance aprobado; no debe utilizarse para entregar trabajo académico ajeno como si fuese propio.

## Archivo de entrada recomendado

Adjunta **un solo archivo** `.txt` o `.md` de hasta 1 MB. Guarda el texto en UTF-8.

Ejemplo `propuesta.md`:

```markdown
# Propuesta comercial

## Objetivo
Organizar el documento para revisión del cliente.

## Alcance
- Normalización de la información.
- Documento Word con formato profesional.
- Entrega en formato DOCX.

## Próximos pasos
Confirma la aprobación para iniciar el servicio.
```

Si no se adjunta un archivo de texto, el servicio genera un documento mínimo a partir de la descripción y objetivo del pedido. Para un trabajo real se recomienda adjuntar el contenido aprobado.

## Salida y QA

El resultado se entrega como:

```text
output/documento-profesional.docx
```

El QA verifica que el archivo:

- Sea un paquete DOCX válido.
- Contenga las partes OpenXML necesarias.
- Incluya texto real en `word/document.xml`.
- No esté vacío.

## Flujo desde el panel web

1. Inicia el panel local con `src\bin\web.ps1`.
2. Crea un pedido con el servicio **Documentos Word**.
3. Escribe una descripción profesional clara.
4. Abre el pedido y adjunta el archivo `.txt` o `.md` en **Archivos de entrada**.
5. Ejecuta **Analizar con Ollama** para registrar requisitos.
6. Emite y aprueba el pago siguiendo el flujo configurado.
7. Ejecuta la producción desde la CLI por ahora:

```powershell
powershell -ExecutionPolicy Bypass -File src\bin\pwx.ps1 job:produce -JobId J-0001
```

8. Revisa el QA, entrega y aprueba:

```powershell
powershell -ExecutionPolicy Bypass -File src\bin\pwx.ps1 job:qa -JobId J-0001
powershell -ExecutionPolicy Bypass -File src\bin\pwx.ps1 job:deliver -JobId J-0001
powershell -ExecutionPolicy Bypass -File src\bin\pwx.ps1 job:approvedeliver -JobId J-0001 -By "operador"
```

## Límites actuales

- No edita todavía un `.docx` de entrada existente.
- No inserta imágenes, tablas, encabezados o referencias automáticas aún.
- No envía el documento por correo/WhatsApp automáticamente.
- PDF, datos y construcción siguen pendientes de implementación de producción.
