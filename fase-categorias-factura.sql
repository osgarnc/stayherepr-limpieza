-- ============================================================
--  STAY HERE PR — Categorías para la factura libre
--  6 categorías por defecto viven en el código; las PERSONALIZADAS
--  que el dueño añada se guardan aquí y sirven para cualquier factura futura.
--  Pegar en: Supabase → SQL Editor → Run
-- ============================================================

create table if not exists invoice_categories (
  id         uuid primary key default gen_random_uuid(),
  name       text not null unique,
  created_at timestamptz default now()
);
alter table invoice_categories enable row level security;

drop policy if exists p_invcat_read on invoice_categories;
create policy p_invcat_read on invoice_categories
  for select to authenticated using (true);

drop policy if exists p_invcat_write on invoice_categories;
create policy p_invcat_write on invoice_categories
  for all to authenticated using (is_owner()) with check (is_owner());

grant select, insert, delete on invoice_categories to authenticated;

-- ============================================================
--  FIN
-- ============================================================
