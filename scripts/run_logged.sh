#!/usr/bin/env bash
# =============================================================================
# scripts/run_logged.sh — run a long pipeline step with a log and a visible verdict.
#
# WHY: a Step 5 run was OOM-killed (SIGKILL, exit 137) twice with NO message in its
# log — it just stopped, and the only clue was a process that had vanished. A kill
# cannot be trapped from inside R, but the parent shell sees the exit status. This
# wrapper appends it to the log, with a hint for the signals that matter.
#
# USAGE (works in the background too):
#   nohup bash scripts/run_logged.sh logs/step5.log Rscript workflow/05_etl_csv_to_omop.R &
#   grep -a "RUN_LOGGED" logs/step5.log     # one summary line when it finishes
# =============================================================================
set -uo pipefail
LOG="${1:?usage: run_logged.sh <logfile> <command...>}"; shift
mkdir -p "$(dirname "$LOG")"
START=$(date +%s)
echo "[RUN_LOGGED] start $(date -u +%FT%TZ): $*" >> "$LOG"
"$@" >> "$LOG" 2>&1
CODE=$?
SECS=$(( $(date +%s) - START ))
case "$CODE" in
  0)   HINT="ok" ;;
  137) HINT="killed by SIGKILL — almost certainly out of memory (see the Step 5 memory guard; try SYNTHEA_SKIP_CLAIMS=true or more RAM)" ;;
  143) HINT="terminated (SIGTERM) — stopped externally" ;;
  130) HINT="interrupted (SIGINT)" ;;
  *)   HINT="failed — see the lines above this one" ;;
esac
echo "[RUN_LOGGED] EXIT=$CODE after ${SECS}s: $HINT" >> "$LOG"
exit "$CODE"
