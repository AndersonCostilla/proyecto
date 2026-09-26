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
- Solicitar pago manual a través de un método configurado.
- Subir comprobante y aprobarlo tras revisión humana.

Los archivos de entrada se limitan a 25 MB. Los comprobantes se limitan a 10 MB y aceptan PNG, JPG, JPEG o PDF.

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