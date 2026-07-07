-- ============================================================
--  STAY HERE PR — FASE 2 (complemento de la Fase 1)
--  1) Datos de la empresa (a quién se factura)
--  2) Almacenamiento de fotos (Storage) + sus permisos
--  3) Ajuste de triggers: total de servicios calculado en servidor
--     y gastos que conservan su monto capturado
--  Pegar en: Supabase -> SQL Editor -> New query -> Run
--  (Requiere haber corrido antes fase1_stayherepr.sql)
-- ============================================================

-- ------------------------------------------------------------
-- 0. PERMISOS BASE PARA LA API (anon / authenticated)
--    La seguridad real la siguen dando las políticas RLS: estos GRANT
--    solo permiten que PostgREST "vea" las tablas; RLS filtra las filas.
--    (Normalmente Supabase los pone solo; aquí los aseguramos.)
-- ------------------------------------------------------------
grant usage on schema public to anon, authenticated;
grant all on all tables    in schema public to anon, authenticated;
grant all on all sequences in schema public to anon, authenticated;
grant all on all functions in schema public to anon, authenticated;
alter default privileges in schema public grant all on tables    to anon, authenticated;
alter default privileges in schema public grant all on sequences to anon, authenticated;
alter default privileges in schema public grant all on functions to anon, authenticated;

-- ------------------------------------------------------------
-- 1. DATOS DE LA EMPRESA (bill-to) — una sola fila
-- ------------------------------------------------------------
create table if not exists company_settings (
  id         int primary key default 1,
  name       text not null default 'Stay Here PR LLC',
  address    text,
  ein        text,
  email      text,
  phone      text,
  updated_at timestamptz not null default now(),
  constraint company_single_row check (id = 1)
);

insert into company_settings (id, name, address, ein, email, phone)
values (1,'Stay Here PR LLC','PO Box 1000, San Juan, PR 00901','66-1234567','admin@stayherepr.com','(787) 555-0100')
on conflict (id) do nothing;

alter table company_settings enable row level security;
drop policy if exists p_company_read  on company_settings;
drop policy if exists p_company_write on company_settings;
-- Cualquier usuario autenticado la lee (sale en la factura); solo mgr la edita
create policy p_company_read  on company_settings
  for select using ( auth.uid() is not null );
create policy p_company_write on company_settings
  for all using ( is_staff_mgr() ) with check ( is_staff_mgr() );


-- ------------------------------------------------------------
-- 2. ALMACENAMIENTO DE FOTOS (bucket privado "evidence")
--    Convención de ruta:  {professional_id}/{submission_id}/{archivo}
--    Así cada quien solo ve sus propias fotos; los mgr ven todas.
-- ------------------------------------------------------------
insert into storage.buckets (id, name, public)
values ('evidence','evidence', false)
on conflict (id) do nothing;

drop policy if exists p_ev_insert on storage.objects;
drop policy if exists p_ev_select on storage.objects;
drop policy if exists p_ev_delete on storage.objects;

-- Subir: mgr a cualquier carpeta; personal solo a la suya (1er nivel = su professional_id)
create policy p_ev_insert on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'evidence'
    and ( is_staff_mgr() or (storage.foldername(name))[1] = my_staff_id()::text )
  );

-- Leer: igual regla (bucket privado, siempre por URL firmada)
create policy p_ev_select on storage.objects
  for select to authenticated
  using (
    bucket_id = 'evidence'
    and ( is_staff_mgr() or (storage.foldername(name))[1] = my_staff_id()::text )
  );

-- Borrar: solo mgr (para liberar fotos después de archivar por correo)
create policy p_ev_delete on storage.objects
  for delete to authenticated
  using ( bucket_id = 'evidence' and is_staff_mgr() );


-- ------------------------------------------------------------
-- 3. TRIGGERS (reemplazan/complementan los de la Fase 1)
-- ------------------------------------------------------------

-- 3a. Al insertar un envío como personal (no mgr): forzar estado seguro.
--     OJO respecto a Fase 1: el 'total' solo se pone en 0 para SERVICIOS
--     (se acumula desde los renglones). Los GASTOS conservan el monto
--     capturado por la persona (queda 'pending' hasta que el mgr lo aprueba).
create or replace function enforce_submission_defaults()
returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not is_staff_mgr() then
    new.status      := 'pending';
    new.paid        := false;
    new.archived_at := null;
    new.invoice_pdf := null;
    new.report_pdf  := null;
    if new.type = 'service' then
      new.total := 0;   -- se acumula desde submission_items (ver 3c)
    end if;
  end if;
  return new;
end $$;

drop trigger if exists trg_submission_defaults on submissions;
create trigger trg_submission_defaults
  before insert on submissions
  for each row execute function enforce_submission_defaults();

-- 3b. Congelar la tarifa del renglón desde la tabla `rates` (para no mgr).
create or replace function freeze_item_rate()
returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_prof uuid;
begin
  if not is_staff_mgr() then
    select professional_id into v_prof from submissions where id = new.submission_id;
    select coalesce(amount, 0) into new.rate_applied
      from rates where professional_id = v_prof and property_id = new.property_id;
    new.rate_applied := coalesce(new.rate_applied, 0);
  end if;
  return new;
end $$;

drop trigger if exists trg_freeze_item_rate on submission_items;
create trigger trg_freeze_item_rate
  before insert on submission_items
  for each row execute function freeze_item_rate();

-- 3c. Mantener submissions.total = suma de los renglones (servicios).
create or replace function bump_submission_total()
returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_sub uuid := coalesce(new.submission_id, old.submission_id);
begin
  update submissions s
     set total = coalesce((select sum(rate_applied)
                             from submission_items
                            where submission_id = v_sub), 0)
   where s.id = v_sub and s.type = 'service';
  return coalesce(new, old);
end $$;

drop trigger if exists trg_bump_total on submission_items;
create trigger trg_bump_total
  after insert or update or delete on submission_items
  for each row execute function bump_submission_total();

-- ------------------------------------------------------------
-- 4. GUARDAR EL CORREO EN EL PERFIL (para la pantalla de Usuarios)
-- ------------------------------------------------------------
alter table profiles add column if not exists email text;

-- Rellenar los perfiles existentes con su correo de auth
update profiles p
   set email = u.email
  from auth.users u
 where u.id = p.id and p.email is null;

-- Actualizar el trigger de registro para que guarde el correo
create or replace function handle_new_user()
returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into profiles (id, display_name, email, role, active)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'display_name', new.email),
    new.email,
    'cleaner',
    false
  )
  on conflict (id) do nothing;
  return new;
end $$;

-- ============================================================
--  FIN — Fase 2 (base de datos lista para la app real).
-- ============================================================
