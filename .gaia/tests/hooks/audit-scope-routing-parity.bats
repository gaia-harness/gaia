#!/usr/bin/env bats
# audit-scope-routing-parity.bats: the release-change skip, proved over every
# path of the frozen routing fixture.
#
# fixtures/audit-routing-before.tsv is `<path><TAB><owner|->`, one row per
# tracked file, generated once against an earlier classifier and roster and
# never regenerated. The tests below reuse its paths as a realistic, wide set of
# inputs; the live tree's ownerless-path coverage is verify-audit-roster.bats.
#
# Assertion style: .claude/rules/bats-assertions.md.

setup() {
  THIS_DIRECTORY="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIRECTORY/../../.." && pwd )"
  SCOPE_LIBRARY="$REPO_ROOT/.claude/hooks/lib/audit-scope.sh"
  FIXTURE="$THIS_DIRECTORY/fixtures/audit-routing-before.tsv"
}

# ---------------------------------------------------------------------------
# The release-change skip, over the same fixture paths. The live roster keys no
# member, so these cases key one claimant (the shell member) in a copy of it,
# and arm the context on a scratch repository that carries the live manifest at
# both ends.
# ---------------------------------------------------------------------------

# release_parity_setup <version-after>: writes the keyed and the
# member-removed roster copies and a repository whose branch moves .gaia/VERSION
# from 1.0.0 to <version-after>.
release_parity_setup() {
  local repository="$BATS_TEST_TMPDIR/release-parity"
  command -v jq >/dev/null 2>&1 || skip "jq required"
  KEYED_ROSTER="$BATS_TEST_TMPDIR/keyed.yml"
  REMOVED_ROSTER="$BATS_TEST_TMPDIR/removed.yml"
  # The live roster already keys the adopter shell member; the fixtures key
  # only the maintainer shell member, so the keys the live roster carries
  # come off first.
  local unkeyed="$BATS_TEST_TMPDIR/unkeyed.yml"
  grep -v '^    skip_gaia_release_changes: true$' "$REPO_ROOT/.gaia/audit-ci.yml" > "$unkeyed"
  awk '
    /^auditors:/ { in_auditors = 1 }
    in_auditors && /^[A-Za-z_]/ && !/^auditors:/ { if (pending) print "    skip_gaia_release_changes: true"; pending = 0; in_auditors = 0 }
    in_auditors && /^  - name:/ { if (pending) print "    skip_gaia_release_changes: true"; pending = ($0 ~ /code-audit-maintainer-shell$/) }
    { print }
  ' "$unkeyed" > "$KEYED_ROSTER"
  awk '
    /^auditors:/ { in_auditors = 1 }
    in_auditors && /^[A-Za-z_]/ && !/^auditors:/ { dropping = 0; in_auditors = 0 }
    in_auditors && /^  - name:/ { dropping = ($0 ~ /code-audit-maintainer-shell$/) }
    !dropping { print }
  ' "$unkeyed" > "$REMOVED_ROSTER"
  [ "$(grep -c '^    skip_gaia_release_changes: true$' "$KEYED_ROSTER")" -eq 1 ]
  grep -q 'name: code-audit-maintainer-shell$' "$REMOVED_ROSTER" && return 1
  mkdir -p "$repository/.gaia"
  git -C "$repository" init -q --initial-branch=main
  git -C "$repository" config user.email test@example.com
  git -C "$repository" config user.name Test
  git -C "$repository" config commit.gpgsign false
  cp "$REPO_ROOT/.gaia/manifest.json" "$repository/.gaia/manifest.json"
  printf '1.0.0\n' > "$repository/.gaia/VERSION"
  git -C "$repository" add -A
  git -C "$repository" commit -qm base
  git -C "$repository" checkout -q -b update
  printf '%s\n' "$1" > "$repository/.gaia/VERSION"
  git -C "$repository" commit -qam update --allow-empty
  RELEASE_PARITY_ROOT="$repository"
}

# release_parity_owners <config> [armed]: fixture paths' owners, one per line.
release_parity_owners() {
  bash -c '
    . "$1" || exit 9
    audit_scope_init "$2" "$3" || exit 9
    [ -z "$5" ] || audit_scope_release_context "$2" main
    [ -z "$5" ] || audit_scope_release_context_state >&2
    cut -f1 "$4" | audit_owners_for_paths | cut -f2
  ' _ "$SCOPE_LIBRARY" "$RELEASE_PARITY_ROOT" "$1" "$FIXTURE" "${2:-}"
}

@test "routing parity, release context armed: only owned rows of the keyed member move, each to its keyed-entry-removed owner" {
  release_parity_setup 1.1.0
  local live keyed removed owned fail=0 moved=0 path live_owner keyed_owner removed_owner expected
  live="$(release_parity_owners "$REPO_ROOT/.gaia/audit-ci.yml")"
  keyed="$(release_parity_owners "$KEYED_ROSTER" armed 2>"$BATS_TEST_TMPDIR/state")"
  removed="$(release_parity_owners "$REMOVED_ROSTER")"
  grep -q '^armed [1-9]' "$BATS_TEST_TMPDIR/state"
  owned=$'\n'"$(jq -r '.files | to_entries[] | select(.value == "owned") | .key' "$REPO_ROOT/.gaia/manifest.json")"$'\n'
  while IFS=$'\t' read -r path live_owner keyed_owner removed_owner; do
    expected="$live_owner"
    if [ "$live_owner" = code-audit-maintainer-shell ]; then
      case "$owned" in *$'\n'"$path"$'\n'*) expected="$removed_owner" ;; esac
    fi
    [ "$expected" = "$live_owner" ] || moved=$((moved + 1))
    if [ "$keyed_owner" != "$expected" ]; then
      echo "RELEASE ROUTING MISMATCH: $path live=$live_owner keyed=$keyed_owner expected=$expected" >&2
      fail=$((fail + 1))
    fi
  done < <(paste <(cut -f1 "$FIXTURE") <(printf '%s\n' "$live") <(printf '%s\n' "$keyed") <(printf '%s\n' "$removed"))
  [ "$moved" -gt 0 ]
  [ "$fail" -eq 0 ]
}

@test "routing parity, release context disarmed: a keyed roster routes every fixture row exactly as the live roster" {
  release_parity_setup 1.0.0
  local live keyed
  live="$(release_parity_owners "$REPO_ROOT/.gaia/audit-ci.yml")"
  keyed="$(release_parity_owners "$KEYED_ROSTER" armed 2>"$BATS_TEST_TMPDIR/state")"
  [ "$(cat "$BATS_TEST_TMPDIR/state")" = "disarmed no-version-change" ]
  [ -n "$live" ]
  [ "$keyed" = "$live" ]
}
