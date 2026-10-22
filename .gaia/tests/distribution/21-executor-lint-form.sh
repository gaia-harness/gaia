#!/usr/bin/env bash
# 21-executor-lint-form.sh
#
# Adopter-flow regression for the lint command a /gaia-plan task sub-agent runs
# over its own files, in a staged release tree:
#
#   1. The planner reference names that command; this scenario reads it from
#      the staged copy rather than restating it, so the doc and the check move
#      together.
#   2. Run as named, from the package, it reports a probe component that
#      restyles a registry Button with raw colors and a hard-coded label
#      (shadcn/no-restyle, shadcn/no-raw-colors, i18next/no-literal-string), and
#      passes the untouched language-select component.
#   3. The no-cd spelling it replaces, eslint from the repository root with
#      `--config frontend/eslint.config.mjs`, passes the same probe and
#      false-fails language-select on canonical/filename-match-exported. ESLint
#      resolves a flat config's `files` globs against the cwd, not the config's
#      directory, so the preset's `app/**` blocks never match `frontend/app/...`
#      from the root. When this step starts failing, ESLint resolves globs from
#      the config's directory and the planner's stated reason is false.
#
# Layer 0: needs host pnpm and network access for the install.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib/lib.sh"
source "$HERE/lib/data-layer.sh"

require_command pnpm "pnpm required for the executor lint scenario (Layer 0)"
require_command rsync "rsync required for adopter-flow scaffold copy"

SECONDS=0
stage_adopter_tree executor-lint
PLANNER_DOC="$SCAFFOLD/.claude/skills/gaia/references/plan/planner.md"

# --- 1. The command, sourced from the shipped planner reference -------------

# shellcheck disable=SC2016 # the backticks are the doc's literal code span
LINT_TEMPLATE="$(grep -oE '`pnpm -C <package dir> exec eslint <its own files>`' "$PLANNER_DOC" | head -n 1 | tr -d '`')" || true
[ -n "$LINT_TEMPLATE" ] \
  || { fail "planner.md names no \`pnpm -C <package dir> exec eslint <its own files>\` command for task sub-agents"; exit 1; }

log "pnpm install --frozen-lockfile"
run_logged "pnpm install --frozen-lockfile" "$WORK/install.log" pnpm -C "$SCAFFOLD" install --frozen-lockfile

PROBE_RELATIVE="app/components/lint-probe/index.tsx"
mkdir -p "$FRONTEND/app/components/lint-probe"
cat > "$FRONTEND/$PROBE_RELATIVE" <<'TSX'
import {Button} from '~/components/ui/button';

export const LintProbe = () => (
  <Button className="bg-red-500 p-8">Delete everything</Button>
);
TSX
CLEAN_RELATIVE="app/components/language-select/index.tsx"

# Runs the planner's command with its placeholders filled; prints eslint's
# output and returns its exit code.
planner_lint() {
  local command_line="${LINT_TEMPLATE//<package dir>/$SCAFFOLD/frontend}"
  command_line="${command_line//<its own files>/$1}"
  local -a words
  read -ra words <<< "$command_line"
  [ "${#words[@]}" -gt 0 ] || return 2
  ${words[@]+"${words[@]}"} 2>&1
}

root_lint() {
  (cd "$SCAFFOLD" && frontend/node_modules/.bin/eslint --config frontend/eslint.config.mjs "frontend/$1") 2>&1
}

# Exit 1 is lint findings; 2 is ESLint failing to run, which proves nothing.
expect_exit() {
  local label="$1" expected="$2" actual="$3" output_file="$4"
  if [ "$actual" -ne "$expected" ]; then
    log "$label output:"
    cat "$output_file" >&2
    fail "$label exited $actual, expected $expected"
    exit 1
  fi
}

expect_rules() {
  local label="$1" output_file="$2" rule
  shift 2
  for rule in "$@"; do
    grep -qF -- "$rule" "$output_file" \
      || { cat "$output_file" >&2; fail "$label did not report $rule"; exit 1; }
  done
}

# --- 2. The named form covers the package's file-scoped rules ---------------

status=0; planner_lint "$PROBE_RELATIVE" > "$WORK/planner-probe.txt" || status=$?
expect_exit "planner form on the probe" 1 "$status" "$WORK/planner-probe.txt"
expect_rules "planner form on the probe" "$WORK/planner-probe.txt" \
  shadcn/no-restyle shadcn/no-raw-colors i18next/no-literal-string

status=0; planner_lint "$CLEAN_RELATIVE" > "$WORK/planner-clean.txt" || status=$?
expect_exit "planner form on language-select" 0 "$status" "$WORK/planner-clean.txt"

# --- 3. The root --config form silently covers less --------------------------

status=0; root_lint "$PROBE_RELATIVE" > "$WORK/root-probe.txt" || status=$?
expect_exit "root --config form on the probe" 0 "$status" "$WORK/root-probe.txt"

status=0; root_lint "$CLEAN_RELATIVE" > "$WORK/root-clean.txt" || status=$?
expect_exit "root --config form on language-select" 1 "$status" "$WORK/root-clean.txt"
expect_rules "root --config form on language-select" "$WORK/root-clean.txt" \
  canonical/filename-match-exported

pass "planner lint form reports the probe and passes language-select; the root --config form misses the probe (${SECONDS}s)"
