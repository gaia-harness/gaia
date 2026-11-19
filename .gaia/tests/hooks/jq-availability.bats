#!/usr/bin/env bats

# Tests for .claude/hooks/lib/jq-availability.sh as the PreToolUse layer runs
# it: every blocking hook driven with jq off PATH, against a payload inside its
# remit and, where the hook carries binding literals, one outside it.
#
# The suite is per-layer rather than per-hook because the claim is a property of
# the layer: with no jq on PATH the fail-closed hooks refuse and the advisory
# ones stand down. A copy of these two assertions in each hook's own suite would
# be one place per hook for the claim to drift, and the arm they all reach is
# one function.
#
# WHAT A FAILURE HERE MEANS. The hook read its payload with jq under errexit and
# died at status 127, which the PreToolUse contract reads as a NON-BLOCKING
# error: the call it was written to deny proceeded, with no denial and no
# diagnostic. That is the defect the arm exists to close, and a green run of the
# hook's own suite says nothing about it, because every other test in those
# suites runs with jq present.
#
# Run under bash 5: `bash .gaia/scripts/bats5.sh .gaia/tests/hooks/jq-availability.bats`.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  . "$BATS_TEST_DIRNAME/helpers/run-hook.sh"
  . "$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)/.gaia/tests/helpers/path.sh"
  HOOKS_SOURCE_DIRECTORY=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)
}

# The mirroring rebuild rather than the dropping one: jq shares a directory with
# the bash, grep and cat both the hooks and these assertions still need, so
# dropping the directory would take them too (.gaia/tests/helpers/path.sh).
scrub_jq_from_path() {
  local rebuilt
  rebuilt="$(path_shim_without jq)"
  export PATH="$rebuilt"
}

# without_jq <hook-basename> <payload>
#
# The payload is built by the caller while jq is still reachable; only the hook
# runs without it.
without_jq() {
  scrub_jq_from_path
  [ -z "$(command -v jq)" ]
  invoke_hook "$2" "$HOOKS_SOURCE_DIRECTORY/$1"
}

# THE AMBIENT FIELDS ARE THE POINT, not padding. A PreToolUse payload carries
# session_id, transcript_path and cwd ahead of tool_input, and every one of the
# three is a filesystem path nobody chose for this purpose. The two below are
# built to carry every binding literal any hook here passes, as a substring, in a
# path shape a real machine could have: a "platform" directory supplies the rm
# literal, a "git-svc" one the git literal, a ".venv" the env literal, a
# "settings" the process-dump literal, a "highlights" one the gh literal, an
# "org-mirror" one the rg literal, a "ripgrep" checkout the grep literal, a
# "storage" one the ag literal, and so on down to .pem, .key and manifest.json.
# Read each of those as the contiguous run it has to be: `.github` spells no
# `gh` and `ripgrep` spells no `rg`, and a segment chosen for how it looks
# rather than for what it contains leaves the tests below unable to fail.
#
# So an arm matching its literals against the whole document denies every
# still-allowed case below, the jq install among them, which is the session with
# no way out the literals exist to prevent, reached by the mechanism meant to
# prevent it. These builders are what make that a red rather than a green.
readonly AMBIENT_CWD="/Users/you/work/platform/git-svc/highlights/org-mirror/ripgrep/storage/.venv/settings/test-credentials/secrets"
readonly AMBIENT_TRANSCRIPT="/Users/you/.claude/projects/gaia-plan/manifest.json.d/server.pem/id.key/plan.md.log"

# The key order mirrors the harness: every ambient field precedes tool_input.
ambient() {
  jq -n --arg c "$AMBIENT_CWD" --arg t "$AMBIENT_TRANSCRIPT" \
    '{session_id: "0193-fixture", transcript_path: $t, cwd: $c, hook_event_name: "PreToolUse"}'
}

