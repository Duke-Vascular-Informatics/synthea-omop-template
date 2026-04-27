# Getting Started: From Zero to Analysis (Complete Workflow)

This guide walks you through the complete workflow from downloading VS Code to creating
a transportable analysis code packet. Each step is designed to work with any AI coding
assistant: GitHub Copilot, Claude Code, or any other supported tool.

**Total time:** ~2 hours first time (mostly Docker vocabulary loading)  
**Requires:** ~35 GB disk space, 8 GB RAM (16 GB recommended), active internet

---

## Step 1: Install Local Prerequisites (15 minutes)

### 1.1 Download VS Code

- Go to [code.visualstudio.com](https://code.visualstudio.com)
- Download and install for your operating system (Windows, macOS, or Linux)
- Launch VS Code

### 1.2 Install Docker Desktop

- Go to [docker.com/products/docker-desktop](https://www.docker.com/products/docker-desktop/)
- Download and install for your OS
- Start Docker Desktop and wait for it to be ready (icon shows "running")

> **Apple Silicon (M1/M2/M3):** Docker Desktop runs natively on ARM64. No Rosetta needed.

### 1.3 Install the VS Code Dev Containers Extension

Inside VS Code:
1. Open the Extensions view (`Ctrl+Shift+X` / `Cmd+Shift+X`)
2. Search for "Dev Containers" (published by Microsoft)
3. Click **Install**

### 1.4 Verify installations

```bash
# In your terminal / command prompt
docker --version        # Should print: Docker version XX.X.X
code --version          # Should print: X.XX.X
```

---

## Step 2: Install Your AI Coding Assistant (10 minutes)

### Option A: GitHub Copilot (Free Education Plan)

1. Go to [github.com/features/copilot](https://github.com/features/copilot)
2. Click **Get Copilot Free** (or **Sign up for free trial**)
3. Sign in with your GitHub account or create one
4. Inside VS Code:
   - Open Extensions (`Ctrl+Shift+X`)
   - Search for "GitHub Copilot"
   - Install the official extension by GitHub
   - Sign in with your GitHub account when prompted

### Option B: Claude Code (Free Trial or Subscription)

1. Go to [claude.ai](https://claude.ai) and sign in or create an account
2. Click on your profile → "API keys"
3. Create a new API key and save it securely
4. Inside VS Code:
   - Open Extensions (`Ctrl+Shift+X`)
   - Search for "Claude" (look for Anthropic extension)
   - Install and configure with your API key

### Option C: Other Coding Assistants

Follow the standard setup for your chosen tool and verify it works in VS Code before
proceeding to Step 3.

---

## Step 3: Create Your Parent Development Folder (5 minutes)

All pieces (SQL Server, OMOP vocabulary, study repositories) live in a single parent folder
so the relative paths work correctly. Create this **once** and reuse it for every study.

### 3.1 Create the folder

```bash
# macOS / Linux
mkdir ~/OMOP_Dev
cd ~/OMOP_Dev

# Windows (PowerShell)
New-Item -ItemType Directory -Path $env:USERPROFILE/OMOP_Dev -Force
cd $env:USERPROFILE/OMOP_Dev
```

### 3.2 Create the .env file with SQL Server password

The `.env` file stores the SQL Server SA password. Keep it outside the study repo so
it's never committed to version control.

```bash
# macOS / Linux
echo 'MSSQL_SA_PASSWORD=YourStrong@Passw0rd' > .env

# Windows (PowerShell) — use backtick to escape special characters, or paste into editor
'MSSQL_SA_PASSWORD=YourStrong@Passw0rd' | Out-File -Encoding ascii .env
```

**Password requirements:**
- At least 8 characters
- Mix of upper, lower, digit, and special character (e.g., `@`, `#`, `$`, `%`)
- Do NOT use `!` (Bash history expansion will fail)

**Example strong passwords:**
- `SqlServer@2024`
- `Dev#OMOP$Vocab1`
- `MyStudy123%Pass`

### 3.3 Verify the folder structure

```bash
# Should see:
# .env                   ← your password file (do not commit)
# (other files added in next steps)

ls -la  # macOS / Linux
dir     # Windows Command Prompt
```

---

## Step 4: Set Up SQL Server in Docker (20 minutes)

**Note:** You do this BEFORE cloning the repo because this is a one-time per-machine setup
independent of any study repository.

### 4.1 Create the docker-compose.yml file

Inside your `OMOP_Dev/` folder, create a file named `docker-compose.yml` with the
following contents. This file is shared across all studies on this machine.

**File: `OMOP_Dev/docker-compose.yml`**

```yaml
version: '3.9'

services:
  mssql:
    # azure-sql-edge provides native linux/arm64 support for Apple Silicon.
    # Swap for mcr.microsoft.com/mssql/server:2022-latest on amd64 hardware only.
    image: mcr.microsoft.com/azure-sql-edge:latest
    container_name: mssql_dev
    restart: unless-stopped
    ports:
      - "${MSSQL_PORT:-1433}:1433"
    environment:
      ACCEPT_EULA: "1"
      MSSQL_SA_PASSWORD: "${MSSQL_SA_PASSWORD}"
      # Performance tuning for vocabulary load (optional)
      # MSSQL_MEMORY_LIMIT_MB: "4096"
    volumes:
      - mssql_data:/var/opt/mssql
    healthcheck:
      test: ["CMD-SHELL", "bash -c 'cat /dev/null > /dev/tcp/localhost/1433' || exit 1"]
      interval: 15s
      timeout: 10s
      retries: 5
      start_period: 30s
    networks:
      - omop_dev_network

volumes:
  mssql_data:
    name: mssql_dev_data

networks:
  omop_dev_network:
    name: omop_dev_network
```

### 4.2 Start SQL Server

```bash
# Run from inside OMOP_Dev/
docker compose up -d

# Monitor startup (~30–60 seconds)
docker compose logs -f mssql

# When you see "SQL Server is now ready for client connections", press Ctrl+C to exit logs
```

### 4.3 Create the shared omop_synth database

```bash
# Replace YourStrong@Passw0rd with your actual password from .env
docker exec mssql_dev \
  /opt/mssql-tools18/bin/sqlcmd \
  -S localhost -U SA -P "YourStrong@Passw0rd" -C \
  -Q "IF DB_ID('omop_synth') IS NULL CREATE DATABASE omop_synth;"
```

### 4.4 Verify SQL Server is healthy

```bash
docker compose ps

# Should show:
# mssql_dev    ...    STATUS: healthy
```

---

## Step 5: Download OMOP Vocabulary from Athena (45 minutes)

The OMOP vocabulary is the shared clinical concept lookup table. Download it once per
machine and reuse across all studies. This happens BEFORE cloning any study repo.

### 5.1 Create Athena account and download

1. Go to [athena.ohdsi.org](https://athena.ohdsi.org)
2. Click **Download** → **Create new download**
3. Select these vocabulary bundles at minimum:

| Vocabulary | Required | Notes |
|------------|----------|-------|
| **SNOMED** | ✅ | Primary clinical vocabulary |
| **RxNorm** | ✅ | Drug ingredients |
| **RxNorm Extension** | ⭐ | Drugs not in RxNorm |
| **LOINC** | ✅ | Lab measurements |
| **ICD10CM** | ✅ | US diagnoses (US studies only) |
| **CPT4** | ⭐ | US procedures (requires UMLS key) |
| **HCPCS** | ⭐ | US outpatient procedures |
| **ICD10PCS** | ⭐ | US inpatient procedures |
| **Visit** | ✅ | Visit types |
| **Gender** / **Race** / **Ethnicity** | ✅ | Demographics |
| **UCUM** | ✅ | Units of measure |

4. Accept the license and click **Download** (2–5 GB zip file)
5. Extract the zip file

### 5.2 Extract vocabulary files to OMOP_Dev/omop_vocab/

```bash
# Create the vocabulary folder
mkdir -p OMOP_Dev/omop_vocab

# Extract the Athena download into this folder
# The folder should contain CONCEPT.csv directly (not in a subfolder)

unzip ~/Downloads/vocabulary_download_v5*.zip -d OMOP_Dev/omop_vocab/
# or (Windows): Extract-Archive -Path ... -DestinationPath ...

# Verify:
ls OMOP_Dev/omop_vocab/CONCEPT.csv  # Should exist
```

### 5.3 Rebuild CPT-4 codes (requires free UMLS API key)

CPT-4 codes are licensed and fetched from the NLM UMLS. If you did not include CPT-4
in your download, you can skip this step for now.

**Get a free UMLS API key (same-day approval):**
1. Go to [uts.nlm.nih.gov](https://uts.nlm.nih.gov)
2. Click **Sign up** and fill in your details
3. After approval, log in and go to your profile
4. Copy your **API Key**

**Run the CPT-4 rebuild:**

```bash
cd OMOP_Dev/omop_vocab

# macOS / Linux
bash cpt.sh YOUR_UMLS_API_KEY

# Windows (Command Prompt, not PowerShell)
cpt.bat YOUR_UMLS_API_KEY
```

Takes 5–15 minutes. Do not close the terminal during this process.

---

## Step 6: Create Your Study Repository from Template (5 minutes)

### 6.1 Use the GitHub template

1. Go to [github.com/ohdsi-studies/OMOP-Study-Template](https://github.com/ohdsi-studies/OMOP-Study-Template)
   *(or your organization's fork of it)*
2. Click **Use this template** → **Create a new repository**
3. Name it something descriptive (e.g., `colectomy-ssi-omop`, `hip-replace-vte`)
4. Choose **Private** (recommended for studies with PHI definitions)
5. Click **Create repository from template**

### 6.2 Clone inside OMOP_Dev/

```bash
cd OMOP_Dev

# Replace <your-org> and <your-study> with your GitHub paths
git clone https://github.com/<your-org>/<your-study>.git

cd <your-study>
```

**Important:** The repo MUST be directly inside `OMOP_Dev/`. The relative paths in
the dev container depend on this structure:

```
OMOP_Dev/
  .env
  docker-compose.yml
  omop_vocab/
  <your-study>/          ← your repo is here
    .devcontainer/
    setup/
      setup_docker_and_vocab.sh
    config.R
    study_params.yaml
    ...
```

---

## Step 7: Verify Docker Setup (or Use Automated Setup Script) — 5 minutes

**You now have the repository cloned!**

If you completed Step 4 manually, your Docker is already running and you can skip to Step 8.

If you **skipped Step 4** or want to **use the automated setup script**, you can run it now:

### Option A: Use the Automated Setup Script (If you skipped Step 4)

The cloned repository includes a setup script that automates Docker configuration:

```bash
# From inside your study repo folder (OMOP_Dev/<your-study>)
cd ..  # Go to OMOP_Dev/

# macOS / Linux
bash <your-study>/setup/setup_docker_and_vocab.sh

# Windows (PowerShell)
powershell -ExecutionPolicy Bypass -File <your-study>\setup\setup_docker_and_vocab.ps1
```

This script:
1. Checks Docker is running
2. Creates `docker-compose.yml` in `OMOP_Dev/`
3. Starts the SQL Server container
4. Creates the `omop_synth` database
5. Guides you through Athena vocabulary download

**If the script succeeds,** skip directly to Step 8.

### Option B: Verify Manual Setup (If you completed Step 4)

If you already completed Step 4 manually, just verify Docker is still running:

```bash
cd OMOP_Dev

# Check status
docker compose ps

# Should show: mssql_dev    ...    STATUS: healthy

# If not healthy, restart:
docker compose up -d
```

### Option C: Manual Troubleshooting

If Docker is not running, see Step 4 instructions above for manual docker-compose setup.

---

## Step 8: Open in Dev Container (10 minutes)

Now that SQL Server is running, you can safely open the dev container in VS Code.

### 8.1 Open in VS Code

1. Inside VS Code: **File** → **Open Folder**
2. Navigate to `OMOP_Dev/<your-study>/` and click **Open**
3. A notification appears: **"Folder contains a Dev Container. Reopen in Container?"**
4. Click **Reopen in Container**
   *(Or use `Cmd+Shift+P` → **Dev Containers: Reopen in Container**)*

### 8.2 Wait for container build (5–10 minutes first time)

The first build:
- Pulls the R + Java image (~1.5 GB)
- Installs system dependencies
- Activates renv environment

VS Code shows a progress indicator. When complete, the status bar shows the container name.

### 8.3 Verify the environment

Open a terminal in VS Code (`Ctrl+`` or `Cmd+`` `) and run:

```bash
# Should print: true
echo $IN_DEV_CONTAINER

# Should show R 4.5.x
R --version

# Should show: No errors
Rscript -e "library(DatabaseConnector); print('OK')"
```

---

## Step 9: Load OMOP Vocabulary into SQL Server (30–60 minutes)

The vocabulary is shared across all studies on this SQL Server instance. Load it once per machine.

### 9.1 Inside the dev container, run the vocabulary loader

```bash
# Run from the study root (inside the container)
Rscript scripts/setup_omop_vocab_schema.R
```

This script:
1. Reads the CSV files from `/omop_vocab/` (mounted from `OMOP_Dev/omop_vocab/`)
2. Creates the `omop_vocab` schema in SQL Server
3. Loads all 9 vocabulary tables
4. Creates primary keys and indexes

**Expected output:**
```
Loading CONCEPT.csv...
Loading CONCEPT_ANCESTOR.csv...
...
✓ OMOP vocabulary schema loaded successfully
```

If you see errors, check:
- SQL Server is running: `docker compose ps` from outside the container
- `.env` password is correct
- Files exist: `ls -la /omop_vocab/`

### 9.2 Verify vocabulary was loaded

```bash
# Still inside the container
Rscript -e "
  config <- get_validation_config()
  conn <- DatabaseConnector::connect(config$connection_details)
  result <- DatabaseConnector::querySql(conn, 'SELECT COUNT(*) FROM omop_vocab.concept')
  print(result)
  DatabaseConnector::disconnect(conn)
"

# Should print: ~2M rows (varies by vocabulary version)
```

---

## Step 10: Define Your Cohort, Outcome, and Covariates (30–60 minutes)

This is where you customize the template for your specific study.

### 10.1 Review the setup checklist

```bash
# Inside the dev container
Rscript scripts/check_setup.R

# or in your coding assistant (Claude Code only):
# /check-setup
```

This shows what still needs your input.

### 10.2 Edit study_params.yaml

Open `study_params.yaml` and fill in study-specific values:

```yaml
study_name: "my_study"              # ← Change this
study_design: "prognostic_model"    # ← Verify / change if different

cdm_schema: "cdm_my_study"          # ← Change to your CDM schema name
results_schema: "my_study_results"  # ← Change to your results schema
cohort_table: "my_study_cohort"     # ← Change to your cohort table name

target:
  cohort_id: 1
  index_event:
    ancestor_concept_ids: [0]       # ← Look these up!
  inclusion_criteria: []
  
outcome:
  cohort_id: 2
  ancestor_concept_ids: [0]         # ← Look these up!

prediction_window_days: 30

study_start_date: "2020-01-01"
study_end_date: "2022-12-31"

output_folder: "output/my_study"    # ← Change this

analyses:
  cohort_characterization: true     # ← Set to true for analyses you want
  propensity_score: false
  ...
```

### 10.3 Look up concept IDs

For every `[0]` placeholder, use your coding assistant to look up the correct concept ID:

```bash
# Inside the container
Rscript scripts/concept_lookup.R "your clinical term" Domain

# Examples:
Rscript scripts/concept_lookup.R "hip replacement" Procedure
Rscript scripts/concept_lookup.R "surgical site infection" Condition
```

**In your coding assistant:** Ask it to help you find and verify concept IDs. It should:
1. Run the lookup script
2. Show you the results
3. Help you document where each ID came from

### 10.4 Edit cohort SQL files

Open the files in `cohorts/`:
- `target_surgery.sql` — index event cohort definition
- `outcome_ssi.sql` — outcome cohort definition
- `comparator_cohort.sql` — (if doing causal inference)

Replace every `concept_id = 0` placeholder with verified concept IDs from Step 10.3.

Example:

```sql
-- BEFORE:
WHERE c.procedure_concept_id IN (0, 0, 0)  -- TODO: insert procedure concept IDs

-- AFTER:
WHERE c.procedure_concept_id IN (4301351, 4306895)  -- [vocab query] Total hip replacement and variants
```

### 10.5 Edit covariate files

Update the covariates your study needs:

- `covariates/covariates.csv` — define covariates (rows with `covariate_id`, `covariate_name`, etc.)
- `covariates/covariate_concepts.csv` — map each covariate to OMOP concept IDs

Example `covariates.csv`:
```csv
covariate_id,covariate_name,type
1,Age,demographic
2,Male,demographic
3,Diabetes,condition
```

Example `covariate_concepts.csv`:
```csv
covariate_id,concept_id
3,201820  # Type 2 diabetes mellitus
```

### 10.6 Validate your setup

```bash
Rscript scripts/check_setup.R

# Should show all [OK] or at least no [FAIL] items
```

---

## Step 11: Design Analysis-Specific Synthea Module (Optional, 30 minutes)

If you're using synthetic data (not a real CDM), customize the Synthea module to match
your study population.

### 10.1 Review the default module

Synthea generates synthetic patient data. The module controls which conditions, procedures,
and medications are simulated.

```bash
# Inside the container, see the default module:
cat synthea/modules/surgical_site_infection_study.json
```

### 10.2 Customize if needed

For your study population, edit the Synthea module JSON to adjust:
- Disease prevalence (comorbidities)
- Procedure rates
- Medication use patterns

This is optional; the default module is often sufficient for testing.

---

## Step 12: Generate Synthetic Data and Run ETL (60 minutes)

### 12.1 Generate Synthea synthetic patient records

```bash
# Inside the container
Rscript workflow/01_setup_synthea_etl_qc_env.R    # Install packages, verify DB
Rscript workflow/03_generate_synthea_module_artifacts.R
Rscript workflow/04_generate_synthea_csv.sh       # (Linux/macOS)
# OR:
Rscript workflow/04_generate_synthea_csv.ps1      # (Windows)
```

This creates synthetic EHR data in CSV format.

### 12.2 Run ETL (Extract, Transform, Load)

```bash
# Load the CSV files into the CDM schema
Rscript workflow/05_etl_csv_to_omop.R
```

This:
1. Reads Synthea CSV files
2. Transforms to OMOP v5.4 format
3. Loads into `config$cdm_schema` in SQL Server

### 12.3 Run data quality checks

```bash
Rscript workflow/06_quality_check_defined_phenotypes.R
```

---

## Step 13: Create and Test Analysis Code (30–60 minutes)

### 13.1 Build cohorts

```bash
Rscript workflow/02_define_omop_cohort_outcome_covariates.R
```

This:
1. Validates your SQL cohort definitions
2. Instantiates target, outcome, and comparator cohorts in SQL Server
3. Checks that the cohorts are non-empty and reasonable

### 13.2 Run analyses

```bash
Rscript workflow/07_setup_analysis_env.R       # Install analysis packages
Rscript workflow/08_run_analysis_and_manuscript_report.R
```

All analysis parameters are controlled by the `analyses:` flags in `study_params.yaml`.
No code editing needed — just set flags to `true` / `false`.

### 13.3 Review outputs

Outputs are written to `config$output_folder` (e.g., `output/my_study/`):

```bash
# Inside the container
ls -la output/my_study/

# View results in VS Code or your file explorer
# e.g., output/my_study/CharacterizationResults.csv
```

---

## Step 14: Create Transportable Code Packet (5 minutes)

Your analysis code is now ready to run in any environment (with SQL Server access).

### 14.1 Generate the transportable bundle

```bash
# Inside the container
Rscript workflow/09_create_transportable_bundle.R
```

This creates a self-contained folder `portable/transportable_bundle/` containing:
- All analysis R code
- Pinned R packages (`renv.lock`)
- JDBC driver (bundled)
- OHDSI packages (prebuilt binaries)
- Configuration templates

### 14.2 Share the packet

The `transportable_bundle/` can be:
1. **Shipped to a data partner** — they extract it, update config with their schema names, and run `Rscript 08_run_analysis.R` locally
2. **Pushed to GitHub** — other researchers can clone and use it
3. **Archived** — long-term preservation of exact analysis code and package versions

---

## Troubleshooting

### Docker/SQL Server issues

**"Cannot connect to SQL Server"**
```bash
docker compose ps              # Check if mssql_dev is running
docker compose logs mssql      # View SQL Server logs
docker compose up -d           # Restart if needed
```

**"OMOP vocabulary load is slow"**
- Vocabulary load is expected to take 30–60 minutes (one-time cost)
- Check `docker compose logs -f mssql` for progress

### Dev Container issues

**"Cannot find omop_vocab"**
- Ensure `OMOP_Dev/omop_vocab/` contains `CONCEPT.csv` directly
- Rebuild container: `Cmd+Shift+P` → **Dev Containers: Rebuild Container**

**"R packages not found"**
- Inside container: `renv::restore()`
- Then retry the script

### Concept ID issues

**"Concept not found"**
- Re-run `Rscript scripts/concept_lookup.R` with different search terms
- Check the OMOP documentation: https://ohdsi.github.io/TheBookOfOhdsi/

**"Concept ID seems wrong"**
- Your vocabulary version may differ from the development version
- Always verify concept IDs against your live vocabulary

---

## Next Steps

1. **Commit your study definition** to version control:
   ```bash
   git add study_params.yaml cohorts/ covariates/
   git commit -m "feat: Define <your study name> cohort, outcome, and covariates"
   git push
   ```

2. **Share your analysis** — push the transportable bundle or the study repo itself

3. **Document your phenotypes** — add README files explaining clinical rationale for each cohort

---

## Getting Help

- **OHDSI Community** — [forums.ohdsi.org](https://forums.ohdsi.org)
- **Book of OHDSI** — [ohdsi.github.io/TheBookOfOhdsi](https://ohdsi.github.io/TheBookOfOhdsi)
- **Your coding assistant** — ask it to explain any of these steps or help debug errors

---

## Key Files to Know

| File | Purpose |
|------|---------|
| `config.R` | Infrastructure settings (do not edit) |
| `study_params.yaml` | Your study's settings (edit this) |
| `cohorts/*.sql` | Cohort definitions (edit these) |
| `covariates/*.csv` | Covariate definitions (edit these) |
| `workflow/01–09` | Analysis pipeline (do not edit) |
| `.devcontainer/` | Dev environment (do not edit) |
| `output/` | Analysis results (gitignored) |
| `portable/` | Transportable bundle (for sharing) |

---

## Version Info

- **R version:** 4.5.x
- **Java:** 17 (Eclipse Adoptium)
- **SQL Server:** Azure SQL Edge (ARM64) or SQL Server 2022 (AMD64)
- **OHDSI packages:** Latest from [github.com/OHDSI](https://github.com/OHDSI)
- **OMOP CDM:** v5.4

