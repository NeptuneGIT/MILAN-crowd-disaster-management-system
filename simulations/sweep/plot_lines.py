"""graph1 and graph2: time to locate <target>% of watches against Bluetooth range (same range at every density),
one pair per install rate.
  python plot_lines.py [--target 99] [--ceiling 90] [--tmax 240] [--installs 0.25,0.5,1,2,5]
  graph1_p<pct>_i<installed %>.png : at the density where the share found within <ceiling> min is lowest, if that is under 80%
                                     (the worst density for that range); the density is printed beside each point.
  graph2_p<pct>_i<installed %>.png : at the maximum density tested.
Reads results_p<pct>[_i<installed %>].csv (the sweep must have been run with --check <ceiling>).
"""
import csv, os, sys
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.ticker import MultipleLocator

def arg(name, default):
    return type(default)(sys.argv[sys.argv.index("--" + name) + 1]) if "--" + name in sys.argv else default

PCT, CEIL, TMAX = arg("target", 99), arg("ceiling", 90), arg("tmax", 240)
INSTALLS = [float(x) for x in arg("installs", "0.25,0.5,1,2,5").split(",")]
here = os.path.dirname(os.path.abspath(__file__))


def run(inst):
    p = os.path.join(here, f"results_p{PCT}" + ("" if inst == 1 else f"_i{inst:g}") + ".csv")
    if not os.path.exists(p):
        print(f"no results file for {inst:g}% installed, skipped"); return
    rows = [
        dict(r=float(d["range_ref_m"]), rho=float(d["density"]), found=float(d["mean_found_at_check"]),
             t=float("inf") if d["median_t_target_min"] == "inf" else float(d["median_t_target_min"]),
             reached=float(d["share_reached_target"]))
        for d in csv.DictReader(open(p))
    ]
    ranges = sorted({x["r"] for x in rows}); dens = sorted({x["rho"] for x in rows})
    cell = {(x["r"], x["rho"]): x for x in rows}
    maxd = dens[-1]
    foot = f"Same Bluetooth range at every density; {inst:g}% of phones have the app; every watch works; v3 defaults otherwise. Median of 20 crowds."

    def worst_density(r):
        """density with the lowest share found within the ceiling, if under 80%"""
        d = min(dens, key=lambda rho: cell[(r, rho)]["found"])
        return d if cell[(r, d)]["found"] < 0.8 else None

    def draw(fn, title, pick, labelled):
        xs, ys, cens, labels = [], [], [], []
        for r in ranges:
            rho = pick(r)
            if rho is None:
                continue
            c = cell[(r, rho)]
            xs.append(r); labels.append(rho)
            ok = c["reached"] >= 0.5 and c["t"] != float("inf")
            ys.append(c["t"] if ok else TMAX); cens.append(not ok)
        fig, ax = plt.subplots(figsize=(8, 5))
        ax.plot(xs, ys, "-", color="#2b6cb0", lw=1.8)
        for x, y, c, lab in zip(xs, ys, cens, labels):
            ax.plot(x, y, "^" if c else "o", color="#c53030" if c else "#2b6cb0", ms=8 if c else 6)
            if labelled:
                ax.annotate(f"{lab:g}/m²", (x, y), textcoords="offset points", xytext=(0, 9), ha="center", fontsize=8)
        ax.set_xlim(min(ranges) - 1, max(ranges) + 1)  # same x span on every graph, even when graph 1 has few points
        if labelled:
            gone = [f"{r:g}" for r in ranges if worst_density(r) is None]
            if gone and len(gone) < len(ranges):
                ax.text(0.5, 0.45, f"No point for {', '.join(gone)} m:\n80% or more are found within {CEIL} min at every density",
                        transform=ax.transAxes, ha="center", fontsize=9, color="#555")
            elif gone:
                ax.text(0.5, 0.45, f"No point: 80% or more are found within {CEIL} min\nat every range and density",
                        transform=ax.transAxes, ha="center", fontsize=9, color="#555")
        ax.yaxis.set_major_locator(MultipleLocator(20 if TMAX <= 120 else 40))
        ax.set_xlabel("Bluetooth range (m), same at every density")
        ax.set_ylabel(f"Minutes to locate {PCT}% of watches (median of crowds)")
        ax.set_title(title, fontsize=11)
        ax.set_ylim(0, TMAX * 1.1)
        ax.axhline(CEIL, color="#38a169", ls="--", lw=1.2); ax.text(ax.get_xlim()[1], CEIL + 3, f"{CEIL} min ceiling", ha="right", fontsize=8, color="#38a169")
        ax.axhline(TMAX, color="grey", ls=":", lw=1)
        ax.text(ax.get_xlim()[0], TMAX * 1.02, f"{TMAX} min limit (red ▲ = not reached)", fontsize=8, color="grey")
        ax.grid(alpha=.3)
        fig.text(0.01, 0.01, foot, fontsize=7, color="#555")
        fig.tight_layout(rect=(0, 0.04, 1, 1))
        fig.savefig(os.path.join(here, fn), dpi=140)
        plt.close(fig)
        return list(zip(xs, labels, ys, cens))

    a = draw(f"graph1_p{PCT}_i{inst:g}.png", f"At the density where under 80% of watches are found within {CEIL} min ({inst:g}% installed)", worst_density, True)
    b = draw(f"graph2_p{PCT}_i{inst:g}.png", f"At maximum density ({maxd:g} people/m², {inst:g}% installed)", lambda r: maxd, False)
    print(f"--- {inst:g}% installed ---")
    print("graph1 (range, density, minutes, not_reached):"); [print(" ", t) for t in a]
    print("graph2 (range, density, minutes, not_reached):"); [print(" ", t) for t in b]


for inst in INSTALLS:
    run(inst)
