# Stay Here PR — App de Limpieza

App web (un solo archivo) conectada a Supabase. Se publica en Vercel **sin compilar**.

## Archivos
| Archivo | Qué es |
|---|---|
| `index.html` | La app real (conectada a Supabase). Es lo que se publica. |
| `config.js` | Tus llaves de Supabase. **Debes editarlo antes de usar.** |
| `fase1_stayherepr.sql` | Base de datos: tablas, roles y seguridad (RLS). |
| `fase2-supabase.sql` | Fotos (Storage), datos de la empresa y ajustes de triggers. |
| `limpieza-app.html` | Prototipo original (solo referencia de diseño, datos falsos). |

## Puesta en marcha (una sola vez)

### 1. Base de datos
En Supabase → **SQL Editor** → New query, corre en orden:
1. `fase1_stayherepr.sql`
2. `fase2-supabase.sql`

### 2. Confirmar correo (para pruebas rápidas)
Supabase → **Authentication → Providers → Email** → puedes desactivar
"Confirm email" mientras pruebas, para que las cuentas nuevas entren sin confirmar.

### 3. Llaves en `config.js`
Supabase → **Project Settings → API**. Copia:
- **Project URL** → `SUPABASE_URL`
- **anon public** → `SUPABASE_ANON_KEY`

### 4. Crear tu usuario dueño
1. Abre la app → **Crear cuenta nueva** con tu correo.
2. En Supabase → SQL Editor:
   ```sql
   update profiles set role='owner', active=true
   where email = 'TU-CORREO@ejemplo.com';
   ```
3. Entra. Ya puedes activar al resto desde **Back Office → Usuarios**.

## Publicar en Vercel
1. Entra a [vercel.com](https://vercel.com) → **Add New → Project**.
2. Opción fácil: arrastra esta carpeta en **Vercel → Deploy** (o conéctala a GitHub).
3. No hace falta configurar build: es un sitio estático. Vercel sirve `index.html`.
4. **Importante:** en Supabase → Authentication → **URL Configuration**, añade la URL
   que te dé Vercel (ej. `https://tu-app.vercel.app`) a *Site URL* y *Redirect URLs*.

## Flujo de uso
- **Personal (cleaner):** entra, elige propiedades, adjunta foto antes/después
  (y daño opcional), envía. También puede enviar gastos con recibo.
- **Administradora/Dueño (back office):** aprueba/rechaza, ve fotos, arma facturas
  semanales, descarga factura y reporte de fotos, marca pagado.

## Pendiente para Fase 3
- Envío **automático por correo** de la factura + reporte (necesita una Supabase
  Edge Function con un servicio de correo). Hoy el botón marca la semana como
  archivada y las descargas de factura/reporte ya funcionan.
