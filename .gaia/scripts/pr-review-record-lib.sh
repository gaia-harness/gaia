# shellcheck shell=bash
# shellcheck disable=SC2016,SC2034
#
# The reviewer-file validation, the disposition rules and the fix routing of
# pr-review-record.sh, split out to keep that script small. Sourced by it, and it
# relies on the script's SCRIPT_DIRECTORY, ROOT, RUN_FOLDER, MAIN_ROOT,
# NORMALIZED_BRANCH, RECORD_FILE, CHANGED_FILES_COPY, the argument variables,
# die_usage, refuse, install_record, require_record and require_open_record.
# Defines functions only. Never `cd`s outside a subshell.
#
# The fix routing writes the audit loop's veto through _veto_recorded_fix, the
# one writer of vetoes.json, so the key, its lock and its round arithmetic stay
# the audit's own. ROOT is the audited checkout; what _veto_recorded_fix and
# _veto_withdraw need is in audit-recorded-decision-lib.sh's header.

# shellcheck source=/dev/null
. "$SCRIPT_DIRECTORY/audit-triage-lib.sh"
# shellcheck source=/dev/null
. "$SCRIPT_DIRECTORY/audit-recorded-decision-lib.sh"
# shellcheck source=/dev/null
. "$SCRIPT_DIRECTORY/../../.claude/hooks/lib/audit-scope.sh"
# shellcheck source=/dev/null
. "$SCRIPT_DIRECTORY/../../.claude/hooks/lib/audit-base-provenance.sh"

_error() { printf 'pr-review-record: %s\n' "$*" >&2; }

# _evaluator <subcommand> [args...]: audit-loop-eval.sh on ROOT, stderr dropped.
_evaluator() {
  local subcommand="$1"
  shift
  bash "$SCRIPT_DIRECTORY/audit-loop-eval.sh" "$subcommand" --root "$ROOT" "$@" 2>/dev/null
}

