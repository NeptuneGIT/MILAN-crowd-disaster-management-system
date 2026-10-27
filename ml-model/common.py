"""Settings and scoring shared by train.py and evaluate_holdout.py."""

from pathlib import Path

import numpy as np
from sklearn.metrics import mean_pinball_loss, mean_squared_error, r2_score

OUT = Path(__file__).parent / "out"
VARIANTS = ["fitted", "cap25"]
FEATURES = ["median_rssi", "n_heard", "iqr"]
SEED = 1


def scores(y, pred, p, alpha=None):
    """RMSE, R², adjusted R² (p = number of inputs), coverage (y <= pred), mean prediction;
    plus pinball loss at quantile [alpha] when given."""
    n = len(y)
    r2 = r2_score(y, pred)
    out = dict(rmse=float(np.sqrt(mean_squared_error(y, pred))), r2=float(r2),
               adj_r2=float(1 - (1 - r2) * (n - 1) / (n - p - 1)),
               coverage=float(np.mean(y <= pred)), mean_pred=float(np.mean(pred)))
    if alpha is not None:
        out["pinball"] = float(mean_pinball_loss(y, pred, alpha=alpha))
    return out
