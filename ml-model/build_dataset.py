"""Steps 1-4 of docs/ml-method.md: fit the signal parameters from the
field-test CSVs, then simulate the labelled upload-window dataset.

Usage:  python build_dataset.py [--windows 50000] [--seed 1]
Reads:  rssi/open/*.csv, rssi/body/*.csv (field-test panel exports)
Writes: out/<variant>/params.json, dataset.csv, report.md for each entry in VARIANTS

Holdout rule: open-field runs with role == holdout (session 3) are never opened here.
They are kept for step 6.
"""

import argparse
import json
from datetime import datetime
from pathlib import Path

import numpy as np
import pandas as pd

ROOT = Path(__file__).parent
DATA = ROOT / "rssi"
OUT = ROOT / "out"

# ---- Fixed by the hardware / app, not fitted --------------------------------
WINDOW_S = 10.0          # app uploads at most once per beacon per 10 s (lib/ble/throttle.dart)
ADV_INTERVAL_S = 0.125   # firmware advertises every 100-150 ms (beacon.ino ADV_MIN/ADV_MAX)
ADVERTS_PER_WINDOW = int(round(WINDOW_S / ADV_INTERVAL_S))  # 80

# ---- Assumptions: no measurement exists for these yet -----------------------
# Step 3 path width (m). No crowd test, so a physics estimate: a person blocks if they
# stand in the first Fresnel zone around the line, about 0.5-1 m across at 2.4 GHz
# over these distances. 0.5 is the low end of that range.
W_PATH = 0.5
SENSITIVITY_DBM = -97.0  # weakest advert the phone reports; field data never got this faint
P_POCKET = 0.7           # share of windows where the phone is in a pocket
# Empty-area windows: nobody between band and phone (venue edges, paths, quiet hours).
# Without them the simulator almost never makes a far window with zero bodies, so the
# model would read an open-field -70 dBm at 30 m as "5-10 m through a crowd".
P_EMPTY = 0.15
# Body runs marked valid but 11-14 dB below the curve; dropped by the user's call.
# B14 (k=0) also heard only 29 adverts with a 52 s silent gap.
BODY_EXCLUDE = ["B14", "B17", "B18", "B21"]
# Two datasets that differ only in the body-loss ceiling. The 0-9 body runs can't show
# where the loss levels off, so step 6 compares a model trained on each.
VARIANTS = {"fitted": None,   # Lmax from the fit (about 42 dB, close to a straight line)
            "cap25": 25.0}    # Lmax fixed at 25 dB: the plan's "loss levels off" assumption
D_RANGE = (0.5, 30.0)
RHO_RANGE = (0.5, 5.0)


def robust_sd(x):
    x = np.asarray(x, float)
    return float(1.4826 * np.median(np.abs(x - np.median(x))))


def load_runs(kind, keep):
    runs = pd.read_csv(DATA / kind / "runs.csv")
    runs = runs[(runs["valid"] == "y") & keep(runs)].copy()
    frames = []
    for r in runs.itertuples():
        name = r.run if r.attempt == 1 else f"{r.run}_{r.attempt}"
        adv = pd.read_csv(DATA / kind / f"{name}.csv", parse_dates=["time"])
        adv = adv[adv["beacon_id"] == r.beacon_id]
        start = datetime.fromisoformat(r.start_time)
        adv["t"] = (adv["time"] - start).dt.total_seconds()
        adv["run"] = r.run
        frames.append(adv)
    return runs, pd.concat(frames, ignore_index=True)


