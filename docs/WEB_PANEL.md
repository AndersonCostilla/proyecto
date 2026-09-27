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

## Autenticación del panel (núcleo PR‑4)

El núcleo de autenticación ya existe en el código (`src/core/auth.ps1`): hashing de contraseñas con PBKDF2, validación de configuración, sesiones en memoria y la función de decisión que el middleware consumirá. **La integración real al panel (endpoint de login, cookies de sesión y control de roles por ruta) llega en PR‑5**; mientras tanto, abrir el panel no cambia en nada y esta sección solo describe cómo preparar la configuración.

### Archivo `config/web.local.json`

Copia el ejemplo (sin secretos) y edítalo localmente:

```powershell
Copy-Item config\web.example.json config\web.local.json
```

El archivo está ignorado por Git. Su schema v1 es:

```json
{
  "schema_version": "1",
  "auth": {
    "enabled": false,
    "users": [
      { "id": "admin",   "role": "admin",    "passwordHash": "REEMPLAZAR" },
      { "id": "operador", "role": "operator", "passwordHash": "REEMPLAZAR" }
    ]
  }
}
```

Reglas que valida el núcleo (`Test-PwxWebAuthConfigValid`, sin lanzar excepciones):

- `schema_version` debe ser exactamente `"1"` (texto).
- `auth.enabled` debe ser booleano.
- Con `enabled: true`: `users` no puede estar vacío; cada usuario necesita `id` no vacío y único, `role` igual a `operator` o `admin`, y `passwordHash` con formato `pbkdf2-sha256$<iters>$<salt>$<hash>` (o `pbkdf2-sha1$...` como compatibilidad en runtimes sin SHA256).
- Con `enabled: false` solo se exigen `schema_version` y `enabled` (el panel queda abierto, sin login).

Si el archivo no existe, `Get-PwxWebAuthConfig` devuelve `$null`. La ruta puede sobrescribirse con la variable de entorno `PWX_WEB_CONFIG_FILE` (útil para pruebas).

### Generar hashes: `web:hash`

```powershell
pwsh -File src/bin/pwx.ps1 web:hash -Password "mi-password"
```

Imprime **una sola línea** con el hash, lista para pegar en `passwordHash` de `config/web.local.json`. Sin `-Password` el comando pide la contraseña de forma interactiva con `Read-Host`:

```powershell
pwsh -File src/bin/pwx.ps1 web:hash
```

Precauciones:

- Pasar `-Password` en la línea de comandos deja la contraseña en el **historial del shell** y en la lista de procesos del sistema; para uso diario prefiere el modo interactivo.
- El hash no se puede revertir (PBKDF2 con 120000 iteraciones, salt aleatorio de 16 bytes), pero no sustituye un archivo local protegido: `config/web.local.json` es privado como `payment-methods.local.json`.

### Qué decidirá el middleware (contrato PR‑5)

`Get-PwxWebAuthDecision -Path -Method -Headers -Config -DevMode` responde `{ allowed, code, userId, role, reason }` con estas reglas:

| Situación | allowed | code | reason |
|---|---|---|---|
| Rutas públicas: `GET /`, `GET /app.js`, `GET /styles.css`, `POST /api/login` | sí | 200 | `PUBLIC` |
| Cualquier otra sin cookie `pwx_session` válida | no | 401 | `AUTH_REQUIRED` |
| Mutación (`POST`/`PUT`/`PATCH`/`DELETE`) sin header `X-Pwx-Panel: 1` | no | 403 | `CSRF_HEADER_MISSING` |
| `/api/admin/*` con rol `operator` | no | 403 | `FORBIDDEN_ROLE` |
| Con sesión válida (y header CSRF si es mutación) | sí | 200 | `SESSION_OK` |
| `auth.enabled: false` en la config | sí | 200 | `AUTH_DISABLED` |
| Ejecución con `-DevMode` | sí | 200 | `DEV_MODE` |

Las sesiones viven solo en memoria: se crean con `New-PwxWebSession` (TTL en minutos), se limpian con `Invoke-PwxWebSessionSweep` y desaparecen al reiniciar el servidor. Ninguna ruta del panel usa todavía esta decisión; eso se conecta en PR‑5 (deny-start sin config, `-Dev`, `/api/login`, cookies y roles).

## Configuración de pagos

Antes de emitir pagos por Nequi o transferencia, crea el archivo privado:

```powershell
Copy-Item config\payment-methods.example.json config\payment-methods.local.json
```

Completa los datos del negocio únicamente en el archivo local. Está ignorado por Git y no debe subirse al repositorio.