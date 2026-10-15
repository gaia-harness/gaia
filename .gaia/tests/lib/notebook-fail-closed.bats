#!/usr/bin/env bats
#
# Fail-closed contract of the notebook: while the one-time move is pending,
# every consumer script refuses with the move line on stderr and changes
# nothing, and the pre-flight sweep that fronts the skills blocks on the same
# readiness check before it runs anything else.
#
# SCRIPT HALF. Each consumer is run from a fixture whose catalog lacks the move
# marker while a legacy ledger still exists (`--legacy`), and again with no
# catalog at all (`--no-catalog --legacy`). For each: exit non-zero, stderr
# names the move command, and a before/after snapshot of the fixture's
# notebook and local state is identical, so no id was minted, no row written,
# no folder created and nothing removed. The snapshot is the path list plus a
# sha256 of every regular file.
#
# PROSE HALF. lifecycle.md's `## Pre-flight sweep` names the readiness check
# before any other command and states that a non-zero exit stops the command,
# and the two callers (/gaia-spec step 2, /gaia-plan step 0) route through that
# section.
#
# Each half has a red twin (.claude/rules/guards-must-fail.md): the script half
# redefines the readiness function in a fixture copy of the library so the
# script's own call passes, which makes the refusal case fail; the prose half
# moves the readiness check below the reconcile in a temp copy, or drops a
# caller's route.

bats_require_minimum_version 1.5.0

# Builds the throwaway fixture repository the suite acts on. Called through a
# wrapper so the whole-tree mark guard does not read the helper call as the
# real tree.
_fixture_repository() {
  "$BATS_TEST_DIRNAME/helpers/tmp-notebook-repo.sh" "$@"
}

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  LIFECYCLE_MD="$REPO_ROOT/.claude/skills/gaia/references/spec/lifecycle.md"
  SPEC_MD="$REPO_ROOT/.claude/skills/gaia/references/spec.md"
  PLAN_MD="$REPO_ROOT/.claude/skills/gaia/references/plan.md"
  FIXTURES=()
}

teardown() {
  local fixture
  for fixture in ${FIXTURES[@]+"${FIXTURES[@]}"}; do
    rm -rf "$fixture"
  done
}

_sha256_lines() {
  if command -v sha256sum >/dev/null 2>&1; then
    xargs -0 sha256sum
  else
    xargs -0 shasum -a 256
  fi
}

# The path list and a sha256 of every regular file under the fixture's
# notebook and local state, sorted. An absent root contributes nothing, so a
# refusal that creates one shows up as new lines.
_snapshot() {
  local repo="$1" root
  for root in "$repo/.notebook" "$repo/.gaia/local"; do
    [ -e "$root" ] || continue
    find "$root" -print
    find "$root" -type f -print0 | _sha256_lines
  done | LC_ALL=C sort
}

# Run the named consumer from inside the fixture. Sets COMMAND for the case.
_consumer_command() {
  local repo="$1" name="$2"
  case "$name" in
    spec-allocator) COMMAND=(bash .gaia/scripts/spec/spec-allocator.sh next "$repo" "a subject") ;;
    plan-allocator) COMMAND=(bash .gaia/scripts/spec/plan-allocator.sh next "$repo" "a subject") ;;
    spec-archive-merged) COMMAND=(bash .gaia/scripts/spec/spec-archive-merged.sh "$repo") ;;
    plan-archive-merged) COMMAND=(bash .gaia/scripts/spec/plan-archive-merged.sh "$repo") ;;
    spec-archive-abandoned) COMMAND=(bash .gaia/scripts/spec/spec-archive-abandoned.sh "$repo") ;;
    research-reaper-list) COMMAND=(bash .gaia/scripts/notebook/research-reaper.sh list) ;;
    research-reaper-apply) COMMAND=(bash .gaia/scripts/notebook/research-reaper.sh apply --reap x) ;;
    reconcile) COMMAND=(bash .gaia/scripts/notebook/reconcile.sh "$repo") ;;
    *) printf 'unknown consumer case: %s\n' "$name" >&2; return 1 ;;
  esac
}

