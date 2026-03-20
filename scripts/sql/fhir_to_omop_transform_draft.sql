-- =============================================================================
-- scripts/sql/fhir_to_omop_transform_draft.sql
-- Draft FHIR -> OMOP transform (SQL Server dialect via SqlRender).
--
-- Parameters rendered by SqlRender:
--   @run_name
--   @staging_schema
--   @cdm_schema
--
-- Scope (draft):
--   - Patient -> person
--   - Encounter -> visit_occurrence
--   - Condition -> condition_occurrence
--
-- Notes:
--   1) This is a scaffold and intentionally conservative.
--   2) Concept IDs are placeholders where source coding is not fully mapped.
--   3) Add joins to concept / source_to_concept_map for production-grade mapping.
-- =============================================================================

-- -------------------------
-- Patient -> PERSON
-- -------------------------
WITH patient_src AS (
  SELECT
      fr.run_name,
      fr.resource_id AS patient_resource_id,
      TRY_CONVERT(date, JSON_VALUE(fr.payload_json, '$.birthDate')) AS birth_date,
      LOWER(JSON_VALUE(fr.payload_json, '$.gender')) AS gender_text
  FROM @staging_schema.fhir_raw_resource fr
  WHERE fr.run_name = '@run_name'
    AND fr.resource_type = 'Patient'
),
patient_typed AS (
  SELECT
      run_name,
      patient_resource_id,
      YEAR(birth_date) AS year_of_birth,
      MONTH(birth_date) AS month_of_birth,
      DAY(birth_date) AS day_of_birth,
      CASE
        WHEN gender_text = 'male' THEN 8507
        WHEN gender_text = 'female' THEN 8532
        ELSE 8551
      END AS gender_concept_id,
      CAST(ABS(CHECKSUM(CONCAT(run_name, ':patient:', patient_resource_id))) AS BIGINT) AS person_id
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
    p.person_id,
    p.gender_concept_id,
    p.year_of_birth,
    p.month_of_birth,
    p.day_of_birth,
    0,
    0,
    NULL,
    NULL,
    NULL,
    CONCAT('fhir:', p.patient_resource_id),
    NULL,
    0,
    NULL,
    0,
    NULL,
    0
FROM patient_typed p
WHERE NOT EXISTS (
  SELECT 1 FROM @cdm_schema.person x WHERE x.person_id = p.person_id
);

-- -------------------------
-- Encounter -> VISIT_OCCURRENCE
-- -------------------------
WITH encounter_src AS (
  SELECT
      fr.run_name,
      fr.resource_id AS encounter_resource_id,
      JSON_VALUE(fr.payload_json, '$.subject.reference') AS subject_reference,
      JSON_VALUE(fr.payload_json, '$.period.start') AS visit_start_ts,
      JSON_VALUE(fr.payload_json, '$.period.end') AS visit_end_ts,
      LOWER(JSON_VALUE(fr.payload_json, '$.class.code')) AS encounter_class_code
  FROM @staging_schema.fhir_raw_resource fr
  WHERE fr.run_name = '@run_name'
    AND fr.resource_type = 'Encounter'
),
encounter_typed AS (
  SELECT
      run_name,
      encounter_resource_id,
      REPLACE(subject_reference, 'Patient/', '') AS patient_resource_id,
      TRY_CONVERT(datetime2, visit_start_ts) AS visit_start_datetime,
      TRY_CONVERT(datetime2, visit_end_ts) AS visit_end_datetime,
      CASE
        WHEN encounter_class_code IN ('imp', 'inpatient') THEN 9201
        WHEN encounter_class_code IN ('amb', 'outpatient') THEN 9202
        WHEN encounter_class_code IN ('emergency', 'emerg') THEN 9203
        ELSE 0
      END AS visit_concept_id,
      CAST(ABS(CHECKSUM(CONCAT(run_name, ':encounter:', encounter_resource_id))) AS BIGINT) AS visit_occurrence_id,
      CAST(ABS(CHECKSUM(CONCAT(run_name, ':patient:', REPLACE(subject_reference, 'Patient/', '')))) AS BIGINT) AS person_id
  FROM encounter_src
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
    e.visit_occurrence_id,
    e.person_id,
    e.visit_concept_id,
    CAST(e.visit_start_datetime AS date),
    e.visit_start_datetime,
    CAST(COALESCE(e.visit_end_datetime, e.visit_start_datetime) AS date),
    COALESCE(e.visit_end_datetime, e.visit_start_datetime),
    32817,
    NULL,
    NULL,
    CONCAT('fhir:', e.encounter_resource_id),
    0,
    0,
    NULL,
    0,
    NULL,
    NULL
FROM encounter_typed e
WHERE e.visit_start_datetime IS NOT NULL
  AND NOT EXISTS (
    SELECT 1 FROM @cdm_schema.visit_occurrence x WHERE x.visit_occurrence_id = e.visit_occurrence_id
  );

-- -------------------------
-- Condition -> CONDITION_OCCURRENCE
-- -------------------------
WITH condition_src AS (
  SELECT
      fr.run_name,
      fr.resource_id AS condition_resource_id,
      JSON_VALUE(fr.payload_json, '$.subject.reference') AS subject_reference,
      JSON_VALUE(fr.payload_json, '$.encounter.reference') AS encounter_reference,
      JSON_VALUE(fr.payload_json, '$.onsetDateTime') AS onset_datetime,
      JSON_VALUE(fr.payload_json, '$.code.coding[0].code') AS source_code,
      JSON_VALUE(fr.payload_json, '$.code.coding[0].system') AS source_system,
      JSON_VALUE(fr.payload_json, '$.code.coding[0].display') AS source_display
  FROM @staging_schema.fhir_raw_resource fr
  WHERE fr.run_name = '@run_name'
    AND fr.resource_type = 'Condition'
),
condition_typed AS (
  SELECT
      run_name,
      condition_resource_id,
      REPLACE(subject_reference, 'Patient/', '') AS patient_resource_id,
      REPLACE(encounter_reference, 'Encounter/', '') AS encounter_resource_id,
      TRY_CONVERT(datetime2, onset_datetime) AS condition_start_datetime,
      source_code,
      source_system,
      source_display,
      CAST(ABS(CHECKSUM(CONCAT(run_name, ':condition:', condition_resource_id))) AS BIGINT) AS condition_occurrence_id,
      CAST(ABS(CHECKSUM(CONCAT(run_name, ':patient:', REPLACE(subject_reference, 'Patient/', '')))) AS BIGINT) AS person_id,
      CAST(ABS(CHECKSUM(CONCAT(run_name, ':encounter:', REPLACE(encounter_reference, 'Encounter/', '')))) AS BIGINT) AS visit_occurrence_id
  FROM condition_src
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
    c.condition_occurrence_id,
    c.person_id,
    0, -- TODO: map source_code/source_system to standard OMOP concept_id
    CAST(c.condition_start_datetime AS date),
    c.condition_start_datetime,
    CAST(c.condition_start_datetime AS date),
    c.condition_start_datetime,
    32817,
    0,
    NULL,
    NULL,
    v.visit_occurrence_id,
    NULL,
    c.source_code,
    0,
    c.source_display
FROM condition_typed c
LEFT JOIN @cdm_schema.visit_occurrence v
  ON v.visit_occurrence_id = c.visit_occurrence_id
WHERE c.condition_start_datetime IS NOT NULL
  AND NOT EXISTS (
    SELECT 1 FROM @cdm_schema.condition_occurrence x WHERE x.condition_occurrence_id = c.condition_occurrence_id
  );

-- Optional run-level audit query
SELECT
    '@run_name' AS run_name,
    (SELECT COUNT(*) FROM @staging_schema.fhir_raw_resource WHERE run_name = '@run_name') AS staged_resource_count,
    (SELECT COUNT(*) FROM @cdm_schema.person p WHERE p.person_source_value LIKE 'fhir:%') AS person_rows_total_fhir,
    (SELECT COUNT(*) FROM @cdm_schema.visit_occurrence v WHERE v.visit_source_value LIKE 'fhir:%') AS visit_rows_total_fhir,
    (SELECT COUNT(*) FROM @cdm_schema.condition_occurrence c WHERE c.condition_source_value IS NOT NULL) AS condition_rows_total;
