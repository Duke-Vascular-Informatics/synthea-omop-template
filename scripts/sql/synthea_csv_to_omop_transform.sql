-- =============================================================================
-- scripts/sql/synthea_csv_to_omop_transform.sql
-- Draft Synthea CSV -> OMOP transform (SQL Server via SqlRender)
-- =============================================================================

-- [BLOCK: cleanup]
DELETE FROM @cdm_schema.condition_occurrence
WHERE person_id IN (
  SELECT person_id FROM @cdm_schema.person
  WHERE person_source_value LIKE 'synthea_csv:%'
);

DELETE FROM @cdm_schema.procedure_occurrence
WHERE person_id IN (
  SELECT person_id FROM @cdm_schema.person
  WHERE person_source_value LIKE 'synthea_csv:%'
);

DELETE FROM @cdm_schema.visit_occurrence
WHERE visit_source_value LIKE 'synthea_csv:%';

DELETE FROM @cdm_schema.person
WHERE person_source_value LIKE 'synthea_csv:%';

-- [BLOCK: person]
WITH patient_src AS (
  SELECT
      s.patient_id,
      TRY_CONVERT(date, s.birth_date) AS birth_date,
      LOWER(s.gender) AS gender_text
  FROM @staging_schema.patients_stage s
  WHERE s.run_name = '@run_name'
),
patient_dedup AS (
  SELECT
      patient_id,
      birth_date,
      gender_text,
      ROW_NUMBER() OVER (PARTITION BY patient_id ORDER BY patient_id) AS rn
  FROM patient_src
)
INSERT INTO @cdm_schema.person (
    person_id,
    gender_concept_id,
    year_of_birth,
    month_of_birth,
    day_of_birth,
    race_concept_id,
    ethnicity_concept_id,
    location_id,
    provider_id,
    care_site_id,
    person_source_value,
    gender_source_value,
    gender_source_concept_id,
    race_source_value,
    race_source_concept_id,
    ethnicity_source_value,
    ethnicity_source_concept_id
)
SELECT
    ROW_NUMBER() OVER (ORDER BY p.patient_id)
      + COALESCE((SELECT MAX(person_id) FROM @cdm_schema.person), 0) AS person_id,
    CASE
      WHEN p.gender_text = 'm' OR p.gender_text = 'male' THEN 8507
      WHEN p.gender_text = 'f' OR p.gender_text = 'female' THEN 8532
      ELSE 8551
    END AS gender_concept_id,
    YEAR(p.birth_date) AS year_of_birth,
    MONTH(p.birth_date) AS month_of_birth,
    DAY(p.birth_date) AS day_of_birth,
    0,
    0,
    NULL,
    NULL,
    NULL,
    CONCAT('synthea_csv:', p.patient_id),
    p.gender_text,
    0,
    NULL,
    0,
    NULL,
    0
FROM patient_dedup p
WHERE p.rn = 1
  AND p.birth_date IS NOT NULL;

-- [BLOCK: visit]
WITH encounter_src AS (
  SELECT
      s.encounter_id,
      s.patient_id,
      TRY_CONVERT(datetime2, s.start_datetime) AS visit_start_datetime,
      TRY_CONVERT(datetime2, s.end_datetime) AS visit_end_datetime,
      LOWER(s.encounter_class) AS encounter_class
  FROM @staging_schema.encounters_stage s
  WHERE s.run_name = '@run_name'
),
encounter_dedup AS (
  SELECT
      encounter_id,
      patient_id,
      visit_start_datetime,
      visit_end_datetime,
      encounter_class,
      ROW_NUMBER() OVER (PARTITION BY encounter_id ORDER BY visit_start_datetime, encounter_id) AS rn
  FROM encounter_src
),
encounter_with_person AS (
  SELECT
      e.encounter_id,
      p.person_id,
      e.visit_start_datetime,
      e.visit_end_datetime,
      CASE
        WHEN e.encounter_class IN ('inpatient', 'imp') THEN 9201
        WHEN e.encounter_class IN ('outpatient', 'ambulatory', 'amb') THEN 9202
        WHEN e.encounter_class IN ('emergency', 'emerg') THEN 9203
        ELSE 0
      END AS visit_concept_id
  FROM encounter_dedup e
  INNER JOIN @cdm_schema.person p
    ON p.person_source_value = CONCAT('synthea_csv:', e.patient_id)
  WHERE e.rn = 1
)
INSERT INTO @cdm_schema.visit_occurrence (
    visit_occurrence_id,
    person_id,
    visit_concept_id,
    visit_start_date,
    visit_start_datetime,
    visit_end_date,
    visit_end_datetime,
    visit_type_concept_id,
    provider_id,
    care_site_id,
    visit_source_value,
    visit_source_concept_id,
    admitted_from_concept_id,
    admitted_from_source_value,
    discharged_to_concept_id,
    discharged_to_source_value,
    preceding_visit_occurrence_id
)
SELECT
    ROW_NUMBER() OVER (ORDER BY e.encounter_id)
      + COALESCE((SELECT MAX(visit_occurrence_id) FROM @cdm_schema.visit_occurrence), 0) AS visit_occurrence_id,
    e.person_id,
    e.visit_concept_id,
    CAST(e.visit_start_datetime AS date),
    e.visit_start_datetime,
    CAST(COALESCE(e.visit_end_datetime, e.visit_start_datetime) AS date),
    COALESCE(e.visit_end_datetime, e.visit_start_datetime),
    32817,
    NULL,
    NULL,
    CONCAT('synthea_csv:', e.encounter_id),
    0,
    0,
    NULL,
    0,
    NULL,
    NULL
