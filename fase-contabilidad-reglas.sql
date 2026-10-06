-- ============================================================
--  CONTABILIDAD — reglas que la app aprende + cuenta por renglón
--
--  Sept/2026: 17 payouts se quedaron trabados porque el motor no reconocía
--  cosas que no son reservas (compras por PayPal tipo Vistaprint, movimientos
--  internos) ni los cargos de la tienda sin nombre de huésped.
--
--  cont_rules: "si el texto trae X, trátalo así". Se crea una vez desde la
--  pantalla de pendientes y de ahí en adelante el motor lo hace solo.
--  cont_payout_lines.qbo_account_id: deja que un renglón apunte a CUALQUIER
--  cuenta de QuickBooks, no solo a las 18 llaves fijas de cont_qbo_account.
-- ============================================================

create table if not exists cont_rules (
  id uuid primary key default gen_random_uuid(),
  pattern text not null,                 -- texto que debe aparecer (sin mayúsculas ni acentos)
  kind text not null,                    -- tipo de renglón: gasto, servicio, prepago, reembolso…
  qbo_account_id text,                   -- cuenta de QuickBooks cuando el tipo no la define
  property_id uuid references ops_properties(id) on delete set null,
  note text,
  hits int not null default 0,           -- cuántas veces la ha usado el motor
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index if not exists idx_cont_rules_pattern on cont_rules(pattern);

alter table cont_payout_lines add column if not exists qbo_account_id text;

alter table cont_rules enable row level security;
drop policy if exists p_cont_rules on cont_rules;
create policy p_cont_rules on cont_rules for all to authenticated
  using (can_reconcile()) with check (can_reconcile());
grant all on cont_rules to authenticated, service_role;
