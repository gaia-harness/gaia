#!/usr/bin/env bash
# The publish job's "Handle scope rejection" step. Reads the handoff and gate
# folders under RUNNER_TEMP and needs GH_TOKEN for the needs-human handler.
# Runs from the publish job's checkout of main, never the fix.
set -eu
# The triage job's own scope check passed this fix, so a rejection
# here means that check was bypassed or tampered with. The branch is
# never pushed.
reason_file="${RUNNER_TEMP}/scope-rejection-reason.md"
rejection_file="${RUNNER_TEMP}/forensics-gate/scope-rejection.md"
{
  cat "${RUNNER_TEMP}/forensics-handoff/reasoning.md"
  printf '\n\n---\n\nThe quality-gate job rejected the fix on its independent scope check, which the triage job had passed (possible tampering):\n\n'
  if [ -f "$rejection_file" ]; then
    cat "$rejection_file"
  else
    printf '_(rejection detail missing, see workflow run logs)_\n'
  fi
  printf '\n\nworkflow run: %s/%s/actions/runs/%s\n' \
    "${GITHUB_SERVER_URL}" "${GITHUB_REPOSITORY}" "${GITHUB_RUN_ID}"
} > "$reason_file"
"$FORENSICS_DIR/handlers/handle-needs-human.sh" \
  "$ISSUE_NUMBER" \
  "$reason_file" \
  "out-of-scope"