def cut_windows(adv, duration_s):
    """Split each run into consecutive WINDOW_S windows, as the app would."""
    n_win = int(duration_s // WINDOW_S)
    adv = adv[(adv["t"] >= 0) & (adv["t"] < n_win * WINDOW_S)].copy()
    adv["win"] = (adv["t"] // WINDOW_S).astype(int)
    rows = []
    for run, g in adv.groupby("run"):
        for w in range(n_win):
            x = g.loc[g["win"] == w, "rssi_dbm"].to_numpy(float)
            rows.append(dict(run=run, win=w, n_heard=len(x),
                             median_rssi=np.median(x) if len(x) else np.nan,
                             iqr=np.subtract(*np.percentile(x, [75, 25])) if len(x) else np.nan))
    return pd.DataFrame(rows)


def beta_moments(p):
    """Beta(a, b) with the same mean and variance as the observed per-window hear rates."""
    m, v = float(np.mean(p)), float(np.var(p, ddof=1))
    common = m * (1 - m) / v - 1 if v > 0 else 1e3
    return m * common, (1 - m) * common


def loss_curve(k, lmax, k0):
    return lmax * (1 - np.exp(-np.asarray(k, float) / k0))


# ---- Step 1: open field ------------------------------------------------------
def fit_open():
    runs, adv = load_runs("open", lambda r: r["role"] == "fit")
    assert (runs["role"] == "fit").all()
    med = adv.groupby("run")["rssi_dbm"].median().rename("median")
    runs = runs.join(med, on="run")
    pocket = (runs["phone_position"] == "pocket").to_numpy(float)
    x = np.log10(runs["distance_m"].to_numpy(float))
    # median = A - 10 n log10(d) - pocket_loss * pocket   (shared A and n)
    X = np.column_stack([np.ones_like(x), -10 * x, -pocket])
    (A, n, pocket_loss), *_ = np.linalg.lstsq(X, runs["median"].to_numpy(), rcond=None)
    runs["resid"] = runs["median"] - X @ [A, n, pocket_loss]

    adv = adv.join(med, on="run")
    sigma_adv = robust_sd(adv["rssi_dbm"] - adv["median"])
    sigma_run = float(np.sqrt(np.sum(runs["resid"] ** 2) / (len(runs) - 3)))

    win = cut_windows(adv, 60).merge(runs[["run", "distance_m", "phone_position"]], on="run")
    hear = {}
    for pos, g in win.groupby("phone_position"):
        p = np.clip(g["n_heard"] / ADVERTS_PER_WINDOW, 1e-3, 1)
        a, b = beta_moments(p)
        hear[pos] = dict(mean=float(p.mean()), a=a, b=b,
                         heard_per_window=float(g["n_heard"].mean()))
    return dict(A=float(A), n=float(n), pocket_loss=float(pocket_loss),
                sigma_open=sigma_adv, sigma_run=sigma_run, hear=hear,
                min_rssi_seen=float(adv["rssi_dbm"].min())), runs, win


# ---- Step 2: body stacking ---------------------------------------------------
def fit_body(lmax_cap=None):
    runs, adv = load_runs("body", lambda r: (r["distance_m"] == 10) & ~r["run"].isin(BODY_EXCLUDE))
    med = adv.groupby("run")["rssi_dbm"].median().rename("median")
    runs = runs.join(med, on="run")
    k = runs["bodies_k"].to_numpy(float)
    y = runs["median"].to_numpy(float)
    # median = B - Lmax (1 - exp(-k/k0)); grid over k0, linear least squares for B and Lmax.
    # B is one shared baseline: the per-session k = 0 runs scatter too much to subtract.
    best = None
    # With lmax_cap set, Lmax is fixed at the cap and only B and k0 are fitted.
    for k0 in np.arange(0.2, 30.0, 0.05):
        shape = 1 - np.exp(-k / k0)
        if lmax_cap is None:
            X = np.column_stack([np.ones_like(k), -shape])
            coef, *_ = np.linalg.lstsq(X, y, rcond=None)
            pred = X @ coef
        else:
            coef = [float(np.mean(y + lmax_cap * shape)), lmax_cap]
            pred = coef[0] - lmax_cap * shape
        sse = float(np.sum((y - pred) ** 2))
        if best is None or sse < best[0]:
            best = (sse, k0, *coef)
    sse, k0, B, lmax = best
    runs["fit"] = B - loss_curve(k, lmax, k0)
    runs["resid"] = y - runs["fit"]

    adv = adv.join(med, on="run").merge(runs[["run", "bodies_k"]], on="run")
    blocked = adv[adv["bodies_k"] > 0]
    sigma_body = robust_sd(blocked["rssi_dbm"] - blocked["median"])
    sigma_run_body = float(np.sqrt(sse / (len(runs) - (3 if lmax_cap is None else 2))))
    return dict(B=float(B), Lmax=float(lmax), k0=float(k0),
                sigma_body=sigma_body, sigma_run_body=sigma_run_body), runs


# ---- Step 4: simulate --------------------------------------------------------
def simulate(p, n_windows, rng):
    d = rng.uniform(*D_RANGE, n_windows)
    rho = rng.uniform(*RHO_RANGE, n_windows)
    rho[rng.random(n_windows) < P_EMPTY] = 0.0
    k = rng.poisson(rho * W_PATH * d)
    pocket = rng.random(n_windows) < P_POCKET
    hp, hh = p["hear"]["pocket"], p["hear"]["held"]
    p_hear = np.where(pocket, rng.beta(hp["a"], hp["b"], n_windows),
                      rng.beta(hh["a"], hh["b"], n_windows))
    # Between-window shift (set-up, orientation, multipath) fixed for the window;
    # per-advert noise on top. The plan only had the per-advert term; the field
    # data shows run medians moving several dB between sessions, so both are kept.
    sigma_run = np.where(k > 0, max(p["sigma_run"], p["sigma_run_body"]), p["sigma_run"])
    offset = rng.normal(0, 1, n_windows) * sigma_run
    sigma_adv = np.where(k > 0, p["sigma_body"], p["sigma_open"])

    mean = (p["A"] - 10 * p["n"] * np.log10(d) - p["pocket_loss"] * pocket
            - loss_curve(k, p["Lmax"], p["k0"]) + offset)
    rssi = mean[:, None] + rng.normal(0, 1, (n_windows, ADVERTS_PER_WINDOW)) * sigma_adv[:, None]
    rssi = np.round(rssi)  # phones report whole dBm
    kept = (rssi > SENSITIVITY_DBM) & (rng.random(rssi.shape) < p_hear[:, None])
    vals = np.where(kept, rssi, np.nan)
    n_heard = kept.sum(1)
    ok = n_heard > 0  # a window with nothing heard never uploads
    vals = vals[ok]
    q25, q50, q75 = np.nanpercentile(vals, [25, 50, 75], axis=1)
    return pd.DataFrame(dict(
        median_rssi=q50, n_heard=n_heard[ok], iqr=q75 - q25, d=d[ok],
        # hidden truth for diagnostics only; not model inputs
        rho=rho[ok], k=k[ok], pocket=pocket[ok].astype(int), offset_db=offset[ok],
    )), int((~ok).sum())


def sim_check(p, win_open, runs_open, rng):
    """Simulate k = 0 windows at each fit run's distance/position, compare with the real windows."""
    rows = []
    for (dist, pos), g in win_open.groupby(["distance_m", "phone_position"]):
        q = dict(p, hear={pos: p["hear"][pos], "held": p["hear"][pos], "pocket": p["hear"][pos]})
        m = 20000
        pocket = pos == "pocket"
        hp = q["hear"][pos]
        ph = rng.beta(hp["a"], hp["b"], m)
        mean = (p["A"] - 10 * p["n"] * np.log10(dist) - p["pocket_loss"] * pocket
                + rng.normal(0, p["sigma_run"], m))
        r = np.round(mean[:, None] + rng.normal(0, p["sigma_open"], (m, ADVERTS_PER_WINDOW)))
        kept = (r > SENSITIVITY_DBM) & (rng.random(r.shape) < ph[:, None])
        v = np.where(kept, r, np.nan)[kept.any(1)]
        rows.append(dict(distance_m=dist, position=pos,
                         real_median=g["median_rssi"].median(), sim_median=np.nanmedian(np.nanmedian(v, 1)),
                         real_heard=g["n_heard"].mean(), sim_heard=kept.sum(1).mean(),
                         real_iqr=g["iqr"].median(), sim_iqr=np.nanmedian(
                             np.subtract(*np.nanpercentile(v, [75, 25], axis=1)))))
    return pd.DataFrame(rows)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--windows", type=int, default=50000)
    ap.add_argument("--seed", type=int, default=1)
    args = ap.parse_args()
    open_p, runs_open, win_open = fit_open()
    for name, cap in VARIANTS.items():
        build(name, cap, args, open_p, runs_open, win_open)


def build(name, lmax_cap, args, open_p, runs_open, win_open):
    # Same seed for every variant, so the datasets differ only in the body-loss curve.
    rng = np.random.default_rng(args.seed)
    out = OUT / name
    out.mkdir(parents=True, exist_ok=True)

    body_p, runs_body = fit_body(lmax_cap)
    params = dict(**open_p, **body_p, variant=name, lmax_cap=lmax_cap, w=W_PATH,
                  sensitivity_dbm=SENSITIVITY_DBM, p_pocket=P_POCKET, p_empty=P_EMPTY, window_s=WINDOW_S,
                  adverts_per_window=ADVERTS_PER_WINDOW, d_range=D_RANGE, rho_range=RHO_RANGE,
                  body_exclude=BODY_EXCLUDE, seed=args.seed,
                  assumed=["w", "sensitivity_dbm", "p_pocket", "p_empty", "rho_range"]
                  + (["Lmax"] if lmax_cap is not None else []))
    (out / "params.json").write_text(json.dumps(params, indent=2))

    ds, dropped = simulate(params, args.windows, rng)
    ds.round(3).to_csv(out / "dataset.csv", index=False)
    check = sim_check(params, win_open, runs_open, rng)

    def f(df):
        fmt = lambda v: f"{v:.1f}" if isinstance(v, (float, np.floating)) else str(v)
        lines = ["| " + " | ".join(map(str, df.columns)) + " |", "|" + "---|" * len(df.columns)]
        lines += ["| " + " | ".join(fmt(v) for v in row) + " |" for row in df.itertuples(index=False)]
        return "\n".join(lines)
    curve = ("Lmax fitted to the data." if lmax_cap is None else
             f"Lmax fixed at {lmax_cap:.0f} dB (assumption: loss levels off); only B and k0 fitted.")
    report = f"""# Dataset build report: `{name}`

Generated by `build_dataset.py` (seed {args.seed}). Open-field holdout runs (session 3) were not read.
Body-loss curve: {curve}

## Step 1: open field (fit runs, sessions 1-2)

`RSSI = A - 10 n log10(d) - pocket_loss * pocket`

| A (dBm @ 1 m) | n | pocket loss (dB) | sigma per advert | sigma between runs | weakest advert seen |
|---|---|---|---|---|---|
| {open_p['A']:.1f} | {open_p['n']:.2f} | {open_p['pocket_loss']:.1f} | {open_p['sigma_open']:.1f} | {open_p['sigma_run']:.1f} | {open_p['min_rssi_seen']:.0f} |

Adverts heard per {WINDOW_S:.0f} s window (beacon sends about {ADVERTS_PER_WINDOW}):
held {open_p['hear']['held']['heard_per_window']:.1f}, pocket {open_p['hear']['pocket']['heard_per_window']:.1f}.

{f(runs_open[['run', 'session', 'distance_m', 'phone_position', 'n_adverts', 'median', 'resid']])}

## Step 2: body stacking at 10 m (all sessions, excluding {', '.join(BODY_EXCLUDE)})

`RSSI = B - Lmax (1 - exp(-k/k0))`

| B (dBm, k=0) | Lmax (dB) | k0 | sigma per advert (k>0) | sigma between runs |
|---|---|---|---|---|
| {body_p['B']:.1f} | {body_p['Lmax']:.1f} | {body_p['k0']:.2f} | {body_p['sigma_body']:.1f} | {body_p['sigma_run_body']:.1f} |

{f(runs_body[['run', 'session', 'bodies_k', 'n_adverts', 'median', 'fit', 'resid']].sort_values(['bodies_k', 'session']))}

## Step 3: crowd calibration

No crowd test was run, so `w` was not tuned on data. `w = {W_PATH}` m is a physics estimate:
the low end of the first Fresnel zone width (about 0.5-1 m at 2.4 GHz over 1-30 m).

## Step 4: simulated dataset

{len(ds)} windows kept, {dropped} dropped with nothing heard. Columns: `median_rssi, n_heard, iqr` (model inputs),
`d` (label), and `rho, k, pocket, offset_db` (hidden truth, diagnostics only).

{f(ds[['d', 'median_rssi', 'n_heard', 'iqr', 'k']].describe().T.reset_index())}

### Sanity check: simulator vs real fit windows (no bodies)

{f(check)}

## Assumed, not measured

- `w = {W_PATH}` m: physics estimate, not measured (no crowd test).
- Body runs {', '.join(BODY_EXCLUDE)} dropped as faulty, though recorded as valid.
- Sensitivity {SENSITIVITY_DBM:.0f} dBm: the weakest single advert in the open-field fit runs was {open_p['min_rssi_seen']:.0f} dBm, but no run's median came near it, so the logs can't show where reception actually stops.
- {P_POCKET:.0%} of windows have the phone in a pocket.
- {P_EMPTY:.0%} of windows are empty areas (density 0, nobody in the path); the rest draw density from {RHO_RANGE[0]}-{RHO_RANGE[1]} people/m².
- Body loss measured at 10 m only; the curve is assumed to hold at every distance (no 5 m or 15 m runs).
- Body loss measured up to 9 bodies; the simulator goes up to about {int(ds['k'].max())}. {curve}
"""
    (out / "report.md").write_text(report, encoding="utf-8")
    print(report)


if __name__ == "__main__":
    main()
