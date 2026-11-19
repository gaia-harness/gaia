#!/usr/bin/env bats

# Tests for .claude/hooks/block-audit-loop-write.sh.
#
# The protected folder (<main>/.gaia/local/protected/, holding the audit loop
# state and the checkpoint override) is written only by hooks and by a human.
# This guard denies Claude's Edit / Write / MultiEdit calls that resolve into it
# (including through a linked worktree's `.gaia/local` symlink and a `..`
# segment) and Bash / Monitor commands that redirect into it or name it
# alongside a write, move or delete verb, while allowing reads, quoted notes
# that mention it redirected elsewhere, and the audit loop scripts, which never
# name the folder. A path segment that merely ends in `audit-loop` (a worktree
# named like `spec-091-audit-loop`) or merely starts with `protected` does not
# arm it.
#
# Most tests are case tables: one fixture, one row per spelling. A row is
# `tool~input~cwd~extra` (an empty cwd means the main checkout); `~` never
# appears in the fixture paths.

setup() {
  . "$BATS_TEST_DIRNAME/helpers/run-hook.sh"
  HOOKS_SOURCE_DIRECTORY=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)
  # HOOK_UNDER_TEST lets a mutation proof point the suite at a scratch copy.
  HOOK_ABSOLUTE_PATH="${HOOK_UNDER_TEST:-$HOOKS_SOURCE_DIRECTORY/block-audit-loop-write.sh}"

  FIX=$(cd "$(mktemp -d "$BATS_TEST_TMPDIR/fix.XXXXXX")" && pwd -P)
  MAIN="$FIX/main"
  WORKTREE="$FIX/wt"
  mkdir -p "$MAIN"
  git -C "$MAIN" init -q -b main
  git -C "$MAIN" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m init
  mkdir -p "$MAIN/.gaia/local/protected/audit-loop/feat"
  git -C "$MAIN" worktree add -q "$WORKTREE" -b feat
  mkdir -p "$WORKTREE/.gaia"
  ln -s "$MAIN/.gaia/local" "$WORKTREE/.gaia/local"
  STATE="$MAIN/.gaia/local/protected/audit-loop/feat/x.json"
  WORKTREE_STATE="$WORKTREE/.gaia/local/protected/audit-loop/feat/x.json"
  NEW_STATE="$MAIN/.gaia/local/protected/new-state.json"
  WORKTREE_NEW_STATE="$WORKTREE/.gaia/local/protected/new-state.json"
  FOLDER="$MAIN/.gaia/local/protected"
  WORKTREE_FOLDER="$WORKTREE/.gaia/local/protected"
  OLD_STATE="$MAIN/.gaia/local/audit-loop/feat/x.json"
  OLD_OVERRIDE="$MAIN/.gaia/local/checkpoint-override.json"
  mkdir -p "$MAIN/.gaia/local/cache/shared/context"
  CONTEXT_FILE_NAME=0a1b2c3d-0000-4000-8000-000000000001.json
  CONTEXT_FILE="$MAIN/.gaia/local/cache/shared/context/$CONTEXT_FILE_NAME"
  WORKTREE_CONTEXT_FILE="$WORKTREE/.gaia/local/cache/shared/context/$CONTEXT_FILE_NAME"
  printf '{"version":1}' >"$CONTEXT_FILE"
  OVERRIDE="$MAIN/.gaia/local/protected/checkpoint-override.json"
  WORKTREE_OVERRIDE="$WORKTREE/.gaia/local/protected/checkpoint-override.json"
  ASK_RECORDER="$MAIN/.claude/hooks/audit-loop-ask-grant.sh"
  GRANT_RECORDER="$MAIN/.claude/hooks/audit-loop-grant.sh"
}

edit_payload() {
  jq -n --arg tool_name "$1" --arg file_path "$2" --arg cwd "$3" '{tool_name: $tool_name, cwd: $cwd, tool_input: {file_path: $file_path}}'
}

command_payload() {
  jq -n --arg tool_name "$1" --arg command "$2" --arg cwd "$3" '{tool_name: $tool_name, cwd: $cwd, tool_input: {command: $command}}'
}

run_edit() {
  invoke_hook "$(edit_payload "$1" "$2" "${3:-$MAIN}")" "$HOOK_ABSOLUTE_PATH"
}

run_bash() {
  invoke_hook "$(command_payload Bash "$1" "${2:-$MAIN}")" "$HOOK_ABSOLUTE_PATH"
}

run_monitor() {
  invoke_hook "$(command_payload Monitor "$1" "${2:-$MAIN}")" "$HOOK_ABSOLUTE_PATH"
}

