-- ============================================================
--  Website: propiedades para stayherepr.com + ocupación editable
--  Lectura PÚBLICA (el website la lee con la anon key).
--  Escritura solo managers (is_staff_mgr()).
-- ============================================================
create table if not exists website_properties (
  uid           text primary key,                 -- uid de la propiedad en Hostfully
  name          text not null,
  sort          int  not null default 0,          -- orden de aparición
  max_occupancy int  not null,                     -- OCUPACIÓN que muestra el website (editable)
  hostfully_max int,                               -- referencia: máximo según Hostfully
  price         numeric(10,2),
  bedrooms      int,
  bathrooms     int,
  beds          int,
  rating        numeric(3,1),
  reviews       int,
  min_stay      int,
  city          text,
  web_path      text,                              -- ruta de reserva (se antepone book URL)
  active        boolean not null default true,     -- mostrar u ocultar en el website
  updated_at    timestamptz not null default now()
);

alter table website_properties enable row level security;

drop policy if exists p_webprops_public_read on website_properties;
create policy p_webprops_public_read on website_properties
  for select using ( true );                       -- cualquiera (incluye el website anónimo)

drop policy if exists p_webprops_mgr_insert on website_properties;
create policy p_webprops_mgr_insert on website_properties
  for insert with check ( is_staff_mgr() );

drop policy if exists p_webprops_mgr_update on website_properties;
create policy p_webprops_mgr_update on website_properties
  for update using ( is_staff_mgr() ) with check ( is_staff_mgr() );

-- Semilla con tus 12 propiedades (max_occupancy = valor de Hostfully; edítalo en la app)
insert into website_properties
  (uid, name, sort, max_occupancy, hostfully_max, price, bedrooms, bathrooms, beds, rating, reviews, min_stay, city, web_path, active)
values
  ('61455cf8-55ed-451d-85cd-257011b2aa40','Amazing Ocean View Apt · Marbella del Caribe',1,6,6,286,2,2,2,4.8,0,3,'Carolina','/property-details/61455cf8-55ed-451d-85cd-257011b2aa40/amazing-ocean-view-apt-marbella-del-caribe-',true),
  ('88f3be63-b938-4905-9bdd-388e23bf413b','Atlantis Loft Studio',2,4,4,159,1,1,2,4.8,0,1,'San Juan','/property-details/88f3be63-b938-4905-9bdd-388e23bf413b/atlantis-loft-studio-by-stay-here-pr',true),
  ('83601cda-b5d8-4801-ba68-1889628d5519','Casa Amarilla',3,4,4,165,1,1,1,4.8,6,1,'San Juan','/property-details/83601cda-b5d8-4801-ba68-1889628d5519/casita-amarilla-by-stay-here-pr',true),
  ('2031e442-e5f8-4eb0-94bf-d9185675dfd6','Lealtad · Secret Garden Loft',4,4,4,158,2,1,2,4.9,0,1,'San Juan','/property-details/2031e442-e5f8-4eb0-94bf-d9185675dfd6/santurce-arts-district-hideaway-%28calle-cerra%29',true),
  ('75cba634-bae5-445b-90a2-f83a13d0a81b','Modern Micro Loft in Art Hub',5,2,2,95,1,1,2,4.7,0,1,'San Juan','/property-details/75cba634-bae5-445b-90a2-f83a13d0a81b/modern-micro-loft-in-art-hub',true),
  ('d7ec09f6-f971-4e67-afc9-0b2f36edd636','Monaco Garden-Level Urban Enclave',6,4,4,165,1,1,2,4.8,0,1,'San Juan','/property-details/d7ec09f6-f971-4e67-afc9-0b2f36edd636/garden-level-urban-enclave-by-stay-here-pr-llc',true),
  ('35cf3675-394c-43c8-98d4-813beed40ffb','Salo · Casa Verde Studio',7,2,2,82,1,1,1,4.6,0,1,'San Juan','/property-details/35cf3675-394c-43c8-98d4-813beed40ffb/salo-casa-verde-studio-by-stay-here-pr',true),
  ('1c6a5ba9-9f2e-49bf-93a0-4605bb65934b','Salo · Casa Verde 1st Floor & Patio',8,6,6,147,2,1,3,4.7,0,1,'San Juan','/property-details/1c6a5ba9-9f2e-49bf-93a0-4605bb65934b/salo-casa-verde-1st-floor-%26-patio-by-stay-here-pr',true),
  ('36987887-b6b4-4683-bb4b-f43f6f14b1ed','Salo · Casa Verde 2nd Floor',9,4,4,158,2,1,2,4.9,0,1,'San Juan','/property-details/36987887-b6b4-4683-bb4b-f43f6f14b1ed/salo-casa-verde-2nd-floor-by-stay-here-pr',true),
  ('cc53c78a-f0ef-46fe-9803-63a7c34ed9fc','SALO · Casa Verde — Casa Completa (4 hab)',10,10,10,311,4,2,5,4.8,0,1,'San Juan','/property-details/cc53c78a-f0ef-46fe-9803-63a7c34ed9fc/salo-casa-verde-4-bdrm-house-by-stay-here-pr',true),
  ('9efdcd80-47d7-4966-92e9-c116f04cf440','Spacious Loft · Sea View Atlantis',11,5,5,242,2,2,2,4.9,0,1,'San Juan','/property-details/9efdcd80-47d7-4966-92e9-c116f04cf440/spacious-loft-sea-view--by-stay-here-pr',true),
  ('b6373f38-fbe2-4422-ae8c-9e30fd6433db','Stylish 1BR · Coral Beach',12,4,4,305,1,1,2,4.9,1,3,'Carolina','/property-details/b6373f38-fbe2-4422-ae8c-9e30fd6433db/stylish-designed-1br-%E2%80%A2-coral-beach-by-stay-here-pr',true),
  ('055c75bb-47fc-4ec6-ac08-90956ecee867','Salo · Corner Urban Stay',13,5,5,89,3,1,3,4.8,0,1,'Santurce, San Juan','/property-details/055c75bb-47fc-4ec6-ac08-90956ecee867/salo-corner-urban-stay-by-stay-here-pr',true)
on conflict (uid) do update set
  name=excluded.name, price=excluded.price, bedrooms=excluded.bedrooms,
  bathrooms=excluded.bathrooms, beds=excluded.beds, rating=excluded.rating,
  reviews=excluded.reviews, min_stay=excluded.min_stay, city=excluded.city,
  web_path=excluded.web_path, hostfully_max=excluded.hostfully_max;
-- (No sobreescribe max_occupancy ni active en conflicto: respeta lo que edites en la app)
