#!/usr/bin/env bash
# PreToolUse hook (AskUserQuestion, Edit, Write, MultiEdit, NotebookEdit,
# Bash, Monitor): while the autonomy switch is live, deny every
# AskUserQuestion with what to do instead, and deny every write to a file that
# governs the harness itself. With the switch off it allows everything and
# says nothing.
#
# WHY DENY. An unattended run has nobody to answer a question, so the call
# would stall the run; a denial reaches Claude at once with the answer or the
# park command. A denied call never reaches PostToolUse, so
# audit-loop-ask-grant.sh records no grant from it.
#
# ASKUSERQUESTION. In this order:
#   1. A `tool_input` equal to the pinned question of a pending audit
#      checkpoint on any branch (gaia_loop_input_is_pin, the comparison the
#      grant hook makes; never by header) parks with reason audit-checkpoint.
#   2. A question whose header is on the human-only list
#      (autonomy_human_only_header) parks with reason question, as does an
#      unreadable list.
#   3. A question with no option ending ` (Recommended)`, or more than one,
#      parks with reason question: the gate never guesses.
#   4. A recommended label whose first word is Merge, in any case, parks with
#      reason question unless the switch sets may_merge true.
#   5. Otherwise each question's one recommended label is appended to the
#      decision log (autonomy_log_decision) before the deny, which tells Claude
#      to take that label and continue. A failed append parks instead, so the
#      log never misses a decision Claude was told to take.
# A call with no readable `questions` array parks.
#
# SELF-GOVERNING EDITS. Edit, Write, MultiEdit (`file_path`), NotebookEdit
# (`notebook_path`) and a Bash or Monitor command that writes a path in the
# protected set (autonomy_protected_globs) are denied with the park command.
# Each path is resolved physically (physical_path), then made relative to the
# checkout holding it (autonomy_relative_path, then sibling_tree for a linked
# worktree of the same main checkout outside it), so every linked worktree's
# copy of a protected file is protected too. A Bash command is read with the scan
# block-audit-loop-write.sh uses (a redirect into the path, or a write verb
# outside quotes in a command naming it; on an unsound reading, any write
# spelling) and with lib/bash-write-target.sh. An unreadable protected set
# denies every write this arm reads.
#
# HONEST LIMITS. The Bash arm inherits both parsers' limits (their headers name
# them): a path in a variable, built by substitution, reached by a `cd` and a
# relative name, or written through `eval` or an interpreter script passes. A
# word is considered only when its spelling names `.claude/`, `CLAUDE.md`,
# `CLAUDE.local.md`, `local/protected`, `autonomy-` or `.gaia/scripts/`, so
# a symlink alias to a protected file passes on every arm. A `git checkout
# <ref> -- <file>`, `git restore` or `git apply` that rewrites a protected file
# carries no redirect and no write verb, so it passes too. A `cp` or `mv` that only reads a protected path is denied: the verb is
# armed and the direction is not parsed, the over-deny being the safe side.
#
# Fail mode: a missing library refuses with exit 2; the one exception is a merge,
# rebase, cherry-pick or revert that conflicts in a library this hook sources,
# where allow_library_conflict_repair or load_autonomy_library allows a fixed
# repair set. A missing jq refuses
# only a call whose tool_input names a guarded spelling (never a bare
# AskUserQuestion: with jq absent the switch reads as off, so it is allowed). A
# deny is JSON on stdout with exit 0.
#
# Bash 3.2 compatible.
set -euo pipefail

payload=$(cat)