# One refusal check: exit non-zero, the move line on stderr, nothing changed.
# Returns 1 with a reason on the first violation.
_check_refusal() {
  local repo="$1" name="$2" before after
  _consumer_command "$repo" "$name" || return 1
  before="$(_snapshot "$repo")"
  [ -n "$before" ] || { printf 'the fixture snapshot is empty\n' >&2; return 1; }

  run --separate-stderr env GAIA_SPEC_FORCE_OFFLINE=1 GAIA_NOTEBOOK_TREE="$repo" \
    bash -c 'cd "$1" && shift && exec "$@"' _ "$repo" "${COMMAND[@]}"

  if [ "$status" -eq 0 ]; then
    printf '%s exited 0 although the one-time move is pending (stdout: %s)\n' "$name" "$output" >&2
    return 1
  fi
  if ! printf '%s\n' "$stderr" | grep -qF 'bash .gaia/scripts/notebook/move.sh run'; then
    printf '%s refused (status %s) without the move line on stderr: %s\n' "$name" "$status" "$stderr" >&2
    return 1
  fi
  after="$(_snapshot "$repo")"
  if [ "$before" != "$after" ]; then
    printf '%s changed the fixture while refusing:\n' "$name" >&2
    diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") >&2 || true
    return 1
  fi
  true
}

_check_refusal_in_both_shapes() {
  local name="$1" repo
  FIXTURES+=("$(_fixture_repository --legacy)")
  repo="${FIXTURES[${#FIXTURES[@]} - 1]}"
  _check_refusal "$repo" "$name" || return 1

  FIXTURES+=("$(_fixture_repository --no-catalog --legacy)")
  repo="${FIXTURES[${#FIXTURES[@]} - 1]}"
  _check_refusal "$repo" "$name"
}

@test "spec-allocator.sh next refuses while the move is pending and changes nothing" {
  _check_refusal_in_both_shapes spec-allocator
}

@test "plan-allocator.sh next refuses while the move is pending and changes nothing" {
  _check_refusal_in_both_shapes plan-allocator
}

@test "spec-archive-merged.sh refuses while the move is pending and changes nothing" {
  _check_refusal_in_both_shapes spec-archive-merged
}

@test "plan-archive-merged.sh refuses while the move is pending and changes nothing" {
  _check_refusal_in_both_shapes plan-archive-merged
}

@test "spec-archive-abandoned.sh refuses while the move is pending and changes nothing" {
  _check_refusal_in_both_shapes spec-archive-abandoned
}

@test "research-reaper.sh list refuses while the move is pending and changes nothing" {
  _check_refusal_in_both_shapes research-reaper-list
}

@test "research-reaper.sh apply refuses while the move is pending and changes nothing" {
  _check_refusal_in_both_shapes research-reaper-apply
}

@test "notebook/reconcile.sh refuses while the move is pending and changes nothing" {
  _check_refusal_in_both_shapes reconcile
}

@test "red twin script half: a script whose readiness check is bypassed fails the refusal check" {
  local name repo reason
  for name in spec-allocator plan-allocator spec-archive-merged plan-archive-merged \
    spec-archive-abandoned research-reaper-list research-reaper-apply reconcile; do
    FIXTURES+=("$(_fixture_repository --legacy)")
    repo="${FIXTURES[${#FIXTURES[@]} - 1]}"
    # The library's own readiness function now passes, so the script proceeds as
    # on a ready machine: sourced functions do not re-check readiness.
    printf '\ngaia_notebook_require_ready() { return 0; }\n' >> "$repo/.gaia/scripts/notebook/notebook-lib.sh"
    reason="$(_check_refusal "$repo" "$name" 2>&1 >/dev/null)" && {
      printf 'the refusal check still passed for %s with its readiness check bypassed\n' "$name" >&2
      return 1
    }
    # A failing check names why, so the twin cannot pass on an unrelated crash.
    [ -n "$reason" ] || { printf 'the refusal check failed for %s without a reason\n' "$name" >&2; return 1; }
    printf '# bypassed %s: %s\n' "$name" "$(printf '%s' "$reason" | head -1)" >&3
  done
  true
}

