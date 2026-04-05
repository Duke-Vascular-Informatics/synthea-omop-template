# setup/

One-time environment setup scripts. Run these **once per machine** before starting
the analysis workflow. They are sourced by `workflow/01_setup_synthea_etl_qc_env.R`
on every run but are safe to call repeatedly (idempotent).

## Files

| File | Description | When to run |
|------|-------------|-------------|
| `setup_renv.R` | Activates the renv project library and restores packages from `renv.lock`. Ensures all R package versions match the locked environment. | Every session (called by Step 01) |
| `install_packages.R` | Installs any packages missing from the renv library (CRAN-first, GitHub fallback for OHDSI-only packages). Also provisions the JDBC driver bundle via `R/drivers.R`. | First run or after `renv.lock` changes |
| `setup_omop_vocab_schema.R` | Loads the OMOP standard vocabulary into a shared `omop_vocab` schema on the SQL Server instance. Creates all 10 vocabulary tables and populates them from source CSV files. **Only needs to run once per SQL Server instance** — subsequent ETL runs use SQL Server synonyms to reference this schema. | Once per SQL Server instance |

## Prerequisites for setup_omop_vocab_schema.R

- OMOP vocabulary CSV files downloaded from [Athena](https://athena.ohdsi.org)
- Sufficient disk space (~25 GB for full vocabulary load)
- A pre-existing SQL Server database to host the `omop_vocab` schema
- Connection details configured in `config.R`