# Raw pre-filter, before any fork: every call this hook can bind names the
# AskUserQuestion tool or, in its tool_input, one of the spellings is_protected
# arms on (the harness writes `/` unescaped, though JSON allows `\/`), so the
# ordinary Bash call stops here. The spellings are matched against the payload
# from the tool_input key on, because the fields before it (transcript_path,
# cwd) are paths under `.claude/` on every call; a payload without the key is
# matched whole.
_gate_region=${payload#*\"tool_input\"}
case "$payload" in
  *AskUserQuestion*) ;;
  *)
    case "$_gate_region" in
      *.claude/* | *CLAUDE.md* | *CLAUDE.local.md* | *local/protected* | *autonomy-* | *.gaia/scripts/*) ;;
      *) exit 0 ;;
    esac
    ;;
esac

_gate_directory="${BASH_SOURCE[0]%/*}"
[ "$_gate_directory" != "${BASH_SOURCE[0]}" ] || _gate_directory=.
_gate_scripts="$_gate_directory/../../.gaia/scripts"
# The protected set's data file and the package registry it joins are read
# from the tree this hook runs from, so both halves come from one checkout.
_gate_tree=$(cd -P -- "$_gate_directory/../.." 2>/dev/null && pwd -P) || _gate_tree=''

# load <file> <function>: source a library, refusing loudly when it is gone.
load() {
  set +e
  # shellcheck source=/dev/null
  [ -f "$1" ] && . "$1" 2>/dev/null
  set -e
  if ! type "$2" >/dev/null 2>&1; then
    printf 'BLOCKED: autonomy-gate.sh cannot load %s, so this call cannot be checked. Fail-loud, not fail-open -- restore the library.\n' "${1##*/}" >&2
    exit 2
  fi
}

# Every library the hook sources before it can gate a call, relative to a tree
# root. A conflict in one leaves a library that cannot load, and every repair
# route is itself a gated call, so allow_library_conflict_repair reads the
# payload with none of them. autonomy-lib.sh has its own repair arm below.
_gate_conflict_libraries='
.claude/hooks/lib/jq-availability.sh
.claude/hooks/lib/hook-payload.sh
.claude/hooks/lib/audit-loop-write-scan.sh
.claude/hooks/lib/bash-write-target.sh
.gaia/scripts/main-root-lib.sh
.gaia/scripts/audit-loop-state-lib.sh
'

