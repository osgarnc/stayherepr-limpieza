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

---

# 📒 Contabilidad — Ingresos

Reemplaza el trabajo manual de cuadrar los payouts contra QuickBooks. Subes los
reportes del mes, la app los cuadra contra las reservas de Hostfully y crea los
depósitos en QuickBooks **listos para hacerles match con la cuenta de banco**.

## Archivos
| Archivo | Qué es |
|---|---|
| `fase-contabilidad.sql` | Tablas, permisos y el catálogo de cuentas de QBO. |
| `deliverable-cont-qbo.ts` | Edge Function `cont-qbo`: el único que habla con Intuit. |

## Puesta en marcha (una sola vez)

### 1. Base de datos *(ya hecho)*
Las tablas se aplicaron como migraciones desde el repo `stayhere-ops`:
`20260909000000_contabilidad.sql` y `20260909010000_contabilidad_credenciales.sql`.
`fase-contabilidad.sql` se queda aquí como referencia legible.

### 2. Dar acceso
Contabilidad solo la ve quien tenga `can_reconcile`:
```sql
update profiles set can_reconcile = true where email = 'TU-CORREO@ejemplo.com';
```

### 3. Conectar QuickBooks — todo desde la app

En la app → **Contabilidad → Ingresos → 🔑 Conexión**. Ahí pegas:

| Campo | De dónde sale |
|---|---|
| Company ID (Realm) | QuickBooks → Cuenta y configuración → Facturación |
| Client ID y Client Secret | [Intuit developer dashboard](https://developer.intuit.com/app/developer/dashboard) → tu app → Keys |
| Refresh Token | [OAuth Playground](https://developer.intuit.com/app/developer/playground) |

Se guardan en `cont_qbo_config`, una tabla **sin RLS y sin permisos para
`anon`/`authenticated`**: solo `service_role` la lee. Compruébalo si quieres —
un `select` a esa tabla con la llave del navegador devuelve `401`.

Al volver a la pantalla solo verás los **últimos 4 caracteres** de cada valor.
**Lo que dejes vacío no se toca**, así que puedes renovar el token sin volver a
pegar el secret.

> ⚠️ **El refresh token de Intuit rota en cada uso y solo puede vivir en un
> sitio.** Si lo pones aquí, los scripts locales de `Stayhere accounting/qbo`
> dejan de funcionar, y al revés. Escoge uno de los dos.

Los secrets `QBO_CLIENT_ID` / `QBO_CLIENT_SECRET` de Edge Functions siguen
sirviendo de respaldo si alguna vez los pusiste, pero ya no hacen falta.

### 4. Desplegar la función *(ya hecho)*

Vive en el repo **`stayhere-ops`**, que es el que gobierna esta base de datos:
`supabase/functions/cont-qbo/index.ts`. Para redesplegar:
```bash
cd ../stayhere-ops && supabase functions deploy cont-qbo
```

### 5. Mapear propiedades a clases
En la app → **Contabilidad → Ingresos → ⚙️ Clases y cuentas** →
**Traer clases y cuentas de QuickBooks**, y asigna la clase de cada propiedad.
Marca **"la limpieza es del dueño"** en las propiedades donde el dueño limpia
(Coral Beach): ahí lo cobrado por limpieza se le pasa a él, no es ingreso tuyo.

**Sin clase la app se niega a postear.** Es a propósito.

## Cómo se usa cada mes
1. **Sube el reporte de dueños de Hostfully primero.** De ahí sale el desglose
   de cada reserva; sin él no hay nada que cuadrar.
2. Sube los payouts de Airbnb, la actividad de PayPal y los payouts de Stripe
   (una subida por cuenta de Stripe: reservas, servicios, host.co).
3. **Cuadrar el mes.** Agrupa los payouts, les busca sus reservas y arma el
   desglose. No escribe nada en QuickBooks todavía.
4. Resuelve los pendientes. Cada uno tiene dos salidas:
   - **es el huésped…** — cuando el que paga tiene otro nombre (paga la
     empresa, la pareja, un familiar). Se guarda como alias y queda aprendido.
   - **clasificar como…** — cuando no es una reserva: un reembolso, un cliente
     de limpieza, un cobro de prueba, una reclamación de seguro.
5. **Postear los que cuadran.** Solo sube lo que cuadra al centavo y trae clase
   en todos sus renglones.

## Reglas que aplica sola
- **El impuesto de turismo de Airbnb no entra**, porque Airbnb lo remite. Usa
  la columna *Tax To Be Remitted by Ingrid*, no *Tourism Tax*.
- **Co-host vs. payout completo**: si Airbnb le paga al dueño directo, solo
  registra limpieza y comisión.
- **Diferencias contra Hostfully las absorbe la comisión**, que es el residuo
  del negocio. La limpieza y el impuesto son montos fijos.
- **Una reserva se desglosa una sola vez.** Si vuelve a aparecer (un ajuste, un
  segundo tramo, un reembolso parcial), se reparte entre comisión y dueño con
  la proporción original — si no, la limpieza se cobraría dos veces.
- **Cobro doble del impuesto**: si al huésped se le cobró exactamente un 7% de
  más, ese dinero va a *Customer prepayments* como deuda con él, no a ingreso
  ni a impuesto por remitir.
- **El barrido de PayPal se lleva el saldo que había cuando se disparó**, no
  todo lo acumulado: un cobro que entra minutos después cae en el retiro del
  día siguiente.
- **No escribe dentro del periodo ya reconciliado** (hasta 2026-07-31). Está
  en `PERIODO_CERRADO` dentro de la Edge Function.

## Gastos
La pestaña de Gastos hoy tiene los gastos por propiedad que ya existían. Ahí es
donde crece cuando decidas cómo quieres trabajarlos.
