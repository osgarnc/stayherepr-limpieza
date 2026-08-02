-- ============================================================
--  STAY HERE PR — Cron del sync de reservas (Calendario)
--  Corre ops-sync-reservations cada hora (trae reservas de
--  Hostfully -> ops_reservations). Pegar en: SQL Editor -> Run.
--  Requisitos: haber corrido fase-ops-reservations.sql y
--  desplegado la Edge Function ops-sync-reservations.
-- ============================================================

create extension if not exists pg_cron;
create extension if not exists pg_net;

do $$ begin perform cron.unschedule('sync-reservations'); exception when others then null; end $$;

select cron.schedule(
  'sync-reservations',
  '0 * * * *',   -- cada hora en punto
  $$
  select net.http_post(
    url := 'https://dlrovaeubycsjzebmmgu.supabase.co/functions/v1/ops-sync-reservations',
    headers := jsonb_build_object('Content-Type','application/json'),
    body := '{}'::jsonb
  );
  $$
);

-- ============================================================
--  Nota: si configuras el secreto CRON_SECRET en la función,
--  añade el header 'x-cron-secret' con ese valor arriba.
--  Para probar YA (sin esperar la hora), invócala una vez desde
--  Supabase -> Edge Functions -> ops-sync-reservations -> Run.
-- ============================================================
