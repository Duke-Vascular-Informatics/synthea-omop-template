# Validation Report Generation Guide

## Overview

The PAD/OLER SSI validation project now includes automated Word document report generation with comprehensive tables, figures, and metrics.

## Generated Report Contents

The `ssi_validation_report.docx` includes:

### **Table 1: Risk Score Components**
- All ten risk score components with their point values
- Lookback windows for each component
- OMOP domain and derivation method for each variable
- Full OMOP concept mappings and transformations

### **Table 2: Component Prevalence**
- Prevalence of each risk score component in the validation cohort
- Counts of positive cases and total eligible procedures
- Prevalence percentages for each component

### **Table 3: Discrimination and Calibration Metrics**
- **AUROC** — Area under the receiver operating characteristic curve
- **AUPRC** — Area under the precision-recall curve
- **Brier Score** — Average squared prediction error
- **Calibration Intercept** — Calibration-in-the-large
- **Calibration Slope** — Overall calibration slope

Metrics are reported for:
- **Lookup model** — Using published score-to-risk table
- **Recalibrated model** — Logistic regression recalibration

### **ROC Curve (Figure 1)**
- Receiver operating characteristic curve showing model discrimination
- AUROC value displayed on the plot

### **Calibration Plots (Figures 2-3)**
- Observed vs. predicted risk across deciles
- Separate plots for lookup-based and recalibrated models
- Perfect calibration line (45°) shown for reference

### **Expected Calibration Error (ECE)**
- Average absolute difference between predicted and observed probabilities
- Computed across deciles of risk
- Interpretation guidance (excellent/good/moderate/poor)

### **Sections**
1. Executive Summary
2. Methods (Study Population, Risk Score Computation, Performance Evaluation)
3. Risk Model Variables (Table 1)
4. Component Prevalence (Table 2)
5. Discrimination and Calibration Results (Table 3)
6. ROC Curve (Figure 1)
7. Calibration Plots (Figures 2-3)
8. Expected Calibration Error
9. Discussion and Conclusion

## Workflow

### **One-Step Approach: Full Validation + Report**

Run the complete workflow in one script:

```bash
cd C:\Users\rapiduser\pad-oler-ssi-val
Rscript gen_validation_report.R
```

This will:
1. Build cohorts from the OMOP CDM
2. Compute integer risk scores for all eligible procedures
3. Evaluate discrimination (AUROC, AUPRC) and calibration (ECE)
4. Generate the Word validation report

### **Two-Step Approach: Pipeline, Then Report**

If you prefer to run steps separately:

**Step 1: Run the Risk Score Pipeline**
```bash
cd C:\Users\rapiduser\pad-oler-ssi-val
Rscript run_risk_score_pipeline.R
```

This generates:
- `output/risk_score_eval/person_level_scores.csv` — Person-level scores and outcomes
- `output/risk_score_eval/component_summary.csv` — Component prevalence
- `output/risk_score_eval/metrics.csv` — Discrimination and calibration metrics
- `output/risk_score_eval/calibration_*.png` — Calibration plots

**Step 2: Generate the Report**
```bash
cd C:\Users\rapiduser\pad-oler-ssi-val
Rscript -e "source('run_report.R')"
```

Or from within R:
```r
setwd("C:/path/to/pad-oler-ssi-val")
source("run_report.R")
```

## Key Files

- **`run_report.R`** — Main entry point for report generation
  - Loads the extended report function
  - Generates the Word document

- **`R/report_extended.R`** — Extended report generation module
  - Complete report structure with all tables and figures
  - Automatic ECE and ROC curve computation
  - Graceful handling of missing pipeline outputs

- **`gen_validation_report.R`** — Combined workflow script
  - Runs pipeline and report in sequence
  - Error handling for each step

- **`run_risk_score_pipeline.R`** — Risk score extraction and evaluation
  - Computes person-level scores from OMOP CDM
  - Evaluates discrimination (AUROC, AUPRC)
  - Evaluates calibration (lookup-based and recalibrated)
  - Generates calibration plots

- **`output/risk_score_eval/ssi_validation_report.docx`** — Generated report (Word format)

## Prerequisites

- R 4.5+
- SQL Server instance with OMOP CDM (`localhost:1434`, `omop_synth.cdm_synthea`)
- OHDSI packages installed via `renv`
  - `DatabaseConnector`
  - `SqlRender`
  - `PatientLevelPrediction`
  - `FeatureExtraction`
- R packages for reporting:
  - `officer` — Word document generation
  - `flextable` — Styled tables
  - `ggplot2` — Graphics
  - `pROC` — ROC curve computation

All packages are listed in `renv.lock` and will be installed via `renv::restore()` on first run.

## Report Customization

To customize the report generation, edit `R/report_extended.R`:

- **Title and date**: Modify the heading section in `generate_word_report()`
- **Thresholds and interpretations**: Adjust AUROC/ECE interpretation thresholds in the function
- **Table formatting**: Modify flextable styling in `.build_table1()` and similar helpers
- **Additional sections**: Add new `body_add_par()` and `body_add_flextable()` calls

## Troubleshooting

### "Could not find function body_add_page_break"
This error indicates an older version of the `officer` package. The report uses spacing (`body_add_par("")`) instead of explicit page breaks for compatibility. If you encounter this, update officer:

```r
renv::install("officer")
renv::snapshot()
```

### Missing calibration or component data
The report gracefully handles missing pipeline outputs. If some sections appear blank:
1. Ensure `run_risk_score_pipeline.R` completed successfully
2. Check that all output files exist in `output/risk_score_eval/`
3. Re-run the pipeline if needed

### Database connection errors
If the report fails to generate due to DB errors during pipeline execution:
1. Verify SQL Server is running: `Get-Service -Name MSSQLSERVER`
2. Check connection details in `config.R`
3. Run `Rscript preflight_db_check.R` to diagnose connectivity

## Next Steps

1. **Run the full workflow**:
   ```bash
   Rscript gen_validation_report.R
   ```

2. **Review the report** in `output/risk_score_eval/ssi_validation_report.docx`

3. **Customize as needed** (edit `R/report_extended.R`)

4. **Share or archive** the report with validation results

---

For more information, see the main [README.md](README.md) and method documentation in the risk_score section.
