-- ============================================================
--  STAY HERE PR — Cada limpiadora ve SUS early/late pagados
--  Política RLS: una limpiadora autenticada puede leer las filas
--  de ops_upsell_events que ella aprobó (approved_by_name = su
--  nombre de perfil). El dueño mantiene su acceso (is_owner()).
--  Pegar en: Supabase -> SQL Editor -> Run
-- ============================================================

drop policy if exists p_upsell_cleaner_own on ops_upsell_events;
create policy p_upsell_cleaner_own on ops_upsell_events
  for select to authenticated
  using (
    approved_by_name is not null
    and lower(trim(approved_by_name)) =
        lower(trim((select display_name from profiles where id = auth.uid())))
  );

-- ============================================================
--  IMPORTANTE: para que a una limpiadora le aparezcan sus early/late,
--  su NOMBRE en Back Office -> Usuarios (display_name) debe coincidir
--  con el nombre con que aprueba en Telegram (approved_by_name).
--  Si no le aparece nada, revisa que los nombres sean iguales.
-- ============================================================
