# Workspace Instructions

This analysis folder inherits shared AI coding instructions from:

- `../CLAUDE.md`

Use the workspace-level file as canonical guidance for Claude Code and other assistants.

## Local Overrides

### Version Control Routing

This repo is a **git submodule** of the workspace root (`omop-dev-workspace`). It has its own independent remote.

| Remote | URL | What to push |
|--------|-----|-------------|
| `origin` | `https://github.com/Duke-Vascular-Informatics/synthea-omop-template.git` | Full repository (`git push origin main`) |

**Submodule rule:** after committing and pushing changes here, also update the submodule pointer in the workspace root repo:

```bash
# From /workspace (root repo)
git add synthea-omop-template
git commit -m "chore: update synthea-omop-template submodule pointer"
git push origin main
```

### Template Sync Workflow

Comparing analysis repos against this template is a **manual, on-demand step** — run the
`/sync-template` skill from the workspace root when you want to check for infrastructure
improvements to back-port. There is no automatic/scheduled routine; the previous every-3-day
scheduled routine was removed because it generated unnecessary GitHub issues on a fixed
cadence regardless of whether anything had actually changed.

**Repo list source — always `studies.yaml`, never an ad hoc list.** `/sync-template` reads
`<workspace_root>/studies.yaml` for the authoritative list of studies, ETLs, and templates.
Do not hardcode a repo list and do not auto-discover repos by globbing directory names
(e.g. `find ... -name 'pad-*'`) — `studies.yaml` is the single source of truth and already
covers repos that aren't physically present in the workspace folder (via GitHub API) and
repos that don't follow the `pad-*` naming convention (e.g. ETLs, `tbad-tevar-rupture-val`).
Register new studies there (workflow/02 does this automatically on first successful run)
rather than relying on any naming pattern.