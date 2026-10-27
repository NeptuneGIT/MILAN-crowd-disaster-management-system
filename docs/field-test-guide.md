# Field guide: open-field and body-stacking tests

Steps 1 and 2 of [ml-method.md](ml-method.md), recorded with the **Field test panel** in the app's debug screen.

| Sheet | Runs | What it measures |
|---|---|---|
| [rssi-open-field-sheet.csv](../guardian-app/assets/field-test/rssi-open-field-sheet.csv) | 36: 1, 2, 5, 10, 20, 30 m × phone held / in pocket × 3 sessions | `A` (signal at 1 m), `n` (fade rate), scatter, dropouts, pocket loss |
| [rssi-body-stacking-sheet.csv](../guardian-app/assets/field-test/rssi-body-stacking-sheet.csv) | 18 core (sessions 1 to 3) + 10 optional (4 and 5) | Extra loss from 0 to 5 bodies (up to 9 in the optional sessions) at 10 m |

The run order in each sheet is already shuffled. The app walks you through it.

## 1. One-time set-up

1. **Build and install a debug build** (the panel is hidden in release builds):
   ```bash
   flutter build apk --debug --dart-define-from-file=dart-defines.json
   ```
   Install `build/app/outputs/flutter-apk/app-debug.apk` on the Pixel 8 (`flutter install`, or copy it over). `dart-defines.json` needs your Supabase URL and anon key (see the README); the app needs a login to get past the first screen, for example `parent1@demo.test`.
2. **Open the app**, accept the Bluetooth, location and notification prompts, and make sure device location is on. The app blocks until it is.
3. **Switch the band on.** It must be a flashed board with an ID set (`ID <n>` over serial, `INFO` to check). Leave its settings alone for the whole test; write the TX power in your notes.
4. **Open the debug screen:** long-press the "Lost & Found" title at the top left. The **FIELD TEST** card is at the top, under the four status tiles. Check the *Band* line shows your band (for example `KM-000007`) and *Live · -xx dBm*.
5. **Dry runs** (nothing is saved):
   - *Held:* pick any run (`O01`), tap **Start**, wait for the lead-in to end and recording to begin, then watch the advert counter. At close range it should climb by about 7 to 10 a second. Tap **Cancel**.
   - *Pocket:* set up like a pocket run, tap **Start**, put the phone in your pocket during the lead-in, stand still until three buzzes, take it out, and look at the review screen. The count should be a few hundred in 60 s at 1 m. Tap **Discard**. If it is far lower than the held count at the same distance, scanning is being throttled with the screen off: stop and report it before you collect anything.

## 2. Equipment and site

- Pixel 8 (debug build), the band, a **tripod or stick** for the band, a **tape measure (30 m or more)**, **7 markers** (cones, pegs, labelled tape), a pen and printed copy of the sheet if you want to tick runs off.
- Body test: **5 friends** and 1 helper for the core runs (9 volunteers for sessions 4 and 5). Ask them to switch off their Bluetooth.
- Site: flat and open, with no buildings, cars, fences, trees or crowds within about 10 m of the line, and nobody walking nearby. Dry weather.
- Use the **same phone, band and TX power** for every run. The same person holds the phone every time.

## 3. Fixed rules for every run

