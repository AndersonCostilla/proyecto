# Panel web local de PWX

El panel web convierte las operaciones principales de PWX en una interfaz de navegador local. Es una primera fase para operadores internos: no es todavía un portal público ni un sistema multiusuario.

## Ejecutarlo

Desde la raíz del repositorio, en Windows PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File src\bin\web.ps1
```

O mediante la CLI:

```powershell
powershell -ExecutionPolicy Bypass -File src\bin\pwx.ps1 web:start
```

Abre después:

```text
http://127.0.0.1:8787
```

Para usar otro puerto:

```powershell
powershell -ExecutionPolicy Bypass -File src\bin\web.ps1 -Port 8790
```

Presiona `Ctrl + C` en PowerShell para detener el servidor.

## Funciones incluidas

- Resumen de clientes, trabajos, pagos pendientes y entregas.
- Registro de un cliente y creación de un pedido.
- Cotizador por servicio, unidades, complejidad, extras y descuento.
- Cola de trabajos con estado y pago asociado.
- Extracción de requisitos mediante Ollama local.
- Adjuntar guía, datos o archivos de entrada desde el navegador.
- Usar el **Asistente Word**: el cliente sube una solicitud `.md`/`.txt`, el modelo local propone preguntas de aclaración, el operador registra respuestas, revisa un borrador y genera un Word temporal.
- Ejecutar una prueba Word aislada desde el navegador: archivo `.md`/`.txt` UTF-8 de máximo 1 MB, requisitos con Ollama local, producción DOCX, QA, entrega temporal y descarga.
- Solicitar pago manual a través de un método configurado.
- Subir comprobante y aprobarlo tras revisión humana.

Los archivos de entrada se limitan a 25 MB. Los comprobantes se limitan a 10 MB y aceptan PNG, JPG, JPEG o PDF.

## Asistente Word: solicitud, preguntas y borrador

La sección **Asistente Word** está diseñada para la fase de preparación de documentos profesionales. El cliente u operador sube una solicitud `.md` o `.txt` UTF-8 de máximo 64 KB con preguntas, temas o actividades. Ollama local analiza el encargo, propone entre tres y ocho preguntas de aclaración y sugiere una estructura. Después de responder, genera un borrador Markdown visible y editable antes de crear el DOCX.

El modelo recibe la instrucción de no inventar hechos, fuentes, cifras o resultados. Los datos no confirmados deben quedar como `Pendiente de confirmar`. El flujo bloquea solicitudes con señales explícitas de trabajos académicos para presentar como propios; puede utilizarse para documentación profesional legítima, informes, propuestas, manuales, diagnósticos, planes y guías autorizadas.

La generación final usa el mismo workspace temporal aislado de la prueba Word. Es una validación local sin cobro: no crea pedidos comerciales, no solicita pagos y no representa un pago como aprobado. Para entregar un servicio comercial real se debe registrar el trabajo, validar requisitos, cotizar, verificar el pago real y pasar por QA dentro del flujo comercial normal.

## Prueba Word sin cobro

La sección **Prueba Word** crea un workspace temporal independiente del `store/` normal del panel. No crea pedidos comerciales, no solicita pagos y no representa un pago como aprobado. Requiere que Ollama y el modelo configurado estén disponibles en el computador local.

Selecciona un archivo `.md` o `.txt` UTF-8 de máximo 1 MB, espera el resultado `DELIVERED` con QA `PASS` y descarga el documento. El enlace queda disponible por 24 horas mientras el servidor del panel continúe abierto. El archivo puede contener datos privados, por lo que debe usarse únicamente en el computador local y no se debe exponer este panel a Internet.

## Seguridad y alcance

El servidor está restringido a `127.0.0.1`/`localhost`. Esto significa que solo se puede abrir desde el mismo computador donde ejecutas PowerShell.

No lo expongas a Internet ni lo publiques mediante port forwarding. Para convertirlo en un portal de clientes público faltan, como mínimo:

- Registro, inicio de sesión y recuperación de cuenta.
- Roles y autorización por cliente, agente, revisor y administrador.
- HTTPS, sesiones seguras, límite de intentos y auditoría.
- Almacenamiento multiusuario y copias de seguridad.
- Revisión de seguridad antes del despliegue.

## Configuración de pagos

Antes de emitir pagos por Nequi o transferencia, crea el archivo privado:

```powershell
Copy-Item config\payment-methods.example.json config\payment-methods.local.json
```

Completa los datos del negocio únicamente en el archivo local. Está ignorado por Git y no debe subirse al repositorio.