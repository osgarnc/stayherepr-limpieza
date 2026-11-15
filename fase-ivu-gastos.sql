-- ============================================================
--  IVU en los gastos de las limpiadoras
--
--  La limpiadora entra SOLO el gasto (el precio del artículo, como sale en el
--  recibo) y el app le calcula el IVU. Un recibo puede dividirse en varios
--  renglones: una foto, varios gastos, cada uno con su IVU.
--
--  `total` sigue siendo lo que se le reembolsa (gasto + IVU), así que todo lo
--  de atrás —facturas, bisemanas, bills de QuickBooks— no cambia.
-- ============================================================

alter table public.submissions
  add column if not exists amount_base numeric,
  add column if not exists ivu         numeric,
  add column if not exists ivu_rate    numeric;

comment on column public.submissions.amount_base is
  'El gasto sin IVU, tal como lo entro la limpiadora.';
comment on column public.submissions.ivu is
  'El IVU calculado sobre amount_base. total = amount_base + ivu.';
comment on column public.submissions.ivu_rate is
  'El por ciento que se uso, por si cambia la ley.';

-- El por ciento vive en ajustes, no en el código: 11.5% (10.5% estado + 1%
-- municipio). Se puede poner en 0 en un renglón exento.
alter table public.company_settings
  add column if not exists ivu_rate numeric not null default 11.5;

comment on column public.company_settings.ivu_rate is
  'IVU de Puerto Rico que el app le suma a los gastos de las limpiadoras.';
-- ============================================================
--  FIN
-- ============================================================
