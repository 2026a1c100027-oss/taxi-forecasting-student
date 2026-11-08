<#
.SYNOPSIS
    Golden path: run the whole project end to end from one command.

.DESCRIPTION
    Runs every local stage in order and prints a PASS/FAIL summary with
    timestamps and the git commit hash. Everything is also written to
    logs\golden_path_<timestamp>.log.

    Stages:
      1. Environment      - create .venv (Python 3.11) and install requirements if missing
      2. Data pipeline    - download (first run) or reuse raw TLC data, clean, validate, build features
      3. Quality gate     - ruff lint + pytest with coverage (same checks as GitHub Actions)
      4. Models           - reuse registered MLflow models, or train them if missing (-ForceTrain to retrain)
      5. API smoke test   - start FastAPI on a spare port, check /health, call /predict/fare, stop it
      6. Batch inference  - recursive demand forecast for every zone -> predictions.db
      7. Drift report     - PSI/KS drift report for demand and fare -> artifacts\drift
      8. Responsible AI   - subgroup error analysis, SHAP, model cards -> artifacts\responsible

    Local only: no AWS resources are created.

.EXAMPLE
    .\scripts\golden_path.ps1
.EXAMPLE
    .\scripts\golden_path.ps1 -ForceTrain -Trials 5
#>

[CmdletBinding()]
param(
    # Retrain both models even if they are already registered in MLflow.
    [switch]$ForceTrain,
    # Optuna trials per estimator when training (config default is 25).
    [int]$Trials = 5,
    # Port for the temporary smoke-test API (kept off 8000 so a running API is not disturbed).
    [int]$ApiPort = 8010,
    # Hours ahead for the batch forecast.
    [int]$Horizon = 3,
    # Force "pip install -r requirements.txt" even when .venv already exists.
    [switch]$Install
)

$ErrorActionPreference = "Continue"
$RepoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $RepoRoot

$RunStamp = Get-Date -Format "yyyyMMdd_HHmmss"
New-Item -ItemType Directory -Force -Path "logs" | Out-Null
$Log = Join-Path $RepoRoot "logs\golden_path_$RunStamp.log"
$Python = Join-Path $RepoRoot ".venv\Scripts\python.exe"
$Results = New-Object System.Collections.Generic.List[object]

function Write-Log {
    param([string]$Text, [string]$Color = "Gray")
    Write-Host $Text -ForegroundColor $Color
    Add-Content -Path $Log -Value $Text
}

# Run a native command, stream its output to console + log, return its exit code.
function Invoke-Logged {
    param([string]$Exe, [string[]]$Arguments)
    Write-Log ("> " + $Exe + " " + ($Arguments -join " ")) "DarkGray"
    & $Exe @Arguments 2>&1 | ForEach-Object {
        $line = "$_"
        Write-Host $line
        Add-Content -Path $Log -Value $line
    }
    return $LASTEXITCODE
}

function Invoke-Stage {
    param([string]$Name, [scriptblock]$Action)
    $start = Get-Date
    Write-Log ""
    Write-Log ("=== [{0}] {1} ===" -f $start.ToString("HH:mm:ss"), $Name) "Cyan"
    $ok = $false
    try {
        $ok = [bool](& $Action)
    } catch {
        Write-Log ("ERROR: " + $_.Exception.Message) "Red"
        $ok = $false
    }
    $secs = [math]::Round(((Get-Date) - $start).TotalSeconds, 1)
    $status = if ($ok) { "PASS" } else { "FAIL" }
    $color = if ($ok) { "Green" } else { "Red" }
    Write-Log ("--- {0}: {1} ({2}s)" -f $Name, $status, $secs) $color
    $Results.Add([pscustomobject]@{
        Stage   = $Name
        Status  = $status
        Started = $start.ToString("HH:mm:ss")
        Seconds = $secs
    })
    return $ok
}

