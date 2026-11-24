#!/usr/bin/env bats

# Security test for the per-session rate-limit reading arm of
# .claude/hooks/block-audit-loop-write.sh.
#
# The statusline writes each session's reading and the dispatch checkpoint hook writes its
# marker, and the dispatch checkpoint trusts both; the 7-day bands
# trust the plan tier in the account profile. A session's own tools must not
# write, move, delete or forge a reading or a marker, run the CLI's write verb,
# or change the tier. The guard refuses the natural spellings and allows
# reading. Piping a crafted payload into the statusline script is a stated
# residual the guard does not read.

setup() {
  . "$BATS_TEST_DIRNAME/helpers/run-hook.sh"
  HOOKS_SOURCE_DIRECTORY=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)
  HOOK_ABSOLUTE_PATH="${HOOK_UNDER_TEST:-$HOOKS_SOURCE_DIRECTORY/block-audit-loop-write.sh}"

  FIX=$(cd "$(mktemp -d "$BATS_TEST_TMPDIR/fix.XXXXXX")" && pwd -P)
  MAIN="$FIX/main"
  WORKTREE="$FIX/wt"
  mkdir -p "$MAIN"
  git -C "$MAIN" init -q -b main
  git -C "$MAIN" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m init
  git -C "$MAIN" worktree add -q "$WORKTREE" -b feat
  mkdir -p "$MAIN/.gaia/local/cache/shared/rate-limits" "$MAIN/.gaia/local/cache/rate-limit-checkpoint" "$WORKTREE/.gaia"
  ln -s "$MAIN/.gaia/local" "$WORKTREE/.gaia/local"
  SESSION_ID='0b8f4c1e-5d2a-4e6f-9a3b-7c1d2e3f4a5b'
  FOLDER_RELATIVE='.gaia/local/cache/shared/rate-limits'
  READING_RELATIVE="$FOLDER_RELATIVE/$SESSION_ID.json"
  MARKER_FOLDER_RELATIVE='.gaia/local/cache/rate-limit-checkpoint'
  MARKER_RELATIVE="$MARKER_FOLDER_RELATIVE/$SESSION_ID"
  LEGACY_RELATIVE='.gaia/local/cache/shared/rate-limits.json'
  WRITE_JSON='{"source":"statusline","five_hour":{"used_percentage":1}}'
  PROFILE="$FIX/home/.claude.json"
  TIER_TEXT='{"oauthAccount":{"organizationRateLimitTier":"default_claude_max_20x"}}'
}

edit_payload() {
  jq -n --arg tool_name "$1" --arg file_path "$2" --arg cwd "$3" '{tool_name: $tool_name, cwd: $cwd, tool_input: {file_path: $file_path}}'
}

edit_text_payload() {
  jq -n --arg tool_name "$1" --arg file_path "$2" --arg text "$3" --arg cwd "$MAIN" '
    {tool_name: $tool_name, cwd: $cwd, tool_input:
      (if $tool_name == "Write" then {file_path: $file_path, content: $text}
       elif $tool_name == "Edit" then {file_path: $file_path, old_string: "a", new_string: $text}
       else {file_path: $file_path, edits: [{old_string: "a", new_string: "b"}, {old_string: "c", new_string: $text}]} end)}'
}

command_payload() {
  jq -n --arg tool_name "$1" --arg command "$2" --arg cwd "$3" '{tool_name: $tool_name, cwd: $cwd, tool_input: {command: $command}}'
}

# Each case helper returns 1 on a wrong verdict, naming the case on stderr.
refuse_edit() {
  invoke_hook "$(edit_payload "$1" "$2" "$3")" "$HOOK_ABSOLUTE_PATH"
  assert_denied_by_json || { printf 'not denied: %s %s\n' "$1" "$2" >&2; return 1; }
}

refuse_text() {
  invoke_hook "$(edit_text_payload "$1" "$2" "$3")" "$HOOK_ABSOLUTE_PATH"
  assert_denied_by_json || { printf 'not denied: %s %s\n' "$1" "$3" >&2; return 1; }
}

