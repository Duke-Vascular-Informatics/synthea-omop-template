-- =============================================================================
-- cohorts/outcome_ssi.sql
-- Outcome cohort: patients diagnosed with a surgical site infection.
--
-- Index date  : first SSI condition occurrence date per person
-- Cohort end  : condition end date (or index + 1 day if absent)
-- Inclusion   : any condition concept that is a descendant of the SSI /
--               wound-infection ancestor concepts listed below
-- Study window: @study_start_date – @study_end_date
--
-- Parameters (SqlRender):
--   @cdm_database_schema    CDM schema, e.g. cdm_synthea
--   @target_database_schema Results schema, e.g. plp_results
--   @target_cohort_table    Cohort table name, e.g. ssi_val_cohort
--   @outcome_cohort_id      Cohort definition id for the outcome (e.g. 2)
--   @study_start_date       Earliest admissible condition start date
--   @study_end_date         Latest admissible condition start date
--
-- Ancestor concept IDs used (verify against your concept table):
--   4201004  Infection of wound            (SNOMED: 76844004)
--   4318887  Surgical wound infection      (SNOMED: 433202001)
--   40480632 Infected wound                (SNOMED: 444948002, if present)
--   4110523  Complication of procedure     (SNOMED: 116223007, broader parent
--            – included to catch ICD-10-coded SSI records T81.4 that may map
--            here in some vocabularies)
--
-- Tip: run the query below against cdm_synthea to confirm concept coverage
-- before running the pipeline:
--   SELECT c.concept_id, c.concept_name, c.vocabulary_id
--   FROM   cdm_synthea.concept c
--   INNER JOIN cdm_synthea.concept_ancestor ca
--     ON ca.descendant_concept_id = c.concept_id
--   WHERE ca.ancestor_concept_id IN (4201004, 4318887, 40480632, 4110523)
--     AND c.standard_concept = 'S'
--   ORDER BY c.concept_name;
-- =============================================================================

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
  first_ssi.person_id                              AS subject_id,
  first_ssi.condition_start_date                   AS cohort_start_date,
  ISNULL(
    first_ssi.condition_end_date,
    DATEADD(DAY, 1, first_ssi.condition_start_date)
  )                                                AS cohort_end_date
FROM (
  -- Earliest SSI diagnosis per person within the study window
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
    (
      ca.ancestor_concept_id IN (
        4201004,   -- Infection of wound
        4318887,   -- Surgical wound infection
        40480632,  -- Infected wound
        4110523    -- Complication of procedure (broader; catches T81.4 mappings)
      )
      OR co.condition_source_value = '76844004'
    )
    AND co.condition_start_date >= CAST('@study_start_date' AS DATE)
    AND co.condition_start_date <= CAST('@study_end_date'   AS DATE)
) first_ssi
WHERE first_ssi.rn = 1;
