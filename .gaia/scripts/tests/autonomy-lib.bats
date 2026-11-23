#!/usr/bin/env bats
#
# Suite for .gaia/scripts/autonomy-lib.sh: the autonomy switch reads as live
# only for an exact, enabled, unexpired file, in the maintainer tree and an
# adopter tree alike, from the main checkout and from a linked worktree.
#
# Run: .gaia/scripts/bats5.sh .gaia/scripts/tests/autonomy-lib.bats < /dev/null
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  # AUTONOMY_LIBRARY lets a mutation proof point the suite at a scratch copy.
  LIBRARY="${AUTONOMY_LIBRARY:-$REPO_ROOT/.gaia/scripts/autonomy-lib.sh}"
  FIX=$(cd "$(mktemp -d "$BATS_TEST_TMPDIR/fix.XXXXXX")" && pwd -P)
  MAIN="$FIX/main"
  WORKTREE="$FIX/wt"
  mkdir -p "$MAIN"
  git -C "$MAIN" init -q -b main
  git -C "$MAIN" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m init
  git -C "$MAIN" worktree add -q "$WORKTREE" -b feat
  mkdir -p "$MAIN/.gaia/local/protected" "$WORKTREE/.gaia"
  ln -s "$MAIN/.gaia/local" "$WORKTREE/.gaia/local"
  SWITCH="$MAIN/.gaia/local/protected/autonomy.json"
}

# live_switch [extra jq]: a valid switch expiring in an hour, with the extra
# jq applied to it.
live_switch() {
  jq -n "{enabled: true, expires_at: (now + 3600 | todate), may_merge: false, audit_extra_units_per_pr: 1, audit_units_pool: 3} ${1:-}" >"$SWITCH"
}

# reads_as <on|off> [directory]: assert autonomy_active's answer, and no
# output, for the directory (default: the main checkout), in a fresh shell.
reads_as() {
  run bash -c '. "$1" && autonomy_active "$2"' _ "$LIBRARY" "${2:-$MAIN}"
  case "$1" in
    on) [ "$status" -eq 0 ] ;;
    off) [ "$status" -eq 1 ] ;;
  esac || return 1
  [ -z "$output" ]
}

field() {
  run bash -c '. "$1" && autonomy_field "$2" "$3"' _ "$LIBRARY" "$1" "${2:-$MAIN}"
}

# bats test_tags=protected
@test "the maintainer tree and an adopter tree read a missing switch as off and a valid live one as on" {
  local tree
  for tree in adopter maintainer; do
    echo "case: $tree tree"
    if [ "$tree" = maintainer ]; then
      mkdir -p "$MAIN/.claude/rules/maintainers"
      printf 'marker\n' >"$MAIN/.claude/rules/maintainers/harness-triage-threshold.md"
    fi
    rm -f "$SWITCH"
    reads_as off || return 1
    live_switch
    reads_as on || return 1
    reads_as on "$WORKTREE" || return 1
  done
}

# bats test_tags=protected
@test "a malformed switch reads as off: unknown field, wrong type, missing field, or not the documented object" {
  local edit
  local edits=(
    '| .unknown = 1'
    '| .enabled = "true"'
    '| .may_merge = 1'
    '| .expires_at = 4102444800'
    '| .expires_at = "2099-01-01T00:00:00+09:00"'
    '| .expires_at = "2099-01-01T00:00:00.000Z"'
    '| .expires_at = "2099-02-30T00:00:00Z"'
    '| del(.enabled)'
    '| del(.expires_at)'
    '| del(.may_merge)'
    '| [.]'
  )
  for edit in "${edits[@]}"; do
    echo "case: $edit"
    live_switch "$edit"
    reads_as off || return 1
  done
  echo "case: not JSON"
  printf '{"enabled": true,' >"$SWITCH"
  reads_as off || return 1
  echo "case: two JSON values"
  live_switch
  cat "$SWITCH" "$SWITCH" >"$SWITCH.two"
  mv "$SWITCH.two" "$SWITCH"
  reads_as off || return 1
}

# bats test_tags=protected
@test "enabled false and an expired switch read as off, and expiry is read on every call" {
  live_switch '| .enabled = false'
  reads_as off || return 1
  live_switch '| .expires_at = (now - 1 | todate)'
  reads_as off || return 1
  live_switch
  run bash -c '. "$1"; autonomy_active "$2" || exit 3; jq "$3" "$4" >"$4.next" && mv "$4.next" "$4"; autonomy_active "$2" && exit 4; exit 0' \
    _ "$LIBRARY" "$MAIN" '.expires_at = (now - 1 | todate)' "$SWITCH"
  [ "$status" -eq 0 ]
}

@test "a symlinked switch, a missing jq and an unresolvable checkout read as off" {
  live_switch
  echo "case: switch is a symlink"
  mv "$SWITCH" "$FIX/elsewhere.json"
  ln -s "$FIX/elsewhere.json" "$SWITCH"
  reads_as off || return 1
  echo "case: protected folder is a symlink"
  rm "$SWITCH"
  mkdir -p "$FIX/folder"
  mv "$FIX/elsewhere.json" "$FIX/folder/autonomy.json"
  rmdir "$MAIN/.gaia/local/protected"
  ln -s "$FIX/folder" "$MAIN/.gaia/local/protected"
  reads_as off || return 1
  echo "case: jq missing"
  rm "$MAIN/.gaia/local/protected"
  mkdir -p "$MAIN/.gaia/local/protected"
  live_switch
  local farm="$FIX/bin"
  mkdir -p "$farm"
  ln -s "$(command -v git)" "$farm/git"
  ln -s "$(command -v cut)" "$farm/cut"
  run env PATH="$farm" "$BASH" -c '. "$1" && autonomy_active "$2"' _ "$LIBRARY" "$MAIN"
  [ "$status" -eq 1 ]
  echo "case: not a checkout"
  mkdir -p "$FIX/plain"
  reads_as off "$FIX/plain"
}

@test "autonomy_field prints each validated field of a live switch and nothing for an off one" {
  live_switch '| .may_merge = true'
  field enabled && [ "$output" = true ]
  field may_merge && [ "$output" = true ]
  field audit_extra_units_per_pr && [ "$output" = 1 ]
  field audit_units_pool "$WORKTREE" && [ "$output" = 3 ]
  field expires_at
  [ "$status" -eq 0 ]
  [ "$output" = "$(jq -r .expires_at "$SWITCH")" ]
  field unknown
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  live_switch '| .enabled = false'
  field may_merge
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "a missing, non-integer or negative budget field reads as 0 and leaves the switch live" {
  local edit
  local edits=(
    '| del(.audit_extra_units_per_pr, .audit_units_pool)'
    '| .audit_extra_units_per_pr = "2" | .audit_units_pool = 1.5'
    '| .audit_extra_units_per_pr = -1 | .audit_units_pool = null'
  )
  for edit in "${edits[@]}"; do
    echo "case: $edit"
    live_switch "$edit"
    reads_as on || return 1
    field audit_extra_units_per_pr && [ "$output" = 0 ] || return 1
    field audit_units_pool && [ "$output" = 0 ] || return 1
  done
}
