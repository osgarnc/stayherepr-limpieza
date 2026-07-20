-- ============================================================
--  DIAGNÓSTICO (solo lectura) — Factura de Ingrid Ortiz
--  Bisemana 12–25 de julio 2026. NO borra ni cambia nada.
--  Pegar en: Supabase -> SQL Editor -> Run
-- ============================================================

select
  s.id,
  s.type,
  s.status,
  s.date,
  s.total,
  s.expense_desc,
  s.custom_lines,                                   -- <— aquí estaría el detalle de los ~$8,000
  jsonb_array_length(coalesce(s.custom_lines->'lines','[]'::jsonb)) as num_renglones,
  (select count(*) from submission_items si where si.submission_id = s.id) as num_items
from submissions s
join professionals p on p.id = s.professional_id
where p.name ilike 'Ingrid%'
  and s.date between '2026-07-12' and '2026-07-25'
order by s.date, s.type;

-- ============================================================
--  Qué buscamos:
--   * Si alguna fila tiene "num_renglones" alto y "custom_lines"
--     con los detalles -> SE RECUPERA directo (sin backup).
--   * Si el detalle era por "num_items" (servicio) y ahora sale 0
--     o pocos -> se borraron renglones; ahí sí haría falta backup.
-- ============================================================
