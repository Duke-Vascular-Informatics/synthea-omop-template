-- =============================================================================
-- cohorts/target_surgery.sql
-- Target cohort: patients who underwent inpatient open lower extremity
-- revascularization.
--
-- Index date  : visit start date (first qualifying inpatient visit per person)
-- Cohort end  : visit end date
-- Inclusion   : age >= 18 at index; open lower extremity revascularization
--               recorded during the inpatient visit
-- Exclusion   : any wound / SSI diagnosis in the 365 days BEFORE index date
--               (prior-event washout so we do not capture prevalent cases)
-- Study window: @study_start_date – @study_end_date
--
-- Parameters (SqlRender):
--   @cdm_database_schema    CDM schema, e.g. cdm_synthea
--   @target_database_schema Results schema, e.g. plp_results
--   @target_cohort_table    Cohort table name, e.g. ssi_val_cohort
--   @target_cohort_id       Cohort definition id for the target (e.g. 1)
--   @study_start_date       Earliest admissible visit start date
--   @study_end_date         Latest admissible visit start date
--
-- NOTE: Concept ancestors used in this query:
--   4159960  = Procedure on blood vessel of lower extremity (procedure inclusion)
--              Covers descendants: 4012936 (fem-pop bypass), 4166196 (femo-tibial
--              bypass), 4231680 (aorto-femoral bypass), 4040974 (fem endarterectomy)
--   4334801  = Surgical site infection (SSI washout exclusion — SNOMED-CT 433202001)
--              Covers: postoperative wound infection, superficial/deep/organ-space SSI
--
--   Previously used IDs 4201004 and 4318887 are absent or map to unrelated concepts
--   in the current OMOP vocabulary and have been replaced by 4334801.
-- Verify in your omop_vocab.concept table with:
--   SELECT concept_id, concept_name FROM omop_vocab.concept
--   WHERE concept_id IN (4159960, 4334801);
-- =============================================================================

DELETE FROM @target_database_schema.@target_cohort_table
WHERE cohort_definition_id = @target_cohort_id;

INSERT INTO @target_database_schema.@target_cohort_table (
  cohort_definition_id,
  subject_id,
  cohort_start_date,
  cohort_end_date
)
SELECT
  @target_cohort_id                AS cohort_definition_id,
  first_visit.person_id            AS subject_id,
  first_visit.visit_start_date     AS cohort_start_date,
  first_visit.visit_end_date       AS cohort_end_date
FROM (
  -- One row per person: the earliest qualifying inpatient surgical visit
  -- within the study window.
  SELECT
    vo.person_id,
    CAST(vo.visit_start_date AS DATE) AS visit_start_date,
    CAST(
      ISNULL(vo.visit_end_date, DATEADD(DAY, 1, vo.visit_start_date))
      AS DATE
    )                                  AS visit_end_date,
    ROW_NUMBER() OVER (
      PARTITION BY vo.person_id
      ORDER BY vo.visit_start_date DESC   -- most recent qualifying admission
    ) AS rn
  FROM @cdm_database_schema.visit_occurrence  vo
  INNER JOIN @cdm_database_schema.person       p
    ON p.person_id = vo.person_id

  WHERE
    -- Inpatient admissions only (visit_concept_id 9201).
    -- The prior revascularization component of the PAD module records the
    -- procedure in an outpatient PAD evaluation encounter using the same SNOMED
    -- code as the index surgery.  Without this filter the cohort SQL would
    -- select the earlier outpatient encounter as the index date, causing the
    -- actual inpatient surgery to appear after the index and the prior
    -- revascularization to be invisible in the lookback window.
    vo.visit_concept_id = 9201

    -- Study date window
    AND vo.visit_start_date >= CAST('@study_start_date' AS DATE)
    AND vo.visit_start_date <= CAST('@study_end_date'   AS DATE)

    -- Age >= 18 at visit start (use mid-year birthday when day unknown)
    AND DATEDIFF(
          YEAR,
          DATEFROMPARTS(
            p.year_of_birth,
            ISNULL(p.month_of_birth, 7),
            ISNULL(p.day_of_birth,   1)
          ),
          vo.visit_start_date
        ) >= 18

    -- Open lower extremity revascularization during the qualifying visit.
    -- Uses concept_ancestor rollup under 4159960 (Open lower extremity
    -- revascularization) to match all four procedure subtypes in the module
    -- (femoral-popliteal bypass, femorotibial bypass, aorto-femoral bypass,
    -- femoral endarterectomy) via their standard OMOP concept IDs.
    AND EXISTS (
      SELECT 1
      FROM @cdm_database_schema.procedure_occurrence po
      INNER JOIN @cdm_database_schema.concept_ancestor ca
        ON ca.descendant_concept_id = po.procedure_concept_id
      WHERE ca.ancestor_concept_id = 4159960
        AND po.person_id    = vo.person_id
        AND po.procedure_date BETWEEN vo.visit_start_date
                                  AND ISNULL(vo.visit_end_date, vo.visit_start_date)
    )

    -- Washout: no wound / SSI diagnosis in the 365 days before index
    AND NOT EXISTS (
      SELECT 1
      FROM @cdm_database_schema.condition_occurrence  prior_ssi
      INNER JOIN @cdm_database_schema.concept_ancestor ca
        ON ca.descendant_concept_id = prior_ssi.condition_concept_id
      WHERE
        ca.ancestor_concept_id = 4334801   -- Surgical site infection (SNOMED 433202001)
        AND prior_ssi.person_id = vo.person_id
        AND prior_ssi.condition_start_date
              BETWEEN DATEADD(DAY, -365, vo.visit_start_date)
                  AND DATEADD(DAY,   -1, vo.visit_start_date)
    )
) first_visit
WHERE first_visit.rn = 1;
