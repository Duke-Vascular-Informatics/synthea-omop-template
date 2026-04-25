# covariates/

CSV specification files that define the covariates (patient features) used in your study.
These files are the primary inputs to `R/covariates_pipeline.R` and validated by Step 2.

They support any study design — prognostic models, causal inference, cohort characterization —
wherever you need a structured, reusable covariate specification rather than defining
covariates inline in R code.

## Files

| File | Description |
|------|-------------|
| `components.csv` | One row per covariate. Defines the name, OMOP domain, lookback window, minimum event count, and optional point value (for scored models). |
| `component_concepts.csv` | OMOP concept ID mappings for each component. Supports `include_descendants = TRUE` for ancestor rollup via `concept_ancestor`. |
| `risk_lookup.csv` | Optional. Maps an integer total score to a calibrated predicted probability. Leave empty if using logistic regression only. |

## When to use these files

**Use this CSV approach when:**
- You have a pre-specified covariate list (e.g. from a published risk model or protocol).
- You want to version-control the exact concepts used.
- You are building an integer risk score with point values per covariate.

**Use `FeatureExtraction::createCovariateSettings()` instead when:**
- You want automated, data-driven covariate extraction across all OMOP domains.
- You are running PatientLevelPrediction or CohortMethod with a broad feature set.

Set both covariate file paths to `NULL` in `config.R` to skip this pipeline and define
covariates directly in Step 8.

---

## components.csv — column definitions

| Column | Description |
|--------|-------------|
| `component_id` | Short unique identifier. Lowercase, letters/numbers/underscores only. Must match `component_id` values in `component_concepts.csv`. Examples: `female`, `diabetes`, `prior_hosp` |
| `component_name` | Human-readable label used in reports and output tables. |
| `domain` | OMOP CDM domain: `condition` → `condition_occurrence`, `procedure` → `procedure_occurrence`, `drug` → `drug_exposure`, `measurement` → `measurement`, `observation` → `observation` |
| `lookback_start_day` | Start of lookback window relative to index date (negative = before index). Examples: `-365`, `-3650`, `-30` |
| `lookback_end_day` | End of lookback window. `-1` = day before index (strictly prior). `0` = include index date. |
| `min_count` | Minimum qualifying records to count the component as present. Almost always `1`. |
| `points` | Score points assigned when present. Positive = risk factor. Negative = protective factor. Use `1` for binary presence/absence covariates. |
| `missing_is_negative` | `TRUE` = absence means component is absent (default). `FALSE` = for derived components where missing ≠ absent (e.g. BMI from weight/height). |

**Notes:**
- Mutually exclusive categories (e.g. overweight vs. obese) should be separate rows with distinct `component_id`s.
- For multi-concept OR components, add multiple rows in `component_concepts.csv` with the same `component_id` — the component is flagged if **any** row matches.

---

## component_concepts.csv — column definitions

| Column | Description |
|--------|-------------|
| `component_id` | Must exactly match a `component_id` in `components.csv`. |
| `concept_id` | Standard OMOP concept ID (`standard_concept = 'S'`). Exception: ATC drug class ancestors use `standard_concept = 'C'`. Use `0` as a placeholder — Step 2 warns when `0`s remain. |
| `include_descendants` | `TRUE` = use `concept_ancestor` rollup (matches concept and all descendants). Recommended for most clinical concepts. `FALSE` = exact match only. Use for gender, specific LOINC codes, or when descendants include unrelated concepts. |
| `concept_role` | Optional. Tag for the concept's role within the component. Leave blank for simple presence/absence. Used for measurement sub-types (`bmi_direct`, `weight`, `height`) or to group multi-domain concepts. |
| `value_concept_ids` | Optional. Semicolon-separated `value_as_concept_id` values for observation-table lookups where the concept alone is insufficient. Leave blank for condition, procedure, drug, and most measurement rows. |

### Special component types

**Gender / sex** (queries `person.gender_concept_id` directly — use `include_descendants = FALSE`):
```
female,8532,FALSE,,
```

**BMI from weight + height** (when direct BMI measurement is absent):
Use `concept_role` to tag each measurement type (`bmi_direct`, `weight`, `height`). The pipeline
resolves BMI in priority order: direct measurement first, then weight + height calculation.

**Operative time / duration** (derived from procedure timestamps):
The pipeline computes `DATEDIFF(MINUTE, procedure_datetime, procedure_end_datetime)` for
procedures descended from the listed ancestor concept IDs. No `value_concept_ids` needed.

---

## Concept lookup

Before writing any concept ID, verify it against the live vocabulary. Use the
`/concept-lookup` slash command in Claude Code:

```
/concept-lookup diabetes mellitus condition
/concept-lookup cefazolin drug
/concept-lookup ankle brachial index measurement
```

Or run directly:

```sql
-- Find candidate standard concepts
SELECT concept_id, concept_name, vocabulary_id, domain_id
FROM omop_vocab.concept
WHERE concept_name LIKE '%your covariate name%'
  AND standard_concept = 'S'
  AND invalid_reason IS NULL
  AND domain_id IN ('Condition', 'Procedure', 'Drug', 'Measurement', 'Observation');

-- Check descendants of a candidate ancestor
SELECT c.concept_id, c.concept_name, ca.min_levels_of_separation
FROM omop_vocab.concept_ancestor ca
INNER JOIN omop_vocab.concept c ON c.concept_id = ca.descendant_concept_id
WHERE ca.ancestor_concept_id = <candidate_concept_id>
ORDER BY ca.min_levels_of_separation;

-- Find ATC drug class ancestors
SELECT concept_id, concept_name, vocabulary_id
FROM omop_vocab.concept
WHERE vocabulary_id = 'ATC'
  AND standard_concept = 'C'
  AND concept_name LIKE '%antibiotic%';
```