# The Bash tool's tool_input carries a model-authored `description` beside the
# command, and no caller predicate reads it, so it is the same class of field as
# the ambient head one level deeper. This one carries every literal any
# Bash-matcher caller passes -- "Confirm" holds rm, "latest" holds test,
# "environment" holds env, "setup" holds the dump spelling -- so an arm that
# stops cutting it denies the jq install on the wording of its own description.
readonly AMBIENT_DESCRIPTION="Confirm the latest environment setup, gitignore and permissions"

bash_payload() {
  jq -n --argjson a "$(ambient)" --arg c "$1" --arg d "$AMBIENT_DESCRIPTION" \
    '$a + {tool_name: "Bash", tool_input: {command: $c, description: $d}}'
}

# The same fields with the two tool_input keys swapped. No session produces this
# order today -- which is exactly why it needs a builder: the arm's description
# cut must not depend on an emission order GAIA does not control, and the
# command-first builder above pins nothing about the other order.
#
# Both claims the command-first pair makes are re-made against it, and each
# catches a different way the cut can go wrong. The refusal catches a cut that
# takes the command out of the haystack along with the description, which is the
# fail-open direction on the guard whose purpose is to close it. The allow
# catches a cut that gives up and leaves the description in the haystack, which
# denies the jq install on the wording of its own description: the session with
# no way out from inside it.
bash_payload_description_first() {
  jq -n --argjson a "$(ambient)" --arg c "$1" --arg d "$AMBIENT_DESCRIPTION" \
    '$a + {tool_name: "Bash", tool_input: {description: $d, command: $c}}'
}

edit_payload() {
  jq -n --argjson a "$(ambient)" --arg p "$1" \
    '$a + {tool_name: "Edit", tool_input: {file_path: $p, new_string: "x"}}'
}

# The command that repairs the machine. Every literal set below is checked
# against it, because a hook whose refusal catches this one leaves the session
# with no way out from inside it.
readonly INSTALL_COMMAND="brew install jq"

# The Agent payload keeps the harness key order: ambient head first, then the
# tool call. The bound hook's binding literal is the member-name prefix, which
# no ambient path carries.
agent_payload() {
  jq -n --argjson a "$(ambient)" --arg s "$1" \
    '$a + {tool_name: "Agent", tool_input: {subagent_type: $s}}'
}

write_payload() {
  jq -n --argjson a "$(ambient)" --arg p "$1" \
    '$a + {tool_name: "Write", tool_input: {file_path: $p, content: "x"}}'
}

read_payload() {
  jq -n --arg p "$1" '{tool_name: "Read", tool_input: {file_path: $p}}'
}

# row_payload <kind> <argument>: builds the payload while jq is still on PATH.
row_payload() {
  case "$1" in
    edit) edit_payload "$2" ;;
    bash) bash_payload "$2" ;;
    bash-description-first) bash_payload_description_first "$2" ;;
    read) read_payload "$2" ;;
    agent) agent_payload "$2" ;;
    write) write_payload "$2" ;;
  esac
}

# A hook whose matcher cannot reach the jq install refuses unconditionally.
# One whose matcher can refuses only its in-remit call: its refusal row below
# and its allow row in the next test are together the whole claim.

