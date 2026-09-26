# APC Corporacion · Reportes de transporte

Web React/Vite para que el ingeniero revise los reportes que la APK sincroniza con Supabase.

## 1. Base de datos
Ejecuta `database.sql` (entregado aparte) completo en **Supabase > SQL Editor**.

PIN inicial de la web: **2026**.

## 2. Ejecutar localmente
```bash
npm install
npm run dev
```

## 3. Compilar
```bash
npm run build
```
La carpeta `dist` queda lista para publicar.

## 4. GitHub + Vercel
1. Sube esta carpeta a un repositorio GitHub.
2. En Vercel: New Project > importa el repositorio.
3. Framework preset: Vite.
4. Build command: `npm run build`.
5. Output directory: `dist`.

La URL y la publishable key de Supabase ya están configuradas en `src/config.js`.
La **service_role/secret key NO está incluida** y no debe colocarse en código del navegador.

## Uso
- La APK funciona offline y conserva los movimientos localmente.
- Cuando haya internet, usa **Sincronizar web** / **Enviar al ingeniero** desde la APK.
- El ingeniero abre la web, ingresa el PIN, revisa el reporte, abre boletas/declaraciones, agrega una observación y puede aprobar o solicitar corrección.
- PDF y Excel se generan desde la propia web.
