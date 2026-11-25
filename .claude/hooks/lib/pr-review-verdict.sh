#!/usr/bin/env bash
# shellcheck shell=bash
# The PR review verdict: whether a pull request's review record is complete,
# the one decision the merge hook, the GAIA-Audit success poster and the CLI
# wiki flow must agree on, plus the renderers for the PR body's `## PR review`
# section and the session report. Sourced, never executed; defines functions
# only and does no work at source time.
#
#   pr_review_record_path <main-root> <head-ref-name>
#   pr_review_load_record <main-root> <head-ref-name>
#   pr_review_findings_digest <record-json>
#   pr_review_render_section <record-json>
#   pr_review_render_report <record-json>
#   pr_review_body_section <pr-body>
#   pr_review_marker_scan <file>
#   pr_review_verdict <record-json-or-empty> <pr-number> <pr-body>
#                     <out-of-scope 0|1> <repo-dir> <head-sha> <base-tip-or-empty>
#
# pr_review_verdict exits 0 when the review is complete, else 1 printing one
# reason with no `PR review:` prefix and no trailing period; each gate site
# adds its own wrapper. The record's findings are fixed at its outcome, so a
# recomputed digest that differs is a refusal, not a repair. An empty record
# is a refusal too: the PR body section is only checked against the record,
# never read as one, since the body is editable by anyone.
#
# Two libraries are sourced. audit-loop-state-lib.sh owns the run-folder format
# (gaia_loop_run_directory) and pulls in branch-name-lib.sh, main-root-lib.sh,
# audit-key-lib.sh, exclusive-lock-lib.sh, branch-authorship-lib.sh and
# filing-outcomes-lib.sh; pr-body-sections-lib.sh owns the section's heading
# (PR_BODY_HEADING_PR_REVIEW). A sandbox that copies libraries one by one
# carries all eight; with the heading library absent the renderers print
# nothing and the verdict refuses.
#
# Bash 3.2 compatible. Never changes directory.

_PR_REVIEW_START_MARKER='<!-- gaia:pr-review:start -->'
_PR_REVIEW_END_MARKER='<!-- gaia:pr-review:end -->'

_pr_review_library_directory="${BASH_SOURCE[0]%/*}"
[ "$_pr_review_library_directory" = "${BASH_SOURCE[0]}" ] && _pr_review_library_directory="."
# shellcheck source=/dev/null
. "$_pr_review_library_directory/../../../.gaia/scripts/audit-loop-state-lib.sh" 2>/dev/null || true
# shellcheck source=/dev/null
. "$_pr_review_library_directory/../../../.gaia/scripts/pr-body-sections-lib.sh" 2>/dev/null || true

# The disposition orderings live in these jq programs only. A summary and a
# reason are one line with comment markers removed, so neither can end the
# section's marker comment or shift a line onto another finding.
# shellcheck disable=SC2016
_PR_REVIEW_JQ='
def one: gsub("<!--|-->"; "") | gsub("\\s+"; " ") | gsub("^ | $"; "");
def secure: (.security == false | not);
def secure_text:
  if .disposition == null then "undecided"
  elif .fix_state == "fixed" then "fixed"
  else "fix" end;
def disposition_text:
  if .disposition == null then "undecided"
  elif .disposition == "fix" then (if .fix_state == "fixed" then "fixed" else "fix" end)
  elif .disposition == "file" then "file: #\(.issue)"
  else "\(.disposition): \((.reason // "") | one)" end;
def item:
  if secure then "- \(.severity) security finding -> \(secure_text)"
  else "- \(.severity) \(.file // "PR body" | one)\(if .line == null then "" else ":\(.line)" end) \(.summary | one) -> \(disposition_text)" end;
