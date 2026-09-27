# APC Transporte Web v1.3

Interfaz React sencilla para el administrador del comedor: reporte actual, periodos enviados y cuentas liquidadas en una sola página.

## Cambios principales
- Ya no existe un historial lateral separado: todo se muestra en una vista continua.
- Los periodos antiguos liquidados muestran saldo pendiente **S/ 0.00** y el ajuste de cierre (devolución o regularización).
- El periodo 16–19/09 no se duplica porque está contenido en el consolidado 16–22/09.
- Modo claro/nocturno con preferencia guardada en el navegador.
- Boletas históricas visibles cuando existe imagen; declaraciones juradas visibles desde la misma tabla.
- La boleta extraviada del 13/09 se identifica claramente como **Boleta extraviada**.
- Si una evidencia histórica no está disponible digitalmente puede mostrarse como **Ya mostrada**.
- Para periodos enviados no liquidados: **Aprobar reporte**, **Solicitar corrección** y **Volver a revisión**.
- Exportación consolidada a PDF y Excel.

## Actualizar una instalación existente
1. Ejecuta `ACTUALIZAR_SUPABASE_v1.7.sql` en Supabase SQL Editor.
2. Reemplaza los archivos del repositorio `luqueSmith/RPTransporte` por esta carpeta.
3. Ejecuta `git add .`, `git commit -m "Actualiza APC Transporte v1.3"` y `git push`.

## Desarrollo
```bash
npm install
npm run dev
```

## GitHub Pages
El proyecto conserva `base: '/RPTransporte/'` y `.github/workflows/deploy-pages.yml`.
