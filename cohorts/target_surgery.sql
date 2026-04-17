-- =============================================================================
-- cohorts/target_surgery.sql
-- TARGET / EXPOSURE COHORT DEFINITION
--
-- TODO [TARGET COHORT]: Replace this template with your study's exposure
-- definition. This file defines WHO enters the study and WHEN.
--
-- WHAT TO DEFINE HERE
-- ────────────────────
-- This SQL defines:
--   • The INDEX EVENT — the procedure, drug initiation, diagnosis, or visit
--     that marks a patient's entry into the study population.
--   • The INDEX DATE (cohort_start_date) — the date of the qualifying event.
--   • COHORT EXIT (cohort_end_date) — when follow-up ends (visit end date,
--     a fixed window after index, death, or end of observation period).
--   • INCLUSION CRITERIA — who qualifies (age, visit type, required events).
--   • EXCLUSION / WASHOUT — who is disqualified (prior outcome, comorbidities).
--
-- EXPOSURE DEFINITION CHECKLIST
-- ──────────────────────────────
-- Before writing SQL, answer these questions:
--
--   1. INDEX EVENT — what is the qualifying entry event?
--        OMOP table  : procedure_occurrence | drug_exposure | condition_occurrence
--                      | visit_occurrence | observation | measurement
--        Concept IDs : Find with the query in the CONCEPT LOOKUP section below.
--
--   2. INDEX DATE — which date field marks entry?
--        Examples    : procedure_date, drug_exposure_start_date,
--                      condition_start_date, visit_start_date
--
--   3. INCLUSION CRITERIA
--        Minimum age at index  : ___ years
--        Visit type            : 9201 Inpatient | 9202 Outpatient | 9203 ED | any
--        Required prior events : (e.g. prior diagnosis, required labs)
--        Required data window  : must have ___ days of prior observation
--
--   4. EXCLUSION / WASHOUT CRITERIA
--        Prior outcome within ___ days before index?
--        Other disqualifying conditions or procedures?
--
--   5. ONE ENTRY PER PERSON? (incident vs. prevalent case definition)
--        This matters because most observational study methods assume one
--        entry per person (the "new user" or "incident" design).
--
--        First event only (ORDER BY date ASC, rn = 1)
--          → "Incident" / "new user" design. The patient enters the cohort
--            at their FIRST qualifying event. This is the standard approach
--            for new-user comparative studies and most prognostic models
--            because it avoids immortal time bias and prevalent user bias.
--
--        Most recent event (ORDER BY date DESC, rn = 1)
--          → Use when the study question focuses on the most recent exposure
--            (e.g. "last surgery before a complication").
--
--        All qualifying events (remove ROW_NUMBER filter)
--          → Use carefully — a patient can contribute multiple index dates.
--            This can inflate apparent sample size and introduces within-person
--            correlation that requires adjustment in the analysis.
--
--   6. COHORT END DATE — when does follow-up stop?
--        The cohort_end_date defines when a patient "exits" the study. Choose
--        based on what follow-up time is clinically meaningful:
--
--        Visit end date   → use for in-hospital complications (outcome must
--                            occur during the admission that triggered index).
--        DATEADD(DAY, N)  → use for fixed follow-up windows (e.g. 90-day risk).
--                            N must match prediction_window_days in config.R.
--        Death date       → use when death is an informative competing event.
--        Observation end  → use for long-term follow-up; ties exit to data
--                            availability (recommended for PLP models).
--
-- CONCEPT LOOKUP
-- ──────────────
-- Find standard OMOP concept IDs for your exposure:
--
--   SELECT concept_id, concept_name, vocabulary_id, domain_id, standard_concept
--   FROM omop_vocab.concept
--   WHERE concept_name LIKE '%your event name%'
--     AND standard_concept = 'S'
--     AND invalid_reason IS NULL
--     AND domain_id IN ('Procedure', 'Condition', 'Drug');
--
-- Use concept_ancestor rollup to capture all sub-types of a concept:
--   INNER JOIN concept_ancestor ca ON ca.descendant_concept_id = po.procedure_concept_id
--   WHERE ca.ancestor_concept_id IN (<your ancestor concept IDs>)
--
-- Verify your chosen concept IDs:
--   SELECT concept_id, concept_name, standard_concept, invalid_reason
--   FROM omop_vocab.concept
--   WHERE concept_id IN (<your concept IDs>);
--
-- Parameters (SqlRender — do not rename these):
--   @cdm_database_schema    CDM schema (config$cdm_schema)
--   @target_database_schema Results schema (config$results_schema)
--   @target_cohort_table    Cohort table name (config$cohort_table)
--   @target_cohort_id       Cohort ID for the target cohort (config$target_cohort_id)
--   @study_start_date       Study start date (config$study_start_date)
--   @study_end_date         Study end date (config$study_end_date)
-- =============================================================================

-- TODO [TARGET COHORT]: Review each TODO comment below and replace placeholder
-- values (concept_id = 0, visit_concept_id = 9201, age >= 18, etc.) with your
-- study-specific values. Remove any blocks that do not apply to your design.

DELETE FROM @target_database_schema.@target_cohort_table
WHERE cohort_definition_id = @target_cohort_id;

INSERT INTO @target_database_schema.@target_cohort_table (
  cohort_definition_id,
  subject_id,
  cohort_start_date,
  cohort_end_date
)
SELECT
  @target_cohort_id                  AS cohort_definition_id,
  qualifying_event.person_id         AS subject_id,
  qualifying_event.index_date        AS cohort_start_date,
  qualifying_event.cohort_end_date   AS cohort_end_date