allow_text() {
  invoke_hook "$(edit_text_payload "$1" "$2" "$3")" "$HOOK_ABSOLUTE_PATH"
  assert_allowed_by_json || { printf 'not allowed: %s %s\n' "$1" "$3" >&2; return 1; }
}

refuse_command() {
  invoke_hook "$(command_payload "$1" "$2" "$MAIN")" "$HOOK_ABSOLUTE_PATH"
  assert_denied_by_json || { printf 'not denied: %s %s\n' "$1" "$2" >&2; return 1; }
}

allow_command() {
  invoke_hook "$(command_payload Bash "$1" "$MAIN")" "$HOOK_ABSOLUTE_PATH"
  assert_allowed_by_json || { printf 'not allowed: %s\n' "$1" >&2; return 1; }
  [ -z "$output" ] || { printf 'allowed call printed output: %s\n' "$1" >&2; return 1; }
}

# A fresh `bash -c` with a scrubbed PATH holding only what the hook's jq-absent
# path needs; the payload is built (with jq) by the caller before this strips it.
run_without_jq() {
  local payload="$1" bin="$FIX/nojq-bin" tool_name
  mkdir -p "$bin"
  for tool_name in bash cat dirname tr; do
    ln -sf "$(command -v "$tool_name")" "$bin/$tool_name"
  done
  run /bin/bash -c 'PATH="$1"; printf %s "$2" | /bin/bash "$3"' _ "$bin" "$payload" "$HOOK_ABSOLUTE_PATH"
}