# run_as <tool> <input> [cwd]: the input is a path for the edit tools and Read,
# a command line for Bash and Monitor.
run_as() {
  case "$1" in
    Write | Edit | MultiEdit) run_edit "$1" "$2" "${3:-$MAIN}" ;;
    Bash) run_bash "$2" "${3:-$MAIN}" ;;
    Monitor) run_monitor "$2" "${3:-$MAIN}" ;;
    Read) invoke_hook "$(jq -n --arg file_path "$2" '{tool_name: "Read", tool_input: {file_path: $file_path}}')" "$HOOK_ABSOLUTE_PATH" ;;
  esac
}

# parse_row <row>: split `tool~input~cwd~extra` (an input may span lines) into
# row_tool, row_input, row_cwd and row_extra.
parse_row() {
  local rest="$1"
  row_tool="${rest%%~*}"
  rest="${rest#*~}"
  row_input="${rest%%~*}"
  rest="${rest#*~}"
  row_cwd="${rest%%~*}"
  row_extra="${rest#*~}"
}

# A table row for an allowed call: allowed, and silent.
assert_row_allowed() {
  assert_allowed_by_json
  [ -z "$output" ]
}

# --- denied: state folder ---

@test "Write into the protected state folder is denied in each non-direct spelling" {
  local row
  # The first two rows run before `runs/` exists, so the `..` segment is
  # resolved through a directory that is absent.
  echo "case: .. through an absent directory"
  run_edit Write "$MAIN/.gaia/local/runs/../protected/audit-loop/feat/x.json"
  assert_denied_by_json
  echo "case: a not-yet-existing nested state path"
  run_edit Write "$MAIN/.gaia/local/protected/audit-loop/new/branch/y.json"
  assert_denied_by_json

  mkdir -p "$MAIN/.gaia/local/runs"
  ln -s "$FOLDER" "$FIX/vault"
  ln -s "$MAIN/.gaia/local" "$FIX/alias-local"
  local rows=(
    "Write~.gaia/local/protected/new-state.json~~folder"
    "Write~$MAIN/.gaia/local/runs/../protected/audit-loop/feat/x.json~~state"
    "Write~$WORKTREE/.gaia/local/runs/../protected/audit-loop/feat/x.json~$WORKTREE~state"
    "Write~$FIX/vault/audit-loop/feat/x.json~~state"
    "Write~$FIX/alias-local/protected/new-state.json~~folder"
  )
  for row in "${rows[@]}"; do
    echo "case: $row"
    parse_row "$row"
    run_as "$row_tool" "$row_input" "$row_cwd"
    assert_pins_only_class "$row_extra"
  done
}

# With no resolvable checkout, only the guarded_class protected-folder arm
# recognizes the path.
# bats test_tags=protected
@test "Write into a protected folder with no resolvable checkout is denied" {
  mkdir -p "$FIX/nogit/.gaia/local/protected"
  . "$HOOKS_SOURCE_DIRECTORY/../../.gaia/scripts/main-root-lib.sh"
  [ -z "$(gaia_resolve_main_root "$FIX/nogit" 2>/dev/null)" ]
  run_edit Write "$FIX/nogit/.gaia/local/protected/new-state.json" "$FIX/nogit"
  assert_denied_by_json
}

@test "Bash and Monitor writes into the state folder are denied in every shape" {
  local row nl=$'\n'
  local rows=(
    "Bash~rm -f $STATE~~"
    "Bash~rm -rf $MAIN/.gaia/local/protected/audit-loop~~"
    "Bash~mv $STATE /tmp/y~~"
    "Bash~python3 -c \"open('$STATE','w')\"~~"
    "Bash~mv $WORKTREE_STATE /tmp/y~$WORKTREE~"
    "Bash~echo x >$STATE~~"
    "Bash~printf '{}' > \"$STATE\"~~"
    "Bash~printf '%s' 'a > b' > $STATE~~"
    "Bash~x=\"\$(printf '{}' > $STATE)\"~~"
    "Bash~cat <<EOF > $BATS_TEST_TMPDIR/n${nl}don't${nl}EOF${nl}echo x > $STATE~~"
    "Bash~echo hi # don't${nl}rm $STATE # it's gone~~"
    "Bash~# don't do this lightly${nl}rm -f $STATE${nl}# it's fine now~~"
    "Bash~# don't do this lightly${nl}echo '{}' > $STATE${nl}# it's fine now~~"
    "Bash~D=$MAIN/.gaia/local/protected/audit-loop/feat; echo x > \"\$D/x.json\"~~"
    "Bash~for f in $MAIN/.gaia/local/protected/audit-loop/feat/*.json; do echo '{}' > \"\$f\"; done~~"
    "Bash~rm -f $FIX/spec-091-audit-loop/.gaia/local/protected/audit-loop/feat/x.json~~"
    "Bash~rm -rf $MAIN/.gaia/local/protected/audit-loop/feat~~state"
  )
  for row in "${rows[@]}"; do
    echo "case: $row"
    parse_row "$row"
    run_as "$row_tool" "$row_input" "$row_cwd"
    if [ -n "$row_extra" ]; then
      assert_pins_only_class "$row_extra"
    else
      assert_denied_by_json
    fi
  done
}

