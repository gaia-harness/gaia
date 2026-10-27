#!/usr/bin/env bash
# The triage job's "Parse issue body" step. Reads FORENSICS_DIR from the job
# environment and RUNNER_TEMP and GITHUB_OUTPUT from the runner; writes
# parsed_file and valid to GITHUB_OUTPUT. Runs before the model edits the
# tree, from the job's own checkout.
set -eu
parsed_file="${RUNNER_TEMP}/forensics/parsed.json"
"$FORENSICS_DIR/parse-issue-body.sh" "${RUNNER_TEMP}/forensics/issue-body.md" > "$parsed_file"
cp "$parsed_file" "${RUNNER_TEMP}/forensics-handoff/parsed.json"

# parse-issue-body.sh emits an internal-error
# JSON envelope when one of its awk pipelines fails. Distinct
# from valid:false; route to needs-human with reason-code
# `internal-error` rather than letting the workflow fall
# through to malformed-body handling.
if [ "$(jq -r '.internal_error // false' "$parsed_file")" = "true" ]; then
  reason_file="${RUNNER_TEMP}/forensics/internal-error-reason.md"
  jq -r '"forensics primitive `parse-issue-body.sh` failed at stage `\(.stage)` (exit \(.exit_code))"' "$parsed_file" > "$reason_file"
  cp "$reason_file" "${RUNNER_TEMP}/forensics-handoff/reason.md"
  printf 'route=needs-human\nreason_code=internal-error\n' > "${RUNNER_TEMP}/forensics-handoff/route.env"
  exit 0
fi

valid="$(jq -r '.valid' "$parsed_file")"
echo "parsed_file=$parsed_file" >> "$GITHUB_OUTPUT"
echo "valid=$valid" >> "$GITHUB_OUTPUT"