# bats test_tags=protected
@test "Claude cannot write, move or delete a reading or a marker, run the write verb or change the tier; reads stay allowed" {
  local tool command_line reason target

  # Edit tools over a reading, the folder, a marker and the legacy file, by the
  # main path and through the linked worktree's symlink.
  for target in "$READING_RELATIVE" "$FOLDER_RELATIVE" "$FOLDER_RELATIVE/" "$MARKER_RELATIVE" "$LEGACY_RELATIVE"; do
    for tool in Write Edit MultiEdit; do
      refuse_edit "$tool" "$MAIN/$target" "$MAIN" || return 1
      refuse_edit "$tool" "$WORKTREE/$target" "$WORKTREE" || return 1
    done
  done

  # Every deny for a reading names the readings folder.
  invoke_hook "$(edit_payload Write "$MAIN/$READING_RELATIVE" "$MAIN")" "$HOOK_ABSOLUTE_PATH"
  assert_denied_by_json
  reason=$(jq -r '.hookSpecificOutput.permissionDecisionReason // .reason // empty' <<<"$output")
  case "$reason" in
    *cache/shared/rate-limits/*) ;;
    *) printf 'wrong deny reason: %s\n' "$reason" >&2; return 1 ;;
  esac

  # Bash and Monitor spellings that write, move, delete or link a reading, a
  # marker or either folder, with and without a trailing slash, the write verb,
  # and the two ways to change the tier the bands follow.
  while IFS= read -r command_line; do
    refuse_command Bash "$command_line" || return 1
  done <<EOF2
echo '{}' > $READING_RELATIVE
mv /tmp/x $READING_RELATIVE
rm $READING_RELATIVE
rm -rf $MAIN/$FOLDER_RELATIVE
rm -rf $MAIN/$FOLDER_RELATIVE/
rm -rf $MAIN/$MARKER_FOLDER_RELATIVE
rm -rf $MAIN/$MARKER_FOLDER_RELATIVE/
rm $MARKER_RELATIVE
cp /tmp/x $READING_RELATIVE
echo '{}' | tee $READING_RELATIVE
sed -i 's/a/b/' $READING_RELATIVE
ln -s /tmp/x $MARKER_RELATIVE
echo '{}' > $LEGACY_RELATIVE
rm $LEGACY_RELATIVE
bash .gaia/scripts/rate-limits.sh write $SESSION_ID '$WRITE_JSON'
sh .gaia/scripts/rate-limits.sh write $SESSION_ID '$WRITE_JSON'
./.gaia/scripts/rate-limits.sh write $SESSION_ID '$WRITE_JSON'
exec .gaia/scripts/rate-limits.sh write $SESSION_ID '$WRITE_JSON'
source .gaia/scripts/rate-limits.sh write $SESSION_ID '$WRITE_JSON'
CLAUDE_CONFIG_DIR=/tmp/x bash .gaia/scripts/rate-limits.sh read
export CLAUDE_CONFIG_DIR=/tmp/x; bash .gaia/scripts/rate-limits.sh read
env CLAUDE_CONFIG_DIR=/tmp/x bash .gaia/scripts/rate-limits.sh read
echo '$TIER_TEXT' > $PROFILE
EOF2
  refuse_command Monitor "rm $READING_RELATIVE" || return 1

  # Through a linked worktree's symlink.
  invoke_hook "$(command_payload Bash "rm -rf $WORKTREE/$FOLDER_RELATIVE" "$WORKTREE")" "$HOOK_ABSOLUTE_PATH"
  assert_denied_by_json || return 1
  invoke_hook "$(command_payload Bash "rm $WORKTREE/$MARKER_RELATIVE" "$WORKTREE")" "$HOOK_ABSOLUTE_PATH"
  assert_denied_by_json || return 1

  # The tier: a new text naming it, written to a .claude.json by any edit tool.
  for tool in Write Edit MultiEdit; do
    refuse_text "$tool" "$PROFILE" "$TIER_TEXT" || return 1
  done

  # Reading is allowed, and so are an unrelated .claude.json edit and a
  # read-only jq of the tier.
  while IFS= read -r command_line; do
    allow_command "$command_line" || return 1
  done <<EOF3
bash .gaia/scripts/rate-limits.sh read
cat $READING_RELATIVE
jq . $READING_RELATIVE
ls $FOLDER_RELATIVE
jq .oauthAccount.organizationRateLimitTier $PROFILE
printf '%s\n' 'the guard denies CLAUDE_CONFIG_DIR= before rate-limits.sh' > /tmp/findings-note.json
git commit -m 'deny CLAUDE_CONFIG_DIR=x before rate-limits.sh'
gh pr comment 1 --body 'CLAUDE_CONFIG_DIR=x then rate-limits.sh is denied'
grep -n CLAUDE_CONFIG_DIR= .gaia/scripts/rate-limits.sh
EOF3
  for tool in Write Edit MultiEdit; do
    allow_text "$tool" "$PROFILE" '{"mcpServers":{"example":{"command":"x"}}}' || return 1
  done

  # Stated residual: a payload piped into the statusline is outside the guard.
  allow_command "echo '$WRITE_JSON' | .gaia/statusline/gaia-statusline.sh" || return 1

  # With jq absent the guard still allows the read and refuses every payload
  # carrying one of the guarded literals (exit 2).
  run_without_jq "$(command_payload Bash 'bash .gaia/scripts/rate-limits.sh read' "$MAIN")"
  [ "$status" -eq 0 ] || { printf 'jq absent: read not allowed (status %s)\n' "$status" >&2; return 1; }
  [ -z "$output" ] || { printf 'jq absent: read printed output: %s\n' "$output" >&2; return 1; }
  while IFS= read -r command_line; do
    run_without_jq "$(command_payload Bash "$command_line" "$MAIN")"
    [ "$status" -eq 2 ] || { printf 'jq absent: not refused (status %s): %s\n' "$status" "$command_line" >&2; return 1; }
  done <<EOF4
bash .gaia/scripts/rate-limits.sh write $SESSION_ID '$WRITE_JSON'
rm -rf $MAIN/$FOLDER_RELATIVE
rm -rf $MAIN/$MARKER_FOLDER_RELATIVE
rm $MARKER_RELATIVE
CLAUDE_CONFIG_DIR=/tmp/x bash .gaia/scripts/rate-limits.sh read
echo '$TIER_TEXT' > $PROFILE
EOF4
  true
}
