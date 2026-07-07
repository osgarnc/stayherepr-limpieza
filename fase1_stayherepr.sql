-- ============================================================
--  STAY HERE PR — App de Servicios de Limpieza
--  FASE 1 — Estructura de datos + Seguridad por roles (RLS)
--  (versión corregida: cierra los huecos de auto-aprobación
--   y de falsificación de auditoría)
--  Pegar en: Supabase -> SQL Editor -> New query -> Run
-- ============================================================
--  Roles: 'owner' (dueño), 'admin' (administradora), 'cleaner' (personal)
-- ============================================================

-- ---------- 0. Tipos (enums) ----------
do $$ begin
  create type user_role      as enum ('owner','admin','cleaner');
exception when duplicate_object then null; end $$;

do $$ begin
  create type submission_type as enum ('service','expense');
exception when duplicate_object then null; end $$;

do $$ begin
  create type submission_status as enum ('pending','approved','rejected');
exception when duplicate_object then null; end $$;


-- ============================================================
--  1. TABLAS
-- ============================================================

-- Perfiles de usuario. Se enlaza 1-a-1 con auth.users (el login real).
create table if not exists profiles (
  id           uuid primary key references auth.users(id) on delete cascade,
  display_name text not null,
  role         user_role not null default 'cleaner',
  staff_id     uuid,                    -- se enlaza a professionals (solo cleaners)
  active       boolean not null default true,
  created_at   timestamptz not null default now()
);

-- Profesionales (el EMISOR de la factura). Datos que salen en la factura.
create table if not exists professionals (
  id         uuid primary key default gen_random_uuid(),
  name       text not null,
  address    text,
  phone      text,
  tax_id     text,
  email      text,
  active     boolean not null default true,
  created_at timestamptz not null default now()
);

-- Enlazamos profiles.staff_id -> professionals.id
alter table profiles
  drop constraint if exists profiles_staff_fk;
alter table profiles
  add constraint profiles_staff_fk
  foreign key (staff_id) references professionals(id) on delete set null;

-- Propiedades (los Airbnb administrados)
create table if not exists properties (
  id         uuid primary key default gen_random_uuid(),
  name       text not null,
  address    text,
  active     boolean not null default true,
  created_at timestamptz not null default now()
);

-- Tarifas negociadas: independientes por persona + propiedad
create table if not exists rates (
  id              uuid primary key default gen_random_uuid(),
  professional_id uuid not null references professionals(id) on delete cascade,
  property_id     uuid not null references properties(id)     on delete cascade,
  amount          numeric(10,2) not null default 0,
  unique (professional_id, property_id)
);

-- Envíos: un servicio (con varias propiedades) o un gasto
create table if not exists submissions (
  id              uuid primary key default gen_random_uuid(),
  type            submission_type   not null,
  professional_id uuid not null references professionals(id) on delete cascade,
  date            date not null default current_date,
  status          submission_status not null default 'pending',
  total           numeric(10,2) not null default 0,   -- calculado en el servidor
  paid            boolean not null default false,
  -- solo para gastos:
  expense_desc    text,
  property_id     uuid references properties(id),
  receipt_photo   text,
  -- archivo por correo:
  archived_at     timestamptz,
  invoice_pdf     text,
  report_pdf      text,
  created_at      timestamptz not null default now()
);

-- Renglones de un servicio: una fila por propiedad limpiada
create table if not exists submission_items (
  id             uuid primary key default gen_random_uuid(),
  submission_id  uuid not null references submissions(id) on delete cascade,
  property_id    uuid not null references properties(id),
  rate_applied   numeric(10,2) not null default 0,   -- tarifa congelada
  photo_before   text,
  photo_after    text,
  damage_note    text,
  damage_photo   text,
  photos_deleted boolean not null default false
);

-- Lista de distribución de correos (envío semanal)
create table if not exists distribution (
  id         uuid primary key default gen_random_uuid(),
  label      text,
  email      text not null unique,
  active     boolean not null default true,
  created_at timestamptz not null default now()
);

-- Bitácora de auditoría (quién hizo qué)
create table if not exists audit_log (
  id         uuid primary key default gen_random_uuid(),
  actor      uuid references auth.users(id),
  action     text not null,
  detail     text,
  created_at timestamptz not null default now()
);


-- ============================================================
--  2. FUNCIONES DE APOYO (para las reglas de seguridad)
-- ============================================================

