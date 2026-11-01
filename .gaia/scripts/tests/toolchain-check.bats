#!/usr/bin/env bats
# Tests for .gaia/scripts/toolchain-check.sh and the floors file it reads.
#
# Every tool the check reads is a stub on an otherwise empty PATH, so each
# version and each absence is exact, and the script is proved to need nothing
# but bash. A machine with no jq has to be able to run it.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

bats_require_minimum_version 1.5.0

setup() {
  THIS_DIRECTORY="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  REPO_ROOT="$(cd "$THIS_DIRECTORY/../../.." && pwd)"
  CHECK="$REPO_ROOT/.gaia/scripts/toolchain-check.sh"
  FLOORS="$REPO_ROOT/.gaia/toolchain-floors.tsv"
  NOTE="$REPO_ROOT/.gaia/migrations/2.4.0.md"
  STUBS="$(mktemp -d -t toolchain-check-XXXXXX)"
  ABSOLUTE_BASH_PATH="$(command -v bash)"
}

teardown() {
  [ -n "${STUBS:-}" ] && [ -d "$STUBS" ] && rm -rf "$STUBS"
  return 0
}

# stub <tool> <line printed for --version>
stub() {
  printf '#!%s\nprintf "%%s\\n" "%s"\n' "$ABSOLUTE_BASH_PATH" "$2" >"$STUBS/$1"
  chmod +x "$STUBS/$1"
}

stub_current() {
  stub git 'git version 2.56.0'
  stub jq 'jq-1.7.1-apple'
  stub pnpm '12.11.2'
  stub lsof 'lsof 4.91'
  stub ss 'ss utility, iproute2-6.1.0'
}

check() {
  run env -i PATH="$STUBS" "$ABSOLUTE_BASH_PATH" "$CHECK" "$@"
}

floor_of() {
  awk -F '\t' -v tool="$1" '$1 == tool { print $2 }' "$FLOORS"
}

@test "at or above every floor: exit 0, no guidance" {
  stub_current
  check --platform darwin
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK git 2.56.0"* ]]
  [[ "$output" != *"GUIDE"* ]]
}

@test "exactly at the floor passes: the floor is a minimum, not a bound to beat" {
  stub_current
  stub git "git version $(floor_of git)"
  check --platform darwin
  [ "$status" -eq 0 ]
}

@test "a version is compared by number, so 2.100 is above 2.40" {
  stub_current
  stub git 'git version 2.100.1'
  check --platform darwin
  [ "$status" -eq 0 ]
}

@test "the vendor suffix on a version does not break the read" {
  stub_current
  stub git 'git version 2.50.1 (Apple Git-155)'
  check --platform darwin
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK git 2.50.1"* ]]
}

@test "git below the floor warns on update, names installed and floor, and says latest" {
  stub_current
  stub git 'git version 2.39.5'
  check --platform linux --os-id debian
  [ "$status" -eq 3 ]
  [[ "$output" == *"BELOW git 2.39.5 $(floor_of git) warn"* ]]
  [[ "$output" == *"Update to the latest git"* ]]
  [[ "$output" == *"apt stays behind"* ]]
  [[ "$output" == *"brew install git"* ]]
}

@test "pnpm below the floor blocks, and an absent jq blocks" {
  stub_current
  stub pnpm '11.2.0'
  rm "$STUBS/jq"
  check --platform darwin
  [ "$status" -eq 1 ]
  [[ "$output" == *"BELOW pnpm 11.2.0 $(floor_of pnpm) block"* ]]
  [[ "$output" == *"MISSING jq"* ]]
  [[ "$output" == *"npm install -g pnpm@latest"* ]]
}

@test "a platform tool is checked only on its platform" {
  stub_current
  rm "$STUBS/ss"
  check --platform darwin
  [ "$status" -eq 0 ]
  stub ss 'ss'
  rm "$STUBS/lsof"
  check --platform linux --os-id debian
  [ "$status" -eq 0 ]
  rm "$STUBS/ss"
  check --platform linux --os-id debian
  [ "$status" -eq 3 ]
  [[ "$output" == *"MISSING ss"* ]]
  [[ "$output" == *"iproute2"* ]]
  [[ "$output" == *"dev-smoke"* ]]
}

