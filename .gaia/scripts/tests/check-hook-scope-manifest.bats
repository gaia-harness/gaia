#!/usr/bin/env bats
#
# Conformance suite for .gaia/scripts/check-hook-scope-manifest.sh -- Check D,
# INV-5: every .claude/hooks/**/*.sh reaches .gaia/local only through a
# resolved root.
#
# Two assertions, both in gaia_check_hook_scope_manifest: no hook holds a
# bare .gaia/local literal, and every hook outside .claude/hooks/lib/ that
# holds a live .gaia/local reference names a resolver-backed lib.
#
# Run under bash 5 (bash 3.2's `[[ ]]` skip-under-set-e gap is real; see
# .claude/rules/bats-assertions.md): `source .gaia/scripts/bats5.sh && bats5
# .gaia/scripts/tests/check-hook-scope-manifest.bats`.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  SCRIPT_DIRECTORY="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  CHECK="$SCRIPT_DIRECTORY/check-hook-scope-manifest.sh"
  REPO_ROOT="$(cd "$SCRIPT_DIRECTORY/../.." && pwd)"
  # shellcheck source=.gaia/scripts/check-hook-scope-manifest.sh
  source "$CHECK"
}

# make_fixture_repo <name>: an empty .claude/hooks tree under BATS_TEST_TMPDIR.
# Returns the repo path on stdout.
make_fixture_repo() {
  local repository_directory="$BATS_TEST_TMPDIR/$1"
  mkdir -p "$repository_directory/.claude/hooks/lib"
  printf '%s' "$repository_directory"
}

# add_hook <repo> <relpath> <body>: writes a hook script at
# .claude/hooks/<relpath> under <repo> with <body> as its content.
add_hook() {
  local repo="$1" relative_path="$2" body="$3"
  mkdir -p "$(dirname "$repo/.claude/hooks/$relative_path")"
  printf '%s\n' "$body" >"$repo/.claude/hooks/$relative_path"
}

# ========== real repo ==========

