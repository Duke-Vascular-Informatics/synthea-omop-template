# Troubleshooting: OMOP Vocabulary Load

Use this when Step 10 fails or stalls.

## Quick Checks

1. Confirm SQL Server is running from host:

```bash
docker compose ps
```

2. Confirm mount exists inside container:

```bash
ls -la /omop_vocab/
```

3. Confirm credentials are valid:
- Check `.env` at `OMOP_Dev/.env`
- Ensure password matches SQL Server container env

## Retry Loader

```bash
Rscript scripts/setup_omop_vocab_schema.R
```

## Verify Load

```bash
Rscript -e "
  config <- get_validation_config()
  conn <- DatabaseConnector::connect(config$connection_details)
  result <- DatabaseConnector::querySql(conn, 'SELECT COUNT(*) AS n FROM omop_vocab.concept')
  print(result)
  DatabaseConnector::disconnect(conn)
"
```

Expected concept row count is usually around 2M (varies by vocabulary version).

## Common Failure Patterns

- `Login failed for user 'sa'`: incorrect `MSSQL_SA_PASSWORD` in `.env`
- `Invalid object name omop_vocab.concept`: schema not loaded yet
- Loader cannot find CSV files: `OMOP_Dev/omop_vocab` path mismatch or missing extract
- Extremely slow load: one-time expected cost can be 30-60 minutes
