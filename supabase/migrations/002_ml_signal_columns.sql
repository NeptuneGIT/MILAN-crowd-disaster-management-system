-- For a project created before the ML distance model. Skip on a fresh project (schema.sql has it).
-- Safe to re-run. Run this, THEN re-run auth.sql (it re-grants what the dropped view lost).
--
-- 1. sightings gain the signal features the phone now uploads (median RSSI, adverts heard, IQR).
-- 2. report_sighting takes them (the old 5-argument version is dropped; the new one still accepts 5).
-- 3. missing_board exposes them and no longer has radius_m: the camp app sizes the circle itself
--    from accuracy_m + its predicted distance. ble_allowance_m() (the fixed 10 m) goes with it.
--
-- ORDER: run this BEFORE using the new camp app (it no longer reads radius_m), and note the
-- previous camp app build stops working once radius_m is gone.

alter table public.sightings
  add column if not exists rssi_dbm real,   -- median signal strength heard from the beacon in the upload window
  add column if not exists n_heard integer,
  add column if not exists iqr real;

do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'sightings_n_heard_check') then
    alter table public.sightings add constraint sightings_n_heard_check check (n_heard is null or n_heard >= 0);
  end if;
  if not exists (select 1 from pg_constraint where conname = 'sightings_iqr_check') then
    alter table public.sightings add constraint sightings_iqr_check check (iqr is null or iqr >= 0);
  end if;
end $$;

drop function if exists public.report_sighting(integer, float8, float8, real, text);

create or replace function public.report_sighting(
  p_beacon_id integer,
  p_lat float8,
  p_lon float8,
  p_accuracy_m real,
  p_reporter text default null,
  p_rssi real default null,
  p_n_heard integer default null,
  p_iqr real default null
) returns void language plpgsql security definer set search_path = public as $$
declare v_child uuid;
begin
  if p_beacon_id is null or p_lat is null or p_lon is null or p_accuracy_m is null
     or p_lat not between -90 and 90 or p_lon not between -180 and 180
     or p_accuracy_m < 0 or p_accuracy_m > 500 then
    return;
  end if;

  select id into v_child from public.children where beacon_id = p_beacon_id and is_missing;
  if v_child is null then return; end if;

  -- same phone, same child, within 5 s: drop
  if exists (
    select 1 from public.sightings
    where child_id = v_child and reporter is not distinct from p_reporter
      and seen_at > now() - interval '5 seconds'
  ) then return; end if;

  insert into public.sightings (child_id, lat, lon, accuracy_m, reporter, rssi_dbm, n_heard, iqr)
  values (v_child, p_lat, p_lon, p_accuracy_m, p_reporter, p_rssi, p_n_heard, p_iqr);
end $$;

revoke all on function public.report_sighting(integer, float8, float8, real, text, real, integer, real) from public, anon, authenticated;
grant execute on function public.report_sighting(integer, float8, float8, real, text, real, integer, real) to anon, authenticated;

-- The view's column list changes, so it must be dropped and recreated (grants are lost with it).
drop view if exists public.missing_board;

create view public.missing_board with (security_invoker = true) as
select
  c.id                                     as child_id,
  c.name                                   as child_name,
  public.beacon_label(c.beacon_id)         as beacon_label,
  c.missing_since,
  s.lat,
  s.lon,
  s.seen_at,
  s.accuracy_m,
  s.rssi_dbm,
  s.n_heard,
  s.iqr,
  nc.camp_id,
  nc.camp_name,
  nc.camp_lat,
  nc.camp_lon,
  nc.distance_m
from public.children c
left join lateral (
  select * from public.sightings x
  where x.child_id = c.id and x.seen_at >= c.missing_since
  order by x.seen_at desc, x.id desc limit 1
) s on true
left join lateral (
  select ca.id as camp_id, ca.name as camp_name, ca.lat as camp_lat, ca.lon as camp_lon,
         public.haversine_m(s.lat, s.lon, ca.lat, ca.lon) as distance_m
  from public.camps ca
  where s.lat is not null
  order by public.haversine_m(s.lat, s.lon, ca.lat, ca.lon)
  limit 1
) nc on true
where c.is_missing;

grant select on public.missing_board to authenticated;   -- rows only appear for staff (RLS)

drop function if exists public.ble_allowance_m();
