-- ============================================================
--  STAY HERE PR — CONTABILIDAD / Reconciliación de ingresos
--  Corre este archivo UNA VEZ en Supabase → SQL Editor.
--  Depende de: fase-ops-reservations.sql y fase-reconciliacion.sql
-- ============================================================

-- ------------------------------------------------------------
-- 1) Credenciales de QuickBooks Online
--    El refresh_token de Intuit ROTA en cada uso, por eso vive en
--    una tabla (hay que reescribirlo) y no en un secret de Supabase.
--    NADIE lo lee desde el navegador: solo service_role.
-- ------------------------------------------------------------
create table if not exists cont_qbo_config (
  id            int primary key default 1 check (id = 1),
  realm_id      text,
  refresh_token text,
  environment   text not null default 'production',
  company_name  text,
  last_refresh  timestamptz,
  updated_at    timestamptz not null default now()
);
insert into cont_qbo_config(id) values (1) on conflict (id) do nothing;

alter table cont_qbo_config enable row level security;
-- Sin políticas = nadie con la llave anon puede leerla ni escribirla.
revoke all on cont_qbo_config from anon, authenticated;
grant all on cont_qbo_config to service_role;

-- ------------------------------------------------------------
-- 2) Mapa propiedad → Clase de QuickBooks
--    Todo asiento lleva clase. Sin esto la app se niega a postear.
-- ------------------------------------------------------------
create table if not exists cont_qbo_class (
  property_id     uuid primary key references ops_properties(id) on delete cascade,
  qbo_class_id    text not null,
  qbo_class_name  text,
  -- Cuando el dueño hace su propia limpieza (Coral Beach), lo cobrado por
  -- limpieza NO es ingreso de Stay Here: se le pasa al dueño.
  cleaning_to_owner boolean not null default false,
  updated_at      timestamptz not null default now()
);
alter table cont_qbo_class add column if not exists cleaning_to_owner boolean not null default false;

-- ------------------------------------------------------------
-- 3) Mapa de cuentas de QuickBooks por tipo de renglón
--    key: limpieza, comision, dueno, roomtax, canal, partnerfee,
--         fee, prepago, sobrecobro, seguro, reparaciones, reserva, banco
-- ------------------------------------------------------------
create table if not exists cont_qbo_account (
  key             text primary key,
  qbo_account_id  text not null,
  label           text,
  updated_at      timestamptz not null default now()
);

-- ------------------------------------------------------------
-- 4) Archivos subidos (un renglón por archivo)
-- ------------------------------------------------------------
create table if not exists cont_uploads (
  id            uuid primary key default gen_random_uuid(),
  month         text not null,                    -- YYYY-MM
  kind          text not null,                    -- hostfully | airbnb | paypal | stripe
  account_label text,                             -- p.ej. "reservas", "servicios", "host.co"
  filename      text,
  storage_path  text,
  row_count     int not null default 0,
  uploaded_by   uuid,
  created_at    timestamptz not null default now()
);
create index if not exists idx_cont_upl_month on cont_uploads(month);

-- ------------------------------------------------------------
-- 5) Finanzas por reserva — sale del reporte de dueños de Hostfully.
--    Es la fuente de verdad del desglose: renta, limpieza, impuesto,
--    comisión de Stay Here y pago al dueño.
-- ------------------------------------------------------------
create table if not exists cont_reservation_finance (
  id             uuid primary key default gen_random_uuid(),
  upload_id      uuid references cont_uploads(id) on delete set null,
  guest_name     text not null,
  guest_key      text not null,                   -- nombre normalizado, para ligar
  property_name  text,
  property_id    uuid references ops_properties(id) on delete set null,
  source         text,                            -- Airbnb / Booking.com / Vrbo / directo
  check_in       date,
  check_out      date,
  rent           numeric not null default 0,
  cleaning       numeric not null default 0,
  extra_guest    numeric not null default 0,
  pet_fee        numeric not null default 0,
  gross_total    numeric not null default 0,
  tourism_tax    numeric not null default 0,
  guest_paid     numeric not null default 0,
  channel_fee    numeric not null default 0,
  processor_fee  numeric not null default 0,
  net_earnings   numeric not null default 0,
  due_stayhere   numeric not null default 0,
  owner_payout   numeric not null default 0,
  -- Impuesto que remite Stay Here. En Airbnb es 0 (lo remite Airbnb) y por eso
  -- no viene dentro del payout; en Booking/Vrbo/directo sí entra y hay que
  -- pasarlo a Sales tax payable.
  tax_remitted   numeric not null default 0,
  created_at     timestamptz not null default now(),
  unique (guest_key, check_in)
);
alter table cont_reservation_finance add column if not exists tax_remitted numeric not null default 0;

-- Alias de pagadores: el nombre que aparece en PayPal/Stripe no siempre es el
-- del huésped (paga la pareja, la empresa, un familiar).
create table if not exists cont_alias (
  payer_key   text primary key,        -- nombre normalizado como llega del banco
  guest_key   text not null,           -- nombre normalizado del huésped en Hostfully
  note        text,
  created_at  timestamptz not null default now()
);
create index if not exists idx_cont_fin_checkin on cont_reservation_finance(check_in);
create index if not exists idx_cont_fin_key on cont_reservation_finance(guest_key);

