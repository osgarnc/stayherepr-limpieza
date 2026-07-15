-- ============================================================
--  STAY HERE PR — Estado de facturación de los cargos de limpieza
--  Igual que los daños: pending / billed / closed, uno por cada cargo.
--  Pegar en: Supabase -> SQL Editor -> Run
-- ============================================================

alter table submission_items
  add column if not exists early_status text not null default 'pending',
  add column if not exists late_status  text not null default 'pending',
  add column if not exists guest_status text not null default 'pending';

alter table submission_items drop constraint if exists chk_early_status;
alter table submission_items drop constraint if exists chk_late_status;
alter table submission_items drop constraint if exists chk_guest_status;
alter table submission_items add constraint chk_early_status check (early_status in ('pending','billed','closed'));
alter table submission_items add constraint chk_late_status  check (late_status  in ('pending','billed','closed'));
alter table submission_items add constraint chk_guest_status check (guest_status in ('pending','billed','closed'));

-- ============================================================
--  FIN
-- ============================================================