# allow_library_conflict_repair: exit 0 when the call is exactly the repair of a
# merge, rebase, cherry-pick or revert that conflicts in a library above: its
# own `--abort`, or a `checkout|restore [--ours|--theirs] -- <path>` of one
# unmerged library path. A spelling with a quote, a backslash or any other word
# falls through to the ordinary load. The operation is looked up in the tree
# `git -C <path>` names, else the session's cwd.
allow_library_conflict_repair() {
  local cwd_pattern='"cwd": ?"([^"\\]+)"' command_pattern='"command": ?"([^"\\]+)"'
  local tool_pattern='"tool_name": ?"Bash"'
  local abort_pattern='^git( -C ([A-Za-z0-9_./+@:-]+))? (merge|rebase|cherry-pick|revert) --abort$'
  local pick_pattern='^git( -C ([A-Za-z0-9_./+@:-]+))? (checkout|restore) (--ours |--theirs )?-- ([A-Za-z0-9_./+-]+)$'
  local directory='' verb='' file='' command_line target operation='' candidate unmerged unmerged_path found=0
  [[ "$payload" =~ $tool_pattern ]] || return 0
  [[ "$payload" =~ $cwd_pattern ]] || return 0
  target=${BASH_REMATCH[1]}
  [[ "$payload" =~ $command_pattern ]] || return 0
  command_line=${BASH_REMATCH[1]}
  case "$target" in /*) ;; *) return 0 ;; esac
  if [[ "$command_line" =~ $abort_pattern ]]; then
    directory=${BASH_REMATCH[2]}
    verb=${BASH_REMATCH[3]}
  elif [[ "$command_line" =~ $pick_pattern ]]; then
    directory=${BASH_REMATCH[2]}
    file=${BASH_REMATCH[5]}
  else
    return 0
  fi
  case "$directory" in
    '') ;;
    /*) target=$directory ;;
    *) target=$target/$directory ;;
  esac
  for candidate in merge:MERGE_HEAD rebase:REBASE_HEAD cherry-pick:CHERRY_PICK_HEAD revert:REVERT_HEAD; do
    if git -C "$target" rev-parse -q --verify "${candidate#*:}" >/dev/null 2>&1; then
      operation=${candidate%%:*}
      break
    fi
  done
  [ -n "$operation" ] || return 0
  unmerged=$(git -C "$target" ls-files -u 2>/dev/null) || return 0
  if [ -n "$file" ]; then
    # A path in the command is relative to the directory git runs in, so only
    # a tree root names a library path unambiguously.
    [ -z "$(git -C "$target" rev-parse --show-prefix 2>/dev/null)" ] || return 0
    case $'\n'"$_gate_conflict_libraries" in *$'\n'"$file"$'\n'*) ;; *) return 0 ;; esac
    while IFS=$'\t' read -r _ unmerged_path; do
      [ "$unmerged_path" != "$file" ] || found=1
    done <<<"$unmerged"
  else
    [ "$verb" = "$operation" ] || return 0
    while IFS=$'\t' read -r _ unmerged_path; do
      case $'\n'"$_gate_conflict_libraries" in *$'\n'"$unmerged_path"$'\n'*) found=1 ;; esac
    done <<<"$unmerged"
  fi
  [ "$found" -eq 1 ] || return 0
  exit 0
}
allow_library_conflict_repair

load "$_gate_directory/lib/jq-availability.sh" gaia_require_jq
gaia_require_jq 'the autonomy gate' "$payload" tool_input '.claude/' 'CLAUDE.md' 'CLAUDE.local.md' 'local/protected' 'autonomy-' '.gaia/scripts/'
load "$_gate_directory/lib/hook-payload.sh" gaia_hook_payload_read
load "$_gate_scripts/main-root-lib.sh" gaia_resolve_main_root
# A merge, rebase, cherry-pick or revert that conflicts in autonomy-lib.sh leaves
# the library unparseable, and every repair route is itself a gated call, so a
# refusal would be permanent. In that one state (such an operation in progress
# and the library unloadable) exactly the commands below pass; widening the set
# opens the gate. The pattern admits only an optional `git -C <path>` prefix and
# these fixed words, so no shell metacharacter can ride along. A call naming no
# harness path never reaches this check (the raw pre-filter exits first).
# Bash runs a sourced file up to its first syntax error, so a conflict hunk
# late in the library still defines the early functions: loadable means every
# function the gate calls, or the protected-write arm fails open on a
# half-loaded library.
library_is_loaded() {
  local function_name
  for function_name in autonomy_active autonomy_field autonomy_log_decision \
    autonomy_human_only_header autonomy_protected_globs autonomy_relative_path \
    autonomy_protected_match; do
    type "$function_name" >/dev/null 2>&1 || return 1
  done
}

load_autonomy_library() {
  set +e
  # shellcheck source=/dev/null
  [ -f "$1" ] && . "$1" 2>/dev/null
  set -e
  ! library_is_loaded || return 0
  local operation='' candidate library=".gaia/scripts/${1##*/}" pattern
  if gaia_hook_payload_read "$payload" && [ "$GAIA_HOOK_TOOL_NAME" = Bash ]; then
    for candidate in merge:MERGE_HEAD rebase:REBASE_HEAD cherry-pick:CHERRY_PICK_HEAD revert:REVERT_HEAD; do
      if git -C "$GAIA_HOOK_CWD" rev-parse -q --verify "${candidate#*:}" >/dev/null 2>&1; then
        operation=${candidate%%:*}
        break
      fi
    done
    if [ -n "$operation" ]; then
      pattern="^git( -C [A-Za-z0-9_./+@:-]+)? ($operation --abort|(checkout|restore) (--ours |--theirs )?-- ${library//./\\.})\$"
      if [[ "$GAIA_HOOK_COMMAND" =~ $pattern ]]; then
        exit 0
      fi
    fi
  fi
  printf 'BLOCKED: autonomy-gate.sh cannot load %s, so this call cannot be checked. Fail-loud, not fail-open -- restore the library.' "${1##*/}" >&2
  if [ -n "$operation" ]; then
    printf ' A %s is in progress: run exactly one of: git %s --abort, git checkout --ours|--theirs -- %s, git restore --ours|--theirs -- %s. Choosing a side drops the other side'"'"'s changes to the library: re-apply them once it loads, before git add.' "$operation" "$operation" "$library" "$library" >&2
  fi
  printf '\n' >&2
  exit 2
}

load_autonomy_library "$_gate_scripts/autonomy-lib.sh"

