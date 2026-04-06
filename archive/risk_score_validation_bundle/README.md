# Portable OMOP Risk Score Validation Bundle

This folder is designed to be zipped and shared with external OMOP data partners.
It contains only the files needed to run integer risk score validation.

## Contents

- `run_risk_score_pipeline.R` - main entry point
- `config.R` - environment-specific settings template
- `install_packages_risk_score.R` - package install helper
- `R/` - pipeline and database helper functions
- `risk_score/` - component, concept, and lookup CSV inputs
- `drivers/mssql-jdbc-13.2.1.zip` - SQL Server JDBC archive

## How To Use At A New Site

1. Unzip this folder.
2. Edit `config.R` with local SQL Server and OMOP schema details.
3. Review `risk_score/component_concepts.csv` — all components are pre-mapped to OMOP standard
   concept IDs. Adjust or supplement with site-approved concepts if needed.
4. In a fresh R session, run:

```r
setwd("<unzipped_bundle_path>")
source("install_packages_risk_score.R")
source("run_risk_score_pipeline.R")
```

## Output

Results are written to:

- `output/risk_score_eval/`

## Notes

- The bundle expects existing target/outcome cohorts in `results_schema.cohort_table` with IDs from `config.R`.
- `risk_score/risk_lookup.csv` is optional but required for lookup-based calibration metrics.

### Pre-mapped Components

All risk score components are pre-mapped in `risk_score/component_concepts.csv`:

| Component | Concept(s) | Notes |
|---|---|---|
| `female` | 8532 | Biological sex = Female |
| `overweight` | 3025315 (weight), 3036277 (height) | BMI 25–30 derived from measurements |
| `obese` | 3025315 (weight), 3036277 (height) | BMI ≥ 30 derived from measurements |
| `urgnt` | 4158569, 4250892 + descendants | Emergency or urgent procedure flag |
| `abi_35` | 40489833, 46237026 + descendants | Ankle-brachial index measurement < 0.35 |
| `prrevasc_any` | 4159960 + descendants | Prior lower-extremity vascular procedure |
| `prolong_abx` | 21603553 + descendants | Non-prophylactic antibiotic (start ≤ index − 1 day, duration > 2 days) |
| `optime4h` | procedure_end_datetime (primary) | Operative time > 240 minutes |
| `mFI_high` | 201820, 255573, 316139, 316866, 4215267 | Composite mFI > 0.25 (≥2/5: diabetes, COPD, CHF, hypertension, functional status) |
| `indicationClaudication` | 442774 + descendants | Intermittent claudication as surgical indication |

## Missing Value Handling

**The risk score pipeline treats missing component data as zero evidence.**

When a component's event count cannot be determined from your OMOP CDM (no matching records):
- The component's event count defaults to 0
- The component scores 0 points (unless `min_count = 0`)
- The total risk score includes this component as 0

**Result:** Total risk scores are always computed and never marked as missing or incomplete.

**Why this approach:** Missing data from the CDM is interpreted as no documented evidence of that 
risk factor. This is appropriate when:
- You expect OMOP data completeness to be reasonably high
- A missing risk factor should be treated conservatively (not as "unknown risk", but as "no risk documented")

If your understanding or requirements differ, consider:
- Pre-processing the data to flag incomplete cases before scoring
- Post-processing to mark scores as provisional when many components are missing
- Documenting data completeness in your results notes
