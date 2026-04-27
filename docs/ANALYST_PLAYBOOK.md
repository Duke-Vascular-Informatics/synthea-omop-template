# Analyst Playbook

Fast operational guide for analysts using this template.

Use this page for quick routing. Use `docs/GETTING_STARTED.md` for full procedural detail.
Use `docs/COMMANDS.md` for canonical command snippets.
For repository governance and release docs checks, use `docs/MAINTAINER_PLAYBOOK.md`.

---

## Decision Tree

1. New machine or first run?
- Follow `docs/GETTING_STARTED.md` Steps 1-9.

2. Existing machine, new study?
- Start at Step 10 in `docs/GETTING_STARTED.md`.

3. Unsure what is missing?
- Run:

```bash
Rscript scripts/check_setup.R
```

4. Need concept IDs?
- Run:

```bash
Rscript scripts/concept_lookup.R "<clinical term>" <Domain>
```

5. Stuck after one fix attempt?
- Run:

```bash
Rscript scripts/create_support_bundle.R
```

---

## One-Click Tasks (VS Code)

Use `Terminal -> Run Task`:

- Analyst: Install Git Hooks
- Analyst: Check Setup
- Analyst: Concept Lookup
- Analyst: Validate Step 2 Artifacts
- Analyst: Run Step 8 Analysis
- Analyst: Build Portable Bundle (bash / PowerShell)
- Analyst: Create Support Bundle

---

## Common Paths

### Real CDM path

- Skip synthetic generation steps.
- Run Step 2 validation and Step 8 analysis.

### Synthetic data path

- Run Steps 3-6 for generation and ETL.
- Then run Step 8 analysis.

---

## Hooks for Local Guardrails

Install local git hooks once per clone:

```bash
bash scripts/hooks/install_git_hooks.sh
```

What they do:

- pre-commit: runs setup checks when study-definition files are staged.
- pre-push: validates docs commands and runs tests (if `testthat` is installed).

To bypass once:

```bash
SKIP_ANALYST_HOOKS=1 git commit -m "message"
```

---

## Escalation Bundle

When requesting support, attach the archive path printed by:

```bash
Rscript scripts/create_support_bundle.R
```

Bundle contents include:

- redacted `study_params.yaml`
- setup check report
- git branch/status/history
- recent log snippets
