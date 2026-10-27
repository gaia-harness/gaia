#!/usr/bin/env bats
# shellcheck disable=SC2317,SC2329
#
# Suite for .gaia/scripts/roster-prune-overbroad.sh, which /update-gaia runs
# after a roster member is added to remove the `unowned:` entries that member
# makes overbroad. Fixture repositories live in $BATS_TEST_TMPDIR; the checker
# and its libraries are copied from HEAD so a sibling edit in the working tree
# never changes what this suite tests against.
#
# Run under bash 5 (.claude/rules/bats-assertions.md):
#   .gaia/scripts/bats5.sh .gaia/scripts/tests/roster-prune-overbroad.bats < /dev/null

bats_require_minimum_version 1.5.0

setup() {
  THIS_DIRECTORY="$(cd "$BATS_TEST_DIRNAME" && pwd)"
  REPO_ROOT="$(cd "$THIS_DIRECTORY/../../.." && pwd)"
  SCRIPT="$REPO_ROOT/.gaia/scripts/roster-prune-overbroad.sh"
  TAB="$(printf '\t')"
}

# copy_from_head <relative path> <destination root>
copy_from_head() {
  mkdir -p "$2/$(dirname "$1")"
  git -C "$REPO_ROOT" show "HEAD:$1" >"$2/$1"
}

# make_fixture <dir> <tracked path>...: the roster arrives on stdin. Only the
# named files are tracked, so the scaffolding never enters the checker's universe.
make_fixture() {
  local fixture="$1" tracked member names
  shift
  rm -rf "$fixture"
  mkdir -p "$fixture/.gaia" "$fixture/.claude/agents"
  copy_from_head .gaia/scripts/verify-audit-roster.sh "$fixture"
  copy_from_head .gaia/scripts/verify-audit-roster-registration.sh "$fixture"
  copy_from_head .gaia/scripts/verify-audit-roster-dialect.sh "$fixture"
  copy_from_head .gaia/scripts/verify-audit-roster-keys.sh "$fixture"
  copy_from_head .gaia/scripts/verify-audit-roster-coverage.sh "$fixture"
  copy_from_head .gaia/scripts/write-audit-remits.sh "$fixture"
  copy_from_head .claude/hooks/lib/audit-scope.sh "$fixture"
  copy_from_head .claude/hooks/lib/audit-machinery.sh "$fixture"
  cat >"$fixture/.gaia/audit-ci.yml"
  names="$(awk '/^[[:space:]]*-[[:space:]]+name[[:space:]]*:/ {
    sub(/^[[:space:]]*-[[:space:]]+name[[:space:]]*:[[:space:]]*/, ""); print }' "$fixture/.gaia/audit-ci.yml")"
  # The library is code the checker sources and data it reads as text: keep the
  # code and swap only the heredoc list for the fixture's own agent files.
  awk -v names="${names//$'\n'/ }" '
    index($0, "AUDIT_MACHINERY_PATHS=") == 1 && !done {
      print
      count = split(names, member_list, " ")
      for (i = 1; i <= count; i++) if (member_list[i] != "") printf ".claude/agents/%s.md\n", member_list[i]
      skipping = 1
      next
    }
    skipping && $0 == "EOF" { skipping = 0; done = 1 }
    !skipping { print }
  ' "$fixture/.claude/hooks/lib/audit-machinery.sh" >"$fixture/machinery.tmp"
  mv "$fixture/machinery.tmp" "$fixture/.claude/hooks/lib/audit-machinery.sh"
  for member in $names; do
    printf -- '---\nname: %s\n---\n\n# %s\n\n## Remit and self-skip\n\nYou own things.\n' "$member" "$member" \
      >"$fixture/.claude/agents/$member.md"
  done
  bash "$fixture/.gaia/scripts/write-audit-remits.sh" --root "$fixture" --config "$fixture/.gaia/audit-ci.yml" >/dev/null
  git init -q "$fixture"
  for tracked in "$@"; do
    mkdir -p "$fixture/$(dirname "$tracked")"
    : >"$fixture/$tracked"
    git -C "$fixture" add -- "$tracked"
  done
}

