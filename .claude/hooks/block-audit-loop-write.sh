#!/usr/bin/env bash
# PreToolUse Edit/Write/MultiEdit + Bash/Monitor hook: deny Claude any write,
# edit, move or delete of the audit loop gate inputs, and any execution of the
# two audit loop recorders, of the local-state reaper scripts, or of the
# statusline and the context writers. The gate
# inputs are
#   <main>/.gaia/local/protected/                       hook-only and human-only state
#     protected/audit-loop/                             state: history + allowance
#     protected/checkpoint-override.json                the per-machine override
#   <main>/.gaia/local/cache/shared/context/            per-session context readings
#   <main>/.gaia/local/cache/shared/rate-limits/        per-session rate-limit readings
#   <main>/.gaia/local/cache/rate-limit-checkpoint/     per-session checkpoint markers
#   (and the legacy cache/shared/rate-limits.json)
# The protected folder is guarded as a whole, so a file added to it later is
# protected by its placement, with no edit to this guard.
#
# WHY. The state directory holds each branch's audit history and its
# human-granted allowance. Only audit-loop-bound.sh may write history, and only
# audit-loop-grant.sh and audit-loop-ask-grant.sh may write allowance; if Claude
# could write the files through its own tools it could forge an allowance or
# reset the history. The bound hook also trusts the context readings (the
# statusline writes one per render) and the override (written only by a
# human), so Claude writing either would move the checkpoint line. A
# checkpoint is answered by the pinned AskUserQuestion or by a human typing
# `audit-grant <n>` or `audit-accept`; both reach the state through a hook,
# never a tool call.
# The dispatch checkpoint trusts each session's rate-limit reading (the
# statusline writes it through the CLI's library) and its marker, and the 7-day
# bands trust the plan tier in the account profile, so Claude writing a reading
# or a marker, running the CLI's write verb, or changing the tier would forge
# the figure the checkpoint acts on. That arm lives in lib/rate-limits-guard.sh,
# sourced below.
# The recorders read a hook payload on stdin, so a forged payload piped to one
# from Bash would mint an answer: this guard denies executing them. The writer
# hooks and the statusline run as their own processes, so they are not subject
# to this guard.
# The reaper prunes spent entries under the protected folder, which Claude never
# writes or deletes, so the reaper and its SessionStart launcher run only as
# hooks too. The post-merge cleanup script never touches the protected folder
# and stays executable.
#
# WHAT IS COVERED.
#   Edit / Write / MultiEdit: .tool_input.file_path is resolved physically (the
#     deepest existing ancestor through `pwd -P`, `..` collapsed, the rest
#     re-appended), so a linked worktree's `.gaia/local` symlink to the main
#     checkout resolves to the real directory. Denied when the result is
#     <main>/.gaia/local/protected or lies inside it, or lies inside
#     <main>/.gaia/local/cache/shared/context/, or is
#     <main>/.gaia/local/cache/shared/rate-limits or
#     <main>/.gaia/local/cache/rate-limit-checkpoint, or lies inside either
#     (<main> from
#     gaia_resolve_main_root of the payload cwd), or when the literal path
#     contains or ends in one of those spellings (catches a worktree spelling
#     whose symlink target cannot be resolved). A sibling inside the folder
#     such as `protected/checkpoint-override.json.bak` is guarded; a sibling
#     beside the folder such as `.gaia/local/protected-notes.md` is not.
#     `.claude/settings.json`, `.claude/settings.local.json` and GAIA's
#     writable opt-ins file `.gaia/local/settings.json` are not this guard's
#     remit.
#   Bash / Monitor: .tool_input.command. Cheap pre-filter first: allowed unless
#     the payload contains `audit-loop`, `local/protected` or
#     `cache/shared/context`, `cache/shared/rate-limits` (slashless, so it also
#     arms the legacy file and the folder spelled with no trailing slash),
#     `cache/rate-limit-checkpoint`, `organizationRateLimitTier`,
#     `rate-limits-lib.sh`, `CLAUDE_CONFIG_DIR` followed by `rate-limits.sh`, or
#     `rate-limits.sh` with `write` after it (never a bare `rate-limits`, so a
#     read arms nothing). For the protected folder the command must name
#     `.gaia/local/protected` followed by a slash, a delimiter or the end of
#     the command: a path segment that merely starts with `protected` (a
#     sibling such as `.gaia/local/protected-notes.md`) does not arm it. The
#     command is read with its quotes grouped (single and double quotes, a
#     backslash escape), and a command that names a guarded path is
#     denied when a `>`, `>>`, `>|` or `>&` redirect TARGETS that path, or
#     when a write, move or delete verb stands outside quotes: rm, mv, cp, tee,
#     ln, install, dd, touch, truncate, chmod, rsync, unlink, shred, `sed -i`,
#     `perl -i`, or python/node/perl/ruby given -c or -e. So a printf of a
#     quoted note that names a path, redirected elsewhere, is allowed, and so
#     are read-only commands naming a path (cat, jq, ls). A `cp` or `mv` that
#     only READS a path is denied too: the verb is armed, the direction is not
#     parsed, and the over-deny is the safe side. A comment is skipped. A
#     command holding a heredoc, an unclosed quote, a command substitution or
#     backtick inside double quotes, or a redirect target built from a
#     variable, a substitution or a glob is not read that way, since its
#     quoting or its target means something else there: it is denied on any
#     redirect (a redirect to /dev/null or a descriptor duplication such as
#     2>&1 is not one) or verb anywhere. The deny message follows what the
#     command writes: the audit loop state, the override, or the folder.
#   Recorder execution: a command that EXECUTES audit-loop-grant.sh or
#     audit-loop-ask-grant.sh is denied. The command is split on `;`, `&&`,
#     `||`, `|`, `&`, `(`, `)`, backticks, `$(` and newlines; each simple
#     command is read with its quotes grouped (so a quoted recorder path under
#     a checkout path with a space stays one word) and again as blank-separated
#     words with quotes stripped, and executes a recorder when, in either
#     reading, the recorder path is its command word (leading NAME=value words
#     skipped), or the script argument of bash, sh, zsh, dash, ksh, `source`,
#     `.` or `exec` (flags skipped, `-o <option>` skipped, a lone `-n` syntax
#     check excepted). A command that merely NAMES a recorder
#     (`git add`, `git diff`, `git grep -l`, `git log`, `shellcheck`, `cat`,
#     `grep`, `bash -n`) is allowed, because staging, gate discovery and commits
#     name these paths. The split ignores quotes, here and in the reaper and
#     context writer readings below, so a quoted `;`, `&`, `|`, `(`, `)`,
#     backtick or newline in an argument can deny a command that only names a
#     recorder, reaper or context writer script; the Read tool, or one grep
#     with a `-e <pattern>` per alternative and none of those characters, still
#     reads one. A heredoc body the verb-arming walker proves is data (a
#     `cat` or `tee` into a file) is not read as commands, so a line of it
#     naming a recorder is allowed. A script a data heredoc writes and a later
#     command in the same call runs is not caught: the body is data when the
#     guard reads it.
#   Reaper execution: the same reading, with its own deny message, over the
#     scripts state-reaper.sh, state-reaper-lib.sh, state-reaper-classes.sh and
#     state-reaper-session-start.sh. Naming them stays allowed, and so does
#     running a bats suite whose path merely contains `state-reaper`, since the
#     suite path is not one of those four file names.
#   Rate-limit readings and markers: the same quote-aware reading and
#     unsound-reading fallback denies a command that redirects into a reading,
#     a marker, either folder or the legacy file, or runs a write, move or
#     delete verb over one (`>`, `rm`, `mv`, `cp`, `tee`, `ln`, `sed -i`
#     and the like, including `rm -rf` of either folder with or without a
#     trailing slash), and a command that EXECUTES `rate-limits.sh` with `write`
#     as its first argument (command word, or the script argument of bash, sh,
#     zsh, dash, ksh, `source`, `.` or `exec`; quoted or not). `rate-limits.sh
#     read`, `cat` and `jq .` of a reading, and `git add`, `git diff`,
#     `shellcheck` or `bash -n` naming either script stay allowed.
#   Context writer execution: the same reading, with its own deny message, over
#     two criteria. A command that EXECUTES gaia-statusline.sh or
#     context-reading.sh (matched by exact base name, so gaia-statusline-left.sh,
#     gaia-statusline-right.sh and a bats suite path never match), or that
#     SOURCES context-checkpoint-lib.sh, context-any-age-lib.sh,
#     gaia-next-handoff-lib.sh (both source it) or context-reading.sh (`source` or `.`
#     script argument) and names gaia_context_write or
#     gaia_statusline_write_context as a whole word anywhere in the command, is
#     denied: either mints the context reading the checkpoint trusts. Naming the
#     files (`git add`, `git diff`, `grep`, `cat`, `shellcheck`, `bash -n`),
#     sourcing the library to call a reader or `gaia_context_yield_limit`, and a
#     data heredoc line naming a statusline script stay allowed.
#   Plan tier: an Edit, Write or MultiEdit of a `.claude.json` whose new text
#     (`content`, `new_string`, any `edits[].new_string`) names
#     `organizationRateLimitTier`, and a command that writes a `.claude.json`
#     and names it, are denied; a command that sets CLAUDE_CONFIG_DIR (prefix,
#     `export`, `env`) and names `rate-limits.sh` is denied, since the CLI would
#     read another folder's profile. A read-only jq of the tier, and an edit of
#     `.claude.json` that does not name it, stay allowed.
#
# WHAT IS NOT COVERED (exotic spellings, outside the guarantee): a `cd` into a
# guarded directory followed by relative names; `eval`, `bash -c`, `env`,
# `timeout` and `xargs` wrappers, and a path held in a variable or built from a
# command substitution, for any guarded path, for the recorders and for the
# reaper scripts; glob
# spellings such as `.gaia/local/prot*`; a verb joined to the path by quoting
# tricks, or itself quoted (`'rm'`); `bash < <recorder>` and
# `cat <recorder> | bash`, and the same two spellings for a reaper script; a
# leading input redirect before the command word (`< file bash <recorder>`,
# and the same for a reaper script), which the command-word reading does not
# skip; a
# recorder or reaper name inside a quoted string that the
# split above cuts at a `;`, `|` or `&`; case variants of a guarded path on a
# case-insensitive filesystem (`.gaia/local/Protected`); an Edit/Write path or
# a Bash command that reaches `protected/` without naming `local/protected` or
# `audit-loop` anywhere in its spelling (a `..` hop such as
# `.gaia/local/runs/../protected/x`, or a symlink alias whose own path names
# neither): the raw pre-filter allows it before any resolution; a symlink alias
# to `protected/` or into it whose own path never names it, and the two-hop
# parent alias (an allowed `ln -s <main>/.gaia/local <elsewhere>`, which names
# neither `.gaia/local/protected` nor `local/protected`, followed by a write
# through `<elsewhere>/protected/...`, or a `mv` or `ln` through the alias),
# since the `ln -s` that names the folder is denied but the parent alias is not;
# `mkdir`, which is not a write verb, so creating the folder or a directory
# inside it stays allowed; a context reading minted through a spelling the
# context writer execution match misses (the wrappers, variables, substitutions
# and quoting tricks listed above for the recorders, a copy of the statusline
# or the library under another name, a script Claude writes that never names
# them). A name match is bypassable, so the residual stays, bounded: a minted
# low reading yields automatic units on the fallback and the enriching, stalled,
# nitpicky and small-tail signals, up to the effective round cap (10 when none is set);
# reintroduced, waiver-drift, an Accept, Stop or State-the-rule recommendation
# and the cap still ask whatever the reading. Such a reading stands until the
# next real statusline render overwrites it. A rate-limit reading has the same
# residuals: sourcing .gaia/scripts/rate-limits-lib.sh and calling its writer
# (directly or through .gaia/statusline/rate-limits-reading.sh), and a write
# spelled through the wrappers above, a path in a variable or a `cd` followed
# by a relative name; such a reading stands until a higher real reading or the window's reset.
# With jq absent, a quoted `'write'` or a doubled space before it passes the
# jq-absent refusal, which matches the unquoted single-space literal only.
#
# THE PARENT. Deleting the parent `.gaia/local` (which would take the state with
# it) is block-rm-rf.sh's remit, not this guard's, and is not widened here.
#
# Fail mode: a missing jq refuses only a call whose tool_input mentions one of
# the guarded spellings (exit 2, via lib/jq-availability.sh), so installing jq
# stays allowed. A deny is JSON on stdout with exit 0.
#
# Bash 3.2 compatible.
set -euo pipefail