# --- allowed ---

# A note that quotes a guarded path as text and is redirected elsewhere is the
# shape an audit member stages a findings sidecar with.
@test "reads, quoted notes naming a guarded path, lookalike worktrees and unrelated calls are allowed" {
  local row guarded_path
  local rows=(
    "Write~$MAIN/.gaia/local/runs/feat/notes.json~~"
    "Bash~ls $MAIN/.gaia/local/protected/audit-loop/~~"
    "Bash~cat $STATE 2>&1 | head -5~~"
    "Bash~cat $STATE > /dev/null~~"
    "Bash~bash .gaia/scripts/audit-loop-eval.sh brief --root /x~~"
    "Bash~bash .gaia/scripts/audit-loop-record.sh --pr 1 --values-json -~~"
    "Bash~rm -f $FIX/spec-091-audit-loop/notes.txt~~"
    "Bash~echo x > $FIX/spec-091-audit-loop/app/file.ts~~"
    "Bash~rm /tmp/z~~"
    "Bash~echo x > /tmp/z~~"
    "Read~$STATE~~"
    "Bash~git -C $FIX/spec-093-audit-loop-unit status --short~~"
    "Bash~printf '%s\n' \"never rm or mv $STATE by hand\" >> $BATS_TEST_TMPDIR/note.txt~~"
  )
  for guarded_path in "$STATE" "$CONTEXT_FILE" "$OVERRIDE" "$NEW_STATE"; do
    rows+=("Bash~printf '%s\n' 'the hook trusts $guarded_path as written' > $BATS_TEST_TMPDIR/note.txt~~")
  done
  for row in "${rows[@]}"; do
    echo "case: $row"
    parse_row "$row"
    run_as "$row_tool" "$row_input" "$row_cwd"
    assert_row_allowed
  done
}

# --- jq absent ---

# A fresh `bash -c` with a scrubbed PATH: under stock bash 3.2 a command-scoped
# PATH does not drop an already-hashed jq.
run_without_jq() {
  local payload="$1" hook="${2:-$HOOK_ABSOLUTE_PATH}" bin="$FIX/nojq-bin" tool_name
  mkdir -p "$bin"
  for tool_name in bash cat dirname tr; do
    ln -sf "$(command -v "$tool_name")" "$bin/$tool_name"
  done
  run /bin/bash -c 'PATH="$1"; printf %s "$2" | /bin/bash "$3"' _ "$bin" "$payload" "$hook"
}

@test "jq absent: a write to a guarded path is refused" {
  local row payload
  local rows=(
    "Write~$STATE~~"
    "Bash~rm $STATE~~"
    "Write~$CONTEXT_FILE~~"
    "Bash~echo '{}' > $OVERRIDE~~"
  )
  for row in "${rows[@]}"; do
    echo "case: $row"
    parse_row "$row"
    if [ "$row_tool" = Write ]; then
      payload=$(edit_payload Write "$row_input" "$MAIN")
    else
      payload=$(command_payload Bash "$row_input" "$MAIN")
    fi
    run_without_jq "$payload"
    [ "$status" -eq 2 ]
    grep -qF -- 'BLOCKED' <<<"$output"
  done
}