@test "real repo: sourcing the script defines the gate with no side effects" {
  run bash -c '
    # shellcheck disable=SC1090
    source "$1"
    type gaia_check_hook_scope_manifest >/dev/null
    echo OK
  ' _ "$CHECK"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

# bats test_tags=whole-tree
@test "real repo: every hook reaches .gaia/local only through a resolved root" {
  run gaia_check_hook_scope_manifest "$REPO_ROOT"
  [ "$status" -eq 0 ]
  local hook_count
  hook_count="$(find "$REPO_ROOT/.claude/hooks" -name '*.sh' | wc -l | tr -d ' ')"
  grep -qF "all $hook_count hooks reach .gaia/local only through a resolved root" <<<"$output" || return 1
}

# bats test_tags=whole-tree
@test "real repo: run directly with no argument, it resolves the repo and passes" {
  run bash -c 'cd "$1" && bash "$2"' _ "$REPO_ROOT" "$CHECK"
  [ "$status" -eq 0 ]
}

# ========== bare literal ==========

# A clean hook beside the bad one proves one bad hook fails the whole gate
# without the clean one being reported.
# bats test_tags=protected
@test "bare literal: a bare .gaia/local literal in a top-level hook fails" {
  local -a names=(top lib new-hook notebook notebook-lib)
  local -a paths=("foo.sh" "lib/foo.sh" "nested/new-hook.sh" "foo.sh" "lib/foo.sh")
  local -a line_suffixes=(":3" "" "" ":3" "")
  local -a bodies=(
    '#!/usr/bin/env bash
source .gaia/scripts/main-root-lib.sh
ledger=".gaia/local/plans/x.json"
cat "$ledger"'
    '#!/usr/bin/env bash
cat ".gaia/local/audit/sneaky.json"'
    '#!/usr/bin/env bash
: > ".gaia/local/cache/x"'
    '#!/usr/bin/env bash
source .gaia/scripts/main-root-lib.sh
ledger=".notebook/specs/x.json"
cat "$ledger"'
    '#!/usr/bin/env bash
cat ".notebook/research/sneaky.json"'
  )
  local index repo
  for index in 0 1 2 3 4; do
    repo="$(make_fixture_repo "bare-${names[$index]}")"
    add_hook "$repo" "good-hook.sh" '#!/usr/bin/env bash
source .gaia/scripts/main-root-lib.sh
root="$(gaia_resolve_main_root)"
cat "$root/.gaia/local/plans/x.json"'
    add_hook "$repo" "${paths[$index]}" "${bodies[$index]}"
    run gaia_check_hook_scope_manifest "$repo"
    [ "$status" -eq 1 ] || { echo "case ${names[$index]}: status $status"; return 1; }
    grep -qF "BARE LITERAL: .claude/hooks/${paths[$index]}" <<<"$output" || { echo "case ${names[$index]}: not reported as a bare literal"; return 1; }
    if [ -n "${line_suffixes[$index]}" ]; then
      grep -qF ".claude/hooks/${paths[$index]}${line_suffixes[$index]}" <<<"$output" || { echo "case ${names[$index]}: line not named"; return 1; }
    fi
    grep -qF "good-hook.sh" <<<"$output" && { echo "case ${names[$index]}: the clean hook was reported"; return 1; }
  done
  return 0
}

@test "a resolved root, a comment or an inherited root passes" {
  local -a names=(comment regex resolved inherited lib-param notebook-joined notebook-comment)
  local -a paths=("foo.sh" "foo.sh" "foo.sh" "foo.sh" "lib/foo.sh" "foo.sh" "foo.sh")
  local -a bodies=(
    '#!/usr/bin/env bash
# This guard never touches .gaia/local.
exit 0'
    '#!/usr/bin/env bash
source .gaia/scripts/main-root-lib.sh
name="$(printf "%s" "$1" | sed "s#.*/\.gaia/local/##")"'
    '#!/usr/bin/env bash
source .gaia/scripts/main-root-lib.sh
root="$(gaia_resolve_main_root)"
ledger="$root/.gaia/local/plans/x.json"
cat "$ledger"'
    '#!/usr/bin/env bash
. .gaia/scripts/state-registry-lib.sh
ledger="$(gaia_registry_path)"
echo "$ledger"'
    '#!/usr/bin/env bash
marker_path() {
  local root="$1" digest="$2"
  printf "%s\n" "${root}/.gaia/local/audit/${digest}.ok"
}'
    '#!/usr/bin/env bash
source .gaia/scripts/main-root-lib.sh
ledger="$main_root/.notebook/specs/x.json"
cat "$ledger"'
    '#!/usr/bin/env bash
# This guard never touches .notebook.
exit 0'
  )
  local index repo
  for index in 0 1 2 3 4 5 6; do
    repo="$(make_fixture_repo "pass-${names[$index]}")"
    add_hook "$repo" "${paths[$index]}" "${bodies[$index]}"
    run gaia_check_hook_scope_manifest "$repo"
    [ "$status" -eq 0 ] || { echo "case ${names[$index]}: status $status"; return 1; }
  done
}

# ========== resolver-backed ==========

@test "resolver: a hook joining a root with no resolver-backed lib fails" {
  local -a names=(hand-derived other-lib notebook)
  local -a bodies=(
    '#!/usr/bin/env bash
root="$(git rev-parse --show-toplevel)"
ledger="$root/.gaia/local/plans/x.json"
cat "$ledger"'
    '#!/usr/bin/env bash
. .gaia/scripts/branch-name-lib.sh
root="$(git rev-parse --show-toplevel)"
cat "$root/.gaia/local/plans/x.json"'
    '#!/usr/bin/env bash
root="$1"
cat "$root/.notebook/x.json"'
  )
  local index repo
  for index in 0 1 2; do
    repo="$(make_fixture_repo "resolver-${names[$index]}")"
    add_hook "$repo" "foo.sh" "${bodies[$index]}"
    run gaia_check_hook_scope_manifest "$repo"
    [ "$status" -eq 1 ] || { echo "case ${names[$index]}: status $status"; return 1; }
    grep -qF "NO RESOLVER: .claude/hooks/foo.sh" <<<"$output" || { echo "case ${names[$index]}: not reported as no resolver"; return 1; }
  done
}

# ========== whole gate ==========

@test "gate: a tree with no hooks fails rather than passing over nothing" {
  local repo; repo="$(make_fixture_repo gate-empty)"
  run gaia_check_hook_scope_manifest "$repo"
  [ "$status" -eq 1 ]
  grep -qF "no hooks found" <<<"$output" || return 1
}
