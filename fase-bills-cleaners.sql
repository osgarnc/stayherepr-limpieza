-- ============================================================
--  Bills de las cleaners en QuickBooks
--  Lo mismo que se hizo con los dueños, pero para las facturas
--  bisemanales de las cleaners.
-- ============================================================

-- 1) El proveedor de QuickBooks de cada cleaner. El nombre no sirve para
--    ligarlos: "Ana Polanco Garcia" en el app es "Ana C. Polanco Garcia" en
--    QuickBooks, y "Mayra Lespier Cruz" es "Mayra Josefa Lespier Cruz".
alter table public.professionals
  add column if not exists qbo_vendor_id   text,
  add column if not exists qbo_vendor_name text;

comment on column public.professionals.qbo_vendor_id is
  'Id del proveedor de QuickBooks al que se le hace el bill de esta cleaner.';

-- 2) La cuenta de QuickBooks de cada categoría de factura libre. Es por
--    categoría y no por renglón: una sola decisión sirve para siempre.
alter table public.invoice_categories
  add column if not exists qbo_account_id text;

comment on column public.invoice_categories.qbo_account_id is
  'Cuenta de QuickBooks donde entra un renglon de esta categoria.';

-- Una categoría por nombre, para que sembrarlas no las duplique.
create unique index if not exists idx_invcat_name on public.invoice_categories(lower(name));

-- Las categorías fijas vivían solo en el código; se siembran para poderles
-- poner cuenta. El app las une por nombre, así que no se duplican.
insert into public.invoice_categories(name, qbo_account_id) values
  ('Repair and Maintenance','50'),
  ('Cleaning supplies','1150040008'),
  ('Commissions','37'),
  ('Purchases','110'),
  ('Vehicle expense','58'),
  ('Utilities','54')
on conflict do nothing;

update public.invoice_categories set qbo_account_id='1150040011'
  where lower(name)='hoa fees' and qbo_account_id is null;

-- 3) La clase de QuickBooks de cada propiedad DEL APP DE LIMPIEZA. Ojo: no es
--    la misma tabla que la de contabilidad (`properties` vs `ops_properties`,
--    con ids distintos), así que la clase se guarda aquí.
-- `properties` tiene un trigger set_updated_at pero le falta la columna, asi que
-- CUALQUIER update a esta tabla falla ("record new has no field updated_at").
-- Es un bug de antes: tambien rompia editar una propiedad en Ajustes.
alter table public.properties
  add column if not exists updated_at timestamptz not null default now();

alter table public.properties
  add column if not exists qbo_class_id text;

comment on column public.properties.qbo_class_id is
  'Clase de QuickBooks de esta propiedad, para los bills de las cleaners.';

-- 4) El bill que ya se creó, para no duplicarlo y para poder decir en pantalla
--    que esa bisemana ya está en QuickBooks.
create table if not exists public.ops_cleaner_bills (
  professional_id uuid not null references public.professionals(id) on delete cascade,
  week            date not null,                 -- inicio de la bisemana
  qbo_bill_id     text,
  doc_number      text,
  amount          numeric not null default 0,
  services        numeric not null default 0,
  retention       numeric not null default 0,
  materials       numeric not null default 0,
  created_at      timestamptz not null default now(),
  created_by      uuid,
  primary key (professional_id, week)
);

alter table public.ops_cleaner_bills enable row level security;
drop policy if exists p_clbill_rec on public.ops_cleaner_bills;
create policy p_clbill_rec on public.ops_cleaner_bills
  for all to authenticated using (can_reconcile()) with check (can_reconcile());
grant all on public.ops_cleaner_bills to authenticated, service_role;

comment on table public.ops_cleaner_bills is
  'Bills de las facturas bisemanales de las cleaners que ya estan en QuickBooks.';

-- ============================================================
--  5) El mapeo, ya resuelto contra QuickBooks
-- ============================================================

-- Cleaners → proveedor. El nombre no calza solo: "Ana Polanco Garcia" en el app
-- es "Ana C. Polanco Garcia" en QuickBooks.
update public.professionals set qbo_vendor_id='479',       qbo_vendor_name='Ana C. Polanco Garcia'        where name='Ana Polanco Garcia';
update public.professionals set qbo_vendor_id='486',       qbo_vendor_name='Mayra Josefa Lespier Cruz'    where name='Mayra Lespier Cruz';
update public.professionals set qbo_vendor_id='477',       qbo_vendor_name='Ingrid Soveira Ortiz Rosario' where name in ('Ingrid S. Ortiz Rosario','Ingrid Ortiz');
update public.professionals set qbo_vendor_id='200000111', qbo_vendor_name='Marlie Velez'                 where name='Marlie Velez';
update public.professionals set qbo_vendor_id='200000301', qbo_vendor_name='Osvaldo Garcia Ortiz'         where name='Osvaldo Garcia';

-- Propiedades → clase de QuickBooks.
update public.properties set qbo_class_id='1000000012' where name='Andrew 306 - Atlantis Studio Loft';
update public.properties set qbo_class_id='1000000025' where name='Atabey Beach Haus';
update public.properties set qbo_class_id='1000000011' where name='Casa Amarilla LLC';
update public.properties set qbo_class_id='1000000006' where name='Cerra Modern Micro Loft';
update public.properties set qbo_class_id='1000000015' where name='Condominio Park Center Claire';
update public.properties set qbo_class_id='1000000010' where name='Coral Beach APT 1614 Stylish 1 Br';
update public.properties set qbo_class_id='1000000016' where name='Gabriel Geradino';
update public.properties set qbo_class_id='1000000023' where name='Ian Guaynabo';
update public.properties set qbo_class_id='1000000008' where name='Justin 401 - Atlantis Spacious Loft';
update public.properties set qbo_class_id='1000000007' where name='Lealtad Santurce Art District';
update public.properties set qbo_class_id='1000000013' where name='Marbella 506- Amazing Ocean View';
update public.properties set qbo_class_id='1000000018' where name='Monaco Garden Level Urban Enclave';
update public.properties set qbo_class_id='1000000017' where name='Oficina Hato Rey';
update public.properties set qbo_class_id='1000000005' where name='Salo 1st Floor';
update public.properties set qbo_class_id='1000000002' where name='Salo 2nd Floor';
update public.properties set qbo_class_id='1000000009' where name='Salo Casa Verde Whole House (Salo 1 & 2)';
update public.properties set qbo_class_id='1000000024' where name='Salo Corner Urban Stay';
update public.properties set qbo_class_id='1000000004' where name='Salo Studio';
update public.properties set qbo_class_id='1000000019' where name='Sandra Torres Condado';
update public.properties set qbo_class_id='1000000021' where name='Scott Meier Home';
update public.properties set qbo_class_id='1000000026' where name='Solara Pine & Tide';
update public.properties set qbo_class_id='1000000022' where name='Willy Bayamon';
update public.properties set qbo_class_id='1000000020' where name='Yasser Kahn Old SJ Apt';
-- ============================================================
--  FIN
-- ============================================================
