-- ============================================================
--  STAY HERE PR — Retención 10% configurable por persona
--  En PR los servicios están exentos de retención los primeros
--  $500 del año natural. Este switch permite activar/desactivar
--  la retención de cada contratista.
--  Pegar en: Supabase -> SQL Editor -> Run
-- ============================================================

alter table professionals
  add column if not exists withhold_tax boolean not null default true;

-- Este año excluimos a Ana y a Mayra (ya empezado el año, cubiertos por los primeros $500).
-- Coincide por el PRIMER nombre para no afectar a otros. Verifícalo luego en Perfiles.
update professionals
   set withhold_tax = false
 where lower(split_part(name, ' ', 1)) in ('ana', 'mayra');

-- ============================================================
--  FIN — las demás quedan con retención activada (la controlas
--  con el switch "Retener 10%" en cada perfil).
-- ============================================================