payload=$(cat)

# A missing jq-availability library refuses before the pre-filter below: the
# pre-filter's silent allow is only sound while the arm it skips is loadable,
# and a guard that exits 0 with its library gone fails open. A plain file test
# keeps this free of a fork on the common path.
_self_directory="${BASH_SOURCE[0]%/*}"
[ "$_self_directory" != "${BASH_SOURCE[0]}" ] || _self_directory=.
if [ ! -f "$_self_directory/lib/jq-availability.sh" ]; then
  printf 'BLOCKED: block-audit-loop-write.sh cannot load lib/jq-availability.sh, so this call cannot be checked. Fail-loud, not fail-open -- restore the library.\n' >&2
  exit 2
fi

# Raw pre-filter. Every call this guard can bind carries one of these literals
# in its payload (JSON never escapes those characters; both recorder names
# contain `audit-loop`, every reaper script name contains `state-reaper`, and the
# context writers are named by the three literals after it), so
# a payload without any is outside the remit with no
# jq read at all. This is the path every ordinary Bash call takes.
case "$payload" in
  *audit-loop* | *state-reaper* | *gaia-statusline.sh* | *context-reading.sh* | *context-checkpoint-lib.sh* | *context-any-age-lib.sh* | *gaia-next-handoff-lib.sh* | *local/protected* | *cache/shared/context* | *cache/shared/rate-limits* | *cache/rate-limit-checkpoint* | *organizationRateLimitTier* | *CLAUDE_CONFIG_DIR*rate-limits.sh* | *rate-limits-lib.sh* | *rate-limits.sh*write*) ;;
  *) exit 0 ;;
