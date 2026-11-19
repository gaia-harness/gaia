#!/usr/bin/env bats

# Security test for the shared rate-limit reading arm of
# .claude/hooks/block-audit-loop-write.sh.
#
# The statusline writes the shared reading on each render and the dispatch
# checkpoint trusts it, so a session's own tools must not write, move, delete
# or forge it. The guard refuses the natural spellings (Write, Edit, MultiEdit,
# a Bash or Monitor redirect or write verb naming the file, and running the CLI
# with the write verb) and allows reading. Piping a crafted payload into the
# statusline script is a stated residual the guard does not read.

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
  mkdir -p "$MAIN/.gaia/local/cache/shared" "$WORKTREE/.gaia"
  ln -s "$MAIN/.gaia/local" "$WORKTREE/.gaia/local"
  SHARED_RELATIVE='.gaia/local/cache/shared/rate-limits.json'
  SHARED="$MAIN/$SHARED_RELATIVE"
  WORKTREE_SHARED="$WORKTREE/$SHARED_RELATIVE"
  WRITE_JSON='{"source":"statusline","five_hour":{"used_percentage":1}}'
  REASON_OPENING='BLOCKED: block-audit-loop-write.sh: the shared rate-limit reading (<main>/.gaia/local/cache/shared/rate-limits.json) is written by the statusline on each render'
}

edit_payload() {
  jq -n --arg tool_name "$1" --arg file_path "$2" --arg cwd "$3" '{tool_name: $tool_name, cwd: $cwd, tool_input: {file_path: $file_path}}'
}

command_payload() {
  jq -n --arg tool_name "$1" --arg command "$2" --arg cwd "$3" '{tool_name: $tool_name, cwd: $cwd, tool_input: {command: $command}}'
}

# Each case helper returns 1 on a wrong verdict, naming the case on stderr.
refuse_edit() {
  invoke_hook "$(edit_payload "$1" "$2" "$3")" "$HOOK_ABSOLUTE_PATH"
  assert_denied_by_json || { printf 'not denied: %s %s\n' "$1" "$2" >&2; return 1; }
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

@test "a session's own tools cannot write, move, delete or forge the shared rate-limit reading" {
  local tool command_line reason

  # Edit tools, by the main path and through the linked worktree's symlink.
  for tool in Write Edit MultiEdit; do
    refuse_edit "$tool" "$SHARED" "$MAIN" || return 1
    refuse_edit "$tool" "$WORKTREE_SHARED" "$WORKTREE" || return 1
  done

  # The deny names the shared rate-limit reading.
  invoke_hook "$(edit_payload Write "$SHARED" "$MAIN")" "$HOOK_ABSOLUTE_PATH"
  assert_denied_by_json
  reason=$(jq -r '.hookSpecificOutput.permissionDecisionReason // .reason // empty' <<<"$output")
  case "$reason" in
    "$REASON_OPENING"*) ;;
    *) printf 'wrong deny reason: %s\n' "$reason" >&2; return 1 ;;
  esac

  # Bash and Monitor spellings that write, move, delete or link the file.
  while IFS= read -r command_line; do
    refuse_command Bash "$command_line" || return 1
  done <<EOF2
echo '{}' > $SHARED_RELATIVE
mv /tmp/x $SHARED_RELATIVE
rm $SHARED_RELATIVE
cp /tmp/x $SHARED_RELATIVE
echo '{}' | tee $SHARED_RELATIVE
sed -i 's/a/b/' $SHARED_RELATIVE
ln -s /tmp/x $SHARED_RELATIVE
bash .gaia/scripts/rate-limits.sh write '$WRITE_JSON'
sh .gaia/scripts/rate-limits.sh write '$WRITE_JSON'
./.gaia/scripts/rate-limits.sh write '$WRITE_JSON'
exec .gaia/scripts/rate-limits.sh write '$WRITE_JSON'
source .gaia/scripts/rate-limits.sh write '$WRITE_JSON'
EOF2
  refuse_command Monitor "rm $SHARED_RELATIVE" || return 1

  # Reading is allowed.
  while IFS= read -r command_line; do
    allow_command "$command_line" || return 1
  done <<EOF3
bash .gaia/scripts/rate-limits.sh read
cat $SHARED_RELATIVE
jq . $SHARED_RELATIVE
EOF3

  # Stated residual: a payload piped into the statusline is outside the guard.
  allow_command "echo '$WRITE_JSON' | .gaia/statusline/gaia-statusline.sh" || return 1

  # With jq absent the guard still allows the read and refuses the write (exit 2).
  run_without_jq "$(command_payload Bash 'bash .gaia/scripts/rate-limits.sh read' "$MAIN")"
  [ "$status" -eq 0 ] || { printf 'jq absent: read not allowed (status %s)\n' "$status" >&2; return 1; }
  [ -z "$output" ] || { printf 'jq absent: read printed output: %s\n' "$output" >&2; return 1; }
  run_without_jq "$(command_payload Bash "bash .gaia/scripts/rate-limits.sh write '$WRITE_JSON'" "$MAIN")"
  [ "$status" -eq 2 ] || { printf 'jq absent: write not refused (status %s)\n' "$status" >&2; return 1; }
  true
}
