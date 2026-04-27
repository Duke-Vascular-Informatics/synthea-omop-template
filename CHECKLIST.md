# OMOP Study Template — Quick Reference Checklist

Use this checklist to track your progress. Detailed instructions are in [docs/GETTING_STARTED.md](docs/GETTING_STARTED.md).

See also: [docs/SETUP.md](docs/SETUP.md) for Docker & vocabulary setup details, [CLAUDE.md](CLAUDE.md) for coding conventions.

This checklist is intentionally concise. For full command examples and platform-specific variants,
follow [docs/GETTING_STARTED.md](docs/GETTING_STARTED.md).

---

## Phase 1: Bootstrap And Clone (Per machine + per study, 15-20 minutes)

- [ ] **Step 1:** Install VS Code
- [ ] **Step 2:** Install your coding assistant extension and sign in (Copilot, Claude Code, or other)
- [ ] **Step 3:** Create `OMOP_Dev/` folder and `.env` file with SQL Server password
- [ ] **Step 4:** Create study repo from GitHub template, clone into `OMOP_Dev/`
- [ ] **Step 4.3:** Install Docker Desktop and VS Code Dev Containers extension (with assistant help)
- [ ] **Step 5:** Check whether this machine already has shared setup (see Step 5 in [docs/GETTING_STARTED.md](docs/GETTING_STARTED.md))
- [ ] **Skip Step 6 if already set up:** `.env`, `docker-compose.yml`, `omop_vocab/CONCEPT.csv`, and healthy `mssql_dev`

---

## Phase 2: Machine Setup If Needed (One-time, 1–2 hours)

- [ ] **Step 6 (AUTOMATED):** Run Docker setup script if Step 5 failed (see Step 6 in [docs/GETTING_STARTED.md](docs/GETTING_STARTED.md))
- [ ] **Or Step 6 (MANUAL):** Create `docker-compose.yml`, start `mssql_dev`, create `omop_synth`, download Athena vocabulary
- [ ] **Step 6b (Optional):** Rebuild CPT-4 codes with UMLS API key

---

## Phase 3: Open Container And Check Shared Database State (Per study, ~10 minutes)

- [ ] **Step 7:** Open in VS Code → Reopen in Container (wait 5–10 min first time)
- [ ] **Step 8:** Check whether `omop_vocab` is already loaded in SQL Server
- [ ] **Skip Step 9 if already loaded**

---

## Phase 4: Load OMOP Vocabulary If Needed (Per machine, ~45 minutes, one-time)

- [ ] **Step 9:** Run vocabulary loader (see Step 9 in [docs/GETTING_STARTED.md](docs/GETTING_STARTED.md))
- [ ] **Verify:** Should load ~2M concept rows (takes 30–60 min)

---

## Phase 5: Define Your Study (Per study, ~30–60 minutes)

- [ ] **Step 10.1:** Check setup status (`Rscript scripts/check_setup.R`)

- [ ] **Step 10.2:** Edit `study_params.yaml`:
  - [ ] `study_name`, `study_design`
  - [ ] `cdm_schema`, `results_schema`, `cohort_table`
  - [ ] `study_start_date`, `study_end_date`
  - [ ] `output_folder`
  - [ ] Set `analyses:` flags

- [ ] **Step 10.3:** Look up all concept IDs (`Rscript scripts/concept_lookup.R "<term>" <Domain>`)

- [ ] **Step 10.4:** Edit cohort SQL files in `cohorts/` — replace `concept_id = 0`
  - [ ] `target_surgery.sql`
  - [ ] `outcome_ssi.sql`

- [ ] **Step 10.5:** Edit covariate files:
  - [ ] `covariates/covariates.csv`
  - [ ] `covariates/covariate_concepts.csv`

- [ ] **Step 10.6:** Validate (`Rscript scripts/check_setup.R` should show no `[FAIL]`)

- [ ] **Commit study definition:** stage study files, commit, and push

---

## Phase 6: Generate Synthetic Data & ETL (Per study, ~60 minutes)

*Skip if using real CDM already populated.*

- [ ] **Step 11:** (Optional) Customize Synthea module
- [ ] **Step 12.1:** Generate synthetic data (see Step 12 in [docs/GETTING_STARTED.md](docs/GETTING_STARTED.md))
- [ ] **Step 12.2:** Run ETL (`Rscript workflow/05_etl_csv_to_omop.R`)
- [ ] **Step 12.3:** Quality checks (`Rscript workflow/06_quality_check_defined_phenotypes.R`)

---

## Phase 7: Build Cohorts & Run Analyses (Per study, ~30–60 minutes)

- [ ] **Step 13.1:** Build cohorts (`Rscript workflow/02_define_omop_cohort_outcome_covariates.R`)
- [ ] **Step 13.2:** Run analyses (`Rscript workflow/07_setup_analysis_env.R`, then `Rscript workflow/08_run_analysis_and_manuscript_report.R`)
- [ ] **Step 13.3:** Review outputs in `output/<your-study>/`

---

## Phase 8: Create Transportable Code Packet (Per study, ~5 minutes)

- [ ] **Step 14:** Generate bundle:
  ```bash
  bash workflow/09_build_portable_analysis_bundle.sh
  # OR (Windows PowerShell):
  powershell -ExecutionPolicy Bypass -File workflow/09_build_portable_analysis_bundle.ps1
  ```
- [ ] **Share or archive** `portable/transportable_bundle/`

---

## Key Commands

| Task | Command |
|------|---------|
| Setup check | `Rscript scripts/check_setup.R` |
| Concept lookup | `Rscript scripts/concept_lookup.R "term" Domain` |
| SQL Server status | `docker compose ps` |
| Restart SQL Server | `docker compose up -d` (from `OMOP_Dev/`) |
| Run analyses | `Rscript workflow/08_run_analysis_and_manuscript_report.R` |
| Transportable bundle | `bash workflow/09_build_portable_analysis_bundle.sh` or `powershell -ExecutionPolicy Bypass -File workflow/09_build_portable_analysis_bundle.ps1` |

---

## Troubleshooting

**SQL Server not connecting?**
- Run `docker compose ps` from `OMOP_Dev/` — should show `mssql_dev` as `healthy`
- If stopped: `docker compose up -d`

**Dev container won't open?**
- Run `Cmd+Shift+P` → Dev Containers: Rebuild Container
- Ensure repo is directly in `OMOP_Dev/<study>/`, not nested deeper

**Vocabulary load slow?**
- Expected (30–60 min, one-time). Monitor with `docker compose logs -f mssql`

**Concept not found?**
- Try different search terms or check [Book of OHDSI](https://ohdsi.github.io/TheBookOfOhdsi/)

---

For complete details, see [docs/GETTING_STARTED.md](docs/GETTING_STARTED.md)
