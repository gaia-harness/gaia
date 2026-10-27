#!/usr/bin/env bats
# Tests for .gaia/scripts/shellcheck-changed.sh and the shellcheck-scan
# workflow that runs it: the opt-in advisory shellcheck over the shell files a
# pull request changes, minus every file the manifest lists as owned.
#
# Every fixture shell file is written at test time into $BATS_TEST_TMPDIR and
# never committed: the maintainer shell lint runs shellcheck over every
# tracked `.sh`, so a committed fixture with a deliberate warning would fail it.
# The deliberate warning is SC2034 (unused variable), which `-S warning`
# reports.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  THIS_DIRECTORY="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIRECTORY/../../.." && pwd )"
  export SCRIPT="$REPO_ROOT/.gaia/scripts/shellcheck-changed.sh"
  WORKFLOW="$REPO_ROOT/.github/workflows/shellcheck-scan.yml"
  export FIXTURE_ROOT="$BATS_TEST_TMPDIR/project"
  mkdir -p "$FIXTURE_ROOT/.gaia/scripts" "$FIXTURE_ROOT/.claude/hooks" \
    "$FIXTURE_ROOT/scripts" "$FIXTURE_ROOT/tests"
  export MANIFEST="$BATS_TEST_TMPDIR/manifest.json"
  cat > "$MANIFEST" <<'JSON'
{"files": {
  ".gaia/scripts/gaia-owned.sh": "owned",
  ".claude/hooks/gaia-hook.sh": "owned",
  ".gaia/scripts/gaia-shared.sh": "shared"
}}
JSON
}

# write_warning <relative path>: a script carrying SC2034.
write_warning() {
  mkdir -p "$( dirname "$FIXTURE_ROOT/$1" )"
  printf '#!/usr/bin/env bash\nunused_variable=1\n' > "$FIXTURE_ROOT/$1"
}

write_clean() {
  mkdir -p "$( dirname "$FIXTURE_ROOT/$1" )"
  printf '#!/usr/bin/env bash\necho ok\n' > "$FIXTURE_ROOT/$1"
}

need_shellcheck() {
  command -v shellcheck >/dev/null 2>&1 || skip "shellcheck is not installed"
}

# run_script <changed path>...: paths go NUL-delimited on stdin, as the
# workflow pipes them. EXTRA_ARGS carries optional flags such as --select-only.
run_script() {
  run bash -c 'printf "%s\0" "$@" | bash "$SCRIPT" --root "$FIXTURE_ROOT" --manifest "$MANIFEST" $EXTRA_ARGS' _ "$@"
}

selection() {
  printf '%s' "$output" | tr '\0' '\n'
}

@test "select-only prints exactly the changed adopter script" {
  write_warning scripts/adopter.sh
  EXTRA_ARGS="--select-only" run_script scripts/adopter.sh
  [ "$status" -eq 0 ]
  [ "$( selection )" = "scripts/adopter.sh" ]
}

@test "a changed adopter script with a warning fails and names the code" {
  need_shellcheck
  write_warning scripts/adopter.sh
  EXTRA_ARGS="" run_script scripts/adopter.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *SC2034* ]]
}

@test "a changed owned script alone selects nothing and exits 0" {
  write_warning .gaia/scripts/gaia-owned.sh
  EXTRA_ARGS="--select-only" run_script .gaia/scripts/gaia-owned.sh
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  EXTRA_ARGS="" run_script .gaia/scripts/gaia-owned.sh
  [ "$status" -eq 0 ]
}

@test "an owned script plus a clean adopter script selects only the adopter script" {
  need_shellcheck
  write_warning .gaia/scripts/gaia-owned.sh
  write_clean scripts/clean.sh
  EXTRA_ARGS="--select-only" run_script .gaia/scripts/gaia-owned.sh scripts/clean.sh
  [ "$status" -eq 0 ]
  [ "$( selection )" = "scripts/clean.sh" ]
  EXTRA_ARGS="" run_script .gaia/scripts/gaia-owned.sh scripts/clean.sh
  [ "$status" -eq 0 ]
}

@test "an adopter hook absent from the manifest is linted and fails" {
  need_shellcheck
  write_warning .claude/hooks/my-guard.sh
  EXTRA_ARGS="" run_script .claude/hooks/my-guard.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *SC2034* ]]
}

@test "an unchanged script with a warning is ignored when only a README changed" {
  write_warning scripts/stale.sh
  printf '# readme\n' > "$FIXTURE_ROOT/README.md"
  EXTRA_ARGS="--select-only" run_script README.md
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  EXTRA_ARGS="" run_script README.md
  [ "$status" -eq 0 ]
}

