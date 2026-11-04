-- Cuando se marca como pagado el estado de un dueño, los gastos que iban en esa
-- factura quedan LIQUIDADOS: dejan de salir en la lista de gastos para que no se
-- sigan acumulando, pero no se borran — el registro queda.
--
-- paid_month: el mes del estado en que se le cobraron ('YYYY-MM').
-- paid_at:    cuándo se marcó.
alter table public.ops_property_expenses
  add column if not exists paid_month text,
  add column if not exists paid_at     timestamptz;

comment on column public.ops_property_expenses.paid_month is
  'Mes YYYY-MM del estado de dueno en que se liquido este gasto. NULL = todavia pendiente.';

create index if not exists idx_prop_exp_paid on public.ops_property_expenses(paid_month);
