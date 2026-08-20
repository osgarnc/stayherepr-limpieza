-- ============================================================
--  STAY HERE PR — Fotos en avisos de emergencia (bucket público)
--
--  La API de Hostfully NO permite adjuntar imágenes al enviar un mensaje
--  (POST /api/v3.2/messages solo acepta text + subject). Por eso las fotos
--  del aviso de emergencia se suben a este bucket PÚBLICO y viajan como
--  ENLACE al pie del mensaje. Nota: Airbnb suele bloquear enlaces.
--
--  Pegar en: Supabase → SQL Editor → Run
-- ============================================================

-- Bucket público (25MB, solo imágenes)
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('broadcast','broadcast',true,26214400,
        array['image/jpeg','image/png','image/webp','image/gif','image/heic'])
on conflict (id) do update
  set public = true,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- Lectura pública (para que el huésped abra el enlace) + subida por autenticados (el dueño).
drop policy if exists bcast_public_read on storage.objects;
create policy bcast_public_read on storage.objects
  for select to public using (bucket_id = 'broadcast');

drop policy if exists bcast_auth_insert on storage.objects;
create policy bcast_auth_insert on storage.objects
  for insert to authenticated with check (bucket_id = 'broadcast');

-- ============================================================
--  FIN
-- ============================================================
