-- ============================================================
--  STAY HERE PR — Estado de facturación del daño
--  Independiente de la aprobación del servicio.
--  pending = pendiente a facturar · billed = facturado · closed = no se facturará
--  Pegar en: Supabase -> SQL Editor -> Run
-- ============================================================

alter table submission_items
  add column if not exists damage_status text not null default 'pending';

alter table submission_items drop constraint if exists chk_damage_status;
alter table submission_items
  add constraint chk_damage_status check (damage_status in ('pending','billed','closed'));

-- ============================================================
--  FIN
-- ============================================================
