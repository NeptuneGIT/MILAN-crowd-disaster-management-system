#!/usr/bin/env sh
# Out-of-band check that the anon key can only reach what it should (README §2.3).
# Usage: SUPABASE_URL=https://xxxx.supabase.co SUPABASE_ANON_KEY=... sh supabase/anon-check.sh
: "${SUPABASE_URL:?set SUPABASE_URL}" "${SUPABASE_ANON_KEY:?set SUPABASE_ANON_KEY}"

body=$(mktemp)
fail=0

call() { # method path -> sets $code, body in $body
  code=$(curl -s -o "$body" -w '%{http_code}' -X "$1" "$SUPABASE_URL$2" \
    -H "apikey: $SUPABASE_ANON_KEY" -H "Authorization: Bearer $SUPABASE_ANON_KEY" \
    -H 'Content-Type: application/json' -d "${3:-}")
}

for t in children parents sightings missing_board band_keys; do
  call GET "/rest/v1/$t?select=*"
  if [ "$code" = 401 ] || [ "$code" = 403 ] || [ "$(cat "$body")" = "[]" ]; then
    echo "ok   $t denied ($code)"
  else
    echo "FAIL $t readable with anon key ($code): $(head -c 200 "$body")"; fail=1
  fi
done

# Parent lookup must need a login, and the old "look up anyone by email" function must be gone.
call POST "/rest/v1/rpc/get_my_children" '{}'
if [ "$code" = 401 ] || [ "$code" = 403 ] || [ "$code" = 404 ]; then echo "ok   get_my_children denied for anon ($code)"
else echo "FAIL get_my_children callable by anon ($code): $(head -c 200 "$body")"; fail=1; fi

call POST "/rest/v1/rpc/get_children_for_email" '{"p_email":"parent1@demo.test"}'
if [ "$code" = 401 ] || [ "$code" = 403 ] || [ "$code" = 404 ]; then echo "ok   get_children_for_email gone ($code)"
else echo "FAIL get_children_for_email still callable ($code): $(head -c 200 "$body")"; fail=1; fi

call POST "/rest/v1/rpc/acknowledge_found" '{"p_child_id":"00000000-0000-0000-0000-000000000000"}'
if [ "$code" = 401 ] || [ "$code" = 403 ] || [ "$code" = 404 ]; then echo "ok   acknowledge_found denied for anon ($code)"
else echo "FAIL acknowledge_found callable by anon ($code): $(head -c 200 "$body")"; fail=1; fi

call GET "/rest/v1/camps?select=*"
if [ "$code" = 200 ] && [ "$(cat "$body")" != "[]" ]; then echo "ok   camps readable"
else echo "FAIL camps ($code): $(head -c 200 "$body")"; fail=1; fi

call POST "/rest/v1/rpc/get_missing_eids" '{}'
if [ "$code" = 200 ]; then echo "ok   get_missing_eids -> $(cat "$body")"
else echo "FAIL get_missing_eids ($code): $(head -c 200 "$body")"; fail=1; fi

# The key helper must not be callable, and the old static-ID list must be gone.
call POST "/rest/v1/rpc/band_eid" '{"p_key":"\\x00112233445566778899aabbccddeeff","p_epoch":1}'
if [ "$code" = 401 ] || [ "$code" = 403 ] || [ "$code" = 404 ]; then echo "ok   band_eid denied for anon ($code)"
else echo "FAIL band_eid callable by anon ($code): $(head -c 200 "$body")"; fail=1; fi

call POST "/rest/v1/rpc/get_missing_beacons" '{}'
if [ "$code" = 401 ] || [ "$code" = 403 ] || [ "$code" = 404 ]; then echo "ok   get_missing_beacons gone ($code)"
else echo "FAIL get_missing_beacons still callable ($code): $(head -c 200 "$body")"; fail=1; fi

rm -f "$body"
exit $fail
