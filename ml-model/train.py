"""Step 5 of docs/ml-method.md: train the d90 model on each simulated dataset.

Usage:  .venv/Scripts/python train.py
Reads:  out/<variant>/dataset.csv (from build_dataset.py)
Writes: out/<variant>/model_d90.joblib, model_mean.joblib, metrics.json; out/train_report.md

80/20 train/test split; 5-fold CV on the 80% picks the settings; the 20% is scored once.
The real open-field holdout (step 6) is not touched here.
"""

import json
import sys

import joblib
import pandas as pd
from sklearn.ensemble import HistGradientBoostingRegressor
from sklearn.metrics import make_scorer, mean_pinball_loss
from sklearn.model_selection import GridSearchCV, KFold, train_test_split

from common import FEATURES, OUT, SEED, VARIANTS, scores

# Stronger signal -> smaller circle; more adverts heard -> smaller circle; IQR free.
MONOTONIC = [-1, -1, 0]
ALPHA = 0.9
GRID = dict(learning_rate=[0.03, 0.1], max_leaf_nodes=[8, 31], min_samples_leaf=[20, 100])


def fit(X, y, loss):
    kw = dict(quantile=ALPHA) if loss == "quantile" else {}
    scoring = (make_scorer(mean_pinball_loss, alpha=ALPHA, greater_is_better=False)
               if loss == "quantile" else "neg_root_mean_squared_error")
    search = GridSearchCV(
        HistGradientBoostingRegressor(loss=loss, monotonic_cst=MONOTONIC, max_iter=300,
                                      random_state=SEED, **kw),
        GRID, cv=KFold(5, shuffle=True, random_state=SEED), scoring=scoring, n_jobs=-1)
    search.fit(X, y)
    return search


def main():
    results = {}
    for name in VARIANTS:
        ds = pd.read_csv(OUT / name / "dataset.csv")
        X_tr, X_te, y_tr, y_te = train_test_split(ds[FEATURES], ds["d"], test_size=0.2,
                                                  random_state=SEED)
        res = dict(n_train=len(X_tr), n_test=len(X_te))
        # d90 is the model the plan uses. The mean model is only a reference: RMSE and
        # R^2 measure how close a prediction is to the true distance, which d90 is
        # deliberately not (it sits above the truth 90% of the time).
        for label, loss in [("d90", "quantile"), ("mean", "squared_error")]:
            search = fit(X_tr, y_tr, loss)
            res[label] = dict(best_params=search.best_params_,
                              cv_score=float(-search.best_score_),
                              test=scores(y_te.to_numpy(), search.predict(X_te), len(FEATURES), ALPHA))
            joblib.dump(search.best_estimator_, OUT / name / f"model_{label}.joblib")
        (OUT / name / "metrics.json").write_text(json.dumps(res, indent=2))
        results[name] = res

    rows = []
    for name, res in results.items():
        for label in ["d90", "mean"]:
            t = res[label]["test"]
            rows.append(f"| {name} | {label} | {res['n_test']} | {t['rmse']:.2f} | {t['adj_r2']:.3f} "
                        f"| {t['coverage']:.1%} | {t['pinball']:.3f} | {t['mean_pred']:.1f} "
                        f"| {res[label]['cv_score']:.3f} |")
    report = "\n".join([
        "# Training report (simulated 20% test split)",
        "",
        "| dataset | model | test rows | RMSE (m) | adj. R² | coverage (d ≤ pred) | pinball | mean prediction (m) | CV score* |",
        "|---|---|---|---|---|---|---|---|---|",
        *rows,
        "",
        "*CV score on the 80%: pinball loss for d90, RMSE for mean. Used only to choose settings.",
        "",
        "Best settings: " + "; ".join(f"{n} {l}: {results[n][l]['best_params']}"
                                      for n in results for l in ["d90", "mean"]),
    ])
    (OUT / "train_report.md").write_text(report, encoding="utf-8")
    sys.stdout.reconfigure(encoding="utf-8")
    print(report)


if __name__ == "__main__":
    main()