@test "jq absent: installing jq is allowed" {
  run_without_jq "$(command_payload Bash "brew install jq" "$MAIN")"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- gate inputs: context readings, override, recorder execution ---

# Every deny names the guard and carries both answer channels; the class
# fragment tells the four messages apart.
assert_denied_class() {
  assert_denied_by_json
  grep -qF -- 'block-audit-loop-write.sh' <<<"$output"
  grep -qF -- 'AskUserQuestion' <<<"$output"
  grep -qF -- 'audit-grant' <<<"$output"
  grep -qF -- "$1" <<<"$output"
}

# --- context readings ---

# bats test_tags=protected
@test "a context reading is never written by an edit tool, Bash or Monitor, in any spelling" {
  local row
  local rows=(
    "Write~$CONTEXT_FILE~~"
    "Edit~$CONTEXT_FILE~~"
    "Write~$MAIN/.gaia/local/cache/shared/context/0a1b2c3d-0000-4000-8000-000000000002.json~~"
    "Write~$WORKTREE_CONTEXT_FILE~$WORKTREE~"
    "Write~$MAIN/.gaia/local/cache/../cache/shared/context/$CONTEXT_FILE_NAME~~"
    "Bash~printf x > $CONTEXT_FILE~~"
    "Bash~mv $CONTEXT_FILE /tmp/x~~"
    "Bash~rm -f $CONTEXT_FILE~~"
    "Bash~rm -rf $MAIN/.gaia/local/cache/shared/context~~"
    "Bash~printf x > $WORKTREE_CONTEXT_FILE~$WORKTREE~"
    "Bash~mv $WORKTREE_CONTEXT_FILE /tmp/x~$WORKTREE~"
    "Bash~rm -f $WORKTREE_CONTEXT_FILE~$WORKTREE~"
    "Monitor~rm -f $CONTEXT_FILE~~"
  )
  for row in "${rows[@]}"; do
    echo "case: $row"
    parse_row "$row"
    run_as "$row_tool" "$row_input" "$row_cwd"
    assert_denied_class 'context readings'
  done
}

@test "reading a context file or the override, and writing a sibling cache file, are allowed" {
  local row
  printf '{}' >"$OVERRIDE"
  local rows=(
    "Bash~cat $CONTEXT_FILE~~"
    "Bash~jq . $CONTEXT_FILE~~"
    "Write~$MAIN/.gaia/local/cache/shared/update-check.json~~"
    "Bash~cat $OVERRIDE~~"
    "Bash~jq . $OVERRIDE~~"
  )
  for row in "${rows[@]}"; do
    echo "case: $row"
    parse_row "$row"
    run_as "$row_tool" "$row_input" "$row_cwd"
    assert_row_allowed
  done
}

# --- override file ---

# bats test_tags=protected
@test "the checkpoint override is never written by an edit tool, Bash or Monitor" {
  local row
  # The denied rows create nothing, so the file stays absent through the loop.
  [ ! -e "$OVERRIDE" ]
  local rows=(
    "Write~$OVERRIDE~~"
    "Write~$WORKTREE_OVERRIDE~$WORKTREE~"
    "Bash~echo '{}' > $OVERRIDE~~"
    "Bash~echo '{}' > $WORKTREE_OVERRIDE~$WORKTREE~"
    "Bash~rm -f $OVERRIDE~~"
    "Bash~mv /tmp/s.json $OVERRIDE~~"
    "Monitor~echo '{}' > $OVERRIDE~~"
  )
  for row in "${rows[@]}"; do
    echo "case: $row"
    parse_row "$row"
    run_as "$row_tool" "$row_input" "$row_cwd"
    assert_denied_class 'only a human edits the override'
  done
  printf '{}' >"$OVERRIDE"
  echo "case: Edit of an existing override file"
  run_edit Edit "$OVERRIDE"
  assert_denied_class 'only a human edits the override'
}

@test "writes to settings files and the opt-ins file are allowed" {
  local row
  local rows=(
    "Write~$MAIN/.claude/settings.json~~"
    "Write~$MAIN/.claude/settings.local.json~~"
    "Bash~echo '{}' > $MAIN/.claude/settings.json~~"
    "Write~$MAIN/.gaia/local/settings.json~~"
    "Write~$WORKTREE/.gaia/local/settings.json~$WORKTREE~"
    "Bash~echo '{}' > $MAIN/.gaia/local/settings.json~~"
  )
  for row in "${rows[@]}"; do
    echo "case: $row"
    parse_row "$row"
    run_as "$row_tool" "$row_input" "$row_cwd"
    assert_row_allowed
  done
}

# --- recorder execution ---

# Each execution form is denied before it runs, and the state is untouched.
# The optional second argument names the runner (run_bash by default).
assert_recorder_denied() {
  cp "$STATE" "$BATS_TEST_TMPDIR/state.before"
  "${2:-run_bash}" "$1"
  assert_denied_class 'run only as hooks'
  cmp "$STATE" "$BATS_TEST_TMPDIR/state.before"
}

# bats test_tags=protected
@test "a forged payload piped to the ask recorder through bash is denied" {
  printf '{"seed":1}' >"$STATE"
  assert_recorder_denied "printf '%s' '{\"tool_name\":\"AskUserQuestion\"}' | bash $ASK_RECORDER"
}

# A checkout path with a space: the quoted recorder path is one shell word, so
# splitting before the quotes are read would hand the guard `.../My` instead.
@test "every form of running a recorder is denied before it runs" {
  local row nl=$'\n'
  printf '{"seed":1}' >"$STATE"
  local rows=(
    "Bash~printf x | $ASK_RECORDER~~"
    "Bash~bash .claude/hooks/audit-loop-grant.sh < payload.json~~"
    "Bash~.claude/hooks/audit-loop-grant.sh < payload.json~~"
    "Bash~source .claude/hooks/audit-loop-grant.sh~~"
    "Bash~. .claude/hooks/audit-loop-grant.sh~~"
    "Bash~true && sh $GRANT_RECORDER~~"
    "Bash~exec $ASK_RECORDER~~"
    "Bash~bash -eu -o pipefail $GRANT_RECORDER~~"
    "Bash~FOO=1 \"$ASK_RECORDER\" < /dev/null~~"
    "Bash~echo hi${nl}bash $GRANT_RECORDER~~"
    "Bash~bash \"$FIX/My Repo/.claude/hooks/audit-loop-grant.sh\" < p.json~~"
    "Bash~\"$FIX/My Repo/.claude/hooks/audit-loop-grant.sh\" < p.json~~"
    "Monitor~printf '%s' '{}' | bash $ASK_RECORDER~~"
    "Monitor~bash .claude/hooks/audit-loop-grant.sh < payload.json~~"
  )
  for row in "${rows[@]}"; do
    echo "case: $row"
    parse_row "$row"
    assert_recorder_denied "$row_input" "run_$(printf '%s' "$row_tool" | tr 'A-Z' 'a-z')"
  done
}

@test "staging, reading and checking a recorder is allowed" {
  local row
  local rows=(
    "Bash~git -C \"$FIX/My Repo\" add -- \"$FIX/My Repo/.claude/hooks/audit-loop-grant.sh\"~~"
    "Bash~git -C $MAIN add -- .claude/hooks/audit-loop-grant.sh~~"
    "Bash~git -C $MAIN diff -- .claude/hooks/audit-loop-grant.sh~~"
    "Bash~git -C $MAIN grep -l 'audit-loop-grant.sh' -- '*.bats'~~"
    "Bash~git -C $MAIN log --oneline -- .claude/hooks/audit-loop-ask-grant.sh~~"
    "Bash~shellcheck .claude/hooks/audit-loop-ask-grant.sh~~"
    "Bash~bash -n .claude/hooks/audit-loop-grant.sh~~"
    "Bash~cat .claude/hooks/audit-loop-grant.sh~~"
    "Bash~grep -n audit-loop-ask-grant.sh .claude/settings.json~~"
  )
  for row in "${rows[@]}"; do
    echo "case: $row"
    parse_row "$row"
    run_as "$row_tool" "$row_input" "$row_cwd"
    assert_row_allowed
  done
}

# --- reaper execution ---

# The reaper message is its own class: it names the guard and the pin, and
# carries neither checkpoint answer channel, since the reason is not a forged
# answer.
assert_reaper_denied() {
  assert_pins_only_class reaper
  grep -qF -- 'block-audit-loop-write.sh' <<<"$output"
}

# bats test_tags=protected
@test "every form of running the state reaper is denied" {
  local row
  local rows=(
    "Bash~bash .gaia/scripts/state-reaper.sh~~"
    "Bash~.gaia/scripts/state-reaper.sh~~"
    "Bash~$MAIN/.gaia/scripts/state-reaper.sh~~"
    "Bash~bash .claude/hooks/state-reaper-session-start.sh~~"
    "Bash~source .gaia/scripts/state-reaper-classes.sh~~"
    "Bash~. .gaia/scripts/state-reaper-lib.sh~~"
    "Bash~FOO=1 bash .gaia/scripts/state-reaper.sh~~"
    "Bash~true && bash .gaia/scripts/state-reaper.sh~~"
    "Monitor~bash .gaia/scripts/state-reaper.sh~~"
  )
  for row in "${rows[@]}"; do
    echo "case: $row"
    parse_row "$row"
    run_as "$row_tool" "$row_input" "$row_cwd"
    assert_reaper_denied
  done
}

@test "staging, reading and checking the state reaper, and running its suite and the cleanup script, is allowed" {
  local row
  local rows=(
    "Bash~git add .gaia/scripts/state-reaper.sh~~"
    "Bash~shellcheck .gaia/scripts/state-reaper.sh~~"
    "Bash~bash -n .gaia/scripts/state-reaper.sh~~"
    "Bash~cat .gaia/scripts/state-reaper-lib.sh~~"
    "Bash~bash .gaia/scripts/bats5.sh .gaia/scripts/tests/state-reaper.bats < /dev/null~~"
    "Bash~bash .gaia/scripts/state-cleanup.sh --branch fix/a~~"
  )
  for row in "${rows[@]}"; do
    echo "case: $row"
    parse_row "$row"
    run_as "$row_tool" "$row_input" "$row_cwd"
    assert_row_allowed
  done
}

# --- deny text, every class ---

@test "each deny message names the guard, its class and both answer channels" {
  local row frag class_name fragments
  local channels='block-audit-loop-write.sh;AskUserQuestion;audit-grant'
  local rows=(
    "Bash~rm $STATE~~state;The branch checkpoint;outside Claude Code"
    "Bash~echo x > $STATE~~state;redirects into it;only as quoted text"
    "Write~$STATE~~state;$channels;audit-accept;#### The branch checkpoint"
    "Write~$CONTEXT_FILE~~;$channels"
    "Write~$OVERRIDE~~override;$channels;audit-accept;#### The branch checkpoint;<main>/.gaia/local/protected/checkpoint-override.json;<main>/.gaia/local/settings.json"
    "Write~$NEW_STATE~~folder;$channels;audit-accept;#### The branch checkpoint"
    "Bash~bash $ASK_RECORDER~~;$channels"
  )
  for row in "${rows[@]}"; do
    echo "case: $row"
    parse_row "$row"
    run_as "$row_tool" "$row_input" "$row_cwd"
    IFS=';' read -ra fragments <<<"$row_extra"
    class_name="${fragments[0]}"
    if [ -n "$class_name" ]; then
      assert_pins_only_class "$class_name"
    else
      assert_denied_by_json
    fi
    for frag in "${fragments[@]:1}"; do
      grep -qF -- "$frag" <<<"$output"
    done
  done
}

# --- the protected folder as a whole ---

# cell_is_denied <label>: the last invoke_hook run is a deny whose reason names
# the guard; a failing cell prints its label.
cell_is_denied() {
  local reason
  [ "$status" -eq 0 ] || {
    printf 'cell %s: status %s\n' "$1" "$status" >&2
    return 1
  }
  grep -qF -- '"permissionDecision": "deny"' <<<"$output" || {
    printf 'cell %s: not denied: %s\n' "$1" "$output" >&2
    return 1
  }
  reason=$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$output")
  case "$reason" in
    'BLOCKED: block-audit-loop-write.sh:'*) ;;
    *)
      printf 'cell %s: reason does not start with the guard name: %s\n' "$1" "$reason" >&2
      return 1
      ;;
  esac
}

