# ml-model: signal strength to distance (d90)

Trains the model the camp software uses to size the "last seen" circle: from the signal a phone heard
in one 10 s window, predict the distance the band is within with 90% confidence. Method:
[../docs/ml-method.md](../docs/ml-method.md).

| Path | What |
|---|---|
| `rssi/open/`, `rssi/body/` | **Real field recordings** (Pixel 8 + ESP32-C3 band, Oct 2026): 36 open-field runs (1–30 m, phone held / in pocket) and 28 body-stacking runs (0–9 people between band and phone at 10 m). One CSV per run (`time,beacon_id,rssi_dbm,address`) plus `runs.csv` with the labels. |
| `build_dataset.py` | Steps 1–4: fits path loss, pocket loss and the body-loss curve from the recordings, then simulates 50,000 labelled crowd windows (windows where the phone hears nothing are dropped, leaving 33,679 rows for `fitted`). |
| `train.py` | Step 5: trains a gradient-boosted quantile regressor (α = 0.9) and a mean model on each simulated dataset. |
| `evaluate_holdout.py` | Step 6: scores every model on real open-field session 3, which no earlier step reads. |
| `export_model.py` | Step 7: exports the trees to JSON plus a parity test suite for the TypeScript runtime. |
| `out/fitted/`, `out/cap25/` | Two dataset variants (body loss fitted vs. capped at 25 dB): `params.json` (fitted physics), `dataset.csv` (the simulated training data), `report.md`, `metrics.json`. |
| `out/train_report.md`, `out/holdout_report.md`, `out/holdout_windows.csv` | Results. |

**Shipped model:** `fitted` d90, 69 trees. On the real holdout it covers 82.9% of windows (target 90%)
with RMSE 8.6 m and adj. R² 0.283, against the old fixed 10 m allowance at 68.6% coverage and
adj. R² −0.008.

## Reproduce

```
python -m venv .venv
.venv/Scripts/pip install -r requirements.txt      # Linux/macOS: .venv/bin/...
.venv/Scripts/python build_dataset.py              # -> out/<variant>/params.json, dataset.csv, report.md
.venv/Scripts/python train.py                      # -> out/<variant>/*.joblib, out/train_report.md
.venv/Scripts/python evaluate_holdout.py           # -> out/holdout_report.md
.venv/Scripts/python export_model.py               # -> out/fitted/model_d90_exported.json, test_suite.json
```

Everything is seeded (seed 1), so the outputs are repeatable. The `*.joblib` files are not committed:
`train.py` rebuilds them.

To ship a retrained model, copy `out/fitted/model_d90_exported.json` and `out/fitted/test_suite.json`
into `camp-software/src/shared/ml/`, then run `npm test` there.
