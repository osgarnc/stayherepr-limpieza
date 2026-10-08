-- ============================================================
--  DUEÑOS — la comisión que Booking factura aparte
--
--  Airbnb y Vrbo descuentan su comisión del payout, y por eso Hostfully la trae
--  en el reporte de dueños. Booking NO: el huésped nos paga completo (el merchant
--  de cobro somos nosotros) y Booking nos factura su comisión por tarjeta a fin
--  de mes. En el reporte de Hostfully esa columna sale en 0.
--
--  Resultado: hasta ahora Stay Here estaba absorbiendo esa comisión completa y
--  repartiendo la renta como si Booking no cobrara nada. Igual que con Airbnb,
--  la comisión se baja de la base ANTES de repartir, así que el dueño absorbe su
--  porcentaje.
--
--  La tasa estándar de Booking es 15% sobre renta + limpieza + extras (sin el
--  impuesto de turismo). Se guarda por propiedad porque puede cambiar con los
--  programas de Booking (Preferente, Genius).
-- ============================================================

alter table ops_property_owner
  add column if not exists booking_pct numeric not null default 15;

comment on column ops_property_owner.booking_pct is
  'Comisión que cobra Booking.com, en %, sobre renta + limpieza + extras. Se usa solo cuando el reporte de Hostfully trae la comisión del canal en 0, porque Booking la factura aparte. 0 = no estimar nada.';