# cell_is_allowed <label>: the last run allowed with no output.
cell_is_allowed() {
  [ "$status" -eq 0 ] || {
    printf 'cell %s: status %s\n' "$1" "$status" >&2
    return 1
  }
  [ -z "$output" ] || {
    printf 'cell %s: expected silence, got: %s\n' "$1" "$output" >&2
    return 1
  }
}

# class_pin <class>: the substring only that class's message carries.
class_pin() {
  case "$1" in
    state) printf '%s' 'the audit loop state (<main>/.gaia/local/protected/audit-loop/)' ;;
    override) printf '%s' 'only a human edits the override' ;;
    folder) printf '%s' 'only hooks or a human write <main>/.gaia/local/protected/' ;;
    context) printf '%s' 'the context readings (<main>/.gaia/local/cache/shared/context/)' ;;
    recorder) printf '%s' 'run only as hooks' ;;
    reaper) printf '%s' 'the local-state reaper scripts' ;;
  esac
}

# assert_pins_only_class <class>: the last run is a deny carrying that class's
# pin and none of the other five classes' pins.
assert_pins_only_class() {
  local expected_class="$1" other_class
  assert_denied_by_json
  grep -qF -- "$(class_pin "$expected_class")" <<<"$output" || {
    printf 'class %s: its pin is missing from: %s\n' "$expected_class" "$output" >&2
    return 1
  }
  for other_class in state override folder context recorder reaper; do
    if [ "$other_class" != "$expected_class" ]; then
      if grep -qF -- "$(class_pin "$other_class")" <<<"$output"; then
        printf 'class %s: carries the %s pin: %s\n' "$expected_class" "$other_class" "$output" >&2
        return 1
      fi
    fi
  done
  return 0
}

