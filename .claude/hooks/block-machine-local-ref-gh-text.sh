#!/usr/bin/env bash
#
# PreToolUse Bash hook: deny a `gh pr create|edit` or `gh issue create|edit`
# whose title or body cites a machine-local reference.
#
# Exit 2 = block the tool call; stderr is shown to Claude as the reason.
#
# WHY. A pull request or issue is read by people who cannot open a document
# that exists on one machine, and a merged pull request's body stays as it was
# written. The git hooks guard what a commit carries; this guards the other
# text Claude publishes. The patterns are the shared detector's,
# .gaia/scripts/machine-local-ref-lib.sh, and the rule is
# .claude/rules/working-doc-ids.md. A bare issue or pull request number
# passes: the detector never matches one.
#
# WHAT IT READS. Only the text the command writes, never the title or body
# already on GitHub: each `--title`/`-t` and `--body`/`-b` value and each
# `--body-file`/`-F` file, spelled `--flag <v>` or `--flag=<v>`. Each top-level
# command of the tool call is read through the shared shell-word scanner, as
# block-invalid-pr-title.sh reads it. A value is scanned as written, so a body
# passed as `"$(cat <<'EOF' ... EOF)"` is scanned whole, and its wrapper lines
# can never match. A relative body file resolves against the payload's cwd.
#
# HONEST LIMITS, all allowing:
#   - `--body-file -` (stdin), and a body file whose path carries `$` or a
#     backtick or cannot be read (gh refuses an unreadable one itself);
#   - text a substitution produces rather than text written inside it: a
#     `"$(cat <file>)"` body is not read (and a concrete run-folder path in
#     that `cat` is refused as written text; pass the file as --body-file);
#   - `--repo` / `-R`, a pull request or issue in another repository;
#   - `gh pr comment`, `gh issue comment`, `gh api`, and a `gh` nested in a
#     subshell or compound-command body, which the top-level read does not
#     enter.
# An unloadable detector denies, fail-loud.

payload=$(cat)

# jq-availability arm, narrowed by the `gh pr` and `gh issue` literals so the
# command that installs jq is never caught: .claude/hooks/lib/jq-availability.sh.
_jq_library_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" 2>/dev/null && pwd)" || _jq_library_directory=''
# shellcheck source=lib/jq-availability.sh
[ -n "$_jq_library_directory" ] && [ -f "$_jq_library_directory/jq-availability.sh" ] && . "$_jq_library_directory/jq-availability.sh" 2>/dev/null
if ! type gaia_require_jq >/dev/null 2>&1; then
  printf 'BLOCKED: block-machine-local-ref-gh-text.sh cannot load lib/jq-availability.sh, so this call cannot be checked. Fail-loud, not fail-open -- restore the library.\n' >&2
  exit 2
fi
gaia_require_jq 'the machine-local reference guard for gh text' "$payload" tool_input 'gh pr' 'gh issue'

# shellcheck source=lib/hook-payload.sh
[ -n "$_jq_library_directory" ] && [ -f "$_jq_library_directory/hook-payload.sh" ] && . "$_jq_library_directory/hook-payload.sh" 2>/dev/null
if ! type gaia_hook_payload_read >/dev/null 2>&1; then
  printf 'BLOCKED: block-machine-local-ref-gh-text.sh cannot load lib/hook-payload.sh, so this call cannot be checked. Fail-loud, not fail-open -- restore the library.\n' >&2
  exit 2
fi
gaia_hook_payload_read "$payload" || exit 0

[ "$GAIA_HOOK_TOOL_NAME" = "Bash" ] || exit 0
command_text=$GAIA_HOOK_COMMAND
[ -n "$command_text" ] || exit 0

_hook_library_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" 2>/dev/null && pwd)" || exit 0
repository_root="$(cd "$_hook_library_directory/../../.." 2>/dev/null && pwd)" || exit 0
# shellcheck source=/dev/null
"${BASH:-bash}" -n "$_hook_library_directory/verb-arming.sh" 2>/dev/null && . "$_hook_library_directory/verb-arming.sh" 2>/dev/null
type gaia_verb_armed >/dev/null 2>&1 || exit 0

verb_pattern='gh[[:space:]]+(pr|issue)[[:space:]]+(create|edit)([[:space:]]|$)'
if gaia_verb_armed "$verb_pattern" 'gh pr create;gh pr edit;gh issue create;gh issue edit' "$command_text"; then
  :
else
  exit 0
fi

detector="$repository_root/.gaia/scripts/machine-local-ref-lib.sh"
# shellcheck source=/dev/null
"${BASH:-bash}" -n "$detector" 2>/dev/null && . "$detector" 2>/dev/null
if ! type machine_local_ref_text >/dev/null 2>&1; then
  printf 'BLOCKED: block-machine-local-ref-gh-text.sh cannot load .gaia/scripts/machine-local-ref-lib.sh, so this gh text cannot be checked. Fail-loud, not fail-open -- restore the detector.\n' >&2
  exit 2
