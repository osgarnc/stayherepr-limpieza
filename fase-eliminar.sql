-- ============================================================
--  STAY HERE PR — Permitir ELIMINAR envíos y renglones (mgr)
--  Owner/Admin pueden borrar servicios, gastos y quitar propiedades.
--  Pegar en: Supabase -> SQL Editor -> Run
-- ============================================================

drop policy if exists p_sub_mgr_delete on submissions;
create policy p_sub_mgr_delete on submissions
  for delete using ( is_staff_mgr() );

drop policy if exists p_items_mgr_delete on submission_items;
create policy p_items_mgr_delete on submission_items
  for delete using ( is_staff_mgr() );

-- ============================================================
--  FIN
-- ============================================================
