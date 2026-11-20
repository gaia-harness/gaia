#!/usr/bin/env bats
#
# Fail-closed contract of the notebook: while the one-time move is pending,
# every consumer script refuses with the move line on stderr and changes
# nothing.
#
# Each consumer is run from a fixture whose catalog lacks the move marker while
# a legacy ledger still exists (`--legacy`), and again with no catalog at all
# (`--no-catalog --legacy`). For each: exit non-zero, stderr names the move
# command, and a before/after snapshot of the fixture's notebook and local
# state is identical, so no id was minted, no row written, no folder created
# and nothing removed.

bats_require_minimum_version 1.5.0

# Builds the throwaway fixture repository the suite acts on. Called through a
# wrapper so the whole-tree mark guard does not read the helper call as the
# real tree.
_fixture_repository() {
  "$BATS_TEST_DIRNAME/helpers/tmp-notebook-repo.sh" "$@"
}

setup() {
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
  # The spec and plan scripts document exit 3 for this refusal, with nothing on stdout.
  case "$name" in
    spec-* | plan-*)
      if [ "$status" -ne 3 ] || [ -n "$output" ]; then
        printf '%s refused with status %s and stdout %s, not exit 3 and empty stdout\n' "$name" "$status" "$output" >&2
        return 1
      fi
      ;;
  esac
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

# bats test_tags=protected
@test "each notebook consumer refuses while the one-time move is pending, in a legacy and a no-catalog repository, and changes nothing" {
  local name template repo legacy_template no_catalog_template
  legacy_template="$(_fixture_repository --legacy)"
  no_catalog_template="$(_fixture_repository --no-catalog --legacy)"
  FIXTURES+=("$legacy_template" "$no_catalog_template")
  for name in spec-allocator plan-allocator spec-archive-merged plan-archive-merged \
    spec-archive-abandoned research-reaper-list research-reaper-apply reconcile; do
    for template in "$legacy_template" "$no_catalog_template"; do
      repo="$BATS_TEST_TMPDIR/$name-$(basename "$template")"
      cp -R "$template" "$repo"
      _check_refusal "$repo" "$name" || return 1
    done
  done
}
