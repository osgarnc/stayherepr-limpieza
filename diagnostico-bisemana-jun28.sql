-- ============================================================
--  DIAGNÓSTICO (solo lectura) — Bisemana 28 jun – 11 jul 2026
--  Muestra el estado de cada envío de ese período. NO cambia nada.
-- ============================================================

select
  p.name                         as contratista,
  s.type,
  s.status,                      -- approved / pending / rejected
  s.paid,                        -- ¿marcada como pagada?
  s.date,
  s.total,
  s.expense_desc,
  s.archived_at,                 -- se llena cuando se envió por correo
  s.deleted_at                   -- si tiene valor, está en la Papelera
from submissions s
join professionals p on p.id = s.professional_id
where s.date between '2026-06-28' and '2026-07-11'
order by p.name, s.date;
