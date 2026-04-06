-- =============================================================================
-- cohorts/outcome_ssi.sql
-- Outcome cohort: patients diagnosed with a surgical site infection.
--
-- Index date  : first SSI condition occurrence date per person
-- Cohort end  : condition end date (or index + 1 day if absent)
-- Inclusion   : any condition concept that is a descendant of the SSI
--               ancestor concept listed below
-- Study window: @study_start_date – @study_end_date
--
-- Parameters (SqlRender):
--   @cdm_database_schema    CDM schema, e.g. omop_synth_pad_oler_ssi_02
--   @target_database_schema Results schema, e.g. plp_results
--   @target_cohort_table    Cohort table name, e.g. ssi_val_cohort
--   @outcome_cohort_id      Cohort definition id for the outcome (e.g. 2)
--   @study_start_date       Earliest admissible condition start date
--   @study_end_date         Latest admissible condition start date
--
-- Ancestor concept ID used (verified against omop_vocab.concept):
--   4334801  Surgical site infection  (SNOMED-CT 433202001, standard Condition)
--
--   Descendants include (min_levels_of_separation shown):
--     4237450  Postoperative wound infection                           (1)
--     43530818 Superficial incisional surgical site infection          (2)
--     4308542  Postoperative wound infection - deep                    (2)
--     4308837  Postoperative wound infection - superficial             (2)
--     4145549  MRSA infection of postoperative wound                   (2)
--     43530819 Deep incisional surgical site infection                 (3)
--     43530820 Organ-space surgical site infection                     (3)
--     42538804 Organ surgical site infection                           (3)
--
-- NOTE: Previously used ancestor IDs (4201004, 4318887, 40480632, 4110523)
--   are NOT present or map to unrelated concepts in the current OMOP vocabulary
--   (v5.0 2024-10-01 and later). They have been replaced by 4334801.
--   Verify with:
--     SELECT concept_id, concept_name FROM omop_vocab.concept
--     WHERE concept_id IN (4201004, 4318887, 40480632, 4110523, 4334801);
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
    ca.ancestor_concept_id = 4334801   -- Surgical site infection (SNOMED 433202001)
    AND co.condition_start_date >= CAST('@study_start_date' AS DATE)
    AND co.condition_start_date <= CAST('@study_end_date'   AS DATE)
) first_ssi
WHERE first_ssi.rn = 1;