# roster_with_unowned <unowned line>...: members default, mine, new.
roster_with_unowned() {
  cat <<'YAML'
# Roster header comment.
auditors:
  - name: code-audit-default
    default: true
    globs:
      - "src/**"
  # An adopter-added member.
  - name: code-audit-mine
    globs:
      - "infra/**"
  - name: code-audit-new
    globs:
      - "**/*.sh"

# Ownerless regions.
unowned:
YAML
  printf '%s\n' "$@"
}

run_prune() {
  run --separate-stderr bash "$SCRIPT" --root "$1" "${@:2}"
}

run_checker() {
  run bash "$1/.gaia/scripts/verify-audit-roster.sh" --root "$1"
}

@test "removes the overbroad entry for the named member and reports it" {
  local fixture="$BATS_TEST_TMPDIR/f1" expected
  roster_with_unowned '  # keep this comment' '  - "scripts/**"' '  - "docs/**"' |
    make_fixture "$fixture" scripts/deploy.sh docs/guide.md infra/main.tf src/a.ts
  expected="$(grep -vxF '  - "scripts/**"' "$fixture/.gaia/audit-ci.yml")"
  run_prune "$fixture" --member code-audit-new
  [ "$status" -eq 0 ]
  [ "$output" = "REMOVED${TAB}scripts/**${TAB}scripts/deploy.sh${TAB}code-audit-new" ]
  [ "$(cat "$fixture/.gaia/audit-ci.yml")" = "$expected" ]
  grep -qF '  - "docs/**"' "$fixture/.gaia/audit-ci.yml"
  grep -qF '# keep this comment' "$fixture/.gaia/audit-ci.yml"
  run_checker "$fixture"
  [ "$status" -eq 0 ]
}

@test "an entry made overbroad by a member that is not named stays" {
  local fixture="$BATS_TEST_TMPDIR/f2" before
  roster_with_unowned '  - "infra/**"' '  - "docs/**"' |
    make_fixture "$fixture" docs/guide.md infra/main.tf src/a.ts
  before="$(cat "$fixture/.gaia/audit-ci.yml")"
  run_prune "$fixture" --member code-audit-new
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(cat "$fixture/.gaia/audit-ci.yml")" = "$before" ]
}

@test "a roster with nothing overbroad is byte-identical and silent" {
  local fixture="$BATS_TEST_TMPDIR/f3" before
  roster_with_unowned '  - "docs/**"' |
    make_fixture "$fixture" docs/guide.md infra/main.tf src/a.ts
  before="$(cat "$fixture/.gaia/audit-ci.yml")"
  run_prune "$fixture" --member code-audit-new
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(cat "$fixture/.gaia/audit-ci.yml")" = "$before" ]
}

@test "a second run after a removal changes nothing" {
  local fixture="$BATS_TEST_TMPDIR/f3b" before
  roster_with_unowned '  - "scripts/**"' '  - "docs/**"' |
    make_fixture "$fixture" scripts/deploy.sh docs/guide.md src/a.ts
  run_prune "$fixture" --member code-audit-new
  before="$(cat "$fixture/.gaia/audit-ci.yml")"
  run_prune "$fixture" --member code-audit-new
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(cat "$fixture/.gaia/audit-ci.yml")" = "$before" ]
}

@test "double, single, bare and commented items are each removed, and the auditors block is never touched" {
  local fixture="$BATS_TEST_TMPDIR/f4"
  roster_with_unowned '  - "a/**"' "  - 'b/**'" '  - c/**' '  - "d/**"   # trailing note' '  - docs/**' |
    make_fixture "$fixture" a/x.sh b/x.sh c/x.sh d/x.sh docs/guide.md src/a.ts
  # The same glob text sits in the auditors block and must survive.
  awk '{ print } $0 == "      - \"**/*.sh\"" { print "      - \"a/**\"" }' "$fixture/.gaia/audit-ci.yml" >"$fixture/roster.tmp"
  mv "$fixture/roster.tmp" "$fixture/.gaia/audit-ci.yml"
  run_prune "$fixture" --member code-audit-new
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c '^REMOVED')" -eq 4 ]
  grep -qE "(^|[ \"'])(b|c|d)/\*\*|trailing note" "$fixture/.gaia/audit-ci.yml" && return 1
  [ "$(grep -c '"a/\*\*"' "$fixture/.gaia/audit-ci.yml")" -eq 1 ]
  awk '/^unowned:/ { exit } /"a\/\*\*"/ { found = 1 } END { exit !found }' "$fixture/.gaia/audit-ci.yml"
  grep -qF -- '- docs/**' "$fixture/.gaia/audit-ci.yml"
}

