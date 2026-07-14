-- ============================================================
--  STAY HERE PR — Videos + Horario de envío configurable
--  Pegar en: Supabase -> SQL Editor -> Run
-- ============================================================

-- 1) Permitir VIDEOS en el bucket de evidencia
update storage.buckets
   set file_size_limit = 209715200,   -- 200 MB por archivo
       allowed_mime_types = null       -- imagen y video
 where id = 'evidence';

-- 2) Día y hora del envío automático (los configura el dueño en la app)
alter table company_settings
  add column if not exists send_dow  int not null default 0,   -- 0=domingo … 6=sábado
  add column if not exists send_hour int not null default 9;   -- hora PR (0-23)

-- 3) El cron ahora corre CADA HORA; la función decide si es el momento configurado
create extension if not exists pg_cron;
create extension if not exists pg_net;
do $$ begin perform cron.unschedule('facturas-bisemanales'); exception when others then null; end $$;
do $$ begin perform cron.unschedule('facturas-semanales');   exception when others then null; end $$;

select cron.schedule(
  'facturas-bisemanales',
  '0 * * * *',   -- cada hora en punto
  $$
  select net.http_post(
    url := 'https://dlrovaeubycsjzebmmgu.supabase.co/functions/v1/send-weekly-invoices',
    headers := jsonb_build_object('Content-Type','application/json'),
    body := '{}'::jsonb
  );
  $$
);

-- ============================================================
--  Recuerda: Project Settings -> Storage -> "Upload file size limit"
--  súbelo (ej. 200 MB) para videos grandes.
-- ============================================================
