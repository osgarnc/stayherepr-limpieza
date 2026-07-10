-- ============================================================
--  STAY HERE PR — Cargo de LAVANDERÍA
--  Monto variable que coloca el PERSONAL en cada servicio
--  (no es un precio fijo global; lo escribe quien limpia).
--  Pegar en: Supabase -> SQL Editor -> Run
-- ============================================================

-- 1. Nuevo campo por renglón (monto que escribe el personal)
alter table submission_items
  add column if not exists laundry numeric(10,2) not null default 0;

-- 2. Incluir la lavandería en el total del servicio
create or replace function bump_submission_total()
returns trigger
language plpgsql security definer set search_path = public as $$
declare v_sub uuid := coalesce(new.submission_id, old.submission_id);
begin
  update submissions s
     set total = coalesce((select sum(rate_applied + early_checkin + late_checkout + extra_guest + laundry)
                             from submission_items
                            where submission_id = v_sub), 0)
   where s.id = v_sub and s.type = 'service';
  return coalesce(new, old);
end $$;

-- ============================================================
--  FIN — Lavandería lista.
--  (freeze_item_rate NO toca la lavandería: se respeta el monto
--   que escribe el personal, sujeto a tu aprobación.)
-- ============================================================
