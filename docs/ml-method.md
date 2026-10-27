# Signal strength to distance: building a dataset without a crowd

This plan produces training data for the signal-strength-to-distance model when no real crowd is available beyond 1 to 2 m.

**Idea.** A 3 people/m² crowd can't be placed between the band and the phone at 15 m. Each ingredient of the signal loss can still be measured on its own. Combine the ingredients in a simulator, train the model on the simulator's output, and test it on real measurements it never saw.

All numbers below are **made-up illustrations** chosen to be plausible. Real measurements replace them.

| Step | What it gives | Data source |
|---|---|---|
| 1. Open field | `A`, `n`, `σ_open` | Real, 1 to 30 m, no people needed |
| 2. Body stacking | Body loss curve `L(k)`, `σ_body` | Real, 5 / 10 / 15 m, about 5 friends |
| 3. Crowd calibration | Path width `w` | Real 3 people/m² crowd at 1 m |
| 4. Simulator | 50,000 labelled upload windows | Synthetic, built from steps 1 to 3 |
| 5. Training | Model predicting the 90% upper-bound distance | Synthetic data |
| 6. Testing | Coverage and circle size | Real data held back from steps 1 to 5 |
| 7. Live use | Circle radius per sighting | App and database changes |

---

## Step 1: Open field (baseline without bodies)

**Purpose.** Measure how the signal fades with distance alone. This is the base the body losses are subtracted from.

**Procedure.**
- An open field, no people between the band and the phone, the band held at a dependent's wrist height.
- Distances: 1, 2, 5, 10, 20 and 30 m, about 60 s each.
- Record with the debug screen's field-test panel, which follows `guardian-app/assets/field-test/rssi-open-field-sheet.csv` and `rssi-body-stacking-sheet.csv` (procedure: [field-test-guide.md](field-test-guide.md)). Each run is saved as a CSV (`time,beacon_id,rssi_dbm,address`) plus a row in `runs.csv`.

**Example.**

| Distance | Median signal (RSSI) |
|---|---|
| 1 m | −59 dBm |
| 2 m | −65 |
| 5 m | −73 |
| 10 m | −79 |
| 20 m | −85 |
| 30 m | −88 |

**Fit.** `RSSI = A − 10·n·log10(d)`

- `A = −59`: signal at 1 m.
- `n = 2.0`: how fast the signal fades.
- `σ_open ≈ 4 dB`: how far single readings scatter around each distance's median. The simulator needs this as well as the medians.

---

## Step 2: Body stacking (the body loss curve)

**Purpose.** Measure the extra loss caused by `k` bodies standing directly between the band and the phone.

**Procedure.**
- Fix the distance at 10 m. The open-field reading there is −79 dBm.
- Add friends one at a time, standing in a line on the direct path: 0, 1, 2, … k bodies, about 60 s each.

**Example.**

| Bodies k | 0 | 1 | 2 | 3 | 4 | 5 |
|---|---|---|---|---|---|---|
| RSSI | −79 | −86 | −90 | −92 | −93.5 | −94 |
| Loss L(k) | 0 | 7 | 11 | 13 | 14.5 | 15 dB |

**Fit.** `L(k) = Lmax · (1 − e^(−k/k0))`

- Example fit: `Lmax = 16 dB`, `k0 = 1.6`, within about 0.5 dB of every point.
- Each extra body adds **less** loss than the one before. There is no fixed loss per body.
- The levelling off happens because once the direct path is blocked, the signal mostly arrives by going over heads and bouncing off the ground.
- Also record `σ_body`, the scatter of single readings with bodies present. Expect it to be larger than in the open field, around 6 dB.

**Check the assumption.** "The loss levels off at the same maximum at any distance" is an assumption, not a known fact. Repeat the test at **5 m and 15 m**:
- Fit the curve on the 5 m and 10 m runs.
- **Hold back the 15 m runs** for step 6. They are the main test of extrapolating beyond what a real crowd could cover.
- If the curves differ a lot between distances, give the curve distance as an input as well.

**Why this curve allows extrapolation.** A 3 people/m² crowd at 15 m works out to about 22 bodies in the path, far more than 5 friends. Because the loss has already levelled off by about 5 bodies, the curve covers it.

---

## Step 3: Crowd calibration (the path width `w`)

**Purpose.** Connect the body loss curve to crowd density using the real 1 to 2 m crowd test.

**Model.** In a real crowd, the number of bodies in the path is random:

```
k ~ Poisson(ρ · w · d)
```

- `ρ` is the crowd density in people/m², and `d` is the distance in metres.
- `w` is the width in metres of the strip along the band–phone line where a person counts as blocking. It is the **only parameter that can't be measured directly**, so the real crowd test sets it.

**Average the loss, not the body count.** Draw many random `k` from the Poisson distribution, compute `L(k)` for each, and average those losses. Plugging the average `k` into the curve gives a different answer, because the curve bends.

**Example** with `w = 0.5` and `ρ = 3`:

| Distance | Average bodies (ρ·w·d) | Average loss E[L(k)] | Predicted RSSI | Measured in real crowd |
|---|---|---|---|---|
| 1 m | 1.5 | ≈ 8 dB | −59 − 8 = −67 | −68 |
| 2 m | 3 | ≈ 12 dB | −65 − 12 = −77 | −76 |

**Procedure.**
- **Tune `w` on the 1 m crowd data only.** Adjust it until the predicted signal strength and its spread match the measurements.
- **Hold back the 2 m crowd data** for step 6. If both distances are used for tuning, nothing is left to check against.