FROM (
  SELECT
    vo.person_id,

    -- TODO [TARGET COHORT]: Set index date — the moment the patient "enters" the study.
    -- This date anchors all downstream analysis: covariates are measured BEFORE it,
    -- outcomes are measured AFTER it.
    -- Common choices: vo.visit_start_date, po.procedure_date,
    -- de.drug_exposure_start_date, co.condition_start_date.
    CAST(vo.visit_start_date AS DATE) AS index_date,

    -- TODO [TARGET COHORT]: Set cohort end date — when follow-up stops for this patient.
    -- This determines how long the patient is "at risk" for the outcome.
    -- See the COHORT END DATE section in the header above for guidance.
    -- Common choices:
    --   • Visit end date (as below) — for in-hospital outcomes during the index admission
    --   • DATEADD(DAY, N, vo.visit_start_date) — fixed follow-up (N = prediction_window_days)
    --   • Death date from person table — when death is a competing event
    --   • End of observation period — for long-term follow-up to data availability
    CAST(
      ISNULL(vo.visit_end_date, DATEADD(DAY, 1, vo.visit_start_date))
      AS DATE
    ) AS cohort_end_date,

    -- TODO [TARGET COHORT]: Choose event ordering for one-event-per-person logic.
    -- Most study designs require exactly one entry per person (the "new user" design).
    -- ASC  = keep the FIRST (earliest) qualifying event — standard for new-user designs.
    -- DESC = keep the MOST RECENT qualifying event.
    -- Remove the ROW_NUMBER filter at the bottom to allow multiple entries per person.
    ROW_NUMBER() OVER (
      PARTITION BY vo.person_id
      ORDER BY vo.visit_start_date ASC
    ) AS rn

  FROM @cdm_database_schema.visit_occurrence  vo
  INNER JOIN @cdm_database_schema.person       p
    ON p.person_id = vo.person_id

  WHERE

    -- TODO [TARGET COHORT]: Set visit type filter.
    -- Standard visit_concept_id values:
    --   9201 = Inpatient Visit
    --   9202 = Outpatient Visit
    --   9203 = Emergency Room Visit
    -- Remove this filter to include all visit types.
    vo.visit_concept_id = 9201

    -- Study date window (driven by config.R — do not hard-code dates here)
    AND vo.visit_start_date >= CAST('@study_start_date' AS DATE)
    AND vo.visit_start_date <= CAST('@study_end_date'   AS DATE)

    -- TODO [TARGET COHORT]: Set minimum age requirement.
    -- Change >= 18 to your threshold or remove this block if no age restriction.
    AND DATEDIFF(
          YEAR,
          DATEFROMPARTS(
            p.year_of_birth,
            ISNULL(p.month_of_birth, 7),
            ISNULL(p.day_of_birth,   1)
          ),
          vo.visit_start_date
        ) >= 18

    -- TODO [TARGET COHORT]: Define the qualifying index event.
    -- Replace concept_id = 0 with your verified standard OMOP concept ancestor IDs.
    -- This example looks for a procedure during the qualifying visit.
    -- For drug/condition-based entry events, adapt the inner table and join accordingly.
    AND EXISTS (
      SELECT 1
      FROM @cdm_database_schema.procedure_occurrence po
      INNER JOIN @cdm_database_schema.concept_ancestor ca
        ON ca.descendant_concept_id = po.procedure_concept_id
      WHERE ca.ancestor_concept_id IN (
        0   -- TODO [TARGET COHORT]: Replace 0 with your procedure ancestor concept ID(s).
            -- Add more IDs separated by commas if the exposure has multiple parent concepts.
      )
        AND po.person_id      = vo.person_id
        AND po.procedure_date BETWEEN vo.visit_start_date
                                  AND ISNULL(vo.visit_end_date, vo.visit_start_date)
    )

    -- TODO [TARGET COHORT]: Define washout / exclusion criteria (optional).
    --
    -- A washout period excludes patients who already had the outcome (or the exposure)
    -- before the index date. This is important for two reasons:
    --
    --   1. INCIDENT case design — for prognostic models and new-user designs you want
    --      patients who are truly NEW to the exposure or outcome. Patients who already
    --      had the outcome before entry are "prevalent" cases and would bias the model.
    --
    --   2. Immortal time / selection bias — patients who enter despite having the outcome
    --      already create a situation where the model appears to predict something that
    --      was already determined before the index date.
    --
    -- How long should the washout window be?
    --   • 365 days is a common default (one full year of prior history).
    --   • Use longer windows (e.g. all prior history) for rare outcomes that are unlikely
    --     to recur if they happened years ago.
    --   • Match the washout window to the minimum prior observation requirement in
    --     workflow/02 Section C (min_prior_observation_days).
    --
    -- Replace concept_id = 0 with your washout condition ancestor concept ID.
    -- Remove this entire block if no washout is needed for your design.
    AND NOT EXISTS (
      SELECT 1
      FROM @cdm_database_schema.condition_occurrence  prior_event
      INNER JOIN @cdm_database_schema.concept_ancestor ca
        ON ca.descendant_concept_id = prior_event.condition_concept_id
      WHERE
        ca.ancestor_concept_id = 0    -- TODO [TARGET COHORT]: Replace 0 with washout concept ID
        AND prior_event.person_id = vo.person_id
        AND prior_event.condition_start_date
              BETWEEN DATEADD(DAY, -365, vo.visit_start_date)  -- TODO: adjust to match min_prior_observation_days
                  AND DATEADD(DAY,   -1, vo.visit_start_date)
    )

) qualifying_event
WHERE qualifying_event.rn = 1;