# require_main_root_match: --root names a checkout of the run folder's
# repository. Compared physically, so a symlinked path never reads as another.
require_main_root_match() {
  local resolved physical_main physical_resolved
  case "$ROOT" in /*) ;; *) die_usage "--root must be an absolute path" ;; esac
  ROOT="${ROOT%/}"
  [ "$ROOT" = "$MAIN_ROOT" ] && return 0
  resolved="$(gaia_resolve_main_root "$ROOT" 2>/dev/null)" || die_usage "--root does not resolve to a main checkout: $ROOT"
  physical_main="$(cd "$MAIN_ROOT" 2>/dev/null && pwd -P)" || physical_main="$MAIN_ROOT"
  physical_resolved="$(cd "$resolved" 2>/dev/null && pwd -P)" || physical_resolved="$resolved"
  [ "$physical_resolved" = "$physical_main" ] || die_usage "--root belongs to $resolved, not the run folder's main root $MAIN_ROOT"
}

# audited_root: a checkout whose current branch is the run folder's branch, which
# is the root the audit loop's evaluator keys its state by. --root itself when it
# is on that branch, else a linked worktree that is.
audited_root() {
  local candidate
  while IFS= read -r candidate; do
    [ -n "$candidate" ] || continue
    if [ "$(gaia_loop_key "$candidate" 2>/dev/null)" = "$NORMALIZED_BRANCH" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done <<EOF
$ROOT
$(_gaia_loop_git -C "$ROOT" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p')
EOF
  die_usage "no checkout of branch $NORMALIZED_BRANCH under $ROOT"
}

# finding_field <jq-expression>: the field of the --id finding, as raw text.
finding_field() {
  jq -r --arg id "$FINDING_ID" ".findings[] | select(.id == \$id) | $1" "$RECORD_FILE"
}

require_finding() {
  [[ "$FINDING_ID" =~ ^pr-[1-9][0-9]*$ ]] || die_usage "--id must be pr-<n>"
  jq -e --arg id "$FINDING_ID" 'any(.findings[]; .id == $id)' "$RECORD_FILE" >/dev/null || die_usage "no finding $FINDING_ID in the record"
}

# update_finding <jq-filter> [jq-args...]: apply the filter to the --id finding.
update_finding() {
  local filter="$1"
  shift
  jq --arg id "$FINDING_ID" "$@" '.findings |= map(if .id == $id then ('"$filter"') else . end)' "$RECORD_FILE" | install_record
}

# --- outcome ------------------------------------------------------------------

NOT_AN_ARRAY_REFUSAL='reviewer output must be a JSON array of findings'

# The first schema refusal of the reviewer's file, in entry order and, within an
# entry, in the order below. `security` is not checked: a missing or non-boolean
# value is stored as true instead.
REVIEWER_FILE_JQ='
def required: ["file", "line", "severity", "summary", "failure_scenario", "verified"];
def allowed: ["file", "line", "severity", "security", "summary", "failure_scenario", "verified"];
if length != 1 or (.[0] | type) != "array" or any(.[0][]; type != "object") then $not_an_array
else .[0]
  | [.[] | (
      ((required - keys)[0] | select(. != null) | "missing key: \(.)"),
      ((keys - allowed)[0] | select(. != null) | "unknown key: \(.)"),
      (select((.severity | IN("Critical", "Major", "Minor")) | not) | "severity must be Critical, Major or Minor"),
      (select((.line | type == "null" or (type == "number" and . == floor and . >= 1)) | not) | "line must be a positive integer or null"),
      (select((.verified | type) != "boolean") | "verified must be boolean"),
      (select((.summary | type) != "string") | "summary must be a string"),
      (select((.failure_scenario | type) != "string") | "failure_scenario must be a string"),
      (.file as $file | select(($file | type == "string"
          and ($file == "PR body" or ($changelog and $file == "CHANGELOG.md") or any($changed | split("\n")[]; . == $file))) | not)
        | "file not in this PR: \($file | if type == "string" then . else tojson end)")
    )] | .[0] // empty
end'

# install_record_with_digest: install the record on stdin with its findings
# digest set, fixing the findings at this outcome.
install_record_with_digest() {
  local record digest
  record="$(cat)"
  digest="$(pr_review_findings_digest "$record")"
  printf '%s' "$record" | jq --arg digest "$digest" '.findings_sha256 = $digest' | install_record
}

# record_refusal <line>: the refusal closes the open attempt as a no-op. With no
# attempt open, the latest attempt the classifier passed is the one the schema
# contradicts.
record_refusal() {
  jq --arg refusal "$1" '
    (([.attempts[] | select(.state == "open") | .n] | first)
      // ([.attempts[] | select(.state == "closed" and .classifier_exit == 0) | .n] | last)) as $number
    | if $number == null then .
      else .attempts |= map(if .n == $number then .state = "closed" | .classifier_exit = 1 | .dispatch_failed = false | .refusal = $refusal else . end) end' \
    "$RECORD_FILE" | install_record
}

cmd_outcome() {
  [ -n "$FINDINGS_FILE" ] || die_usage "--findings is required"
  require_record
  require_open_record
  [ -f "$CHANGED_FILES_COPY" ] || die_usage "no changed-file list beside the record: open the review first"
  local refusal
  refusal="$(jq -r -s --rawfile changed "$CHANGED_FILES_COPY" --argjson changelog "$(jq '.changelog_present' "$RECORD_FILE")" \
    --arg not_an_array "$NOT_AN_ARRAY_REFUSAL" "$REVIEWER_FILE_JQ" "$FINDINGS_FILE" 2>/dev/null)" || refusal="$NOT_AN_ARRAY_REFUSAL"
  if [ -n "$refusal" ]; then
    record_refusal "$refusal"
    printf '%s\n' "$refusal"
    exit 3
  fi
  jq --slurpfile reviewer "$FINDINGS_FILE" '
    .outcome = "ran"
    | .attempts |= map(if .state == "open" then .state = "closed" | .classifier_exit = 0 else . end)
    | .findings = [$reviewer[0] | to_entries[] | .key as $index | .value | {id: "pr-\($index + 1)", file, line, severity,
        security: (if (.security | type) == "boolean" then .security else true end), summary, failure_scenario, verified,
        disposition: null, reason: null, issue: null, basis: null, fix_route: null, fix_state: null, dropped_by: null, fix_commits: []}]' \
    "$RECORD_FILE" | install_record_with_digest
}

cmd_not_run() {
  case "$REASON" in
    'reviewer silent twice' | 'reviewer agent not loaded') ;;
    *) refuse "unknown not-run reason" ;;
  esac
  require_record
  require_open_record
  if [ "$REASON" = 'reviewer silent twice' ]; then
    jq -e '(.attempts | length) == 2 and all(.attempts[]; .state == "closed" and .classifier_exit == 1)' "$RECORD_FILE" >/dev/null ||
      refuse "not run needs two closed no-op attempts"
  else
    jq -e '(.attempts | last) as $latest | $latest != null and $latest.state == "closed" and $latest.dispatch_failed == true' "$RECORD_FILE" >/dev/null ||
      refuse "not run needs the latest attempt closed as dispatch-failed"
  fi
  jq --arg reason "$REASON" '.outcome = "not-run" | .not_run_reason = $reason | .findings = []' "$RECORD_FILE" | install_record_with_digest
}

# --- dispositions ---------------------------------------------------------------

# The first rule a disposition breaks, as {kind: "usage"|"refusal", line}, or
# nothing. The set and the Critical, security, reason, issue and basis rules are
# the audit's (audit-dispositions-grade-lib.sh), plus `dismiss`; divert is the
# audit's own refusal for a finding no member authored. A Critical or
# security-class finding takes fix, except `dismiss` once its fix was dropped
# with evidence: the reopened finding then has a human-visible way to close.
DISPOSE_JQ='
def trim: gsub("^\\s+|\\s+$"; "");
def usage($line): {kind: "usage", line: $line};
def refusal($line): {kind: "refusal", line: $line};
. as $finding
| ($reason | trim) as $reason_text
| [
    (select($disposition | IN("fix", "file", "accept-residual", "waive-out-of-scope", "dismiss", "divert") | not) | usage("unknown disposition: \($disposition)")),
    (select(($severity != "" and $severity != $finding.severity) or ($security != "" and ($security == "true") != $finding.security))
      | refusal("finding class is fixed at the reviewer'"'"'s output")),
    (select($disposition == "divert") | refusal("divert-not-allowed: \($finding.id)")),
    (select(($finding.severity == "Critical" or $finding.security) and $disposition != "fix" and ($finding.fix_state == "dropped" and $disposition == "dismiss" | not)) | refusal("a Critical or security-class finding takes fix")),
    (select(($finding.fix_state | IN("routed", "fixed")) and $disposition != "fix") | refusal("\($finding.id) has a fix routed or fixed")),
    (select($disposition == "accept-residual" and ($accepted | not)) | refusal("accept-residual needs a human accept: \($finding.id)")),
    (select($disposition | IN("dismiss", "file", "waive-out-of-scope", "accept-residual")) | select($reason_text == "") | refusal("empty-reason: \($finding.id)")),
    (select($disposition == "file" and ($issue | test("^[1-9][0-9]{0,9}$") | not)) | refusal("file needs an issue number: \($finding.id)")),
    (select($disposition == "waive-out-of-scope" and ($basis | IN("triage-threshold", "cross-remit") | not))
      | refusal("missing-basis: \($finding.id) (waive-out-of-scope needs --basis triage-threshold or cross-remit)"))
  ] | .[0] // empty'

cmd_dispose() {
  [ -n "$DISPOSITION" ] || die_usage "--disposition is required"
  case "$SECURITY" in '' | true | false) ;; *) die_usage "--security must be true or false" ;; esac
  require_record
  require_finding
  local accept_file="$MAIN_ROOT/.gaia/local/protected/pr-review-accepts/$NORMALIZED_BRANCH.json" accepted=false decision pr_number
  pr_number="$(jq -r '.pr' "$RECORD_FILE")"
  if jq -e --argjson pr "$pr_number" --arg id "$FINDING_ID" 'any(.accepted[]?; .pr == $pr and .id == $id)' "$accept_file" >/dev/null 2>&1; then
    accepted=true
  fi
  decision="$(finding_field '.' | jq -r --arg disposition "$DISPOSITION" --arg reason "$REASON" --arg issue "$ISSUE" --arg basis "$BASIS" \
    --arg severity "$SEVERITY" --arg security "$SECURITY" --argjson accepted "$accepted" "$DISPOSE_JQ" --compact-output)"
  if [ -n "$decision" ]; then
    if [ "$(jq -r '.kind' <<<"$decision")" = usage ]; then die_usage "$(jq -r '.line' <<<"$decision")"; fi
    refuse "$(jq -r '.line' <<<"$decision")"
  fi
  update_finding '.disposition = $disposition
    | .reason = (if ($reason | test("\\S")) then $reason else null end)
    | .issue = (if $disposition == "file" then ($issue | tonumber) else null end)
    | .basis = (if $disposition == "waive-out-of-scope" then $basis else null end)' \
    --arg disposition "$DISPOSITION" --arg reason "$REASON" --arg issue "$ISSUE" --arg basis "$BASIS"
}

# --- fix routing ------------------------------------------------------------------

# gaia:maintainer-only:start
MAINTAINER_MARKER=".claude/rules/maintainers/harness-triage-threshold.md"
# gaia:maintainer-only:end

# decide_route <audited-root> <file>: prints `body`, `changelog`, `veto <owner>`
# or `human`.
decide_route() {
  local audited="$1" file="$2" owner
  if [ "$file" = "PR body" ]; then
    printf 'body\n'
    return 0
  fi
  # gaia:maintainer-only:start
  if [ "$file" = "CHANGELOG.md" ] && _gaia_loop_git -C "$audited" ls-files --error-unmatch -- "$MAINTAINER_MARKER" >/dev/null 2>&1; then
    printf 'changelog\n'
    return 0
  fi
  # gaia:maintainer-only:end
  # No roster is no owner: the fix goes to a human, the safe direction.
  if audit_scope_init "$audited" 2>/dev/null; then
    audit_scope_release_context "$audited" "$(audit_local_base_reference "$audited" 2>/dev/null)"
    owner="$(audit_owner_for_path "$file")"
  else
    owner=""
  fi
  if [ -n "$owner" ]; then printf 'veto %s\n' "$owner"; else printf 'human\n'; fi
}

# veto_row: the finding's veto row, the key the veto ledger records it under.
veto_row() {
  jq -n -c --arg class "pr-review/$FINDING_ID" --arg path "$(finding_field '.file')" --argjson line "$(finding_field '.line // 1')" \
    '{member: "pr-reviewer", finding_class: $class, path: $path, line: $line}'
}

cmd_route_fix() {
  require_main_root_match
  require_record
  require_finding
  [ "$(finding_field '.disposition')" = fix ] || refuse "$FINDING_ID is not disposed fix"
  [ "$(finding_field '.fix_state')" != fixed ] || refuse "$FINDING_ID is already fixed"
  local file summary route first_time=1 finding_file row
  file="$(finding_field '.file')"
  [ "$(finding_field '.fix_state')" != routed ] || first_time=0
  ROOT="$(audited_root)"
  route="$(decide_route "$ROOT" "$file")"
  case "$route" in
    veto*)
      if [ "$first_time" -eq 1 ]; then
        summary="$(finding_field '.summary | gsub("[\\r\\n]+"; " ")')"
        finding_file="$(mktemp)"
        row="$(veto_row)"
        jq -n --arg reason "$summary" '{reason: $reason}' >"$finding_file"
        FINDING_FILE="$finding_file"
        _veto_recorded_fix "$row" || { rm -f "$finding_file"; exit 2; }
        rm -f "$finding_file"
      fi
      update_finding '.fix_route = "veto" | .fix_state = "routed"'
      printf '%s\n' "$route"
      ;;
    human)
      update_finding '.fix_route = "human" | .fix_state = "routed"'
      printf 'PR review: fix needs a human on an unowned path: %s\n' "$file"
      exit 4
      ;;
    *)
      update_finding '.fix_route = $route | .fix_state = "routed"' --arg route "$route"
      printf '%s\n' "$route"
      ;;
  esac
}

cmd_fixed() {
  require_main_root_match
  require_record
  require_finding
  [ "$(finding_field '.fix_state')" = routed ] || refuse "$FINDING_ID has no routed fix"
  local route key full_commit=""
  route="$(finding_field '.fix_route')"
  ROOT="$(audited_root)"
  if [ "$route" = veto ]; then
    key="$(veto_row | jq -c '[.member, .finding_class, .path, .line]')"
    _evaluator veto-state | jq -e --argjson key "$key" '.satisfied | any(. == $key)' >/dev/null ||
      refuse "$FINDING_ID: the veto is not satisfied yet"
  fi
  if [ "$route" = changelog ] || [ "$route" = human ]; then
    [ -n "$COMMIT" ] || refuse "$FINDING_ID: a $route fix needs --commit <sha>"
  fi
  if [ -n "$COMMIT" ]; then
    full_commit="$(_gaia_loop_git -C "$ROOT" rev-parse --verify --quiet "$COMMIT^{commit}")" || die_usage "--commit is not a commit: $COMMIT"
  fi
  jq --arg id "$FINDING_ID" --arg commit "$full_commit" '
    .findings |= map(if .id == $id then .fix_state = "fixed" | .fix_commits += (if $commit == "" then [] else [$commit] end) else . end)
    | .review_fix_commits |= (if $commit == "" then . else (. + [$commit] | unique) end)' "$RECORD_FILE" | install_record
}

cmd_dropped() {
  [ -n "$MEMBER" ] || die_usage "--by is required"
  printf '%s' "$EVIDENCE" | grep -q '[^[:space:]]' || die_usage "--evidence is required"
  require_record
  require_finding
  [ "$(finding_field '.fix_state')" = routed ] || refuse "$FINDING_ID has no routed fix to drop"
  if [ "$(finding_field '.fix_route')" = veto ]; then
    # A binding veto left unsatisfied would keep the dispositions check failing.
    _veto_withdraw "$(veto_row)" || exit 2
  fi
  update_finding '.dropped_by = "\($member): \($evidence | gsub("[\\r\\n]+"; " "))" | .fix_state = "dropped" | .disposition = null | .reason = null' \
    --arg member "$MEMBER" --arg evidence "$EVIDENCE"
}
