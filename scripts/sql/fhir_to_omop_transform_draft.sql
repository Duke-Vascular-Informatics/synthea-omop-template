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
--   - Procedure -> procedure_occurrence
--   - Condition -> condition_occurrence
-- =============================================================================

-- [BLOCK: cleanup]
-- Remove all FHIR-sourced rows in FK-safe order before inserting.
-- This guarantees a clean slate regardless of previous partial runs.
DELETE FROM @cdm_schema.condition_occurrence
WHERE person_id IN (
    SELECT person_id FROM @cdm_schema.person
    WHERE person_source_value LIKE 'fhir:%'
);

DELETE FROM @cdm_schema.procedure_occurrence
WHERE person_id IN (
    SELECT person_id FROM @cdm_schema.person
    WHERE person_source_value LIKE 'fhir:%'
);

DELETE FROM @cdm_schema.visit_occurrence
WHERE visit_source_value LIKE 'fhir:%';

DELETE FROM @cdm_schema.person
WHERE person_source_value LIKE 'fhir:%';

-- [BLOCK: person]
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
patient_dedup AS (
  SELECT
      patient_resource_id,
      birth_date,
      gender_text,
      ROW_NUMBER() OVER (PARTITION BY patient_resource_id ORDER BY patient_resource_id) AS rn
  FROM patient_src
),
patient_typed AS (
  SELECT
      patient_resource_id,
      YEAR(birth_date) AS year_of_birth,
      MONTH(birth_date) AS month_of_birth,
      DAY(birth_date) AS day_of_birth,
      CASE
        WHEN gender_text = 'male' THEN 8507
        WHEN gender_text = 'female' THEN 8532
        ELSE 8551
      END AS gender_concept_id
  FROM patient_dedup
  WHERE rn = 1
),
patient_new AS (
  SELECT
      p.patient_resource_id,
      p.year_of_birth,
      p.month_of_birth,
      p.day_of_birth,
      p.gender_concept_id,
      ROW_NUMBER() OVER (ORDER BY p.patient_resource_id)
        + COALESCE((SELECT MAX(person_id) FROM @cdm_schema.person), 0) AS person_id
  FROM patient_typed p
  WHERE NOT EXISTS (
    SELECT 1
    FROM @cdm_schema.person x
    WHERE x.person_source_value = CONCAT('fhir:', p.patient_resource_id)
  )
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
FROM patient_new p;

-- [BLOCK: visit]
-- -------------------------
-- Encounter -> VISIT_OCCURRENCE
-- -------------------------
WITH encounter_src AS (
  SELECT
      fr.resource_id AS encounter_resource_id,
      JSON_VALUE(fr.payload_json, '$.subject.reference') AS subject_reference,
      JSON_VALUE(fr.payload_json, '$.period.start') AS visit_start_ts,
      JSON_VALUE(fr.payload_json, '$.period.end') AS visit_end_ts,
      LOWER(JSON_VALUE(fr.payload_json, '$.class.code')) AS encounter_class_code
  FROM @staging_schema.fhir_raw_resource fr
  WHERE fr.run_name = '@run_name'
    AND fr.resource_type = 'Encounter'
),
encounter_dedup AS (
  SELECT
      encounter_resource_id,
      subject_reference,
      visit_start_ts,
      visit_end_ts,
      encounter_class_code,
      ROW_NUMBER() OVER (PARTITION BY encounter_resource_id ORDER BY visit_start_ts, encounter_resource_id) AS rn
  FROM encounter_src
),
encounter_typed AS (
  SELECT
      encounter_resource_id,
      CASE
        WHEN subject_reference LIKE 'Patient/%' THEN REPLACE(subject_reference, 'Patient/', '')
        WHEN subject_reference LIKE 'urn:uuid:%' THEN REPLACE(subject_reference, 'urn:uuid:', '')
        ELSE subject_reference
      END AS patient_resource_id,
      TRY_CONVERT(datetime2, visit_start_ts) AS visit_start_datetime,
      TRY_CONVERT(datetime2, visit_end_ts) AS visit_end_datetime,
      CASE
        WHEN encounter_class_code IN ('imp', 'inpatient') THEN 9201
        WHEN encounter_class_code IN ('amb', 'outpatient') THEN 9202
        WHEN encounter_class_code IN ('emergency', 'emerg') THEN 9203
        ELSE 0
      END AS visit_concept_id
  FROM encounter_dedup
  WHERE rn = 1
),
encounter_with_person AS (
  SELECT
      e.encounter_resource_id,
      p.person_id,
      e.visit_start_datetime,
      e.visit_end_datetime,
      e.visit_concept_id
  FROM encounter_typed e
  INNER JOIN @cdm_schema.person p
    ON p.person_source_value = CONCAT('fhir:', e.patient_resource_id)
),
encounter_new AS (
  SELECT
      e.encounter_resource_id,
      e.person_id,
      e.visit_start_datetime,
      e.visit_end_datetime,
      e.visit_concept_id,
      ROW_NUMBER() OVER (ORDER BY e.encounter_resource_id)
        + COALESCE((SELECT MAX(visit_occurrence_id) FROM @cdm_schema.visit_occurrence), 0) AS visit_occurrence_id
  FROM encounter_with_person e
  WHERE e.visit_start_datetime IS NOT NULL
    AND NOT EXISTS (
      SELECT 1
      FROM @cdm_schema.visit_occurrence x
      WHERE x.visit_source_value = CONCAT('fhir:', e.encounter_resource_id)
    )
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
FROM encounter_new e;

-- [BLOCK: procedure]
-- -------------------------
-- Procedure -> PROCEDURE_OCCURRENCE
-- -------------------------
WITH procedure_src AS (
  SELECT
      fr.resource_id AS procedure_resource_id,
      JSON_VALUE(fr.payload_json, '$.subject.reference') AS subject_reference,
      JSON_VALUE(fr.payload_json, '$.encounter.reference') AS encounter_reference,
      COALESCE(
        JSON_VALUE(fr.payload_json, '$.performedPeriod.start'),
        JSON_VALUE(fr.payload_json, '$.performedDateTime')
      ) AS procedure_start_ts,
      COALESCE(
        JSON_VALUE(fr.payload_json, '$.performedPeriod.end'),
        JSON_VALUE(fr.payload_json, '$.performedDateTime')
      ) AS procedure_end_ts,
      JSON_VALUE(fr.payload_json, '$.code.coding[0].code') AS source_code,
      JSON_VALUE(fr.payload_json, '$.code.coding[0].display') AS source_display
  FROM @staging_schema.fhir_raw_resource fr
  WHERE fr.run_name = '@run_name'
    AND fr.resource_type = 'Procedure'
),
procedure_dedup AS (
  SELECT
      procedure_resource_id,
      subject_reference,
      encounter_reference,
      procedure_start_ts,
      procedure_end_ts,
      source_code,
      source_display,
      ROW_NUMBER() OVER (PARTITION BY procedure_resource_id ORDER BY procedure_start_ts, procedure_resource_id) AS rn
  FROM procedure_src
),
procedure_typed AS (
  SELECT
      procedure_resource_id,
      CASE
        WHEN subject_reference LIKE 'Patient/%' THEN REPLACE(subject_reference, 'Patient/', '')
        WHEN subject_reference LIKE 'urn:uuid:%' THEN REPLACE(subject_reference, 'urn:uuid:', '')
        ELSE subject_reference
      END AS patient_resource_id,
      CASE
        WHEN encounter_reference LIKE 'Encounter/%' THEN REPLACE(encounter_reference, 'Encounter/', '')
        WHEN encounter_reference LIKE 'urn:uuid:%' THEN REPLACE(encounter_reference, 'urn:uuid:', '')
        ELSE encounter_reference
      END AS encounter_resource_id,
      TRY_CONVERT(datetime2, procedure_start_ts) AS procedure_start_datetime,
      TRY_CONVERT(datetime2, procedure_end_ts) AS procedure_end_datetime,
      source_code,
      source_display
  FROM procedure_dedup
  WHERE rn = 1
),
procedure_with_refs AS (
  SELECT
      t.procedure_resource_id,
      p.person_id,
      v.visit_occurrence_id,
      t.procedure_start_datetime,
      t.procedure_end_datetime,
      t.source_code,
      t.source_display
  FROM procedure_typed t
  INNER JOIN @cdm_schema.person p
    ON p.person_source_value = CONCAT('fhir:', t.patient_resource_id)
  LEFT JOIN @cdm_schema.visit_occurrence v
    ON v.visit_source_value = CONCAT('fhir:', t.encounter_resource_id)
),
procedure_with_omop_mapping AS (
  SELECT
      ROW_NUMBER() OVER (ORDER BY p.procedure_resource_id)
        + COALESCE((SELECT MAX(procedure_occurrence_id) FROM @cdm_schema.procedure_occurrence), 0) AS procedure_occurrence_id,
      p.person_id,
      COALESCE(c2.concept_id, 0) AS procedure_concept_id,
      CAST(COALESCE(p.procedure_start_datetime, p.procedure_end_datetime) AS date) AS procedure_date,
      p.procedure_start_datetime,
      p.procedure_end_datetime,
      32817 AS procedure_type_concept_id,
      NULL AS modifier_concept_id,
      1 AS quantity,
      NULL AS provider_id,
      p.visit_occurrence_id,
      NULL AS visit_detail_id,
      p.source_code AS procedure_source_value,
      0 AS procedure_source_concept_id,
      NULL AS modifier_source_value
  FROM procedure_with_refs p
  LEFT JOIN @cdm_schema.concept c2
    ON c2.concept_code = p.source_code
   AND c2.vocabulary_id = 'SNOMED'
   AND c2.standard_concept = 'S'
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
    p.procedure_occurrence_id,
    p.person_id,
    p.procedure_concept_id,
    p.procedure_date,
    p.procedure_start_datetime,
    CAST(COALESCE(p.procedure_end_datetime, p.procedure_start_datetime) AS date),
    COALESCE(p.procedure_end_datetime, p.procedure_start_datetime),
    p.procedure_type_concept_id,
    p.modifier_concept_id,
    p.quantity,
    p.provider_id,
    p.visit_occurrence_id,
    p.visit_detail_id,
    p.procedure_source_value,
    p.procedure_source_concept_id,
    p.modifier_source_value
FROM procedure_with_omop_mapping p
WHERE p.procedure_date IS NOT NULL;

-- [BLOCK: condition]
-- -------------------------
-- Condition -> CONDITION_OCCURRENCE
-- -------------------------
WITH condition_src AS (
  SELECT
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
condition_dedup AS (
  SELECT
      condition_resource_id,
      subject_reference,
      encounter_reference,
      onset_datetime,
      source_code,
      source_system,
      source_display,
      ROW_NUMBER() OVER (PARTITION BY condition_resource_id ORDER BY onset_datetime, condition_resource_id) AS rn
  FROM condition_src
),
condition_typed AS (
  SELECT
      condition_resource_id,
      CASE
        WHEN subject_reference LIKE 'Patient/%' THEN REPLACE(subject_reference, 'Patient/', '')
        WHEN subject_reference LIKE 'urn:uuid:%' THEN REPLACE(subject_reference, 'urn:uuid:', '')
        ELSE subject_reference
      END AS patient_resource_id,
      CASE
        WHEN encounter_reference LIKE 'Encounter/%' THEN REPLACE(encounter_reference, 'Encounter/', '')
        WHEN encounter_reference LIKE 'urn:uuid:%' THEN REPLACE(encounter_reference, 'urn:uuid:', '')
        ELSE encounter_reference
      END AS encounter_resource_id,
      TRY_CONVERT(datetime2, onset_datetime) AS condition_start_datetime,
      source_code,
      source_system,
      source_display
  FROM condition_dedup
  WHERE rn = 1
),
condition_with_refs AS (
  SELECT
      t.condition_resource_id,
      p.person_id,
      v.visit_occurrence_id,
      t.condition_start_datetime,
      t.source_code,
      t.source_system,
      t.source_display
  FROM condition_typed t
  INNER JOIN @cdm_schema.person p
    ON p.person_source_value = CONCAT('fhir:', t.patient_resource_id)
  LEFT JOIN @cdm_schema.visit_occurrence v
    ON v.visit_source_value = CONCAT('fhir:', t.encounter_resource_id)
),
condition_with_omop_mapping AS (
  SELECT
      ROW_NUMBER() OVER (ORDER BY c.condition_resource_id)
        + COALESCE((SELECT MAX(condition_occurrence_id) FROM @cdm_schema.condition_occurrence), 0) AS condition_occurrence_id,
      c.person_id,
      COALESCE(
        c2.concept_id,
        CASE
          WHEN c.source_code = '76844004' THEN 4201004
          WHEN c.source_code = '433202001' THEN 4318887
          WHEN c.source_code = '444948002' THEN 40480632
          ELSE 0
        END
      ) AS condition_concept_id,
      CAST(c.condition_start_datetime AS date) AS condition_start_date,
      c.condition_start_datetime,
      CAST(c.condition_start_datetime AS date) AS condition_end_date,
      c.condition_start_datetime AS condition_end_datetime,
      32817 AS condition_type_concept_id,
      0 AS condition_status_concept_id,
      NULL AS stop_reason,
      NULL AS provider_id,
      c.visit_occurrence_id,
      NULL AS visit_detail_id,
      c.source_code AS condition_source_value,
      0 AS condition_source_concept_id,
      c.source_display AS condition_status_source_value
  FROM condition_with_refs c
  LEFT JOIN @cdm_schema.concept c2
    ON c2.concept_code = c.source_code
   AND c2.vocabulary_id = 'SNOMED'
   AND c2.standard_concept = 'S'
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
    c.condition_concept_id,
    c.condition_start_date,
    c.condition_start_datetime,
    c.condition_end_date,
    c.condition_end_datetime,
    c.condition_type_concept_id,
    c.condition_status_concept_id,
    c.stop_reason,
    c.provider_id,
    c.visit_occurrence_id,
    c.visit_detail_id,
    c.condition_source_value,
    c.condition_source_concept_id,
    c.condition_status_source_value
FROM condition_with_omop_mapping c
WHERE c.condition_start_datetime IS NOT NULL
  AND c.condition_concept_id > 0;