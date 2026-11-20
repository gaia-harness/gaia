#!/usr/bin/env bats
#
# Doc-conformance suite for the shared adversarial-audit lens-dispatch contract
# (.claude/skills/gaia/references/spec/lens-dispatch.md), read by the spec
# audit and the plan decomposition audit.
#
# THE PROBLEM. A dispatched lens that no-ops writes nothing, and a caller that
# never classifies the file reads the absence as "the lens found nothing". The
# contract prescribes one classify command; this suite EXECUTES that command
# (extracted from the file's own fenced block, not a retyped copy) against
# fixtures.
#
# Assertion style: .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  CONTRACT="$REPO_ROOT/.claude/skills/gaia/references/spec/lens-dispatch.md"
}

# Print the classify command from the file's fenced bash block, with the script
# path made absolute and the findings-file placeholder replaced by $2.
classify_command() {
  local file="$1" findings="$2" line
  line="$(grep -E '^[[:space:]]*bash \.gaia/scripts/audit-noop-detect\.sh ' "$file" | head -n 1)"
  [ -n "$line" ] || return 1
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line/bash .gaia\/scripts\//bash $REPO_ROOT/.gaia/scripts/}"
  printf '%s\n' "${line/<findings file>/$findings}"
}

# Run the extracted command against a fixture body ($2); "-" means no file.
# Prints the exit code.
classify_exit() {
  local file="$1" body="$2" fixture="$BATS_TEST_TMPDIR/fixture.json" cmd
  rm -f "$fixture"
  if [ "$body" != "-" ]; then printf '%s' "$body" >"$fixture"; fi
  cmd="$(classify_command "$file" "$fixture")" || { echo "no-command"; return 0; }
  local rc=0
  (cd "$REPO_ROOT" && bash -c "$cmd" >/dev/null 2>&1) || rc=$?
  echo "$rc"
}

@test "classify command exit codes on empty, missing and keyless findings" {
  local case_name body want got
  for case_name in "empty findings array:{\"dimension\":\"FG\",\"findings\":[]}:0" "missing file:-:1" "no findings key:{\"dimension\":\"FG\"}:1"; do
    want="${case_name##*:}"
    body="${case_name#*:}"
    body="${body%:*}"
    got="$(classify_exit "$CONTRACT" "$body")"
    [ "$got" = "$want" ] || { printf 'case %s: exit %s, want %s\n' "${case_name%%:*}" "$got" "$want" >&2; return 1; }
  done
}
