#!/usr/bin/env bash
# The publish job's "Compose PR body" step. Reads the handoff folder under
# RUNNER_TEMP; writes file to GITHUB_OUTPUT for the step that opens the draft
# pull request. Runs from the publish job's checkout of main, never the fix.
set -eu
# `## Capture` is passed through verbatim. No
# re-redaction, no de-redaction, no normalization. The parsed
# JSON's `.sections.capture` field is the byte-for-byte content
# the body parser pulled from the issue (modulo the at-most-one
# leading/trailing blank line trim documented in
# parse-issue-body.sh).
handoff_dir="${RUNNER_TEMP}/forensics-handoff"
body_file="${RUNNER_TEMP}/pr-body.md"
# shellcheck disable=SC2016 # markdown literals contain backticks; jq filter is single-quoted
{
  printf 'Auto-fix attempt for issue #%s.\n\n' "$ISSUE_NUMBER"
  printf 'Closes #%s\n\n' "$ISSUE_NUMBER"
  printf -- '---\n\n'
  printf '## Capture (verbatim from issue)\n\n'
  jq -r '.sections.capture' "$handoff_dir/parsed.json"
  printf '\n\n---\n\n'
  printf '## Classifier reasoning\n\n'
  cat "$handoff_dir/reasoning.md"
  printf '\n\n---\n\n'
  printf '_Draft PR. Branch protection on `main` requires human review before merge._\n'
} > "$body_file"
echo "file=$body_file" >> "$GITHUB_OUTPUT"