fi

if ! type gaia_scan_first_command >/dev/null 2>&1; then
  # shellcheck source=/dev/null
  "${BASH:-bash}" -n "$_hook_library_directory/repo-scope.sh" 2>/dev/null && . "$_hook_library_directory/repo-scope.sh" 2>/dev/null
  type gaia_scan_first_command >/dev/null 2>&1 || exit 0
fi

# The data-masked view keeps byte offsets, so it scans like the original.
scan_text="$command_text"
case "${GAIA_VERB_ARM_KIND:-}" in
  start | sep) [ -n "${GAIA_VERB_ARM_VIEW:-}" ] && scan_text="$GAIA_VERB_ARM_VIEW" ;;
esac

working_directory="${GAIA_HOOK_CWD:-$PWD}"
all_hits=""
scan_failed=""

# scan_value <flag> <value>: append the value's hits, each prefixed with the flag.
scan_value() {
  local flag="$1" value="$2" hits status path
  case "$flag" in
    --body-file | -F)
      case "$value" in
        - | *'$'* | *'`'*) return 0 ;;
        /*) path="$value" ;;
        *) path="$working_directory/$value" ;;
      esac
      [ -f "$path" ] && [ -r "$path" ] || return 0
      hits=$(machine_local_ref_text "$path" 2>&1) && status=0 || status=$?
      ;;
    *)
      hits=$(printf '%s\n' "$value" | machine_local_ref_text - 2>&1) && status=0 || status=$?
      ;;
  esac
  case "$status" in
    0) ;;
    1) all_hits="$all_hits$(printf '%s\n' "$hits" | sed "s/^/  $flag /")"$'\n' ;;
    *) scan_failed="$scan_failed  $flag: $hits"$'\n' ;;
  esac
}

# Reads GAIA_FIRST_COMMAND_WORDS for one `gh pr|issue create|edit` command.
read_gh_command() {
  local index=3 word_count="${#GAIA_FIRST_COMMAND_WORDS[@]}" word
  local flags=() values=() entry
  while [ "$index" -lt "$word_count" ]; do
    word="${GAIA_FIRST_COMMAND_WORDS[$index]}"
    case "$word" in
      --title | -t | --body | -b | --body-file | -F)
        index=$((index + 1))
        flags+=("$word")
        values+=("${GAIA_FIRST_COMMAND_WORDS[$index]:-}")
        ;;
      --title=* | --body=* | --body-file=*)
        flags+=("${word%%=*}")
        values+=("${word#*=}")
        ;;
      --repo | -R | --repo=* | -R?*) return 0 ;;
    esac
    index=$((index + 1))
  done
  for entry in "${!flags[@]}"; do
    scan_value "${flags[$entry]}" "${values[$entry]}"
  done
}

newline=$'\n'
offset=0
scan_guard=0
# The scan returns 1 for a command holding no words (a bare comment line), so
# the walk continues on its status and stops only when the offset stops
# advancing. 64 commands bounds a pathological input.
while [ "$scan_guard" -lt 64 ] && [ "$offset" -lt "${#scan_text}" ]; do
  scan_guard=$((scan_guard + 1))
  GAIA_FIRST_COMMAND_WORDS=()
  gaia_scan_first_command "$scan_text" "$offset" || true
  next_offset="$GAIA_FIRST_COMMAND_END"
  if [ "${#GAIA_FIRST_COMMAND_WORDS[@]}" -ge 3 ] &&
    [ "${GAIA_FIRST_COMMAND_WORDS[0]}" = gh ]; then
    case "${GAIA_FIRST_COMMAND_WORDS[1]} ${GAIA_FIRST_COMMAND_WORDS[2]}" in
      'pr create' | 'pr edit' | 'issue create' | 'issue edit') read_gh_command ;;
    esac
  fi
  # A comment closed the command: skip to the end of its line.
  if [ "$next_offset" -gt 0 ] && [ "${scan_text:$((next_offset - 1)):1}" = '#' ]; then
    rest="${scan_text:$next_offset}"
    after_newline="${rest#*"$newline"}"
    [ "$after_newline" != "$rest" ] || break
    next_offset=$((next_offset + ${#rest} - ${#after_newline}))
  fi
  [ "$next_offset" -gt "$offset" ] || break
  offset="$next_offset"
done

if [ -n "$scan_failed" ]; then
  {
    printf 'BLOCKED: this gh text could not be scanned for machine-local references:\n%s' "$scan_failed"
    printf 'Fail-loud, not fail-open: fix what the detector reports and run the command again.\n'
  } >&2
  exit 2
fi

if [ -n "$all_hits" ]; then
  {
    printf 'BLOCKED: this gh command would publish a machine-local reference:\n%s\n' "$all_hits"
    machine_local_ref_explain
    printf '\nRewrite the text and run the command again. A bare #<N> issue or pull request number is fine.\n'
  } >&2
  exit 2
fi

exit 0
