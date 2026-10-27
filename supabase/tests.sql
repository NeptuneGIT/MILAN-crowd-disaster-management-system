-- Run as postgres in the SQL editor AFTER schema.sql and seed.sql.
-- Any failure raises an exception (and rolls back the whole block).
-- Note: the block is one transaction, so now() is constant throughout it.
do $$
declare
  v_child  uuid;
  v_n      int;
  v_since  timestamptz;
  v_row    public.missing_board%rowtype;
  v_near   text;
  v_ok     boolean;
  v_key    bytea;
  v_eid    text;    -- child 1's rotating ID for the current slot
begin
  -- clean slate
  delete from public.sightings;
  update public.children set is_missing = false;
  select id into v_child from public.children where beacon_id = 1;
  if v_child is null then raise exception 'seed missing: no child with beacon_id 1'; end if;
  select key into v_key from public.band_keys where child_id = v_child;
  if v_key is null then raise exception 'seed missing: child 1 has no band key (run migrations/003_rotating_eid.sql)'; end if;
  v_eid := public.band_eid(v_key, public.band_epoch());

  -- 0. known answer: the same vector is checked in the firmware notes and in Node, so SQL and band agree
  if public.band_eid(decode('000102030405060708090a0b0c0d0e0f', 'hex'), 1) <> '7346139595c0b41e'
     or public.band_eid(decode('000102030405060708090a0b0c0d0e0f', 'hex'), 2952345) <> '4f60ca774199673f' then
    raise exception 'T0: band_eid does not match the AES known-answer vectors';
  end if;

  -- 1. nobody missing -> empty list
  if public.get_missing_eids() <> '{}'::text[] then
    raise exception 'T1: get_missing_eids should be {} but is %', public.get_missing_eids();
  end if;

  -- 2. child not missing -> sighting ignored
  perform public.report_sighting(v_eid, 25.44, 81.85, 8, 'dev-a');
  select count(*) into v_n from public.sightings;
  if v_n <> 0 then raise exception 'T2: expected 0 sightings for non-missing child, got %', v_n; end if;

  -- 3. mark missing -> missing_since set; insert, dedupe, different reporter
  update public.children set is_missing = true where id = v_child;
  select missing_since into v_since from public.children where id = v_child;
  if v_since is null then raise exception 'T3: missing_since not set'; end if;
  -- 7 EIDs for one missing child (now +/- 3 slots), including the one the band is advertising now
  if array_length(public.get_missing_eids(), 1) <> 7 or not (v_eid = any (public.get_missing_eids())) then
    raise exception 'T3: get_missing_eids should hold 7 EIDs including the current one, got %', public.get_missing_eids();
  end if;

  perform public.report_sighting(v_eid, 25.44, 81.85, 8, 'dev-a');
  select count(*) into v_n from public.sightings;
  if v_n <> 1 then raise exception 'T3: expected 1 sighting, got %', v_n; end if;

  perform public.report_sighting(v_eid, 25.44, 81.85, 8, 'dev-a');
  select count(*) into v_n from public.sightings;
  if v_n <> 1 then raise exception 'T3: dedupe failed, got % sightings', v_n; end if;

  perform public.report_sighting(v_eid, 25.44, 81.85, 8, 'dev-b');
  select count(*) into v_n from public.sightings;
  if v_n <> 2 then raise exception 'T3: different reporter should insert, got % sightings', v_n; end if;
  -- 3b. sighting with signal strength metrics (ML features)
  perform public.report_sighting(v_eid, 25.441, 81.851, 6, 'dev-sig', -55.0, 14, 3.2);
  select * into v_row from public.missing_board where child_id = v_child;
  if v_row.rssi_dbm is distinct from -55.0::real or v_row.n_heard <> 14 or v_row.iqr is distinct from 3.2::real then
    raise exception 'T3b: signal metrics not saved on sighting, got rssi=%, n_heard=%, iqr=%', v_row.rssi_dbm, v_row.n_heard, v_row.iqr;
  end if;

  -- 4. invalid input -> no rows, no error
  perform public.report_sighting(v_eid, 25.44, 81.85, 9999, 'dev-c');
  perform public.report_sighting(v_eid, 123,   81.85, 8,    'dev-c');
  perform public.report_sighting(null, 25.44, 81.85, 8, 'dev-c');
  perform public.report_sighting(v_eid, null,  81.85, 8,    'dev-c');
  perform public.report_sighting(v_eid, 25.44, null,  8,    'dev-c');
  perform public.report_sighting(v_eid, 25.44, 81.85, null, 'dev-c');
  select count(*) into v_n from public.sightings;
  if v_n <> 3 then raise exception 'T4: invalid input inserted rows, got % sightings (expected the 3 valid ones)', v_n; end if;

  -- 5. missing_board shows the latest sighting (T3b's, accuracy 6); nearest camp matches haversine
  select * into v_row from public.missing_board where child_id = v_child;
  if not found then raise exception 'T5: child not on missing_board'; end if;
  if v_row.accuracy_m <> 6 then raise exception 'T5: latest sighting accuracy should be 6, got %', v_row.accuracy_m; end if;
  select name into v_near from public.camps order by public.haversine_m(25.44, 81.85, lat, lon) limit 1;
  if v_row.camp_name is null or v_row.camp_name <> v_near then
    raise exception 'T5: nearest camp should be %, got %', v_near, v_row.camp_name;
  end if;

  -- 5b. contract: select exactly the columns the clients read, so a renamed or missing column
  --     fails here instead of in an app. Update when src/main/db.ts or lib/data.dart changes.
  perform child_id, child_name, beacon_label, missing_since, lat, lon, seen_at, accuracy_m,
          rssi_dbm, n_heard, iqr, camp_id, camp_name, distance_m
    from public.missing_board;                                   -- camp app: getBoard
  perform id, name, beacon_id, is_missing, found_at, found_camp_id, found_acknowledged_at
    from public.children;                                        -- camp app: getDependents / getFound
  perform child_id, child_name, beacon_id, beacon_label, is_missing,
          found_camp_name, found_camp_lat, found_camp_lon, found_at
    from public.get_my_children();                               -- phone app: fetchDependents
  perform id, name, lat, lon from public.camps;                  -- both apps: camps

  -- 5c. rotating IDs: the edge of the time window is accepted, one slot beyond is not, and nothing else matches
  perform public.report_sighting(public.band_eid(v_key, public.band_epoch() + 3), 25.44, 81.85, 8, 'dev-edge-in');
  perform public.report_sighting(public.band_eid(v_key, public.band_epoch() - 3), 25.44, 81.85, 8, 'dev-edge-in2');
  select count(*) into v_n from public.sightings;
  if v_n <> 5 then raise exception 'T5c: EIDs 3 slots from now should be accepted, got % sightings', v_n; end if;
  perform public.report_sighting(public.band_eid(v_key, public.band_epoch() + 4), 25.44, 81.85, 8, 'dev-late');
  perform public.report_sighting(public.band_eid(v_key, public.band_epoch() - 4), 25.44, 81.85, 8, 'dev-stale');
  perform public.report_sighting('0000000000000000', 25.44, 81.85, 8, 'dev-wrong');
  perform public.report_sighting(substr(v_eid, 1, 15), 25.44, 81.85, 8, 'dev-short');
  perform public.report_sighting('KM-000001', 25.44, 81.85, 8, 'dev-label');
  select count(*) into v_n from public.sightings;
  if v_n <> 5 then raise exception 'T5c: stale, wrong or malformed EIDs inserted rows, got % sightings', v_n; end if;
  -- another child's key never matches this child
  perform public.report_sighting(public.band_eid((select key from public.band_keys where child_id <> v_child limit 1),
                                                 public.band_epoch()), 25.44, 81.85, 8, 'dev-other');
  select count(*) into v_n from public.sightings;
  if v_n <> 5 then raise exception 'T5c: another child''s EID is not missing, but inserted a row (% sightings)', v_n; end if;

  -- 6. found -> off the board; re-marking missing hides older sightings
  update public.children set is_missing = false where id = v_child;
  select missing_since into v_since from public.children where id = v_child;
  if v_since is not null then raise exception 'T6: missing_since should be null after found'; end if;
  if exists (select 1 from public.missing_board where child_id = v_child) then
    raise exception 'T6: found child still on missing_board';
  end if;
  -- now() is frozen in this transaction, so age the old sightings to simulate time passing
  update public.sightings set seen_at = seen_at - interval '1 minute';
  update public.children set is_missing = true where id = v_child;
  select * into v_row from public.missing_board where child_id = v_child;
  if not found then raise exception 'T6: re-marked child not on missing_board'; end if;
  if v_row.lat is not null then raise exception 'T6: old sighting leaked onto board after re-marking'; end if;

  -- 7. parent lookup by the verified email in the login token (simulated via the JWT claims
  --    setting that PostgREST fills in). Case-insensitive.
  perform set_config('request.jwt.claims', '{"email":"PARENT1@demo.test"}', true);
  select count(*) into v_n from public.get_my_children();
  if v_n <> 2 then raise exception 'T7: expected 2 children for parent1, got %', v_n; end if;
  perform set_config('request.jwt.claims', '{"email":"nobody@demo.test"}', true);
  select count(*) into v_n from public.get_my_children();
  if v_n <> 0 then raise exception 'T7: unknown email returned % rows', v_n; end if;
  perform set_config('request.jwt.claims', '{}', true);
  select count(*) into v_n from public.get_my_children();
  if v_n <> 0 then raise exception 'T7: no email in token returned % rows', v_n; end if;

  -- 8. real-looking Aadhaar rejected
  begin
    insert into public.parents (name, email, aadhaar_number)
    values ('Bad Aadhaar', 'bad@demo.test', '234567890123');
    raise exception 'T8: aadhaar check constraint did not fire';
  exception when check_violation then
    null; -- expected
  end;

  -- 9. access rules per role. Child 1 is missing at this point. `set local role` makes RLS and
  --    grants apply like they do for real API calls (the editor itself runs as postgres).

  -- 9a. anon: no direct table access, no parent lookup
  set local role anon;
  begin
    perform 1 from public.children limit 1;
    raise exception 'T9a: anon could read children';
  exception when insufficient_privilege then null;
  end;
  begin
    perform 1 from public.get_my_children();
    raise exception 'T9a: anon could call get_my_children';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.acknowledge_found(v_child);
    raise exception 'T9a: anon could call acknowledge_found';
  exception when insufficient_privilege then null;
  end;
  begin
    perform 1 from public.band_keys limit 1;
    raise exception 'T9a: anon could read band_keys';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.band_eid(v_key, 1);
    raise exception 'T9a: anon could call band_eid with a key';
  exception when insufficient_privilege then null;
  end;
  select array_length(public.get_missing_eids(), 1) into v_n;   -- phones keep scanning when signed out
  if v_n <> 7 then raise exception 'T9a: anon should get 7 EIDs for the one missing child, got %', v_n; end if;
  reset role;

  -- 9b. signed-in parent: sees nothing staff-only and cannot change anything
  perform set_config('request.jwt.claims', '{"email":"parent1@demo.test","app_metadata":{}}', true);
  set local role authenticated;
  select count(*) into v_n from public.children;
  if v_n <> 0 then raise exception 'T9b: parent could read % children rows', v_n; end if;
  select count(*) into v_n from public.missing_board;
  if v_n <> 0 then raise exception 'T9b: parent could read % missing_board rows', v_n; end if;
  select count(*) into v_n from public.parents;
  if v_n <> 0 then raise exception 'T9b: parent could read % parents rows', v_n; end if;
  update public.children set is_missing = false;
  get diagnostics v_n = row_count;
  if v_n <> 0 then raise exception 'T9b: parent changed % children rows', v_n; end if;
  select count(*) into v_n from public.get_my_children();
  if v_n <> 2 then raise exception 'T9b: parent should still see their 2 children, got %', v_n; end if;
  reset role;
  if not exists (select 1 from public.children where id = v_child and is_missing) then
    raise exception 'T9b: parent un-marked a child as missing';
  end if;

  -- 9c. staff: reads the board and the children list, can toggle is_missing, never sees Aadhaar
  perform set_config('request.jwt.claims',
                     '{"email":"staff@demo.test","app_metadata":{"role":"staff"}}', true);
  set local role authenticated;
  select count(*) into v_n from public.children;
  if v_n <> 4 then raise exception 'T9c: staff should see 4 children, got %', v_n; end if;
  select count(*) into v_n from public.missing_board where child_id = v_child;
  if v_n <> 1 then raise exception 'T9c: staff should see child 1 on the board, got %', v_n; end if;
  select count(*) into v_n from public.parents;
  if v_n <> 3 then raise exception 'T9c: staff should see 3 parents, got %', v_n; end if;
  begin
    perform aadhaar_number from public.parents limit 1;
    raise exception 'T9c: staff could read aadhaar_number';
  exception when insufficient_privilege then null;
  end;
  begin
    perform 1 from public.band_keys limit 1;
    raise exception 'T9c: staff could read band_keys';
  exception when insufficient_privilege then null;
  end;
  begin
    update public.children set name = 'Hacked' where id = v_child;
    raise exception 'T9c: staff could change a child name';
  exception when insufficient_privilege then null;
  end;
  update public.children set is_missing = false where id = v_child;
  get diagnostics v_n = row_count;
  if v_n <> 1 then raise exception 'T9c: staff should be able to toggle is_missing, changed %', v_n; end if;
  update public.children set found_camp_id = (select id from public.camps order by name limit 1) where id = v_child;
  get diagnostics v_n = row_count;
  if v_n <> 1 then raise exception 'T9c: staff should be able to set found_camp_id, changed %', v_n; end if;
  reset role;

  -- 10. found: the parent keeps seeing the camp until someone acknowledges
  if (select found_at from public.children where id = v_child) is null then
    raise exception 'T10: found_at not set when marked found';
  end if;
  perform set_config('request.jwt.claims', '{"email":"parent1@demo.test"}', true);
  select count(*) into v_n from public.get_my_children()
    where child_id = v_child and found_camp_name is not null and found_at is not null;
  if v_n <> 1 then raise exception 'T10: parent should see the found camp, got % rows', v_n; end if;
  -- no timer: still there much later
  update public.children set found_at = now() - interval '3 days' where id = v_child;
  select count(*) into v_n from public.get_my_children() where child_id = v_child and found_camp_name is not null;
  if v_n <> 1 then raise exception 'T10: found notice should not expire on its own, got % rows', v_n; end if;
  -- another parent cannot acknowledge it
  perform set_config('request.jwt.claims', '{"email":"parent2@demo.test"}', true);
  select public.acknowledge_found(v_child) into v_ok;
  if v_ok then raise exception 'T10: another parent acknowledged someone else''s child'; end if;
  -- the guardian can
  perform set_config('request.jwt.claims', '{"email":"parent1@demo.test"}', true);
  select public.acknowledge_found(v_child) into v_ok;
  if not v_ok then raise exception 'T10: guardian could not acknowledge'; end if;
  select count(*) into v_n from public.get_my_children() where child_id = v_child and found_camp_name is not null;
  if v_n <> 0 then raise exception 'T10: acknowledged notice should clear for the guardian, got % rows', v_n; end if;
  select public.acknowledge_found(v_child) into v_ok;
  if v_ok then raise exception 'T10: acknowledging twice should do nothing'; end if;

  -- 11. staff can dismiss a notice the guardian never confirmed; missing again clears the lot
  update public.children set is_missing = true where id = v_child;
  update public.children set is_missing = false, found_camp_id = (select id from public.camps order by name limit 1)
    where id = v_child;
  if (select found_acknowledged_at from public.children where id = v_child) is not null then
    raise exception 'T11: found again should start unacknowledged';
  end if;
  perform set_config('request.jwt.claims', '{"email":"staff@demo.test","app_metadata":{"role":"staff"}}', true);
  select public.acknowledge_found(v_child) into v_ok;
  if not v_ok then raise exception 'T11: staff could not dismiss'; end if;
  perform set_config('request.jwt.claims', '{"email":"parent1@demo.test"}', true);
  select count(*) into v_n from public.get_my_children() where child_id = v_child and found_camp_name is not null;
  if v_n <> 0 then raise exception 'T11: dismissed notice should clear for the guardian, got % rows', v_n; end if;
  update public.children set is_missing = true where id = v_child;
  select count(*) into v_n from public.get_my_children()
    where child_id = v_child and found_camp_name is null and found_at is null;
  if v_n <> 1 then raise exception 'T11: found info should clear when missing again, got % rows', v_n; end if;
  if (select found_acknowledged_at from public.children where id = v_child) is not null then
    raise exception 'T11: acknowledgement should clear when missing again';
  end if;

  -- reset
  perform set_config('request.jwt.claims', '', true);
  delete from public.sightings;
  update public.children set is_missing = false;

  raise notice 'All tests passed';
end $$;

-- Only reached if the block above did not raise. The Supabase editor hides notices, so show a result row.
select 'All tests passed' as result;
