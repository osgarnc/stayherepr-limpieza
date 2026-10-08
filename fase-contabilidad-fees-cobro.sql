-- ============================================================
--  CONTABILIDAD — fee REAL de cada cobro (PayPal / Stripe)
--
--  El reporte de dueños de Hostfully trae una columna "Paypal Fee", pero viene
--  en 0 en muchas reservas (y siempre en las canceladas). El fee de verdad está
--  en el reporte de PayPal/Stripe: una fila por cobro, con su monto y su fee.
--
--  Importa porque en Booking, Vrbo y directo el merchant de cobro somos
--  NOSOTROS: ese fee lo paga Stay Here. En una reserva normal Hostfully ya lo
--  descuenta antes de repartir, pero cuando la reserva se cancela y se devuelve
--  el dinero, la plataforma NO devuelve su fee: hay que saber cuánto fue para
--  pasarle al dueño su parte.
--
--  La llave es el id de la transacción, así que volver a subir el mismo reporte
--  no duplica nada.
-- ============================================================

create table if not exists cont_cobro_fees (
  txn_id      text primary key,      -- Transaction ID de PayPal / balance txn de Stripe
  source      text not null,         -- paypal | stripe
  charge_date date,
  payer_name  text,                  -- quien pagó (puede no ser el huésped)
  guest_key   text,                  -- huésped de la reserva, ya ligado
  property_id uuid references ops_properties(id) on delete set null,
  check_in    date,
  gross       numeric not null default 0,
  fee         numeric not null default 0,
  created_at  timestamptz not null default now()
);
create index if not exists idx_cont_cobro_fees_reserva
  on cont_cobro_fees(property_id, guest_key, check_in);

alter table cont_cobro_fees enable row level security;
drop policy if exists p_cont_cobro_fees on cont_cobro_fees;
create policy p_cont_cobro_fees on cont_cobro_fees for all to authenticated
  using (can_reconcile()) with check (can_reconcile());
grant all on cont_cobro_fees to authenticated, service_role;
