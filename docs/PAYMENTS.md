# Cobro previo y comprobantes manuales

PWX incorpora un flujo local de **cotización, comprobante y aprobación manual**. Está diseñado para comenzar sin pasarelas de pago ni APIs pagas.

> El sistema no cobra dinero ni valida movimientos de Nequi o bancos automáticamente. Solo prepara una solicitud de pago, guarda un comprobante y exige que una persona lo apruebe antes de habilitar la producción.

## Flujo

```text
Requisitos completos
→ Cotización determinista
→ Solicitud de pago
→ Cliente paga por el método acordado
→ Cliente entrega comprobante
→ Operador revisa y aprueba
→ Producción habilitada
```

Los servicios comerciales requieren un pago con estado `APPROVED` antes de iniciar `job:produce`. El servicio `simulate-service` queda exento porque se usa para demos y pruebas.

## Configuración privada de métodos de pago

1. Copia el ejemplo:

```powershell
Copy-Item config\payment-methods.example.json config\payment-methods.local.json
```

2. Edita `config/payment-methods.local.json` con datos reales del negocio. Por ejemplo:

```json
{
  "currency": "COP",
  "methods": {
    "nequi": {
      "name": "Nequi",
      "enabled": true,
      "recipient": "3001234567",
      "instructions": "Envía el valor exacto a Nequi 3001234567 y usa el ID del trabajo como referencia.",
      "qr_path": "C:\\ruta-local\\qr-nequi.png"
    }
  }
}
```

3. Nunca subas este archivo al repositorio: ya está incluido en `.gitignore`.

La ruta del código QR es opcional. El archivo no se publica ni se entrega automáticamente; solo se guarda como referencia para el operador.

Para pruebas se puede cargar otro archivo de métodos mediante la variable de entorno `PWX_PAYMENT_METHODS_FILE`.

## Comandos

### Ver métodos disponibles

```powershell
powershell -ExecutionPolicy Bypass -File src\bin\pwx.ps1 payment:methods
```

### Calcular una cotización

```powershell
powershell -ExecutionPolicy Bypass -File src\bin\pwx.ps1 quote:calc `
  -ServiceId excel-service `
  -Complexity advanced `
  -Units 3 `
  -Addons rush `
  -DiscountPct 5
```

La cotización toma una instantánea de:

- Precio base del servicio.
- Unidades incluidas y unidades adicionales.
- Complejidad: `basic`, `standard`, `advanced` o `expert`.
- Add-ons, por ejemplo `rush`.
- Descuento permitido por el catálogo.

### Solicitar pago de un trabajo

Los requisitos del trabajo deben estar completos antes de cotizar y solicitar cobro.

```powershell
powershell -ExecutionPolicy Bypass -File src\bin\pwx.ps1 payment:request `
  -JobId J-0001 `
  -Method nequi `
  -Complexity standard `
  -Units 1
```

La solicitud queda en estado `REQUESTED` y almacena una instantánea inmutable de la cotización y del método elegido.

### Registrar comprobante

```powershell
powershell -ExecutionPolicy Bypass -File src\bin\pwx.ps1 payment:proof `
  -JobId J-0001 `
  -Path "C:\evidencias\comprobante.png" `
  -Reference "NEQUI-123456"
```

Se aceptan `.png`, `.jpg`, `.jpeg` y `.pdf`, con un máximo de 10 MB. El archivo se copia dentro del workspace del pago y se le calcula SHA-256.

### Aprobar o rechazar

```powershell
powershell -ExecutionPolicy Bypass -File src\bin\pwx.ps1 payment:approve -JobId J-0001 -By "Anderson"
```

```powershell
powershell -ExecutionPolicy Bypass -File src\bin\pwx.ps1 payment:reject `
  -JobId J-0001 `
  -By "Anderson" `
  -Reason "El comprobante no coincide con el valor cotizado"
```

Solo un comprobante en estado `PROOF_SUBMITTED` puede ser aprobado. Tras rechazo, se puede crear una nueva solicitud de pago.

## Estados de pago

```text
REQUESTED
→ PROOF_SUBMITTED
→ APPROVED

REQUESTED / PROOF_SUBMITTED
→ REJECTED
```

Un pago aprobado no se modifica por CLI. Esto evita que la producción continúe con evidencia alterada.

## Límites de esta fase

- No hay cobro automático ni conexión con Nequi, bancos o QR dinámicos.
- La aprobación depende de una persona que valide el monto y el comprobante.
- No se generan facturas electrónicas.
- No reemplaza procesos contables ni legales.

Esta es la ruta gratuita y controlada para comenzar. Una pasarela real puede añadirse después mediante un adaptador independiente y webhooks verificados.