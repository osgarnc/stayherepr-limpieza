-- ============================================================
--  STAY HERE PR — Cargos adicionales
--  Early Check-in, Late Check-out, Extra huésped
--  · Montos GLOBALES (configura el dueño en el back office)
--  · El personal solo marca sí/no por propiedad
--  Pegar en: Supabase -> SQL Editor -> Run
-- ============================================================

-- 1. Montos globales (una sola fila, en company_settings)
alter table company_settings
  add column if not exists fee_early_checkin numeric(10,2) not null default 0,
  add column if not exists fee_late_checkout numeric(10,2) not null default 0,
  add column if not exists fee_extra_guest   numeric(10,2) not null default 0;

-- 2. Cada renglón guarda el monto congelado de cada cargo (0 si no aplicó)
alter table submission_items
  add column if not exists early_checkin numeric(10,2) not null default 0,
  add column if not exists late_checkout numeric(10,2) not null default 0,
  add column if not exists extra_guest   numeric(10,2) not null default 0;

-- 3. Al insertar como personal: congelar tarifa base + cargos desde el servidor.
--    El personal solo "marca" (manda monto > 0); el servidor pone el monto global real.
create or replace function freeze_item_rate()
returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_prof uuid; v_ec numeric; v_lc numeric; v_eg numeric;
begin
  if not is_staff_mgr() then
    select professional_id into v_prof from submissions where id = new.submission_id;

    select coalesce(amount, 0) into new.rate_applied
      from rates where professional_id = v_prof and property_id = new.property_id;
    new.rate_applied := coalesce(new.rate_applied, 0);

    select coalesce(fee_early_checkin,0), coalesce(fee_late_checkout,0), coalesce(fee_extra_guest,0)
      into v_ec, v_lc, v_eg from company_settings where id = 1;

    new.early_checkin := case when coalesce(new.early_checkin,0) > 0 then v_ec else 0 end;
    new.late_checkout := case when coalesce(new.late_checkout,0) > 0 then v_lc else 0 end;
    new.extra_guest   := case when coalesce(new.extra_guest,0)   > 0 then v_eg else 0 end;
  end if;
  return new;
end $$;

-- 4. El total del servicio = suma de (tarifa base + los 3 cargos) de cada renglón
create or replace function bump_submission_total()
returns trigger
language plpgsql security definer set search_path = public as $$
declare v_sub uuid := coalesce(new.submission_id, old.submission_id);
begin
  update submissions s
     set total = coalesce((select sum(rate_applied + early_checkin + late_checkout + extra_guest)
                             from submission_items
                            where submission_id = v_sub), 0)
   where s.id = v_sub and s.type = 'service';
  return coalesce(new, old);
end $$;

-- ============================================================
--  FIN — Cargos adicionales listos.
-- ============================================================