@test "a missing checker exits 1" {
  local fixture="$BATS_TEST_TMPDIR/f5"
  roster_with_unowned '  - "scripts/**"' |
    make_fixture "$fixture" scripts/deploy.sh src/a.ts
  rm "$fixture/.gaia/scripts/verify-audit-roster.sh"
  run_prune "$fixture" --member code-audit-new
  [ "$status" -eq 1 ]
}

@test "an unreadable roster exits 2, as does a usage error" {
  local fixture="$BATS_TEST_TMPDIR/f6"
  mkdir -p "$fixture/.gaia"
  run_prune "$fixture" --member code-audit-new
  [ "$status" -eq 2 ]
  run_prune "$fixture"
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" --member x
  [ "$status" -eq 2 ]
}

@test "the member filter can fail: a copy without it removes the unnamed member's entry" {
  local fixture="$BATS_TEST_TMPDIR/f7" copy="$BATS_TEST_TMPDIR/no-filter.sh"
  roster_with_unowned '  - "infra/**"' '  - "docs/**"' |
    make_fixture "$fixture" docs/guide.md infra/main.tf src/a.ts
  sed 's/^    is_named_member "\$owner" || continue$/    :/' "$SCRIPT" >"$copy"
  cmp -s "$copy" "$SCRIPT" && return 1
  run --separate-stderr bash "$copy" --root "$fixture" --member code-audit-new
  [ "$status" -eq 0 ]
  [[ "$output" == REMOVED* ]]
}

@test "an entry that also covered ownerless paths is removed with one stderr follow-up line" {
  local fixture="$BATS_TEST_TMPDIR/f8"
  roster_with_unowned '  - "scripts/**"' '  - "docs/**"' |
    make_fixture "$fixture" scripts/deploy.sh scripts/README.md docs/guide.md src/a.ts
  run_prune "$fixture" --member code-audit-new
  [ "$status" -eq 0 ]
  [ "$output" = "REMOVED${TAB}scripts/**${TAB}scripts/deploy.sh${TAB}code-audit-new" ]
  [ "$(printf '%s\n' "$stderr" | wc -l | tr -d ' ')" -eq 1 ]
  [[ "$stderr" == *"no member owns"* ]]
  ! grep -qF 'scripts/**' "$fixture/.gaia/audit-ci.yml"
}

@test "a finding in an unrecognized layout fails loudly and changes no file" {
  local fixture="$BATS_TEST_TMPDIR/f9" before
  roster_with_unowned '  - "scripts/**"' '  - "docs/**"' |
    make_fixture "$fixture" scripts/deploy.sh docs/guide.md src/a.ts
  cat >"$fixture/.gaia/scripts/verify-audit-roster.sh" <<'STUB'
#!/usr/bin/env bash
printf 'verify-audit-roster: FAIL overbroad-unowned-glob\n'
printf '  entry=scripts/** reaches scripts/deploy.sh owned by code-audit-new\n'
exit 1
STUB
  before="$(cat "$fixture/.gaia/audit-ci.yml")"
  run_prune "$fixture" --member code-audit-new
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [[ "$stderr" == *"not recognized"* ]]
  [[ "$stderr" == *"entry=scripts/** reaches"* ]]
  [ "$(cat "$fixture/.gaia/audit-ci.yml")" = "$before" ]
}

@test "the script stays within the line limit" {
  [ "$(wc -l <"$SCRIPT" | tr -d ' ')" -le 400 ]
}
