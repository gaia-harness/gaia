#!/usr/bin/env bats
# The ownership classifier's release-bookkeeping arm: on a change the
# release-bookkeeping predicate accepts, every changed path is ownerless and
# out-of-scope allowlisted, so the resolver dispatches nobody; anything else,
# and any tree without the predicate, routes as before.
#
# Fixtures come from .gaia/tests/helpers/release-bookkeeping-fixture.sh. Every
# case builds its repository in $BATS_TEST_TMPDIR.
#
# Run under bash 5 (.claude/rules/bats-assertions.md):
#   bash .gaia/scripts/bats5.sh .gaia/tests/hooks/audit-scope-release-bookkeeping.bats
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  LIBRARY_DIRECTORY="$REPO_ROOT/.claude/hooks/lib"
  RESOLVER="$REPO_ROOT/.gaia/scripts/resolve-audit-members.sh"
  . "$REPO_ROOT/.gaia/tests/helpers/release-bookkeeping-fixture.sh"
  command -v jq >/dev/null 2>&1 || skip "jq required"
  FIXTURE="$BATS_TEST_TMPDIR/fixture"
  mkdir -p "$FIXTURE/.gaia"
  git -C "$FIXTURE" init -q --initial-branch=main
  git -C "$FIXTURE" config user.email test@example.com
  git -C "$FIXTURE" config user.name Test
  git -C "$FIXTURE" config commit.gpgsign false
  printf '%s\n' 'auditors:' '  - name: fixture-default' '    globs:' '      - "**"' '    default: true' \
    > "$FIXTURE/.gaia/audit-ci.yml"
  git -C "$FIXTURE" add .gaia/audit-ci.yml
  git -C "$FIXTURE" commit -q -m roster
  release_bookkeeping_seed_base "$FIXTURE"
  git -C "$FIXTURE" checkout -q -b release main
}

# classify_with <library-directory> <path>...: "<path>\t<owner>\t<allowlisted>"
# lines, the context armed against main the way every consumer arms it.
classify_with() {
  bash -c '
    library="$1" root="$2"; shift 2
    . "$library/audit-scope.sh" || exit 9
    audit_scope_init "$root" || exit 9
    audit_scope_release_context "$root" main
    for path in "$@"; do
      allowlisted=no
      ! audit_out_of_scope_allowlisted "$path" || allowlisted=yes
      printf "%s\t%s\t%s\n" "$path" "$(audit_owner_for_path "$path")" "$allowlisted"
    done
  ' _ "$1" "$FIXTURE" "${@:2}"
}

classify() {
  classify_with "$LIBRARY_DIRECTORY" "$@"
}

# track_predicate_on_main: commits the installed predicate onto the base so the
# release branch inherits it unchanged, then returns to the release branch.
track_predicate_on_main() {
  git -C "$FIXTURE" checkout -q main
  git -C "$FIXTURE" add .gaia/scripts/release-bookkeeping-check.sh
  git -C "$FIXTURE" commit -q -m "track predicate"
  git -C "$FIXTURE" checkout -q release
  git -C "$FIXTURE" rebase -q main
}

resolve_members() {
  "$RESOLVER" --root "$FIXTURE" --base "$(git -C "$FIXTURE" merge-base main HEAD)"
}

lines_of() {
  printf '%s\n' "$@"
}

@test "a bookkeeping release: every changed path is ownerless and allowlisted, and the resolver dispatches nobody" {
  release_bookkeeping_install_predicate "$FIXTURE"
  release_bookkeeping_apply "$FIXTURE"
  run classify package.json apps/web/package.json CHANGELOG.md .gaia/VERSION .gaia/manifest.json
  [ "$status" -eq 0 ]
  [ "$output" = "$(lines_of $'package.json\t\tyes' $'apps/web/package.json\t\tyes' $'CHANGELOG.md\t\tyes' \
    $'.gaia/VERSION\t\tyes' $'.gaia/manifest.json\t\tyes')" ]
  # A path the release did not change keeps its owner on the same armed branch.
  [ "$(classify a.sh)" = $'a.sh\tfixture-default\tno' ]
  run resolve_members
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# bats test_tags=protected
@test "the arm stays off unless the predicate accepts: a release that also changes source, and a tree without the predicate" {
  local row
  for row in source-change-refused no-predicate-adopter-clone; do
    echo "case: $row"
    git -C "$FIXTURE" reset -q --hard main
    rm -f "$FIXTURE/.gaia/scripts/release-bookkeeping-check.sh"
    case "$row" in
      source-change-refused)
        release_bookkeeping_install_predicate "$FIXTURE"
        release_bookkeeping_apply "$FIXTURE" extra
        [ "$(classify package.json a.sh)" = "$(lines_of $'package.json\tfixture-default\tno' $'a.sh\tfixture-default\tno')" ]
        ;;
      no-predicate-adopter-clone)
        release_bookkeeping_apply "$FIXTURE"
        [ ! -e "$FIXTURE/.gaia/scripts/release-bookkeeping-check.sh" ]
        [ "$(classify package.json)" = $'package.json\tfixture-default\tno' ]
        ;;
    esac
    run resolve_members
    [ "$status" -eq 0 ]
    [ "$output" = fixture-default ]
  done
}

@test "the predicate runs only on a change that moves .gaia/VERSION" {
  local calls="$BATS_TEST_TMPDIR/predicate-calls"
  mkdir -p "$FIXTURE/.gaia/scripts"
  printf '#!/usr/bin/env bash\nprintf "called\\n" >> %q\nexit 1\n' "$calls" \
    > "$FIXTURE/.gaia/scripts/release-bookkeeping-check.sh"
  printf 'echo changed\n' > "$FIXTURE/a.sh"
  git -C "$FIXTURE" commit -qam "source only"
  classify a.sh >/dev/null
  [ ! -e "$calls" ]
  printf '1.1.0\n' > "$FIXTURE/.gaia/VERSION"
  git -C "$FIXTURE" commit -qam "bump"
  classify a.sh >/dev/null
  [ "$(cat "$calls")" = called ]
}

@test "a branch that loosens the predicate itself leaves every path in scope and the resolver names its member" {
  release_bookkeeping_install_predicate "$FIXTURE"
  track_predicate_on_main
  printf '#!/usr/bin/env bash\nexit 0\n' > "$FIXTURE/.gaia/scripts/release-bookkeeping-check.sh"
  git -C "$FIXTURE" commit -qam "loosen predicate"
  release_bookkeeping_apply "$FIXTURE" extra
  [ "$(classify a.sh)" = $'a.sh\tfixture-default\tno' ]
  run resolve_members
  [ "$status" -eq 0 ]
  [ "$output" = fixture-default ]
}

@test "an accepting predicate allowlists only the fixed bookkeeping set, never another changed path" {
  mkdir -p "$FIXTURE/.gaia/scripts"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$FIXTURE/.gaia/scripts/release-bookkeeping-check.sh"
  track_predicate_on_main
  release_bookkeeping_apply "$FIXTURE" extra
  run classify package.json a.sh
  [ "$status" -eq 0 ]
  [ "$output" = "$(lines_of $'package.json\t\tyes' $'a.sh\tfixture-default\tno')" ]
}
