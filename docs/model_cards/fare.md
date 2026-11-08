# Model Card — taxi-fare-predictor

_Generated: 2026-11-07 08:36 UTC_

## Model details

- **Problem:** fare
- **Algorithm:** LGBMRegressor
- **Target:** `fare_amount`
- **Registry version:** n/a

## Intended use

Operational forecasting of fare_amount to support fleet positioning and rider fare estimates. Not intended for individual pricing decisions or any use with legal/financial consequences for individuals.

## Evaluation — overall (test split)

| Metric | Value |
|--------|-------|
| rmse | 3.4717 |
| mae | 0.8151 |
| mape | 8.6912 |
| r2 | 0.9550 |

## Evaluation — subgroup fairness

### By borough

Disparity ratio (worst/best RMSE): **8.12** (threshold 1.5) — ⚠️ **flagged**. Worst: `Unknown`, best: `Manhattan`.

| Group | n | RMSE | MAE | MAPE |
|-------|---|------|-----|------|
| Unknown | 815 | 18.418 | 3.352 | 12.60 |
| Bronx | 580 | 10.251 | 6.148 | 452.63 |
| Brooklyn | 1946 | 8.942 | 4.799 | 18.48 |
| Queens | 23747 | 7.990 | 2.619 | 15.48 |
| Manhattan | 245640 | 2.268 | 0.587 | 6.89 |

### By time_of_day

Disparity ratio (worst/best RMSE): **1.84** (threshold 1.5) — ⚠️ **flagged**. Worst: `overnight`, best: `evening`.

| Group | n | RMSE | MAE | MAPE |
|-------|---|------|-----|------|
| overnight | 8572 | 5.606 | 1.362 | 6.54 |
| afternoon | 101213 | 3.691 | 0.836 | 9.32 |
| morning | 68332 | 3.337 | 0.897 | 7.82 |
| evening | 94618 | 3.046 | 0.684 | 8.84 |

### By day_type

Disparity ratio (worst/best RMSE): **1.32** (threshold 1.5) — ok. Worst: `weekend`, best: `weekday`.

| Group | n | RMSE | MAE | MAPE |
|-------|---|------|-----|------|
| weekend | 3150 | 4.576 | 1.133 | 4.95 |
| weekday | 269585 | 3.457 | 0.811 | 8.73 |

### By holiday

Disparity ratio (worst/best RMSE): **1.00** (threshold 1.5) — ok. Worst: `non-holiday`, best: `non-holiday`.

| Group | n | RMSE | MAE | MAPE |
|-------|---|------|-----|------|
| non-holiday | 272735 | 3.472 | 0.815 | 8.69 |

### By airport

Disparity ratio (worst/best RMSE): **2.54** (threshold 1.5) — ⚠️ **flagged**. Worst: `airport`, best: `non-airport`.

| Group | n | RMSE | MAE | MAPE |
|-------|---|------|-----|------|
| airport | 20957 | 7.411 | 2.243 | 15.11 |
| non-airport | 251778 | 2.913 | 0.696 | 8.16 |

## Top features (SHAP)

| Feature | Mean |SHAP| |
|---------|-----------|
| trip_distance | 6.8493 |
| trip_duration_min | 3.7284 |
| PULocationID | 0.6443 |
| DOLocationID | 0.5209 |
| passenger_count | 0.1070 |
| hour_cos | 0.0818 |
| hour | 0.0673 |
| hour_sin | 0.0358 |
| dow_sin | 0.0210 |
| day_of_week | 0.0183 |

## Limitations

- Trained on a single month of NYC Yellow Taxi data; may not generalise to other periods, boroughs served sparsely, or green/for-hire vehicles.
- Predictions degrade under distribution shift (see drift monitoring).

## Ethical considerations

- No demographic or protected attributes are used or available; fairness is assessed as geographic/temporal service equity, not demographic parity.
- Large borough-level disparities could translate into unequal service quality across neighbourhoods and should be monitored.
