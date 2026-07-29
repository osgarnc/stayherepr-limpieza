-- ============================================================
--  STAY HERE PR — Medir almacenamiento (solo lectura, NO borra)
--  Bucket de evidencia (fotos/videos). Pegar en SQL Editor -> Run.
--  Corre las consultas una por una y pásame los resultados.
-- ============================================================

-- 1) TOTAL usado hoy y cuánto libre queda hasta 1 GB (plan gratuito)
select
  count(*)                                                   as archivos,
  pg_size_pretty(coalesce(sum((metadata->>'size')::bigint),0)) as usado,
  pg_size_pretty(1073741824 - coalesce(sum((metadata->>'size')::bigint),0)) as libre_hasta_1gb
from storage.objects
where bucket_id = 'evidence';

-- 2) CRECIMIENTO por mes (para ver el ritmo real)
select
  to_char(created_at,'YYYY-MM')                              as mes,
  count(*)                                                   as archivos,
  pg_size_pretty(coalesce(sum((metadata->>'size')::bigint),0)) as peso_del_mes
from storage.objects
where bucket_id = 'evidence'
group by 1
order by 1;

-- 3) FOTOS vs VIDEOS (los videos son los que pesan)
select
  case when metadata->>'mimetype' like 'video/%' then 'video' else 'imagen/otro' end as tipo,
  count(*)                                                   as archivos,
  pg_size_pretty(coalesce(sum((metadata->>'size')::bigint),0)) as peso
from storage.objects
where bucket_id = 'evidence'
group by 1
order by 2 desc;

-- 4) PROYECCIÓN — meses aprox. hasta llenar 1 GB, según el ritmo
--    (usa el promedio de TODO el historial y también el de los últimos 30 días)
with base as (
  select
    coalesce(sum((metadata->>'size')::bigint),0)                     as usado,
    min(created_at)                                                  as primero,
    max(created_at)                                                  as ultimo
  from storage.objects where bucket_id='evidence'
),
ult30 as (
  select coalesce(sum((metadata->>'size')::bigint),0) as bytes_30d
  from storage.objects
  where bucket_id='evidence' and created_at >= now() - interval '30 days'
)
select
  pg_size_pretty(usado)                                                          as usado,
  round(extract(epoch from (ultimo-primero))/86400.0, 1)                         as dias_con_datos,
  pg_size_pretty((usado / greatest(extract(epoch from (ultimo-primero))/86400.0,1))::bigint) as ritmo_por_dia_historico,
  round( (1073741824 - usado) / greatest( usado / greatest(extract(epoch from (ultimo-primero))/86400.0,1), 1) / 30.0, 1) as meses_restantes_historico,
  pg_size_pretty(ult30.bytes_30d)                                                as subido_ultimos_30d,
  round( (1073741824 - usado) / greatest(ult30.bytes_30d/30.0, 1) / 30.0, 1)     as meses_restantes_segun_ultimos_30d
from base, ult30;

-- 5) Los 15 archivos MÁS GRANDES (para saber si son videos)
select name,
       pg_size_pretty((metadata->>'size')::bigint) as peso,
       metadata->>'mimetype' as tipo,
       created_at
from storage.objects
where bucket_id='evidence'
order by (metadata->>'size')::bigint desc nulls last
limit 15;

-- ============================================================
--  FIN — todo solo lectura.
-- ============================================================
