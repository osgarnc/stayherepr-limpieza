-- Hasta qué mes se le pagó ya a este dueño por esta propiedad ('YYYY-MM').
-- El reporte NO toca los meses hasta esa fecha: se quedan exactamente como se
-- pagaron. De ahí en adelante sí aplica las correcciones (noche extra por lo
-- que de verdad se cobró, fees de la tienda que no le tocan al dueño, ajustes
-- de renta de Hostfully).
--
-- NULL = usar el corte general del reporte (2026-09, o sea que se corrige de
-- octubre en adelante).
alter table public.ops_property_owner
  add column if not exists pagado_hasta text;

comment on column public.ops_property_owner.pagado_hasta is
  'Ultimo mes YYYY-MM ya pagado al dueno. El reporte no recalcula hasta ahi. NULL = corte general.';

-- Solara Pine & Tide todavía no se le ha pagado septiembre, así que ese mes sí
-- se corrige.
update public.ops_property_owner po
   set pagado_hasta = '2026-08'
  from public.ops_properties p
 where p.id = po.property_id
   and p.name ilike 'Solara%';