# bats test_tags=protected
@test "Edit, Write and MultiEdit into the protected folder are denied in every spelling" {
  local tool cell cell_path cell_cwd cells=0
  local -a spellings=(
    "$STATE|$MAIN" "$OVERRIDE|$MAIN" "$NEW_STATE|$MAIN"
    "$WORKTREE_STATE|$WORKTREE" "$WORKTREE_OVERRIDE|$WORKTREE" "$WORKTREE_NEW_STATE|$WORKTREE"
  )
  for tool in Edit Write MultiEdit; do
    for cell in "${spellings[@]}"; do
      cell_path="${cell%%|*}"
      cell_cwd="${cell#*|}"
      run_edit "$tool" "$cell_path" "$cell_cwd"
      cell_is_denied "$tool $cell_path"
      cells=$((cells + 1))
    done
  done
  [ "${#spellings[@]}" -eq 6 ]
  [ "$cells" -eq 18 ]
}

# The tool-spelling matrix for Bash and Monitor: every target through every
# write shape.
assert_write_matrix() {
  local runner="$1" cell target cwd shape command_line cells=0
  local -a targets=(
    "$MAIN/.gaia/local/protected/audit-loop/x.json|$MAIN" "$OVERRIDE|$MAIN" "$NEW_STATE|$MAIN" "$FOLDER|$MAIN" "$FOLDER/|$MAIN"
    "$WORKTREE/.gaia/local/protected/audit-loop/x.json|$WORKTREE" "$WORKTREE_OVERRIDE|$WORKTREE" "$WORKTREE_NEW_STATE|$WORKTREE" "$WORKTREE_FOLDER|$WORKTREE" "$WORKTREE_FOLDER/|$WORKTREE"
    ".gaia/local/protected/new-state.json|$MAIN"
  )
  local -a shapes=(
    "printf x > @T@"
    "printf x >> @T@"
    "rm @T@"
    "rm -rf @T@"
    "mv $BATS_TEST_TMPDIR/a @T@"
    "cp $BATS_TEST_TMPDIR/a @T@"
    "touch @T@"
    "sed -i '' 's/a/b/' @T@"
    "printf x | tee @T@"
    "ln -s $BATS_TEST_TMPDIR/a @T@"
  )
  for cell in "${targets[@]}"; do
    target="${cell%%|*}"
    cwd="${cell#*|}"
    for shape in "${shapes[@]}"; do
      command_line="${shape//@T@/$target}"
      "$runner" "$command_line" "$cwd"
      cell_is_denied "$runner: $command_line"
      cells=$((cells + 1))
    done
  done
  [ "${#targets[@]}" -eq 11 ]
  [ "${#shapes[@]}" -eq 10 ]
  [ "$cells" -eq 110 ]
}

