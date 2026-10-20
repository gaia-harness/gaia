#!/usr/bin/env bats
# setup-ping.sh: /setup-gaia's closing adoption ping. Decides whether the run
# owes a setup event and sends it. Runs against a fixture project with a stub
# `.gaia/cli/gaia` that logs each ping's arguments.
#
# The ping snippet in the setup reference runs through Claude's Bash tool, which
# is zsh on macOS: zsh does not word-split an unquoted parameter expansion, so
# a `for id in $OWED_AT_START` loop there runs once over the whole list. The
# snippet tests below run the reference's own fenced block under those
# semantics (real zsh when present, and bash with an empty IFS everywhere).
#
# Assertion style per .claude/rules/bats-assertions.md.
#
# Maintainer-only. `.gaia/tests` is wholesale release-excluded.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
  SCRIPT="$REPO_ROOT/.gaia/scripts/setup-ping.sh"
  REFERENCE="$REPO_ROOT/.claude/skills/gaia/references/setup/land-decisions.md"
  PROJECT="$BATS_TEST_TMPDIR/project"
  PING_LOG="$BATS_TEST_TMPDIR/ping.log"
  rm -rf "$PROJECT" "$PING_LOG"
  mkdir -p "$PROJECT/.gaia/cli" "$PROJECT/.gaia/scripts"
  cp "$SCRIPT" "$PROJECT/.gaia/scripts/setup-ping.sh"
  cat > "$PROJECT/.gaia/cli/gaia" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  'setup drift')
    [ -z "$DRIFT_FAILS" ] || exit 1
    printf '%s\n' "$DRIFT_JSON"
    ;;
  'sandbox status')
    printf '{"outcome":"%s"}\n' "${SANDBOX_OUTCOME:-declined}"
    ;;
  ping*)
    shift
    printf '%s\n' "$*" >> "$PING_LOG"
    ;;
  *) exit 2 ;;
esac
STUB
  chmod +x "$PROJECT/.gaia/cli/gaia"
  export PING_LOG
}

# A drift answer whose `decided` map holds the given ids.
decided_json() {
  local id map=''
  for id in "$@"; do map="$map${map:+,}\"$id\":{}"; done
  printf '{"decided":{%s},"undecided":[]}' "$map"
}

# Runs the script from the fixture project. Leading NAME=value pairs go into its
# environment; the rest are its arguments.
run_ping() {
  local env_pairs=()
  while [ "$#" -gt 0 ] && [ "${1#*=}" != "$1" ] && [ "${1#--}" = "$1" ]; do
    env_pairs+=("$1"); shift
  done
  # shellcheck disable=SC2016  # the inner script expands its own positional arguments
  run env "${env_pairs[@]}" bash -c 'cd "$1" || exit 99; shift; exec bash .gaia/scripts/setup-ping.sh "$@"' _ "$PROJECT" "$@"
}

# The fenced bash block under the reference's `## The setup ping` heading.
reference_snippet() {
  awk '
    /^## / { in_section = ($0 == "## The setup ping") }
    in_section && /^```bash$/ { in_block = 1; next }
    in_block && /^```$/ { exit }
    in_block { print }
  ' "$REFERENCE"
}

# Runs the reference snippet from the fixture project with the given shell
# command line ("zsh" or "bash-no-split"), the values the run carries set as
# plain shell variables the way Claude prefixes them.
run_reference_snippet() {
  local shell_kind="$1" owed="$2" snippet_file="$BATS_TEST_TMPDIR/snippet.sh"
  reference_snippet > "$snippet_file"
  [ -s "$snippet_file" ] || { echo "no snippet under ## The setup ping" >&2; return 1; }
  # shellcheck disable=SC2016  # the inner shells expand their own positional arguments
  case "$shell_kind" in
    zsh) run env DRIFT_JSON="$DRIFT_JSON" zsh -c 'cd "$1" || exit 99; OWED_AT_START="$2"; SETUP_TYPE=""; REPO_CHOICE=""; . "$3"' _ "$PROJECT" "$owed" "$snippet_file" ;;
    bash-no-split) run env DRIFT_JSON="$DRIFT_JSON" bash -c 'cd "$1" || exit 99; OWED_AT_START="$2"; SETUP_TYPE=""; REPO_CHOICE=""; IFS=; . "$3"' _ "$PROJECT" "$owed" "$snippet_file" ;;
  esac
}

