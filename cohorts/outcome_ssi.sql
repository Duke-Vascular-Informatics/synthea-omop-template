-- =============================================================================
-- cohorts/outcome_ssi.sql
-- OUTCOME COHORT DEFINITION
--
-- TODO [OUTCOME COHORT]: Replace this template with your study's outcome
-- definition. This file defines WHAT the outcome is and HOW it is identified
-- in the OMOP CDM.
--
-- WHAT TO DEFINE HERE
-- ────────────────────
-- This SQL defines:
--   • The OUTCOME EVENT — the condition, procedure, or measurement that
--     constitutes the study outcome (e.g. post-operative infection, VTE,
--     readmission, adverse drug event).
--   • The INDEX DATE (cohort_start_date) — the date of the first outcome event.
--   • COHORT EXIT (cohort_end_date) — condition end date or index + 1 day.
--   • EXCLUSIONS — outcome records that should NOT be counted (e.g. events
--     from unrelated procedures, obstetric complications, prevalent cases).
--
-- OUTCOME DEFINITION CHECKLIST
-- ─────────────────────────────
-- Before writing SQL, answer these questions:
--
--   1. OUTCOME EVENT — what constitutes the outcome?
--        OMOP table  : condition_occurrence | procedure_occurrence | measurement
--                      | drug_exposure | observation | visit_occurrence (readmission)
--        Concept IDs : Find with the query in the CONCEPT LOOKUP section below.
--        Ancestor ID : Is there a single ancestor concept that captures all
--                      relevant sub-types via concept_ancestor rollup?
--
--   2. INCIDENT vs. PREVALENT cases
--        First occurrence only (keep rn = 1)?
--        Any occurrence within the prediction window?
--        Must be NEW (not present before index date)?
--
--   3. EXCLUSIONS — which outcome records should be excluded?
--        Example: obstetric complications that share a parent concept
--        Example: bilateral/unilateral variants that don't apply
--        Example: records from specific source codes (condition_source_concept_id)
--        Exclude using NOT EXISTS / concept_ancestor sub-queries or
--        condition_source_concept_id NOT IN (...) for code-level exclusions.
--
--   4. STUDY WINDOW
--        Outcome must occur between @study_start_date and @study_end_date.
--        (The prediction window — e.g. 90 days after index — is applied
--        in R/risk_score_pipeline.R using prediction_window_days from config.R,
--        not here. This SQL captures all outcome events in the study period.)
--
-- CONCEPT LOOKUP
-- ──────────────
-- Find standard OMOP concept IDs and their descendants for your outcome:
--
--   -- Find the ancestor concept:
--   SELECT concept_id, concept_name, vocabulary_id, domain_id, standard_concept
--   FROM omop_vocab.concept
--   WHERE concept_name LIKE '%your outcome name%'
--     AND standard_concept = 'S'
--     AND invalid_reason IS NULL
--     AND domain_id = 'Condition';
--
--   -- Review descendants of a candidate ancestor concept:
--   SELECT c.concept_id, c.concept_name, ca.min_levels_of_separation
--   FROM omop_vocab.concept_ancestor ca
--   INNER JOIN omop_vocab.concept c ON c.concept_id = ca.descendant_concept_id
--   WHERE ca.ancestor_concept_id = <your ancestor concept_id>
--   ORDER BY ca.min_levels_of_separation;
--
-- Parameters (SqlRender — do not rename these):
--   @cdm_database_schema    CDM schema (config$cdm_schema)
--   @target_database_schema Results schema (config$results_schema)
--   @target_cohort_table    Cohort table name (config$cohort_table)
--   @outcome_cohort_id      Cohort ID for the outcome cohort (config$outcome_cohort_id)
--   @study_start_date       Study start date (config$study_start_date)
--   @study_end_date         Study end date (config$study_end_date)
-- =============================================================================

-- TODO [OUTCOME COHORT]: Replace concept_id = 0 in the WHERE clause with your
-- verified standard OMOP ancestor concept ID for the outcome of interest.
-- Add NOT EXISTS exclusion blocks for any outcome sub-types to exclude.

DELETE FROM @target_database_schema.@target_cohort_table
WHERE cohort_definition_id = @outcome_cohort_id;

INSERT INTO @target_database_schema.@target_cohort_table (
  cohort_definition_id,
  subject_id,
  cohort_start_date,
  cohort_end_date
)
SELECT
  @outcome_cohort_id                               AS cohort_definition_id,
  first_outcome.person_id                          AS subject_id,
  first_outcome.condition_start_date               AS cohort_start_date,
  ISNULL(
    first_outcome.condition_end_date,
    DATEADD(DAY, 1, first_outcome.condition_start_date)
  )                                                AS cohort_end_date
FROM (
  -- TODO [OUTCOME COHORT]: Adapt the inner query for your outcome's OMOP domain.
  -- This template queries condition_occurrence for a condition-based outcome.
  -- For procedure-based outcomes: use procedure_occurrence and procedure_date.
  -- For measurement-based outcomes: use measurement and value_as_number/concept.
  -- For readmission: use visit_occurrence with visit_concept_id = 9201.

  SELECT
    co.person_id,
    CAST(co.condition_start_date AS DATE) AS condition_start_date,
    CAST(co.condition_end_date   AS DATE) AS condition_end_date,
    ROW_NUMBER() OVER (
      PARTITION BY co.person_id
      ORDER BY co.condition_start_date
    ) AS rn
  FROM @cdm_database_schema.condition_occurrence co
  INNER JOIN @cdm_database_schema.concept_ancestor ca
    ON ca.descendant_concept_id = co.condition_concept_id

  WHERE
    -- TODO [OUTCOME COHORT]: Replace 0 with your outcome ancestor concept ID.
    -- This captures all descendants via concept_ancestor rollup.
    -- If the outcome is captured by a single specific concept (no hierarchy),
    -- replace the INNER JOIN + WHERE with:
    --   WHERE co.condition_concept_id = <your concept_id>
    ca.ancestor_concept_id = 0   -- TODO [OUTCOME COHORT]: Replace 0 with outcome ancestor concept ID

    AND co.condition_start_date >= CAST('@study_start_date' AS DATE)
    AND co.condition_start_date <= CAST('@study_end_date'   AS DATE)

    -- TODO [OUTCOME COHORT]: Add exclusion blocks for outcome sub-types that
    -- should NOT be counted. Examples are shown below.
    --
    -- Exclusion example 1: Exclude a specific sub-hierarchy using concept_ancestor.
    -- Replace 0 with the ancestor concept ID of the sub-type to exclude.
    -- AND NOT EXISTS (
    --   SELECT 1
    --   FROM @cdm_database_schema.concept_ancestor excl
    --   WHERE excl.descendant_concept_id = co.condition_concept_id
    --     AND excl.ancestor_concept_id   = 0  -- TODO: Replace with exclusion ancestor concept ID
    -- )
    --
    -- Exclusion example 2: Exclude specific source concept IDs (ICD codes that
    -- map to the outcome ancestor but represent unrelated conditions).
    -- AND co.condition_source_concept_id NOT IN (
    --   0  -- TODO: Replace with source concept IDs to exclude
    -- )

) first_outcome
WHERE first_outcome.rn = 1;
