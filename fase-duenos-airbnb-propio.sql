-- ============================================================
--  DUEÑOS — propiedades donde la cuenta de Airbnb es de Stay Here
--
--  Por defecto el reporte de fin de mes NO cuadra comisión de las reservas de
--  Airbnb, porque Airbnb le paga al dueño directo (co-anfitrión) y a Stay Here
--  solo le manda su parte.
--
--  Pero hay dueños cuya cuenta de Airbnb es de Stay Here: ahí el dinero entra
--  completo a Stay Here y el reporte de fin de mes SÍ tiene que repartir esas
--  reservas (comisión de Stay Here + pago al dueño), igual que Booking o Vrbo.
-- ============================================================

alter table ops_property_owner
  add column if not exists airbnb_sh boolean not null default false;

comment on column ops_property_owner.airbnb_sh is
  'true = la cuenta de Airbnb de esta propiedad es de Stay Here: el dinero entra a Stay Here y el reporte reparte la reserva. false = Airbnb le paga al dueño directo.';