# Rows are label|hook|payload kind|argument|refusal text the output must carry.
# A row naming a refusal text also asserts its payload never spells audit-loop,
# so the protected folder is armed by the `local/protected` literal alone and an
# omitted literal would exit 0 there.
@test "with jq absent these blocking hooks refuse: dotenv edit, eslint config edit, app/foo.ts edit, dotenv read, force push to main, --no-verify, manifest write, rm -rf /, key path read, description-first dotenv read, member dispatch, audit-loop state write, new protected-folder file, protected-folder redirect, gh pr merge" {
  local original_path="$PATH" row label hook kind argument needle json
  for row in \
    "secrets-write|block-secrets-write.sh|edit|.env.local|" \
    "eslint-config|block-eslint-config-edit.sh|edit|eslint.config.ts|" \
    "worktree-path-mismatch|block-worktree-path-mismatch.sh|edit|app/foo.ts|" \
    "sensitive-read-dotenv|block-sensitive-read.sh|bash|cat .env.local|" \
    "main-destructive-git|block-main-destructive-git.sh|bash|git push --force origin main|" \
    "no-verify|block-no-verify.sh|bash|git commit --no-verify -m x|" \
    "manifest-write|block-manifest-write.sh|edit|.gaia/manifest.json|" \
    "rm-rf|block-rm-rf.sh|bash|rm -rf /|" \
    "sensitive-read-key-path|block-sensitive-read.sh|read|certs/server.pem|" \
    "sensitive-read-description-first|block-sensitive-read.sh|bash-description-first|cat .env.local|" \
    "audit-loop-bound|audit-loop-bound.sh|agent|code-audit-frontend|" \
    "audit-loop-write-state|block-audit-loop-write.sh|write|.gaia/local/protected/audit-loop/state.json|" \
    "audit-loop-write-new-file|block-audit-loop-write.sh|write|/Users/you/work/repo/.gaia/local/protected/new-state.json|cannot be checked" \
    "audit-loop-write-redirect|block-audit-loop-write.sh|bash|printf x > /Users/you/work/repo/.gaia/local/protected/new-state.json|cannot be checked" \
    "pr-merge-audit-check|pr-merge-audit-check.sh|bash|gh pr merge 42 --squash|" \
    "worthiness-presence-check|worthiness-presence-check.sh|bash|gh pr merge 42 --squash|"; do
    IFS='|' read -r label hook kind argument needle <<<"$row"
    PATH="$original_path"
    json=$(row_payload "$kind" "$argument")
    if [ -n "$needle" ]; then
      grep -qF -- 'audit-loop' <<<"$json" && { echo "case $label: payload names audit-loop"; return 1; }
    fi
    without_jq "$hook" "$json"
    [ "$status" -eq 2 ] || { echo "case $label: status=$status output=$output"; return 1; }
    grep -qF -- 'BLOCKED' <<<"$output" || { echo "case $label: no BLOCKED in $output"; return 1; }
    if [ -n "$needle" ]; then
      grep -qF -- "$needle" <<<"$output" || { echo "case $label: no '$needle' in $output"; return 1; }
    fi
  done
}

@test "with jq absent the narrowed hooks still allow: the jq install, a manifest-free edit, a README read, a non-member dispatch, an unrelated write" {
  local original_path="$PATH" row label hook kind argument json
  for row in \
    "sensitive-read-install|block-sensitive-read.sh|bash|$INSTALL_COMMAND" \
    "main-destructive-git-install|block-main-destructive-git.sh|bash|$INSTALL_COMMAND" \
    "no-verify-install|block-no-verify.sh|bash|$INSTALL_COMMAND" \
    "manifest-write-no-manifest|block-manifest-write.sh|edit|app/foo.ts" \
    "rm-rf-install|block-rm-rf.sh|bash|$INSTALL_COMMAND" \
    "sensitive-read-no-secret-class|block-sensitive-read.sh|read|README.md" \
    "sensitive-read-install-description-first|block-sensitive-read.sh|bash-description-first|$INSTALL_COMMAND" \
    "audit-loop-bound-no-member|audit-loop-bound.sh|agent|general-purpose" \
    "audit-loop-write-install|block-audit-loop-write.sh|bash|$INSTALL_COMMAND" \
    "audit-loop-write-unrelated|block-audit-loop-write.sh|write|app/foo.ts" \
    "pr-merge-audit-check-install|pr-merge-audit-check.sh|bash|$INSTALL_COMMAND" \
    "worthiness-presence-check-install|worthiness-presence-check.sh|bash|$INSTALL_COMMAND"; do
    IFS='|' read -r label hook kind argument <<<"$row"
    PATH="$original_path"
    json=$(row_payload "$kind" "$argument")
    without_jq "$hook" "$json"
    [ "$status" -eq 0 ] || { echo "case $label: status=$status output=$output"; return 1; }
    [ -z "$output" ] || { echo "case $label: unexpected output $output"; return 1; }
  done
}