@test "no owed ids and no setup type skips the ping" {
  run_ping DRIFT_JSON="$(decided_json A)" --owed ''
  [ "$status" -eq 0 ]
  [ "$output" = PING_SKIPPED ]
  [ ! -e "$PING_LOG" ]
}

@test "one owed id decided this run sends the ping with no type" {
  run_ping DRIFT_JSON="$(decided_json A)" --owed 'A'
  [ "$status" -eq 0 ]
  [ "$(cat "$PING_LOG")" = '--event setup --sandbox off' ]
}

@test "one owed id left undecided skips the ping" {
  run_ping DRIFT_JSON="$(decided_json Z)" --owed 'A'
  [ "$output" = PING_SKIPPED ]
  [ ! -e "$PING_LOG" ]
}

@test "three owed ids with only the middle one decided sends the ping" {
  run_ping DRIFT_JSON="$(decided_json B Z)" --owed 'A B C'
  [ "$status" -eq 0 ]
  [ "$(cat "$PING_LOG")" = '--event setup --sandbox off' ]
}

@test "three owed ids none decided skips the ping" {
  run_ping DRIFT_JSON="$(decided_json Y Z)" --owed 'A B C'
  [ "$output" = PING_SKIPPED ]
  [ ! -e "$PING_LOG" ]
}

@test "an owed id matches only a whole decided id, never a prefix" {
  run_ping DRIFT_JSON="$(decided_json AB)" --owed 'A'
  [ "$output" = PING_SKIPPED ]
}

@test "a setup type sends the ping even with nothing newly decided" {
  run_ping DRIFT_JSON="$(decided_json)" --owed '' --type fresh --repo create
  [ "$status" -eq 0 ]
  [ "$(cat "$PING_LOG")" = '--event setup --sandbox off --type fresh --repo create' ]
}

@test "empty type and repo values ride as absent" {
  run_ping DRIFT_JSON="$(decided_json A)" --owed 'A' --type '' --repo ''
  [ "$(cat "$PING_LOG")" = '--event setup --sandbox off' ]
}

@test "an enabled sandbox marker sends sandbox on" {
  run_ping DRIFT_JSON="$(decided_json A)" SANDBOX_OUTCOME=enabled --owed 'A'
  [ "$(cat "$PING_LOG")" = '--event setup --sandbox on' ]
}

@test "a drift failure counts as nothing newly decided" {
  run_ping DRIFT_FAILS=1 --owed 'A B C'
  [ "$status" -eq 0 ]
  [ "$output" = PING_SKIPPED ]
}

@test "an unknown argument is a usage error" {
  run_ping --bogus x
  [ "$status" -eq 2 ]
}

@test "the reference snippet sends the ping under no-split semantics with three owed ids" {
  DRIFT_JSON="$(decided_json B Z)"
  run_reference_snippet bash-no-split 'A B C'
  [ "$status" -eq 0 ]
  [ "$(cat "$PING_LOG")" = '--event setup --sandbox off' ]
}

@test "the reference snippet sends the ping under zsh with three owed ids" {
  command -v zsh >/dev/null 2>&1 || skip "zsh not installed"
  DRIFT_JSON="$(decided_json B Z)"
  run_reference_snippet zsh 'A B C'
  [ "$status" -eq 0 ]
  [ "$(cat "$PING_LOG")" = '--event setup --sandbox off' ]
}
