-- Camps on the Ashoka University campus (Sonipat). Coordinates are OpenStreetMap positions of real
-- spots, 150-360 m apart. To use another venue, edit the rows below.
insert into public.camps (name, lat, lon) values
  ('Camp A (Gate 1)',        28.94523, 77.10274),
  ('Camp B (Amphitheatre)',  28.94668, 77.10149),
  ('Camp C (Sports Centre)', 28.94829, 77.10100),
  ('Camp D (Gate 2)',        28.94846, 77.10259);

-- All Aadhaar numbers are DUMMY (start with 0/1; enforced by a check constraint).
insert into public.parents (name, email, phone, aadhaar_number) values
  ('Ramesh Kumar', 'parent1@demo.test', '9000000001', '000000000001'),
  ('Sunita Devi',  'parent2@demo.test', '9000000002', '000000000002'),
  ('Anil Sharma',  'parent3@demo.test', '9000000003', '000000000003');

-- Beacon IDs 1–4 map to physical ESP32s labelled KM-000001 … KM-000004.
insert into public.children (name, age, parent_id, beacon_id)
select v.cname, v.age, p.id, v.beacon
from (values
  ('Aarav Kumar',  6, 'parent1@demo.test', 1),
  ('Diya Kumar',   4, 'parent1@demo.test', 2),
  ('Kabir Devi',   8, 'parent2@demo.test', 3),
  ('Meera Sharma', 5, 'parent3@demo.test', 4)
) as v(cname, age, email, beacon)
join public.parents p on lower(p.email) = v.email;
