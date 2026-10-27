"""Step 7 of docs/ml-method.md: export the fitted d90 model for the camp app.

Usage:  .venv/Scripts/python export_model.py
Reads:  out/fitted/model_d90.joblib (from train.py)
Writes: out/fitted/model_d90_exported.json, out/fitted/test_suite.json

Then copy both files into camp-software/src/shared/ml/. The camp app
evaluates the trees in TypeScript (src/shared/mlDistanceModel.ts) and its test checks the
predictions against test_suite.json, so a retrained model that drifts from scikit-learn fails there.
"""

import json
from pathlib import Path

import joblib
import numpy as np
import pandas as pd

OUT = Path(__file__).parent / "out" / "fitted"
FEATURES = ["median_rssi", "n_heard", "iqr"]

# Inputs for the parity test: a spread of strong/weak signals, sparse windows, and flat spread.
# Expected values are recomputed from the model on every export.
TEST_INPUTS = [
    [-44.0, 13, 3.0], [-46.2, 7, 3.5], [-53.5, 12, 4.0], [-51.2, 6, 2.5],
    [-67.2, 10, 5.0], [-61.5, 8, 4.5], [-69.2, 5, 5.5], [-66.5, 7, 4.0],
    [-71.0, 4, 3.0], [-72.0, 3, 2.0], [-69.5, 6, 6.0], [-89.0, 2, 4.0],
    [-50.0, 1, 0.0], [-70.0, 1, 0.0], [-90.0, 1, 0.0], [-97.0, 0, 0.0],
]


def main():
    model = joblib.load(OUT / "model_d90.joblib")
    baseline = float(np.ravel(model._baseline_prediction)[0])
    trees = []
    for stage in model._predictors:
        nodes = stage[0].nodes  # one tree per stage for a regressor
        trees.append([
            dict(value=float(n["value"]), feature_idx=int(n["feature_idx"]),
                 threshold=float(n["num_threshold"]), left=int(n["left"]),
                 right=int(n["right"]), is_leaf=bool(n["is_leaf"]))
            for n in nodes
        ])
    exported = dict(baseline=round(baseline, 4), features=FEATURES, n_trees=len(trees), trees=trees)
    (OUT / "model_d90_exported.json").write_text(json.dumps(exported, indent=2))

    # Use the rounded baseline so the file is self-consistent with what the app adds up.
    pred = model.predict(pd.DataFrame(TEST_INPUTS, columns=FEATURES))
    suite = dict(baseline=exported["baseline"],
                 test_cases=[dict(features=f, expected=round(float(p), 4))
                             for f, p in zip(TEST_INPUTS, pred)])
    (OUT / "test_suite.json").write_text(json.dumps(suite, indent=2))
    print(f"exported {len(trees)} trees, baseline {exported['baseline']}")


if __name__ == "__main__":
    main()
