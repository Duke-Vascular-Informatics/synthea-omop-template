# OMOP Synthetic Data Generation Template

This GitHub repo is a reusable starter kit for generating a disease/procedure/outcome-specific
synthetic OMOP CDM v5.4 dataset using Synthea — the module-authoring, generation, ETL, and
quality-check steps (`workflow/01–06`) that produce a reusable synthetic dataset for a
`<study>-synth` repo. It is **not** used for analysis: create a separate analysis-core repo
from [`strategus-study-template`](https://github.com/Duke-Vascular-Informatics/strategus-study-template)
for that, consuming the dataset this repo produces.

The template is self-contained and optimized to develop with any AI coding assistant
(GitHub Copilot, Claude Code, or others). The purpose of this development workflow is to create
transportable offline-capable code: all R packages are pinned in `renv.lock`, the JDBC driver is bundled,
and OHDSI packages ship as prebuilt binaries so the resulting code runs in air-gapped or
restricted-network environments.

---

## What this repo is for

**Use this template only to generate a reusable synthetic OMOP CDM dataset** — author a Synthea
disease/procedure module, generate synthetic patients, ETL them into OMOP CDM, and run
post-ETL quality checks (`workflow/01–06`). Register the result in
`synthetic_data/registry.yaml` so other studies can reuse it. This is the `-synth` repo
convention: a dedicated, data-generation-only repo that never itself answers a research
question.

**For a study's analysis — any study, whether or not it consumes a dataset generated
here — use
[`strategus-study-template`](https://github.com/Duke-Vascular-Informatics/strategus-study-template)
instead.** That is the current, recommended template for every new analysis-core repo:
declarative circe/Strategus cohort definitions, the extract layer, and nothing else. See
[charon's README ("Multi-Repo Analysis Pipeline")](https://github.com/Duke-Vascular-Informatics/charon#multi-repo-analysis-pipeline)
for the full picture.

**Every study also gets a separate report repo**, built from
[`omop-report-template`](https://github.com/Duke-Vascular-Informatics/omop-report-template) —
manuscript composition never belongs in an analysis-core repo, and never belonged in this
data-generation repo either.

> **A previous version of this template also supported a full in-repo analysis workflow**
> (`workflow/07–09`: run the analysis, generate a Word manuscript report, and package a
> portable bundle, all in the same repo as data generation). That capability is no longer
> documented or recommended — new analysis work goes in `strategus-study-template`. It
> remains visible in this repo's git history for any study still built on it, but the
> documentation below describes only the data-generation path.

---

## Start Here (Canonical Setup Guide)

To avoid duplicated or conflicting instructions, this README is intentionally high-level.

## Scope

- Owns: repository orientation, architecture map, and links to canonical docs.
- Does not own: step-by-step execution details or command snippets that may drift.
- Canonical procedural source: [../docs/GETTING_STARTED.md](../docs/GETTING_STARTED.md).
- Canonical commands source: [../docs/COMMANDS.md](../docs/COMMANDS.md).

- Use [../docs/GETTING_STARTED.md](../docs/GETTING_STARTED.md) as the **single source of truth** for end-to-end setup and execution.
- Use the root `omop-dev-workspace` README for shared Docker, SQL Server, dev container, and vocabulary setup.

## Quick Start (Condensed)

1. Create a repo from this template and name it `<study>-synth` (the `-synth` suffix is
   the workspace-wide convention for a data-generation-only repo).
2. Clone the new repo into your local `omop-dev-workspace/` as a subfolder.
3. Open the workspace in VS Code Dev Containers (from the workspace root).
4. From inside the repo's container, run the required bootstrap step:
   `Rscript workflow/01_setup_synthea_etl_qc_env.R`
5. Author your Synthea module, and fill in `cohorts/*.sql` and `covariates/*.csv` only as
   far as needed to validate the generated data (Steps 2–6) — there is no study analysis
   to configure here.
6. Run Steps 2–6 using canonical commands in [../docs/COMMANDS.md](../docs/COMMANDS.md),
   then register the resulting dataset in `synthetic_data/registry.yaml`.

For full step-by-step commands, follow [../docs/GETTING_STARTED.md](../docs/GETTING_STARTED.md).
For workspace-level setup (Docker, SQL Server, OMOP vocabulary, and dev container),
use the root workspace README in `omop-dev-workspace/`.

---

## What to change vs. what to leave alone

| Change for every dataset | Leave as-is |
|------------------------|-------------|
| `synthea/modules/*.json` (your disease/procedure module) | `config.R` (infrastructure only — no edits needed) |
| `cohorts/*.sql` (only as far as Step 2 validation needs) | `R/drivers.R`, `R/connection.R`, `R/cohorts.R` |
| `covariates/*.csv` (only as far as Step 2 validation needs) | `setup/` |
| `study_params.yaml`'s generation parameters (population, age range, seed) | `renv.lock` (update only to add a new package) |

---

## Dev Container Scope

This study template is designed to run inside the shared root workspace container.
Keep machine-level setup instructions in the workspace README and keep this README
focused on template usage.

Workspace-first note: open `omop-dev-workspace/` in VS Code and use the single
shared root-level container definition for the workspace.

---

## Workflow Reference

Run Step 1 once immediately after opening this repo in the dev container. This is
the per-repo bootstrap checkpoint (renv/packages, JDBC checks, and DB preflight), distinct
from one-time workspace infrastructure setup.

| Step | Script | Purpose |
|------|--------|---------|
| 1 | `workflow/01_setup_synthea_etl_qc_env.R` | Install packages, verify DB connectivity, provision JDBC driver |
| 2 | `workflow/02_define_omop_cohort_outcome_covariates.R` | **Validate your study definition** — cohort SQL, covariate CSVs, concept IDs |
| 3 | `workflow/03_generate_synthea_module_artifacts.R` | Validate Synthea disease module and regenerate HTML diagram |
| 4 | `workflow/04_generate_synthea_csv.ps1` / `.sh` | Generate Synthea synthetic patients |
| 5 | `workflow/05_etl_csv_to_omop.R` | ETL Synthea CSV → OMOP CDM |
| 6 | `workflow/06_quality_check_defined_phenotypes.R` | Post-ETL data quality checks — the last step for a `-synth` repo |

After Step 6, register the resulting dataset in `synthetic_data/registry.yaml` so other
studies can reuse it. This repo's documented workflow ends here — there is no Step 7
onward; analysis happens in a separate `strategus-study-template` repo.

Each step script is standalone and resolves the project root automatically, so it can be
run from any shell working directory.

---

## Repository Structure

```
<study>-synth/
  config.R                    ← single source of truth for all settings
  workflow/                   ← numbered step scripts (01–06)
  R/                          ← reusable infrastructure functions
  setup/                      ← renv + package install helpers
  scripts/                    ← ETL, Synthea runner, QC utilities
  cohorts/                    ← SQL cohort definitions (as far as Step 2 validation needs)
  covariates/                 ← covariate CSV spec files (as far as Step 2 validation needs)
  synthea/modules/            ← Synthea disease module + diagram (edit this)
  drivers/                    ← JDBC driver archive
  .github/                    ← Claude Code / AI assistant instructions
  output/                     ← generation/QC outputs (gitignored)
```

---

## Package Management

R packages are pinned in `renv.lock` (R 4.5.2, cloud.r-project.org). Packages needed for
synthetic data generation (ETLSyntheaBuilder, Synthea tooling, and the rest of this
repo's lockfile) are CRAN- or OHDSI-drat-available and handled by `renv` directly.

To add a new package:

```r
renv::install("package_name")
renv::snapshot()
```

---

## AI Assistant Integration

This repo ships coding convention files that work with any AI coding assistant
(GitHub Copilot, Claude Code, or others):

1. **Concept ID transparency** — every concept ID recommendation must be tagged `[vocab query]`
   (confirmed against live vocabulary) or `[pretraining]` (unverified, with explicit warning).
2. **HADES-first package selection** — use OHDSI HADES packages for all OHDSI methodology;
   fall back to tidyverse; all packages must be on the project CRAN mirror.
3. **Verbose comments** — all code follows OHDSI GitHub repository commenting conventions.

| File | Scope | Purpose |
|------|-------|---------|
| `CLAUDE.md` | Every session | Core coding conventions (concept IDs, packages, comments, architecture) |
| `.github/copilot-instructions.md` | GitHub Copilot | Points all assistants to `CLAUDE.md` |
| `.github/instructions/r-packages.instructions.md` | `*.R` files | HADES priority, CRAN mirror, renv workflow |
| `.github/instructions/omop-ohdsi.instructions.md` | `*.R` and `*.sql` | DatabaseConnector/SqlRender patterns, concept ID lookup, OMOP CDM conventions |

**Concept Lookup (terminal):**

```bash
Rscript scripts/concept_lookup.R "peripheral arterial disease" Condition
Rscript scripts/concept_lookup.R "cefazolin" Drug
Rscript scripts/concept_lookup.R "ankle brachial index" Measurement
```

Queries the live OMOP vocabulary in the connected SQL Server and returns ranked
candidate concepts with recommendation. Use this before writing any concept ID into
code or CSV files.

---

## Documentation

| Resource | Purpose | Audience |
|----------|---------|----------|
| **[../docs/GETTING_STARTED.md](../docs/GETTING_STARTED.md)** | Canonical step-by-step workflow from first-time setup to synthetic data generation | New users, first time setup |
| **[../docs/COMMANDS.md](../docs/COMMANDS.md)** | Canonical command index used by all operational docs | All users |
| **[docs/CITATION_TEMPLATE_METHODS.md](docs/CITATION_TEMPLATE_METHODS.md)** | Template-repo citation language and contributor list for methods sections | Manuscript authors |
| **[../docs/ANALYST_PLAYBOOK.md](../docs/ANALYST_PLAYBOOK.md)** | Fast decision-tree guidance for common analyst tasks and escalation | Analysts, support triage |
| **[../docs/MAINTAINER_PLAYBOOK.md](../docs/MAINTAINER_PLAYBOOK.md)** | Governance and release-freeze checks for documentation consistency | Maintainers |
| **[../docs/SETUP.md](../docs/SETUP.md)** | Detailed Docker, SQL Server, Athena vocabulary, and dev container setup | Docker/infrastructure details |
| **[CHECKLIST.md](CHECKLIST.md)** | Quick visual reference for workflow phases and key commands | Quick reference during work |
| **[CLAUDE.md](CLAUDE.md)** | Coding conventions, package rules, comment style, architecture | Developers, AI assistants |
| **[../docs/CHANGELOG.md](../docs/CHANGELOG.md)** | Categorized docs-governance change history for high-signal review | Maintainers, reviewers |
| **[../infrastructure/setup/setup_docker_and_vocab.sh](../infrastructure/setup/setup_docker_and_vocab.sh)** | Automated Docker + vocabulary setup (macOS/Linux, workspace-level) | Automation-first users |
| **[../infrastructure/setup/setup_docker_and_vocab.ps1](../infrastructure/setup/setup_docker_and_vocab.ps1)** | Automated Docker + vocabulary setup (Windows PowerShell, workspace-level) | Windows users |
| **[Book of OHDSI](https://ohdsi.github.io/TheBookOfOhdsi/)** | OHDSI methodology reference (cohorts, phenotypes, causal inference) | OHDSI methods questions |
| **[OHDSI Forums](https://forums.ohdsi.org)** | Community Q&A and discussion | Troubleshooting, best practices |

---

## License, Copyleft, and Publication Expectations

Copyright 2026 Duke University. All Rights Reserved. The software is hereby licensed under the GNU GPL License v2 (see [LICENSE](LICENSE)).

What that means in practice for repos built from this template:

1. If you modify this code and **convey/distribute** it to others (including collaborators,
  clients, or partner sites), you must provide the corresponding source code under GPL v2.
2. Modified versions must keep license/copyright notices, include a copy of GPL v2, and
  clearly indicate that changes were made.
3. You may run and modify code privately without distribution obligations until you convey it.
4. You may not apply additional restrictions that remove recipients' GPL rights.

Template project expectation:

1. Maintain a GitHub repository for each synthetic dataset derived from this template.
2. Publish the code and workflow artifacts for reproducibility whenever institutionally and
  contractually permitted.
3. If public release is not allowed (for governance, legal, or contractual reasons), keep a
  private repository but still satisfy GPL v2 obligations when sharing code with recipients.

> This section is a practical summary for analysts and developers, not legal advice.
> For legal interpretation, consult your organization's counsel.

### Third-party software: Synthea

This template vendors [Synthea](https://github.com/synthetichealth/synthea)
(Copyright 2017-2025 The MITRE Corporation) at `external/synthea/`, an independently
developed, open-source synthetic patient generator distributed under its own
**Apache License 2.0** — a separate license from this repository's GPL v2, not a
GPL v2 dependency. Synthea's own `LICENSE` and `NOTICE` files are preserved unmodified
in `external/synthea/`; the `NOTICE` file documents Synthea's own third-party content
(RxNorm, LOINC, SNOMED CT terminology, and the SBSCL library). Synthea is not
affiliated with Duke University; see the upstream project for its own terms,
attribution requirements, and citation.

---

## Notes

- `drivers/mssql-jdbc-13.2.1.zip` is tracked so JDBC setup is reproducible offline.
- `renv/library/` is intentionally not committed (restored from `renv.lock` on first run).
- `output/` is gitignored — commit outputs separately if needed for reproducibility.

---

## Funding

Research reported in this publication was supported by the National Center For Advancing Translational Sciences of the National Institutes of Health under Award Number K12TR005435. The content is solely the responsibility of the authors and does not necessarily represent the official views of the National Institutes of Health.
