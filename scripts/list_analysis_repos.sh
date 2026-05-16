#!/usr/bin/env bash
# scripts/list_analysis_repos.sh
#
# Discovers analysis repos to include in the daily sync routine.
# Prints one line per repo: "<local-path> <github-remote-url>"
#
# Usage:
#   bash scripts/list_analysis_repos.sh
#
# The sync agent sources this output to build its repo list dynamically,
# so adding a new pad-* directory to the workspace root is all that's
# needed to include it in the next sync run.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
WORKSPACE_ROOT="$(cd "$TEMPLATE_ROOT/.." && pwd)"

while IFS= read -r -d '' repo_dir; do
  if [ ! -d "$repo_dir/.git" ]; then
    continue
  fi
  remote_url=$(git -C "$repo_dir" remote get-url origin 2>/dev/null) || continue
  echo "$repo_dir $remote_url"
done < <(find "$WORKSPACE_ROOT" -maxdepth 1 -type d -name 'pad-*' -print0 | sort -z)