# --- prose half --------------------------------------------------------------

# The `## Pre-flight sweep` section of a lifecycle.md, to the end of the file.
sweep_section() {
  local start_line
  start_line="$(grep -n -F -- '## Pre-flight sweep' "$1" | head -1 | cut -d: -f1)"
  [ -n "$start_line" ] || { printf 'no "## Pre-flight sweep" section in %s\n' "$1" >&2; return 1; }
  sed -n "${start_line},\$p" "$1"
}

check_sweep_blocks_on_readiness() {
  local section first_command
  section="$(sweep_section "$1")" || return 1
  # The first shell command of the section, in document order, is the check.
  first_command="$(printf '%s\n' "$section" | grep -m1 -E '^bash \.gaia/scripts/')"
  if [ "$first_command" != 'bash .gaia/scripts/notebook/notebook-lib.sh require-ready' ]; then
    printf 'the first command of the pre-flight sweep is not the readiness check: %s\n' "$first_command" >&2
    return 1
  fi
  if ! printf '%s\n' "$section" | grep -qF 'A non-zero exit stops the command'; then
    printf 'the pre-flight sweep does not state that a non-zero readiness exit stops the command\n' >&2
    return 1
  fi
  true
}

@test "the pre-flight sweep names the readiness check before any other command and a non-zero exit stops the command" {
  check_sweep_blocks_on_readiness "$LIFECYCLE_MD"
}

@test "red twin prose half: the readiness check moved below the reconcile fails the order check" {
  local mutated="$BATS_TEST_TMPDIR/lifecycle-reordered.md"
  awk '
    /^bash \.gaia\/scripts\/notebook\/notebook-lib\.sh require-ready$/ { held = 1; next }
    { print }
    /^bash \.gaia\/scripts\/spec\/plan-reconcile\.sh "\$PWD"/ && held { print "bash .gaia/scripts/notebook/notebook-lib.sh require-ready"; held = 0 }
  ' "$LIFECYCLE_MD" > "$mutated"
  if cmp -s "$LIFECYCLE_MD" "$mutated"; then
    printf 'the reorder was not applied\n' >&2
    return 1
  fi
  check_sweep_blocks_on_readiness "$mutated" && return 1
  true
}

# Whether the text of <file> between two anchors routes through the sweep.
check_caller_routes_through_sweep() {
  local file="$1" start_anchor="$2" end_anchor="$3" start_line end_line
  start_line="$(grep -n -F -- "$start_anchor" "$file" | head -1 | cut -d: -f1)"
  end_line="$(grep -n -F -- "$end_anchor" "$file" | head -1 | cut -d: -f1)"
  [ -n "$start_line" ] && [ -n "$end_line" ] || { printf 'anchors not found in %s\n' "$file" >&2; return 1; }
  sed -n "${start_line},$((end_line - 1))p" "$file" | grep -qF 'spec/lifecycle.md` and run its `## Pre-flight sweep`'
}

@test "spec.md step 2 and plan.md step 0 both route through the pre-flight sweep" {
  check_caller_routes_through_sweep "$SPEC_MD" '### 2. Resume-vs-start-new prompt' '### 3. Initial draft'
  check_caller_routes_through_sweep "$PLAN_MD" '### 0. Pre-flight sweep' '### 1. Get description'
}

@test "red twin prose half: a caller that drops the route to the sweep fails the routing check" {
  local mutated="$BATS_TEST_TMPDIR/plan-no-route.md"
  sed 's|run its `## Pre-flight sweep`|run its checks|' "$PLAN_MD" > "$mutated"
  if cmp -s "$PLAN_MD" "$mutated"; then
    printf 'the route was not dropped\n' >&2
    return 1
  fi
  check_caller_routes_through_sweep "$mutated" '### 0. Pre-flight sweep' '### 1. Get description' && return 1
  true
}