---

## Step 4: Generate the dataset

Each row is one **upload window**: the burst of adverts a phone hears before it sends a sighting.

```
for each of 50,000 windows:
    d   ~ Uniform(0.5, 30)          # true distance: the label
    ρ   ~ Uniform(0.5, 5)           # unknown at prediction time, so sampled, not fixed at 3
    k   ~ Poisson(ρ · w · d)        # bodies in the path, fixed for the whole window
    for each of 50 adverts in the window:
        rssi = A − 10·n·log10(d) − L(k) + Normal(0, σ_body)
        keep the advert only if rssi > −97 dBm (phone sensitivity)
                             and the phone happened to be scanning (80% chance)
    features = median RSSI of kept adverts, number kept, spread of RSSI (IQR)
    label    = d
```

**Example rows.**

| True d | ρ | k | Median RSSI | Adverts heard | IQR |
|---|---|---|---|---|---|
| 3 m | 1.0 | 1 | −76 | 40/50 | 5 |
| 8 m | 4.2 | 17 | −92 | 30/50 | 6 |
| 20 m | 0.6 | 5 | −94 | 12/50 | 4 |

**Details.**
- **Density is random per window.** The live app doesn't know the density, so the model has to work across 0.5 to 5 people/m². Unknown density then shows up as wider circles.
- **Bodies are fixed per window, noise varies per advert.** A crowd doesn't reshuffle in a few seconds, but each advert takes a different path.
- **Weak adverts are dropped.** This makes "adverts heard" a useful input: far or heavily blocked bands get through less often.
- **Windows with no adverts heard** are dropped, since the phone would never report them.
- **The sensitivity and scan-chance figures** (−97 dBm, 80%) are placeholders. Measure them from the open-field logs at 20 to 30 m.

**What this data is.** It is synthetic, but every parameter is measured, and step 6 tests the extrapolation against reality. Describe it as "synthetic, built from measured parameters, tested on held-back real data", not as real crowd data.

---

## Step 5: Train the model

- **Inputs:** median RSSI, adverts heard, IQR.
- **Output:** `d90`, the distance the band is within 90% of the time. This is the circle's radius.
- **Model:** gradient boosting with quantile loss, for example scikit-learn's `GradientBoostingRegressor(loss="quantile", alpha=0.9)`.
- **Don't train a plain distance regressor.** A model that predicts the average distance gives circles too small about half the time.

**Why ML, not just rearranging the formula.** Once the body count is random and weak adverts drop out, there is no closed-form way to go from signal strength back to distance. The model learns that reverse mapping from the simulator. This is an established technique (simulation-based inference).

---

## Step 6: Test on real data

Before the model is used, test it on real measurements held back from all fitting:

| Held-back data | What it tests |
|---|---|
| Open-field readings, 1 to 30 m | The no-crowd case and the fade curve |
| 2 m crowd runs | The density model and `w` |
| 15 m body-stacking runs | Extrapolation well beyond the real crowd distance |

**Report two numbers.**
- **Coverage:** the true distance should fall inside `d90` about 90% of the time.
- **Circle size:** the average radius compared with today's fixed 10 m.

The real data comes in single runs, not upload windows. Cut each run into windows of the same length the app uses before computing the features.

**This is the evidence for the demo.** Without it, the model has only been shown to fit its own simulator.

---

## Step 7: Use it live

- **Phone:** sends the median RSSI and number of adverts heard with each sighting (new arguments to `report_sighting`).
- **Database:** stores them on `sightings`.
- **Camp app (as built):** circle radius = GPS accuracy + `d90`, computed in the app from `sightings.rssi_dbm / n_heard / iqr`; falls back to 10 m when the fields are missing (older app versions). The fixed 10 m `ble_allowance_m()` and `missing_board.radius_m` were removed from the database.
- **Storing the model (as built):** the fitted trees are exported to JSON (`ml-model/export_model.py`) and shipped in the camp app (`src/shared/ml/`). Refitting means replacing two JSON files.

**Worked example (real model outputs, from `camp-software/src/shared/ml/test_suite.json`).** With GPS accuracy of 8 m, the old fixed allowance gave every sighting 8 + 10 = 18 m.

| Phone hears (10 s window) | Model d90 | New circle |
|---|---|---|
| Median −44 dBm, 13 adverts, IQR 3 dB | 1.6 m | 8 + 1.6 = **9.6 m**: tighter, the phone was close |
| Median −53.5 dBm, 12 adverts, IQR 4 dB | 5.8 m | 8 + 5.8 = **13.8 m** |
| Median −71 dBm, 4 adverts, IQR 3 dB | 25.5 m | 8 + 25.5 = **33.5 m**: wider |

The wider circle is the honest answer: the fixed 10 m was overconfident for faint signals.

---

## Limitations

- **One phone, one band.** Phone models can read several dB apart, so `A` only holds for the phone it was measured on. Re-measure `A` for each phone model.
- **Bodies are idealised.** Friends standing in a line aren't a random crowd. Bodies near the band or the phone probably matter more than those in the middle, and the Poisson model ignores that.
- **Carrying position.** The phone in a pocket and the band on a moving dependent add extra loss. Measure a pocket run in the open field and add it as an extra random term if it matters.
- **Placeholder figures.** The sensitivity cut-off and scan chance are guesses until measured.
