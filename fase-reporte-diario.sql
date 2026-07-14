-- ============================================================
--  STAY HERE PR — Reporte diario
--  El personal reporta cosas para administración (fotos + texto).
--  Estados: pending · partial (con nota de qué falta) · resolved
--  Pegar en: Supabase -> SQL Editor -> Run
-- ============================================================

create table if not exists daily_reports (
  id              uuid primary key default gen_random_uuid(),
  professional_id uuid not null references professionals(id) on delete cascade,
  date            date not null default current_date,
  description     text not null,
  photos          text[] not null default '{}',
  status          text not null default 'pending',
  pending_note    text,
  created_at      timestamptz not null default now(),
  constraint chk_dr_status check (status in ('pending','partial','resolved'))
);

alter table daily_reports enable row level security;

drop policy if exists p_dr_read   on daily_reports;
drop policy if exists p_dr_insert on daily_reports;
drop policy if exists p_dr_update on daily_reports;

-- Leer: el personal ve solo lo suyo; los mgr ven todo
create policy p_dr_read on daily_reports
  for select using ( is_staff_mgr() or professional_id = my_staff_id() );
-- Crear: el personal solo a su nombre
create policy p_dr_insert on daily_reports
  for insert with check ( professional_id = my_staff_id() or is_staff_mgr() );
-- Actualizar (estado / nota): solo mgr
create policy p_dr_update on daily_reports
  for update using ( is_staff_mgr() ) with check ( is_staff_mgr() );

-- Permisos base para la API (RLS controla las filas)
grant all on daily_reports to anon, authenticated, service_role;

-- ============================================================
--  FIN — Reporte diario listo.
-- ============================================================
