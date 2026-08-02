-- ============================================================
--  STAY HERE PR — Calendario compartido (reservas de Hostfully)
--  Tabla que llena el sync desde la API de Hostfully. El app
--  Personal la lee para mostrar el calendario a TODOS (lectura
--  para autenticados). Marca early/late aprobados por reserva.
--  Pegar en: Supabase -> SQL Editor -> Run
-- ============================================================

create table if not exists ops_reservations (
  id uuid primary key default gen_random_uuid(),
  lead_uid text unique,                 -- identificador de la reserva en Hostfully
  property_id uuid references ops_properties(id),
  hostfully_property_uid text,
  property_name text,
  guest_name text,
  check_in date,
  check_out date,
  status text,                          -- p.ej. BOOKED / STAY / CANCELLED
  source text,                          -- canal (Airbnb, Booking, Direct…)
  early_checkin_approved boolean not null default false,
  late_checkout_approved boolean not null default false,
  updated_at timestamptz not null default now()
);

alter table ops_reservations enable row level security;

-- Lectura para TODOS los autenticados (calendario compartido: limpiadoras, admin, dueño)
drop policy if exists p_resv_read on ops_reservations;
create policy p_resv_read on ops_reservations for select to authenticated using (true);

-- Escritura solo del dueño desde la app (el sync escribe con service_role y salta RLS)
drop policy if exists p_resv_owner_write on ops_reservations;
create policy p_resv_owner_write on ops_reservations for all to authenticated
  using (is_owner()) with check (is_owner());

grant select on ops_reservations to anon, authenticated;
grant all on ops_reservations to service_role;

create index if not exists idx_resv_checkin  on ops_reservations(check_in);
create index if not exists idx_resv_checkout on ops_reservations(check_out);

-- ============================================================
--  FIN — el sync (Edge Function) hace UPSERT por lead_uid.
-- ============================================================
