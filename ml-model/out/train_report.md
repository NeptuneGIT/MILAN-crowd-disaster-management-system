# Training report (simulated 20% test split)

| dataset | model | test rows | RMSE (m) | adj. R² | coverage (d ≤ pred) | pinball | mean prediction (m) | CV score* |
|---|---|---|---|---|---|---|---|---|
| fitted | d90 | 6736 | 12.26 | -1.344 | 90.0% | 1.244 | 22.3 | 1.260 |
| fitted | mean | 6736 | 6.71 | 0.299 | 58.8% | 2.720 | 12.4 | 6.678 |
| cap25 | d90 | 9181 | 11.82 | -0.949 | 89.8% | 1.148 | 24.2 | 1.140 |
| cap25 | mean | 9181 | 6.59 | 0.394 | 54.5% | 2.674 | 14.8 | 6.560 |

*CV score on the 80%: pinball loss for d90, RMSE for mean. Used only to choose settings.

Best settings: fitted d90: {'learning_rate': 0.1, 'max_leaf_nodes': 8, 'min_samples_leaf': 100}; fitted mean: {'learning_rate': 0.03, 'max_leaf_nodes': 8, 'min_samples_leaf': 20}; cap25 d90: {'learning_rate': 0.1, 'max_leaf_nodes': 8, 'min_samples_leaf': 20}; cap25 mean: {'learning_rate': 0.1, 'max_leaf_nodes': 8, 'min_samples_leaf': 20}