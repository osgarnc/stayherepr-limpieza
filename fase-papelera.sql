-- ============================================================
--  STAY HERE PR — Borrado suave (Papelera) para envíos
--  "Eliminar" ya no borra físico: marca deleted_at. Se puede
--  restaurar desde la Papelera. Evita pérdidas como la de Ingrid.
--  Pegar en: Supabase -> SQL Editor -> Run
-- ============================================================

alter table submissions
  add column if not exists deleted_at timestamptz;

create index if not exists idx_submissions_deleted_at on submissions (deleted_at);

-- ============================================================
--  FIN — mgr (owner/admin) ya puede UPDATE submissions, así que
--  marcar/restaurar deleted_at funciona con las políticas actuales.
-- ============================================================