-- ------------------------------------------------------------
-- 6) Payouts / retiros — un renglón por depósito que llega al banco
-- ------------------------------------------------------------
create table if not exists cont_payouts (
  id             uuid primary key default gen_random_uuid(),
  month          text not null,
  source         text not null,                   -- airbnb | paypal | stripe
  account_label  text,
  ref            text not null,                   -- referencia del payout / fecha del retiro
  pay_date       date not null,
  amount         numeric not null,                -- lo que llega al banco
  matched        numeric not null default 0,      -- suma de los renglones cuadrados
  status         text not null default 'pendiente',
                 -- pendiente | listo | posteado | excluido
  unresolved     jsonb not null default '[]'::jsonb,
  qbo_deposit_id text,
  qbo_posted_at  timestamptz,
  note           text,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  unique (source, account_label, ref, pay_date)
);
create index if not exists idx_cont_pay_month on cont_payouts(month);
create index if not exists idx_cont_pay_status on cont_payouts(status);

-- ------------------------------------------------------------
-- 7) Renglones de cada payout — es literalmente el depósito de QBO
-- ------------------------------------------------------------
create table if not exists cont_payout_lines (
  id            uuid primary key default gen_random_uuid(),
  payout_id     uuid not null references cont_payouts(id) on delete cascade,
  ord           int not null default 0,
  kind          text not null,                    -- limpieza | comision | dueno | roomtax | ...
  amount        numeric not null,
  property_id   uuid references ops_properties(id) on delete set null,
  qbo_class_id  text,
  guest_name    text,
  description   text,
  created_at    timestamptz not null default now()
);
create index if not exists idx_cont_line_payout on cont_payout_lines(payout_id);

-- ------------------------------------------------------------
-- 8) Bitácora de escrituras a QuickBooks (para poder auditar y revertir)
-- ------------------------------------------------------------
create table if not exists cont_qbo_log (
  id          uuid primary key default gen_random_uuid(),
  payout_id   uuid references cont_payouts(id) on delete set null,
  action      text not null,
  ok          boolean not null,
  qbo_id      text,
  intuit_tid  text,
  detail      text,
  created_by  uuid,
  created_at  timestamptz not null default now()
);
create index if not exists idx_cont_log_created on cont_qbo_log(created_at desc);

-- ------------------------------------------------------------
-- 9) Seguridad: todo esto es solo para quien tiene can_reconcile()
--    (can_reconcile() ya existe, viene de fase-reconciliacion.sql)
-- ------------------------------------------------------------
alter table cont_qbo_class           enable row level security;
alter table cont_qbo_account         enable row level security;
alter table cont_uploads             enable row level security;
alter table cont_reservation_finance enable row level security;
alter table cont_payouts             enable row level security;
alter table cont_payout_lines        enable row level security;
alter table cont_alias               enable row level security;
alter table cont_qbo_log             enable row level security;

do $$
declare t text;
begin
  foreach t in array array['cont_qbo_class','cont_qbo_account','cont_uploads',
                           'cont_reservation_finance','cont_payouts','cont_payout_lines','cont_alias']
  loop
    execute format('drop policy if exists p_%s_rec on %I', t, t);
    execute format('create policy p_%s_rec on %I for all to authenticated
                    using (can_reconcile()) with check (can_reconcile())', t, t);
  end loop;
end $$;

-- La bitácora se lee pero no se escribe desde el navegador.
drop policy if exists p_cont_log_read on cont_qbo_log;
create policy p_cont_log_read on cont_qbo_log for select to authenticated using (can_reconcile());

grant all on cont_qbo_class, cont_qbo_account, cont_uploads,
             cont_reservation_finance, cont_payouts, cont_payout_lines, cont_alias
         to authenticated, service_role;
grant select on cont_qbo_log to authenticated;
grant all on cont_qbo_log to service_role;

-- ------------------------------------------------------------
-- 10) Bucket para guardar los CSV originales
-- ------------------------------------------------------------
insert into storage.buckets (id, name, public)
  values ('contabilidad','contabilidad',false)
  on conflict (id) do nothing;

drop policy if exists p_cont_files on storage.objects;
create policy p_cont_files on storage.objects for all to authenticated
  using (bucket_id = 'contabilidad' and can_reconcile())
  with check (bucket_id = 'contabilidad' and can_reconcile());

-- ------------------------------------------------------------
-- 11) Cuentas de QuickBooks de Stay Here PR (los IDs reales).
--     Si algún día cambian, edítalas desde la pantalla de Ajustes
--     de Contabilidad, no aquí.
-- ------------------------------------------------------------
insert into cont_qbo_account(key, qbo_account_id, label) values
  ('banco',       '10',         'Flexicuenta de Negocios (banco)'),
  ('limpieza',    '112',        'Cleaning Fee'),
  ('comision',    '109',        'Rental & Commissions'),
  ('dueno',       '1150040023', 'Pagos Pendientes a Dueños de Propiedades'),
  ('roomtax',     '27',         'Sales tax payable'),
  ('canal',       '37',         'Commissions & fees'),
  ('partnerfee',  '37',         'Commissions & fees (fee de Hostfully)'),
  ('fee',         '1150040001', 'STRIPE FEE EXPENSE'),
  ('paypalfee',   '1150040021', 'Paypal Fee'),
  ('reserva',     '1150040002', 'Reserve Funds (retención de Stripe)'),
  ('prepago',     '26',         'Customer prepayments'),
  ('sobrecobro',  '26',         'Customer prepayments (cobro doble a devolver)'),
  ('seguro',      '66',         'Insurance claims'),
  ('reembolso',   '30',         'Refunds & discounts'),
  ('reparaciones','50',         'Repairs & maintenance'),
  ('earlyci',     '1150040020', 'EARLY CHECK IN'),
  ('extraguest',  '115',        'Extra Guest'),
  ('servicio',    '2',          'Services')
on conflict (key) do nothing;

-- ============================================================
--  FIN — Contabilidad
-- ============================================================
