#!/usr/bin/env bash
# The triage job's "Render apply-fix prompt" step. Reads PARSED_FILE and
# VERDICT_FILE from the step environment; writes body to GITHUB_OUTPUT, which
# the apply-fix step passes to the model as its prompt. The last script this
# job runs before the model edits the tree.
set -eu

symptom="$(jq -r '.sections.symptom' "$PARSED_FILE")"
capture="$(jq -r '.sections.capture' "$PARSED_FILE")"
repro="$(jq -r '.sections.reproduction_context' "$PARSED_FILE")"
reasoning="$(jq -r '.reasoning' "$VERDICT_FILE")"

# Each proposed path on its own line (the prompt fences the
# block; content is read-back-into-position via a single gsub).
paths_block="$(jq -r '.proposed_paths[]' "$VERDICT_FILE")"

# SEC-2: neutralize the untrusted issue sections (backtick runs +
# injected GAIA-FIX-ABORT/GAIA-VERDICT markers) before substitution.
symptom="$("$FORENSICS_DIR/neutralize-untrusted.sh" "$symptom")"
capture="$("$FORENSICS_DIR/neutralize-untrusted.sh" "$capture")"
repro="$("$FORENSICS_DIR/neutralize-untrusted.sh" "$repro")"

# SEC-2: per-run random sentinel wrapping each untrusted section.
SENTINEL="UNTRUSTED_$(openssl rand -hex 12)"

rendered_file="${RUNNER_TEMP}/forensics/apply-fix-prompt.md"

"$FORENSICS_DIR/render-prompt.sh" "$FORENSICS_DIR/apply-fix-prompt.md" \
  "ISSUE_NUMBER=$ISSUE_NUMBER" \
  "SENTINEL=$SENTINEL" \
  "PROPOSED_PATHS=$paths_block" \
  "CLASSIFIER_REASONING=$reasoning" \
  "SYMPTOM=$symptom" \
  "CAPTURE=$capture" \
  "REPRO_CONTEXT=$repro" \
  > "$rendered_file"

delim="EOF_$(openssl rand -hex 16)"
{
  echo "body<<$delim"
  cat "$rendered_file"
  echo "$delim"
} >> "$GITHUB_OUTPUT"
