#!/usr/bin/env bats

# Tests for .claude/hooks/block-eslint-config-edit.sh.
#
# The guard protects eslint.config.{js,cjs,mjs,ts} at any path, and what
# it does on a match is ASK: every edit to the file prompts the operator,
# whatever the edit does. So the suite has two halves and neither is decoration.
#
# The first half is the path gate, which is the only thing that decides anything:
# a file that is not an eslint config passes silently, every guarded extension at
# every depth asks. It is pinned in both directions on purpose. The pattern's
# `(^|/)` boundary is what keeps an ordinary source file named
# `my-eslint.config.mjs` out of the prompt, a dimension no fixture varies unless
# one is written for it.
#
# The second half is the ask itself: the operator is asked precisely because the
# hook cannot tell the legitimate edit from the silencing one, so the answer is
# theirs to give and the hook never rules on an edit either way.
#
# The ask cases below deliberately include both extremes, a comment-only change
# and a whole-file replacement, an added bare preset spread and an added rule
# override. They are the cases where a guard that started judging edits again
# would first diverge, and judging is what this hook exists not to do: the
# legitimate shape and the silencing shape are the same shape, so the uniform ask
# is the contract rather than a coarse approximation of one.
#
# shellcheck disable=SC2016
# SC2016 (expressions don't expand in single quotes) fires on the `$` inside
# fixture identifiers and on `${...}` inside fixture config bodies. Not
# expanding is the point: a fixture has to reach the hook as the literal text a
# real edit would carry. (Keep the word "shellcheck" off the start of a comment
# line here; it is parsed as a directive there.)

setup() {
  . "$BATS_TEST_DIRNAME/helpers/run-hook.sh"
  HOOKS_SOURCE_DIRECTORY=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)
  HOOK_ABSOLUTE_PATH="$HOOKS_SOURCE_DIRECTORY/block-eslint-config-edit.sh"
  TEMPORARY_DIRECTORY=$(mktemp -d "${BATS_TMPDIR:-/tmp}/eslint-hook.XXXXXX")
}

teardown() {
  [ -n "${TEMPORARY_DIRECTORY:-}" ] && rm -rf "$TEMPORARY_DIRECTORY"
  return 0
}

# A realistic config: a header block comment, bare spreads, a called preset, and
# an overrides object with a rules block. Every fixture below edits this.
DEFAULT_BODY="import gaiaLint from '@gaia-react/lint';
import {defineConfig} from 'eslint/config';

/*
 * Config for the app. It OMITS the presets the app does not use
 * (storybook, playwright, betterTailwind).
 */
const lint = gaiaLint();

export default defineConfig([
  ...lint.ignores({extra: ['dist/**']}),
  ...lint.base,
  ...lint.react,
  ...lint.guardrails,
  ...lint.prettier,
  {
    name: 'app/overrides',
    // why this rule is off
    rules: {'no-console': 'off'},
  },
]);"

# Writes a config to the temp dir and echoes its path. Takes an optional body.
write_config_fixture() {
  local name="${2:-eslint.config.mjs}"
  printf '%s\n' "${1:-$DEFAULT_BODY}" >"$TEMPORARY_DIRECTORY/$name"
  printf '%s' "$TEMPORARY_DIRECTORY/$name"
}

# The fixtures here carry quotes of their own, so delivery goes through
# `invoke_hook` (helpers/run-hook.sh), which passes the payload positionally.
run_hook() {
  invoke_hook "$1" "$HOOK_ABSOLUTE_PATH"
}

run_edit() {
  run_hook "$(jq -n --arg file_path "$1" --arg old_string "$2" --arg new_string "$3" \
    '{tool_name: "Edit", tool_input: {file_path: $file_path, old_string: $old_string, new_string: $new_string}}')"
}

run_write() {
  run_hook "$(jq -n --arg file_path "$1" --arg content "$2" \
    '{tool_name: "Write", tool_input: {file_path: $file_path, content: $content}}')"
}

# For the shapes run_edit/run_write cannot express: a MultiEdit's edits[], and
# the malformed payloads whose whole point is a missing field. Takes the
# tool_input as a JSON literal, so a `\n` in a fixture is a real newline by the
# time the hook reads it.
run_tool() {
  run_hook "$(jq -n --arg tool_name "$1" --argjson tool_input "$2" '{tool_name: $tool_name, tool_input: $tool_input}')"
}