-- Rol del usuario actual
create or replace function current_role_name()
returns user_role
language sql stable security definer set search_path = public as $$
  select role from profiles where id = auth.uid();
$$;

-- ¿El usuario actual es owner o admin? (puede ver el back office)
create or replace function is_staff_mgr()
returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from profiles
    where id = auth.uid() and role in ('owner','admin') and active
  );
$$;

-- ¿El usuario actual es owner?
create or replace function is_owner()
returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from profiles
    where id = auth.uid() and role = 'owner' and active
  );
$$;

-- El professional_id (staff) vinculado al usuario actual
create or replace function my_staff_id()
returns uuid
language sql stable security definer set search_path = public as $$
  select staff_id from profiles where id = auth.uid();
$$;


-- ============================================================
--  3. ACTIVAR ROW LEVEL SECURITY (RLS) EN TODAS LAS TABLAS
-- ============================================================
alter table profiles          enable row level security;
alter table professionals     enable row level security;
alter table properties        enable row level security;
alter table rates             enable row level security;
alter table submissions       enable row level security;
alter table submission_items  enable row level security;
alter table distribution      enable row level security;
alter table audit_log         enable row level security;


-- ============================================================
--  4. POLÍTICAS DE ACCESO
-- ============================================================

-- ---- PROFILES ----
drop policy if exists p_profiles_self_read   on profiles;
drop policy if exists p_profiles_mgr_read    on profiles;
drop policy if exists p_profiles_owner_write on profiles;

create policy p_profiles_self_read on profiles
  for select using ( id = auth.uid() );
create policy p_profiles_mgr_read on profiles
  for select using ( is_staff_mgr() );
create policy p_profiles_owner_write on profiles
  for all using ( is_owner() ) with check ( is_owner() );

-- ---- PROFESSIONALS ----
drop policy if exists p_prof_read      on professionals;
drop policy if exists p_prof_mgr_write on professionals;

create policy p_prof_read on professionals
  for select using ( is_staff_mgr() or id = my_staff_id() );
create policy p_prof_mgr_write on professionals
  for all using ( is_staff_mgr() ) with check ( is_staff_mgr() );

-- ---- PROPERTIES ----
drop policy if exists p_props_read      on properties;
drop policy if exists p_props_mgr_write on properties;

create policy p_props_read on properties
  for select using ( auth.uid() is not null );
create policy p_props_mgr_write on properties
  for all using ( is_staff_mgr() ) with check ( is_staff_mgr() );

-- ---- RATES ----
drop policy if exists p_rates_read      on rates;
drop policy if exists p_rates_mgr_write on rates;

create policy p_rates_read on rates
  for select using ( is_staff_mgr() or professional_id = my_staff_id() );
create policy p_rates_mgr_write on rates
  for all using ( is_staff_mgr() ) with check ( is_staff_mgr() );

-- ---- SUBMISSIONS ----
drop policy if exists p_sub_read        on submissions;
drop policy if exists p_sub_insert_self on submissions;
drop policy if exists p_sub_mgr_update  on submissions;

-- Leer: mgr ve todo; personal ve solo lo suyo
create policy p_sub_read on submissions
  for select using ( is_staff_mgr() or professional_id = my_staff_id() );
-- Crear: el personal solo puede crear envíos a su propio nombre
create policy p_sub_insert_self on submissions
  for insert with check (
    professional_id = my_staff_id() or is_staff_mgr()
  );
-- Aprobar/rechazar/pagar/archivar: solo mgr
create policy p_sub_mgr_update on submissions
  for update using ( is_staff_mgr() ) with check ( is_staff_mgr() );

-- FIX #1: forzar valores seguros cuando el que inserta NO es mgr.
-- Evita que un cleaner se auto-apruebe, se auto-pague o ponga un total inventado.
create or replace function enforce_submission_defaults()
returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not is_staff_mgr() then
    new.status      := 'pending';
    new.paid        := false;
    new.total       := 0;          -- el total real lo recalcula el mgr al aprobar
    new.archived_at := null;
    new.invoice_pdf := null;
    new.report_pdf  := null;
  end if;
  return new;
end $$;

drop trigger if exists trg_submission_defaults on submissions;
create trigger trg_submission_defaults
  before insert on submissions
  for each row execute function enforce_submission_defaults();

-- ---- SUBMISSION_ITEMS ----
drop policy if exists p_items_read        on submission_items;
drop policy if exists p_items_insert_self on submission_items;
drop policy if exists p_items_mgr_update  on submission_items;

