# Reglas de cotización

El catálogo `config/services.json` define precios base y reglas deterministas para cada servicio. La IA puede ayudar a describir requisitos, pero no calcula ni modifica precios.

## Fórmula

```text
subtotal de trabajo = precio base + (unidades adicionales × valor por unidad)
ajuste de complejidad = subtotal de trabajo × (multiplicador - 1)
subtotal = subtotal de trabajo + ajuste de complejidad + add-ons
descuento = subtotal × porcentaje de descuento permitido
valor final = subtotal - descuento
```

## Complejidad

Cada servicio define sus multiplicadores en el catálogo:

| Nivel | Uso recomendado |
|---|---|
| `basic` | Trabajo rutinario, limpio y bien definido. |
| `standard` | Alcance normal del precio base. |
| `advanced` | Reglas complejas, validaciones, análisis o diseño adicional. |
| `expert` | Alto riesgo, automatización compleja o revisión especializada. |

## Unidades por tipo de servicio

| Servicio | Unidad | Incluido en base | Cobro adicional |
|---|---|---:|---:|
| Excel | Hoja | 1 | Por hoja adicional |
| Word | Página | 5 | Por página adicional |
| PDF | Página | 10 | Por página adicional |
| Limpieza de datos | Mil registros | 5 | Por cada mil registros adicionales |
| Construcción | Ítem de obra | 20 | Por ítem adicional |

Los montos concretos viven en `config/services.json`, no en este documento. Así pueden ajustarse sin cambiar el código.

## Ejemplo

```powershell
powershell -ExecutionPolicy Bypass -File src\bin\pwx.ps1 quote:calc `
  -ServiceId excel-service `
  -Units 3 `
  -Complexity advanced `
  -Addons rush
```

La respuesta incluye todos los componentes del cálculo, incluidos unidades extra, multiplicador, add-ons, descuento, total en COP y horas estimadas.

## Política operativa

1. Revisar requisitos, archivos y fecha antes de emitir una cotización.
2. No usar descuentos superiores al máximo configurado para el servicio.
3. Emitir pago solo con un alcance entendido y rastreable.
4. Si el alcance cambia de forma material, rechazar la solicitud de pago anterior y emitir una nueva.
5. No producir trabajos comerciales hasta que exista un comprobante aprobado.

## Alcance responsable

La cotización está orientada a servicios profesionales legítimos: organización de archivos, automatización, análisis, diseño, edición, documentación corporativa y asesoría. No se debe usar para entregar trabajo académico de terceros como si fuera obra propia ni para ocultar el uso de IA.