gaia_hook_payload_read "$payload" || exit 0
cwd="$GAIA_HOOK_CWD"
case "$cwd" in /*) ;; *) cwd=$PWD ;; esac

autonomy_active "$cwd" || exit 0


deny() {
  jq -n --arg reason "Unattended run (the autonomy switch is live): $1" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
  exit 0
}

park_question() {
  deny "$1 Park this run: $PARK_QUESTION (add --pr <n> when the branch has a pull request), then stop. Do not ask it again or work around it."
}

main_root=$(gaia_resolve_main_root "$cwd" 2>/dev/null) || main_root=''
[ -z "$main_root" ] || main_root=$(cd -P -- "$main_root" 2>/dev/null && pwd -P) || main_root=''
tree_root=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null) || tree_root=''
[ -z "$tree_root" ] || tree_root=$(cd -P -- "$tree_root" 2>/dev/null && pwd -P) || tree_root=''

# The park command names the script by absolute path and parks the session's
# own tree, so it runs from any working directory.
PARK_SCRIPT="bash $_gate_tree/.gaia/scripts/autonomy-park.sh"
PARK_ROOT="--root ${tree_root:-$cwd}"
PARK_QUESTION="$PARK_SCRIPT --reason question --detail '<one line: what needs a human>' $PARK_ROOT"

ask_gate() {
  local tool_input state_file state pending pin pr questions count index header recommended labels='' branch
  tool_input=$(jq -c '.tool_input' <<<"$payload" 2>/dev/null) || tool_input=null

  if [ -n "$main_root" ] && [ -d "$main_root/.gaia/local/protected/audit-loop" ]; then
    load "$_gate_scripts/audit-loop-state-lib.sh" gaia_loop_input_is_pin
    while IFS= read -r state_file; do
      state=$(gaia_loop_read_state "$state_file" 2>/dev/null) || continue
      pending=$(gaia_loop_pending_checkpoint "$state")
      [ -n "$pending" ] || continue
      pin=$(jq -c '.question // empty' <<<"$pending" 2>/dev/null) || pin=''
      [ -n "$pin" ] || continue
      if gaia_loop_input_is_pin "$payload" "$pin"; then
        pr=$(jq -r '.pr // empty' <<<"$state" 2>/dev/null) || pr=''
        deny "this is the pinned audit checkpoint question, which only a human answers. Park this run: $PARK_SCRIPT --reason audit-checkpoint --pr ${pr:-<n>} $PARK_ROOT, then stop. Do not ask it again or dispatch another audit unit."
      fi
    done < <(find "$main_root/.gaia/local/protected/audit-loop" -name .closed -prune -o -type f -name '*.json' -print 2>/dev/null)
  fi

  questions=$(jq -c 'if (.questions | type) == "array" and (.questions | length) > 0 then .questions else empty end' <<<"$tool_input" 2>/dev/null) || questions=''
  [ -n "$questions" ] || park_question "the call carries no readable question."
  count=$(jq 'length' <<<"$questions")

  index=0
  while [ "$index" -lt "$count" ]; do
    header=$(jq -r --argjson i "$index" '.[$i].header // "" | strings' <<<"$questions")
    local status=0
    autonomy_human_only_header "$header" || status=$?
    case "$status" in
      0) park_question "the question '$header' is on the human-only list, so only a human answers it." ;;
      1) ;;
      *) park_question "the human-only header list cannot be read, so no question can be answered unattended." ;;
    esac
    recommended=$(jq -r --argjson i "$index" '[.[$i].options // [] | .[]? | .label? | strings | select(endswith(" (Recommended)"))] | if length == 1 then .[0] else empty end' <<<"$questions")
    [ -n "$recommended" ] || park_question "the question '$header' does not mark exactly one option (Recommended), and the gate never guesses."
    # A merge is the human's to allow: with may_merge not true, a recommended
    # label that leads to a merge parks instead of being taken.
    if [[ "$recommended" =~ ^[Mm][Ee][Rr][Gg][Ee]([^[:alnum:]]|$) ]] && [ "$(autonomy_field may_merge "$cwd" 2>/dev/null || true)" != true ]; then
      park_question "the question '$header' recommends a merge and the switch has may_merge false, so only a human allows the merge."
    fi
    labels="$labels$header"$'\t'"$recommended"$'\n'
    index=$((index + 1))
  done

  branch=$(git -C "$cwd" branch --show-current 2>/dev/null) || branch=''
  local take='' label
  while IFS=$'\t' read -r header label; do
    [ -n "$label" ] || continue
    autonomy_log_decision "$GAIA_HOOK_SESSION_ID" "$branch" "$header" "$label" "$cwd" ||
      park_question "the decision log could not be written, so the choice cannot be recorded."
    take="$take '$label' for '$header';"
  done <<<"$labels"
  deny "this question was shown to nobody. Take${take%;} and continue as if it had been selected. The choice is in the decision log."
}

PROTECTED_GLOBS=''
protected_globs() {
  [ -z "$PROTECTED_GLOBS" ] || return 0
  PROTECTED_GLOBS=$(autonomy_protected_globs "$_gate_tree" 2>/dev/null) || PROTECTED_GLOBS=''
  [ -n "$PROTECTED_GLOBS" ] ||
    park_question "the protected set (.gaia/autonomy-protected-paths.json) cannot be read, so no write is allowed unattended."
}

# sibling_tree <physical path>: print the root of the linked worktree holding
# the path when that worktree belongs to this main checkout, else nothing.
sibling_tree() {
  local directory="${1%/*}" root
  while [ -n "$directory" ] && [ ! -d "$directory" ]; do directory="${directory%/*}"; done
  [ -n "$directory" ] || return 0
  [ "$(gaia_resolve_main_root "$directory" 2>/dev/null)" = "$main_root" ] || return 0
  root=$(git -C "$directory" rev-parse --show-toplevel 2>/dev/null) || return 0
  cd -P -- "$root" 2>/dev/null && pwd -P
}

# is_protected <word>: rc 0 when the word, a path, resolves into the protected
# set, or carries a protected spelling when no main checkout resolves (fail
# closed). Called by name from gaia_bash_command_writes_target too.
is_protected() {
  local word resolved relative
  word=$(gaia_write_target_strip_quotes "${1-}")
  case "$word" in
    *.claude/* | *CLAUDE.md* | *CLAUDE.local.md* | *local/protected* | *autonomy-* | *.gaia/scripts/*) ;;
    *) return 1 ;;
  esac
  [ -n "$main_root" ] || return 0
  resolved=$(physical_path "$word" "$cwd")
  relative=$(autonomy_relative_path "$resolved" "$main_root" "$tree_root" ||
    autonomy_relative_path "$resolved" "$main_root" "$(sibling_tree "$resolved")") || return 1
  protected_globs
  if autonomy_protected_match "$relative" "$PROTECTED_GLOBS"; then
    PROTECTED_HIT="$relative"
    return 0
  fi
  return 1
}

deny_protected() {
  park_question "${PROTECTED_HIT:-this path} governs the harness itself (the protected set in .gaia/autonomy-protected-paths.json), so a change to it needs a human. Do not retry it by another tool, shell shape or path spelling."
}

bash_gate() {
  local command_line="$1" word target
  shell_scan "$command_line"
  if [ "$SCAN_SOUND" -eq 1 ]; then
    while IFS= read -r target; do
      [ -n "$target" ] || continue
      ! is_protected "$target" || deny_protected
    done <<<"$SCAN_TARGETS"
    if has_write_verb "$SCAN_BARE"; then
      for word in "${SCAN_WORDS[@]+"${SCAN_WORDS[@]}"}"; do
        ! is_protected "$word" || deny_protected
      done
    fi
  elif has_write_spelling "$command_line"; then
    # shellcheck disable=SC2086 # split into blank-separated words on purpose
    for word in $command_line; do
      ! is_protected "$word" || deny_protected
    done
  fi
  ! gaia_bash_command_writes_target "$command_line" is_protected || deny_protected
}

PROTECTED_HIT=''
case "$GAIA_HOOK_TOOL_NAME" in
  AskUserQuestion)
    ask_gate
    ;;
  Edit | Write | MultiEdit | NotebookEdit | Bash | Monitor)
    load "$_gate_directory/lib/audit-loop-write-scan.sh" physical_path
    load "$_gate_directory/lib/bash-write-target.sh" gaia_bash_command_writes_target
    case "$GAIA_HOOK_TOOL_NAME" in
      NotebookEdit)
        target=$(jq -r '.tool_input["notebook_path"] // "" | strings' <<<"$payload" 2>/dev/null) || target=''
        [ -z "$target" ] || ! is_protected "$target" || deny_protected
        ;;
      Bash | Monitor)
        [ -z "$GAIA_HOOK_COMMAND" ] || bash_gate "$GAIA_HOOK_COMMAND"
        ;;
      *)
        [ -z "$GAIA_HOOK_FILE_PATH" ] || ! is_protected "$GAIA_HOOK_FILE_PATH" || deny_protected
        ;;
    esac
    ;;
esac
exit 0
