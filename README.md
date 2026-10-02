# APC Transporte Web v1.9

Actualización enfocada en hacer el filtro de fechas más fácil de encontrar y usar.

## Novedades
- El filtro por fecha ahora está dentro del bloque **Movimientos / Detalle de transporte**.
- Ya no ocupa una tarjeta completa encima del período actual.
- Los campos de fecha se abren al tocar el campo completo o el botón visible **Elegir**.
- Accesos rápidos: **Hoy**, **Últimos 7 días**, **Este mes** y **Ver todo**.
- El filtro continúa aplicándose al reporte actual y a períodos anteriores.
- Si se filtra una fecha antigua, el período actual no desaparece: el administrador conserva siempre los controles del filtro.
- Ajustes responsivos para PC, tablet y móvil.

No requiere ejecutar SQL nuevo ni actualizar la APK.


## v1.12 · Estado de entrega de boletas
La columna Sustento muestra, solo para boletas, **Entregada** o **Pendiente de entregar**. El estado lo cambia el trabajador desde la APK v2.0 y se refleja al sincronizar.

Antes de usar esta versión junto con la APK v2.0, ejecuta `ACTUALIZAR_SUPABASE_v1.8_BOLETAS_ENTREGADAS.sql` en Supabase.
