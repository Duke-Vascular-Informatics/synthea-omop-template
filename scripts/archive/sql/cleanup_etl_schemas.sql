-- =============================================================================
-- cleanup_etl_schemas.sql
-- Drops all ETL-created schemas and their objects from omop_synth, then
-- shrinks the transaction log back to ~100 MB.
--
-- Target schemas:
--   omop_synth_pad_oler_ssi
--   omop_synth_pad_oler_ssi_02
--   synthea
--   synthea_csv_stage
--   cdm_synthea
-- =============================================================================

USE omop_synth;
GO

PRINT 'Step 1: Setting SIMPLE recovery to minimise log growth during cleanup...';
ALTER DATABASE omop_synth SET RECOVERY SIMPLE WITH NO_WAIT;
GO

-- ---------------------------------------------------------------------------
-- Step 2: Drop all foreign-key constraints on tables in the target schemas.
--         FK constraints must be removed before tables can be dropped.
-- ---------------------------------------------------------------------------
PRINT 'Step 2: Dropping foreign-key constraints...';
DECLARE @sql NVARCHAR(MAX) = N'';

SELECT @sql += 'ALTER TABLE [' + s.name + '].[' + t.name + '] '
             + 'DROP CONSTRAINT [' + fk.name + ']; '
FROM   sys.foreign_keys  fk
JOIN   sys.tables        t  ON fk.parent_object_id = t.object_id
JOIN   sys.schemas       s  ON t.schema_id        = s.schema_id
WHERE  s.name IN (
    'omop_synth_pad_oler_ssi',
    'omop_synth_pad_oler_ssi_02',
    'synthea',
    'synthea_csv_stage',
    'cdm_synthea'
);

IF LEN(@sql) > 0
BEGIN
    PRINT '  Executing: ' + LEFT(@sql, 200);
    EXEC sp_executesql @sql;
    PRINT '  Foreign keys dropped.';
END
ELSE
    PRINT '  No foreign keys found.';
GO

-- ---------------------------------------------------------------------------
-- Step 3: Drop all indexes that may have been left on the tables.
--         (Not strictly required before DROP TABLE, but helps with log size.)
-- ---------------------------------------------------------------------------
PRINT 'Step 3: Dropping non-clustered indexes...';
DECLARE @sql NVARCHAR(MAX) = N'';

SELECT @sql += 'DROP INDEX [' + i.name + '] ON [' + s.name + '].[' + t.name + ']; '
FROM   sys.indexes  i
JOIN   sys.tables   t ON i.object_id = t.object_id
JOIN   sys.schemas  s ON t.schema_id = s.schema_id
WHERE  s.name IN (
    'omop_synth_pad_oler_ssi',
    'omop_synth_pad_oler_ssi_02',
    'synthea',
    'synthea_csv_stage',
    'cdm_synthea'
)
AND i.type_desc = 'NONCLUSTERED'
AND i.is_primary_key = 0
AND i.is_unique_constraint = 0;

IF LEN(@sql) > 0
BEGIN
    EXEC sp_executesql @sql;
    PRINT '  Non-clustered indexes dropped.';
END
ELSE
    PRINT '  No non-clustered indexes found.';
GO

-- ---------------------------------------------------------------------------
-- Step 4: Drop all tables in the target schemas.
-- ---------------------------------------------------------------------------
PRINT 'Step 4: Dropping tables...';
DECLARE @sql NVARCHAR(MAX) = N'';

SELECT @sql += 'DROP TABLE [' + s.name + '].[' + t.name + ']; '
FROM   sys.tables  t
JOIN   sys.schemas s ON t.schema_id = s.schema_id
WHERE  s.name IN (
    'omop_synth_pad_oler_ssi',
    'omop_synth_pad_oler_ssi_02',
    'synthea',
    'synthea_csv_stage',
    'cdm_synthea'
)
ORDER BY s.name, t.name;

IF LEN(@sql) > 0
BEGIN
    PRINT '  Dropping ' + CAST((LEN(@sql) - LEN(REPLACE(@sql,'DROP TABLE','')))/LEN('DROP TABLE') AS VARCHAR) + ' table(s)...';
    EXEC sp_executesql @sql;
    PRINT '  Tables dropped.';
END
ELSE
    PRINT '  No tables found in target schemas.';
GO

-- ---------------------------------------------------------------------------
-- Step 5: Drop the schemas themselves (must be empty first).
-- ---------------------------------------------------------------------------
PRINT 'Step 5: Dropping schemas...';

IF SCHEMA_ID('omop_synth_pad_oler_ssi')    IS NOT NULL BEGIN PRINT '  Dropping omop_synth_pad_oler_ssi';    DROP SCHEMA [omop_synth_pad_oler_ssi];    END
IF SCHEMA_ID('omop_synth_pad_oler_ssi_02') IS NOT NULL BEGIN PRINT '  Dropping omop_synth_pad_oler_ssi_02'; DROP SCHEMA [omop_synth_pad_oler_ssi_02]; END
IF SCHEMA_ID('synthea')                    IS NOT NULL BEGIN PRINT '  Dropping synthea';                    DROP SCHEMA [synthea];                    END
IF SCHEMA_ID('synthea_csv_stage')          IS NOT NULL BEGIN PRINT '  Dropping synthea_csv_stage';          DROP SCHEMA [synthea_csv_stage];          END
IF SCHEMA_ID('cdm_synthea')                IS NOT NULL BEGIN PRINT '  Dropping cdm_synthea';                DROP SCHEMA [cdm_synthea];                END
GO

-- ---------------------------------------------------------------------------
-- Step 6: Shrink the transaction log.
-- ---------------------------------------------------------------------------
PRINT 'Step 6: Shrinking transaction log...';

-- Checkpoint forces dirty pages to disk so VLFs can be reused / cleared.
CHECKPOINT;
GO

DBCC SHRINKFILE (omop_synth_log, 100);  -- target 100 MB
GO

-- ---------------------------------------------------------------------------
-- Step 7: Report final state.
-- ---------------------------------------------------------------------------
PRINT 'Step 7: Final state check...';

SELECT
    name                 AS schema_name,
    schema_id
FROM sys.schemas
WHERE schema_id BETWEEN 5 AND 16000
ORDER BY schema_id;

SELECT
    DB_NAME()                          AS database_name,
    f.name                             AS log_file,
    CAST(f.size * 8.0 / 1024 AS INT)  AS size_MB,
    ls.log_reuse_wait_desc
FROM sys.database_files f
CROSS JOIN sys.databases ls
WHERE f.type_desc = 'LOG'
  AND ls.name = DB_NAME();

PRINT 'Cleanup complete.';
GO
