# Taxi Forecasting

Python application for two NYC taxi prediction tasks:

- **Demand:** pickup count for one pickup zone and hour.
- **Fare:** `fare_amount` for one trip, not the full passenger bill.

The repository includes data processing, XGBoost/LightGBM training, MLflow
tracking, FastAPI serving, recursive batch forecasts, SHAP explanations,
subgroup evaluation, drift detection, a Streamlit dashboard, and optional AWS
infrastructure templates. It contains no datasets or trained model bundles.

## Start Locally

For the preinstalled Windows course image, follow the
[AWS account and image-access guide](docs/STUDENT_AWS_IMAGE_ACCESS.md) instead of
recreating the environment with the local-install commands below.

Use Python 3.11. From the repository root on Windows PowerShell:

```powershell
py -3.11 -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
.\.venv\Scripts\python.exe -m pytest
```

Tests use synthetic data and do not require downloads, models or AWS access.
Follow [setup](docs/SETUP.md) to download data, train registered models, and
start the API and dashboard. Do not expect working predictions immediately
after cloning: serving requires both registered models and saved demand history.

## Golden Path: Run Everything With One Command

One entry point runs the whole project end to end on a local Windows machine and
prints a PASS/FAIL summary. No AWS resources are created.

### Prerequisites

- Windows PowerShell 5.1+ and Git
- 64-bit Python 3.11 available as `py -3.11`
- Internet access on the first run (pip packages and the NYC TLC data download)
- About 5 GB free disk space; 16 GB RAM recommended for training

### Raw Data

Nothing needs to be downloaded by hand. On the first run the pipeline fetches the
public NYC TLC January 2024 Yellow Taxi trip file and the taxi zone lookup from
`https://d37ci6vzurychx.cloudfront.net` (configured in `config/config.yaml`) into
`data/raw/`. Later runs reuse the cached files.

### Single Command

From a fresh clone:

```powershell
git clone https://github.com/2026a1c100027-oss/taxi-forecasting-student.git
cd taxi-forecasting-student
powershell -ExecutionPolicy Bypass -File .\scripts\golden_path.ps1
```

Options: `-ForceTrain` retrains even if models are registered, `-Trials 5` sets
Optuna trials per estimator (default 5 for a fast run; the config default is 25),
`-Horizon 3` sets the batch forecast hours, `-ApiPort 8010` sets the temporary
smoke-test port, and `-Install` forces `pip install`.

### Stages and Expected Outputs

| # | Stage | What it does | Evidence |
|---|---|---|---|
| 1 | Environment | Creates `.venv` and installs `requirements.txt` if missing | Python version in log |
| 2 | Data pipeline | Downloads/reuses raw data, cleans, validates, builds features, splits by time | `data/processed/pipeline_summary.json`, `data/features/` |
| 3 | Quality gate | `ruff check` and `pytest --cov=src` (same as GitHub Actions) | Test summary in log |
| 4 | Models | Reuses registered MLflow models or trains both | `mlflow.db`, `mlruns/`, registry versions in log |
| 5 | API smoke test | Starts FastAPI, checks `/health`, calls `/predict/fare`, stops it | Health and prediction JSON in log |
| 6 | Batch inference | Recursive demand forecast for every zone | `predictions.db` table `demand_forecasts` |
| 7 | Drift report | PSI/KS drift check for demand and fare | `artifacts/drift/*_drift_metrics.json` |
| 8 | Responsible AI | Subgroup errors, SHAP, model cards | `artifacts/responsible/*_fairness.json`, `docs/model_cards/` |

The run ends with `RESULT: PASS - all 8 stages completed`, a stage table with start
times and durations, and the git commit hash. The full log is written to
`logs/golden_path_<timestamp>.log`. The script exits with code 0 on PASS and 1 on
FAIL, stopping at the first failed stage.

After a PASS, start the services for interactive use:

```powershell
.\.venv\Scripts\python.exe -m uvicorn src.serving.api:app --host 127.0.0.1 --port 8000
.\.venv\Scripts\python.exe -m mlflow ui --backend-store-uri sqlite:///mlflow.db --port 5000
.\.venv\Scripts\python.exe -m pip install -r requirements-dashboard.txt
$env:API_BASE_URL = "http://127.0.0.1:8000"
.\.venv\Scripts\python.exe -m streamlit run dashboard/app.py
```

### Teardown

- **Local:** press `Ctrl+C` in each service terminal. To reset to a clean state,
  delete `.venv`, the contents of `data/raw`, `data/processed` and `data/features`, `mlruns/`, `mlflow.db`, `predictions.db`, `artifacts/`
  and `logs/` (all are git-ignored or regenerated).
- **Cloud:** the golden path creates no AWS resources. If you deployed with the
  [AWS walkthrough](docs/STUDENT_AWS_DEPLOYMENT_WALKTHROUGH.md), remove
  everything with `terraform -chdir=infra\terraform destroy` (see Part Q) and
  confirm the state is empty.

## Documentation

- [Request and launch the Windows course image](docs/STUDENT_AWS_IMAGE_ACCESS.md)
- [Deploy the API to AWS with CodeBuild](docs/STUDENT_AWS_DEPLOYMENT_WALKTHROUGH.md)
- [Local setup and commands](docs/SETUP.md)
- [API request examples](docs/API_EXAMPLES.md)
- [System architecture](docs/ARCHITECTURE.md)
- [Data scope and model limitations](docs/DATA_STATEMENT.md)
- [Optional AWS infrastructure](infra/terraform/README.md)
- [Recording companion and learner activity map](docs/RECORDING_COMPANION.md)
- [Recorded architecture walkthrough](docs/PROJECT_ARCHITECTURE.md)
- [Historical business report](docs/BUSINESS_REPORT.md)
- [Cloud cost boundaries](docs/COST_OPTIMIZATION.md)

The companion links all L2-L12 learner labs; L1 uses setup and tests. Videos are
provided separately. Lab files, reviewed diagrams, and the exploration notebook
retain the paths shown in the recordings. The notebook has no saved outputs.
Datasets, trained models, and evidence reports must be generated locally; AWS
activities require your own authorized configuration or the stated local fallback.

## Layout

| Path | Responsibility |
| --- | --- |
| `src/data/`, `src/features/` | Download, clean, aggregate, engineer features, and split by time |
| `src/models/` | Tune, train, evaluate, explain, and register models |
| `src/serving/`, `clients/python/` | API contracts, inference, batch forecasting, and HTTP client |
| `src/monitoring/`, `src/responsible/` | Drift, performance comparisons, SHAP, and subgroup metrics |
| `scripts/` | Technical command entrypoints |
| `dashboard/` | Streamlit views calling the API and reading local reports |
| `tests/` | Offline unit and integration checks |
| `notebooks/`, `docs/` | Data exploration, learner activities, and technical references |
| `docker/`, `infra/terraform/`, `retraining/` | Optional packaging and cloud operation |

## Operational Boundaries

Docker, Terraform and AWS are optional for local operation. The cloud templates
are not connected to any account, remote repository or existing deployment.
They can create billable resources if you explicitly deploy them with credentials.
No GitHub Actions workflows or automatic release hooks are configured here.

Historical evaluation does not establish current production quality. The default
forecast follows the latest stored history, not the current clock. Model errors,
duration estimation, drift and subgroup disparities require review before using
predictions to make operational or financial decisions.