@test "--scope user leaves out what GAIA installs itself, so a fresh clone with no pnpm passes" {
  stub_current
  rm "$STUBS/pnpm"
  check --platform darwin --scope user
  [ "$status" -eq 0 ]
  [[ "$output" != *"pnpm"* ]]
}

@test "--tool reads one tool only" {
  stub_current
  stub git 'git version 2.10.0'
  check --platform darwin --tool pnpm
  [ "$status" -eq 0 ]
  [[ "$output" == "OK pnpm 12.11.2 $(floor_of pnpm)" ]]
}

@test "the floor is read from the file, so a target bundle's newer floor governs" {
  stub_current
  printf 'git\t3.0\tany\tuser\tblock\n' >"$STUBS/floors.tsv"
  check --platform darwin --floors "$STUBS/floors.tsv"
  [ "$status" -eq 1 ]
  [[ "$output" == *"BELOW git 2.56.0 3.0 block"* ]]
}

@test "an unreadable version is flagged, never passed" {
  stub_current
  stub jq 'not a version'
  check --platform darwin
  [ "$status" -eq 1 ]
  [[ "$output" == *"BELOW jq unknown"* ]]
}

@test "a missing floors file and an unknown argument are refusals" {
  check --floors "$STUBS/absent.tsv"
  [ "$status" -eq 2 ]
  check --nonsense
  [ "$status" -eq 2 ]
}

@test "every git route names a package source, on every platform family" {
  stub_current
  stub git 'git version 2.39.5'
  local family
  for family in 'darwin' 'windows' 'linux ubuntu' 'linux debian' 'linux fedora' 'linux rhel' 'linux arch' 'linux alpine' 'linux gentoo'; do
    set -- $family
    if [ "$#" -eq 2 ]; then check --platform "$1" --os-id "$2"; else check --platform "$1"; fi
    [[ "$output" == *"GUIDE git: "* ]]
    [[ "$output" == *"latest git"* ]]
  done
}

@test "no guidance pins a version: each route reaches latest, never the floor" {
  run grep -nE '(git|jq|pnpm)@?[ -]?[0-9]+\.[0-9]+' "$CHECK"
  [ "$status" -ne 0 ]
}

@test "the floors file has one row per tool, and the note states the same floors" {
  run awk -F '\t' '!/^#/ && NF != 5 { print }' "$FLOORS"
  [ -z "$output" ]
  grep -q "git $(floor_of git)" "$NOTE"
  grep -q "jq $(floor_of jq)" "$NOTE"
  grep -q "pnpm $(floor_of pnpm)" "$NOTE"
}

@test "the note is blocking, says latest, and leans on no after-merge step" {
  run sed -n 2p "$NOTE"
  [ "$output" = "mode: blocking" ]
  grep -q 'latest git' "$NOTE"
  grep -q 'apt stays behind' "$NOTE"
}

# bats test_tags=whole-tree
@test "a 2.3.x project crosses the 2.4.0 note, and it is blocking" {
  run --separate-stderr bash "$REPO_ROOT/.gaia/scripts/select-migration-notes.sh" "$REPO_ROOT" 2.3.1 2.4.0
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '2.4.0\tblocking\t%s/.gaia/migrations/2.4.0.md' "$REPO_ROOT")" ]
}

# bats test_tags=whole-tree
@test "a project at 2.4.0 selects no 2.4.0 note, so a re-run after the crossing is clean" {
  run --separate-stderr bash "$REPO_ROOT/.gaia/scripts/select-migration-notes.sh" "$REPO_ROOT" 2.4.0 2.4.0
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run --separate-stderr bash "$REPO_ROOT/.gaia/scripts/select-migration-notes.sh" "$REPO_ROOT" 2.4.0 2.99.0
  [ "$status" -eq 0 ]
  [ "${output#*2.4.0.md}" = "$output" ]
}

@test "the note owns its hop: on a pass it runs the ordinary walk through the version and manifest write" {
  grep -qF 'the walk the running skill runs when no `BLOCKING` line prints' "$NOTE"
  grep -qF '`.gaia/VERSION` and manifest write' "$NOTE"
}

