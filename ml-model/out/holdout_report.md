# Holdout report: real open-field session 3

12 runs, 70 windows of 10 s (2 empty windows dropped). Never used for fitting, tuning or training.

| Method | RMSE (m) | adj. R² | coverage (95% range, by run) | mean radius (m) |
|---|---|---|---|---|
| Fixed 10 m (today) | 10.38 | -0.008 | 68.6% (43%-93%) | 10.0 |
| Formula d_upper | 315.14 | -942.372 | 98.6% (96%-100%) | 119.6 |
| fitted d90 | 8.56 | 0.283 | 82.9% (60%-100%) | 16.0 |
| fitted mean (reference) | 7.72 | 0.416 | 57.1% (32%-81%) | 8.2 |
| cap25 d90 | 8.49 | 0.295 | 82.9% (60%-100%) | 16.0 |
| cap25 mean (reference) | 7.39 | 0.466 | 38.6% (19%-59%) | 7.8 |

Coverage = share of windows with true distance ≤ predicted radius (target 90% for d90).
Adjusted R² uses p = number of inputs (0 for fixed, 1 for formula, 3 for the models).

## Median prediction by true distance

| true d (m) | phone | windows | median RSSI | formula | fitted d90 | cap25 d90 |
|---|---|---|---|---|---|---|
| 1 | held | 6 | -44.0 | 1.7 | 1.6 | 1.7 |
| 1 | pocket | 6 | -46.2 | 2.3 | 1.6 | 2.1 |
| 2 | held | 6 | -53.5 | 6.6 | 5.4 | 4.3 |
| 2 | pocket | 6 | -51.2 | 4.7 | 3.6 | 3.4 |
| 5 | held | 6 | -67.2 | 46.2 | 21.7 | 22.5 |
| 5 | pocket | 6 | -61.5 | 20.3 | 19.1 | 17.4 |
| 10 | held | 6 | -69.2 | 61.6 | 19.9 | 18.0 |
| 10 | pocket | 6 | -66.5 | 41.6 | 19.0 | 19.0 |
| 20 | held | 6 | -71.0 | 79.0 | 24.8 | 25.1 |
| 20 | pocket | 5 | -72.0 | 91.2 | 25.2 | 25.1 |
| 30 | held | 6 | -69.5 | 63.9 | 25.3 | 25.2 |
| 30 | pocket | 5 | -89.0 | 1039.0 | 25.2 | 26.8 |