esac

_jq_library_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" 2>/dev/null && pwd)" || _jq_library_directory=''
set +e
# shellcheck source=lib/jq-availability.sh
[ -n "$_jq_library_directory" ] && [ -f "$_jq_library_directory/jq-availability.sh" ] && . "$_jq_library_directory/jq-availability.sh" 2>/dev/null
set -e
if ! type gaia_require_jq >/dev/null 2>&1; then
  printf 'BLOCKED: block-audit-loop-write.sh cannot load lib/jq-availability.sh, so this call cannot be checked. Fail-loud, not fail-open -- restore the library.\n' >&2
  exit 2
fi
gaia_require_jq 'the audit loop state guard' "$payload" tool_input 'audit-loop' 'state-reaper' 'gaia-statusline.sh' 'context-reading.sh' 'context-checkpoint-lib.sh' 'context-any-age-lib.sh' 'gaia-next-handoff-lib.sh' 'local/protected' 'cache/shared/context' 'cache/shared/rate-limits' 'cache/rate-limit-checkpoint' 'organizationRateLimitTier' 'CLAUDE_CONFIG_DIR' 'rate-limits-lib.sh' 'rate-limits.sh write'

set +e
# shellcheck source=lib/hook-payload.sh
[ -n "$_jq_library_directory" ] && [ -f "$_jq_library_directory/hook-payload.sh" ] && . "$_jq_library_directory/hook-payload.sh" 2>/dev/null
set -e
if ! type gaia_hook_payload_read >/dev/null 2>&1; then
  printf 'BLOCKED: block-audit-loop-write.sh cannot load lib/hook-payload.sh, so this call cannot be checked. Fail-loud, not fail-open -- restore the library.\n' >&2
  exit 2
