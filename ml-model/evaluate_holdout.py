"""Step 6 of docs/ml-method.md: test on the real open-field holdout runs.

Usage:  .venv/Scripts/python evaluate_holdout.py
Reads:  rssi/open/ runs with role == holdout (session 3), out/<variant>/*.joblib, params.json
Writes: out/holdout_report.md, out/holdout_windows.csv

Each 60 s run is cut into 10 s windows, the same length the app uses. Windows from one
run share a set-up, so coverage ranges come from resampling whole runs.
"""

import json
import sys

import joblib
import numpy as np
import pandas as pd

from build_dataset import cut_windows, load_runs
from common import FEATURES, OUT, SEED, VARIANTS, scores


def run_bootstrap(win, col, n_boot=5000):
    """95% range of coverage, resampling whole runs."""
    rng = np.random.default_rng(SEED)
    per_run = win.assign(hit=win["distance_m"] <= win[col]).groupby("run")["hit"].agg(["sum", "size"])
    idx = rng.integers(0, len(per_run), (n_boot, len(per_run)))
    cov = per_run["sum"].to_numpy()[idx].sum(1) / per_run["size"].to_numpy()[idx].sum(1)
    return np.percentile(cov, [2.5, 97.5])


def main():
    runs, adv = load_runs("open", lambda r: r["role"] == "holdout")
    win = cut_windows(adv, 60).merge(runs[["run", "distance_m", "phone_position"]], on="run")
    empty = win["n_heard"] == 0
    win = win[~empty].reset_index(drop=True)  # the app never uploads an empty window

    # Baselines. Formula = the log-distance d_upper formula (docs/ml-method.md) with the open-field fit (held A,
    # no pocket term, sigma = between-run scatter): no ML.
    p = json.loads((OUT / "fitted" / "params.json").read_text())
    win["fixed10"] = 10.0
    win["formula"] = 10 ** ((p["A"] - win["median_rssi"] + 1.28 * p["sigma_run"]) / (10 * p["n"]))
    methods = [("Fixed 10 m (today)", "fixed10", 0), ("Formula d_upper", "formula", 1)]
    for name in VARIANTS:
        for label in ["d90", "mean"]:
            model = joblib.load(OUT / name / f"model_{label}.joblib")
            win[f"{name}_{label}"] = model.predict(win[FEATURES])
            methods.append((f"{name} {label}" + (" (reference)" if label == "mean" else ""),
                            f"{name}_{label}", len(FEATURES)))

    y = win["distance_m"].to_numpy(float)
    rows = []
    for title, col, k in methods:
        s = scores(y, win[col].to_numpy(), k)
        lo, hi = run_bootstrap(win, col)
        rows.append(f"| {title} | {s['rmse']:.2f} | {s['adj_r2']:.3f} | {s['coverage']:.1%} "
                    f"({lo:.0%}-{hi:.0%}) | {s['mean_pred']:.1f} |")

    by_d = win.groupby(["distance_m", "phone_position"]).agg(
        windows=("run", "size"), median_rssi=("median_rssi", "median"),
        **{f"{c}": (c, "median") for c in ["formula", "fitted_d90", "cap25_d90"]}).reset_index()
    by_d_rows = [f"| {r.distance_m:g} | {r.phone_position} | {r.windows} | {r.median_rssi:.1f} "
                 f"| {r.formula:.1f} | {r.fitted_d90:.1f} | {r.cap25_d90:.1f} |"
                 for r in by_d.itertuples()]

    report = "\n".join([
        "# Holdout report: real open-field session 3",
        "",
        f"{len(runs)} runs, {len(win)} windows of 10 s ({int(empty.sum())} empty windows dropped). "
        "Never used for fitting, tuning or training.",
        "",
        "| Method | RMSE (m) | adj. R² | coverage (95% range, by run) | mean radius (m) |",
        "|---|---|---|---|---|",
        *rows,
        "",
        "Coverage = share of windows with true distance ≤ predicted radius (target 90% for d90).",
        "Adjusted R² uses p = number of inputs (0 for fixed, 1 for formula, 3 for the models).",
        "",
        "## Median prediction by true distance",
        "",
        "| true d (m) | phone | windows | median RSSI | formula | fitted d90 | cap25 d90 |",
        "|---|---|---|---|---|---|---|",
        *by_d_rows,
    ])
    win.round(3).to_csv(OUT / "holdout_windows.csv", index=False)
    (OUT / "holdout_report.md").write_text(report, encoding="utf-8")
    sys.stdout.reconfigure(encoding="utf-8")
    print(report)


if __name__ == "__main__":
    main()