FROM encounter_with_person e
WHERE e.visit_start_datetime IS NOT NULL;

-- [BLOCK: procedure]
WITH procedure_src AS (
  SELECT
      s.patient_id,
      s.encounter_id,
      TRY_CONVERT(datetime2, s.procedure_date) AS procedure_datetime,
      s.source_code,
      s.source_display
  FROM @staging_schema.procedures_stage s
  WHERE s.run_name = '@run_name'
),
procedure_with_refs AS (
  SELECT
      p.person_id,
      v.visit_occurrence_id,
      s.procedure_datetime,
      s.source_code,
      s.source_display,
      ROW_NUMBER() OVER (
        ORDER BY p.person_id, s.procedure_datetime, s.source_code, COALESCE(s.source_display, '')
      ) AS rn
  FROM procedure_src s
  INNER JOIN @cdm_schema.person p
    ON p.person_source_value = CONCAT('synthea_csv:', s.patient_id)
  LEFT JOIN @cdm_schema.visit_occurrence v
    ON v.visit_source_value = CONCAT('synthea_csv:', s.encounter_id)
)
INSERT INTO @cdm_schema.procedure_occurrence (
    procedure_occurrence_id,
    person_id,
    procedure_concept_id,
    procedure_date,
    procedure_datetime,
    procedure_end_date,
    procedure_end_datetime,
    procedure_type_concept_id,
    modifier_concept_id,
    quantity,
    provider_id,
    visit_occurrence_id,
    visit_detail_id,
    procedure_source_value,
    procedure_source_concept_id,
    modifier_source_value
)
SELECT
    p.rn + COALESCE((SELECT MAX(procedure_occurrence_id) FROM @cdm_schema.procedure_occurrence), 0),
    p.person_id,
    COALESCE(c.concept_id, 0) AS procedure_concept_id,
    CAST(p.procedure_datetime AS date),
    p.procedure_datetime,
    CAST(p.procedure_datetime AS date),
    p.procedure_datetime,
    32817,
    NULL,
    1,
    NULL,
    p.visit_occurrence_id,
    NULL,
    p.source_code,
    0,
    NULL
FROM procedure_with_refs p
LEFT JOIN @cdm_schema.concept c
  ON c.concept_code = p.source_code
 AND c.vocabulary_id = 'SNOMED'
 AND c.standard_concept = 'S'
WHERE p.procedure_datetime IS NOT NULL;

-- [BLOCK: condition]
WITH condition_src AS (
  SELECT
      s.patient_id,
      s.encounter_id,
      TRY_CONVERT(datetime2, s.condition_start) AS condition_start_datetime,
      TRY_CONVERT(datetime2, s.condition_end) AS condition_end_datetime,
      s.source_code,
      s.source_display
  FROM @staging_schema.conditions_stage s
  WHERE s.run_name = '@run_name'
),
condition_with_refs AS (
  SELECT
      p.person_id,
      v.visit_occurrence_id,
      s.condition_start_datetime,
      s.condition_end_datetime,
      s.source_code,
      s.source_display,
      ROW_NUMBER() OVER (
        ORDER BY p.person_id, s.condition_start_datetime, s.source_code, COALESCE(s.source_display, '')
      ) AS rn
  FROM condition_src s
  INNER JOIN @cdm_schema.person p
    ON p.person_source_value = CONCAT('synthea_csv:', s.patient_id)
  LEFT JOIN @cdm_schema.visit_occurrence v
    ON v.visit_source_value = CONCAT('synthea_csv:', s.encounter_id)
)
INSERT INTO @cdm_schema.condition_occurrence (
    condition_occurrence_id,
    person_id,
    condition_concept_id,
    condition_start_date,
    condition_start_datetime,
    condition_end_date,
    condition_end_datetime,
    condition_type_concept_id,
    condition_status_concept_id,
    stop_reason,
    provider_id,
    visit_occurrence_id,
    visit_detail_id,
    condition_source_value,
    condition_source_concept_id,
    condition_status_source_value
)
SELECT
    c.rn + COALESCE((SELECT MAX(condition_occurrence_id) FROM @cdm_schema.condition_occurrence), 0),
    c.person_id,
    COALESCE(
      cc.concept_id,
      CASE
        WHEN c.source_code = '76844004' THEN 4201004
        WHEN c.source_code = '399957001' THEN 321052
        ELSE 0
      END
    ) AS condition_concept_id,
    CAST(c.condition_start_datetime AS date),
    c.condition_start_datetime,
    CAST(COALESCE(c.condition_end_datetime, c.condition_start_datetime) AS date),
    COALESCE(c.condition_end_datetime, c.condition_start_datetime),
    32817,
    0,
    NULL,
    NULL,
    c.visit_occurrence_id,
    NULL,
    c.source_code,
    0,
    c.source_display
FROM condition_with_refs c
LEFT JOIN @cdm_schema.concept cc
  ON cc.concept_code = c.source_code
 AND cc.vocabulary_id = 'SNOMED'
 AND cc.standard_concept = 'S'
WHERE c.condition_start_datetime IS NOT NULL;
