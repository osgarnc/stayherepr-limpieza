-- ============================================================
--  STAY HERE PR — Reconciliación de dueños (Fase 1: datos + acceso)
-- ============================================================

-- 1) Dueños de propiedad
create table if not exists ops_owners (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  email text,
  phone text,
  notes text,
  created_at timestamptz not null default now()
);

-- 2) Asignación dueño + % comisión por propiedad (tabla puente, no toca ops_properties)
create table if not exists ops_property_owner (
  property_id uuid primary key references ops_properties(id) on delete cascade,
  owner_id uuid references ops_owners(id) on delete set null,
  commission_pct numeric,          -- % de la RENTA que retiene Stay Here
  updated_at timestamptz not null default now()
);

-- 3) Gastos por propiedad
create table if not exists ops_property_expenses (
  id uuid primary key default gen_random_uuid(),
  property_id uuid references ops_properties(id) on delete cascade,
  date date not null,
  description text not null,
  amount numeric not null default 0,
  billable boolean not null default true,   -- facturable al dueño (sí/no)
  receipt_url text,
  created_by uuid,
  created_at timestamptz not null default now()
);
create index if not exists idx_prop_exp_prop on ops_property_expenses(property_id);
create index if not exists idx_prop_exp_date on ops_property_expenses(date);

-- 4) Permiso de reconciliación por usuario
alter table profiles add column if not exists can_reconcile boolean not null default false;

-- 5) Helper: ¿el usuario actual tiene acceso a reconciliación?
create or replace function can_reconcile() returns boolean
  language sql stable security definer set search_path = public as $$
  select coalesce((select can_reconcile from profiles where id = auth.uid()), false);
$$;

-- 6) RLS: solo usuarios con can_reconcile() acceden a estas tablas
alter table ops_owners enable row level security;
alter table ops_property_owner enable row level security;
alter table ops_property_expenses enable row level security;

drop policy if exists p_owners_rec on ops_owners;
create policy p_owners_rec on ops_owners for all to authenticated using (can_reconcile()) with check (can_reconcile());
drop policy if exists p_propowner_rec on ops_property_owner;
create policy p_propowner_rec on ops_property_owner for all to authenticated using (can_reconcile()) with check (can_reconcile());
drop policy if exists p_propexp_rec on ops_property_expenses;
create policy p_propexp_rec on ops_property_expenses for all to authenticated using (can_reconcile()) with check (can_reconcile());

grant all on ops_owners, ops_property_owner, ops_property_expenses to authenticated, service_role;
-- ============================================================
--  FIN
-- ============================================================

-- ============================================================
--  FASE 4 — Completar el reporte (reservas de canal + cancelaciones)
-- ============================================================

-- 1) LEDGER DURABLE de reservas: lo llena el webhook/cron (syncReservationLead)
--    y NUNCA se purga. El reporte de fin de mes lo une con /leads de Hostfully
--    para no perder reservas de canal iCal (Booking.com) que ya hicieron
--    check-out (ops_reservations sí se purga; /leads no las devuelve).
create table if not exists ops_reservations_ledger (
  lead_uid    text primary key,
  property_id uuid references ops_properties(id),
  guest_name  text,
  source      text,
  check_in    date,
  check_out   date,
  first_seen  timestamptz default now(),
  updated_at  timestamptz default now()
);
create index if not exists idx_rled_checkin on ops_reservations_ledger(check_in);
alter table ops_reservations_ledger enable row level security;
drop policy if exists p_rled_rec on ops_reservations_ledger;
create policy p_rled_rec on ops_reservations_ledger
  for select to authenticated using (can_reconcile());
grant select on ops_reservations_ledger to service_role, authenticated;

-- Backfill inicial desde las reservas vivas actuales.
insert into ops_reservations_ledger(lead_uid,property_id,guest_name,source,check_in,check_out,updated_at)
  select lead_uid,property_id,guest_name,source,check_in,check_out,now() from ops_reservations
  on conflict (lead_uid) do update set guest_name=excluded.guest_name, source=excluded.source,
    check_in=excluded.check_in, check_out=excluded.check_out, updated_at=now();

-- 2) CANCELACIONES: las registra ops-sync-reservations al detectar que un lead
--    ya no está BOOKED, ANTES de borrarlo de ops_reservations.
create table if not exists ops_cancellations (
  id          uuid primary key default gen_random_uuid(),
  lead_uid    text,
  property_id uuid references ops_properties(id),
  guest_name  text,
  source      text,
  check_in    date,
  check_out   date,
  status      text,
  cancelled_at timestamptz default now()
);
create index if not exists idx_canc_checkin on ops_cancellations(check_in);
alter table ops_cancellations enable row level security;
drop policy if exists p_cancel_rec on ops_cancellations;
create policy p_cancel_rec on ops_cancellations
  for select to authenticated using (can_reconcile());
grant select on ops_cancellations to service_role, authenticated;

-- ============================================================
--  FIN Fase 4
-- ============================================================

-- Lectura del ledger para mostrar la ESTADÍA (check-in/out) del huésped en el
-- histórico de Early/Late (back office). Mismo tipo de dato que ops_reservations
-- (que ya es legible por todos los autenticados) pero durable (no se purga).
drop policy if exists p_rled_read on ops_reservations_ledger;
create policy p_rled_read on ops_reservations_ledger
  for select to authenticated using (true);
