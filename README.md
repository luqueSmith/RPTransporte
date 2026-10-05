# APC Transporte Web v1.23 — revisión final

Esta versión deja la revisión de movimientos como una función exclusiva de la web.

## Cambios

- Botón visible **Quitar del cálculo** en gastos y créditos del período abierto/finalizado.
- Sin cuadro de confirmación: el cambio se aplica directamente.
- Si se toca por error aparece **Volver a incluir**.
- El movimiento nunca se elimina; queda visible como **Fuera del cálculo**.
- Los totales de la web se recalculan automáticamente.
- Los períodos liquidados no se pueden modificar.
- La columna **Detalle / ruta** se redujo ligeramente para dar espacio al control de cálculo.
- PDF y Excel descargados desde la web indican si un movimiento quedó fuera del cálculo.
- La APK no necesita actualización y sus funciones `apc_owner_*` / `apc_sync_report` no se modifican.
- El SQL fuerza una recarga del schema cache de Supabase/PostgREST para corregir el error de función no encontrada.

## Orden correcto

1. En Supabase > SQL Editor ejecuta `ACTUALIZAR_SUPABASE_v1.23_REVISION_WEB.sql`.
2. Ejecuta `ACTUALIZAR_WEB_V1.23.ps1`.
3. Espera 1–3 minutos y recarga GitHub Pages con Ctrl+F5.
