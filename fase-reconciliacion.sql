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