fi
# An empty or unreadable payload names nothing to guard, and the hook stands
# down with status 0, as the per-field reads did for an empty payload.
gaia_hook_payload_read "$payload" || exit 0
tool_name="$GAIA_HOOK_TOOL_NAME"

# The shell reading, then the per-class libraries: each is fail-loud, so a
# missing one refuses the call rather than letting its class through.
set +e
# shellcheck source=lib/audit-loop-write-scan.sh
[ -n "$_jq_library_directory" ] && [ -f "$_jq_library_directory/audit-loop-write-scan.sh" ] && . "$_jq_library_directory/audit-loop-write-scan.sh" 2>/dev/null
set -e
if ! type runs_guarded_script >/dev/null 2>&1; then
  printf 'BLOCKED: block-audit-loop-write.sh cannot load lib/audit-loop-write-scan.sh, so this call cannot be checked. Fail-loud, not fail-open -- restore the library.\n' >&2
  exit 2
fi

set +e
# shellcheck source=lib/gate-input-paths-guard.sh
[ -n "$_jq_library_directory" ] && [ -f "$_jq_library_directory/gate-input-paths-guard.sh" ] && . "$_jq_library_directory/gate-input-paths-guard.sh" 2>/dev/null
set -e
if ! type guarded_class >/dev/null 2>&1; then
  printf 'BLOCKED: block-audit-loop-write.sh cannot load lib/gate-input-paths-guard.sh, so this call cannot be checked. Fail-loud, not fail-open -- restore the library.\n' >&2
  exit 2
