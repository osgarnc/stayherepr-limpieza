-- ============================================================
--  STAY HERE PR — Factura libre (del dueño, va a la bandeja)
--  Se guarda como un envío tipo 'expense' con renglones libres.
--  Pegar en: Supabase -> SQL Editor -> Run
-- ============================================================

alter table submissions
  add column if not exists custom_lines jsonb;

-- ============================================================
--  FIN
-- ============================================================
