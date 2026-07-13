-- ============================================================
--  STAY HERE PR — Varias fotos por reporte de daño
--  Permite documentar un daño significativo con múltiples fotos.
--  Pegar en: Supabase -> SQL Editor -> Run
-- ============================================================

-- Nueva columna: lista de rutas de fotos del daño (además de la vieja damage_photo)
alter table submission_items
  add column if not exists damage_photos text[] not null default '{}';

-- (Opcional) migrar la foto única existente a la lista, para registros viejos
update submission_items
   set damage_photos = array[damage_photo]
 where damage_photo is not null
   and (damage_photos is null or array_length(damage_photos,1) is null);

-- ============================================================
--  FIN — Daños con varias fotos.
-- ============================================================