fi

set +e
# shellcheck source=lib/hook-only-scripts-guard.sh
[ -n "$_jq_library_directory" ] && [ -f "$_jq_library_directory/hook-only-scripts-guard.sh" ] && . "$_jq_library_directory/hook-only-scripts-guard.sh" 2>/dev/null
set -e
if ! type guarded_script_kind >/dev/null 2>&1; then
  printf 'BLOCKED: block-audit-loop-write.sh cannot load lib/hook-only-scripts-guard.sh, so this call cannot be checked. Fail-loud, not fail-open -- restore the library.\n' >&2
  exit 2
fi

DENY_BASH_TRIGGER="Trigger: the command names that path and either redirects into it or carries a write, move or delete verb (rm, mv, cp, tee, ln, touch, sed -i, an interpreter given -c or -e, and the like) outside quotes; in a command holding a heredoc, an unclosed quote, a command substitution inside double quotes, or a redirect target built from a variable or a glob, any redirect or such verb anywhere counts. A command that names the path only as quoted text and redirects elsewhere is allowed, so stage a note that mentions it with printf and a quoted string, no heredoc, or leave the literal path out of the command."

# deny <state|override|folder|context|recorder|reaper|context-writer|rate-limits|rate-limits-tier> [bash]
deny() {
  local message
  case "$1" in
    context) message="$DENY_CONTEXT_MESSAGE" ;;
    override) message="$DENY_OVERRIDE_MESSAGE" ;;
    folder) message="$DENY_FOLDER_MESSAGE" ;;
    recorder) message="$DENY_RECORDER_MESSAGE" ;;
    reaper) message="$DENY_REAPER_MESSAGE" ;;
    context-writer) message="$DENY_CONTEXT_WRITER_MESSAGE" ;;
    rate-limits) message="$DENY_RATE_LIMITS_MESSAGE" ;;
    rate-limits-tier) message="$DENY_RATE_LIMITS_TIER_MESSAGE" ;;
    *) message="$DENY_STATE_MESSAGE" ;;
  esac
  [ "${2-}" != bash ] || message="$message $DENY_BASH_TRIGGER"
  jq -n --arg reason "$message" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
  exit 0
}

set +e
# shellcheck source=lib/rate-limits-guard.sh
[ -n "$_jq_library_directory" ] && [ -f "$_jq_library_directory/rate-limits-guard.sh" ] && . "$_jq_library_directory/rate-limits-guard.sh" 2>/dev/null
set -e
if ! type gaia_rate_limits_guard_path >/dev/null 2>&1; then
  printf 'BLOCKED: block-audit-loop-write.sh cannot load lib/rate-limits-guard.sh, so this call cannot be checked. Fail-loud, not fail-open -- restore the library.\n' >&2
  exit 2
