-- Run ONCE on an empty project, then auth.sql, then seed.sql. Re-running this file fails with
-- "already exists" because the tables are created without IF NOT EXISTS (auth.sql is re-runnable).

create extension if not exists pgcrypto with schema extensions;   -- AES for the rotating band IDs

-- ───────────── tables ─────────────
create table public.camps (
  id   uuid primary key default gen_random_uuid(),
  name text not null,
  lat  double precision not null check (lat between -90 and 90),
  lon  double precision not null check (lon between -180 and 180)
);

create table public.parents (
  id             uuid primary key default gen_random_uuid(),
  name           text not null,
  email          text not null,
  phone          text,
  -- DEMO ONLY. Real Aadhaar numbers never start with 0 or 1, so this constraint
  -- makes it impossible to accidentally store a real one.
  aadhaar_number text not null check (aadhaar_number ~ '^[01][0-9]{11}$')
);
create unique index parents_email_key on public.parents (lower(email));

create table public.children (
  id            uuid primary key default gen_random_uuid(),
  name          text not null,
  age           smallint,
  parent_id     uuid not null references public.parents(id) on delete cascade,
  beacon_id     integer not null unique check (beacon_id > 0),   -- value broadcast by the ESP32
  is_missing    boolean not null default false,
  missing_since timestamptz,
  found_camp_id uuid references public.camps(id) on delete set null,  -- where staff say the child was found
  found_at      timestamptz,
  found_acknowledged_at timestamptz,                                    -- guardian or staff cleared the Found notice
  created_at    timestamptz not null default now()
);

create table public.sightings (
  id         bigint generated always as identity primary key,
  child_id   uuid not null references public.children(id) on delete cascade,
  lat        double precision not null,
  lon        double precision not null,
  accuracy_m real not null check (accuracy_m >= 0),
  reporter   text,                                   -- random per-install id, for de-duplication only
  seen_at    timestamptz not null default now(),
  rssi_dbm   real,                                   -- median signal strength heard from beacon in upload window
  n_heard    integer check (n_heard is null or n_heard >= 0),
  iqr        real check (iqr is null or iqr >= 0)
);
create index sightings_child_seen_idx on public.sightings (child_id, seen_at desc);

-- ───────────── helpers ─────────────
create or replace function public.beacon_label(p_beacon_id integer)
returns text language sql immutable as $$
  select 'KM-' || lpad(p_beacon_id::text, 6, '0')
$$;

create or replace function public.haversine_m(lat1 float8, lon1 float8, lat2 float8, lon2 float8)
returns float8 language sql immutable parallel safe as $$
  select 2 * 6371000 * asin(least(1, sqrt(
    power(sin(radians(lat2 - lat1) / 2), 2) +
    cos(radians(lat1)) * cos(radians(lat2)) * power(sin(radians(lon2 - lon1) / 2), 2)
  )))
$$;

-- keep missing_since in sync with is_missing
create or replace function public.children_set_missing_since()
returns trigger language plpgsql as $$
begin
  if tg_op = 'INSERT' then
    if new.is_missing then new.missing_since := now(); end if;
  elsif new.is_missing and not old.is_missing then
    new.missing_since := now();
    new.found_camp_id := null; new.found_at := null; new.found_acknowledged_at := null; -- missing again: forget the last "found"
  elsif not new.is_missing then
    new.missing_since := null;
    if old.is_missing then new.found_at := now(); new.found_acknowledged_at := null; end if; -- staff sets found_camp_id in the same update
  end if;
  return new;
end $$;

create trigger children_missing_since_trg
  before insert or update of is_missing on public.children
  for each row execute function public.children_set_missing_since();

-- ───────────── rotating encrypted band IDs ─────────────
-- Each band holds its own secret AES-128 key. Every 10 minutes it advertises
--   EID = first 8 bytes of AES(key, epoch),  epoch = unix time / 600
-- so an eavesdropper sees a different, unlinkable ID each time. Only this database has the keys, so only
-- it can map an EID back to a child. Phones are given the EIDs of MISSING children only and compare locally.
-- band_keys has RLS on and no policy or grant: no API role can read a key (only SQL run as postgres can).
create table public.band_keys (
  child_id uuid primary key references public.children(id) on delete cascade,
  key      bytea not null default extensions.gen_random_bytes(16) check (octet_length(key) = 16)
);