# later_bundle <mode>: a target bundle above 2.4.0, carrying the shipped notes
# and the selector plus a 2.5.0 note in the given mode.
later_bundle() {
  LATER="$BATS_TEST_TMPDIR/later"
  mkdir -p "$LATER/.gaia/scripts/lib" "$LATER/.gaia/migrations"
  cp "$REPO_ROOT"/.gaia/migrations/*.md "$LATER/.gaia/migrations/"
  cp "$REPO_ROOT/.gaia/scripts/select-migration-notes.sh" "$LATER/.gaia/scripts/"
  cp "$REPO_ROOT/.gaia/scripts/lib/version-compare.awk" "$LATER/.gaia/scripts/lib/"
  printf -- '---\nmode: %s\n---\n\nbody\n' "$1" >"$LATER/.gaia/migrations/2.5.0.md"
}

@test "a run from below 2.4.0 to a later target reaches a later after-merge note only through the note's selection from 2.4.0" {
  later_bundle after-merge
  run --separate-stderr bash "$REPO_ROOT/.gaia/scripts/update-gaia-preflight.sh" select-notes --latest-dir "$LATER" --baseline 2.3.1 --latest 2.5.0
  [ "$status" -eq 0 ]
  [ "$output" = "BLOCKING 2.4.0 $LATER/.gaia/migrations/2.4.0.md" ]
  run --separate-stderr bash "$REPO_ROOT/.gaia/scripts/update-gaia-preflight.sh" select-notes --latest-dir "$LATER" --baseline 2.4.0 --latest 2.5.0
  [ "$status" -eq 0 ]
  [ "$output" = "AFTER_MERGE 2.5.0 $LATER/.gaia/migrations/2.5.0.md" ]
  grep -qF 'select-notes --latest-dir <bundle folder> --baseline 2.4.0 --latest <target>' "$NOTE"
  grep -qF 'Persist the `AFTER_MERGE` lines' "$NOTE"
}

@test "a later blocking note surfaces in that selection, and the note stops before any merge on it" {
  later_bundle blocking
  run --separate-stderr bash "$REPO_ROOT/.gaia/scripts/update-gaia-preflight.sh" select-notes --latest-dir "$LATER" --baseline 2.4.0 --latest 2.5.0
  [ "$status" -eq 0 ]
  [ "$output" = "BLOCKING 2.5.0 $LATER/.gaia/migrations/2.5.0.md" ]
  grep -qF 'A `BLOCKING` line from it: stop before any merge' "$NOTE"
}

# bats test_tags=whole-tree
@test "no shipped note above 2.4.0 is blocking: the 2.4.0 note's hop stops at one" {
  local note version highest offenders=""
  for note in "$REPO_ROOT"/.gaia/migrations/*.md; do
    version="${note##*/}"
    version="${version%.md}"
    highest="$(printf '%s\n%s\n' 2.4.0 "$version" | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1)"
    if [ "$version" != 2.4.0 ] && [ "$highest" = "$version" ] && [ "$(sed -n 2p "$note")" = "mode: blocking" ]; then
      offenders="$offenders $version"
    fi
  done
  if [ -n "$offenders" ]; then
    printf 'Blocking note(s) above 2.4.0:%s. Extend the hop in .gaia/migrations/2.4.0.md to run them, in the same PR, then update this test.\n' "$offenders"
    return 1
  fi
}

@test "the setup and init commands hold no literal floor" {
  run grep -nE 'pnpm 1[0-9]|git 2\.[0-9]+|jq 1\.[0-9]' \
    "$REPO_ROOT/.claude/commands/setup-gaia.md" \
    "$REPO_ROOT/.claude/commands/gaia-init.md" \
    "$REPO_ROOT/.claude/skills/gaia/references/toolchain.md"
  [ "$status" -ne 0 ]
}

@test "no jq filter binds a reserved word, which jq 1.6 refuses to parse" {
  run grep -rnE --include='*.sh' --exclude-dir=fixtures \
    '( as |def [a-z_]+\([^)]*)\$(end|if|then|else|elif|and|or|not|def|reduce|foreach|try|catch|label|import|include)\b' \
    "$REPO_ROOT/.gaia/scripts" "$REPO_ROOT/.claude/hooks"
  [ "$status" -ne 0 ]
}

@test "no jq object uses a reserved word as a shorthand key, which jq 1.6 refuses to parse" {
  run grep -rnE --include='*.sh' --exclude-dir=fixtures \
    '\{(end|if|then|else|elif|and|or|not|def|reduce|foreach|try|catch|label|import|include), ' \
    "$REPO_ROOT/.gaia/scripts" "$REPO_ROOT/.claude/hooks"
  [ "$status" -ne 0 ]
}
