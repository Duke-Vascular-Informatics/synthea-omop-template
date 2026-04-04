# run_drug_era_manual.ps1
# Manually executes the optimized drug_era INSERT for omop_synth_pad_oler_ssi_02.
# All temp tables are created on the SAME connection (temp tables are session-scoped).
# Run after the ETL has completed all steps through insert_condition_era.sql.

param(
  [string]$Schema = "omop_synth_pad_oler_ssi_02"
)

$ErrorActionPreference = "Stop"
$conn = New-Object System.Data.SqlClient.SqlConnection(
  "Server=localhost;Database=omop_synth;Integrated Security=SSPI;Connect Timeout=30;"
)
$conn.Open()
Write-Host "Connected (session will persist for all temp table steps)" -ForegroundColor Cyan

$q = [char]39

function Exec-Sql {
  param([string]$Label, [string]$Sql, [int]$TimeoutSec = 3600)
  $cmd = $conn.CreateCommand()
  $cmd.CommandTimeout = $TimeoutSec
  $cmd.CommandText = $Sql
  $t = [System.Diagnostics.Stopwatch]::StartNew()
  $cmd.ExecuteNonQuery() | Out-Null
  $t.Stop()
  $sec = [Math]::Round($t.Elapsed.TotalSeconds, 1)
  Write-Host ("  [$Label] $sec s") -ForegroundColor Green
}

function Count-Rows {
  param([string]$Table)
  $cmd = $conn.CreateCommand()
  $cmd.CommandText = "SELECT COUNT(*) FROM $Table"
  return $cmd.ExecuteScalar()
}