# --- path gate, the only thing that decides anything ------------------------

@test "a file that is not the guarded config is allowed" {
  local row name old new
  local rows=(
    "home.tsx|const a = 1;|const a = 2;"
    "eslint.config.md|rules: {}|rules: {a: 'off'}"
    "my-eslint.config.mjs|const a = 1;|const a = 2;"
    "eslint.config.mjs.bak|const a = 1;|const a = 2;"
  )
  for row in "${rows[@]}"; do
    echo "case: $row"
    IFS='|' read -r name old new <<<"$row"
    run_edit "$(write_config_fixture "$old" "$name")" "$old" "$new"
    assert_allowed_by_exit
  done
}

# This fixture is pinned between two limits that pull in opposite directions,
# and it is the only test here that cannot use the shared helpers. Both
# constraints are load-bearing; satisfying one alone breaks it.
#
# It must be FAR ABOVE the pipe boundary. What it pins is a pipe fail-open, so
# the shape only reproduces past pipe capacity (65536) plus whatever the reader
# drains before exiting, and that second term is a property of the grep
# implementation rather than a constant: it moves by kilobytes between the two
# greps on one macOS host, and CI runs a third. A fixture tuned just above the
# local boundary passes with the defect fully restored on any reader that
# buffers more.
#
# It must also NEVER TRAVEL THROUGH ARGV, which is the constraint that bites as
# soon as the first one is satisfied. Linux caps a single execve argument at
# MAX_ARG_STRLEN, 32 pages (131072 bytes), independently of ARG_MAX, so a
# megabyte-scale payload handed to `jq --arg` never execs at all: jq dies E2BIG,
# the substitution yields nothing, the hook reads empty stdin and exits 0, and
# the test fails on the platform CI runs while passing on macOS, which has no
# per-string cap. That is a kernel limit rather than a bash-version gap, so the
# bash-5 pre-flight cannot see it either.
#
# So the payload is assembled into files and reaches jq by --rawfile and the
# hook by stdin redirection, crossing no argv boundary at any size.
@test "asks on a guarded path arriving with megabytes of trailing payload" {
  { printf '%s\n' "$(write_config_fixture)"; head -c 1000000 /dev/zero | tr '\0' 'x'; } >"$TEMPORARY_DIRECTORY/path.txt"
  jq -n --rawfile file_path "$TEMPORARY_DIRECTORY/path.txt" \
    '{tool_name: "Edit", tool_input: {file_path: $file_path, old_string: "a", new_string: "b"}}' \
    >"$TEMPORARY_DIRECTORY/payload.json"
  run bash -c 'bash "$2" <"$1"' _ "$TEMPORARY_DIRECTORY/payload.json" "$HOOK_ABSOLUTE_PATH"
  assert_asked_by_json
}

# Every other fixture builds its path under $TEMPORARY_DIRECTORY, so all of them carry a slash
# and only the `/` half of the pattern's `(^|/)` gets exercised. Without this
# case, narrowing the group to `(/)` is undetected.
@test "guards a config named with no directory component at all" {
  run_tool Edit '{"file_path": "eslint.config.mjs", "old_string": "a", "new_string": "b"}'
  assert_asked_by_json
}

@test "guards every extension ESLint resolves, at any depth" {
  mkdir -p "$TEMPORARY_DIRECTORY/apps/web"
  for name in eslint.config.js eslint.config.cjs eslint.config.mjs eslint.config.ts \
    apps/web/eslint.config.mjs; do
    run_edit "$(write_config_fixture "$DEFAULT_BODY" "$name")" '  ...lint.react,' "  ...lint.react,
  rules: {'no-empty-pattern': 'off'},"
    [ "$status" -eq 0 ] || return 1
    grep -qF -- '"permissionDecision": "ask"' <<<"$output" || return 1
  done
}

# --- the ask is uniform, across every shape a judging guard would split -----

@test "every edit of a guarded config asks, whatever it changes" {
  local row
  local rows=(
    reactRouter-migration comment-only blank-line-only write-comment-only
    multiedit-comment-and-spread remove-preset-spread write-whole-config
  )
  for row in "${rows[@]}"; do
    echo "case: $row"
    case "$row" in
      reactRouter-migration)
        run_edit "$(write_config_fixture)" '  ...lint.react,' '  ...lint.react,
  ...lint.reactRouter,'
        ;;
      comment-only)
        run_edit "$(write_config_fixture)" ' * Config for the app.' ' * ESLint config for the app.'
        ;;
      blank-line-only)
        run_edit "$(write_config_fixture)" "const lint = gaiaLint();

