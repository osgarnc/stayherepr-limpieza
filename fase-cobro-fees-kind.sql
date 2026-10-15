-- Qué fue lo que se cobró en ese cargo ('nocheextra', 'earlyci', 'servicio'…).
-- Los cobros de la tienda que manda Stripe vienen SIN nombre de huésped, solo
-- con la propiedad en la descripción. Guardar el tipo permite distinguir la
-- NOCHE EXTRA (que es renta de la propiedad y su fee le toca al dueño) de los
-- extras de Stay Here (early check-in, late check-out), cuyo fee no sale de la
-- base del dueño.
alter table public.cont_cobro_fees
  add column if not exists kind text;

comment on column public.cont_cobro_fees.kind is
  'Tipo del cargo de la tienda: nocheextra, earlyci, extraguest, servicio. NULL = cobro de una reserva.';