create policy p_items_read on submission_items
  for select using (
    is_staff_mgr() or exists (
      select 1 from submissions s
      where s.id = submission_id and s.professional_id = my_staff_id()
    )
  );
create policy p_items_insert_self on submission_items
  for insert with check (
    is_staff_mgr() or exists (
      select 1 from submissions s
      where s.id = submission_id and s.professional_id = my_staff_id()
    )
  );
create policy p_items_mgr_update on submission_items
  for update using ( is_staff_mgr() ) with check ( is_staff_mgr() );

-- FIX #1b: congelar la tarifa desde la tabla `rates` para inserciones de cleaner,
-- en vez de confiar en el valor que manda el cliente.
create or replace function freeze_item_rate()
returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_prof uuid;
begin
  if not is_staff_mgr() then
    select professional_id into v_prof
      from submissions where id = new.submission_id;

    select coalesce(amount, 0) into new.rate_applied
      from rates
      where professional_id = v_prof and property_id = new.property_id;

    new.rate_applied := coalesce(new.rate_applied, 0);
  end if;
  return new;
end $$;

drop trigger if exists trg_freeze_item_rate on submission_items;
create trigger trg_freeze_item_rate
  before insert on submission_items
  for each row execute function freeze_item_rate();

-- ---- DISTRIBUTION ----
drop policy if exists p_dist_read      on distribution;
drop policy if exists p_dist_mgr_write on distribution;

create policy p_dist_read on distribution
  for select using ( is_staff_mgr() );
create policy p_dist_mgr_write on distribution
  for all using ( is_staff_mgr() ) with check ( is_staff_mgr() );

-- ---- AUDIT_LOG ----
drop policy if exists p_audit_read   on audit_log;
drop policy if exists p_audit_insert on audit_log;

create policy p_audit_read on audit_log
  for select using ( is_staff_mgr() );
-- FIX #2: el actor debe ser el propio usuario; no se puede falsificar a nombre de otro.
create policy p_audit_insert on audit_log
  for insert with check ( actor = auth.uid() );


-- ============================================================
--  5. AUTO-CREAR PERFIL AL REGISTRAR UN USUARIO
--  Entra como 'cleaner' e inactivo hasta que el owner lo active.
-- ============================================================
create or replace function handle_new_user()
returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into profiles (id, display_name, role, active)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'display_name', new.email),
    'cleaner',
    false
  )
  on conflict (id) do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function handle_new_user();


-- ============================================================
--  6. DATOS DE PRUEBA (propiedades, personal y tarifas)
--  Puedes borrar esta sección cuando metas tus datos reales.
-- ============================================================

insert into properties (id, name, address) values
  ('11111111-1111-1111-1111-111111111111','Casa Coral — Ponce','Ponce, PR'),
  ('22222222-2222-2222-2222-222222222222','Villa Marlin — Rincón','Rincón, PR'),
  ('33333333-3333-3333-3333-333333333333','Loft Viejo San Juan','San Juan, PR'),
  ('44444444-4444-4444-4444-444444444444','Apto. Isla Verde 4B','Carolina, PR')
on conflict (id) do nothing;

insert into professionals (id, name, address, phone, tax_id, email) values
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','María Rivera','Calle Sol 12, Ponce, PR 00730','(787) 555-0142','123-45-6789','maria.rivera@email.com'),
  ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb','José Colón','Ave. Hostos 8, Mayagüez, PR 00680','(787) 555-0198','987-65-4321','jose.colon@email.com')
on conflict (id) do nothing;

insert into rates (professional_id, property_id, amount) values
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','11111111-1111-1111-1111-111111111111',45),
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','22222222-2222-2222-2222-222222222222',55),
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','33333333-3333-3333-3333-333333333333',50),
  ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','44444444-4444-4444-4444-444444444444',40),
  ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb','11111111-1111-1111-1111-111111111111',42),
  ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb','22222222-2222-2222-2222-222222222222',52),
  ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb','33333333-3333-3333-3333-333333333333',48),
  ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb','44444444-4444-4444-4444-444444444444',38)
on conflict (professional_id, property_id) do nothing;

insert into distribution (label, email, active) values
  ('Administradora','admin@stayherepr.com', true),
  ('Osval (Dueño)','osval@stayherepr.com', true)
on conflict (email) do nothing;

-- ============================================================
--  FIN — Fase 1 lista (corregida).
-- ============================================================
