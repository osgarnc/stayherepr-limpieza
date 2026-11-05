-- Para poder crear solos los bills de los dueños en QuickBooks hacen falta dos
-- datos que el app todavía no guarda.

-- 1) La cuenta de gasto de cada entrada. En los bills que se hacen a mano, el
--    gasto que se le cobra al dueño se acredita a la MISMA cuenta donde se
--    registró el costo: limpieza, compras, reparaciones, reembolsos…
alter table public.ops_property_expenses
  add column if not exists qbo_account_id text;

comment on column public.ops_property_expenses.qbo_account_id is
  'Cuenta de QuickBooks donde se registro el gasto. Es la que se acredita en el bill del dueno.';

-- 2) El proveedor de QuickBooks de cada dueño. El nombre no sirve para ligarlos:
--    "Alan Blunt" en el app es "Alan Blum" en QuickBooks, y OD Investments paga
--    a "Osvaldo Garcia Ortiz".
alter table public.ops_owners
  add column if not exists qbo_vendor_id   text,
  add column if not exists qbo_vendor_name text;

comment on column public.ops_owners.qbo_vendor_id is
  'Id del proveedor de QuickBooks al que se le hace el bill de este dueno.';

-- 3) El bill que ya se creó en QuickBooks, para no duplicarlo y para poder
--    decir en pantalla que ese mes ya está facturado.
alter table public.ops_owner_statements
  add column if not exists qbo_bill_id text;

comment on column public.ops_owner_statements.qbo_bill_id is
  'Id del Bill de QuickBooks que recoge lo pagado a este dueno ese mes.';
