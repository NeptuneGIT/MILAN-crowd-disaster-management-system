-- Supabase Auth for parents and camp staff. Run AFTER schema.sql (safe to re-run).
-- (camps access and the phone RPC grants for signed-in users are already in schema.sql.)
--
-- Users are created in the dashboard (Authentication -> Users -> Add user -> Create new user,
-- tick "Auto Confirm User"). A parent is matched to their `parents` row by the verified email in
-- their login token. A staff member is a user whose app_metadata role is 'staff' (set at the
-- bottom). app_metadata can only be changed server-side, never by the user.

create or replace function public.is_staff()
returns boolean language sql stable as $$
  select coalesce(auth.jwt() -> 'app_metadata' ->> 'role', '') = 'staff'
$$;

-- The signed-in parent's children. No email argument: it can only ever return your own.
-- found_* is filled from when staff mark the child found until the guardian confirms (or staff dismiss),
-- and only if they picked a camp.
drop function if exists public.get_my_children();
create function public.get_my_children()
returns table (child_id uuid, child_name text, beacon_id integer, beacon_label text,
               is_missing boolean, parent_name text,
               found_camp_name text, found_camp_lat float8, found_camp_lon float8, found_at timestamptz)
language sql security definer set search_path = public stable as $$
  select c.id, c.name, c.beacon_id, public.beacon_label(c.beacon_id), c.is_missing, p.name,
         ca.name, ca.lat, ca.lon, case when ca.id is not null then c.found_at end
  from public.parents p
  join public.children c on c.parent_id = p.id
  left join public.camps ca on ca.id = c.found_camp_id and not c.is_missing
                           and c.found_acknowledged_at is null
  where lower(p.email) = lower(auth.jwt() ->> 'email')
  order by c.name
$$;

-- Clears the Found notice for everyone. The guardian confirms; staff can dismiss if the guardian never does.
-- Returns false when there was nothing to clear or the caller isn't allowed.
create or replace function public.acknowledge_found(p_child_id uuid)
returns boolean language plpgsql security definer set search_path = public as $$
declare v_n int;
begin
  update public.children c set found_acknowledged_at = now()
  where c.id = p_child_id and not c.is_missing and c.found_at is not null and c.found_acknowledged_at is null
    and (public.is_staff() or exists (
      select 1 from public.parents p
      where p.id = c.parent_id and lower(p.email) = lower(auth.jwt() ->> 'email')));
  get diagnostics v_n = row_count;
  return v_n = 1;
end $$;

-- New functions get EXECUTE for everyone by default; lock down, then grant deliberately.
revoke all on function public.is_staff()        from public, anon, authenticated;
revoke all on function public.get_my_children() from public, anon, authenticated;
revoke all on function public.acknowledge_found(uuid) from public, anon, authenticated;
grant execute on function public.is_staff()        to authenticated;   -- used inside RLS policies
grant execute on function public.get_my_children() to authenticated;
grant execute on function public.acknowledge_found(uuid) to authenticated;

-- ───────────── staff access (camp app) ─────────────
-- The missing_board view is security_invoker, so it needs the staff to be able to read what it
-- reads, plus the helper functions it calls.
grant execute on function public.beacon_label(integer)                to authenticated;
grant execute on function public.haversine_m(float8, float8, float8, float8) to authenticated;

drop policy if exists staff_children_select on public.children;
drop policy if exists staff_children_update on public.children;
create policy staff_children_select on public.children for select to authenticated using (public.is_staff());
create policy staff_children_update on public.children for update to authenticated
  using (public.is_staff()) with check (public.is_staff());
grant select on public.children to authenticated;
grant update (is_missing, found_camp_id) on public.children to authenticated;   -- staff can change nothing else

drop policy if exists staff_sightings_select on public.sightings;
create policy staff_sightings_select on public.sightings for select to authenticated using (public.is_staff());
grant select on public.sightings to authenticated;

-- Column-level grant: aadhaar_number is deliberately NOT readable by any signed-in role.
drop policy if exists staff_parents_select on public.parents;
create policy staff_parents_select on public.parents for select to authenticated using (public.is_staff());
grant select (id, name, email, phone) on public.parents to authenticated;

grant select on public.missing_board to authenticated;           -- rows only appear for staff (RLS)

-- ───────────── make a user staff ─────────────
-- Create staff@demo.test in the dashboard first (auto confirm), then run this file again
-- (or just this statement). No effect if the user doesn't exist yet. The user must sign in
-- again to get a token with the new role.
update auth.users
set raw_app_meta_data = coalesce(raw_app_meta_data, '{}'::jsonb) || '{"role": "staff"}'::jsonb
where lower(email) = 'staff@demo.test';