try {
  Write-Host "`n=== Drug Era optimized run for schema: $Schema ===" -ForegroundColor Cyan
  $total = [System.Diagnostics.Stopwatch]::StartNew()

  # Step 1: drug→ingredient map (small, ~400 rows)
  Write-Host "Step 1: #drug_ingredient_map ..."
  Exec-Sql "dim_map" (
    "IF OBJECT_ID($q`tempdb..#drug_ingredient_map$q,$q`U$q) IS NOT NULL DROP TABLE #drug_ingredient_map;" +
    " SELECT DISTINCT d.drug_concept_id, c.concept_id AS ingredient_concept_id" +
    " INTO #drug_ingredient_map" +
    " FROM $Schema.drug_exposure d" +
    " JOIN $Schema.concept_ancestor ca ON ca.descendant_concept_id = d.drug_concept_id" +
    " JOIN $Schema.concept c ON ca.ancestor_concept_id = c.concept_id" +
    " WHERE c.vocabulary_id = $q`RxNorm$q" +
    "   AND c.concept_class_id = $q`Ingredient$q" +
    "   AND d.drug_concept_id != 0;" +
    " CREATE INDEX IX_dim_dc ON #drug_ingredient_map (drug_concept_id)"
  )
  Write-Host ("    Rows: " + (Count-Rows "#drug_ingredient_map"))

  # Step 2: Materialize ctePreDrugTarget into indexed temp table
  Write-Host "Step 2: #pre_drug_target (drug_exposure x dim_map) ..."
  Exec-Sql "pre_drug_target" (
    "IF OBJECT_ID($q`tempdb..#pre_drug_target$q,$q`U$q) IS NOT NULL DROP TABLE #pre_drug_target;" +
    " SELECT d.drug_exposure_id, d.person_id, dim.ingredient_concept_id," +
    "   d.drug_exposure_start_date, d.days_supply," +
    "   COALESCE(NULLIF(d.drug_exposure_end_date,NULL)," +
    "            NULLIF(DATEADD(day,d.days_supply,d.drug_exposure_start_date),d.drug_exposure_start_date)," +
    "            DATEADD(day,1,d.drug_exposure_start_date)) AS drug_exposure_end_date" +
    " INTO #pre_drug_target" +
    " FROM $Schema.drug_exposure d" +
    " JOIN #drug_ingredient_map dim ON dim.drug_concept_id = d.drug_concept_id" +
    " WHERE d.drug_concept_id != 0 AND COALESCE(d.days_supply,0) >= 0;" +
    " CREATE INDEX IX_pdt ON #pre_drug_target" +
    "   (person_id, ingredient_concept_id, drug_exposure_start_date)" +
    "   INCLUDE (drug_exposure_end_date, drug_exposure_id, days_supply)"
  )
  Write-Host ("    Rows: " + (Count-Rows "#pre_drug_target"))

  # Step 3: Materialize cteSubExposureEndDates — critical: avoids non-equi CTE re-scan
  Write-Host "Step 3: #sub_exposure_end_dates (gap-and-island first pass) ..."
  Exec-Sql "sub_exposure_end_dates" (
    "IF OBJECT_ID($q`tempdb..#sub_exposure_end_dates$q,$q`U$q) IS NOT NULL DROP TABLE #sub_exposure_end_dates;" +
    " SELECT person_id, ingredient_concept_id, event_date AS end_date" +
    " INTO #sub_exposure_end_dates" +
    " FROM (" +
    "   SELECT person_id, ingredient_concept_id, event_date, event_type," +
    "     MAX(start_ordinal) OVER (PARTITION BY person_id, ingredient_concept_id" +
    "       ORDER BY event_date, event_type ROWS UNBOUNDED PRECEDING) AS start_ordinal," +
    "     ROW_NUMBER() OVER (PARTITION BY person_id, ingredient_concept_id" +
    "       ORDER BY event_date, event_type) AS overall_ord" +
    "   FROM (" +
    "     SELECT person_id, ingredient_concept_id, drug_exposure_start_date AS event_date," +
    "       -1 AS event_type," +
    "       ROW_NUMBER() OVER (PARTITION BY person_id, ingredient_concept_id" +
    "         ORDER BY drug_exposure_start_date) AS start_ordinal" +
    "     FROM #pre_drug_target" +
    "     UNION ALL" +
    "     SELECT person_id, ingredient_concept_id, drug_exposure_end_date, 1, NULL" +
    "     FROM #pre_drug_target" +
    "   ) RAWDATA" +
    " ) e WHERE (2 * e.start_ordinal) - e.overall_ord = 0;" +
    " CREATE INDEX IX_sed ON #sub_exposure_end_dates (person_id, ingredient_concept_id, end_date)"
  )
  Write-Host ("    Rows: " + (Count-Rows "#sub_exposure_end_dates"))

  # Step 4: Materialize intermediate era rollup into #final_target
  Write-Host "Step 4: #final_target (sub-exposure grouping) ..."
  Exec-Sql "final_target" (
    "IF OBJECT_ID($q`tempdb..#final_target$q,$q`U$q) IS NOT NULL DROP TABLE #final_target;" +
    " WITH cteDrugExposureEnds AS (" +
    "   SELECT dt.person_id, dt.ingredient_concept_id AS drug_concept_id, dt.drug_exposure_start_date," +
    "     MIN(e.end_date) AS drug_sub_exposure_end_date" +
    "   FROM #pre_drug_target dt" +
    "   JOIN #sub_exposure_end_dates e ON dt.person_id = e.person_id" +
    "     AND dt.ingredient_concept_id = e.ingredient_concept_id" +
    "     AND e.end_date >= dt.drug_exposure_start_date" +
    "   GROUP BY dt.drug_exposure_id, dt.person_id, dt.ingredient_concept_id, dt.drug_exposure_start_date" +
    " )," +
    " cteSubExposures AS (" +
    "   SELECT ROW_NUMBER() OVER (PARTITION BY person_id, drug_concept_id, drug_sub_exposure_end_date ORDER BY person_id) AS row_number," +
    "     person_id, drug_concept_id, MIN(drug_exposure_start_date) AS drug_sub_exposure_start_date," +
    "     drug_sub_exposure_end_date, COUNT(*) AS drug_exposure_count" +
    "   FROM ctoDrugExposureEnds" +
    "   GROUP BY person_id, drug_concept_id, drug_sub_exposure_end_date" +
    " )" +
    " SELECT row_number, person_id, drug_concept_id," +
    "   drug_sub_exposure_start_date, drug_sub_exposure_end_date, drug_exposure_count," +
    "   DATEDIFF(day,drug_sub_exposure_start_date,drug_sub_exposure_end_date) AS days_exposed" +
    " INTO #final_target" +
    " FROM cteSubExposures;" +
    " CREATE INDEX IX_ft ON #final_target (person_id, drug_concept_id, drug_sub_exposure_start_date)" +
    "   INCLUDE (drug_sub_exposure_end_date, drug_exposure_count, days_exposed)"
  )
  Write-Host ("    Rows: " + (Count-Rows "#final_target"))

  # Step 5: Final era computation into #tmp_de
  Write-Host "Step 5: #tmp_de (final era aggregation) ..."
  Exec-Sql "tmp_de" (
    "IF OBJECT_ID($q`tempdb..#tmp_de$q,$q`U$q) IS NOT NULL DROP TABLE #tmp_de;" +
    " WITH cteEndDates AS (" +
    "   SELECT person_id, ingredient_concept_id, DATEADD(day,-30,event_date) AS end_date" +
    "   FROM (" +
    "     SELECT person_id, ingredient_concept_id, event_date, event_type," +
    "       MAX(start_ordinal) OVER (PARTITION BY person_id, ingredient_concept_id" +
    "         ORDER BY event_date, event_type ROWS UNBOUNDED PRECEDING) AS start_ordinal," +
    "       ROW_NUMBER() OVER (PARTITION BY person_id, ingredient_concept_id" +
    "         ORDER BY event_date, event_type) AS overall_ord" +
    "     FROM (" +
    "       SELECT person_id, ingredient_concept_id, drug_sub_exposure_start_date AS event_date," +
    "         -1 AS event_type," +
    "         ROW_NUMBER() OVER (PARTITION BY person_id, ingredient_concept_id" +
    "           ORDER BY drug_sub_exposure_start_date) AS start_ordinal" +
    "       FROM #final_target" +
    "       UNION ALL" +
    "       SELECT person_id, ingredient_concept_id, DATEADD(day,30,drug_sub_exposure_end_date), 1, NULL" +
    "       FROM #final_target" +
    "     ) RAWDATA" +
    "   ) e WHERE (2 * e.start_ordinal) - e.overall_ord = 0" +
    " )," +
    " cteDrugEraEnds AS (" +
    "   SELECT ft.person_id, ft.drug_concept_id, ft.drug_sub_exposure_start_date," +
    "     MIN(e.end_date) AS era_end_date, ft.drug_exposure_count, ft.days_exposed" +
    "   FROM #final_target ft" +
    "   JOIN cteEndDates e ON ft.person_id = e.person_id" +
    "     AND ft.drug_concept_id = e.ingredient_concept_id" +
    "     AND e.end_date >= ft.drug_sub_exposure_start_date" +
    "   GROUP BY ft.person_id, ft.drug_concept_id, ft.drug_sub_exposure_start_date, ft.drug_exposure_count, ft.days_exposed" +
    " )" +
    " SELECT ROW_NUMBER() OVER (ORDER BY person_id) AS drug_era_id," +
    "   person_id, drug_concept_id," +
    "   MIN(drug_sub_exposure_start_date) AS drug_era_start_date," +
    "   era_end_date," +
    "   SUM(drug_exposure_count) AS drug_exposure_count," +
    "   DATEDIFF(day,MIN(drug_sub_exposure_start_date),era_end_date)-SUM(days_exposed) AS gap_days" +
    " INTO #tmp_de FROM cteDrugEraEnds dee GROUP BY person_id, drug_concept_id, era_end_date"
  )
  Write-Host ("    Rows: " + (Count-Rows "#tmp_de"))

  # Step 6: Insert into drug_era
  Write-Host "Step 6: INSERT INTO $Schema.drug_era ..."
  Exec-Sql "drug_era_insert" (
    "INSERT INTO $Schema.drug_era (drug_era_id,person_id,drug_concept_id,drug_era_start_date,drug_era_end_date,drug_exposure_count,gap_days)" +
    " SELECT * FROM #tmp_de"
  )
  $inserted = Count-Rows "$Schema.drug_era"
  Write-Host ("    drug_era rows inserted: " + $inserted)

  $total.Stop()
  Write-Host ("`n=== drug_era complete in " + [Math]::Round($total.Elapsed.TotalMinutes, 1) + " min ===") -ForegroundColor Green

} finally {
  $conn.Close()
  Write-Host "Connection closed."
}
