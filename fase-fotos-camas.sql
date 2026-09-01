-- ============================================================
--  STAY HERE PR — Foto(s) de cama(s) arreglada(s) en el servicio del personal
--  Reemplaza el requisito de fotos "Antes/Después" por foto(s) de la(s) cama(s).
--  Se guardan como arreglo en submission_items.bed_photos.
--  Pegar en: Supabase → SQL Editor → Run
-- ============================================================
alter table submission_items add column if not exists bed_photos text[];
-- ============================================================
