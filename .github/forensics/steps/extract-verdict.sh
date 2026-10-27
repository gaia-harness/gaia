#!/usr/bin/env bash
# The triage job's "Extract verdict" step. Reads EXEC_FILE, the classifier
# action's execution file, from the step environment; writes verdict,
# verdict_file, verdict_text and reasoning_file to GITHUB_OUTPUT for the
# routing steps. Runs before the model edits the tree.
set -eu
# The action emits a top-level JSON array of execution events;
# the assistant's final response lives on the entry where
# `type == "result"` (field `.result`). Extract that to a plain
# text file for parse-verdict.
verdict_text="${RUNNER_TEMP}/forensics/verdict-text.md"
if [ -z "${EXEC_FILE:-}" ] || [ ! -f "$EXEC_FILE" ]; then
  echo "::error::classifier execution_file missing or unreadable: ${EXEC_FILE:-<empty>}"
  exit 1
fi
jq -r '[.[] | select(.type == "result")] | .[-1].result // empty' "$EXEC_FILE" > "$verdict_text"
if [ ! -s "$verdict_text" ]; then
  echo "::warning::classifier produced no result text, treating as ambiguous"
fi

parsed="${RUNNER_TEMP}/forensics/verdict.json"
"$FORENSICS_DIR/parse-verdict.sh" "$verdict_text" > "$parsed"

# parse-verdict.sh emits an internal-error
# JSON envelope when one of its awk pipelines fails. Route to
# needs-human with reason-code `internal-error` before the
# ambiguous-verdict dispatch (the two are deliberately
# distinct: `ambiguous` is a parsed-but-non-conformant
# classifier response; `internal-error` is the parser itself
# failing).
if [ "$(jq -r '.internal_error // false' "$parsed")" = "true" ]; then
  reason_file="${RUNNER_TEMP}/forensics/internal-error-reason.md"
  jq -r '"forensics primitive `parse-verdict.sh` failed at stage `\(.stage)` (exit \(.exit_code))"' "$parsed" > "$reason_file"
  cp "$reason_file" "${RUNNER_TEMP}/forensics-handoff/reason.md"
  printf 'route=needs-human\nreason_code=internal-error\n' > "${RUNNER_TEMP}/forensics-handoff/route.env"
  exit 0
fi

verdict="$(jq -r '.verdict' "$parsed")"
echo "verdict=$verdict"

# Reasoning becomes the comment body for non-issue / needs-human.
reasoning="${RUNNER_TEMP}/forensics/reasoning.md"
jq -r '.reasoning' "$parsed" > "$reasoning"
cp "$reasoning" "${RUNNER_TEMP}/forensics-handoff/reasoning.md"

{
  echo "verdict=$verdict"
  echo "verdict_file=$parsed"
  echo "verdict_text=$verdict_text"
  echo "reasoning_file=$reasoning"
} >> "$GITHUB_OUTPUT"
