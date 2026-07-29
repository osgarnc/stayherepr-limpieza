-- ============================================================
--  STAY HERE PR — Recuperar tarifa base en servicios que subieron en $0
--  (por el bug donde no se guardaba rate_applied)
--  Pegar en: Supabase -> SQL Editor.
-- ============================================================

-- 1) PREVIEW (solo lectura) — qué items se corregirían y con qué monto:
select p.name as contratista, pr.name as propiedad, s.date, s.status,
       si.rate_applied as base_actual, r.amount as tarifa_correcta
from submission_items si
join submissions s   on s.id = si.submission_id
join professionals p on p.id = s.professional_id
join properties pr   on pr.id = si.property_id
join rates r on r.professional_id = s.professional_id and r.property_id = si.property_id
where s.type = 'service'
  and coalesce(si.rate_applied,0) = 0
  and coalesce(r.amount,0) > 0
order by s.date desc;

-- 2) BACKFILL — si el preview se ve bien, corre este UPDATE:
update submission_items si
set rate_applied = r.amount
from submissions s, rates r
where si.submission_id = s.id
  and s.type = 'service'
  and r.professional_id = s.professional_id
  and r.property_id = si.property_id
  and coalesce(si.rate_applied,0) = 0
  and coalesce(r.amount,0) > 0;

-- ============================================================
--  Nota: solo toca items con base 0 que TENGAN una tarifa
--  configurada. No inventa montos donde no hay tarifa.
-- ============================================================
