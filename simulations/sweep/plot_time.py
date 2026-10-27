"""Charts from the sweep results (Bluetooth range is the same at every density).
  python plot_time.py [--target 99] [--within 90] [--installs 0.25,0.5,1,2,5] [--tmax 240]

1. time_heatmap_p<pct>_i<installed %>.png : one per install rate. Median minutes to locate <target>% of watches for
   every range and density. Contours at 10, 30 and <within> min; hatched = not reached in the time limit.
2. min_range_p<pct>.png : the smallest Bluetooth range that locates <target>% of watches within <within> min
   for the median crowd, against crowd density, one line per install rate.
Reads results_p<pct>[_i<installed %>].csv written by sweep.js; install rates with no file are skipped.
"""
import csv, os, sys
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.colors import LogNorm

def arg(name, default):
    return type(default)(sys.argv[sys.argv.index("--" + name) + 1]) if "--" + name in sys.argv else default

PCT, WITHIN, TMAX = arg("target", 99), arg("within", 90), arg("tmax", 240)
INSTALLS = [float(x) for x in arg("installs", "0.25,0.5,1,2,5").split(",")]
here = os.path.dirname(os.path.abspath(__file__))
foot = "Same Bluetooth range at every density; every watch works; v3 defaults otherwise. Median of 20 crowds."


def load(inst):
    """{(range, density): median minutes (inf = not reached)} or None if there is no file"""
    p = os.path.join(here, f"results_p{PCT}" + ("" if inst == 1 else f"_i{inst:g}") + ".csv")
    if not os.path.exists(p):
        return None
    return {(float(d["range_ref_m"]), float(d["density"])):
            float("inf") if d["median_t_target_min"] == "inf" else float(d["median_t_target_min"])
            for d in csv.DictReader(open(p))}


data = {i: load(i) for i in INSTALLS}
for i, d in data.items():
    if d is None:
        print(f"no results file for {i:g}% installed, skipped")
data = {i: d for i, d in data.items() if d is not None}
R = sorted({k[0] for d in data.values() for k in d}); D = sorted({k[1] for d in data.values() for k in d})


def heatmap(inst, base):
    Z = [[base[(r, d)] for r in R] for d in D]
    fig, ax = plt.subplots(figsize=(10, 7.5))
    masked = [[v if v != float("inf") else float("nan") for v in row] for row in Z]
    im = ax.imshow(masked, origin="lower", aspect="auto", cmap="viridis_r", norm=LogNorm(vmin=1, vmax=TMAX))
    for i, row in enumerate(Z):
        for j, v in enumerate(row):
            if v == float("inf"):
                ax.add_patch(plt.Rectangle((j - .5, i - .5), 1, 1, fill=False, hatch="///", edgecolor="grey", lw=0))
                ax.text(j, i, f">{TMAX}", ha="center", va="center", fontsize=7)
            else:
                ax.text(j, i, f"{v:.0f}" if v >= 1 else "<1", ha="center", va="center", fontsize=7, color="white" if v < 40 else "black")
    levels = sorted({10, 30, WITHIN})
    try:
        cs = ax.contour(range(len(R)), range(len(D)), [[min(v, TMAX * 2) for v in row] for row in Z], levels=levels, colors="red",
                        linewidths=[2.4 if l == WITHIN else 1 for l in levels])
        ax.clabel(cs, fmt=lambda v: f"{v:.0f} min", fontsize=8)
    except Exception:
        pass  # a level with no crossing can't be drawn
    ax.set_xticks(range(len(R))); ax.set_xticklabels([f"{r:g}" for r in R])
    ax.set_yticks(range(len(D))); ax.set_yticklabels([f"{d:g}" for d in D])
    ax.set_xlabel("Bluetooth range (m), same at every density"); ax.set_ylabel("Crowd density (people/m²)")
    ax.set_title(f"Minutes to locate {PCT}% of watches ({inst:g}% of phones have the app)\nthick red line = {WITHIN} min", fontsize=11)
    fig.colorbar(im, ax=ax, label="minutes (log scale)")
    fig.text(0.01, 0.01, foot, fontsize=7, color="#555")
    fig.tight_layout(rect=(0, 0.03, 1, 1))
    fig.savefig(os.path.join(here, f"time_heatmap_p{PCT}_i{inst:g}.png"), dpi=140)
    plt.close(fig)


for inst, d in data.items():
    heatmap(inst, d)


# ---- minimum range needed ----
def min_range(t_of_r, rs):
    """smallest range from which every larger range meets the deadline, interpolated between grid points.
    Returns (value, flag): flag 'gt' = even the largest range fails, 'le' = even the smallest range passes."""
    fails = [i for i, r in enumerate(rs) if t_of_r[r] > WITHIN]
    if not fails:
        return rs[0], "le"
    i = fails[-1]
    if i == len(rs) - 1:
        return rs[-1], "gt"
    ti, tj = t_of_r[rs[i]], t_of_r[rs[i + 1]]
    frac = 1.0 if ti == float("inf") else (ti - WITHIN) / (ti - tj)
    return rs[i] + frac * (rs[i + 1] - rs[i]), "ok"


fig, ax = plt.subplots(figsize=(8.5, 5.5))
out = {}
for inst, dd in data.items():
    xs, ys, fl = [], [], []
    for d in D:
        v, f = min_range({r: dd[(r, d)] for r in R}, R)
        xs.append(d); ys.append(v); fl.append(f)
    out[inst] = list(zip(xs, ys, fl))
    line, = ax.plot(xs, ys, "-", lw=1.8, label=f"{inst:g}% of phones have the app")
    for x, y, f in zip(xs, ys, fl):
        if f != "ok":
            ax.plot(x, y, "^" if f == "gt" else "v", color=line.get_color(), ms=7)
ax.set_xticks([0, 1, 2, 3, 4, 5]); ax.set_yticks(range(0, 31, 5)); ax.set_ylim(0, 32)
ax.set_xlabel("Crowd density (people/m²)"); ax.set_ylabel("Bluetooth range needed (m), same at every density")
ax.set_title(f"Range needed to locate {PCT}% of watches within {WITHIN} min\n▲ = even {R[-1]:g} m is not enough, ▼ = even {R[0]:g} m is enough", fontsize=11)
ax.grid(alpha=.3); ax.legend(fontsize=9)
fig.text(0.01, 0.01, foot + f" Pass = median crowd reaches {PCT}% within {WITHIN} min.", fontsize=7, color="#555")
fig.tight_layout(rect=(0, 0.03, 1, 1))
fig.savefig(os.path.join(here, f"min_range_p{PCT}.png"), dpi=140)
for inst, pts in out.items():
    print(f"installed {inst:g}%: " + ", ".join(f"{d:g}/m2 -> {'>' if f=='gt' else '<=' if f=='le' else ''}{v:.1f}" for d, v, f in pts))
