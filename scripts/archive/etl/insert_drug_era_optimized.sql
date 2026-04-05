-- insert_drug_era_optimized.sql
-- Fully materialized drug_era INSERT for $(Schema).
-- Replaces the CTE-only ETLSyntheaBuilder approach which causes O(n^2)
-- nested-loop re-scans via the non-equi join in ctoDrugExposureEnds.
-- Run via: sqlcmd -S localhost -d omop_synth -E -C -v Schema="omop_synth_pad_oler_ssi_02" -i insert_drug_era_optimized.sql

DECLARE @n INT;
DECLARE @schema NVARCHAR(256) = N'$(Schema)';
PRINT N'=== Optimized drug_era for schema: ' + @schema + ' ===';

-- Step 1: drug->ingredient map (concept_ancestor join ONCE, ~400 rows)
PRINT 'Step 1: building #drug_ingredient_map...';
IF OBJECT_ID('tempdb..#drug_ingredient_map', 'U') IS NOT NULL DROP TABLE #drug_ingredient_map;
SELECT DISTINCT d.drug_concept_id, c.concept_id AS ingredient_concept_id
INTO #drug_ingredient_map
FROM omop_synth_pad_oler_ssi_02.drug_exposure d
  JOIN omop_synth_pad_oler_ssi_02.concept_ancestor ca ON ca.descendant_concept_id = d.drug_concept_id
  JOIN omop_synth_pad_oler_ssi_02.concept c ON ca.ancestor_concept_id = c.concept_id
WHERE c.vocabulary_id = 'RxNorm'
  AND c.concept_class_id = 'Ingredient'
  AND d.drug_concept_id != 0;
CREATE INDEX IX_dim_dc ON #drug_ingredient_map (drug_concept_id);
SELECT @n = COUNT(*) FROM #drug_ingredient_map;
PRINT CONCAT('  #drug_ingredient_map rows: ', @n);

-- Step 2: pre_drug_target (drug_exposure x dim_map, indexed)
PRINT 'Step 2: building #pre_drug_target...';
IF OBJECT_ID('tempdb..#pre_drug_target', 'U') IS NOT NULL DROP TABLE #pre_drug_target;
SELECT
    d.drug_exposure_id, d.person_id, dim.ingredient_concept_id,
    d.drug_exposure_start_date, d.days_supply,
    COALESCE(
        NULLIF(d.drug_exposure_end_date, NULL),
        NULLIF(DATEADD(day, d.days_supply, d.drug_exposure_start_date), d.drug_exposure_start_date),
        DATEADD(day, 1, d.drug_exposure_start_date)
    ) AS drug_exposure_end_date
INTO #pre_drug_target
FROM omop_synth_pad_oler_ssi_02.drug_exposure d
JOIN #drug_ingredient_map dim ON dim.drug_concept_id = d.drug_concept_id
WHERE d.drug_concept_id != 0 AND COALESCE(d.days_supply, 0) >= 0;
CREATE INDEX IX_pdt ON #pre_drug_target
    (person_id, ingredient_concept_id, drug_exposure_start_date)
    INCLUDE (drug_exposure_end_date, drug_exposure_id, days_supply);
SELECT @n = COUNT(*) FROM #pre_drug_target;
PRINT CONCAT('  #pre_drug_target rows: ', @n);

-- Step 3: sub_exposure_end_dates (gap-and-island first pass, indexed)
-- This prevents the non-equi-join CTE re-scan in step 4
PRINT 'Step 3: building #sub_exposure_end_dates...';
IF OBJECT_ID('tempdb..#sub_exposure_end_dates', 'U') IS NOT NULL DROP TABLE #sub_exposure_end_dates;
SELECT person_id, ingredient_concept_id, event_date AS end_date
INTO #sub_exposure_end_dates
FROM (
    SELECT person_id, ingredient_concept_id, event_date, event_type,
        MAX(start_ordinal) OVER (
            PARTITION BY person_id, ingredient_concept_id
            ORDER BY event_date, event_type ROWS UNBOUNDED PRECEDING
        ) AS start_ordinal,
        ROW_NUMBER() OVER (
            PARTITION BY person_id, ingredient_concept_id
            ORDER BY event_date, event_type
        ) AS overall_ord
    FROM (
        SELECT person_id, ingredient_concept_id,
            drug_exposure_start_date AS event_date, -1 AS event_type,
            ROW_NUMBER() OVER (
                PARTITION BY person_id, ingredient_concept_id
                ORDER BY drug_exposure_start_date
            ) AS start_ordinal
        FROM #pre_drug_target
        UNION ALL
        SELECT person_id, ingredient_concept_id,
            drug_exposure_end_date, 1 AS event_type, NULL
        FROM #pre_drug_target
    ) RAWDATA
) e
WHERE (2 * e.start_ordinal) - e.overall_ord = 0;
CREATE INDEX IX_sed ON #sub_exposure_end_dates (person_id, ingredient_concept_id, end_date);
SELECT @n = COUNT(*) FROM #sub_exposure_end_dates;
PRINT CONCAT('  #sub_exposure_end_dates rows: ', @n);