- **Band:** on the tripod or stick at **0.9 m** (a child's wrist height), alone and not worn. Same orientation every run: mark the antenna side or USB port direction with tape.
- **Line:** lay the tape from the band along one straight line. Distances are metres along the ground from the band to the phone.
- **Phone "held":** in the holder's hand at chest height (about 1.2 m), screen up, in front of the body, the holder facing the band.
- **Phone "pocket":** in the holder's front trouser pocket (about 0.9 m), screen towards the body, the holder facing the band. Same pocket and phone orientation every time.
- **Holder:** stands still during a run and doesn't touch the phone.
- **Everyone else** stays behind the band or well off to the side. Nobody crosses the line during a run.

## 4. Recording one run (the same for both tests)

1. In the **FIELD TEST** card choose the sheet (**Open field** or **Body stacking**) and the **Session** chip. The run list shows each run's ID, its distance and condition, a `fit` / `holdout` tag (open field) and a status: *Not done*, *Done* or *Invalid*. The next unfinished run is highlighted.
2. Check the **Band** line shows your band as *Live*. If you see several bands, pick yours.
3. Tap the highlighted run. The run screen shows the run ID, where the phone and any bodies should be, and **Start**.
4. Move the holder (and bodies) as the screen says, then tap **Start**.
5. **Lead-in, 10 s.** The phone gives one short buzz. Use the time to settle. For a pocket run, put the phone in your pocket now.
6. **Recording, 60 s.** One long buzz marks the start. Stand still and don't touch the phone. The screen may turn off; that is fine and it keeps recording.
7. **Three buzzes** mean it is finished. Take the phone out. The review screen appears.
8. **Review:** check the adverts count (at 1 to 10 m expect several hundred; at 20 to 30 m far fewer, and few or none at 30 m is a real result, not a failure). Leave **Valid run** on, unless someone crossed the line, the phone moved, Bluetooth or location dropped, or something else went wrong. Then switch it off, tick the reason and add a note.
9. Tap **Save**. A message confirms the file name. Save *invalid* runs too.
10. To redo a run, tap it again and **Start**. The app keeps the old attempt and saves the new one as `<run>_2`. At the end of each session, redo every run still marked *Invalid*.
11. **Discard** throws away a recording that you don't want to keep at all (nothing is saved). **Cancel** during the lead-in or recording does the same.

Don't force-close the app between **Start** and **Save**: an unsaved recording is lost.

## 5. Test A: open field (36 runs)

**Set-up:** place markers at **1, 2, 5, 10, 20 and 30 m** from the band. Measure 30 m twice.

**Procedure:**
1. Do **three sessions** at three different times of day (for example morning, afternoon, evening). Pack up and set up from scratch each time: band, tape, markers.
2. In the app choose **Open field**, then **Session 1**. Work down the highlighted run list. Each run says the distance and *held* or *pocket*. Only the holder moves; the band and tape stay put. If the band is knocked, re-measure and add a note.
3. A session is 12 runs, about 30 to 40 minutes with walking.
4. Sessions 1 and 2 are tagged `fit`; session 3 is `holdout`. **Don't look at, plot or tune on the holdout runs** until the model is finished (step 6 of the plan).

**Expected (the plan's illustrative numbers):** about −59 dBm held at 1 m, about −85 to −90 at 20 to 30 m; pocket readings several dB weaker. If you are far off, check the band's height and orientation first.

## 6. Test B: body stacking at 10 m (18 core runs)

**Set-up (core, sessions 1 to 3):**
1. The band and phone stay **10 m apart** for every run, phone *held*.
2. Place markers on the line at **2.0, 3.5, 5.0, 6.5 and 8.0 m** from the band.
3. Bodies fill the markers in this order: **5.0 → 3.5 → 6.5 → 2.0 → 8.0**. For `k` bodies, the first `k` markers are occupied. The run screen lists the exact spots.
4. Each friend stands upright, **facing the phone holder**, feet on the marker, arms down, centered on the line (±10 cm). Bluetooth off, nothing in their hands, bags off the line. Same friends in the same spots across sessions where possible.

**Procedure:**
1. In the app choose **Body stacking**, then **Session 1**. Work down the run list: the run screen says how many bodies and where.
2. The helper tells friends when to step on or off their markers. Everyone is still before you tap **Start**.
3. **Session 1** goes 0 → 5 bodies, **session 2** goes 5 → 0, and **session 3** is shuffled. This spreads drift (battery, heat, interference) across the number of bodies. Run `k = 0` in every session; it is that session's baseline.
4. Run each session at a different time of day, like Test A.

**Optional sessions 4 and 5 (9 volunteers):** markers every 1 m from 1 to 9, bodies fill 5, 4, 6, 3, 7, 2, 8, 1, 9. Runs use 0, 3, 5, 7 and 9 bodies. The `k = 5` run here, next to `k = 5` in the 1.5 m layout, shows whether spacing matters. If you can get more than 9 people, ask for a longer test.

**Expected (the plan's illustration):** −79 dBm with no bodies, about −94 with five, with the biggest drop from the first body.

**This sheet is 10 m only.** The plan also wants 5 m (fit) and 15 m (holdout) later: copy the sheet and scale the spots (0.2, 0.35, 0.5, 0.65, 0.8 of the distance).

## 7. Getting the data off the phone

Everything is saved in the app's folder: `/sdcard/Android/data/in.hackforsocial.lostfound/files/rssi/open/` and `.../body/`. The path is also printed at the bottom of the FIELD TEST card. Each folder has `runs.csv` plus one CSV per attempt.

- **Share sheet:** tap **Export all** in the card and send the files to yourself (Drive, email, Nearby Share).
- **USB debugging:** with the phone connected, run `adb pull /sdcard/Android/data/in.hackforsocial.lostfound/files/rssi ml-model/rssi` from the repo root.
- Uninstalling the app deletes the saved runs. Export after every session.

**`runs.csv`** has one row per attempt: the sheet's columns (`run, session, replicate, distance_m, …, role`) with `start_time`, `stop_time`, `valid` (`y`/`n`) and `notes` filled in, plus `attempt`, `beacon_id`, `n_adverts`, `median_rssi` and `phone_model`.
**Each attempt CSV** has the header `time,beacon_id,rssi_dbm,address`, the same format as the debug screen's "Copy as CSV".

## 8. If something looks wrong

| Problem | What to check |
|---|---|
| Band card never appears | Band powered, ID set, within a metre; Bluetooth and location on; the app's top "Scanning" chip is green. |
| Few adverts at close range | Band orientation or battery; phone moved; for pocket runs, compare against a held run at the same distance. |
| Counter doesn't move for a pocket run with screen off | Report it before collecting data; scanning is being throttled. |
| "Save failed" | Storage problem: note the message. Don't close the app, and try Save again. |
| Wrong band selected | Choose the right one in the **Band** dropdown before **Start**. |
| Chip says "Location off" | Turn on device location. The app blocks without it. |

## 9. Afterwards

- Keep the raw files. Merge by `runs.csv` (the run, its `start_time` / `stop_time`, `valid`); drop rows from runs marked `n`.
- The fit script reads `role == fit` only (open field). The `holdout` runs are for the final model test.
- Total effort: the open field is 3 sessions of about 40 minutes; the body test is 3 sessions of about 30 minutes plus friends' time.

## Why the plan looks like this

- **Why 3 sessions?** One session is one afternoon of interference, battery level and band placement. Three fresh set-ups show how much the numbers move between sessions. A single 60 s run doesn't replace this: its adverts share the same set-up, so they aren't independent evidence.
- **Fit and holdout:** *fit* data is used to work out the model's numbers (`A`, `n`, `σ`) and build the simulator. *Holdout* data is set aside; when the model is finished you ask it to predict the holdout distances and compare with the tape measure. It is an exam on questions the model never saw. Without it you could only show the model matches the data it was built from.
- **Held and pocket:** the app will mostly run on phones in pockets and bags. Running both at every distance gives the pocket loss, which goes into the simulator as an extra term. The body test uses the held position only; it assumes bodies add the same dB whatever the phone position. That is an assumption, not a measured fact.
- **Order 0→5, then 5→0, then shuffled:** phones and radios drift during a session. If every session went 0→5, steady drift would look like "more bodies, weaker signal". Going up in one session and down in the next makes drift push the curve in opposite directions so it cancels; the third session is shuffled to catch anything else.
- **Is 5 bodies enough?** Not to prove it. The plan *assumes* the loss levels off by about 5 bodies. The data shows whether it does: if 4 → 5 bodies still costs more than about 1 to 2 dB, it hasn't levelled off and the simulator's curve is wrong for dense crowds. A real 3 people/m² crowd at 10 m has about 15 people in the path. If the simulator underestimates the loss, the model reads a weak signal as "far" and draws circles that are too big, which is the safe direction for finding a child but gives up the benefit. Sessions 4 and 5 test up to 9 bodies.
