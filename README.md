# APC Transporte Web v1.2

Web React para que el ingeniero revise los reportes de transporte desde una interfaz sencilla.

## Actualización v1.2
- Historial sincronizado con Supabase.
- Los 3 reportes históricos entregados por Raul se cargan mediante `supabase/ACTUALIZAR_v1.6.sql`.
- Cuando una evidencia histórica ya fue mostrada, la web indica **Ya mostradas** sin intentar abrir una imagen que no está guardada en Supabase.
- Aprobar reporte, solicitar corrección y observaciones siguen disponibles.
- Descarga PDF y Excel se mantiene.
- Compatible con GitHub Pages en `luqueSmith/RPTransporte`.

## Paso importante antes de usar la APK v1.6
En Supabase abre **SQL Editor > New query**, pega y ejecuta completo:

`supabase/ACTUALIZAR_v1.6.sql`

La sección de historial reemplaza los reportes actuales por los 3 reportes históricos solicitados. Después, los reportes nuevos que sincronices desde la APK se agregarán normalmente.

## Desarrollo local
```bash
npm install
npm run dev
```

## Publicar cambios en GitHub
```bash
git add .
git commit -m "Actualiza web APC v1.2"
git push
```
