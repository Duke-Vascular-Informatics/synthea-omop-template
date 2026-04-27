# docs/

Supplementary project documentation that does not belong in the root README.

## Scope

- Owns: detailed procedural, troubleshooting, and operator references.
- Does not own: root-level repository orientation (see `README.md`).
- Canonical procedure source: `GETTING_STARTED.md`.
- Canonical commands source: `COMMANDS.md`.

## Files

| File | Description |
|------|-------------|
| `GETTING_STARTED.md` | **Start here for new users.** Complete end-to-end workflow from VS Code setup through analysis. Includes post-clone workflow with skip gates for repeat users. |
| `COMMANDS.md` | **Canonical command index.** Single source of truth for executable command snippets used across docs. |
| `ANALYST_PLAYBOOK.md` | **Quick triage guide.** Decision-tree style routing for analysts: first-run vs repeat-study, concept lookup, setup checks, hook install, and support bundle escalation. |
| `MAINTAINER_PLAYBOOK.md` | **Maintainer runbook.** Governance checks, strict release docs freeze commands, and canonical source ownership rules. |
| `GIT_GITHUB_AUTH.md` | **Git auth deep dive.** SSH and HTTPS/token-backed GitHub authentication setup details used by Step 2. |
| `SETUP.md` | **Infrastructure reference.** Deep dive into prerequisites, Docker setup, required `OMOP_Dev/` folder layout, relative paths, Athena vocabulary download and CPT-4 rebuild, loading vocabulary into SQL Server, and troubleshooting. Use this if you hit issues during automated setup. |
| `TROUBLESHOOTING_VOCAB_LOAD.md` | **Vocabulary troubleshooting.** Focused checks and retry flow for Step 10 OMOP vocabulary loading failures. |
| `TROUBLESHOOTING_ETL.md` | **ETL troubleshooting.** Focused run-order and failure-pattern checks for Step 13 synthetic generation and ETL issues. |
| `TOPIC_OWNERSHIP.csv` | **Topic ownership matrix.** Maps sensitive topic headings to canonical owner docs to reduce content cloning. |
| `REPORT_GENERATION.md` | Detailed guide to the automated Word report generation pipeline: what each table and figure contains, how to re-run report generation independently of the full workflow, and how to interpret the output metrics. |
| `workflow_steps.yaml` | **Machine-readable step map.** Canonical step labels/anchors used by docs validation guardrails. |
| `CHANGELOG.md` | **Governance changelog.** Categorized record of workflow/command/validator/process documentation changes. |
