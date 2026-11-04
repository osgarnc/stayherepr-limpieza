-- Foto del estado de dueño cuando se marca como PAGADO.
--
-- Por qué: un estado pagado tiene que poder reimprimirse igual años después,
-- aunque la data de atrás cambie. En noviembre de 2026 se borraron gastos de
-- septiembre y los estados de ese mes dejaron de reproducir lo que ya se había
-- pagado; con esta foto eso no vuelve a pasar.
--
-- `snapshot` guarda el bloque completo de la propiedad tal como salió del
-- reporte el día que se pagó: estadías, gastos, cancelaciones y totales.
create table if not exists public.ops_owner_statements (
  id            uuid primary key default gen_random_uuid(),
  property_id   uuid not null references public.ops_properties(id) on delete cascade,
  month         text not null,                      -- 'YYYY-MM'
  owner_id      uuid references public.ops_owners(id) on delete set null,
  payout        numeric not null default 0,         -- lo que se le pagó
  stays_net     numeric not null default 0,
  billable_expense numeric not null default 0,
  cancel_fee_owner numeric not null default 0,
  snapshot      jsonb,                              -- el estado completo, tal cual
  paid_at       timestamptz not null default now(),
  paid_by       uuid,
  unique (property_id, month)
);
create index if not exists idx_owner_stmt_month on public.ops_owner_statements(month);

alter table public.ops_owner_statements enable row level security;
drop policy if exists p_ownerstmt_rec on public.ops_owner_statements;
create policy p_ownerstmt_rec on public.ops_owner_statements
  for all to authenticated using (can_reconcile()) with check (can_reconcile());
grant all on public.ops_owner_statements to authenticated, service_role;

comment on table public.ops_owner_statements is
  'Estados de dueno ya pagados, con la foto del reporte del dia que se pagaron.';
