-- ============================================================
--  CONTABILIDAD — la comisión REAL que cobra Booking.com
--
--  Hostfully calcula la comisión del canal como 15% de la renta + limpieza de
--  TODA la estadía. Booking solo cobra sobre SU reserva: si el huésped extendió
--  con noches que le vendimos nosotros, esas no llevan comisión de Booking y
--  Hostfully igual se la cobra al dueño.
--
--  Septiembre/2026: 15 de 16 reservas cuadran al centavo, pero en la de Elias
--  Aida (Solara, extendió del 28/09 al 02/10) Hostfully puso $88.29 cuando
--  Booking cobró $33.49. Al dueño se le descontaron $54.80 de más.
--
--  Con el Excel de "Reservations" de la extranet de Booking se usa el número
--  de ellos y se acabó la discusión. La llave es el número de reserva, así que
--  volver a subir el mismo archivo no duplica nada.
-- ============================================================

create table if not exists cont_booking_res (
  reservation_number text primary key,
  booker_name   text,
  guest_key     text,                    -- nombre normalizado, para ligar
  property_name text,                    -- como lo escribe Booking
  property_id   uuid references ops_properties(id) on delete set null,
  arrival       date,
  departure     date,
  booked_on     date,
  status        text,                    -- OK · Cancelled · No show
  total_payment numeric not null default 0,
  commission    numeric not null default 0,
  currency      text,
  upload_id     uuid references cont_uploads(id) on delete set null,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create index if not exists idx_cont_booking_res_liga
  on cont_booking_res(property_id, guest_key, arrival);

alter table cont_booking_res enable row level security;
drop policy if exists p_cont_booking_res on cont_booking_res;
create policy p_cont_booking_res on cont_booking_res for all to authenticated
  using (can_reconcile()) with check (can_reconcile());
grant all on cont_booking_res to authenticated, service_role;
