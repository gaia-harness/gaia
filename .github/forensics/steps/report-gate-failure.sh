#!/usr/bin/env bash
# The publish job's "Handle Quality Gate failure" step. Reads the handoff
# folder and the gate summary under RUNNER_TEMP and needs GH_TOKEN for the
# needs-human handler. Runs from the publish job's checkout of main, never
# the fix.
set -eu
# The branch is never pushed, so there is nothing to clean up on
# origin. Compose the comment, demote.
gate_summary_file="${RUNNER_TEMP}/forensics-gate/gate-summary.json"
reason_file="${RUNNER_TEMP}/gate-failure-reason.md"
# shellcheck disable=SC2016 # jq filters are intentionally single-quoted
{
  cat "${RUNNER_TEMP}/forensics-handoff/reasoning.md"
  printf '\n\n---\n\nQuality Gate failure summary:\n\n'
  if [ -f "$gate_summary_file" ]; then
    failed_step="$(jq -r '.failed_step // "unknown"' "$gate_summary_file")"
    exit_code="$(jq -r '.exit_code // "unknown"' "$gate_summary_file")"
    printf 'failed step: `%s` (exit %s)\n\n' "$failed_step" "$exit_code"
    printf 'log excerpt:\n\n```\n'
    jq -r '.log_excerpt // ""' "$gate_summary_file"
    printf '\n```\n\n'
  else
    printf '_(gate summary file missing, see workflow run logs)_\n\n'
  fi
  printf 'workflow run: %s/%s/actions/runs/%s\n' \
    "${GITHUB_SERVER_URL}" "${GITHUB_REPOSITORY}" "${GITHUB_RUN_ID}"
} > "$reason_file"
"$FORENSICS_DIR/handlers/handle-needs-human.sh" \
  "$ISSUE_NUMBER" \
  "$reason_file" \
  "gate-failure"