def section_lines:
  [$start, $heading, "", "Reviewed head: \(.reviewed_head)"]
  + (if .spec == "none" then ["Coverage: no spec."] else [] end)
  + (if .outcome == "not-run" then ["Not run: \(.not_run_reason // "" | one)."]
     elif .outcome != "ran" then ["Not run: review not finished."]
     elif (.findings | length) == 0 then ["No findings."]
     else [.findings[] | item] end)
  + [$end];
def tally:
  (.findings | map(.disposition // "undecided")) as $held
  | ["fix", "dismiss", "file", "accept-residual", "waive-out-of-scope", "undecided"]
  | map(. as $name | {name: $name, count: ($held | map(select(. == $name)) | length)})
  | map(select(.count > 0))
  | map("\(.count) \(.name)")
  | join(", ");
def report_lines:
  if .outcome == "not-run" then ["PR review: not run: \(.not_run_reason // "" | one)"]
  elif .outcome != "ran" then ["PR review: not run: review not finished"]
  elif (.findings | length) == 0 then ["PR review: no findings"]
  else
    ["PR review: \(.findings | length) finding\(if (.findings | length) == 1 then "" else "s" end): \(tally)"]
    + [.findings[] | select(secure or .disposition != "fix") | item]
  end;
'

# The record's view for the verdict: form, not-run reason, findings with no
# disposition, fix findings not yet fixed, reviewed head; one per line.
# shellcheck disable=SC2016
_PR_REVIEW_RECORD_VIEW_JQ='
(if .outcome == "ran" then "ran" elif .outcome == "not-run" then "not-run" else "open" end),
(.not_run_reason // ""),
([.findings[] | select(.disposition == null)] | length),
([.findings[] | select(.disposition == "fix" and .fix_state != "fixed")] | length),
(.reviewed_head // "")
'

pr_review_record_path() {
  local main_root="$1" head_ref_name="$2" key
  type gaia_branch_normalize >/dev/null 2>&1 && type gaia_loop_run_directory >/dev/null 2>&1 || return 1
  key="$(gaia_branch_normalize "$head_ref_name")"
  [ -n "$key" ] || return 1
  printf '%s/pr-review.json\n' "$(gaia_loop_run_directory "$main_root" "$key")"
}

# pr_review_load_record <main-root> <head-ref-name>: the branch's review record,
# or nothing when it has none or its path cannot be derived.
pr_review_load_record() {
  local record_file
  record_file="$(pr_review_record_path "$1" "$2" 2>/dev/null)" || return 0
  [ -f "$record_file" ] || return 0
  cat "$record_file" 2>/dev/null || true
}

_pr_review_sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | cut -d ' ' -f 1
  else
    sha256sum | cut -d ' ' -f 1
  fi
}

pr_review_findings_digest() {
  local canonical
  canonical="$(printf '%s' "$1" | jq -cS '[.findings[] | {file, line, severity, security, summary, failure_scenario, verified}]')" || return 1
  printf '%s\n' "$canonical" | _pr_review_sha256
}

pr_review_render_section() {
  [ -n "${PR_BODY_HEADING_PR_REVIEW:-}" ] || return 1
  printf '%s' "$1" | jq -r --arg start "$_PR_REVIEW_START_MARKER" --arg end "$_PR_REVIEW_END_MARKER" --arg heading "$PR_BODY_HEADING_PR_REVIEW" "$_PR_REVIEW_JQ"' section_lines | .[]'
}

pr_review_render_report() {
  printf '%s' "$1" | jq -r --arg start "$_PR_REVIEW_START_MARKER" --arg end "$_PR_REVIEW_END_MARKER" --arg heading "${PR_BODY_HEADING_PR_REVIEW:-}" "$_PR_REVIEW_JQ"' report_lines | .[]'
}

# pr_review_marker_scan <file>: six numbers on one line: start markers, end
# markers, first start line, first end line, marker lines inside a fenced code
# block, marker lines not alone on their line.
pr_review_marker_scan() {
  LC_ALL=C awk -v start_marker="$_PR_REVIEW_START_MARKER" -v end_marker="$_PR_REVIEW_END_MARKER" '
    {
      line = $0
      trimmed_line = line
      sub(/[ \t\r]+$/, "", trimmed_line)
      hasStart = index(line, start_marker) > 0
      hasEnd = index(line, end_marker) > 0
      if (hasStart || hasEnd) {
        if (infence) fenced++
        if (hasStart) { start_count++; if (!start_line) start_line = NR; if (trimmed_line != start_marker) alone++ }
        if (hasEnd) { end_count++; if (!end_line) end_line = NR; if (trimmed_line != end_marker) alone++ }
        next
      }
      stripped_line = line
      sub(/^ ? ? ?/, "", stripped_line)
      first_character = substr(stripped_line, 1, 1)
      if ((first_character == "`" || first_character == "~") && substr(stripped_line, 1, 3) == first_character first_character first_character) {
        if (!infence) { infence = 1; fence_character = first_character }
        else if (first_character == fence_character) { infence = 0 }
      }
    }
    END { printf "%d %d %d %d %d %d\n", start_count, end_count, start_line, end_line, fenced, alone }
  ' "$1"
}

# pr_review_body_section <pr-body>: the block between the markers, markers
# included; nothing when there is none or the markers are duplicated,
# unbalanced, misordered, fenced or not alone on their line.
pr_review_body_section() {
  local scratch scan start_count end_count start_line end_line fenced alone
  scratch="$(mktemp)" || return 0
  printf '%s\n' "$1" | tr -d '\r' >"$scratch"
  scan="$(pr_review_marker_scan "$scratch")"
  read -r start_count end_count start_line end_line fenced alone <<EOF
$scan
EOF
  if [ "${start_count:-0}" -eq 1 ] && [ "${end_count:-0}" -eq 1 ] \
    && [ "${fenced:-0}" -eq 0 ] && [ "${alone:-0}" -eq 0 ] \
    && [ "$end_line" -gt "$start_line" ]; then
    sed -n "${start_line},${end_line}p" "$scratch"
  fi
  rm -f "$scratch"
  return 0
}

# _pr_review_stray_commits <repo-dir> <reviewed-head> <head-sha> <base-tip> <fix-commits>
# Prints the short sha of each first-parent commit in reviewed..head that is
# neither a recorded review fix nor a merge whose other parents are all
# ancestors of the base tip. Exit 2 when the range cannot be read.
_pr_review_stray_commits() {
  local repo_directory="$1" reviewed_head="$2" head_sha="$3" base_tip="$4" fix_commits="$5"
  local listing line sha parent exempt
  local -a fields
  [[ "$reviewed_head" =~ ^[0-9a-f]{40}$ ]] && [[ "$head_sha" =~ ^[0-9a-f]{40}$ ]] || return 2
  listing="$(git -C "$repo_directory" rev-list --first-parent --parents --reverse "$reviewed_head..$head_sha" 2>/dev/null)" || return 2
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    read -r -a fields <<<"$line"
    sha="${fields[0]}"
    case $'\n'"$fix_commits"$'\n' in
      *$'\n'"$sha"$'\n'*) continue ;;
    esac
    exempt=0
    if [ "${#fields[@]}" -gt 2 ]; then
      exempt=1
      for parent in "${fields[@]:2}"; do
        if [ -z "$base_tip" ] || ! git -C "$repo_directory" merge-base --is-ancestor "$parent" "$base_tip" 2>/dev/null; then
          exempt=0
        fi
      done
    fi
    [ "$exempt" -eq 1 ] || printf '%s\n' "${sha:0:7}"
  done <<EOF
$listing
EOF
  return 0
}

_pr_review_plural() {
  if [ "$1" -eq 1 ]; then printf '%s' "$2"; else printf '%s' "$3"; fi
}

pr_review_verdict() {
  local record="$1" pr="$2" body="$3" out_of_scope="$4" repo_directory="$5" head_sha="$6" base_tip="$7"
  local section view form="" reason="" undecided=0 unfixed=0 reviewed_head=""
  local fix_commits="" strays status

  case "$pr" in
    '' | *[!0-9]*)
      printf 'no review record for PR #%s\n' "$pr"
      return 1
      ;;
  esac
  if [ -z "${PR_BODY_HEADING_PR_REVIEW:-}" ]; then
    printf 'PR review heading library missing (.gaia/scripts/pr-body-sections-lib.sh) for PR #%s\n' "$pr"
    return 1
  fi
  section="$(pr_review_body_section "$body")"

  if [ -n "$record" ]; then
    if ! printf '%s' "$record" | jq -e 'type == "object" and (.findings | type) == "array"' >/dev/null 2>&1; then
      printf 'record findings changed after outcome on PR #%s\n' "$pr"
      return 1
    fi
    if ! printf '%s' "$record" | jq -e --argjson pr "$pr" '.pr == $pr' >/dev/null 2>&1; then
      printf 'no review record for PR #%s\n' "$pr"
      return 1
    fi
    view="$(printf '%s' "$record" | jq -r "$_PR_REVIEW_RECORD_VIEW_JQ")"
  else
    printf 'no review record for PR #%s\n' "$pr"
    return 1
  fi
  {
    IFS= read -r form
    IFS= read -r reason
    IFS= read -r undecided
    IFS= read -r unfixed
    IFS= read -r reviewed_head
  } <<EOF
$view
EOF

  if [ "$form" = open ]; then
    printf 'no review record for PR #%s\n' "$pr"
    return 1
  fi
  local recorded_digest
  recorded_digest="$(printf '%s' "$record" | jq -r '.findings_sha256 // ""')"
  if [ -n "$recorded_digest" ] || [ "$form" = ran ] \
    || [ "$(printf '%s' "$record" | jq '.findings | length')" -ne 0 ]; then
    if [ "$recorded_digest" != "$(pr_review_findings_digest "$record")" ]; then
      printf 'record findings changed after outcome on PR #%s\n' "$pr"
      return 1
    fi
  fi
  if [ "$form" = not-run ]; then
    printf 'not run on PR #%s (%s); a human decides\n' "$pr" "$reason"
    return 1
  fi
  if [ "$form" = ran ] && [ "$undecided" -gt 0 ]; then
    printf '%s %s no disposition on PR #%s\n' "$undecided" "$(_pr_review_plural "$undecided" 'finding has' 'findings have')" "$pr"
    return 1
  fi
  if [ "$form" = ran ] && [ "$unfixed" -gt 0 ]; then
    printf '%s %s not yet fixed on PR #%s\n' "$unfixed" "$(_pr_review_plural "$unfixed" 'fix finding' 'fix findings')" "$pr"
    return 1
  fi
  if [ "$form" != ran ]; then
    printf 'PR body section missing or stale on PR #%s\n' "$pr"
    return 1
  fi
  if [ "$section" != "$(pr_review_render_section "$record")" ]; then
    printf 'PR body section missing or stale on PR #%s\n' "$pr"
    return 1
  fi

  if [ "$out_of_scope" = 1 ]; then
    fix_commits="$(printf '%s' "$record" | jq -r '.review_fix_commits[]? | strings')"
    status=0
    strays="$(_pr_review_stray_commits "$repo_directory" "$reviewed_head" "$head_sha" "$base_tip" "$fix_commits")" || status=$?
    if [ "$status" -ne 0 ]; then
      printf 'commits after the review on PR #%s: range %s..%s unreadable\n' "$pr" "${reviewed_head:0:7}" "${head_sha:0:7}"
      return 1
    fi
    if [ -n "$strays" ]; then
      printf 'commits after the review on PR #%s: %s\n' "$pr" "$(printf '%s' "$strays" | tr '\n' ' ' | sed 's/ $//')"
      return 1
    fi
  fi
  return 0
}