assert_indirect_writes_denied() {
  local runner="$1"
  "$runner" "D=$MAIN/.gaia/local/protected; echo x > \"\$D/new-state.json\"" "$MAIN"
  cell_is_denied "$runner variable indirection"
  "$runner" "for f in $MAIN/.gaia/local/protected/*.json; do echo '{}' > \"\$f\"; done" "$MAIN"
  cell_is_denied "$runner loop over a glob"
}

@test "Bash and Monitor write shapes, variable writes and loop writes against every protected target are denied" {
  assert_write_matrix run_bash
  assert_write_matrix run_monitor
  assert_indirect_writes_denied run_bash
  assert_indirect_writes_denied run_monitor
}

assert_read_matrix() {
  local runner="$1" cell target cwd reader cells=0
  local -a targets=(
    "$MAIN/.gaia/local/protected/audit-loop/x.json|$MAIN" "$OVERRIDE|$MAIN" "$NEW_STATE|$MAIN" "$FOLDER|$MAIN" "$FOLDER/|$MAIN"
    "$WORKTREE/.gaia/local/protected/audit-loop/x.json|$WORKTREE" "$WORKTREE_OVERRIDE|$WORKTREE" "$WORKTREE_NEW_STATE|$WORKTREE" "$WORKTREE_FOLDER|$WORKTREE" "$WORKTREE_FOLDER/|$WORKTREE"
    ".gaia/local/protected/new-state.json|$MAIN"
  )
  local -a readers=("cat @T@" "ls @T@" "jq . @T@")
  for cell in "${targets[@]}"; do
    target="${cell%%|*}"
    cwd="${cell#*|}"
    for reader in "${readers[@]}"; do
      "$runner" "${reader//@T@/$target}" "$cwd"
      cell_is_allowed "$runner: ${reader//@T@/$target}"
      cells=$((cells + 1))
    done
  done
  [ "${#targets[@]}" -eq 11 ]
  [ "${#readers[@]}" -eq 3 ]
  [ "$cells" -eq 33 ]
  "$runner" "ls .gaia/local/protected/ | wc -l" "$MAIN"
  cell_is_allowed "$runner: ls of the relative folder piped to wc"
}

@test "Bash and Monitor reads of every protected target are allowed" {
  assert_read_matrix run_bash
  assert_read_matrix run_monitor
}

# --- deny class dispatch ---

