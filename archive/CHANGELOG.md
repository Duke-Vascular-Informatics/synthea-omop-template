# Documentation Governance Changelog

Track governance changes that affect documentation consistency and contributor workflow.

## Categories

### Canonical workflow changes
Changes to workflow ordering, step names, or ownership boundaries in procedural docs.

### Canonical command changes
Updates to executable command snippets in `docs/COMMANDS.md`.

### Step map changes
Updates to `docs/workflow_steps.yaml` and generated checklist step index behavior.

### Validator/guardrail changes
Updates to `scripts/validate_docs_commands.R`, hooks, and CI docs enforcement jobs.

### Ownership and process changes
Updates to CODEOWNERS, PR templates, review requirements, and maintainer/analyst playbooks.

---

## 2026-04-27

### Validator/guardrail changes
- Added markdown local link and anchor validation to docs validator.
- Added strict mode (`DOCS_STRICT=1`) to escalate warnings to failures for release freeze checks.

### Step map changes
- Added generated checklist step index sync check.

### Ownership and process changes
- Added `.github/CODEOWNERS` for canonical docs governance.
- Added `docs/MAINTAINER_PLAYBOOK.md` and `docs/TOPIC_OWNERSHIP.csv`.
