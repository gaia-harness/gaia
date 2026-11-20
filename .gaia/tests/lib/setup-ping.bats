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

@test "the ping is sent only when an owed id was decided this run or a setup type is given" {
  local label decided owed drift_fails type_value repo_value expected
  # expected is the logged ping line, or SKIPPED for no ping.
  while IFS='|' read -r label decided owed drift_fails type_value repo_value expected; do
    [ -n "$label" ] || continue
    rm -f "$PING_LOG"
    # shellcheck disable=SC2086  # decided is a space-separated id list
    if [ -n "$type_value" ]; then
      run_ping DRIFT_JSON="$(decided_json $decided)" DRIFT_FAILS="$drift_fails" --owed "$owed" --type "$type_value" --repo "$repo_value"
    else
      run_ping DRIFT_JSON="$(decided_json $decided)" DRIFT_FAILS="$drift_fails" --owed "$owed"
    fi
    [ "$status" -eq 0 ] || { echo "case $label: status $status"; return 1; }
    if [ "$expected" = SKIPPED ]; then
      [ "$output" = PING_SKIPPED ] || { echo "case $label: output $output"; return 1; }
      [ ! -e "$PING_LOG" ] || { echo "case $label: pinged $(cat "$PING_LOG")"; return 1; }
    else
      [ "$(cat "$PING_LOG")" = "$expected" ] || { echo "case $label: ping $(cat "$PING_LOG" 2>/dev/null)"; return 1; }
    fi
  done <<'CASES'
no owed ids, no type|A|||||SKIPPED
one owed id decided|A|A||||--event setup --sandbox off
one owed id undecided|Z|A||||SKIPPED
three owed, middle decided|B Z|A B C||||--event setup --sandbox off
three owed, none decided|Y Z|A B C||||SKIPPED
prefix is not a match|AB|A||||SKIPPED
setup type with nothing decided||||fresh|create|--event setup --sandbox off --type fresh --repo create
drift failure|A B C|A B C|1|||SKIPPED
CASES
}

@test "ping arguments: empty type and repo are absent, an enabled sandbox sends --sandbox on" {
  run_ping DRIFT_JSON="$(decided_json A)" --owed 'A' --type '' --repo ''
  [ "$(cat "$PING_LOG")" = '--event setup --sandbox off' ] || { echo "case empty type and repo: $(cat "$PING_LOG")"; return 1; }
  rm -f "$PING_LOG"
  run_ping DRIFT_JSON="$(decided_json A)" SANDBOX_OUTCOME=enabled --owed 'A'
  [ "$(cat "$PING_LOG")" = '--event setup --sandbox on' ] || { echo "case enabled sandbox: $(cat "$PING_LOG")"; return 1; }
}

@test "the reference snippet sends the ping in bash with an empty IFS and in zsh, neither of which word-splits" {
  local shell_kind
  DRIFT_JSON="$(decided_json B Z)"
  for shell_kind in bash-no-split zsh; do
    if [ "$shell_kind" = zsh ] && ! command -v zsh >/dev/null 2>&1; then
      echo "case zsh: zsh not installed, not run" >&3
      continue
    fi
    rm -f "$PING_LOG"
    run_reference_snippet "$shell_kind" 'A B C'
    [ "$status" -eq 0 ] || { echo "case $shell_kind: status $status"; return 1; }
    [ "$(cat "$PING_LOG")" = '--event setup --sandbox off' ] || { echo "case $shell_kind: ping $(cat "$PING_LOG" 2>/dev/null)"; return 1; }
  done
}
