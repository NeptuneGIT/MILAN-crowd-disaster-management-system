-- For a project created before "found at camp" existed. Skip on a fresh project (schema.sql has it).
-- Safe to re-run. Run this, THEN re-run auth.sql (it replaces get_my_children, adds acknowledge_found).
-- Replaces the old found-at-camp.sql and found-ack.sql.

do $$
declare v_new boolean;
begin
  v_new := not exists (select 1 from information_schema.columns
                       where table_schema = 'public' and table_name = 'children'
                         and column_name = 'found_acknowledged_at');

  alter table public.children
    add column if not exists found_camp_id uuid references public.camps(id) on delete set null,
    add column if not exists found_at timestamptz,
    add column if not exists found_acknowledged_at timestamptz;

  -- Found notices from before this change are old news: don't show them as "waiting".
  -- Only when the column was just added, so a re-run never dismisses a live notice.
  if v_new then
    update public.children set found_acknowledged_at = now()
    where not is_missing and found_at is not null and found_acknowledged_at is null;
  end if;
end $$;

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
