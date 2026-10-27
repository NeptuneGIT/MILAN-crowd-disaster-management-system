# Lost-Dependent Reunion Prototype: build spec

A hackathon **demo**. This document describes what the system does, the contracts between its parts, and the acceptance tests. **Code lives in the files, not here**: where this spec says "see `supabase/schema.sql`", that file is the source of truth. Deliberate shortcuts are listed in [Demo shortcuts](#7-demo-shortcuts). Where this spec differs from the code or the top-level [README](../README.md), those win.

---

## 0. What the system does

```
ESP32-C3 beacon (on dependent) ──BLE advert (beacon_id)──▶ any phone running the app
                                                          │ only if beacon_id ∈ missing list
                                                          ▼
                                              Supabase RPC report_sighting(...)
                                                          │
                                                          ▼
                       Postgres: dependents / parents / sightings / camps
                                                          │ view: missing_board (staff only, via RLS)
                                                          ▼
                       Electron camp app: table + map (circles) + nearest camp
```

Loop:

1. Staff mark a dependent **missing** in the camp app (`children.is_missing = true`). Parents cannot do this. No button exists in the phone app, on purpose.
2. Every phone running the app syncs the current rotating IDs (**EIDs**) of missing dependents only (hex strings, no names).
3. Every phone scans BLE in the background. If it hears a beacon whose EID is in the missing list, it uploads `(eid, lat, lon, gps_accuracy)`. Nothing else is ever uploaded.
4. The camp app shows, per missing dependent: **Dependent Name**, **Region last seen** (circle: latest sighting's GPS accuracy + ML-predicted BLE distance, see [ml-method.md](ml-method.md)), and **Nearest Lost & Found Camp** to that region.

Scope decisions:

| Topic | Decision |
|---|---|
| Platform | Android only (no iOS) |
| Hardware | ESP32-C3 only. No receiver ESP32s, no handheld receivers |
| Beacon ID | **Rotating encrypted ID (EID)** in the advertisement payload, new every 10 min with a new random MAC. The printed label `KM-000123` (`beacon_id`) is never broadcast |
| Aadhaar | **Dummy numbers only** |
| Parent auth | Supabase Auth, email + password. A parent is linked to their `parents` row by the verified email in their login token |
| Staff auth | Supabase Auth, email + password. Staff are users whose `app_metadata.role` is `staff`. **No service-role key anywhere**; row-level security does the work |
| Marking missing | Camp staff only, in the camp app |
| Registration | You insert rows in Supabase and create the auth users in the dashboard (no registration UI) |
| Distance | Straight-line (haversine) + Google Maps directions link |
| Region last seen | Latest sighting only. Radius = `accuracy_m` + ML d90 distance (10 m fallback) |
| Map | Leaflet + OSM with circles. Demo-grade accuracy |

---

## 1. Repo layout and rules

```
supabase/        schema.sql  auth.sql  seed.sql  tests.sql  anon-check.sh  .env.example
firmware/beacon/ beacon.ino
guardian-app/    lib/ test/ android/ pubspec.yaml   Flutter app (package name `lostfound`)
                 dart-defines.example.json          copy to dart-defines.json (gitignored)
camp-software/   src/main  src/preload  src/renderer  src/shared
                 .env.example                       copy to .env (gitignored)
```

- **Verify third-party APIs against the installed package versions.** Package APIs change.
- Never commit secrets: `dart-defines.json`, `supabase/.env` and `camp-software/.env` are gitignored; only the `*.example` files are committed. The camp app needs only the URL and **anon** key. The service-role key must not appear anywhere in the repo.
- Never use real Aadhaar numbers anywhere, including tests.

---

## 2. Supabase (`supabase/`)

Run in the SQL editor of a new project, in this order:

1. `schema.sql`: **once, on an empty project** (not re-runnable). Tables, helper functions, the `missing_board` view, the two phone RPCs, RLS and the base grants.
2. `auth.sql`: re-runnable. `get_my_children()`, `is_staff()`, and the policies and grants for signed-in parents and staff.
3. `seed.sql`: **once.** Change `center` first to where the demo is physically held (offsets are degrees, 0.001° ≈ 110 m). Creates 4 camps, 3 parents, 4 dependents (beacons 1–4, labelled `KM-000001` … `KM-000004`).
4. Create the auth users in the dashboard (Authentication → Users → Add user → Create new user, tick **Auto Confirm User**): `parent1@demo.test`, `parent2@demo.test`, `parent3@demo.test` (the exact emails in the seed) and `staff@demo.test`. Then run `auth.sql` again so `staff@demo.test` gets the staff role. A user must sign in again to get a token with a new role.
5. `tests.sql`: must end with a result row `All tests passed`.

### 2.1 Data model (see `schema.sql`)

- `camps(id, name, lat, lon)`.
- `parents(id, name, email, phone, aadhaar_number)`. Email unique (case-insensitive). `aadhaar_number` must match `^[01][0-9]{11}$`: real Aadhaar numbers never start with 0 or 1, so a real one can't be stored by accident.
- `dependents(id, name, age, parent_id → parents, beacon_id unique, is_missing, missing_since, created_at)`. A trigger keeps `missing_since` in sync with `is_missing`.
- `band_keys(child_id → children, key)`: one secret AES-128 key per band. RLS on, **no policy and no grant**, so no API role can read it; only SQL run as postgres can (`provision-band.sql`). A trigger creates a key for every new child.
- `sightings(id, child_id → dependents, lat, lon, accuracy_m, reporter, seen_at)`.
- `missing_board` view (`security_invoker`): one row per missing dependent, with the latest sighting **since `missing_since`** and the nearest camp. Marking a dependent missing again never shows old sightings.
- Helpers: `band_epoch()` (10-minute slot number), `eid_window_epochs()` (3), `band_eid(key, epoch)` (the AES step, not callable by any API role); `beacon_label(id)` = `KM-` + 6-digit zero-padded id; `haversine_m(...)` (Earth radius 6,371,000 m, identical to the Dart implementation).

### 2.2 Functions

- `get_missing_eids()`: text array of the EIDs of missing dependents for the current slot ±3 (7 per dependent, shuffled). No names, no locations, no way to link an EID to a dependent.
- `report_sighting(eid, lat, lon, accuracy_m, reporter, ...)`: stores a sighting **only if** the EID is valid right now (current slot ±3) for a dependent who is currently missing, the input is valid (coordinates in range, accuracy 0–500 m) and the same reporter hasn't reported that dependent in the last 5 s. It always returns void, so callers cannot probe which EIDs exist.
- `get_my_children()`: the signed-in parent's dependents, matched by the email in the login token. It takes no argument, so it can only return the caller's own.
- `is_staff()`: true when the token's `app_metadata.role` is `staff`. `app_metadata` can only be changed server-side.

### 2.3 Access model

| Role | Can |
|---|---|
| `anon` (a phone that is signed out) | read `camps`; call `get_missing_eids`, `report_sighting` |
| `authenticated` parent | the same, plus `get_my_children` |
| `authenticated` staff | the same, plus read `children`, `parents` (id, name, email, phone), `sightings`, `missing_board`; update **only** `children.is_missing` |
| any role | **cannot read `parents.aadhaar_number`** (no column grant) |

Phones keep scanning and reporting after sign-out, because the two phone RPCs are granted to both `anon` and `authenticated`.

### 2.4 Tests

`tests.sql` is one `do` block that raises on the first failure and ends with a visible `All tests passed` row. It covers:

0. `band_eid` matches two AES known-answer vectors (the same ones are checked against the firmware and Node).
1. `get_missing_eids()` is `{}` when nobody is missing.
2. `report_sighting` for a dependent who is **not** missing inserts 0 rows.
3. Marking missing sets `missing_since`; one sighting inserts; the same reporter again is dropped; a different reporter inserts.
4. Invalid input (accuracy 9999, latitude 123, nulls) inserts 0 rows and does not raise.
5. `missing_board` shows the latest sighting (`accuracy_m`, signal metrics) and the geometrically nearest camp.
6. Marking found clears `missing_since` and removes the dependent from the board; marking missing again does not show old sightings.
7. `get_my_children()` is case-insensitive on the token email and returns nothing for an unknown email or an empty token.
8. An Aadhaar number outside the dummy range fails the check constraint.
5c. EIDs from 3 slots either side of now are accepted; 4 slots away, a wrong or malformed EID, the old `KM-…` label, or another dependent's EID inserts 0 rows.
9. Per-role access (simulated with `set local role`): `anon` can't read tables or call `get_my_children`; a signed-in parent sees no dependents, board or parents rows and can change nothing; staff see the board and dependents, can toggle `is_missing`, cannot change other columns, and cannot read `aadhaar_number`.

`anon-check.sh` does the same kind of check from outside, with the real anon key over PostgREST: `children`, `parents`, `sightings`, `missing_board` denied or empty; `camps` readable; `get_missing_eids` works; `band_keys` and `band_eid` denied; `get_missing_beacons` gone; `get_my_children` denied; the old `get_dependents_for_email` gone.

---

## 3. ESP32-C3 beacon firmware (`firmware/beacon/`)

Arduino IDE (board **ESP32C3 Dev Module**, **USB CDC On Boot: Enabled**), library NimBLE-Arduino 2.x from the Library Manager. Code: `beacon.ino` (verify NimBLE method names against the installed version).

### 3.1 Advertisement format (shared contract with the Flutter app)

Non-connectable, undirected advertising. One advertising packet, no scan response, no device name.

```
Byte  Value        Meaning
 0    02           AD length (flags)
 1    01           AD type: Flags
 2    06           LE General Discoverable | BR/EDR not supported
 3    0E           AD length = 14
 4    FF           AD type: Manufacturer Specific Data
 5-6  FF FF        Company ID 0xFFFF (little-endian): "test/unassigned" ID, fine for a demo
 7-8  52 55        Magic "RU"
 9    02           Format version. 0x02 = rotating encrypted ID. (0x01, the old static beacon_id, is no longer produced or accepted)
10-17 xx x8        EID: first 8 bytes of AES-128(band key, epoch block)
```

Total 18 bytes (31 allowed).

`epoch = unix_time / 600` (integer division). The AES block is 16 bytes: 12 zero bytes, then the epoch as 4 **big-endian** bytes; the EID is the first 8 bytes of its AES-128-ECB encryption. The phone sees the 8 bytes as a lowercase hex string, e.g. `4f60ca774199673f`. Known answer: key `000102030405060708090a0b0c0d0e0f`, epoch `1` gives `7346139595c0b41e`, epoch `2952345` gives `4f60ca774199673f`.

The EID is the identifier, never the BLE address. The address changes with every EID (a fresh random non-resolvable address), so it cannot be used to follow the band either.

### 3.2 Behaviour

- On boot: read `id`, `key` and the last saved time `t` from NVS (`Preferences`, namespace `beacon`). If any is missing, print `UNPROVISIONED - missing: ID <n> KEY <32 hex> TIME <unix seconds>` (only what is missing) every 2 s and do **not** advertise.
- The band keeps time by counting seconds from `millis()` (no RTC, no network). When a new 10-minute slot starts it saves the time to NVS, computes the new EID, picks a new random address and restarts advertising. After a power cut it resumes from the last saved time, so it is behind by however long it was off; the server accepts ±30 minutes, so for a longer outage re-send `TIME`.
- Advertise at 100–150 ms interval (0.625 ms units: min 160, max 240). TX power +9 dBm by default.
- Serial commands (115200, newline-terminated):
  - `ID <n>`: set and persist the label number (1..2147483647), print `OK id=<n> label=KM-<6 digits>`. Not broadcast.
  - `KEY <32 hex>`: set and persist the band's AES key; replies `OK key set` and never prints it back
  - `TIME <unix seconds>`: set the clock
  - `INFO`: print id, label, key set or missing, time, epoch, the current EID, TX power, interval, uptime
  - `TX <dbm>`: set TX power (−12..+9), persist
  - `WIPE`: clear NVS
- Power from a USB power bank for the demo. No sleep modes.

### 3.3 Acceptance

- With the app's debug screen (long-press the title), **Beacons heard** lists the board's current EID and **Matching magic** counts up. (nRF Connect or `bluetoothctl` also show manufacturer data `FFFF` with bytes `52 55 02 <8 EID bytes>`.)
- **Known answer:** send `KEY 000102030405060708090a0b0c0d0e0f`, `ID 1`, then `TIME 1771407000` (epoch 2952345). `INFO` must show `eid=4f60ca774199673f`. If not, the firmware and database disagree.
- **Match with the database:** provision with the lines from `supabase/provision-band.sql`; `INFO`'s `eid` must be one of the 7 values `select public.get_missing_eids()` returns while that dependent is marked missing.
- After a reboot, the band resumes advertising from its saved time.
- The EID and the BLE address both change when a new 10-minute slot starts (wait 10 minutes, or send a `TIME` in the next slot).
- An unprovisioned board (missing ID, key or time) does not advertise.

---

## 4. Flutter phone app (`guardian-app/`, Android only)

### 4.1 Packages and running

`supabase_flutter` (Auth, RPC and one table select), `flutter_blue_plus`, `flutter_foreground_task`, `geolocator`, `permission_handler`, `url_launcher`, `shared_preferences` (only the per-install reporter id), `flutter_riverpod`.

`permission_handler` is pinned to `^12` because 13.x needs Android build tooling newer than Flutter 3.32's template.

Run with the URL and **anon** key from `dart-defines.json`:

```
flutter run --dart-define-from-file=dart-defines.json
```

These values are fixed at compile time: hot reload/restart never picks up a change.

### 4.2 Android setup

- `minSdk 26`.
- Manifest permissions: `BLUETOOTH_SCAN` (**do not** set `neverForLocation`), `BLUETOOTH_CONNECT`, `BLUETOOTH` / `BLUETOOTH_ADMIN` (`maxSdkVersion=30`), `ACCESS_FINE_LOCATION`, `ACCESS_COARSE_LOCATION`, `INTERNET`, `POST_NOTIFICATIONS`, `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_LOCATION`, `FOREGROUND_SERVICE_CONNECTED_DEVICE`.
- Foreground service declared with `android:foregroundServiceType="location|connectedDevice"`.
- Permissions are requested after sign-in, in this order: Bluetooth → fine location → notifications. The app must still work with location denied (see 4.4).

### 4.3 Screens (this is the entire UI)

**Login.** Email and password, with a show/hide button. Signs in with Supabase Auth, then loads the parent's dependents. Messages: "Wrong email or password"; "No dependents are registered to this account" (signs back out); a server error shows the reason. The session is stored and refreshed by `supabase_flutter`. A "Log out" action ends the session but does **not** stop the scanner (see 4.4).

**Home** has two tabs plus a status chip in the app bar. The chip is **status only, never a switch**: "Scanning · 2 missing" normally, or a problem state: "Starting…", "Bluetooth off" (tap turns it on), "Location off – can't report sightings" (tap opens the right settings page). There is no scanner on/off control anywhere in the UI.

**Tab 1: Your dependents**

One card per dependent: name; unique ID large (`KM-000123`, from `beacon_label`) with a small grey `Beacon ID 123` line; a read-only status chip "Marked missing – camp staff are searching" when `is_missing`. **No "report missing" button.** This is deliberate (avoids misclicks and false alerts). Refresh by pull-down and every 15 s.

**Tab 2: Lost & Found Camps**

- `select * from camps` (anon and authenticated may read it).
- Location **on and permitted**: a "Nearest camp" card (name, distance, **Directions**) and a list sorted by distance, each row with name, distance and **Directions**. The list is labelled "Straight-line distance".
- Location **off or denied**: a banner "Turn on location to see the nearest camp" with a button that opens location settings (or the app-settings page if permanently denied); the list sorted by name, with no distances.
- Distance is straight line: `340 m` below 1000 m, else `1.2 km`. Haversine in Dart (`lib/geo/haversine.dart`) uses the same formula and radius as the SQL.
- **Directions** opens `https://www.google.com/maps/dir/?api=1&destination=<lat>,<lon>&travelmode=walking` in an external app.

**Debug screen** (hidden: long-press the app-bar title). Read-only live stats: adverts seen, adverts matching our magic, missing-list size, last uploaded beacon and time, last GPS fix (accuracy, age), skipped uploads (no fresh fix), reporter id, last error. For range and hit-rate tests.

### 4.4 Scanner service (`lib/ble/scanner_service.dart`)

Started after sign-in and permissions, and automatically on app launch when a session exists. Runs in the **main isolate**. `flutter_foreground_task` is used only to hold a foreground notification ("Lost & Found in use") so Android keeps the process alive. Do not move BLE into a background isolate.

**The user cannot turn it off.** No toggle, no stop button, and logging out does not stop it. It runs continuously while the app is installed and permitted, and restarts itself if the scan or the Bluetooth adapter drops. (Android still lets a user stop the service or revoke permissions from system settings. Swiping the app away on some phones can also kill scanning, since BLE runs in the main isolate.)

Algorithm:

1. **Missing list sync.** `rpc('get_missing_eids')` at start, every 20 s and on app resume. Keep a `Set<String> missing`. On network failure keep the last known set.
2. **Scan.** One continuous scan (never restart it repeatedly, because Android limits scan starts): a hardware manufacturer-data filter on company `0xFFFF` with magic `52 55`, low-latency mode, repeated adverts delivered. If the scan stops (adapter off/on, error), restart with back-off (2 s up to 30 s). Scanning continues when location is off.
3. **Parse** the manufacturer data. `flutter_blue_plus` strips the company ID, so the bytes are `[0x52, 0x55, ver, eid0..eid7]`. Require length ≥ 11, magic match, `ver == 2`. The EID is those 8 bytes as 16 lowercase hex characters (the phone cannot decrypt it and does not need to). This is a pure function in `lib/ble/advert_parser.dart`.
4. **Match locally.** If the EID `∉ missing`, drop it. Count it only in debug stats. **Nothing leaves the phone.**
5. **Throttle.** At most one upload per EID per 10 s per phone (`lib/ble/throttle.dart`).
6. **Location.** Keep a high-accuracy position stream running and cache the latest fix. If the fix is older than 20 s or missing, **skip the upload**. Never upload a sighting without a location.
7. **Upload.** `rpc('report_sighting', ...)` with `p_reporter` = a random per-install id (stored in `shared_preferences`). Failures are logged and dropped (no offline queue in the demo).

With location off, scanning continues but no uploads happen, and the chip says "Location off – can't report sightings". The parent's own phone behaves exactly like every other phone.

### 4.5 Tests (`flutter test`)

- `advert_parser`: `[0x52,0x55,0x01,0x7B,0,0,0]` → 123. Wrong magic → null. Version 2 → null. Short list → null. `[...,0xFF,0xFF,0xFF,0x7F]` → 2147483647.
- `haversine`: 25.4358,81.8463 → 25.4388,81.8468 ≈ 337.3 m ± 1 m.
- maps link: URL string exactly as in 4.3.
- throttle (fake clock): same beacon 5 s apart → one upload; 11 s apart → two.
- distance formatting: 340 → `340 m`; 999 → `999 m`; 1000 → `1.0 km`; 1234 → `1.2 km`.

---

## 5. Electron camp app (`camp-software/`)

electron-vite with React + TypeScript. Dependencies include `@supabase/supabase-js`, `leaflet`, `react-leaflet`, `dotenv`.

### 5.1 Security model

- `.env` (gitignored; `.env.example` committed): `SUPABASE_URL`, `SUPABASE_ANON_KEY`. **No service-role key.**
- Staff sign in with a Supabase Auth account whose `app_metadata.role` is `staff`. Anyone else is rejected with "This account isn't camp staff". Row-level security enforces the same rule on the server.
- The Supabase client **and the session** exist only in the main process. The renderer never sees a key or a token. The session is held in memory, so staff sign in on every launch.
- `BrowserWindow`: `contextIsolation: true`, `nodeIntegration: false`, `sandbox: true`. The preload exposes a small typed API through `contextBridge`. The CSP allows only the app itself plus OSM tile images.

### 5.2 Preload API (`window.camp`, see `src/shared/types.ts`)

```ts
signIn(email, password): Promise<{ email: string }>
signOut(): Promise<void>
getSession(): Promise<{ email: string } | null>
getBoard(): Promise<BoardRow[]>      // missing_board, ordered by missing_since
getDependents(): Promise<DependentRow[]>   // dependents + parent name/phone. Never Aadhaar
getCamps(): Promise<Camp[]>
setMissing(dependentId: string, missing: boolean): Promise<void>
```

Implemented in the main process with `ipcMain.handle`. **`aadhaar_number` is never selected in the camp app.** `setMissing` fails loudly if row-level security matched no row.

### 5.3 UI

Sign-in screen, then two tabs and a Sign out button.

**Tab 1: Missing board.** Split view: table left, map right. The table has one row per missing dependent, with columns exactly:

| Dependent Name | Region last seen | Nearest Lost & Found Camp |
|---|---|---|
| Aarav Kumar `KM-000001` | within ~18 m of 25.4361, 81.8466 · 2 min ago | Camp A (North Gate) · 340 m |

- No sighting yet → "No sightings yet" and "—" for the camp.
- Row older than 5 min → greyed, with a "stale" tag.
- Clicking a row pans and zooms the map to that dependent's circle.
- Poll the board every 3 s. A *new* sighting for an already-known dependent flashes the row for 2 s.

Map (Leaflet, OSM tiles, attribution visible):

- Camps as markers with their names.
- Per missing dependent: two circles with the dependent's name: GPS `accuracy_m` inside, and `accuracy_m` + the ML-predicted BLE distance outside (10 m when the sighting has no signal data). Grey and dashed when stale.
- The initial view fits all camps. The map **never auto-moves** (new sightings don't pan it); it moves only on row click.

**Tab 2: All dependents.** A search box (name or beacon label) and a table: Dependent, Beacon label, Parent, Parent phone, **Missing?** switch. Toggling to missing or to found always opens a confirm dialog ("Mark Aarav Kumar (KM-000001) as MISSING?"). This is the single place `is_missing` changes. After a change, refresh the board immediately.

### 5.4 Tests

- Unit-test the formatting helpers (`src/shared/format.test.ts`: label, radius text, "2 min ago", stale rule, distance text).
- Everything else is manual. No Electron end-to-end harness.

---

## 6. End-to-end acceptance (do all of these)

1. **Beacon:** the app's debug screen lists each board's ID under **Beacons heard**.
2. **DB:** `tests.sql` ends with `All tests passed`. `anon-check.sh` passes.
3. **Parent app:** logging in as `parent1@demo.test` shows Aarav and Diya with `KM-000001` and `KM-000002`. A wrong password shows "Wrong email or password". There is no missing button. The camp tab lists 4 camps. With location on they are sorted by distance, with a nearest card. With location off, the banner appears and there are no distances. **Directions** opens Google Maps with walking directions.
4. **Staff app:** `staff@demo.test` signs in. A parent account (`parent1@demo.test`) is rejected with "This account isn't camp staff".
5. **Not missing = silent:** with beacon 1 next to the phone and Aarav not missing, `sightings` stays empty.
6. **Missing loop:** in the camp app mark Aarav missing → within 20 s the phone's debug screen shows the missing-list size 1 → walk the phone near board 1 → a sighting row appears → within ~3 s the board shows Aarav, a circle with radius `accuracy + 10`, and the nearest camp with distance.
7. **Latest wins:** carry the board to a different spot → the circle moves to the newest sighting, not an average.
8. **Found:** toggle Aarav to found → he leaves the board. After the next sync the phone stops uploading for beacon 1.
9. **Second phone:** a different signed-in phone (any parent) also reports Aarav when near. Any app phone is a receiver.
10. **Logout doesn't silence a phone:** log out on a phone; it keeps scanning and uploading.
11. **Range and hit-rate log (for the pitch):** with the debug screen, note adverts seen vs. distance at 1, 3, 5, 10 m; phone in hand, in a pocket, in a bag, and with a person standing between phone and beacon. This became the structured field tests in [field-test-guide.md](field-test-guide.md); recordings are in `ml-model/rssi/`.

---

## 7. Demo shortcuts (known and accepted)

| Shortcut | Why it's acceptable now | Production fix |
|---|---|---|
| Band keys are typed in over USB and sit unencrypted in the ESP32 flash | Per-band keys, so one stolen band exposes only itself | Flash encryption and secure boot; keys loaded in a factory step |
| Replay of a recorded advert is accepted for up to 30 min | Needs someone physically near a band, and only affects a missing dependent | Signed, counter-bound adverts or a plausibility check on the new location |
| Demo accounts with simple passwords, created by hand in the dashboard | Dummy data only | Real onboarding, password rules or OTP, email verification |
| The anon key is baked into every APK and sits in the camp `.env` | It only grants what RLS and the grants allow | Same, plus rate limiting and a captcha on sign-in |
| Every app phone can read the missing **EID** list | The EIDs expire within 30 minutes and identify no one | Same |
| No offline queue for sightings | Demo has connectivity | Local queue, upload on reconnect |
| Dummy Aadhaar stored in plain text | Dummy values enforced by a check constraint | Do not store Aadhaar; verify via a UIDAI-approved flow or store last 4 + hash |
| Android only, scanning while the app/process is alive | Time | iOS has heavy background BLE limits; needs a separate design |
| Straight-line distance | Fast, offline | Routing API (walking) |
| Polling instead of Realtime | Simpler | Supabase Realtime |
| Camp staff session kept in memory only | Simpler | Persist with the OS keychain |
| OSM tiles loaded straight from openstreetmap.org | Fine at demo scale | A tile provider with an SLA, or self-hosted tiles |

---

## 8. Notes on encryption and BLE noise (design context, don't build now)

**Encryption lives in the advertisement payload, not the BLE link.** Non-connectable advertisements cannot use BLE link-layer encryption, because there is no connection or pairing. "Encrypted" beacons work by putting an opaque ID in the payload. This is now built (format version `0x02`, §3.1): the band broadcasts `EID = first 8 bytes of AES-128(K_band, epoch)`, rotating every 10 minutes, together with a fresh random BLE address. Only the database has `K_band`, so only it can map an EID back to a dependent. Phones get the EIDs of **missing** dependents for the current slot and 3 either side, and match locally, exactly like before.

What this buys: an eavesdropper sees an unlinkable ID every 10 minutes and cannot follow a band; fake sightings cannot be made up, because `report_sighting` only accepts an EID the server can derive. What it does not stop: **replay**. Someone who records a real advert can re-broadcast it, and the server accepts it for up to 30 minutes. Also, anyone with a band in hand and a USB cable can read its key (the ESP32-C3 flash is not encrypted); that compromises only that band, because every band has its own key. Per-phone cost: `get_missing_eids()` computes 7 AES blocks per missing dependent per call; cache it per slot if many thousands of phones poll.

**Crowd noise doesn't "mask" beacons, but it does cost detection probability.** Advertising uses three channels (37, 38, 39) in the 2.4 GHz band shared with Wi-Fi and other BLE devices. Other phones' adverts and Wi-Fi traffic cause occasional packet collisions, and bodies absorb 2.4 GHz heavily. At 100–150 ms intervals the beacon sends 7–10 packets a second, so a phone only needs one clean packet within a few seconds. The hardware scan filter on manufacturer data means the phone ignores unrelated adverts without waking the app. The practical limits are range and body shadowing (a few metres in a dense crowd), not "noise". This is why acceptance step 11 measures real hit rates. Don't claim crowd performance in the pitch without those numbers.