@test "a path owned only in a second manifest is excluded" {
  write_warning scripts/base-owned.sh
  printf '{"files": {"scripts/base-owned.sh": "owned"}}\n' > "$BATS_TEST_TMPDIR/base.json"
  run bash -c 'printf "%s\0" scripts/base-owned.sh | bash "$SCRIPT" --root "$FIXTURE_ROOT" --manifest "$MANIFEST" --manifest "$BATS_TEST_TMPDIR/base.json" --select-only'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a path listed shared is selected" {
  write_warning .gaia/scripts/gaia-shared.sh
  EXTRA_ARGS="--select-only" run_script .gaia/scripts/gaia-shared.sh
  [ "$status" -eq 0 ]
  [ "$( selection )" = ".gaia/scripts/gaia-shared.sh" ]
}

@test "a changed bats file with a warning fails, linted as bash" {
  need_shellcheck
  printf '#!/usr/bin/env bats\nunused_variable=1\n@test "x" {\n  true\n}\n' > "$FIXTURE_ROOT/tests/x.bats"
  EXTRA_ARGS="" run_script tests/x.bats
  [ "$status" -ne 0 ]
  [[ "$output" == *SC2034* ]]
}

@test "a deleted changed path is skipped" {
  EXTRA_ARGS="--select-only" run_script scripts/gone.sh
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a path with a space is handled NUL-safe" {
  write_clean "scripts/with space.sh"
  EXTRA_ARGS="--select-only" run_script "scripts/with space.sh"
  [ "$status" -eq 0 ]
  [ "$( selection )" = "scripts/with space.sh" ]
}

@test "an unparseable manifest exits 2" {
  printf 'not json {' > "$BATS_TEST_TMPDIR/bad.json"
  write_clean scripts/clean.sh
  run bash -c 'printf "%s\0" scripts/clean.sh | bash "$SCRIPT" --root "$FIXTURE_ROOT" --manifest "$BATS_TEST_TMPDIR/bad.json"'
  [ "$status" -eq 2 ]
}

@test "an absent manifest file exits 2" {
  write_clean scripts/clean.sh
  run bash -c 'printf "%s\0" scripts/clean.sh | bash "$SCRIPT" --root "$FIXTURE_ROOT" --manifest "$BATS_TEST_TMPDIR/missing.json"'
  [ "$status" -eq 2 ]
}

@test "guard can fail: a copy without the manifest exclusion selects the owned file" {
  scratch="$BATS_TEST_TMPDIR/mutant.sh"
  # Make the owned-path comparison never match, which removes the exclusion.
  sed 's/\*"\$newline\$path\$newline"\*)/*"x$newline$path$newline"*)/' "$SCRIPT" > "$scratch"
  ! cmp -s "$SCRIPT" "$scratch"
  write_warning .gaia/scripts/gaia-owned.sh
  run bash -c 'printf "%s\0" .gaia/scripts/gaia-owned.sh | bash "$0" --root "$FIXTURE_ROOT" --manifest "$MANIFEST" --select-only' "$scratch"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
}

# Static checks over the shipped workflow.

workflow_job_condition() {
  awk '/^  shellcheck:/{in_job=1; next} in_job && /^    if:/{sub(/^    if: */, ""); print; exit}' "$1"
}

@test "workflow lint job is gated on the opt-in variable" {
  [ "$( workflow_job_condition "$WORKFLOW" )" = "vars.GAIA_SHELLCHECK == 'true'" ]
}

@test "guard can fail: the gate assertion reds on a copy without the condition" {
  scratch="$BATS_TEST_TMPDIR/no-if.yml"
  grep -v "^    if: vars.GAIA_SHELLCHECK" "$WORKFLOW" > "$scratch"
  [ "$( workflow_job_condition "$scratch" )" != "vars.GAIA_SHELLCHECK == 'true'" ]
}

@test "workflow triggers on pull_request only" {
  run grep -c 'pull_request_target' "$WORKFLOW"
  [ "$output" = "0" ]
  triggers="$( awk '/^on:/{f=1; next} f && /^[^ #]/{exit} f && /^  [a-z_]+:/{gsub(/[ :]/, ""); print}' "$WORKFLOW" )"
  [ "$triggers" = "pull_request" ]
}

@test "workflow names match the contract" {
  grep -qx 'name: Shellcheck Scan' "$WORKFLOW"
  grep -qx '  shellcheck:' "$WORKFLOW"
  grep -qx '    name: Shellcheck (changed adopter shell) (advisory)' "$WORKFLOW"
}

@test "every workflow uses: is a full SHA with a version comment" {
  count=0
  while IFS= read -r line; do
    count=$((count + 1))
    [[ "$line" =~ uses:\ [^@]+@[0-9a-f]{40}\ \#\ v[0-9] ]]
  done < <( grep -E '^\s*-?\s*uses:' "$WORKFLOW" )
  [ "$count" -ge 1 ]
}

@test "actionlint passes on the workflow" {
  command -v actionlint >/dev/null 2>&1 || skip "actionlint is not installed"
  run actionlint "$WORKFLOW"
  [ "$status" -eq 0 ]
}