-- Step 4: final_target (sub-exposure grouping, indexed)
PRINT 'Step 4: building #final_target...';
IF OBJECT_ID('tempdb..#final_target', 'U') IS NOT NULL DROP TABLE #final_target;
WITH cteDrugExposureEnds AS (
    SELECT
        dt.person_id,
        dt.ingredient_concept_id AS drug_concept_id,
        dt.drug_exposure_start_date,
        MIN(e.end_date) AS drug_sub_exposure_end_date
    FROM #pre_drug_target dt
    JOIN #sub_exposure_end_dates e
        ON dt.person_id = e.person_id
        AND dt.ingredient_concept_id = e.ingredient_concept_id
        AND e.end_date >= dt.drug_exposure_start_date
    GROUP BY dt.drug_exposure_id, dt.person_id, dt.ingredient_concept_id, dt.drug_exposure_start_date
),
cteSubExposures AS (
    SELECT
        ROW_NUMBER() OVER (
            PARTITION BY person_id, drug_concept_id, drug_sub_exposure_end_date
            ORDER BY person_id
        ) AS row_number,
        person_id, drug_concept_id,
        MIN(drug_exposure_start_date) AS drug_sub_exposure_start_date,
        drug_sub_exposure_end_date,
        COUNT(*) AS drug_exposure_count
    FROM cteDrugExposureEnds
    GROUP BY person_id, drug_concept_id, drug_sub_exposure_end_date
)
SELECT row_number, person_id, drug_concept_id,
    drug_sub_exposure_start_date, drug_sub_exposure_end_date, drug_exposure_count,
    DATEDIFF(day, drug_sub_exposure_start_date, drug_sub_exposure_end_date) AS days_exposed
INTO #final_target
FROM cteSubExposures;
CREATE INDEX IX_ft ON #final_target
    (person_id, drug_concept_id, drug_sub_exposure_start_date)
    INCLUDE (drug_sub_exposure_end_date, drug_exposure_count, days_exposed);
SELECT @n = COUNT(*) FROM #final_target;
PRINT CONCAT('  #final_target rows: ', @n);

-- Step 5: final era aggregation into #tmp_de
PRINT 'Step 5: building #tmp_de (final era)...';
IF OBJECT_ID('tempdb..#tmp_de', 'U') IS NOT NULL DROP TABLE #tmp_de;
WITH cteEndDates AS (
    SELECT person_id, ingredient_concept_id,
        DATEADD(day, -30, event_date) AS end_date
    FROM (
        SELECT person_id, ingredient_concept_id, event_date, event_type,
            MAX(start_ordinal) OVER (
                PARTITION BY person_id, ingredient_concept_id
                ORDER BY event_date, event_type ROWS UNBOUNDED PRECEDING
            ) AS start_ordinal,
            ROW_NUMBER() OVER (
                PARTITION BY person_id, ingredient_concept_id
                ORDER BY event_date, event_type
            ) AS overall_ord
        FROM (
            SELECT person_id, drug_concept_id AS ingredient_concept_id,
                drug_sub_exposure_start_date AS event_date, -1 AS event_type,
                ROW_NUMBER() OVER (
                    PARTITION BY person_id, drug_concept_id
                    ORDER BY drug_sub_exposure_start_date
                ) AS start_ordinal
            FROM #final_target
            UNION ALL
            SELECT person_id, drug_concept_id AS ingredient_concept_id,
                DATEADD(day, 30, drug_sub_exposure_end_date), 1 AS event_type, NULL
            FROM #final_target
        ) RAWDATA
    ) e
    WHERE (2 * e.start_ordinal) - e.overall_ord = 0
),
cteDrugEraEnds AS (
    SELECT
        ft.person_id, ft.drug_concept_id, ft.drug_sub_exposure_start_date,
        MIN(e.end_date) AS era_end_date,
        ft.drug_exposure_count, ft.days_exposed
    FROM #final_target ft
    JOIN cteEndDates e
        ON ft.person_id = e.person_id
        AND ft.drug_concept_id = e.ingredient_concept_id
        AND e.end_date >= ft.drug_sub_exposure_start_date
    GROUP BY ft.person_id, ft.drug_concept_id, ft.drug_sub_exposure_start_date,
        ft.drug_exposure_count, ft.days_exposed
)
SELECT
    ROW_NUMBER() OVER (ORDER BY person_id) AS drug_era_id,
    person_id, drug_concept_id,
    MIN(drug_sub_exposure_start_date) AS drug_era_start_date,
    era_end_date,
    SUM(drug_exposure_count) AS drug_exposure_count,
    DATEDIFF(day, MIN(drug_sub_exposure_start_date), era_end_date) - SUM(days_exposed) AS gap_days
INTO #tmp_de
FROM cteDrugEraEnds dee
GROUP BY person_id, drug_concept_id, era_end_date;
SELECT @n = COUNT(*) FROM #tmp_de;
PRINT CONCAT('  #tmp_de rows: ', @n);

-- Step 6: insert into drug_era
PRINT 'Step 6: inserting into drug_era...';
INSERT INTO omop_synth_pad_oler_ssi_02.drug_era
    (drug_era_id, person_id, drug_concept_id, drug_era_start_date, drug_era_end_date, drug_exposure_count, gap_days)
SELECT * FROM #tmp_de;
SELECT @n = COUNT(*) FROM omop_synth_pad_oler_ssi_02.drug_era;
PRINT CONCAT('  drug_era total rows: ', @n);
PRINT '=== drug_era INSERT complete ===';
