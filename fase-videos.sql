-- ============================================================
--  STAY HERE PR — Permitir VIDEOS en el almacenamiento
--  Sube el límite de tamaño del bucket "evidence" y permite
--  cualquier tipo de archivo (imagen y video).
--  Pegar en: Supabase -> SQL Editor -> Run
-- ============================================================

update storage.buckets
   set file_size_limit   = 209715200,  -- 200 MB por archivo
       allowed_mime_types = null        -- acepta imagen y video
 where id = 'evidence';

-- ============================================================
--  IMPORTANTE (además del SQL):
--  Revisa el límite GLOBAL de subida del proyecto en:
--    Supabase -> Project Settings -> Storage -> "Upload file size limit"
--  Súbelo (ej. a 200 MB) si está más bajo, o los videos grandes fallarán.
--  Recomendación: pide videos cortos (10-20 seg) para que suban rápido.
-- ============================================================
