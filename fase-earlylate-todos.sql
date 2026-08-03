-- ============================================================
--  STAY HERE PR — Early/Late visibles para TODOS (no solo quien aprobó)
--  Reemplaza la política por-limpiadora por una de lectura para
--  todos los autenticados (igual que el calendario).
--  Pegar en: Supabase -> SQL Editor -> Run
-- ============================================================

drop policy if exists p_upsell_cleaner_own on ops_upsell_events;
drop policy if exists p_upsell_read_all    on ops_upsell_events;

create policy p_upsell_read_all on ops_upsell_events
  for select to authenticated using (true);

-- ============================================================
--  FIN — cualquier usuario logueado ve los early/late pagados.
-- ============================================================
