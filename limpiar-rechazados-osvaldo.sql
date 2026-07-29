-- ============================================================
--  STAY HERE PR — Borrar facturas RECHAZADAS del usuario de prueba
--  "Osvaldo Garcia" (para evitar confusiones futuras).
--  Pegar en: Supabase -> SQL Editor.
-- ============================================================

-- 1) VISTA PREVIA — corre esto solo para VER qué se borrará (no borra nada):
select s.id, s.type, s.date, s.total, s.status, p.name
from submissions s
join professionals p on p.id = s.professional_id
where p.name ilike 'Osvaldo Garcia'
  and s.status = 'rejected';

-- 2) BORRAR — si la vista previa se ve bien, corre estas dos instrucciones:
delete from submission_items
where submission_id in (
  select s.id
  from submissions s
  join professionals p on p.id = s.professional_id
  where p.name ilike 'Osvaldo Garcia'
    and s.status = 'rejected'
);

delete from submissions s
using professionals p
where p.id = s.professional_id
  and p.name ilike 'Osvaldo Garcia'
  and s.status = 'rejected';

-- ============================================================
--  FIN — solo toca envíos RECHAZADOS de "Osvaldo Garcia".
--  No afecta pendientes, aprobados, ni de otras personas.
-- ============================================================
