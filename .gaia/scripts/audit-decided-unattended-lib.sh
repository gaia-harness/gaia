# shellcheck shell=bash
#
# The "## Decided unattended" PR-body section: the decision log entries whose
# branch is the one ROOT has checked out, so a human reviewing the pull
# request sees what an unattended run chose on their behalf. Sourced by
# audit-pr-sections-lib.sh, and it relies on that file's _ROW_TEXT_JQ and
# _screen_reasons and the caller's _error, _TEMPORARY_FILES,
# _GAIA_DISPOSITIONS_DIRECTORY and ROOT. autonomy-lib.sh owns the log's path,
# entry format and writer. Sources autonomy-lib.sh and branch-name-lib.sh and
# runs nothing else at source time. Never `cd`s.

# shellcheck source=/dev/null
. "$_GAIA_DISPOSITIONS_DIRECTORY/autonomy-lib.sh"
# shellcheck source=/dev/null
. "$_GAIA_DISPOSITIONS_DIRECTORY/branch-name-lib.sh"

# _decided_unattended_section: the section, one `- <header>: <option>` line per
# entry in log order, or nothing when the branch has none (a detached HEAD and
# an absent log included). Branches compare by their normalized key, so an
# entry the gate wrote before the harness's `worktree-` branch was renamed
# still counts. An entry whose text fails the secret screen or names a
# machine-local path is withheld and counted: the PR-text hook would refuse a
# body carrying the path. rc 3 when the log or a screen cannot be read.
_decided_unattended_section() {
  local branch log key candidate matching="[]" texts clean local_lines text_file local_status=0
  branch="$(git -C "$ROOT" branch --show-current 2>/dev/null)" || return 0
  [ -n "$branch" ] || return 0
  log="$(autonomy_log_file "$ROOT")" || return 0
  [ -f "$log" ] || return 0
  key="$(gaia_branch_normalize "$branch")"
  while IFS= read -r candidate; do
    [ -n "$candidate" ] && [ "$(gaia_branch_normalize "$candidate")" = "$key" ] || continue
    matching="$(jq -c -n --argjson matching "$matching" --arg branch "$candidate" '$matching + [$branch]')" || return 3
  done < <(jq -R -r 'fromjson? | select(type == "object" and (.branch | type) == "string") | .branch' "$log" 2>/dev/null | sort -u)
  [ "$matching" != "[]" ] || return 0
  texts="$(jq -R -r --argjson branches "$matching" "$_ROW_TEXT_JQ"'fromjson?
    | select(type == "object" and (.branch | type) == "string" and (.branch | IN($branches[])))
    | "\(text(.header)): \(text(.option))"' "$log" 2>/dev/null)" || { _error "unreadable decision log $log"; return 3; }
  text_file="$(mktemp "${TMPDIR:-/tmp}/audit-decided-unattended.XXXXXX")" || { _error "cannot create a scratch file"; return 3; }
  _TEMPORARY_FILES+=("$text_file")
  clean="$(_screen_reasons "$texts" "$text_file")" || return 3
  local_lines="$(printf '%s\n' "$texts" | bash "$_GAIA_DISPOSITIONS_DIRECTORY/machine-local-ref-lib.sh" text - 2>/dev/null)" || local_status=$?
  case "$local_status" in
    0 | 1) ;;
    *) _error "the machine-local reference screen could not run (exit $local_status)"; return 3 ;;
  esac
  jq -r -n --arg texts "$texts" --argjson clean "$clean" --arg local_lines "$local_lines" '
    ($local_lines | [scan("^line ([0-9]+):"; "m")[0] | tonumber]) as $local_hits
    | ($texts | split("\n")) as $rows
    | [range(0; $rows | length) | select($clean[.] == true and ((. + 1) | IN($local_hits[]) | not)) | "- \($rows[.])"] as $shown
    | (($rows | length) - ($shown | length)) as $withheld
    | (["## Decided unattended", ""] + $shown
       + (if $withheld > 0 then ["- \($withheld) decision(s) withheld: text failed the secret or machine-local reference screen"] else [] end))
    | join("\n")' || return 3
}
