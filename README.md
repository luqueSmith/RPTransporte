# APC Transporte Web v1.4

Actualización visual de la web React de reportes de transporte de APC Corporacion.

## Cambios principales
- Logo corporativo adaptado automáticamente a modo día y modo noche.
- Selector de tema más claro y persistente.
- Revisión del reporte plegable para no saturar la pantalla del administrador.
- Tabla rediseñada con colores corporativos APC, filas más legibles y vista móvil en tarjetas.
- Declaración jurada rediseñada y ordenada para lectura en PC y celular.
- PDF: declaración jurada y tabla con estilo corporativo más limpio.
- Se conservan boletas, declaraciones, estados, aprobación, corrección y volver a revisión.
- No requiere cambios nuevos de base de datos respecto de v1.7.

## Publicar en GitHub Pages
Copia estos archivos sobre el repositorio `RPTransporte` y ejecuta:

```bash
git add .
git commit -m "Mejora diseño APC Transporte v1.4"
git push
```

GitHub Actions compilará y publicará automáticamente la web.