fi

case "$tool_name" in
  # sanctioned copy of .claude/hooks/lib/hook-payload.sh#GAIA_HOOK_EDIT_TOOLS
  Edit | Write | MultiEdit)
    file_path="$GAIA_HOOK_FILE_PATH"
    [[ -n "$file_path" ]] || exit 0

    # Literal spelling first: it needs no resolution and survives a symlink
    # target that cannot be resolved.
    class=$(guarded_class "$file_path")
    [ -z "$class" ] || deny "$class"

    cwd="$GAIA_HOOK_CWD"
    [[ -n "$cwd" ]] || cwd=$(pwd -P)
    resolved=$(physical_path "$file_path" "$cwd")

    main_root=''
    _main_root_library="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)/.gaia/scripts/main-root-lib.sh"
    if [ -f "$_main_root_library" ]; then
      set +e
      # shellcheck source=../../.gaia/scripts/main-root-lib.sh
      . "$_main_root_library" 2>/dev/null
      main_root=$(gaia_resolve_main_root "$cwd" 2>/dev/null)
      set -e
    fi
    if [ -n "$main_root" ]; then
      case "$resolved" in
        "$main_root/.gaia/local/protected" | "$main_root/.gaia/local/protected"/*) deny "$(protected_class "$resolved" "$main_root/.gaia/local/protected")" ;;
        "$main_root/.gaia/local/cache/shared/context" | "$main_root/.gaia/local/cache/shared/context"/*) deny context ;;
      esac
    fi
    # Resolved spelling that still names a guarded path (a symlinked checkout
    # whose main root could not be resolved).
    class=$(guarded_class "$resolved")
    [ -z "$class" ] || deny "$class"
    ! gaia_rate_limits_guard_path "$file_path" "$resolved" || deny rate-limits
    ! gaia_rate_limits_guard_edits_tier "$file_path" "$resolved" "$payload" || deny rate-limits-tier
    exit 0
    ;;

  *)
    gaia_hook_is_command_tool "$tool_name" || exit 0
    command_line="$GAIA_HOOK_COMMAND"
    [[ -n "$command_line" ]] || exit 0

    runs_guarded_script "$command_line" && deny "$SCRIPT_KIND"
    runs_guarded_script "$command_line" context_writer_execute_matcher && deny context-writer
    if names_context_writer "$command_line" && runs_guarded_script "$command_line" context_writer_source_matcher; then
      deny context-writer
    fi

    # Pre-filter per class: does the command name the path at all?
    protected_names_re='\.gaia/local/protected(/|[[:space:]"'\'';|&)<>]|$)'
    state_subpath_re='\.gaia/local/protected/audit-loop(/|[[:space:]"'\'';|&)<>]|$)'
    override_subpath_re='\.gaia/local/protected/checkpoint-override\.json([[:space:]"'\'';|&)<>]|$)'
    context_names_re='\.gaia/local/cache/shared/context(/|[[:space:]"'\'';|&)<>]|$)'
    shell_scan "$command_line"
    if [[ "$command_line" =~ $protected_names_re ]] && writes_named "$command_line" "$protected_names_re"; then
      # The class follows what is written, not what is merely named.
      if [[ "$command_line" =~ $state_subpath_re ]] && writes_named "$command_line" "$state_subpath_re"; then
        deny state bash
      fi
      if [[ "$command_line" =~ $override_subpath_re ]] && writes_named "$command_line" "$override_subpath_re"; then
        deny override bash
      fi
      deny folder bash
    fi
    if [[ "$command_line" =~ $context_names_re ]] && writes_named "$command_line" "$context_names_re"; then
      deny context bash
    fi
    if gaia_rate_limits_guard_runs_write "$command_line" || gaia_rate_limits_guard_writes_file "$command_line"; then
      deny rate-limits bash
    fi
    if gaia_rate_limits_guard_sets_config_dir "$command_line" || gaia_rate_limits_guard_writes_tier "$command_line"; then
      deny rate-limits-tier bash
    fi
    exit 0
    ;;

esac