# ---------------------------------------------------------------- header
$Commit = (git rev-parse --short HEAD 2>$null)
if (-not $Commit) { $Commit = "unknown (not a git checkout)" }
$Branch = (git branch --show-current 2>$null)
Write-Log "Golden path run $RunStamp" "Yellow"
Write-Log "Repository : $RepoRoot"
Write-Log "Commit     : $Commit ($Branch)"
Write-Log "Log file   : $Log"

$allOk = $true

# ---------------------------------------------------------------- 1. environment
$allOk = (Invoke-Stage "1. Environment" {
    if (-not (Test-Path $Python)) {
        Write-Log "Creating .venv with Python 3.11"
        if ((Invoke-Logged "py" @("-3.11", "-m", "venv", ".venv")) -ne 0) { return $false }
        $script:Install = $true
    }
    if ($script:Install) {
        if ((Invoke-Logged $Python @("-m", "pip", "install", "--upgrade", "pip")) -ne 0) { return $false }
        if ((Invoke-Logged $Python @("-m", "pip", "install", "-r", "requirements.txt")) -ne 0) { return $false }
    } else {
        Write-Log "Existing .venv found; skipping install (use -Install to force)."
    }
    return ((Invoke-Logged $Python @("--version")) -eq 0)
}) -and $allOk

if (-not $allOk) { Write-Log "Environment failed; stopping." "Red" }

