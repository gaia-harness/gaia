# shellcheck shell=bash
#
# Sourced only. A complete read of the tech-debt issue lists through paginated
# REST. `gh issue list --limit` is search-backed and stops at 1000 results, so a
# long closed list is cut off with nothing to say so; `gh api --paginate` walks
# every page, and a failed or partial read is an error, never a shorter list.
#
# gaia_debt_list_read <repo> <state> <output-file>
#   <repo>   owner/name, or empty for gh's own {owner}/{repo} placeholder,
#            which gh resolves from the working directory's repository.
#   <state>  open or closed.
#   Writes a JSON array of {number, body, labels: [{name}], stateReason} to
#   <output-file> and returns 0. Returns 1 with one stderr line, leaving no
#   output file, when gh fails, the output does not parse, or any page is not
#   an array. Pull requests (REST returns them among issues) are dropped.
#   stateReason is REST state_reason in GraphQL spelling (NOT_PLANNED).
#
# Never exits, never sets shell options; safe under the caller's `set -u`.

gaia_debt_list_read() {
  local list_repo="$1" list_state="$2" list_output="$3"
  local list_scratch list_raw list_error list_status list_projected
  [ -n "$list_repo" ] || list_repo='{owner}/{repo}'
  rm -f "$list_output"
  list_scratch="$(mktemp -d "${TMPDIR:-/tmp}/debt-list.XXXXXX")" || {
    printf 'cannot create a scratch directory\n' >&2
    return 1
  }
  list_raw="$list_scratch/raw"
  list_error="$list_scratch/error"
  gh api --paginate "repos/$list_repo/issues?labels=tech-debt&state=$list_state&per_page=100" \
    >"$list_raw" 2>"$list_error"
  list_status=$?
  if [ "$list_status" -ne 0 ]; then
    printf '%s\n' "$(tr '\n' ' ' <"$list_error" | sed 's/ *$//')" >&2
    [ -s "$list_error" ] || printf 'gh api failed reading the %s tech-debt issues\n' "$list_state" >&2
    rm -rf "$list_scratch"
    return 1
  fi
  list_projected="$list_scratch/projected"
  if ! jq -s -e '
      if all(.[]; type == "array") then add // [] else error("a page is not an array") end
      | map(select(has("pull_request") | not)
          | {number, body: (.body // ""),
             labels: [(.labels // [])[] | {name}],
             stateReason: (.state_reason | if type == "string" then ascii_upcase else null end)})
    ' "$list_raw" >"$list_projected" 2>"$list_error"; then
    printf 'the %s tech-debt list is not a complete array of issues\n' "$list_state" >&2
    rm -rf "$list_scratch"
    return 1
  fi
  mv "$list_projected" "$list_output"
  list_status=$?
  rm -rf "$list_scratch"
  return "$list_status"
}