export default" "const lint = gaiaLint();


export default"
        ;;
      write-comment-only)
        run_write "$(write_config_fixture)" "${DEFAULT_BODY/Config for the app./ESLint config for the app.}"
        ;;
      multiedit-comment-and-spread)
        run_tool MultiEdit "$(jq -n --arg file_path "$(write_config_fixture)" \
          '{file_path: $file_path,
            edits: [{old_string: " * Config for the app.", new_string: " * ESLint config."},
                    {old_string: "  ...lint.react,", new_string: "  ...lint.react,\n  ...lint.reactRouter,"}]}')"
        ;;
      remove-preset-spread)
        run_edit "$(write_config_fixture)" '  ...lint.guardrails,
' ''
        ;;
      write-whole-config)
        run_write "$(write_config_fixture)" 'export default [];'
        ;;
    esac
    assert_asked_by_json
  done
}

# --- including the shapes that are usually silencing, so the floor is pinned -

# bats test_tags=protected
@test "asks on adding a rule override" {
  run_edit "$(write_config_fixture)" "    rules: {'no-console': 'off'}," \
    "    rules: {'no-console': 'off', 'no-empty-pattern': 'off'},"
  assert_asked_by_json
}

@test "the reason keeps pointing at the source file for the common case" {
  run_edit "$(write_config_fixture)" "    rules: {'no-console': 'off'}," \
    "    rules: {'no-console': 'off', 'no-empty-pattern': 'off'},"
  assert_asked_by_json
  grep -qF -- 'source file where it occurs' <<<"$output"
}

@test "an unreadable shape on a guarded path asks" {
  local row
  local rows=(other-tool-shape edit-without-strings write-to-new-file)
  for row in "${rows[@]}"; do
    echo "case: $row"
    case "$row" in
      other-tool-shape)
        run_tool NotebookEdit "$(jq -n --arg file_path "$(write_config_fixture)" '{file_path: $file_path}')"
        ;;
      edit-without-strings)
        run_tool Edit "$(jq -n --arg file_path "$(write_config_fixture)" '{file_path: $file_path}')"
        ;;
      write-to-new-file)
        run_write "$TEMPORARY_DIRECTORY/eslint.config.ts" 'export default [];'
        ;;
    esac
    assert_asked_by_json
  done
}

# The hook never rules on a config edit, in either direction. Asserting the ask
# positively does not pin this: a hook that emitted BOTH an ask and a deny, or
# that regressed to the exit-2 contract while still printing an ask, satisfies
# every test above. The two failure directions are opposite, so they are pinned
# separately.
@test "never denies a config edit, and never blocks by exit code" {
  run_edit "$(write_config_fixture)" "    rules: {'no-console': 'off'}," \
    "    rules: {'no-console': 'off', 'no-empty-pattern': 'off'},"
  [ "$status" -eq 0 ]
  grep -qF -- '"permissionDecision": "deny"' <<<"$output" && return 1
  true
}

# The decision is machine-read, so a reason string that broke out of the JSON
# would take the whole decision with it and the hook would report nothing at
# all, which is the fail-open direction. `jq -n --arg` is what guarantees this;
# a hand-built JSON string is the shape that loses it.
@test "emits one well-formed JSON object a parser accepts" {
  run_edit "$(write_config_fixture)" ' * Config for the app.' ' * ESLint config.'
  [ "$status" -eq 0 ]
  jq -e '.hookSpecificOutput.hookEventName == "PreToolUse"' <<<"$output" >/dev/null
}

# --- a payload naming no file cannot be judged, and is not an exemption -----

@test "a payload without a readable file path exits zero" {
  local row
  local rows=(no-file-path not-json)
  for row in "${rows[@]}"; do
    echo "case: $row"
    case "$row" in
      no-file-path) run_tool Edit '{"old_string": "a", "new_string": "b"}' ;;
      not-json) run_hook 'not json at all' ;;
    esac
    assert_allowed_by_exit
  done
}