# ---------------------------------------------------------------- 2. data pipeline
if ($allOk) {
    $allOk = (Invoke-Stage "2. Data pipeline" {
        $pipeArgs = @("-m", "scripts.run_pipeline", "--year", "2024", "--month", "1")
        if (Test-Path "data\raw\yellow_tripdata_2024-01.parquet") {
            $pipeArgs += "--skip-download"
        } else {
            Write-Log "Raw data not found; downloading from NYC TLC."
        }
        if ((Invoke-Logged $Python $pipeArgs) -ne 0) { return $false }
        $summary = "data\processed\pipeline_summary.json"
        if (-not (Test-Path $summary)) { Write-Log "Missing $summary" "Red"; return $false }
        $s = Get-Content $summary -Raw | ConvertFrom-Json
        Write-Log ("Validation: input_rows={0} output_rows={1} dropped={2}; demand_feature_rows={3} fare_feature_rows={4}" -f `
            $s.cleaning.input_rows, $s.cleaning.output_rows, $s.cleaning.total_dropped, $s.demand_feature_rows, $s.fare_feature_rows)
        return $true
    }) -and $allOk
}

# ---------------------------------------------------------------- 3. quality gate
if ($allOk) {
    $allOk = (Invoke-Stage "3. Quality gate (ruff + pytest)" {
        if ((Invoke-Logged $Python @("-m", "ruff", "check", ".")) -ne 0) { return $false }
        return ((Invoke-Logged $Python @("-m", "pytest", "-q", "--cov=src", "--cov-report=term")) -eq 0)
    }) -and $allOk
}

# ---------------------------------------------------------------- 4. models
if ($allOk) {
    $allOk = (Invoke-Stage "4. Models (MLflow registry)" {
        $check = "import mlflow,sys; mlflow.set_tracking_uri('sqlite:///mlflow.db'); c=mlflow.MlflowClient(); " +
                 "[print(n, 'version', c.get_latest_versions(n)[-1].version) for n in ('taxi-demand-forecaster','taxi-fare-predictor')]"
        $registered = ((Invoke-Logged $Python @("-W", "ignore", "-c", $check)) -eq 0)
        if ($registered -and -not $script:ForceTrain) {
            Write-Log "Both models already registered; reusing them (use -ForceTrain to retrain)."
            return $true
        }
        Write-Log "Training both models with $($script:Trials) Optuna trials per estimator."
        if ((Invoke-Logged $Python @("-m", "scripts.train_models", "--problem", "both", "--n-trials", "$($script:Trials)")) -ne 0) { return $false }
        return ((Invoke-Logged $Python @("-W", "ignore", "-c", $check)) -eq 0)
    }) -and $allOk
}

# ---------------------------------------------------------------- 5. API smoke test
if ($allOk) {
    $allOk = (Invoke-Stage "5. API smoke test (port $ApiPort)" {
        $apiOut = Join-Path $RepoRoot "logs\api_$RunStamp.out.log"
        $apiErr = Join-Path $RepoRoot "logs\api_$RunStamp.err.log"
        $proc = Start-Process -FilePath $Python -PassThru -WindowStyle Hidden `
            -ArgumentList @("-m", "uvicorn", "src.serving.api:app", "--host", "127.0.0.1", "--port", "$ApiPort") `
            -RedirectStandardOutput $apiOut -RedirectStandardError $apiErr
        $base = "http://127.0.0.1:$ApiPort"
        try {
            $health = $null
            for ($i = 0; $i -lt 90; $i++) {
                Start-Sleep -Seconds 2
                try { $health = Invoke-RestMethod -Uri "$base/health" -TimeoutSec 5; break } catch { }
            }
            if (-not $health) { Write-Log "API did not answer /health within 180s (see $apiErr)" "Red"; return $false }
            Write-Log ("/health: " + ($health | ConvertTo-Json -Compress))
            if ($health.status -ne "ok" -or -not $health.demand_model_loaded -or -not $health.fare_model_loaded) {
                Write-Log "API is not ready (status/model flags)." "Red"; return $false
            }
            $fare = @{
                trip_distance   = 3.4
                pu_location_id  = 132
                do_location_id  = 230
                passenger_count = 1
                pickup_datetime = "2024-01-15T18:30:00"
            } | ConvertTo-Json
            $pred = Invoke-RestMethod -Method Post -Uri "$base/predict/fare" -ContentType "application/json" -Body $fare
            Write-Log ("/predict/fare: " + ($pred | ConvertTo-Json -Compress))
            return $true
        } finally {
            if ($proc -and -not $proc.HasExited) { Stop-Process -Id $proc.Id -Force }
            Write-Log "Smoke-test API stopped."
        }
    }) -and $allOk
}

# ---------------------------------------------------------------- 6. batch inference
if ($allOk) {
    $allOk = (Invoke-Stage "6. Batch inference ($Horizon h)" {
        if ((Invoke-Logged $Python @("-m", "scripts.batch_forecast", "--horizon", "$($script:Horizon)")) -ne 0) { return $false }
        return (Test-Path "predictions.db")
    }) -and $allOk
}

# ---------------------------------------------------------------- 7. drift report
if ($allOk) {
    $allOk = (Invoke-Stage "7. Drift report" {
        if ((Invoke-Logged $Python @("-m", "scripts.monitoring.demo_drift_report", "--problem", "all", "--mode", "drift")) -ne 0) { return $false }
        return ((Test-Path "artifacts\drift\demand_drift_metrics.json") -and (Test-Path "artifacts\drift\fare_drift_metrics.json"))
    }) -and $allOk
}

# ---------------------------------------------------------------- 8. responsible AI
if ($allOk) {
    $allOk = (Invoke-Stage "8. Responsible AI analysis" {
        if ((Invoke-Logged $Python @("-W", "ignore", "-m", "scripts.responsible.run_analysis")) -ne 0) { return $false }
        return ((Test-Path "artifacts\responsible\demand_fairness.json") -and
                (Test-Path "artifacts\responsible\fare_fairness.json") -and
                (Test-Path "docs\model_cards\fare.md"))
    }) -and $allOk
}

# ---------------------------------------------------------------- summary
Write-Log ""
Write-Log "================ GOLDEN PATH SUMMARY ================" "Yellow"
Write-Log "Commit : $Commit ($Branch)"
Write-Log ("Ended  : " + (Get-Date -Format "yyyy-MM-dd HH:mm:ss"))
$table = $Results | Format-Table -AutoSize | Out-String
Write-Host $table
Add-Content -Path $Log -Value $table
if ($allOk -and $Results.Count -eq 8) {
    Write-Log "RESULT: PASS - all 8 stages completed" "Green"
    Write-Log "Log: $Log"
    exit 0
} else {
    Write-Log "RESULT: FAIL - see the first failed stage above" "Red"
    Write-Log "Log: $Log"
    exit 1
}