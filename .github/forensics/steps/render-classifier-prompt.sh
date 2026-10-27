#!/usr/bin/env bash
# The triage job's "Render classifier prompt" step. Reads PARSED_FILE from
# the step environment and ISSUE_NUMBER and FORENSICS_DIR from the job's;
# writes rendered_file and body to GITHUB_OUTPUT, which the classifier step
# passes to the model as its prompt. Runs before the model edits the tree.
set -eu

# shellcheck disable=SC2016 # awk programs are intentionally single-quoted
symptom="$(jq -r '.sections.symptom' "$PARSED_FILE")"
classification="$(jq -r '.sections.classification' "$PARSED_FILE")"
capture="$(jq -r '.sections.capture' "$PARSED_FILE")"
repro="$(jq -r '.sections.reproduction_context' "$PARSED_FILE")"

# Defense-in-depth: mask anything that looks like a leftover
# secret in the parsed body. Phase 1 should have redacted these
# already (the capture passes through verbatim), but the
# workflow never trusts upstream. `::add-mask::` is a no-op for
# the redaction tokens themselves and only masks any literal
# secret-shaped bytes the parser might have surfaced.
mask_secret_shapes() {
  printf '%s\n' "$1" | grep -oE 'sk-ant-[A-Za-z0-9_-]{20,}|gh[psuor]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}' | while IFS= read -r tok; do
    [ -n "$tok" ] && echo "::add-mask::$tok"
  done || true
}
mask_secret_shapes "$symptom"
mask_secret_shapes "$classification"
mask_secret_shapes "$capture"
mask_secret_shapes "$repro"

# The allowlist / denylist are markdown literals (backticks
# inside strings); shellcheck flags single-quoted strings that
# LOOK like command substitution. They're not, these are the
# canonical scope path lists rendered into the classifier
# prompt verbatim. Disable SC2016 for this block.
# shellcheck disable=SC2016
allowlist='- `.gaia/cli/` (except the `gaia` and `gaia-maintainer` bundles)
- `.claude/skills/`
- `.claude/commands/`
- `.claude/agents/`
- `.gaia/scripts/spec/`
- `.gaia/manifest.json`'

# shellcheck disable=SC2016
denylist='- `frontend/app/`, `wiki/`, `studio/`, `website/`
- `.notebook/`
- `.gaia/templates/spec/`
- `.claude/skills/gaia/references/spec/clarify-prompts.md`, `.claude/skills/gaia/references/spec/system-prompt.md`, `.claude/skills/gaia/references/spec/spec-template.md`
- `.github/workflows/`, `.github/forensics/`, `.github/`
- `.claude/hooks/`, `.gaia/statusline/`, `.githooks/`, `.claude/settings.json`, `.claude/settings.local.json` (they run on their own in a local session)
- any `package.json`, `pnpm-workspace.yaml`, `pnpm-lock.yaml`, `.npmrc`, `.pnpmfile.cjs` or `.pnpmfile.mjs`, at any depth'

rendered_file="${RUNNER_TEMP}/forensics/classifier-prompt.md"

# SEC-2: neutralize the untrusted issue sections before they are
# substituted into the prompt. `neutralize-untrusted.sh` collapses
# backtick runs (no fence breakout) and defangs any injected
# `GAIA-VERDICT:` / `GAIA-FIX-ABORT:` marker, so attacker text
# cannot masquerade as the model's own machine-readable output.
# Applied ONLY to the four untrusted sections; the allow/deny
# lists (legitimate backticks) and the template's own control
# markers are left intact.
symptom="$("$FORENSICS_DIR/neutralize-untrusted.sh" "$symptom")"
classification="$("$FORENSICS_DIR/neutralize-untrusted.sh" "$classification")"
capture="$("$FORENSICS_DIR/neutralize-untrusted.sh" "$capture")"
repro="$("$FORENSICS_DIR/neutralize-untrusted.sh" "$repro")"

# SEC-2: per-run random sentinel. Each untrusted section in the
# template is wrapped between a pair of identical sentinel marker
# lines the model is told are data, not instructions. The value is
# unknowable to an attacker before the run, so injected text cannot
# forge or close a marker.
SENTINEL="UNTRUSTED_$(openssl rand -hex 12)"

# Render via the standalone helper. Bash
# parameter-expansion-based substitution sidesteps both the
# multi-line `awk -v` rejection and the `gsub` `&`-replacement
# corruption that the previous inline awk shipped with.
"$FORENSICS_DIR/render-prompt.sh" "$FORENSICS_DIR/prompt.md" \
  "ISSUE_NUMBER=$ISSUE_NUMBER" \
  "SENTINEL=$SENTINEL" \
  "SYMPTOM=$symptom" \
  "CLASSIFICATION=$classification" \
  "CAPTURE=$capture" \
  "REPRO_CONTEXT=$repro" \
  "ALLOWLIST=$allowlist" \
  "DENYLIST=$denylist" \
  > "$rendered_file"

# Surface the rendered prompt as a step output via heredoc so
# the action invocation can consume it. The delimiter is a
# random hex string (the GitHub-recommended pattern) so it can
# never collide with content.
delim="EOF_$(openssl rand -hex 16)"
{
  echo "rendered_file=$rendered_file"
  echo "body<<$delim"
  cat "$rendered_file"
  echo "$delim"
} >> "$GITHUB_OUTPUT"
