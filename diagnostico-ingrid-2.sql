-- ============================================================
--  DIAGNÓSTICO 2 (solo lectura) — TODOS los envíos de Ingrid Ortiz
--  Sin filtro de fecha ni estado, para descartar que el detalle
--  grande quedó en otra fila. NO borra ni cambia nada.
-- ============================================================

select
  s.id, s.type, s.status, s.date, s.total, s.expense_desc,
  jsonb_array_length(coalesce(s.custom_lines->'lines','[]'::jsonb)) as num_renglones,
  (select count(*) from submission_items si where si.submission_id = s.id) as num_items,
  s.archived_at
from submissions s
join professionals p on p.id = s.professional_id
where p.name ilike 'Ingrid%'
order by s.total desc nulls last, s.date;

-- Suma total de todo lo que Ingrid tiene registrado hoy:
select coalesce(sum(s.total),0) as suma_total_ingrid
from submissions s
join professionals p on p.id = s.professional_id
where p.name ilike 'Ingrid%';