# A Write row's input is a path; a Bash or Monitor row's input is the command.
@test "each protected path and compound command is denied with its own class" {
  local row
  local rows=(
    "Write~$STATE~~state"
    "Write~$FOLDER/audit-loop~~state"
    "Write~$OVERRIDE~~override"
    "Write~$NEW_STATE~~folder"
    "Write~$FOLDER/audit-loop-notes.json~~folder"
    "Write~$FOLDER/checkpoint-override.json.bak~~folder"
    "Write~$FOLDER~~folder"
    "Bash~printf x > $STATE~~state"
    "Bash~printf x > $FOLDER/audit-loop~~state"
    "Bash~printf x > $OVERRIDE~~override"
    "Bash~printf x > $NEW_STATE~~folder"
    "Bash~printf x > $FOLDER/audit-loop-notes.json~~folder"
    "Bash~printf x > $FOLDER/checkpoint-override.json.bak~~folder"
    "Bash~printf x > $FOLDER~~folder"
    "Bash~cat $NEW_STATE && rm $NEW_STATE~~folder"
    "Bash~cat $STATE; printf x > $OVERRIDE~~override"
    "Bash~printf x > $NEW_STATE; cat $STATE~~folder"
    "Monitor~cat $STATE; printf x > $OVERRIDE~~override"
    "Monitor~printf x > $NEW_STATE; cat $STATE~~folder"
  )
  for row in "${rows[@]}"; do
    echo "case: $row"
    parse_row "$row"
    run_as "$row_tool" "$row_input" "$row_cwd"
    assert_pins_only_class "$row_extra"
  done
}

# --- siblings and lookalikes ---

@test "siblings that share a prefix with a protected path, and the old state locations, are allowed" {
  local row
  local rows=(
    "Write~$MAIN/.gaia/local/audit-loop-notes.md~~"
    "Write~$MAIN/.gaia/local/protected-notes.md~~"
    "Bash~mkdir -p $MAIN/.gaia/local/protected/audit-loop/feat~~"
    "Write~$OLD_STATE~~"
    "Write~$OLD_OVERRIDE~~"
    "Bash~printf x > $OLD_OVERRIDE~~"
  )
  for row in "${rows[@]}"; do
    echo "case: $row"
    parse_row "$row"
    run_as "$row_tool" "$row_input" "$row_cwd"
    assert_row_allowed
  done
}

assert_lookalikes_allowed() {
  local runner="$1" command_line checked=0
  for command_line in \
    "printf x > $MAIN/.gaia/local/protected-notes.md" \
    "rm $MAIN/.gaia/local/protected.bak" \
    "rm -f $FIX/notes/local/protected/x.json"; do
    "$runner" "$command_line" "$MAIN"
    cell_is_allowed "$runner: $command_line"
    checked=$((checked + 1))
  done
  [ "$checked" -eq 3 ]
  # The lookalike carries the pre-filter literal, so it reaches the path regex.
  grep -qF -- 'local/protected' <<<"$command_line"
}

assert_recorder_run_denied_and_staging_allowed() {
  local runner="$1" recorder_command="bash .claude/hooks/audit-loop-grant.sh"
  grep -qF -- protected <<<"$recorder_command" && return 1
  grep -qF -- 'cache/shared/context' <<<"$recorder_command" && return 1
  "$runner" "$recorder_command" "$MAIN"
  assert_pins_only_class recorder
  "$runner" "git add .claude/hooks/audit-loop-grant.sh" "$MAIN"
  cell_is_allowed "$runner: git add of the grant recorder"
}

@test "Bash and Monitor writes to protected lookalikes are allowed, and running the grant recorder is denied through the audit-loop literal while staging it is allowed" {
  assert_lookalikes_allowed run_bash
  assert_lookalikes_allowed run_monitor
  assert_recorder_run_denied_and_staging_allowed run_bash
  assert_recorder_run_denied_and_staging_allowed run_monitor
}

# --- the shared payload reader ---

@test "a missing lib/hook-payload.sh refuses a write to the state path rather than allowing the call" {
  local scratch_directory="$BATS_TEST_TMPDIR/no-payload-lib"
  mkdir -p "$scratch_directory"
  cp -R "$HOOKS_SOURCE_DIRECTORY/lib" "$scratch_directory/lib"
  rm -f "$scratch_directory/lib/hook-payload.sh"
  cp "$HOOKS_SOURCE_DIRECTORY/block-audit-loop-write.sh" "$scratch_directory/"
  invoke_hook "$(edit_payload Write "$STATE" "$MAIN")" "$scratch_directory/block-audit-loop-write.sh"
  [ "$status" -eq 2 ]
  grep -qF -- 'cannot load lib/hook-payload.sh' <<<"$output"
}

@test "an ordinary Bash call runs no jq at all" {
  local shim_directory="$BATS_TEST_TMPDIR/shim" real_jq
  real_jq=$(command -v jq)
  mkdir -p "$shim_directory"
  printf '#!/usr/bin/env bash\nprintf "jq\\n" >> "%s/calls.log"\nexec "%s" "$@"\n' "$BATS_TEST_TMPDIR" "$real_jq" >"$shim_directory/jq"
  chmod +x "$shim_directory/jq"
  PATH="$shim_directory:$PATH" invoke_hook "$(command_payload Bash "ls -la" "$MAIN")" "$HOOK_ABSOLUTE_PATH"
  assert_allowed_by_json
  [ ! -s "$BATS_TEST_TMPDIR/calls.log" ]
}
