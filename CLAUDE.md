# Workspace Instructions

This analysis folder inherits shared AI coding instructions from:

- `../CLAUDE.md`

Use the workspace-level file as canonical guidance for Claude Code and other assistants.

## Local Overrides

### Version Control Routing

This repo is a **git submodule** of the workspace root (`omop-dev-workspace`). It has its own independent remote.

| Remote | URL | What to push |
|--------|-----|-------------|
| `origin` | `https://github.com/adam-mdmph/synthea-omop-template.git` | Full repository (`git push origin main`) |

**Submodule rule:** after committing and pushing changes here, also update the submodule pointer in the workspace root repo:

```bash
# From /workspace (root repo)
git add synthea-omop-template
git commit -m "chore: update synthea-omop-template submodule pointer"
git push origin main
```

### Daily Sync Routine

When running the repository sync agent (comparing analysis repos against this template), **do not use a hardcoded repo list**. Instead, auto-discover repos at runtime:

1. Locate the workspace root — the parent directory of this repo:
   ```bash
   WORKSPACE_ROOT="$(git -C . rev-parse --show-toplevel)/.."
   ```
2. Find all sibling directories whose names match `pad-*`:
   ```bash
   find "$WORKSPACE_ROOT" -maxdepth 1 -type d -name 'pad-*' | sort
   ```
   Or use the helper script:
   ```bash
   bash scripts/list_analysis_repos.sh
   ```
3. For each discovered directory, read its GitHub remote from git:
   ```bash
   git -C "$REPO_DIR" remote get-url origin
   ```
4. Compare the `main` branch of each discovered repo against this template's `main` branch.
5. Apply the file-scope rules (PROPAGATE / SKIP paths) defined in the sync agent prompt.

**Naming convention:** analysis repos follow `pad-{study-name-kebab-case}` (e.g. `pad-oler-ssi-val`, `pad-amp-nhd-val`). Any new repo added to the workspace root matching this pattern is automatically included in the next sync run — no prompt editing required.
