# Workspace Instructions

This analysis folder inherits shared AI coding instructions from:

- `../CLAUDE.md`

Use the workspace-level file as canonical guidance for Claude Code and other assistants.

## Local Overrides

### Version Control Routing

This repo is a **git submodule** of the workspace root (`omop-dev-workspace`). It has its own independent remote.

| Remote | URL | What to push |
|--------|-----|-------------|
| `origin` | `https://github.com/adam-mdmph/synthea-omop-dev.git` | Full repository (`git push origin main`) |

**Submodule rule:** after committing and pushing changes here, also update the submodule pointer in the workspace root repo:

```bash
# From /workspace (root repo)
git add synthea-omop-dev
git commit -m "chore: update synthea-omop-dev submodule pointer"
git push origin main
```
