# Maintainer Playbook

Operational runbook for repository maintainers.

This complements `docs/ANALYST_PLAYBOOK.md`:
- Analyst playbook: study execution and triage flow.
- Maintainer playbook: repo governance, docs guardrails, release checks.

## Scope

- Owns: governance operations for documentation consistency and release readiness.
- Does not own: analyst workflow instructions (see `docs/ANALYST_PLAYBOOK.md`).

## Daily Maintainer Checks

1. Validate docs consistency:

```bash
Rscript scripts/validate_docs_commands.R
```

2. Verify checklist step index is synchronized:

```bash
Rscript scripts/generate_checklist_step_index.R --check
```

3. If step titles changed, regenerate checklist index:

```bash
Rscript scripts/generate_checklist_step_index.R
```

## Canonical Source Rules

1. Workflow step names and order are owned by `docs/workflow_steps.yaml`.
2. Step-by-step execution is owned by `docs/GETTING_STARTED.md`.
3. Command snippets are owned by `docs/COMMANDS.md`.
4. Topic ownership is declared in `docs/TOPIC_OWNERSHIP.csv`.

## Release Docs Freeze

Run strict docs checks before tagging or high-impact merges:

```bash
DOCS_STRICT=1 Rscript scripts/validate_docs_commands.R
Rscript scripts/generate_checklist_step_index.R --check
```

Strict mode enforces:
- no broken local markdown links
- no unresolved local anchors
- no deprecated command/path references
- no topic ownership warnings
- checklist step index synchronized with step map

## Governance Changelog

Record docs governance changes in `docs/CHANGELOG.md` under:
- Canonical workflow changes
- Canonical command changes
- Step map changes
- Validator/guardrail changes
- Ownership and process changes