# The grant hook runs on UserPromptSubmit, so its payload carries that head and
# a prompt rather than a tool call. The ambient path noise stays in cwd and
# transcript_path.
grant_payload() {
  jq -n --arg c "$AMBIENT_CWD" --arg t "$AMBIENT_TRANSCRIPT" --arg p "$1" \
    '{session_id: "0193-fixture", transcript_path: $t, cwd: $c, hook_event_name: "UserPromptSubmit", prompt: $p}'
}

state_listing() {
  local audit_loop_directory
  audit_loop_directory="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)/.gaia/local/protected/audit-loop"
  if [ -d "$audit_loop_directory" ]; then
    # gaia-lint-ignore whole-tree-mark-guard: the operand is the untracked local audit-loop state directory, not the tracked tree
    find "$audit_loop_directory" -print | sort
  fi
  true
}

@test "jq absent: audit-loop-grant says so and records nothing for a grant line, stays silent for a prompt without the keyword" {
  local original_path="$PATH" json before after
  json=$(grant_payload "audit-grant 2")
  before=$(state_listing)
  without_jq audit-loop-grant.sh "$json"
  after=$(state_listing)
  [ "$status" -eq 0 ] || { echo "case grant-line: status=$status output=$output"; return 1; }
  grep -qF -- 'jq is missing' <<<"$output" || { echo "case grant-line: no 'jq is missing' in $output"; return 1; }
  [ "$before" = "$after" ] || { echo "case grant-line: state changed"; return 1; }

  PATH="$original_path"
  json=$(grant_payload "please continue")
  without_jq audit-loop-grant.sh "$json"
  [ "$status" -eq 0 ] || { echo "case no-keyword: status=$status output=$output"; return 1; }
  [ -z "$output" ] || { echo "case no-keyword: unexpected output $output"; return 1; }
}

# --- the arm's own library is unreachable ------------------------------------

@test "a mis-arity call refuses rather than dying at a non-blocking status" {
  # A caller that omits an argument would expand an unset positional under the
  # errexit-and-nounset every armed hook arms, ending it at status 1, which
  # PreToolUse reads as a NON-BLOCKING error: the same fail-open a missing call
  # produces, reached by a different edit. The arm checks its own arity so a
  # wrong call is loud.
  local library_path
  library_path="$HOOKS_SOURCE_DIRECTORY/lib/jq-availability.sh"
  run bash -c 'set -euo pipefail; . "$1"; gaia_require_jq "only one arg"' _ "$library_path"
  [ "$status" -eq 2 ]
  grep -qF -- 'BLOCKED' <<<"$output"
  grep -qF -- 'needs at least 3' <<<"$output"
}

@test "the library missing refuses too, rather than running the hook unguarded" {
  # A hook resolves the library from its own on-disk location, so a copy in a
  # tree with an empty lib/ reproduces a broken install without touching the
  # real one. jq stays on PATH here: the claim is about the load, not about the
  # interpreter.
  local scratch_directory json
  scratch_directory="$BATS_TEST_TMPDIR/no-lib"
  mkdir -p "$scratch_directory/lib"
  cp "$HOOKS_SOURCE_DIRECTORY/block-eslint-config-edit.sh" "$scratch_directory/block-eslint-config-edit.sh"

  json=$(edit_payload "eslint.config.ts")
  invoke_hook "$json" "$scratch_directory/block-eslint-config-edit.sh"
  [ "$status" -eq 2 ]
  grep -qF -- 'cannot load lib/jq-availability.sh' <<<"$output"
}