create or replace function public.children_make_band_key()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.band_keys (child_id) values (new.id);
  return new;
end $$;

create trigger children_band_key_trg
  after insert on public.children
  for each row execute function public.children_make_band_key();

-- 10-minute slot number. Must match EPOCH_S in firmware/beacon/beacon.ino.
create or replace function public.band_epoch()
returns bigint language sql stable as $$ select floor(extract(epoch from now()) / 600)::bigint $$;

-- A band's clock may be a little off or stale after a power cut, so accept EIDs from this many slots
-- either side of now (3 = 30 minutes). Wider = more tolerant of drift, but phones hold more EIDs.
create or replace function public.eid_window_epochs()
returns integer language sql immutable as $$ select 3 $$;

-- AES-128 of a 16-byte block (12 zero bytes + the epoch as 4 big-endian bytes), first 8 bytes, as 16 hex characters.
create or replace function public.band_eid(p_key bytea, p_epoch bigint)
returns text language sql immutable set search_path = public, extensions as $$
  select encode(substring(encrypt(decode(lpad(to_hex(p_epoch), 32, '0'), 'hex'), p_key, 'aes-ecb/pad:none') from 1 for 8), 'hex')
$$;

-- ───────────── camp board view ─────────────
-- One row per MISSING child. Latest sighting since they were marked missing,
-- plus the camp nearest to that sighting. Staff only (RLS). The camp app sizes the map circle from
-- accuracy_m plus its ML-predicted distance (rssi_dbm, n_heard, iqr), so there is no radius here.
create or replace view public.missing_board with (security_invoker = true) as
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
  order by x.seen_at desc, x.id desc limit 1   -- id breaks ties (same transaction = same now())
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

-- ───────────── RPCs used by the phone app (anon key) ─────────────
-- EIDs of every missing child for the current slot and the slots either side (shuffled, so one child's
-- EIDs are not grouped). No names, no locations, no way back to a child.
create or replace function public.get_missing_eids()
returns text[] language sql security definer set search_path = public stable as $$
  select coalesce(array_agg(public.band_eid(k.key, e) order by random()), '{}'::text[])
  from public.children c
  join public.band_keys k on k.child_id = c.id
  cross join generate_series(public.band_epoch() - public.eid_window_epochs(),
                             public.band_epoch() + public.eid_window_epochs()) e
  where c.is_missing
$$;

-- Server-side enforcement: a sighting is stored ONLY if the EID belongs to a child who is currently missing
-- and is valid for this time window. Always returns void, so callers cannot probe which EIDs exist.
create or replace function public.report_sighting(
  p_eid text,
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
  if p_eid is null or p_eid !~ '^[0-9a-f]{16}$' or p_lat is null or p_lon is null or p_accuracy_m is null
     or p_lat not between -90 and 90 or p_lon not between -180 and 180
     or p_accuracy_m < 0 or p_accuracy_m > 500 then
    return;
  end if;

  select c.id into v_child
  from public.children c
  join public.band_keys k on k.child_id = c.id
  cross join generate_series(public.band_epoch() - public.eid_window_epochs(),
                             public.band_epoch() + public.eid_window_epochs()) e
  where c.is_missing and public.band_eid(k.key, e) = p_eid
  limit 1;
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

-- Parent/staff access (get_my_children, staff policies) is in auth.sql: run it right after this file.

-- ───────────── lock everything down ─────────────
alter table public.camps     enable row level security;
alter table public.parents   enable row level security;
alter table public.children  enable row level security;
alter table public.sightings enable row level security;
alter table public.band_keys enable row level security;

revoke all on all tables    in schema public from anon, authenticated;
revoke all on all functions in schema public from public, anon, authenticated;

create policy camps_read on public.camps for select to anon, authenticated using (true);
grant select on public.camps to anon, authenticated;

-- anon: phones keep scanning and reporting after sign-out. authenticated: while signed in.
grant execute on function public.get_missing_eids()                                  to anon, authenticated;
grant execute on function public.report_sighting(text, float8, float8, real, text, real, integer, real) to anon, authenticated;
