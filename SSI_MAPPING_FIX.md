# SSI Mapping Fix — SNOMED to OMOP CDM Conversion

## Problem

The validation pipeline was not finding any SSI (Surgical Site Infection) events in the synthetic OMOP CDM data, even though:
- The Synthea module correctly generates SSI conditions with SNOMED-CT code **76844004** ("Infection of surgical wound")
- The outcome cohort is configured to find SSI cases using OMOP concept IDs (4201004, 4318887, 40480632, 4110523)

**Root Cause:** The ETL SQL transformation had a `TODO` comment and was hardcoding `condition_concept_id = 0` instead of mapping SNOMED codes to OMOP standard concept IDs.

## Solution

Updated the ETL transformation in `scripts/sql/fhir_to_omop_transform_draft.sql` to:

1. **First attempt**: Direct lookup in the OMOP `concept` table for SNOMED codes with `standard_concept = 'S'`
   ```sql
   SELECT c2.concept_id FROM @cdm_schema.concept c2 
   WHERE c2.concept_code = c.source_code 
     AND c2.vocabulary_id = 'SNOMED'
     AND c2.standard_concept = 'S'
   ```

2. **Fallback mapping**: If direct lookup fails, use hardcoded mappings for known SSI codes:
   - **76844004** → OMOP **4201004** (Infection of wound)
   - **433202001** → OMOP **4318887** (Surgical wound infection)
   - **444948002** → OMOP **40480632** (Infected wound)

3. **Filter**: Only insert conditions that successfully map to a valid OMOP concept ID (> 0)

## Synthea PAD/SSI Module SSI Incidence

The module generates SSI events with comorbidity-adjusted probabilities:

- **12%** of patients with Type 2 diabetes
- **10%** of patients with obesity (BMI ≥ 30), no diabetes
- **9%** of patients with current smoking only
- **6%** baseline incidence (no major risk factors)

With PAD-only generation for patients age 40+ and ~6-12% developing SSI based on comorbidity profile, a 1000-patient synthetic population should yield approximately 60-120 SSI cases, which is sufficient for external validation.

## How to Re-Run the Pipeline

### Step 1: Generate Fresh Synthea Data
```bash
cd C:\path\to\synthea
java -jar synthea-with-dependencies.jar \
  -m src/main/resources/modules/pad_ssi.json \
  -s 12345 \
  -p 1000 \
  -c synthea.properties \
  Washington
```

Output: FHIR resources in `output/fhir/`

### Step 2: Run the ETL (now with proper SNOMED→OMOP mapping)
```r
setwd("C:/path/to/pad-oler-ssi-val")
source("renv/activate.R")
source("scripts/run_fhir_to_omop_etl.R")

# Run the ETL with your Synthea FHIR output directory
run_fhir_to_omop_etl(
  fhir_input_dir = "C:/path/to/synthea/output/fhir",
  sample_size = 1000L,
  module_version = "v04",
  run_date = Sys.Date()
)
```

This will now correctly populate:
- `cdm_synthea.condition_occurrence` with mapped `condition_concept_id` values
- Both target (inpatient surgery) and outcome (SSI diagnosis) cohorts
- The `concept_ancestor` table will now be able to match SSI cases

### Step 3: Run the Risk Score Pipeline
```bash
cd C:\Users\rapiduser\pad-oler-ssi-val
"C:\Program Files\R\R-4.5.2\bin\Rscript.exe" run_risk_score_pipeline.R
```

### Step 4: Generate the Validation Report
```r
setwd("C:/path/to/pad-oler-ssi-val")
source("renv/activate.R")
source("run_report.R")
```

Output: `output/risk_score_eval/ssi_validation_report.docx` (with today's date in the title)

## Files Modified

- **scripts/sql/fhir_to_omop_transform_draft.sql** — Implemented SNOMED to OMOP concept ID mapping in the condition insertion CTE

## Next Steps

1. **Re-generate synthetic data** using the Synthea PAD/SSI module (if needed)
2. **Re-run the ETL** with the corrected transformation
3. **Verify concept mappings**:
   ```sql
   SELECT condition_concept_id, COUNT(*) as count
   FROM cdm_synthea.condition_occurrence
   WHERE condition_start_date IS NOT NULL
   GROUP BY condition_concept_id
   ORDER BY count DESC;
   ```
   Should show non-zero concept IDs for SSI-related conditions

4. **Check cohort populations**:
   ```sql
   /* Check target cohort */
   SELECT cohort_definition_id, COUNT(*) FROM plp_results.ssi_val_cohort
   WHERE cohort_definition_id = 1
   GROUP BY cohort_definition_id;
   
   /* Check outcome cohort */
   SELECT cohort_definition_id, COUNT(*) FROM plp_results.ssi_val_cohort
   WHERE cohort_definition_id = 2
   GROUP BY cohort_definition_id;
   ```

5. **Re-run the full validation pipeline** with SSI cases now properly captured

## Technical Notes

- The hardcoded mapping is a fallback; the concept table lookup is preferred because it respects OMOP vocabulary versions
- The filter `AND c.condition_concept_id > 0` ensures only valid, mapped conditions are inserted
- SNOMED code 76844004 is the primary source; descendant concepts in the concept hierarchy will be automatically matched by the cohort definition's use of `concept_ancestor`
