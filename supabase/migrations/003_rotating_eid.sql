-- For a project whose schema.sql / earlier migrations already ran: switch from static beacon IDs to rotating
-- encrypted IDs. Safe to re-run.
--
-- ORDER (the old phone app and old band firmware stop working at step 1, so do this before the event):
--   1. Run this file in the SQL editor (as postgres).
--   2. Run supabase/provision-band.sql, then give each band its ID / KEY / TIME lines (firmware/beacon).
--   3. Install the new phone app. The old app calls get_missing_beacons and report_sighting(integer, ...),
--      which are dropped here, so it can no longer fetch the list or report.
--   4. Run tests.sql.

create extension if not exists pgcrypto with schema extensions;

-- ───────────── rotating encrypted band IDs ─────────────
-- Each band holds its own secret AES-128 key. Every 10 minutes it advertises
--   EID = first 8 bytes of AES(key, epoch),  epoch = unix time / 600
-- so an eavesdropper sees a different, unlinkable ID each time. Only this database has the keys, so only
-- it can map an EID back to a child. Phones are given the EIDs of MISSING children only and compare locally.
-- band_keys has RLS on and no policy or grant: no API role can read a key (only SQL run as postgres can).
create table if not exists public.band_keys (
  child_id uuid primary key references public.children(id) on delete cascade,
  key      bytea not null default extensions.gen_random_bytes(16) check (octet_length(key) = 16)
);

create or replace function public.children_make_band_key()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.band_keys (child_id) values (new.id);
  return new;
end $$;

drop trigger if exists children_band_key_trg on public.children;
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

-- keys for children that already exist (new children get one from the trigger)
insert into public.band_keys (child_id) select id from public.children on conflict do nothing;

alter table public.band_keys enable row level security;
revoke all on public.band_keys from public, anon, authenticated;
revoke all on function public.children_make_band_key() from public, anon, authenticated;
revoke all on function public.band_epoch()             from public, anon, authenticated;
revoke all on function public.eid_window_epochs()      from public, anon, authenticated;
revoke all on function public.band_eid(bytea, bigint)  from public, anon, authenticated;

-- the static-ID RPCs are gone
drop function if exists public.get_missing_beacons();
drop function if exists public.report_sighting(integer, float8, float8, real, text, real, integer, real);
drop function if exists public.report_sighting(integer, float8, float8, real, text);

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

revoke all on function public.get_missing_eids() from public, anon, authenticated;
revoke all on function public.report_sighting(text, float8, float8, real, text, real, integer, real) from public, anon, authenticated;
grant execute on function public.get_missing_eids() to anon, authenticated;
grant execute on function public.report_sighting(text, float8, float8, real, text, real, integer, real) to anon, authenticated;
