#!/usr/bin/env bats
#
# Suite for .gaia/scripts/audit-dispositions-check.sh: the dispositions rules
# graded from the findings sidecars, frozen snapshots, forward-only vetoes,
# the waiver table and the PR-body sections.
#
# Fixtures are real: a repo with a branch-added file, a seeded branch state, a
# stamp and baseline per round, and findings sidecars with controlled mtimes
# (.gaia/tests/helpers/audit-loop-fixture.sh). Dispositions files sit in the
# branch's run folder.
#
# Run: .gaia/scripts/bats5.sh .gaia/scripts/tests/audit-dispositions-check.bats < /dev/null
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

bats_require_minimum_version 1.5.0

setup_file() {
  # shellcheck source=/dev/null
  . "$BATS_TEST_DIRNAME/../../tests/helpers/audit-loop-fixture.sh"
  alf_build_template
}

setup() {
  build_fixture
}

# reset_fixture: rebuild the setup fixture from scratch inside a merged case
# table, for a row that opens rounds, writes snapshots or vetoes the next row
# must not see.
reset_fixture() {
  rm -rf "$BATS_TEST_TMPDIR/repo" "$BATS_TEST_TMPDIR/origin.git" "$BATS_TEST_TMPDIR/mutant" "$BATS_TEST_TMPDIR/mutant-tree" "$GH_CALLS"
  build_fixture
}

build_fixture() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SCRIPTS="$REPO_ROOT/.gaia/scripts"
  SCRIPT="$SCRIPTS/audit-dispositions-check.sh"
  # shellcheck source=/dev/null
  . "$REPO_ROOT/.gaia/tests/helpers/audit-loop-fixture.sh"
  alf_init
  alf_branch feat/disp
  MEMBER=code-audit-frontend
  alf_fill f.txt 12 feature
  alf_commit "feature"
  RUN_FOLDER="$ALF_ROOT/.gaia/local/runs/$ALF_NORMALIZED_BRANCH"
  SNAPSHOT_DIRECTORY="$ALF_ROOT/.gaia/local/protected/audit-loop/$ALF_NORMALIZED_BRANCH.d"
  mkdir -p "$RUN_FOLDER"
  # f.txt:1 authored Critical, :2 security Minor, :3 Major,
  # base.txt:3 Critical outside the branch diff, :4 cross-remit Major,
  # :5 no security field, :6 Minor; base.txt:5 security Minor,
  # base.txt:6 Major and base.txt:7 Major with no security field, all
  # outside the branch diff.
  FINDINGS_JSON='[
    {"path":"f.txt","line":1,"finding_class":"c/crit","severity":"critical","security":false},
    {"path":"f.txt","line":2,"finding_class":"c/sec","severity":"minor","security":true},
    {"path":"f.txt","line":3,"finding_class":"c/imp","severity":"major","security":false},
    {"path":"base.txt","line":3,"finding_class":"c/oos","severity":"critical","security":false},
    {"path":"f.txt","line":4,"finding_class":"c/xr","severity":"major","security":false,"cross_remit":true},
    {"path":"f.txt","line":5,"finding_class":"c/nosec","severity":"major"},
    {"path":"f.txt","line":6,"finding_class":"c/sug","severity":"minor","security":false},
    {"path":"base.txt","line":5,"finding_class":"c/oossec","severity":"minor","security":true},
    {"path":"base.txt","line":6,"finding_class":"c/oosimp","severity":"major","security":false},
    {"path":"base.txt","line":7,"finding_class":"c/oosnosec","severity":"major"}
  ]'
  open_round 1 "$FINDINGS_JSON"
  # A gh stub logging each call with the GH_REPO it saw. The repository
  # resolution answers owner/repo; the visibility read answers $GH_VISIBILITY,
  # failing when that is unset or empty and printing nothing for __empty__.
  GH_CALLS="$BATS_TEST_TMPDIR/gh-calls"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s GH_REPO=%s\n' "$*" "${GH_REPO-unset}" >>"$GH_CALLS"
case "$*" in *nameWithOwner*) printf 'owner/repo\n'; exit 0 ;; esac
case "${GH_VISIBILITY-}" in '') exit 1 ;; __empty__) exit 0 ;; esac
printf '%s\n' "$GH_VISIBILITY"
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  export GH_CALLS
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  export GH_VISIBILITY=PUBLIC
}

# open_round <round> <findings-json>: record round r on HEAD with its stamp,
# baseline and sidecar (a later round overwrites the same sidecar path).
open_round() {
  alf_add_round "[\"$MEMBER\"]"
  alf_stamp "$1" $((10 * $1))
  alf_baseline "$1" $((10 * $1 + 5))
  alf_sidecar "$MEMBER" "$2" $((10 * $1 + 1))
}

# disposition_entry <path> <line> <class> <disposition> [reason] [basis]: one entry.
disposition_entry() {
  jq -n -c --arg path "$1" --argjson line "$2" --arg finding_class "$3" --arg disposition "$4" --arg reason "${5-because}" --arg basis "${6-}" \
    '{member: "code-audit-frontend", finding_class: $finding_class, path: $path, line: $line, disposition: $disposition, reason: $reason}
     + (if $basis == "" then {} else {basis: $basis} end)'
}

# write_dispositions <r> <entries-array-json> [enforcement-json]: write dispositions-<r>.json.
write_dispositions() {
  jq -n -c --argjson round "$1" --argjson entries "$2" --argjson enforcement_paths "${3-[]}" \
    '{schema: 1, round: $round, entries: $entries, enforcement_paths_allowed: $enforcement_paths}' >"$RUN_FOLDER/dispositions-$1.json"
}

# fill <findings-json> <entries-json> [jq-filter]: the entries plus a fix entry
# for every finding they leave out, of any authorship, narrowed by the optional
# filter, so a green fixture disposes every finding it does not name.
fill() {
  jq -n -c --argjson findings "$1" --argjson entries "$2" "
    \$entries + [\$findings[] | ${3:-.}
      | select([.finding_class, .path, .line] as \$key | any(\$entries[]; [.finding_class, .path, .line] == \$key) | not)
      | {member: \"code-audit-frontend\", finding_class, path, line, disposition: \"fix\", reason: \"\"}]"
}

# key_json <class> <path> <line>: the compact key json a violation line carries.
key_json() {
  printf '{"member":"code-audit-frontend","finding_class":"%s","path":"%s","line":%s}' "$1" "$2" "$3"
}

# run_check <round> [flags...]: the live check.
run_check() {
  local round="$1"
  shift
  run bash "$SCRIPT" check --root "$ALF_ROOT" --run-folder "$RUN_FOLDER" --round "$round" "$@"
}

# run_check_all [flags...]
run_check_all() {
  run bash "$SCRIPT" check-all --root "$ALF_ROOT" --run-folder "$RUN_FOLDER" "$@"
}

# check_filled <entries-json> [enforcement-json]: round 1's dispositions, the
# entries plus a fix for every other finding, then the live check.
check_filled() {
  write_dispositions 1 "$(fill "$FINDINGS_JSON" "$1")" "${2-[]}"
  run_check 1
}

# red <token> <key-json>: the last run exited 1 with exactly that line.
red() {
  [ "$status" -eq 1 ] || { echo "status $status: $output"; return 1; }
  grep -qxF -- "violation: $1 $2" <<<"$output" || { echo "missing violation: $1 $2 in: $output"; return 1; }
}

# green: the last run exited 0.
green() {
  [ "$status" -eq 0 ] || { echo "status $status: $output"; return 1; }
}

# vetoes <effective_from_round> <class> <path> <line>
vetoes() {
  jq -n -c --argjson effective_from_round "$1" --arg finding_class "$2" --arg path "$3" --argjson line "$4" \
    '{version: 1, keys: [{member: "code-audit-frontend", finding_class: $finding_class, path: $path, line: $line, vetoed_at: "t", unit: 1, effective_from_round: $effective_from_round}]}' \
    >"$RUN_FOLDER/vetoes.json"
}

# bats test_tags=protected
@test "check: each dispositions rule refuses its own kind on its key and each allowed disposition passes (case table)" {
  local reason entry
  printf 'case: %s\n' 'branch Critical as accept-residual, waive-out-of-scope, file' >&2
  check_filled "[$(disposition_entry f.txt 1 c/crit accept-residual)]"
  red critical-not-fix "$(key_json c/crit f.txt 1)" || return 1
  check_filled "[$(disposition_entry f.txt 1 c/crit waive-out-of-scope because triage-threshold)]"
  red critical-not-fix "$(key_json c/crit f.txt 1)" || return 1
  check_filled "[$(disposition_entry f.txt 1 c/crit file)]"
  red critical-not-fix "$(key_json c/crit f.txt 1)" || return 1
  printf 'case: %s\n' 'Critical relabelled major inside the entry' >&2
  entry="$(disposition_entry f.txt 1 c/crit waive-out-of-scope because triage-threshold | jq -c '. + {severity: "major", security: false}')"
  check_filled "[$entry]"
  red critical-not-fix "$(key_json c/crit f.txt 1)" || return 1
  printf 'case: %s\n' 'security true Minor and no security field waived' >&2
  check_filled "[$(disposition_entry f.txt 2 c/sec waive-out-of-scope because triage-threshold)]"
  red security-not-fix "$(key_json c/sec f.txt 2)" || return 1
  check_filled "[$(disposition_entry f.txt 5 c/nosec waive-out-of-scope because triage-threshold)]"
  red security-not-fix "$(key_json c/nosec f.txt 5)" || return 1
  printf 'case: %s\n' 'empty and whitespace-only reasons' >&2
  for reason in "" "   "; do
    check_filled "[$(disposition_entry f.txt 3 c/imp waive-out-of-scope "$reason" triage-threshold)]"
    red empty-reason "$(key_json c/imp f.txt 3)" || return 1
  done
  check_filled "[$(disposition_entry f.txt 3 c/imp accept-residual "")]"
  red empty-reason "$(key_json c/imp f.txt 3)" || return 1
  printf 'case: %s\n' 'enforcement_paths_allowed' >&2
  check_filled "[$(disposition_entry f.txt 3 c/imp fix)]" '["x"]'
  red enforcement-paths-set '["x"]' || return 1
  printf 'case: %s\n' 'basis' >&2
  check_filled "[$(disposition_entry f.txt 3 c/imp waive-out-of-scope because)]"
  red missing-basis "$(key_json c/imp f.txt 3)" || return 1
  check_filled "[$(disposition_entry f.txt 3 c/imp waive-out-of-scope because cross-remit)]"
  red cross-remit-basis-mismatch "$(key_json c/imp f.txt 3)" || return 1
  printf 'case: %s\n' 'unknown key' >&2
  check_filled "[$(disposition_entry f.txt 9 c/ghost waive-out-of-scope because triage-threshold)]"
  red unknown-key "$(key_json c/ghost f.txt 9)" || return 1
  check_filled "[$(disposition_entry f.txt 9 c/ghost fix)]"
  green || return 1
  printf 'case: %s\n' 'divert' >&2
  check_filled "[$(disposition_entry base.txt 3 c/oos divert "")]"
  red empty-reason "$(key_json c/oos base.txt 3)" || return 1
  check_filled "[$(disposition_entry f.txt 2 c/sec divert "security class")]"
  red divert-not-allowed "$(key_json c/sec f.txt 2)" || return 1
  check_filled "[$(disposition_entry base.txt 6 c/oosimp divert "not security")]"
  red divert-not-allowed "$(key_json c/oosimp base.txt 6)" || return 1
  check_filled "[$(disposition_entry base.txt 3 c/oos divert "security class"),$(disposition_entry base.txt 5 c/oossec divert "security class"),$(disposition_entry base.txt 7 c/oosnosec divert "no security flag")]"
  green || return 1
  printf 'case: %s\n' 'allowed controls' >&2
  check_filled "[$(disposition_entry f.txt 6 c/sug waive-out-of-scope "below threshold" triage-threshold)]"
  green || return 1
  check_filled "[$(disposition_entry f.txt 4 c/xr waive-out-of-scope "other member's remit" cross-remit)]"
  green || return 1
  printf 'case: %s\n' 'security true Major waived (round 2, last: it overwrites the sidecar)' >&2
  open_round 2 '[{"path":"f.txt","line":7,"finding_class":"c/majsec","severity":"major","security":true}]'
  write_dispositions 2 "[$(disposition_entry f.txt 7 c/majsec waive-out-of-scope because triage-threshold)]"
  run_check 2
  red security-not-fix "$(key_json c/majsec f.txt 7)"
}

@test "security-file-not-private: each security-class out-of-branch kind and each non-PRIVATE answer refuses, only an exact PRIVATE passes, a non-security file never probes (case table)" {
  local visibility line_number finding_class
  printf 'case: %s\n' 'non-security Major filed on a PUBLIC repository passes without probing' >&2
  write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$(disposition_entry base.txt 6 c/oosimp file "filed upstream")]")"
  run_check 1
  green || return 1
  [ ! -e "$GH_CALLS" ] || { echo "probed: $(cat "$GH_CALLS")"; return 1; }
  printf 'case: %s\n' 'security true Minor filed on INTERNAL and on a failed probe' >&2
  write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$(disposition_entry base.txt 5 c/oossec file "filed upstream")]")"
  for visibility in INTERNAL ''; do
    GH_VISIBILITY="$visibility"
    run_check 1
    red security-file-not-private "$(key_json c/oossec base.txt 5)" || return 1
  done
  printf 'case: %s\n' 'out-of-branch Critical, security true and security-absent filed on a PUBLIC repository' >&2
  GH_VISIBILITY=PUBLIC
  for line_number in 3 5 7; do
    finding_class="$(jq -r --argjson line "$line_number" '.[] | select(.path == "base.txt" and .line == $line) | .finding_class' <<<"$FINDINGS_JSON")"
    write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$(disposition_entry base.txt "$line_number" "$finding_class" file "filed upstream")]")"
    run_check 1
    red security-file-not-private "$(key_json "$finding_class" base.txt "$line_number")" || return 1
    grep -qF -- 'violation: empty-reason' <<<"$output" && { echo "empty-reason fired: $output"; return 1; }
  done
  printf 'case: %s\n' 'only an exact PRIVATE answer passes; the environment and a cache change nothing' >&2
  write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$(disposition_entry base.txt 3 c/oos file "filed upstream")]")"
  : >"$GH_CALLS"
  export GH_REPO=someone/private GAIA_REPO_VISIBILITY=PRIVATE REPO_VISIBILITY=PRIVATE VISIBILITY=PRIVATE
  printf 'PRIVATE\n' >"$ALF_ROOT/.gaia/local/repo-visibility"
  printf '{"visibility":"PRIVATE"}\n' >"$ALF_ROOT/.gaia/local/audit/visibility.json"
  for visibility in '' __empty__ PUBLIC INTERNAL private 'PRIVATE '; do
    GH_VISIBILITY="$visibility"
    run_check 1
    red security-file-not-private "$(key_json c/oos base.txt 3)" || { echo "visibility '$visibility'"; return 1; }
  done
  GH_VISIBILITY=PRIVATE
  run_check 1
  green || return 1
  grep -qxF -- 'repo view owner/repo --json visibility --jq .visibility GH_REPO=unset' "$GH_CALLS" || { cat "$GH_CALLS"; return 1; }
  grep -F -- 'GH_REPO=someone/private' "$GH_CALLS" && return 1
  true
}

@test "undisposed: each omitted finding kind fails, and an entry clears the kinds an entry may clear (case table)" {
  printf 'case: %s\n' 'omitted branch-authored Critical, then security finding' >&2
  write_dispositions 1 "$(fill "$FINDINGS_JSON" '[]' 'select(.line != 1)')"
  run_check 1
  red undisposed "$(key_json c/crit f.txt 1)" || return 1
  write_dispositions 1 "$(fill "$FINDINGS_JSON" '[]' 'select(.line != 2)')"
  run_check 1
  red undisposed "$(key_json c/sec f.txt 2)" || return 1
  printf 'case: %s\n' 'omitted out-of-branch Major, then the entry clears it' >&2
  accept_at 1
  write_dispositions 1 "$(fill "$FINDINGS_JSON" '[]' 'select(.path != "base.txt" or .line != 6)')"
  run_check 1
  red undisposed "$(key_json c/oosimp base.txt 6)" || return 1
  write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$(disposition_entry base.txt 6 c/oosimp accept-residual "left for later")]")"
  run_check 1
  green || return 1
  printf 'case: %s\n' 'vetoed key omitted, then every finding and vetoed key disposed but the out-of-branch Critical' >&2
  vetoes 1 c/gone f.txt 9
  write_dispositions 1 "$(fill "$FINDINGS_JSON" '[]')"
  run_check 1
  red undisposed "$(key_json c/gone f.txt 9)" || return 1
  write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$(disposition_entry f.txt 6 c/sug accept-residual later),$(disposition_entry f.txt 9 c/gone fix)]" 'select(.path != "base.txt" or .line != 3)')"
  run_check 1
  red undisposed "$(key_json c/oos base.txt 3)" || return 1
  write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$(disposition_entry f.txt 6 c/sug accept-residual later),$(disposition_entry f.txt 9 c/gone fix)]")"
  run_check 1
  green || return 1
  rm -f "$RUN_FOLDER/vetoes.json"
  printf 'case: %s\n' 'omitted branch-authored Minor, then a fix entry clears it (round 2, last: it overwrites the sidecar)' >&2
  open_round 2 '[{"path":"f.txt","line":7,"finding_class":"c/minorgap","severity":"minor","security":false}]'
  write_dispositions 2 '[]'
  run_check 2
  red undisposed "$(key_json c/minorgap f.txt 7)" || return 1
  write_dispositions 2 "[$(disposition_entry f.txt 7 c/minorgap fix)]"
  run_check 2
  green
}

@test "vetoes: bind forward only, a synthetic fix passes, check-all stays green (UAT-006)" {
  write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$(disposition_entry f.txt 3 c/imp waive-out-of-scope because triage-threshold)]")"
  run_check 1 --snapshot-dir "$SNAPSHOT_DIRECTORY"
  green
  vetoes 2 c/imp f.txt 3
  # a veto never re-grades the earlier round
  run_check 1
  green
  open_round 2 "$FINDINGS_JSON"
  write_dispositions 2 "$(fill "$FINDINGS_JSON" "[$(disposition_entry f.txt 3 c/imp accept-residual because)]")"
  run_check 2
  red vetoed-not-fix "$(key_json c/imp f.txt 3)" || return 1
  write_dispositions 2 "$(fill "$FINDINGS_JSON" "[$(disposition_entry f.txt 3 c/imp fix)]")"
  run_check 2
  green || return 1
  # no member re-reported the key in round 2: a synthetic fix entry passes
  alf_sidecar "$MEMBER" "$(jq -c '[.[] | select(.line == 6)]' <<<"$FINDINGS_JSON")" 22
  write_dispositions 2 "$(fill "$(jq -c '[.[] | select(.line == 6)]' <<<"$FINDINGS_JSON")" "[$(disposition_entry f.txt 3 c/imp fix)]")"
  run_check 2
  green || return 1
  run_check_all --snapshot-dir "$SNAPSHOT_DIRECTORY"
  green
}

@test "snapshots: check-all re-grades an overwritten round from an explicit or default-directory snapshot and fails unknown-key without one, writing nothing read-only (case table)" {
  local before after
  write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$(disposition_entry f.txt 3 c/imp waive-out-of-scope because triage-threshold)]")"
  run_check 1 --snapshot-dir "$SNAPSHOT_DIRECTORY"
  green || return 1
  [ -f "$SNAPSHOT_DIRECTORY/dispositions-1.checked.json" ] || return 1
  open_round 2 '[{"path":"f.txt","line":7,"finding_class":"c/later","severity":"minor","security":false}]'
  printf 'case: %s\n' 'explicit --snapshot-dir' >&2
  run_check_all --snapshot-dir "$SNAPSHOT_DIRECTORY"
  green || return 1
  printf 'case: %s\n' 'default directory snapshot, nothing written' >&2
  write_dispositions 2 "[$(disposition_entry f.txt 7 c/later fix)]"
  before="$(tree_state)"
  run_check_all
  green || return 1
  after="$(tree_state)"
  [ "$before" = "$after" ] || { printf 'a read-only check-all wrote:\n%s\n---\n%s\n' "$before" "$after" >&2; return 1; }
  [ ! -e "$SNAPSHOT_DIRECTORY/dispositions-2.checked.json" ] || return 1
  printf 'case: %s\n' 'default directory holds no snapshot for the round' >&2
  mv "$SNAPSHOT_DIRECTORY/dispositions-1.checked.json" "$BATS_TEST_TMPDIR/kept-snapshot.json"
  before="$(tree_state)"
  run_check_all
  red unknown-key "$(key_json c/imp f.txt 3)" || return 1
  [ "$before" = "$(tree_state)" ] || return 1
  printf 'case: %s\n' 'no snapshot directory at all' >&2
  rm -rf "$SNAPSHOT_DIRECTORY"
  run_check_all
  red unknown-key "$(key_json c/imp f.txt 3)"
}

# tree_state: every file under the run folder and the state directory with its
# digest, so a read that wrote anything differs from the one before it.
tree_state() {
  find "$RUN_FOLDER" "$SNAPSHOT_DIRECTORY" -type f 2>/dev/null | sort | while IFS= read -r file; do
    printf '%s %s\n' "$file" "$(shasum -a 256 <"$file")"
  done
}

@test "snapshots: an edit after the snapshot fails edited-after-check through check and check-all, with and without --snapshot-dir (case table)" {
  local before after
  write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$(disposition_entry f.txt 3 c/imp waive-out-of-scope because triage-threshold)]")"
  run_check 1 --snapshot-dir "$SNAPSHOT_DIRECTORY"
  green || return 1
  open_round 2 '[{"path":"f.txt","line":7,"finding_class":"c/later","severity":"minor","security":false}]'
  run_check 1
  green || return 1
  write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$(disposition_entry f.txt 3 c/imp waive-out-of-scope "a different reason" triage-threshold)]")"
  printf 'case: %s\n' 'check-all and check with --snapshot-dir' >&2
  run_check_all --snapshot-dir "$SNAPSHOT_DIRECTORY"
  red edited-after-check '{"round":1}' || return 1
  run_check 1 --snapshot-dir "$SNAPSHOT_DIRECTORY"
  red edited-after-check '{"round":1}' || return 1
  printf 'case: %s\n' 'check with no --snapshot-dir, writing nothing' >&2
  before="$(tree_state)"
  run_check 1
  red edited-after-check '{"round":1}' || return 1
  after="$(tree_state)"
  [ "$before" = "$after" ]
}

@test "check-all: exits 1 when any one of three files fails and 0 when all pass" {
  local round
  write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$(disposition_entry f.txt 3 c/imp fix)]")"
  run_check 1 --snapshot-dir "$SNAPSHOT_DIRECTORY"
  green || return 1
  for round in 2 3; do
    open_round "$round" "$FINDINGS_JSON"
    write_dispositions "$round" "$(fill "$FINDINGS_JSON" "[$(disposition_entry f.txt 3 c/imp fix)]")"
    run_check "$round" --snapshot-dir "$SNAPSHOT_DIRECTORY"
    green || return 1
  done
  run_check_all --snapshot-dir "$SNAPSHOT_DIRECTORY"
  green || return 1
  for round in 1 2 3; do
    write_dispositions "$round" "$(fill "$FINDINGS_JSON" "[$(disposition_entry f.txt 1 c/crit accept-residual)]")"
    run_check_all
    [ "$status" -eq 1 ] || { echo "round $round: status $status"; return 1; }
    write_dispositions "$round" "$(fill "$FINDINGS_JSON" "[$(disposition_entry f.txt 3 c/imp fix)]")"
  done
}

@test "check-all: an empty run folder after a round with no findings exits 0" {
  alf_sidecar "$MEMBER" '[]' 12
  run_check_all
  green
}

@test "no snapshot flag: check and check-all write nothing anywhere" {
  local before after
  write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$(disposition_entry f.txt 3 c/imp fix)]")"
  before="$(find "$BATS_TEST_TMPDIR" -type f | sort | xargs cksum)"
  run_check 1
  green || return 1
  run_check_all
  green || return 1
  after="$(find "$BATS_TEST_TMPDIR" -type f | sort | xargs cksum)"
  [ -n "$before" ] || return 1
  [ "$before" = "$after" ]
}

@test "exit 3: each unreadable input (state file, vetoes.json, dispositions file, missing triage library) exits 3 and grades nothing (case table)" {
  local copy="$BATS_TEST_TMPDIR/no-triage-library"
  write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$(disposition_entry f.txt 3 c/imp fix)]")"
  printf 'case: %s\n' 'triage library missing' >&2
  mkdir -p "$copy"
  cp "$SCRIPTS/audit-dispositions-check.sh" "$SCRIPTS/filing-outcomes-lib.sh" "$SCRIPTS/audit-pr-sections-lib.sh" "$SCRIPTS/audit-recorded-decision-lib.sh" "$SCRIPTS/audit-decided-unattended-lib.sh" "$SCRIPTS/pr-body-sections-lib.sh" "$SCRIPTS/autonomy-lib.sh" "$SCRIPTS/main-root-lib.sh" "$SCRIPTS/branch-name-lib.sh" "$copy/"
  run bash "$copy/audit-dispositions-check.sh" check --root "$ALF_ROOT" --run-folder "$RUN_FOLDER" --round 1
  [ "$status" -eq 3 ] || { echo "status $status: $output"; return 1; }
  grep -qF -- 'audit-triage-lib.sh' <<<"$output" || { echo "$output"; return 1; }
  grep -qF -- 'violation' <<<"$output" && return 1
  printf 'case: %s\n' 'corrupt state file' >&2
  cp "$ALF_STATE" "$BATS_TEST_TMPDIR/state.kept"
  printf 'not json' >"$ALF_STATE"
  run_check 1
  [ "$status" -eq 3 ] || { echo "status $status: $output"; return 1; }
  run_check_all
  [ "$status" -eq 3 ] || { echo "status $status: $output"; return 1; }
  cp "$BATS_TEST_TMPDIR/state.kept" "$ALF_STATE"
  printf 'case: %s\n' 'unparseable vetoes.json' >&2
  printf 'not json' >"$RUN_FOLDER/vetoes.json"
  run_check 1
  [ "$status" -eq 3 ] || { echo "status $status: $output"; return 1; }
  run_check_all
  [ "$status" -eq 3 ] || { echo "status $status: $output"; return 1; }
  rm -f "$RUN_FOLDER/vetoes.json"
  printf 'case: %s\n' 'unparseable dispositions file' >&2
  printf 'not json' >"$RUN_FOLDER/dispositions-1.json"
  run_check 1
  [ "$status" -eq 3 ] || { echo "status $status: $output"; return 1; }
}

@test "exit 2: each usage error (no subcommand, missing round, pr-sections without --root, a bad or misplaced --decision) exits 2" {
  printf 'case: %s\n' 'no subcommand and missing round' >&2
  run bash "$SCRIPT"
  [ "$status" -eq 2 ] || return 1
  run_check ""
  [ "$status" -eq 2 ]
  printf 'case: %s\n' 'pr-sections without --root' >&2
  write_dispositions 1 "$(fill "$FINDINGS_JSON" '[]')"
  run bash "$SCRIPT" pr-sections --run-folder "$RUN_FOLDER"
  [ "$status" -eq 2 ] || { echo "status $status: $output"; return 1; }
  printf 'case: %s\n' 'bad or misplaced --decision' >&2
  printf '{"member":"%s","finding_class":"c/sug","path":"f.txt","line":6}\n' "$MEMBER" >"$BATS_TEST_TMPDIR/finding.json"
  run bash "$SCRIPT" record-residual --root "$ALF_ROOT" --run-folder "$RUN_FOLDER" --finding "$BATS_TEST_TMPDIR/finding.json" --decision defer
  [ "$status" -eq 2 ] || return 1
  run bash "$SCRIPT" pr-sections --root "$ALF_ROOT" --run-folder "$RUN_FOLDER" --decision accept
  [ "$status" -eq 2 ]
}

@test "waiver-table: header and one row per non-fix entry, severity from the sidecar" {
  local entry rows
  entry="$(disposition_entry f.txt 1 c/crit waive-out-of-scope "pipe | here" triage-threshold | jq -c '. + {severity: "major"}')"
  write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$entry,$(disposition_entry f.txt 3 c/imp fix),$(disposition_entry f.txt 6 c/sug accept-residual later)]")"
  run bash "$SCRIPT" waiver-table --root "$ALF_ROOT" --run-folder "$RUN_FOLDER" --rounds 1-1
  green || return 1
  head -n 1 <<<"$output" | grep -qF -- 'key | member | severity | security | disposition | reason' || return 1
  rows="$(wc -l <<<"$output" | tr -d ' ')"
  [ "$rows" -eq 4 ] || { echo "$output"; return 1; }
  grep -F -- 'f.txt:1 c/crit' <<<"$output" | grep -qF -- '| critical | false |' || { echo "$output"; return 1; }
  grep -qF -- 'pipe \| here' <<<"$output" || { echo "$output"; return 1; }
  grep -qF -- 'f.txt:3 c/imp' <<<"$output" && return 1
  grep -F -- 'f.txt:6 c/sug' <<<"$output" | grep -qF -- '| minor | false | code-audit-frontend' && return 1
  true
}

@test "waiver-table: reads the frozen snapshot once the sidecar is gone" {
  accept_at 1
  write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$(disposition_entry f.txt 1 c/crit fix),$(disposition_entry f.txt 6 c/sug accept-residual later)]")"
  run_check 1 --snapshot-dir "$SNAPSHOT_DIRECTORY"
  green || return 1
  open_round 2 '[{"path":"f.txt","line":7,"finding_class":"c/later","severity":"critical","security":false}]'
  run bash "$SCRIPT" waiver-table --root "$ALF_ROOT" --run-folder "$RUN_FOLDER" --rounds 1-1
  green || return 1
  grep -F -- 'f.txt:6 c/sug' <<<"$output" | grep -qF -- '| minor | false |' || { echo "$output"; return 1; }
}

@test "pr-sections: three headings, keyed entries parse as residue keys, vetoed key drops out (directive 7)" {
  local key_regex='<!-- gaia-debt-key: (v1 class=[^ ]+ path=[^>]+ line=[0-9]+) -->'
  local line
  write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$(disposition_entry f.txt 3 c/imp accept-residual "closing round left it"),$(disposition_entry f.txt 4 c/xr waive-out-of-scope "other remit" cross-remit),$(disposition_entry f.txt 6 c/sug waive-out-of-scope "below threshold" triage-threshold)]")"
  run bash "$SCRIPT" pr-sections --root "$ALF_ROOT" --run-folder "$RUN_FOLDER"
  green || return 1
  grep -qxF -- '## Accepted residuals (recorded, not fixed)' <<<"$output" || { echo "$output"; return 1; }
  grep -qxF -- '## Out-of-scope machinery findings (recorded, not filed)' <<<"$output" || { echo "$output"; return 1; }
  grep -qxF -- '## Waived below triage threshold (not filed)' <<<"$output" || { echo "$output"; return 1; }
  line="$(grep -F -- 'f.txt:3' <<<"$output")"
  [[ "$line" =~ $key_regex ]] || { echo "$line"; return 1; }
  [ "${BASH_REMATCH[1]}" = "v1 class=c/imp path=f.txt line=3" ] || return 1
  line="$(grep -F -- 'f.txt:4' <<<"$output")"
  [[ "$line" =~ $key_regex ]] || { echo "$line"; return 1; }
  line="$(grep -F -- 'f.txt:6' <<<"$output")"
  [ "$line" = '- f.txt:6 c/sug: below threshold' ] || { echo "$line"; return 1; }
  vetoes 1 c/imp f.txt 3
  run bash "$SCRIPT" pr-sections --root "$ALF_ROOT" --run-folder "$RUN_FOLDER"
  green || return 1
  grep -qF -- 'Accepted residuals' <<<"$output" && return 1
  grep -qF -- 'f.txt:3' <<<"$output" && return 1
  grep -qF -- 'Out-of-scope machinery findings' <<<"$output"
}

@test "pr-sections: a veto effective from a later round drops an earlier round's accepted residual and leaves its waiver" {
  write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$(disposition_entry f.txt 3 c/imp accept-residual "closing round left it"),$(disposition_entry f.txt 4 c/xr waive-out-of-scope "other remit" cross-remit)]")"
  run bash "$SCRIPT" pr-sections --root "$ALF_ROOT" --run-folder "$RUN_FOLDER"
  green || return 1
  grep -qxF -- '## Accepted residuals (recorded, not fixed)' <<<"$output" || { echo "$output"; return 1; }
  jq -n -c '{version: 1, keys: [{member: "code-audit-frontend", finding_class: "c/imp", path: "f.txt", line: 3, effective_from_round: 2},
    {member: "code-audit-frontend", finding_class: "c/xr", path: "f.txt", line: 4, effective_from_round: 2}]}' >"$RUN_FOLDER/vetoes.json"
  run bash "$SCRIPT" pr-sections --root "$ALF_ROOT" --run-folder "$RUN_FOLDER"
  green || return 1
  grep -qF -- 'Accepted residuals' <<<"$output" && { echo "$output"; return 1; }
  grep -qF -- '`f.txt:4`' <<<"$output" || { echo "$output"; return 1; }
}

@test "pr-sections: nothing to record prints nothing" {
  write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$(disposition_entry f.txt 3 c/imp fix)]")"
  run bash "$SCRIPT" pr-sections --root "$ALF_ROOT" --run-folder "$RUN_FOLDER"
  green || return 1
  [ -z "$output" ]
}

@test "cost: check-all over nine snapshotted rounds never calls the evaluator and is fast (DP-017)" {
  local round shim="$BATS_TEST_TMPDIR/shim" start_milliseconds end_milliseconds count
  write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$(disposition_entry f.txt 3 c/imp fix)]")"
  run_check 1 --snapshot-dir "$SNAPSHOT_DIRECTORY"
  green || return 1
  round=2
  while [ "$round" -le 9 ]; do
    open_round "$round" "$FINDINGS_JSON"
    write_dispositions "$round" "$(fill "$FINDINGS_JSON" "[$(disposition_entry f.txt 3 c/imp waive-out-of-scope because triage-threshold),$(disposition_entry f.txt 1 c/crit fix)]")"
    run_check "$round" --snapshot-dir "$SNAPSHOT_DIRECTORY"
    green || return 1
    round=$((round + 1))
  done
  count="$(find "$SNAPSHOT_DIRECTORY" -name 'dispositions-*.checked.json' | wc -l | tr -d ' ')"
  [ "$count" -eq 9 ] || { echo "snapshots: $count"; return 1; }
  mkdir -p "$shim"
  cp "$SCRIPT" "$SCRIPTS/audit-triage-lib.sh" "$SCRIPTS/audit-dispositions-grade-lib.sh" "$SCRIPTS/audit-dispositions-snapshot-lib.sh" "$SCRIPTS/audit-pr-sections-lib.sh" "$SCRIPTS/audit-recorded-decision-lib.sh" "$SCRIPTS/audit-decided-unattended-lib.sh" "$SCRIPTS/pr-body-sections-lib.sh" "$SCRIPTS/autonomy-lib.sh" "$SCRIPTS/main-root-lib.sh" "$SCRIPTS/branch-name-lib.sh" "$shim/"
  printf '#!/usr/bin/env bash\nprintf "called\\n" >>"%s/calls"\nexit 9\n' "$BATS_TEST_TMPDIR" >"$shim/audit-loop-eval.sh"
  start_milliseconds="$(perl -MTime::HiRes=time -e 'printf "%d\n", time*1000')"
  run bash "$shim/audit-dispositions-check.sh" check-all --root "$ALF_ROOT" --run-folder "$RUN_FOLDER" --snapshot-dir "$SNAPSHOT_DIRECTORY"
  end_milliseconds="$(perl -MTime::HiRes=time -e 'printf "%d\n", time*1000')"
  green || return 1
  [ ! -e "$BATS_TEST_TMPDIR/calls" ] || { echo "evaluator was called"; return 1; }
  echo "check-all over 9 snapshots: $((end_milliseconds - start_milliseconds)) ms" >&3
  [ $((end_milliseconds - start_milliseconds)) -lt 2000 ]
}

# --- every finding disposed, divert, visibility, outcomes, triage, PR sections ---

SHELL_MEMBER=code-audit-maintainer-shell
TRIAGE_ENTRY='{"path":".claude/hooks/h.sh","line":1,"finding_class":"c/tri","severity":"major","security":false,"triage":true,"triage_reason":"below threshold"}'

# member_key_json <member> <class> <path> <line>
member_key_json() {
  printf '{"member":"%s","finding_class":"%s","path":"%s","line":%s}' "$1" "$2" "$3" "$4"
}

# write_roster: a roster giving f.txt and base.txt to the frontend default and
# .claude/hooks/**/*.sh to the maintainer shell member.
write_roster() {
  cat >"$ALF_ROOT/.gaia/audit-ci.yml" <<'YAML'
auditors:
  - name: code-audit-frontend
    globs:
      - "f.txt"
      - "base.txt"
    default: true
  - name: code-audit-maintainer-shell
    globs:
      - ".claude/hooks/**/*.sh"
  - name: code-audit-maintainer-node
    globs:
      - ".gaia/cli/src/**/*.ts"
YAML
}

# with_maintainer <entries-json> [minutes]: the roster, the maintainer shell
# member added to round 1, and its sidecar in round 1's window.
with_maintainer() {
  write_roster
  alf_state_edit '.history.rounds[0].members |= ((. + ["code-audit-maintainer-shell"]) | unique)'
  alf_sidecar "$SHELL_MEMBER" "$1" "${2:-11}"
}

# outcome_line <class> <path> <line> <disposition> <outcome>: one filing outcome.
outcome_line() {
  jq -n -c --arg finding_class "$1" --arg path "$2" --argjson line "$3" --arg disposition "$4" --arg outcome "$5" \
    '{key: {member: "code-audit-frontend", finding_class: $finding_class, path: $path, line: $line},
      disposition: $disposition, outcome: $outcome, issue: null, record: null}'
}

run_outcomes() {
  run bash "$SCRIPT" check-outcomes --root "$ALF_ROOT" --run-folder "$RUN_FOLDER" --round "$1"
}

run_sections() {
  run bash "$SCRIPT" pr-sections --root "$ALF_ROOT" --run-folder "$RUN_FOLDER"
}

@test "check-outcomes: each outcome value per file and divert entry, and the exact-key veto exemption for refused-authored (case table)" {
  local outcome_file="$RUN_FOLDER/filing-outcomes-1.jsonl" outcome
  printf 'case: %s\n' 'filed and diverted pass, a missing line or failed fails, absent and transient pass' >&2
  write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$(disposition_entry base.txt 6 c/oosimp file upstream),$(disposition_entry base.txt 3 c/oos divert "security class")]")"
  printf '%s\n%s\n' "$(outcome_line c/oosimp base.txt 6 file filed)" "$(outcome_line c/oos base.txt 3 divert diverted)" >"$outcome_file"
  run_outcomes 1
  green || return 1
  outcome_line c/oos base.txt 3 divert diverted >"$outcome_file"
  run_outcomes 1
  red outcome-missing "$(key_json c/oosimp base.txt 6)" || return 1
  outcome_line c/oosimp base.txt 6 file filed >"$outcome_file"
  run_outcomes 1
  red outcome-missing "$(key_json c/oos base.txt 3)" || return 1
  printf '%s\n%s\n' "$(outcome_line c/oosimp base.txt 6 file failed)" "$(outcome_line c/oos base.txt 3 divert diverted)" >"$outcome_file"
  run_outcomes 1
  red outcome-failed "$(key_json c/oosimp base.txt 6)" || return 1
  for outcome in absent transient; do
    printf '%s\n%s\n' "$(outcome_line c/oosimp base.txt 6 file "$outcome")" "$(outcome_line c/oos base.txt 3 divert diverted)" >"$outcome_file"
    run_outcomes 1
    green || { echo "outcome $outcome"; return 1; }
  done
  rm -f "$outcome_file"
  run_outcomes 1
  red outcome-missing "$(key_json c/oosimp base.txt 6)" || return 1
  printf 'not json\n' >"$outcome_file"
  run_outcomes 1
  [ "$status" -eq 3 ] || { echo "status $status: $output"; return 1; }
  printf 'case: %s\n' 'refused-authored on a file entry is its own violation, and the mutant that passes it goes green' >&2
  write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$(disposition_entry base.txt 6 c/oosimp file upstream)]")"
  outcome_line c/oosimp base.txt 6 file refused-authored >"$outcome_file"
  run_outcomes 1
  red refused-authored "$(key_json c/oosimp base.txt 6)" || return 1
  grep -qF -- outcome-failed <<<"$output" && return 1
  mutant_script audit-dispositions-grade-lib.sh -e '/elif \$outcome.outcome == "refused-authored"/d' \
    -e 's/"absent", "transient"/"absent", "transient", "refused-authored"/' || return 1
  run_outcomes 1
  green || return 1
  SCRIPT="$SCRIPTS/audit-dispositions-check.sh"
  printf 'case: %s\n' 'a divert entry refused-authored fails too, and the other outcomes pass' >&2
  write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$(disposition_entry base.txt 3 c/oos divert "security class")]")"
  outcome_line c/oos base.txt 3 divert refused-authored >"$outcome_file"
  run_outcomes 1
  red refused-authored "$(key_json c/oos base.txt 3)" || return 1
  for outcome in filed matched diverted absent transient; do
    outcome_line c/oos base.txt 3 divert "$outcome" >"$outcome_file"
    run_outcomes 1
    green || { echo "outcome $outcome"; return 1; }
  done
  printf 'case: %s\n' 'refused-authored passes once the exact key is vetoed; a malformed vetoes.json exits 3' >&2
  write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$(disposition_entry base.txt 6 c/oosimp file upstream)]")"
  outcome_line c/oosimp base.txt 6 file refused-authored >"$outcome_file"
  run_outcomes 1
  red refused-authored "$(key_json c/oosimp base.txt 6)" || return 1
  grep -qF -- unbound <<<"$output" && { echo "$output"; return 1; }
  vetoes 2 c/oosimp base.txt 7
  run_outcomes 1
  red refused-authored "$(key_json c/oosimp base.txt 6)" || return 1
  vetoes 2 c/oosimp base.txt 6
  run_outcomes 1
  green || return 1
  printf 'not json' >"$RUN_FOLDER/vetoes.json"
  run_outcomes 1
  [ "$status" -eq 3 ] || { echo "status $status: $output"; return 1; }
}

@test "check-outcomes passes a matched outcome, a dedup hit on an existing issue" {
  write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$(disposition_entry base.txt 6 c/oosimp file upstream)]")"
  outcome_line c/oosimp base.txt 6 file matched >"$RUN_FOLDER/filing-outcomes-1.jsonl"
  run_outcomes 1
  green
}

@test "UAT-037: check-all reconciles a live round's outcomes" {
  write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$(disposition_entry base.txt 6 c/oosimp file upstream)]")"
  run_check_all
  red outcome-missing "$(key_json c/oosimp base.txt 6)" || return 1
  outcome_line c/oosimp base.txt 6 file filed >"$RUN_FOLDER/filing-outcomes-1.jsonl"
  run_check_all
  green
}

@test "triage mark: honored only for an allowlisted member on its own path with security false and severity not critical, under a readable roster (case table)" {
  local line_count mutation with_mark
  printf 'case: %s\n' 'honored: own harness path, security false, major' >&2
  with_maintainer "[$TRIAGE_ENTRY]"
  write_dispositions 1 "$(fill "$FINDINGS_JSON" '[]')"
  run_check 1
  green || return 1
  run_sections
  green || return 1
  grep -qxF -- '## Waived below triage threshold (not filed)' <<<"$output" || { echo "$output"; return 1; }
  line_count="$(grep -cxF -- '- .claude/hooks/h.sh:1 c/tri: below threshold' <<<"$output")"
  [ "$line_count" -eq 1 ] || { echo "$output"; return 1; }
  printf 'case: %s\n' 'ignored: critical, security true, security absent, off its member globs, no roster' >&2
  for mutation in '.severity = "critical"' '.security = true' 'del(.security)' '.path = "f.txt" | .line = 9'; do
    with_maintainer "[$(jq -c "$mutation" <<<"$TRIAGE_ENTRY")]"
    write_dispositions 1 "$(fill "$FINDINGS_JSON" '[]')"
    run_check 1
    red undisposed "$(member_key_json "$SHELL_MEMBER" c/tri "$(jq -r "$mutation | .path" <<<"$TRIAGE_ENTRY")" "$(jq -r "$mutation | .line" <<<"$TRIAGE_ENTRY")")" || { echo "mutation $mutation"; return 1; }
    run_sections
    grep -qF -- 'c/tri' <<<"$output" && { echo "rendered under $mutation: $output"; return 1; }
  done
  with_maintainer "[$TRIAGE_ENTRY]"
  rm -f "$ALF_ROOT/.gaia/audit-ci.yml"
  run_check 1
  red undisposed "$(member_key_json "$SHELL_MEMBER" c/tri .claude/hooks/h.sh 1)" || return 1
  printf 'case: %s\n' 'ignored: a code-audit-frontend mark' >&2
  write_roster
  with_mark="$(jq -c '. + [{"path":"f.txt","line":8,"finding_class":"c/fronttri","severity":"minor","security":false,"triage":true,"triage_reason":"below threshold"}]' <<<"$FINDINGS_JSON")"
  alf_sidecar "$MEMBER" "$with_mark" 11
  write_dispositions 1 "$(fill "$FINDINGS_JSON" '[]')"
  run_check 1
  red undisposed "$(key_json c/fronttri f.txt 8)"
}

# secret_token: a secret-shaped token, assembled at run time so the suite's
# own text never holds one.
secret_token() { printf '%s_%s' ghp "$(printf '%036d' 0)"; }

@test "UAT-023: a secret-shaped triage or waiver reason renders the withheld line, never the reason" {
  local token
  token="$(secret_token)"
  with_maintainer "[$(jq -c --arg reason "token $token leaked" '.triage_reason = $reason' <<<"$TRIAGE_ENTRY")]"
  write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$(disposition_entry base.txt 6 c/oosimp waive-out-of-scope "see $token" triage-threshold)]")"
  run_sections
  green || return 1
  grep -qxF -- '- 2 waived finding(s) withheld: reason failed the secret screen' <<<"$output" || { echo "$output"; return 1; }
  grep -qF -- "$token" <<<"$output" && { echo "$output"; return 1; }
  grep -qF -- 'c/tri' <<<"$output" && { echo "$output"; return 1; }
  grep -qF -- 'c/oosimp' <<<"$output" && { echo "$output"; return 1; }
  true
}

@test "pr-sections: a waive line renders exactly once only for security false and severity not critical (case table)" {
  printf 'case: %s\n' 'security true' >&2
  write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$(disposition_entry base.txt 5 c/oossec waive-out-of-scope "below threshold" triage-threshold)]")"
  run_sections
  green || return 1
  grep -qF -- 'c/oossec' <<<"$output" && { echo "$output"; return 1; }
  printf 'case: %s\n' 'no security field' >&2
  write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$(disposition_entry base.txt 7 c/oosnosec waive-out-of-scope "below threshold" triage-threshold)]")"
  run_sections
  green || return 1
  grep -qF -- 'c/oosnosec' <<<"$output" && { echo "$output"; return 1; }
  printf 'case: %s\n' 'severity critical' >&2
  write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$(disposition_entry base.txt 3 c/oos waive-out-of-scope "below threshold" triage-threshold)]")"
  run_sections
  green || return 1
  grep -qF -- 'c/oos' <<<"$output" && { echo "$output"; return 1; }
  printf 'case: %s\n' 'security false major with a clean reason' >&2
  write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$(disposition_entry base.txt 6 c/oosimp waive-out-of-scope "below threshold" triage-threshold)]")"
  run_sections
  green || return 1
  [ "$(grep -cxF -- '- base.txt:6 c/oosimp: below threshold' <<<"$output")" -eq 1 ] || { echo "$output"; return 1; }
}

@test "divert: pr-sections and waiver-table print the count and nothing that names the finding" {
  local field
  write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$(disposition_entry base.txt 3 c/oos divert "the token sits in the debug log")]")"
  run_sections
  green || return 1
  grep -qxF -- 'Diverted security findings: 1 (local records under .gaia/local/audit/security/)' <<<"$output" || { echo "$output"; return 1; }
  for field in c/oos base.txt 'the token sits' code-audit-frontend; do
    grep -qF -- "$field" <<<"$output" && { echo "leaked $field: $output"; return 1; }
  done
  run bash "$SCRIPT" waiver-table --root "$ALF_ROOT" --run-folder "$RUN_FOLDER" --rounds 1-1
  green || return 1
  grep -qxF -- 'Diverted security findings: 1 (local records under .gaia/local/audit/security/)' <<<"$output" || { echo "$output"; return 1; }
  for field in c/oos 'the token sits'; do
    grep -qF -- "$field" <<<"$output" && { echo "leaked $field: $output"; return 1; }
  done
  true
}

@test "UAT-005: an absent outcome renders one not-filed line naming the key; a filed one renders none" {
  local expected='- code-audit-frontend base.txt:6 (c/oosimp): not filed, no issue backend'
  write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$(disposition_entry base.txt 6 c/oosimp file upstream)]")"
  outcome_line c/oosimp base.txt 6 file absent >"$RUN_FOLDER/filing-outcomes-1.jsonl"
  run_sections
  green || return 1
  grep -qxF -- '## Not filed (no issue backend)' <<<"$output" || { echo "$output"; return 1; }
  [ "$(grep -cxF -- "$expected" <<<"$output")" -eq 1 ] || { echo "$output"; return 1; }
  outcome_line c/oosimp base.txt 6 file filed >"$RUN_FOLDER/filing-outcomes-1.jsonl"
  run_sections
  green || return 1
  grep -qF -- 'Not filed' <<<"$output" && { echo "$output"; return 1; }
  grep -qF -- "$expected" <<<"$output" && return 1
  true
}

@test "UAT-005: retry files render one pending count line; an empty or absent retry folder renders none; transient never blocks" {
  local pending='- 2 finding(s) pending: the issue backend was unreachable; retried next round'
  write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$(disposition_entry base.txt 6 c/oosimp file upstream)]")"
  outcome_line c/oosimp base.txt 6 file transient >"$RUN_FOLDER/filing-outcomes-1.jsonl"
  mkdir -p "$RUN_FOLDER/filing-retry"
  printf '{}\n' >"$RUN_FOLDER/filing-retry/aaaa.json"
  printf '{}\n' >"$RUN_FOLDER/filing-retry/bbbb.json"
  run_sections
  green || return 1
  grep -qxF -- '## Not filed (no issue backend)' <<<"$output" || { echo "$output"; return 1; }
  [ "$(grep -cxF -- "$pending" <<<"$output")" -eq 1 ] || { echo "$output"; return 1; }
  run_check_all
  green || return 1
  run_outcomes 1
  green || return 1
  rm -f "$RUN_FOLDER/filing-retry/"*.json
  run_sections
  grep -qF -- 'pending' <<<"$output" && { echo "$output"; return 1; }
  rmdir "$RUN_FOLDER/filing-retry"
  run_sections
  grep -qF -- 'pending' <<<"$output" && { echo "$output"; return 1; }
  run_check_all
  green || return 1
  run_outcomes 1
  green
}

@test "forward-only: each snapshot version re-grades under its own predicate while live grading uses the current one (case table)" {
  local lookup sha snapshot_file="$SNAPSHOT_DIRECTORY/dispositions-1.checked.json"
  printf 'case: %s\n' 'version 1: an undisposed out-of-branch finding re-grades clean; as version 2 it fails' >&2
  write_dispositions 1 "$(fill "$FINDINGS_JSON" '[]' 'select(.path == "f.txt")')"
  run_check 1
  red undisposed "$(key_json c/oos base.txt 3)" || return 1
  lookup="$(bash "$SCRIPTS/audit-loop-eval.sh" findings --root "$ALF_ROOT" --round 1 | jq -c '.entries | map({member, finding_class, path, line, severity, security, cross_remit, authored})')"
  sha="$(shasum -a 256 <"$RUN_FOLDER/dispositions-1.json" | cut -d' ' -f1)"
  mkdir -p "$SNAPSHOT_DIRECTORY"
  jq -n -c --arg sha "$sha" --argjson lookup "$lookup" '{version: 1, round: 1, dispositions_sha256: $sha, lookup: $lookup}' >"$snapshot_file"
  run_check_all
  green || return 1
  run_check 1
  green || return 1
  jq -c '.version = 2' "$snapshot_file" >"$snapshot_file.new" && mv "$snapshot_file.new" "$snapshot_file"
  run_check_all
  red undisposed "$(key_json c/oos base.txt 3)" || return 1
  printf 'case: %s\n' 'version 2: an accept-residual re-grades clean; live it fails; a mutant grading version 2 as 3 goes red' >&2
  rm -f "$snapshot_file"
  write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$(disposition_entry f.txt 6 c/sug accept-residual later)]")"
  run_check 1
  red accept-residual-not-eligible "$(key_json c/sug f.txt 6)" || return 1
  lookup="$(bash "$SCRIPTS/audit-loop-eval.sh" findings --root "$ALF_ROOT" --round 1 | jq -c '.entries | map({member, finding_class, path, line, severity, security, cross_remit, authored, triage: false, triage_reason: ""})')"
  sha="$(shasum -a 256 <"$RUN_FOLDER/dispositions-1.json" | cut -d' ' -f1)"
  jq -n -c --arg sha "$sha" --argjson lookup "$lookup" '{version: 2, round: 1, dispositions_sha256: $sha, lookup: $lookup}' >"$snapshot_file"
  run_check_all
  green || return 1
  run_check 1
  green || return 1
  mutant_script audit-dispositions-grade-lib.sh -e 's/"accept-residual" and \$version >= 3/"accept-residual" and $version >= 2/' || return 1
  run_check_all
  red accept-residual-not-eligible "$(key_json c/sug f.txt 6)"
}

@test "snapshot projection: check-all honors an earlier round's triage mark from its snapshot after the sidecar loses it" {
  with_maintainer "[$TRIAGE_ENTRY]"
  write_dispositions 1 "$(fill "$FINDINGS_JSON" '[]')"
  run_check 1 --snapshot-dir "$SNAPSHOT_DIRECTORY"
  green || return 1
  jq -e '.version == 4 and any(.lookup[]; .finding_class == "c/tri" and .triage == true and .triage_reason == "below threshold")' \
    "$SNAPSHOT_DIRECTORY/dispositions-1.checked.json" >/dev/null || { cat "$SNAPSHOT_DIRECTORY/dispositions-1.checked.json"; return 1; }
  alf_sidecar "$SHELL_MEMBER" "[$(jq -c 'del(.triage, .triage_reason)' <<<"$TRIAGE_ENTRY")]" 12
  open_round 2 '[{"path":"f.txt","line":7,"finding_class":"c/later","severity":"minor","security":false}]'
  write_dispositions 2 "[$(disposition_entry f.txt 7 c/later fix)]"
  run_check_all --snapshot-dir "$SNAPSHOT_DIRECTORY"
  green || return 1
  mv "$SNAPSHOT_DIRECTORY/dispositions-1.checked.json" "$BATS_TEST_TMPDIR/kept.json"
  run_check_all
  red undisposed "$(member_key_json "$SHELL_MEMBER" c/tri .claude/hooks/h.sh 1)"
}

@test "carry-forward: which earlier dispositions carry into a re-report (file filed/transient, fix, filer-refused, accepted, accepted escalated) (case table)" {
  local outcome escalation escalated
  printf 'case: %s\n' 'file, filed or transient, is carried' >&2
  write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$(disposition_entry base.txt 6 c/oosimp file upstream)]")"
  run_check 1 --snapshot-dir "$SNAPSHOT_DIRECTORY"
  green || return 1
  open_round 2 "$FINDINGS_JSON"
  write_dispositions 2 "$(fill "$FINDINGS_JSON" '[]' 'select(.path != "base.txt" or .line != 6)')"
  for outcome in filed transient; do
    outcome_line c/oosimp base.txt 6 file "$outcome" >"$RUN_FOLDER/filing-outcomes-1.jsonl"
    run_check 2
    green || { echo "outcome $outcome"; return 1; }
    run_check_all
    green || { echo "outcome $outcome"; return 1; }
  done
  printf 'case: %s\n' 'a key the filer refused is not carried, and the mutant that carries it goes green' >&2
  outcome_line c/oosimp base.txt 6 file refused-authored >"$RUN_FOLDER/filing-outcomes-1.jsonl"
  run_check 2
  red undisposed "$(key_json c/oosimp base.txt 6)" || return 1
  mutant_script audit-dispositions-grade-lib.sh -e 's/gaia_filing_refused_keys "$RUN_FOLDER"/printf "[]"/' || return 1
  run_check 2
  green || return 1
  reset_fixture
  printf 'case: %s\n' 'fix is not carried' >&2
  write_dispositions 1 "$(fill "$FINDINGS_JSON" '[]')"
  run_check 1 --snapshot-dir "$SNAPSHOT_DIRECTORY"
  green || return 1
  open_round 2 "$FINDINGS_JSON"
  write_dispositions 2 "$(fill "$FINDINGS_JSON" '[]' 'select(.path != "base.txt" or .line != 6)')"
  run_check 2
  red undisposed "$(key_json c/oosimp base.txt 6)" || return 1
  reset_fixture
  printf 'case: %s\n' 'an accepted key on a non-stop round needs no entry; re-disposing it fails; the mutant not carrying accepts goes red' >&2
  accept_at 1
  write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$(disposition_entry f.txt 6 c/sug accept-residual later)]")"
  run_check 1 --snapshot-dir "$SNAPSHOT_DIRECTORY"
  green || return 1
  open_round 2 "$FINDINGS_JSON"
  open_round 3 "$FINDINGS_JSON"
  write_dispositions 3 "$(fill "$FINDINGS_JSON" '[]' 'select(.path != "f.txt" or .line != 6)')"
  run_check 3
  green || return 1
  mutant_script audit-dispositions-grade-lib.sh -e 's/select(\$version >= 3 and .disposition == "accept-residual")/select(false)/' || return 1
  run_check 3
  red undisposed "$(key_json c/sug f.txt 6)" || return 1
  SCRIPT="$SCRIPTS/audit-dispositions-check.sh"
  write_dispositions 3 "$(fill "$FINDINGS_JSON" "[$(disposition_entry f.txt 6 c/sug accept-residual later)]")"
  run_check 3
  red accept-residual-not-eligible "$(key_json c/sug f.txt 6)" || return 1
  reset_fixture
  printf 'case: %s\n' 'an accepted key re-reported as Critical or security-class is undisposed' >&2
  accept_at 1
  write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$(disposition_entry f.txt 6 c/sug accept-residual later)]")"
  run_check 1 --snapshot-dir "$SNAPSHOT_DIRECTORY"
  green || return 1
  open_round 2 "$FINDINGS_JSON"
  for escalation in '.severity = "critical"' '.severity = "major" | .security = true'; do
    escalated="$(jq -c "map(if .path == \"f.txt\" and .line == 6 then $escalation else . end)" <<<"$FINDINGS_JSON")"
    open_round 3 "$escalated"
    write_dispositions 3 "$(fill "$escalated" '[]' 'select(.path != "f.txt" or .line != 6)')"
    run_check 3
    red undisposed "$(key_json c/sug f.txt 6)" || return 1
  done
  mutant_script audit-dispositions-grade-lib.sh -e 's/ and (security_class | not))/)/' || return 1
  open_round 3 "$escalated"
  run_check 3
  green
}

# mutant_script <file> <sed args...>: a scratch copy of the check script and the
# libraries it loads, with <file> run through sed, and SCRIPT pointed at it. Fails
# when sed changed nothing, so a mutation that drifts off its target cannot pass.
mutant_script() {
  local mutant_directory="$BATS_TEST_TMPDIR/mutant" target="$1"
  shift
  mkdir -p "$mutant_directory"
  cp "$SCRIPTS"/*.sh "$mutant_directory/"
  sed "$@" "$SCRIPTS/$target" >"$mutant_directory/$target"
  cmp -s "$SCRIPTS/$target" "$mutant_directory/$target" && return 1
  SCRIPT="$mutant_directory/audit-dispositions-check.sh"
}

# recorded_row <class> <path> <line> <reason>: append one recorded residual.
recorded_row() {
  jq -n -c --arg finding_class "$1" --arg path "$2" --argjson line "$3" --arg reason "$4" \
    '{source: "worthiness", member: "worthiness-evaluator", finding_class: $finding_class, path: $path, line: $line, reason: $reason}' \
    >>"$RUN_FOLDER/recorded-residuals.jsonl"
}

@test "a refused-authored entry re-disposed accept-residual fails on an ordinary round, passes with a human accept and renders once under the accepted heading" {
  write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$(disposition_entry base.txt 6 c/oosimp file upstream)]")"
  outcome_line c/oosimp base.txt 6 file refused-authored >"$RUN_FOLDER/filing-outcomes-1.jsonl"
  run_outcomes 1
  red refused-authored "$(key_json c/oosimp base.txt 6)" || return 1
  write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$(disposition_entry base.txt 6 c/oosimp accept-residual "the branch wrote it")]")"
  run_check 1
  red accept-residual-not-eligible "$(key_json c/oosimp base.txt 6)" || return 1
  accept_at 1
  run_check 1
  green || return 1
  run_outcomes 1
  green || return 1
  run_sections
  green || return 1
  grep -qxF -- '## Accepted residuals (recorded, not fixed)' <<<"$output" || { echo "$output"; return 1; }
  [ "$(grep -cF -- 'base.txt:6' <<<"$output")" -eq 1 ] || { echo "$output"; return 1; }
}

@test "pr-sections: one recorded worthiness row and no dispositions render the committed fixture byte for byte" {
  local fixture="$REPO_ROOT/.gaia/cli/test-fixtures/residue/recorded-residual-section.md"
  recorded_row holistic/unclassified app/components/button.test.tsx 12 "the test passes even when the button renders no label"
  bash "$SCRIPT" pr-sections --root "$ALF_ROOT" --run-folder "$RUN_FOLDER" >"$BATS_TEST_TMPDIR/rendered.md"
  cmp -s "$BATS_TEST_TMPDIR/rendered.md" "$fixture" || { cat "$BATS_TEST_TMPDIR/rendered.md"; return 1; }
}

@test "pr-sections: a recorded row and a round's disposition of the same key render once" {
  write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$(disposition_entry f.txt 3 c/imp accept-residual "closing round left it")]")"
  recorded_row c/imp f.txt 3 "recorded as well"
  run_sections
  green || return 1
  [ "$(grep -cF -- 'f.txt:3' <<<"$output")" -eq 1 ] || { echo "$output"; return 1; }
  # The round's row wins and carries the finding's own failure mode.
  grep -qF -- '- `f.txt:3` f. <!--' <<<"$output" || { echo "$output"; return 1; }
}

@test "pr-sections: a recorded reason holding a secret-shaped token renders withheld, the text absent" {
  local token
  token="$(secret_token)"
  recorded_row holistic/unclassified a.test.ts 4 "leaks $token here"
  run_sections
  green || return 1
  grep -qxF -- '- 1 accepted residual(s) withheld: reason failed the secret screen' <<<"$output" || { echo "$output"; return 1; }
  grep -qF -- "$token" <<<"$output" && return 1
  true
}

@test "pr-sections: a multi-line reason does not shift the secret verdict onto the next row" {
  local token
  token="$(secret_token)"
  recorded_row holistic/unclassified a.test.ts 1 $'first line\nsecond line'
  recorded_row holistic/unclassified b.test.ts 2 "leaks $token"
  run_sections
  green || return 1
  grep -qF -- '`a.test.ts:1` first line second line.' <<<"$output" || { echo "$output"; return 1; }
  grep -qF -- 'b.test.ts' <<<"$output" && return 1
  grep -qxF -- '- 1 accepted residual(s) withheld: reason failed the secret screen' <<<"$output" || { echo "$output"; return 1; }
  grep -qF -- "$token" <<<"$output" && return 1
  mutant_script audit-pr-sections-lib.sh -e 's/def one: .*| trim | if/def one: if/' || return 1
  run_sections
  green || return 1
  grep -qF -- "$token" <<<"$output" || { echo "twin did not fail the case: $output"; return 1; }
}

@test "pr-sections: a reason holding a comment terminator stays one intact keyed bullet" {
  local key_regex='<!-- gaia-debt-key: (v1 class=[^ ]+ path=[^>]+ line=[0-9]+) -->'
  recorded_row holistic/unclassified a.test.ts 4 'ends the comment --> early'
  run_sections
  green || return 1
  [ "$(grep -c -- '^- ' <<<"$output")" -eq 1 ] || { echo "$output"; return 1; }
  [[ "$output" =~ $key_regex ]] || { echo "$output"; return 1; }
  [ "${BASH_REMATCH[1]}" = "v1 class=holistic/unclassified path=a.test.ts line=4" ] || return 1
  [ "$(grep -o -- '-->' <<<"$output" | wc -l | tr -d ' ')" -eq 1 ] || { echo "$output"; return 1; }
}

@test "pr-sections: a recorded row with line 0 renders and keys as line 1, like a disposition row" {
  recorded_row c/file-level a.test.ts 0 "whole file"
  run_sections
  green || return 1
  grep -qF -- '`a.test.ts:1` whole file.' <<<"$output" || { echo "$output"; return 1; }
  grep -qF -- 'class=c/file-level path=a.test.ts line=1 -->' <<<"$output" || { echo "$output"; return 1; }
}

@test "pr-sections: a recorded key a round disposed fix, or a veto names, does not render" {
  recorded_row c/imp f.txt 3 "recorded"
  recorded_row c/veto f.txt 9 "recorded too"
  write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$(disposition_entry f.txt 3 c/imp fix)]")"
  vetoes 1 c/veto f.txt 9
  jq -c '.keys[0].member = "worthiness-evaluator"' "$RUN_FOLDER/vetoes.json" >"$BATS_TEST_TMPDIR/vetoes.json"
  mv "$BATS_TEST_TMPDIR/vetoes.json" "$RUN_FOLDER/vetoes.json"
  run_sections
  green || return 1
  grep -qF -- 'Accepted residuals' <<<"$output" && return 1
  for drop in fixed vetoed; do
    mutant_script audit-pr-sections-lib.sh -e "s/| \\\$dropped\\.$drop | any(. == \\\$key) | not)/| true)/" || return 1
    run_sections
    green || return 1
    grep -qxF -- '## Accepted residuals (recorded, not fixed)' <<<"$output" || { echo "the $drop twin did not fail the case: $output"; return 1; }
  done
}

@test "record-residual: twice on one key leaves one row; a missing --finding is usage; an unreadable finding is exit 3" {
  local finding="$BATS_TEST_TMPDIR/finding.json" rows
  jq -n -c '{member: "code-audit-frontend", finding_class: "c/imp", path: "f.txt", line: 3, failure_mode: "wrong\nreason"}' >"$finding"
  run bash "$SCRIPT" record-residual --root "$ALF_ROOT" --run-folder "$RUN_FOLDER" --finding "$finding"
  green || return 1
  [ -z "$output" ] || { echo "$output"; return 1; }
  run bash "$SCRIPT" record-residual --root "$ALF_ROOT" --run-folder "$RUN_FOLDER" --finding "$finding"
  green || return 1
  rows="$(wc -l <"$RUN_FOLDER/recorded-residuals.jsonl" | tr -d ' ')"
  [ "$rows" -eq 1 ] || { echo "rows $rows"; return 1; }
  [ "$(jq -r '.source' "$RUN_FOLDER/recorded-residuals.jsonl")" = filing-replay ] || return 1
  run bash "$SCRIPT" record-residual --root "$ALF_ROOT" --run-folder "$RUN_FOLDER"
  [ "$status" -eq 2 ] || { echo "status $status: $output"; return 1; }
  printf 'not json\n' >"$BATS_TEST_TMPDIR/bad.json"
  run bash "$SCRIPT" record-residual --root "$ALF_ROOT" --run-folder "$RUN_FOLDER" --finding "$BATS_TEST_TMPDIR/bad.json"
  [ "$status" -eq 3 ] || { echo "status $status: $output"; return 1; }
  run bash "$SCRIPT" record-residual --root "$ALF_ROOT" --run-folder "$RUN_FOLDER" --finding "$BATS_TEST_TMPDIR/missing.json"
  [ "$status" -eq 3 ] || { echo "status $status: $output"; return 1; }
  run_sections
  green || return 1
  grep -qF -- 'f.txt:3' <<<"$output"
}

# --- accept-residual eligibility, veto satisfaction, residual count ----------

SHELL_MAINTAINER=code-audit-maintainer-shell

# accept_at <r>: a checkpoint at round r answered accept, the human accept
# round-history reports for rounds r and r+1.
accept_at() {
  local checkpoint_index
  alf_add_checkpoint "$1" fallback || return 1
  checkpoint_index="$(jq '.history.checkpoints | length' "$ALF_STATE")"
  alf_add_answer "$checkpoint_index" accept
}

# minor_rows <path> <first> <last> [class]: non-security Minors on those lines.
minor_rows() {
  alf_entries "$1" "$2" "$3" "${4:-rule/x}" | jq -c 'map(. + {severity: "minor", security: false})'
}

# joined <array-json>...: the arrays concatenated.
joined() {
  printf '%s\n' "$@" | jq -n -c '[inputs] | add'
}

# review_base_all <reason>: every sidecar's review base reason, its mtime kept.
review_base_all() {
  local sidecar_file
  for sidecar_file in "$ALF_ROOT"/.gaia/local/audit/*.findings.json; do
    jq -c --arg reason "$1" '.review_base = {sha: ("c" * 40), reason: $reason}' "$sidecar_file" >"$sidecar_file.edited"
    touch -r "$sidecar_file" "$sidecar_file.edited" && mv "$sidecar_file.edited" "$sidecar_file"
  done
}

# earn_marker <member> <r>: an earned clearance for the member's digest at round r's tree.
earn_marker() {
  local tree digest marker_name
  tree="$(jq -r --argjson round "$2" '.history.rounds[$round - 1].tree' "$ALF_STATE")"
  digest="$(bash "$SCRIPTS/audit-member-digest.sh" --root "$ALF_ROOT" --member "$1" --ref "$tree")" || return 1
  marker_name="$digest.$1.ok"
  [ "$1" = code-audit-frontend ] && marker_name="$digest.ok"
  jq -n -c --arg digest "$digest" --arg member "$1" '{digest: $digest, member: $member, provenance: "earned"}' >"$ALF_ROOT/.gaia/local/audit/$marker_name"
}

# stop_rounds <entries-json>...: a fresh branch with one round of MEMBER per
# argument, each commit touching only other.txt, every sidecar reviewed
# incrementally and the last round's marker earned, so the last round's
# default stop holds when its entries meet the evaluator's other terms. Sets
# LAST_ROUND, RUN_FOLDER and SNAPSHOT_DIRECTORY.
stop_rounds() {
  local round=1 entries
  # The gh stub answers any call with GH_VISIBILITY, so the member digest's
  # default-branch read would resolve to it; empty makes the stub fail.
  export GH_VISIBILITY=
  # shellcheck source=/dev/null
  . "$SCRIPTS/audit-loop-eval.sh"
  rm -rf "$BATS_TEST_TMPDIR/repo" "$BATS_TEST_TMPDIR/origin.git"
  alf_init && alf_branch feat/stop || return 1
  RUN_FOLDER="$ALF_ROOT/.gaia/local/runs/$ALF_NORMALIZED_BRANCH"
  SNAPSHOT_DIRECTORY="${ALF_STATE%.json}.d"
  mkdir -p "$RUN_FOLDER"
  printf 'auditors:\n  - name: %s\n    globs:\n      - "lib/**"\n    audience: adopter\n  - name: code-audit-frontend\n    globs:\n      - "**"\n    audience: adopter\n    default: true\n' \
    "$SHELL_MAINTAINER" >"$ALF_ROOT/.gaia/audit-ci.yml"
  alf_fill f.txt 12 feature
  alf_fill lib/s.sh 12 shell
  for entries in "$@"; do
    alf_set_line other.txt "$round" "round $round"
    alf_commit "round $round" || return 1
    alf_round "$round" "$MEMBER" "$entries" || return 1
    round=$((round + 1))
  done
  LAST_ROUND=$((round - 1))
  review_base_all member-clearance
  earn_marker "$MEMBER" "$LAST_ROUND"
}

# stop_base [round-3-entries]: rounds of 3, 2, 2 stable Minors on f.txt, the
# last one replaceable.
stop_base() {
  stop_rounds "$(minor_rows f.txt 1 3)" "$(minor_rows f.txt 1 2)" "${1:-$(minor_rows f.txt 1 2)}"
}

# accept_all <r> <entries-json> [extra-entries-json]: dispositions-<r>.json
# with the extra entries and an accept-residual on every other entry's key.
accept_all() {
  write_dispositions "$1" "$(jq -n -c --argjson entries "$2" --argjson extra "${3:-[]}" --arg member "$MEMBER" \
    '$extra + [$entries[] | select([.finding_class, .path, .line] as $key | any($extra[]; [.finding_class, .path, .line] == $key) | not)
       | {member: $member, finding_class, path, line, disposition: "accept-residual", reason: "left for later"}]')"
}

# evaluator_field <r> <jq>: a field of the evaluator's round r snapshot.
evaluator_field() {
  bash "$SCRIPTS/audit-loop-eval.sh" evaluate-round --root "$ALF_ROOT" --round "$1" | jq -r "$2"
}

# mutant_check_tree <file> <sed args...>: a scratch tree mirroring .gaia/scripts
# and .claude/hooks/lib (copies, never links) with <file> run through sed, so
# the evaluator a mutant check calls still proves markers. SCRIPT points at it.
mutant_check_tree() {
  local tree="$BATS_TEST_TMPDIR/mutant-tree" target="$1"
  shift
  rm -rf "$tree"
  mkdir -p "$tree/.gaia/scripts" "$tree/.claude/hooks/lib"
  cp "$SCRIPTS"/*.sh "$tree/.gaia/scripts/"
  cp -R "$REPO_ROOT"/.claude/hooks/lib/. "$tree/.claude/hooks/lib/"
  sed "$@" "$SCRIPTS/$target" >"$tree/.gaia/scripts/$target"
  cmp -s "$SCRIPTS/$target" "$tree/.gaia/scripts/$target" && { echo "mutant of $target changed nothing"; return 1; }
  SCRIPT="$tree/.gaia/scripts/audit-dispositions-check.sh"
}

# minor_key <path> <line> [class]: the compact key json of MEMBER's finding.
minor_key() {
  printf '{"member":"%s","finding_class":"%s","path":"%s","line":%s}' "$MEMBER" "${3:-rule/x}" "$1" "$2"
}

run_residual_count() {
  run bash "$SCRIPT" residual-count --root "$ALF_ROOT" --run-folder "$RUN_FOLDER"
}

@test "eligibility: accept-residual on a round whose default stop holds passes and freezes a version-4 snapshot of the stop's inputs" {
  local snapshot_file
  stop_base
  accept_all 3 "$(minor_rows f.txt 1 2)"
  run_check 3 --snapshot-dir "$SNAPSHOT_DIRECTORY"
  green || return 1
  snapshot_file="$SNAPSHOT_DIRECTORY/dispositions-3.checked.json"
  [ "$(jq -c '[.version, .default_stop, (.default_stop_keys | length), .human_accept, .satisfied_vetoes, .review_bases]' "$snapshot_file")" = \
    "[4,true,2,false,[],{\"$MEMBER\":\"member-clearance\"}]" ] || { cat "$snapshot_file"; return 1; }
  # Re-grade from the snapshot after the sidecar is overwritten and HEAD moves.
  alf_sidecar "$MEMBER" "$(minor_rows f.txt 7 7 rule/later)" 31
  alf_set_line other.txt 9 "after the round"
  alf_commit "after the round"
  [ "$(evaluator_field 3 '.default_stop')" = false ] || return 1
  run_check_all --snapshot-dir "$SNAPSHOT_DIRECTORY"
  green || return 1
  run_check_all
  green || return 1
  accept_all 3 "$(minor_rows f.txt 1 2)" "[$(disposition_entry f.txt 1 rule/x accept-residual "a different reason")]"
  run_check_all --snapshot-dir "$SNAPSHOT_DIRECTORY"
  red edited-after-check '{"round":3}'
}

@test "eligibility: accept-residual is refused when the stop does not hold or a stop key is fixed, allowed by a human accept or a typed key, never by claims in the entry (case table)" {
  local shape key claims round=1
  local -a rows=()
  printf 'case: %s\n' 'Minor-only round 2 refused; a human accept passes; the mutant dropping human_accept goes red' >&2
  stop_rounds "$(minor_rows f.txt 1 3)" "$(minor_rows f.txt 1 2)"
  accept_all 2 "$(minor_rows f.txt 1 2)"
  run_check 2
  red accept-residual-not-eligible "$(minor_key f.txt 1)" || return 1
  red accept-residual-not-eligible "$(minor_key f.txt 2)" || return 1
  accept_at 2
  run_check 2
  green || return 1
  mutant_check_tree audit-dispositions-grade-lib.sh -e 's/(\$stop.human_accept or (\$stop.default_stop/(($stop.default_stop/' || return 1
  run_check 2
  red accept-residual-not-eligible "$(minor_key f.txt 1)" || return 1
  SCRIPT="$SCRIPTS/audit-dispositions-check.sh"
  printf 'case: %s\n' 'a key typed with audit-accept-finding passes and no other key does; the mutant dropping the key arm goes red' >&2
  stop_rounds "$(minor_rows f.txt 1 3)" "$(minor_rows f.txt 1 2)"
  alf_add_checkpoint 1 fallback
  alf_state_edit '.allowance.accepted_keys = [{checkpoint: 1, key: [$member, "rule/x", "f.txt", 1], source: "typed", at: "t", session_id: "s1"}]' --arg member "$MEMBER"
  accept_all 2 "$(minor_rows f.txt 1 2)"
  run_check 2
  red accept-residual-not-eligible "$(minor_key f.txt 2)" || return 1
  grep -qF -- "$(minor_key f.txt 1)" <<<"$output" && { echo "accepted key refused: $output"; return 1; }
  accept_all 2 "$(minor_rows f.txt 1 2)" "[{\"member\":\"$MEMBER\",\"finding_class\":\"rule/x\",\"path\":\"f.txt\",\"line\":2,\"disposition\":\"fix\",\"reason\":\"\"}]"
  run_check 2
  green || return 1
  run bash "$SCRIPT" pr-sections --root "$ALF_ROOT" --run-folder "$RUN_FOLDER"
  green || return 1
  grep -F -- 'f.txt:1' <<<"$output" | grep -qF -- 'Human decision: ' || { echo "$output"; return 1; }
  mutant_check_tree audit-dispositions-grade-lib.sh -e 's/(\$accept_allowed or (\$stop.accepted_keys \/\/ \[\] | any(. == \$key)) | not)/($accept_allowed | not)/' || return 1
  run_check 2
  red accept-residual-not-eligible "$(minor_key f.txt 1)" || return 1
  SCRIPT="$SCRIPTS/audit-dispositions-check.sh"
  printf 'case: %s\n' 'each stop-false shape refuses with no accept and passes with a human accept' >&2
  for shape in major critical security-absent unknown-verdict null-previous-count legacy-snapshot no-marker whole-branch-member \
    repeat-fixed-triple repeat-back-again repeat-gap repeat-moved; do
    stop_false_case "$shape" || { echo "fixture $shape"; return 1; }
    [ "$(evaluator_field "$LAST_ROUND" '.default_stop')" = false ] || { echo "$shape: the stop holds"; return 1; }
    case "$shape" in
      repeat-*) [ "$(evaluator_field "$LAST_ROUND" '.signals.reintroduced')" = true ] || { echo "$shape: not reintroduced"; return 1; } ;;
    esac
    key="$(jq -c '.entries | map(select(.disposition == "accept-residual")) | first | {member, finding_class, path, line}' "$RUN_FOLDER/dispositions-$LAST_ROUND.json")"
    run_check "$LAST_ROUND"
    red accept-residual-not-eligible "$key" || { echo "shape $shape"; return 1; }
    accept_at "$LAST_ROUND"
    run_check "$LAST_ROUND"
    green || { echo "shape $shape twin"; return 1; }
  done
  printf 'case: %s\n' 'round 10 refused while round 9 passes on the stop' >&2
  while [ "$round" -le 9 ]; do rows+=("$(minor_rows f.txt 1 2)"); round=$((round + 1)); done
  stop_rounds "${rows[@]}"
  accept_all 9 "$(minor_rows f.txt 1 2)"
  run_check 9
  green || return 1
  alf_set_line other.txt 10 "round 10"
  alf_commit "round 10"
  alf_round 10 "$MEMBER" "$(minor_rows f.txt 1 2)"
  review_base_all member-clearance
  earn_marker "$MEMBER" 10
  accept_all 10 "$(minor_rows f.txt 1 2)"
  run_check 10
  red accept-residual-not-eligible "$(minor_key f.txt 1)" || return 1
  printf 'case: %s\n' 'a claim inside the entry changes nothing; the mutant reading the entry goes green' >&2
  claims='{"severity":"minor","security":false,"default_stop":true,"human_accept":true,"eligible":true}'
  stop_rounds "$(minor_rows f.txt 1 3)" "$(minor_rows f.txt 1 2)"
  accept_all 2 "$(minor_rows f.txt 1 2)"
  jq -c --argjson claims "$claims" '.entries |= map(. + $claims)' "$RUN_FOLDER/dispositions-2.json" >"$RUN_FOLDER/claimed.json"
  mv "$RUN_FOLDER/claimed.json" "$RUN_FOLDER/dispositions-2.json"
  run_check 2
  red accept-residual-not-eligible "$(minor_key f.txt 1)" || return 1
  mutant_check_tree audit-dispositions-grade-lib.sh \
    -e 's/and (\$accept_allowed or/and (.eligible == true or $accept_allowed or/' || return 1
  run_check 2
  green || return 1
  SCRIPT="$SCRIPTS/audit-dispositions-check.sh"
  printf 'case: %s\n' 'a threshold fix on a stop key refuses the accept beside it; a threshold waiver passes; the mutant dropping the fix arm goes green' >&2
  stop_base
  accept_all 3 "$(minor_rows f.txt 1 2)" "[$(disposition_entry f.txt 1 rule/x fix)]"
  run_check 3
  red accept-residual-not-eligible "$(minor_key f.txt 2)" || return 1
  accept_all 3 "$(minor_rows f.txt 1 2)" "[$(disposition_entry f.txt 1 rule/x waive-out-of-scope "below the threshold" triage-threshold)]"
  run_check 3
  green || return 1
  accept_all 3 "$(minor_rows f.txt 1 2)" "[$(disposition_entry f.txt 1 rule/x fix)]"
  mutant_check_tree audit-dispositions-grade-lib.sh -e 's/ and (\$threshold_fix | not)//' || return 1
  run_check 3
  green
}

# stop_false_case <name>: a branch whose last round fails the default stop
# for that one reason, with dispositions accepting its Minors and fixing
# anything else. Sets LAST_ROUND.
stop_false_case() {
  local extra
  case "$1" in
    major | critical | security-absent)
      case "$1" in
        major) extra='[{"path":"f.txt","line":5,"finding_class":"rule/m","severity":"major","security":false}]' ;;
        critical) extra='[{"path":"f.txt","line":5,"finding_class":"rule/m","severity":"critical","security":false}]' ;;
        *) extra='[{"path":"f.txt","line":5,"finding_class":"rule/m","severity":"minor"}]' ;;
      esac
      stop_base "$(joined "$(minor_rows f.txt 1 2)" "$extra")" || return 1
      accept_all 3 "$(minor_rows f.txt 1 2)" "[$(disposition_entry f.txt 5 rule/m fix)]"
      return 0
      ;;
    unknown-verdict)
      stop_base || return 1
      alf_state_edit '.history.rounds[2].members += ["code-audit-shell"]'
      ;;
    null-previous-count)
      stop_base || return 1
      alf_state_edit '.history.rounds[1].snapshot.A = null'
      ;;
    legacy-snapshot)
      stop_base || return 1
      alf_state_edit 'del(.history.rounds[0].snapshot.counted_keys)'
      ;;
    no-marker)
      stop_base || return 1
      rm -f "$ALF_ROOT"/.gaia/local/audit/*.ok
      ;;
    whole-branch-member)
      stop_base || return 1
      review_base_all no-anchor
      ;;
    repeat-fixed-triple)
      stop_base || return 1
      alf_dispositions 1 "[$(disposition_entry f.txt 1 rule/x fix)]"
      ;;
    repeat-back-again)
      stop_rounds "$(minor_rows f.txt 1 3)" "$(minor_rows f.txt 1 2)" "$(minor_rows f.txt 1 3)" || return 1
      ;;
    repeat-gap)
      stop_rounds "$(joined "$(minor_rows f.txt 1 2)" "$(minor_rows f.txt 3 3 rule/z)")" "$(minor_rows f.txt 1 2)" \
        "$(minor_rows f.txt 1 2)" "$(joined "$(minor_rows f.txt 1 2)" "$(minor_rows f.txt 5 5 rule/z)")" || return 1
      ;;
    repeat-moved)
      stop_rounds "$(minor_rows f.txt 1 2)" "$(minor_rows f.txt 2 3)" "$(minor_rows f.txt 3 4)" || return 1
      ;;
  esac
  accept_all "$LAST_ROUND" "$(jq -c '.findings | map({finding_class, path, line})' "$ALF_ROOT"/.gaia/local/audit/*."$ALF_SLUG.$MEMBER".findings.json)"
}

# accepted_key_rounds [round-2-entries]: rounds of 3 then 2 Minors on f.txt,
# with f.txt:1 typed as audit-accept-finding at checkpoint 1.
accepted_key_rounds() {
  stop_rounds "$(minor_rows f.txt 1 3)" "${1:-$(minor_rows f.txt 1 2)}" || return 1
  alf_add_checkpoint 1 fallback || return 1
  alf_state_edit '.allowance.accepted_keys = [{checkpoint: 1, key: [$member, "rule/x", "f.txt", 1], source: "typed", at: "t", session_id: "s1"}]' --arg member "$MEMBER"
}

# fix_both <r>: dispositions-<r>.json disposing f.txt:1 and f.txt:2 fix.
fix_both() {
  write_dispositions "$1" "$(jq -n -c --arg member "$MEMBER" '[1, 2] | map({member: $member, finding_class: "rule/x", path: "f.txt", line: ., disposition: "fix", reason: ""})')"
}

# bats test_tags=protected
@test "human-accepted-fix: a key a human accepted is refused fix unless a veto binds it or the round re-reports it security-class, and a version-3 snapshot keeps its predicate (case table)" {
  printf 'case: %s\n' 'the accepted key disposed fix is refused, the other key is not; the mutant disarming the rule passes' >&2
  accepted_key_rounds || return 1
  fix_both 2
  run_check 2
  red human-accepted-fix "$(minor_key f.txt 1)" || return 1
  grep -qF -- "$(minor_key f.txt 2)" <<<"$output" && { echo "unaccepted key refused: $output"; return 1; }
  accept_all 2 "$(minor_rows f.txt 1 2)" "[$(disposition_entry f.txt 2 rule/x fix "")]"
  run_check 2
  green || return 1
  fix_both 2
  mutant_check_tree audit-dispositions-grade-lib.sh -e 's/\$version >= 4 and (\$is_vetoed/$version >= 5 and ($is_vetoed/' || return 1
  run_check 2
  green || return 1
  SCRIPT="$SCRIPTS/audit-dispositions-check.sh"
  printf 'case: %s\n' 'a veto binding the accepted key lets it be fixed' >&2
  vetoes 2 rule/x f.txt 1
  run_check 2
  green || return 1
  rm -f "$RUN_FOLDER/vetoes.json"
  printf 'case: %s\n' 'a security-class re-report of the accepted key may be fixed' >&2
  accepted_key_rounds "$(minor_rows f.txt 1 2 | jq -c 'map(if .line == 1 then .security = true else . end)')" || return 1
  fix_both 2
  run_check 2
  green || return 1
  printf 'case: %s\n' 'a version-3 snapshot re-grades without the rule; the same snapshot read as version 4 is refused' >&2
  accepted_key_rounds || return 1
  fix_both 2
  mutant_check_tree audit-dispositions-grade-lib.sh -e 's/\$version >= 4 and (\$is_vetoed/$version >= 5 and ($is_vetoed/' || return 1
  sed -e 's/{version: 4, round/{version: 3, round/' "$SCRIPTS/audit-dispositions-snapshot-lib.sh" >"${SCRIPT%/*}/audit-dispositions-snapshot-lib.sh"
  run_check 2 --snapshot-dir "$SNAPSHOT_DIRECTORY"
  green || return 1
  SCRIPT="$SCRIPTS/audit-dispositions-check.sh"
  [ "$(jq '.version' "$SNAPSHOT_DIRECTORY/dispositions-2.checked.json")" = 3 ] || return 1
  run_check_all --snapshot-dir "$SNAPSHOT_DIRECTORY"
  green || return 1
  jq -c '.version = 4' "$SNAPSHOT_DIRECTORY/dispositions-2.checked.json" >"$BATS_TEST_TMPDIR/snapshot" &&
    mv "$BATS_TEST_TMPDIR/snapshot" "$SNAPSHOT_DIRECTORY/dispositions-2.checked.json"
  run_check_all --snapshot-dir "$SNAPSHOT_DIRECTORY"
  red human-accepted-fix "$(minor_key f.txt 1)"
}

@test "eligibility: an honored triage mark on the stop round needs no entry beside the accepts" {
  local mark='[{"path":"lib/s.sh","line":4,"finding_class":"rule/t","severity":"major","security":false,"triage":true,"triage_reason":"below the threshold"}]'
  MEMBER="$SHELL_MAINTAINER"
  stop_rounds "$(minor_rows lib/s.sh 1 3)" "$(minor_rows lib/s.sh 1 2)" "$(joined "$(minor_rows lib/s.sh 1 2)" "$mark")"
  [ "$(evaluator_field 3 '.default_stop')" = true ] || return 1
  accept_all 3 "$(minor_rows lib/s.sh 1 2)"
  run_check 3
  green
}

# veto_fixed_in <r> <fixer-disposition>: round r disposes c/imp f.txt:3 fix and
# its fixer reports the given disposition on it.
veto_fixed_in() {
  write_dispositions "$1" "$(fill "$FINDINGS_JSON" "[$(disposition_entry f.txt 3 c/imp fix)]")"
  jq -n -c --arg disposition "$2" '{results: [{member: "code-audit-frontend", finding_class: "c/imp", path: "f.txt", line: 3, disposition: $disposition}]}' \
    >"$RUN_FOLDER/fixer-$1-audit.json"
}

# without_veto_key: the round-1 findings minus c/imp f.txt:3.
without_veto_key() {
  jq -c '[.[] | select(.line != 3 or .path != "f.txt")]' <<<"$FINDINGS_JSON"
}

# next_tree_round <r> <findings-json>: commit a change, then record round r on it.
next_tree_round() {
  alf_set_line other.txt "$1" "round $1"
  alf_commit "round $1"
  open_round "$1" "$2"
}

# fixed_tree_round <r> <findings-json>: commit a rewrite of the vetoed line
# f.txt:3, the fix landing, then record round r on it. A veto counts a fix
# only from a tree that changed its path, so a round on next_tree_round's
# tree satisfies no veto.
fixed_tree_round() {
  alf_set_line f.txt 3 "fixed in round $1"
  alf_commit "fix before round $1"
  open_round "$1" "$2"
}

# veto_unsatisfied_red <r> <findings-json>: on round r, an accept-residual on
# the vetoed key fails vetoed-not-fix and no entry fails undisposed.
veto_unsatisfied_red() {
  write_dispositions "$1" "$(fill "$2" "[$(disposition_entry f.txt 3 c/imp accept-residual because)]")"
  run_check "$1"
  red vetoed-not-fix "$(key_json c/imp f.txt 3)" || return 1
  write_dispositions "$1" "$(fill "$2" '[]' 'select(.path != "f.txt" or .line != 3)')"
  run_check "$1"
  red undisposed "$(key_json c/imp f.txt 3)"
}

# bats test_tags=protected
@test "vetoes: unsatisfied (never fixed, re-reported, fixer disputed or cannot_fix, member not dispatched, fix before the veto, shifted line) and satisfied (fixer fixed on a closing round, main-thread fix reviewed clean) (case table)" {
  local fixer_disposition shifted
  printf 'case: %s\n' 'unsatisfied: never fixed, re-reported, fixer disputed or cannot_fix' >&2
  vetoes 1 c/imp f.txt 3
  write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$(disposition_entry f.txt 3 c/imp waive-out-of-scope because triage-threshold)]")"
  fixed_tree_round 2 "$(without_veto_key)"
  veto_unsatisfied_red 2 "$(without_veto_key)" || { echo "never fixed"; return 1; }
  veto_fixed_in 1 fixed
  alf_sidecar "$MEMBER" "$FINDINGS_JSON" 21
  veto_unsatisfied_red 2 "$FINDINGS_JSON" || { echo "re-reported"; return 1; }
  alf_sidecar "$MEMBER" "$(without_veto_key)" 21
  for fixer_disposition in disputed cannot_fix; do
    veto_fixed_in 1 "$fixer_disposition"
    veto_unsatisfied_red 2 "$(without_veto_key)" || { echo "fixer $fixer_disposition"; return 1; }
  done
  reset_fixture
  printf 'case: %s\n' 'unsatisfied: member not dispatched after the fix, or the fix came before the veto round (the round it binds and later)' >&2
  vetoes 1 c/imp f.txt 3
  veto_fixed_in 1 fixed
  fixed_tree_round 2 "$(without_veto_key)"
  alf_state_edit '.history.rounds[1].members = ["code-audit-shell"]'
  write_dispositions 2 "[$(disposition_entry f.txt 3 c/imp accept-residual because)]"
  run_check 2
  red vetoed-not-fix "$(key_json c/imp f.txt 3)" || return 1
  write_dispositions 2 '[]'
  run_check 2
  red undisposed "$(key_json c/imp f.txt 3)" || return 1
  alf_state_edit '.history.rounds[1].members = ["code-audit-frontend"]'
  vetoes 3 c/imp f.txt 3
  next_tree_round 3 "$(without_veto_key)"
  veto_unsatisfied_red 3 "$(without_veto_key)" || { echo "fix before the veto, the round it binds"; return 1; }
  next_tree_round 4 "$(without_veto_key)"
  veto_unsatisfied_red 4 "$(without_veto_key)" || { echo "fix before the veto, later round"; return 1; }
  reset_fixture
  printf 'case: %s\n' 'a shifted-line re-report is a new key; the satisfied veto needs nothing' >&2
  vetoes 1 c/imp f.txt 3
  veto_fixed_in 1 fixed
  shifted="$(jq -c '. + [{"path":"f.txt","line":8,"finding_class":"c/imp","severity":"major","security":false}]' <<<"$(without_veto_key)")"
  fixed_tree_round 2 "$shifted"
  write_dispositions 2 "$(fill "$shifted" '[]' 'select(.path != "f.txt" or .line != 8)')"
  run_check 2
  red undisposed "$(key_json c/imp f.txt 8)" || return 1
  grep -qF -- "$(key_json c/imp f.txt 3)" <<<"$output" && { echo "$output"; return 1; }
  reset_fixture
  printf 'case: %s\n' 'satisfied: a closing round omits the key with no entry through check, both check-alls and a later round' >&2
  write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$(disposition_entry f.txt 3 c/imp waive-out-of-scope because triage-threshold)]")"
  run_check 1 --snapshot-dir "$SNAPSHOT_DIRECTORY"
  green || return 1
  vetoes 2 c/imp f.txt 3
  next_tree_round 2 "$FINDINGS_JSON"
  veto_fixed_in 2 fixed
  run_check 2 --snapshot-dir "$SNAPSHOT_DIRECTORY"
  green || return 1
  fixed_tree_round 3 "$(without_veto_key)"
  alf_state_edit '.history.rounds[2].closing = true'
  write_dispositions 3 "$(fill "$(without_veto_key)" '[]')"
  run_check 3 --snapshot-dir "$SNAPSHOT_DIRECTORY"
  green || return 1
  [ "$(jq -c '.satisfied_vetoes' "$SNAPSHOT_DIRECTORY/dispositions-3.checked.json")" = '[["code-audit-frontend","c/imp","f.txt",3]]' ] || return 1
  run_check_all --snapshot-dir "$SNAPSHOT_DIRECTORY"
  green || return 1
  run_check_all
  green || return 1
  # The bound hook stores round 3's snapshot before round 4, and veto
  # satisfaction reads round 3's keys from it.
  # shellcheck source=/dev/null
  . "$SCRIPTS/audit-loop-eval.sh"
  alf_store_snapshot 3
  next_tree_round 4 "$(without_veto_key)"
  write_dispositions 4 "$(fill "$(without_veto_key)" '[]')"
  run_check 4
  green || return 1
  reset_fixture
  printf 'case: %s\n' 'satisfied: a main-thread fix reviewed clean, its synthetic fix entry passing with the veto kept or retired' >&2
  write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$(disposition_entry f.txt 3 c/imp waive-out-of-scope because triage-threshold)]")"
  run_check 1 --snapshot-dir "$SNAPSHOT_DIRECTORY"
  green || return 1
  vetoes 2 c/imp f.txt 3
  alf_set_line f.txt 3 "fixed on the main thread"
  alf_commit "inline veto fix"
  open_round 2 "$(without_veto_key)"
  write_dispositions 2 "$(fill "$(without_veto_key)" '[]')"
  run_check 2
  green || { echo "inline fix not satisfied"; return 1; }
  write_dispositions 2 "$(fill "$(without_veto_key)" "[$(disposition_entry f.txt 3 c/imp fix)]")"
  run_check 2
  green || { echo "synthetic entry, veto kept"; return 1; }
  printf '{"version":1,"keys":[]}\n' >"$RUN_FOLDER/vetoes.json"
  write_dispositions 2 "$(fill "$(without_veto_key)" "[$(disposition_entry f.txt 3 c/imp waive-out-of-scope because triage-threshold)]")"
  run_check 2
  red unknown-key "$(key_json c/imp f.txt 3)" || { echo "a retired key's waiver must still fail"; return 1; }
  write_dispositions 2 "$(fill "$(without_veto_key)" "[$(disposition_entry f.txt 3 c/imp fix)]")"
  run_check_all --snapshot-dir "$SNAPSHOT_DIRECTORY"
  green || { echo "synthetic entry, veto retired"; return 1; }
}

@test "lapse guard: a veto past every dispositions file fails the read-only check-all and passes the bound hook's call" {
  write_dispositions 1 "$(fill "$FINDINGS_JSON" '[]')"
  vetoes 2 c/imp f.txt 3
  run_check_all --snapshot-dir "$SNAPSHOT_DIRECTORY"
  green || return 1
  run_check_all
  red undisposed "$(key_json c/imp f.txt 3)"
}

# decide <line> <decision> [extra-json]: record the human's decision on round
# 1's Minor at f.txt:<line> through record-residual.
decide() {
  minor_rows f.txt "$1" "$1" | jq -c --arg member "$MEMBER" --argjson extra "${3:-{\}}" '.[0] + {member: $member} + $extra' >"$BATS_TEST_TMPDIR/decided-$1.json"
  run bash "$SCRIPT" record-residual --root "$ALF_ROOT" --run-folder "$RUN_FOLDER" --finding "$BATS_TEST_TMPDIR/decided-$1.json" --decision "$2"
}

@test "needs-human: the open round's findings fail undecided and name record-residual; once a later round closes it they no longer block, and accept and waive are refused" {
  local undecided
  stop_rounds "$(minor_rows f.txt 1 3)"
  run_check_all --snapshot-dir "$SNAPSHOT_DIRECTORY"
  green || return 1
  run_check_all
  for undecided in 1 2 3; do
    red undecided "{\"round\":1,\"member\":\"$MEMBER\",\"finding_class\":\"rule/x\",\"path\":\"f.txt\",\"line\":$undecided}" || return 1
  done
  grep -qF -- "record-residual --root $ALF_ROOT --run-folder $RUN_FOLDER --finding <file> --decision accept|waive|fix|fixed" <<<"$output" || { echo "no next step in: $output"; return 1; }
  # Round 2 overwrites the sidecar with nothing and the hook stores round 1's
  # keys, so round 1 is closed: its findings fall to the residue drain.
  alf_set_line other.txt 2 "round 2"
  alf_commit "round 2" || return 1
  alf_round 2 "$MEMBER" '[]' || return 1
  run_check_all
  green || return 1
  decide 2 accept '{"reason":"deferred to its own change"}'
  [ "$status" -eq 3 ] || { echo "an accept on a closed round recorded: $status $output"; return 1; }
  decide 3 waive '{"reason":"below the threshold"}'
  [ "$status" -eq 3 ] || { echo "a waive on a closed round recorded: $status $output"; return 1; }
}

@test "needs-human: on the open round, accept and waive read severity and security live, another member's row decides nothing, and the latest decision wins" {
  local security_minor critical vetoed
  security_minor="$(alf_entries f.txt 3 3 rule/x | jq -c 'map(. + {severity: "minor", security: true})')"
  critical="$(alf_entries f.txt 4 4 rule/x | jq -c 'map(. + {severity: "critical", security: false})')"
  stop_rounds "$(joined "$(minor_rows f.txt 1 2)" "$security_minor" "$critical")"
  # decide writes severity minor and security false whatever the live read
  # says, so a refusal below proves the bound ignores the caller's values.
  decide 3 accept '{"reason":"deferred"}'
  [ "$status" -eq 3 ] || { echo "a security-class accept recorded: $status $output"; return 1; }
  decide 3 waive '{"reason":"below the threshold"}'
  [ "$status" -eq 3 ] || { echo "a security-class waive recorded: $status $output"; return 1; }
  decide 4 accept '{"reason":"deferred"}'
  [ "$status" -eq 3 ] || { echo "a Critical accept recorded: $status $output"; return 1; }
  MEMBER="$SHELL_MAINTAINER" decide 3 fix || return 1
  run_check_all
  red undecided "{\"round\":1,\"member\":\"$MEMBER\",\"finding_class\":\"rule/x\",\"path\":\"f.txt\",\"line\":3}" || { echo "another member's row decided the key"; return 1; }
  MEMBER="$SHELL_MAINTAINER" decide 2 fix || return 1
  decide 1 accept '{"reason":"deferred to its own change"}' && decide 2 waive '{"reason":"below the threshold"}' && decide 3 fix && decide 4 fix || return 1
  run_check_all
  for vetoed in 3 4; do
    red undisposed "{\"member\":\"$MEMBER\",\"finding_class\":\"rule/x\",\"path\":\"f.txt\",\"line\":$vetoed}" || return 1
  done
  run_sections
  [ "$output" = '## Accepted residuals (recorded, not fixed)

- `f.txt:1` deferred to its own change. <!-- gaia-debt-key: v1 class=rule/x path=f.txt line=1 -->

## Waived below triage threshold (not filed)

- f.txt:2 rule/x: below the threshold' ] || { echo "pr-sections: $output"; return 1; }
  decide 1 fix || return 1
  run_residual_count
  [ "$output" = '{"total":0,"ask":0}' ] || { echo "the corrected decision was dropped: $output"; return 1; }
}

@test "needs-human: a fix decision vetoes its key from the next unit's start round, keeps other vetoes, adds none on a repeat, and check-all refuses it unreviewed" {
  local next_unit
  stop_rounds "$(minor_rows f.txt 1 1)"
  vetoes 9 c/imp other.txt 3
  decide 1 fix || return 1
  next_unit="$(bash "$SCRIPTS/audit-loop-eval.sh" next-unit --root "$ALF_ROOT" | tr ' ' ',')"
  [ "$(jq -c '[.keys[] | [.member, .finding_class, .path, .line, .unit, .effective_from_round]]' "$RUN_FOLDER/vetoes.json")" = \
    "[[\"code-audit-frontend\",\"c/imp\",\"other.txt\",3,1,9],[\"$MEMBER\",\"rule/x\",\"f.txt\",1,$next_unit]]" ] || { cat "$RUN_FOLDER/vetoes.json"; return 1; }
  decide 1 fix || return 1
  [ "$(jq '.keys | length' "$RUN_FOLDER/vetoes.json")" -eq 2 ] || { cat "$RUN_FOLDER/vetoes.json"; return 1; }
  run_check_all
  red undisposed "{\"member\":\"$MEMBER\",\"finding_class\":\"rule/x\",\"path\":\"f.txt\",\"line\":1}"
}

@test "needs-human: a fix decision's reason becomes its veto's direction, a repeat replaces it, and a decision with no reason carries none rather than its failure mode" {
  stop_rounds "$(minor_rows f.txt 1 2)"
  decide 1 fix '{"reason":"use one shared reader"}'
  [ "$status" -eq 0 ] || { echo "the fix was refused: $output"; return 1; }
  [ "$(jq -r '.keys[0].direction' "$RUN_FOLDER/vetoes.json")" = "use one shared reader" ] || { cat "$RUN_FOLDER/vetoes.json"; return 1; }
  decide 1 fix '{"reason":"move it into the lib"}'
  [ "$status" -eq 0 ] || { echo "the repeat fix was refused: $output"; return 1; }
  [ "$(jq -c '[.keys[] | .direction]' "$RUN_FOLDER/vetoes.json")" = '["move it into the lib"]' ] || { cat "$RUN_FOLDER/vetoes.json"; return 1; }
  [ "$(jq -rs '[.[] | select(.line == 1 and .decision == "fix")] | last | .reason' "$RUN_FOLDER/recorded-residuals.jsonl")" = "move it into the lib" ] ||
    { cat "$RUN_FOLDER/recorded-residuals.jsonl"; return 1; }
  decide 2 fix '{"failure_mode":"the reader drops the date","reason":"  "}'
  [ "$status" -eq 0 ] || { echo "the reasonless fix was refused: $output"; return 1; }
  [ "$(jq -c '.keys[1] | has("direction")' "$RUN_FOLDER/vetoes.json")" = false ] || { cat "$RUN_FOLDER/vetoes.json"; return 1; }
  run_check_all
  red undisposed "{\"member\":\"$MEMBER\",\"finding_class\":\"rule/x\",\"path\":\"f.txt\",\"line\":1}"
}

@test "needs-human: a repeat fix decision from a later unit updates the key's one entry in place, moving effective_from_round forward and collapsing older copies" {
  local key next_unit
  stop_rounds "$(minor_rows f.txt 1 1)"
  key="$(jq -n -c --arg member "$MEMBER" '{member: $member, finding_class: "rule/x", path: "f.txt", line: 1}')"
  # Two copies an earlier unit left, both binding from before the next unit's start round.
  jq -n -c --argjson key "$key" '{version: 1, keys: [$key + {unit: 0, effective_from_round: 0, direction: "old"}, $key + {unit: 0, effective_from_round: 1}]}' >"$RUN_FOLDER/vetoes.json"
  decide 1 fix '{"reason":"redo it in the lib","repair_paths":["lib/s.sh"]}'
  [ "$status" -eq 0 ] || { echo "the repeat fix was refused: $output"; return 1; }
  next_unit="$(bash "$SCRIPTS/audit-loop-eval.sh" next-unit --root "$ALF_ROOT" | tr ' ' ',')"
  [ "$(jq -c '[.keys[] | [.unit, .effective_from_round, .direction, .repair_paths]]' "$RUN_FOLDER/vetoes.json")" = "[[$next_unit,\"redo it in the lib\",[\"lib/s.sh\"]]]" ] ||
    { cat "$RUN_FOLDER/vetoes.json"; return 1; }
  decide 1 fix '{"reason":"in place after all"}'
  [ "$(jq -c '[.keys[] | [.direction, has("repair_paths")]]' "$RUN_FOLDER/vetoes.json")" = '[["in place after all",false]]' ] || { cat "$RUN_FOLDER/vetoes.json"; return 1; }
}

@test "needs-human: a fix decision's repair_paths is refused when the roster gives one to no member or cannot be read, or when it is not a list of paths" {
  stop_rounds "$(minor_rows f.txt 1 1)"
  with_f_txt_ownerless decide 1 fix '{"repair_paths":["lib/s.sh","g.txt"]}'
  [ "$status" -eq 3 ] || { echo "an unowned repair path recorded: $status $output"; return 1; }
  grep -qF -- 'repair path to no member' <<<"$output" || { echo "the refusal names no cause: $output"; return 1; }
  with_roster_unreadable decide 1 fix '{"repair_paths":["lib/s.sh"]}'
  [ "$status" -eq 3 ] || { echo "a repair path under an unreadable roster recorded: $status $output"; return 1; }
  local malformed
  for malformed in '"lib/s.sh"' '[""]' '[1]'; do
    decide 1 fix "{\"repair_paths\":$malformed}"
    [ "$status" -eq 3 ] || { echo "repair_paths $malformed recorded: $status $output"; return 1; }
    grep -qF -- 'must be an array of non-empty paths' <<<"$output" || { echo "repair_paths $malformed refused for another cause: $output"; return 1; }
  done
  [ ! -e "$RUN_FOLDER/vetoes.json" ] || { cat "$RUN_FOLDER/vetoes.json"; return 1; }
  with_f_txt_ownerless decide 1 fix '{"repair_paths":["lib/s.sh"]}'
  [ "$status" -eq 0 ] || { echo "an owned repair path was refused: $output"; return 1; }
  [ "$(jq -c '.keys[0].repair_paths' "$RUN_FOLDER/vetoes.json")" = '["lib/s.sh"]' ]
}

@test "needs-human: a fix decision naming an enforcement repair path is refused and writes no veto" {
  local enforcement_path
  stop_rounds "$(minor_rows f.txt 1 1)"
  enforcement_path="$(bash -c '. "$1" && printf "%s" "${ENFORCEMENT_PATHS[0]}"' _ "$SCRIPTS/audit-fix-verify-state-lib.sh")"
  [ -n "$enforcement_path" ] || return 1
  with_f_txt_ownerless decide 1 fix "$(jq -n -c --arg path "$enforcement_path" '{repair_paths: ["lib/s.sh", $path]}')"
  [ "$status" -eq 3 ] || { echo "an enforcement repair path recorded: $status $output"; return 1; }
  grep -qF -- 'enforcement path the fixer can never edit' <<<"$output" || { echo "the refusal names no cause: $output"; return 1; }
  [ ! -e "$RUN_FOLDER/vetoes.json" ] || { cat "$RUN_FOLDER/vetoes.json"; return 1; }
}

# race_shims <directory>: a forced interleave of two fix decisions. Its mkdir
# exits 0 even when the directory exists, as uutils mkdir does for two racing
# creators, and counts attempts on the veto lock. Its date holds the first
# writer inside the lock until the second writer reaches the same point (both
# read the old vetoes.json) or has tried the lock twice more (it is blocked).
race_shims() {
  mkdir -p "$1"
  cat >"$1/mkdir" <<'SHIM'
#!/bin/bash
[ "${1-}" = "$HOLD_LOCK" ] && printf 'x\n' >>"$HOLD_DIRECTORY/attempts"
/bin/mkdir "$@" 2>/dev/null
exit 0
SHIM
  cat >"$1/date" <<'SHIM'
#!/bin/bash
if [ "${1-}" = -u ] && [ -d "$HOLD_LOCK" ]; then
  if ( set -C; : >"$HOLD_DIRECTORY/first" ) 2>/dev/null; then
    waited=0
    until [ -e "$HOLD_DIRECTORY/second" ] || [ "$(($(wc -l <"$HOLD_DIRECTORY/attempts")))" -ge 3 ] || [ "$waited" -ge 100 ]; do
      sleep 0.1; waited=$((waited + 1))
    done
  else
    : >"$HOLD_DIRECTORY/second"
  fi
fi
exec /bin/date "$@"
SHIM
  chmod +x "$1/mkdir" "$1/date"
}

# with_f_txt_ownerless <command...>: run the command under a roster that gives
# f.txt to no member, then restore stop_rounds' roster.
with_f_txt_ownerless() {
  local roster="$ALF_ROOT/.gaia/audit-ci.yml" command_status=0
  cp "$roster" "$BATS_TEST_TMPDIR/audit-ci.yml.kept"
  printf 'auditors:\n  - name: %s\n    globs:\n      - "lib/**"\n    audience: adopter\n  - name: code-audit-frontend\n    globs:\n      - "other.txt"\n    audience: adopter\n    default: true\n' \
    "$SHELL_MAINTAINER" >"$roster"
  "$@" || command_status=$?
  cp "$BATS_TEST_TMPDIR/audit-ci.yml.kept" "$roster"
  return "$command_status"
}

# with_roster_unreadable <command...>: run the command under a roster with no
# auditors: block, then restore stop_rounds' roster.
with_roster_unreadable() {
  local roster="$ALF_ROOT/.gaia/audit-ci.yml" command_status=0
  cp "$roster" "$BATS_TEST_TMPDIR/audit-ci.yml.kept"
  printf 'version: 1\n' >"$roster"
  "$@" || command_status=$?
  cp "$BATS_TEST_TMPDIR/audit-ci.yml.kept" "$roster"
  return "$command_status"
}

@test "needs-human: a fix decision is refused for a cross-remit finding no member owns, security-class included, recorded where one owns it, and concurrent fix decisions each keep their veto" {
  local cross cross_security line
  cross="$(minor_rows f.txt 1 1 | jq -c 'map(. + {cross_remit: true})')"
  cross_security="$(minor_rows f.txt 4 4 | jq -c 'map(. + {cross_remit: true, security: true})')"
  stop_rounds "$(joined "$cross" "$(minor_rows f.txt 2 3)" "$cross_security")"
  with_f_txt_ownerless decide 1 fix
  [ "$status" -eq 3 ] || { echo "a cross-remit fix no member can review recorded: $status $output"; return 1; }
  [ ! -e "$RUN_FOLDER/vetoes.json" ] || { cat "$RUN_FOLDER/vetoes.json"; return 1; }
  race_shims "$BATS_TEST_TMPDIR/race"
  for line in 2 3; do
    minor_rows f.txt "$line" "$line" | jq -c --arg member "$MEMBER" '.[0] + {member: $member}' >"$BATS_TEST_TMPDIR/decided-$line.json"
    HOLD_LOCK="$RUN_FOLDER/vetoes.json.lock" HOLD_DIRECTORY="$BATS_TEST_TMPDIR" PATH="$BATS_TEST_TMPDIR/race:$PATH" \
      bash "$SCRIPT" record-residual --root "$ALF_ROOT" --run-folder "$RUN_FOLDER" --finding "$BATS_TEST_TMPDIR/decided-$line.json" --decision fix >/dev/null 2>&1 &
  done
  wait
  [ -e "$BATS_TEST_TMPDIR/first" ] || { echo "no writer reached the hold, so nothing was interleaved"; return 1; }
  [ "$(jq '.keys | length' "$RUN_FOLDER/vetoes.json")" -eq 2 ] || { cat "$RUN_FOLDER/vetoes.json"; return 1; }
  with_f_txt_ownerless decide 4 fix
  [ "$status" -eq 3 ] || { echo "a security-class cross-remit fix no member can review recorded: $status $output"; return 1; }
  [ "$(jq '.keys | length' "$RUN_FOLDER/vetoes.json")" -eq 2 ] || { cat "$RUN_FOLDER/vetoes.json"; return 1; }
  decide 1 fix
  [ "$status" -eq 0 ] || { echo "a cross-remit fix on an owned path was refused: $status $output"; return 1; }
  [ "$(jq '.keys | length' "$RUN_FOLDER/vetoes.json")" -eq 3 ] || { cat "$RUN_FOLDER/vetoes.json"; return 1; }
}

# member_digest <member> <tree>: the member's audit digest at that tree.
member_digest() {
  bash "$SCRIPTS/audit-member-digest.sh" --root "$ALF_ROOT" --member "$1" --ref "$2"
}

# cross_remit_critical_fixed <round-2-entries-json>: round 1's member reports
# a cross-remit Critical on lib/s.sh:1, which the roster gives to the shell
# maintainer; the human records fix, the main thread commits the repair, and
# round 2 dispatches the path owner alone with the given entries.
cross_remit_critical_fixed() {
  local tree_before
  stop_rounds "$(alf_entries lib/s.sh 1 1 rule/x | jq -c 'map(. + {severity: "critical", security: false, cross_remit: true})')" || return 1
  alf_entries lib/s.sh 1 1 rule/x | jq -c --arg member "$MEMBER" '.[0] + {member: $member, reason: "repair it here"}' >"$BATS_TEST_TMPDIR/critical.json"
  run bash "$SCRIPT" record-residual --root "$ALF_ROOT" --run-folder "$RUN_FOLDER" --finding "$BATS_TEST_TMPDIR/critical.json" --decision fix
  [ "$status" -eq 0 ] || { echo "the cross-remit Critical fix was refused: $output"; return 1; }
  tree_before="$ALF_TREE"
  alf_set_line lib/s.sh 1 "repaired"
  alf_commit "repair lib/s.sh" || return 1
  # The repair moves the owner's digest, so its clearance lapses and it is
  # owed again; the reporting member's digest stays put.
  [ "$(member_digest "$SHELL_MAINTAINER" "$tree_before")" != "$(member_digest "$SHELL_MAINTAINER" "$ALF_TREE")" ] || { echo "the owner is not owed again"; return 1; }
  [ "$(member_digest "$MEMBER" "$tree_before")" = "$(member_digest "$MEMBER" "$ALF_TREE")" ] || { echo "the reporting member is owed again"; return 1; }
  alf_round 2 "$SHELL_MAINTAINER" "$1" || return 1
  write_dispositions 2 "$(fill "$1" '[]')"
}

@test "needs-human: a cross-remit Critical decided fix is satisfied only by its path owner's clean review of the repair (case table)" {
  printf 'case: %s\n' 'owner reviews the repair clean, check-all allows the stop' >&2
  cross_remit_critical_fixed '[]' || return 1
  run_check_all
  green || return 1
  printf 'case: %s\n' 'owner re-reports the repaired line, the veto stays unsatisfied' >&2
  cross_remit_critical_fixed "$(alf_entries lib/s.sh 2 2 rule/owner | jq -c 'map(. + {severity: "major", security: false})')" || return 1
  run_check_all
  red undisposed "$(key_json rule/x lib/s.sh 1)"
}

@test "needs-human: a fixed decision is recorded only for a non-security cross-remit finding whose path changed, or a security-class one no member owns, under a readable roster (case table)" {
  local fixing_commit
  printf 'case: %s\n' 'fixed on a cross-remit finding a commit changed; an unchanged path or a finding not cross-remit is refused' >&2
  stop_rounds "$(joined "$(minor_rows f.txt 1 1 | jq -c 'map(. + {cross_remit: true})')" "$(minor_rows f.txt 2 2)")"
  decide 1 fixed '{"reason":"reworded"}'
  [ "$status" -eq 3 ] || { echo "a fixed on an unchanged path recorded: $status $output"; return 1; }
  alf_set_line f.txt 1 "reworded"
  alf_commit "reword f.txt" || return 1
  fixing_commit="$(git -C "$ALF_ROOT" rev-parse HEAD)"
  decide 2 fixed '{"reason":"reworded"}'
  [ "$status" -eq 3 ] || { echo "a fixed on a finding not cross-remit recorded: $status $output"; return 1; }
  with_f_txt_ownerless decide 1 fix
  [ "$status" -eq 3 ] || { echo "a cross-remit fix no member can review recorded: $status $output"; return 1; }
  grep -qF -- 'record --decision fixed' <<<"$output" || { echo "the fix refusal names no fixed route: $output"; return 1; }
  decide 1 fixed '{"reason":"reworded"}' || return 1
  [ ! -e "$RUN_FOLDER/vetoes.json" ] || { cat "$RUN_FOLDER/vetoes.json"; return 1; }
  decide 2 accept '{"reason":"deferred to its own change"}' || return 1
  run_check_all
  green || return 1
  run_sections
  [ "$output" = "## Accepted residuals (recorded, not fixed)

- \`f.txt:2\` deferred to its own change. <!-- gaia-debt-key: v1 class=rule/x path=f.txt line=2 -->

## Cross-remit findings fixed after their round

- f.txt:1 rule/x: fixed in ${fixing_commit:0:12}: reworded" ] || { echo "pr-sections: $output"; return 1; }
  printf 'case: %s\n' 'a security-class cross-remit finding is refused fixed even after a commit changed its path' >&2
  stop_rounds "$(minor_rows f.txt 1 1 | jq -c 'map(. + {cross_remit: true, security: true})')"
  alf_set_line f.txt 1 "reworded"
  alf_commit "reword f.txt" || return 1
  decide 1 fixed '{"reason":"reworded"}'
  [ "$status" -eq 3 ] || { echo "a security-class fixed recorded: $status $output"; return 1; }
  [ ! -e "$RUN_FOLDER/recorded-residuals.jsonl" ] || return 1
  printf 'case: %s\n' 'a security-class cross-remit finding no member owns takes fixed, with no veto, once a commit changed its path' >&2
  stop_rounds "$(minor_rows f.txt 1 1 | jq -c 'map(. + {cross_remit: true, security: true})')"
  with_f_txt_ownerless decide 1 fixed '{"reason":"reworded"}'
  [ "$status" -eq 3 ] || { echo "a fixed on an unchanged path recorded: $status $output"; return 1; }
  alf_set_line f.txt 1 "reworded"
  alf_commit "reword f.txt" || return 1
  with_f_txt_ownerless decide 1 fixed '{"reason":"reworded"}'
  [ "$status" -eq 0 ] || { echo "a security-class fixed on an unowned path was refused: $status $output"; return 1; }
  [ ! -e "$RUN_FOLDER/vetoes.json" ] || { cat "$RUN_FOLDER/vetoes.json"; return 1; }
  jq -e -s 'length == 1 and .[0].decision == "fixed"' "$RUN_FOLDER/recorded-residuals.jsonl" >/dev/null || return 1
  printf 'case: %s\n' 'a security-class cross-remit finding takes no fixed and no fix while the roster cannot be read' >&2
  stop_rounds "$(minor_rows f.txt 1 1 | jq -c 'map(. + {cross_remit: true, security: true})')"
  alf_set_line f.txt 1 "reworded"
  alf_commit "reword f.txt" || return 1
  with_roster_unreadable decide 1 fixed '{"reason":"reworded"}'
  [ "$status" -eq 3 ] || { echo "a security-class fixed under an unreadable roster recorded: $status $output"; return 1; }
  with_roster_unreadable decide 1 fix
  [ "$status" -eq 3 ] || { echo "a cross-remit fix under an unreadable roster recorded: $status $output"; return 1; }
  [ ! -e "$RUN_FOLDER/recorded-residuals.jsonl" ] && [ ! -e "$RUN_FOLDER/vetoes.json" ]
}

@test "needs-human: a key an earlier round accepted needs a new decision when the open round re-reports it security-class" {
  local escalated
  escalated="$(alf_entries f.txt 1 1 rule/x | jq -c 'map(. + {severity: "minor", security: true})')"
  stop_rounds "$(minor_rows f.txt 1 1)" "$escalated"
  jq -n -c --arg member "$MEMBER" '{schema: 1, round: 1, entries: [{member: $member, finding_class: "rule/x", path: "f.txt", line: 1,
    disposition: "accept-residual", reason: "deferred"}], enforcement_paths_allowed: []}' >"$RUN_FOLDER/dispositions-1.json"
  run_check_all
  red undecided "{\"round\":2,\"member\":\"$MEMBER\",\"finding_class\":\"rule/x\",\"path\":\"f.txt\",\"line\":1}"
}

@test "needs-human: a human's accept decides only its own round, so a later security-class re-report fails undecided and drops the accepted row" {
  local escalated
  escalated="$(alf_entries f.txt 1 1 rule/x | jq -c 'map(. + {severity: "minor", security: true})')"
  stop_rounds "$(minor_rows f.txt 1 1)"
  decide 1 accept '{"reason":"deferred to its own change"}' || return 1
  alf_set_line other.txt 2 "round 2"
  alf_commit "round 2" || return 1
  alf_round 2 "$MEMBER" "$escalated" || return 1
  run_check_all
  red undecided "{\"round\":2,\"member\":\"$MEMBER\",\"finding_class\":\"rule/x\",\"path\":\"f.txt\",\"line\":1}" || return 1
  run_sections
  [ "$status" -eq 0 ] && [ -z "$output" ] || { echo "pr-sections exited $status or still renders the escalated key: $output"; return 1; }
}

@test "needs-human: an open-round finding with an honored triage mark needs no decision" {
  local mark='[{"path":"lib/s.sh","line":4,"finding_class":"rule/t","severity":"minor","security":false,"triage":true,"triage_reason":"below the threshold"}]'
  MEMBER="$SHELL_MAINTAINER"
  stop_rounds "$(joined "$(minor_rows lib/s.sh 1 1)" "$mark")"
  run_check_all
  red undecided "{\"round\":1,\"member\":\"$MEMBER\",\"finding_class\":\"rule/x\",\"path\":\"lib/s.sh\",\"line\":1}" || return 1
  grep -qF -- '"finding_class":"rule/t"' <<<"$output" && { echo "triage-marked finding flagged: $output"; return 1; }
  true
}

# draft_stop <rows-json> [draft-flag]: two rounds reporting <rows>, round 1
# waiving f.txt:1, a veto on it from round 2, and round 2 disposing it fix
# with enforcement_draft set to [draft-flag] (default true): the
# enforcement-draft stop.
draft_stop() {
  local fix_entry
  stop_rounds "$1" "$1" || return 1
  write_dispositions 1 "[$(disposition_entry f.txt 1 rule/x waive-out-of-scope "below the threshold" triage-threshold)]"
  vetoes 2 rule/x f.txt 1
  fix_entry="$(disposition_entry f.txt 1 rule/x fix "drafted" | jq -c --argjson draft "${2:-true}" '. + {enforcement_draft: $draft}')"
  write_dispositions 2 "[$fix_entry]"
}

# discard_refused: the last run refused the discard and left the veto and the recorded residuals alone.
discard_refused() {
  [ "$status" -eq 3 ] || { echo "status $status: $output"; return 1; }
  [ "$(jq '.keys | length' "$RUN_FOLDER/vetoes.json")" -eq 1 ] || { cat "$RUN_FOLDER/vetoes.json"; return 1; }
  [ ! -e "$RUN_FOLDER/recorded-residuals.jsonl" ] || { cat "$RUN_FOLDER/recorded-residuals.jsonl"; return 1; }
}

@test "needs-human: a discard is allowed only on a vetoed enforcement-draft non-security non-Critical key, once (case table)" {
  printf 'case: %s\n' 'allowed: withdraws its veto and renders an accepted residual; a repeat is refused; the renderer mutant drops the row' >&2
  draft_stop "$(minor_rows f.txt 1 1)" || return 1
  decide 1 discard '{"reason":"the human discarded the drafted repair"}' || return 1
  [ "$status" -eq 0 ] || { echo "status $status: $output"; return 1; }
  [ "$(jq -c '.keys' "$RUN_FOLDER/vetoes.json")" = '[]' ] || { cat "$RUN_FOLDER/vetoes.json"; return 1; }
  [ "$(jq -r '.decision' "$RUN_FOLDER/recorded-residuals.jsonl")" = discard ] || { cat "$RUN_FOLDER/recorded-residuals.jsonl"; return 1; }
  run_sections
  grep -qF -- '## Accepted residuals (recorded, not fixed)' <<<"$output" || { echo "pr-sections: $output"; return 1; }
  grep -qF -- '- `f.txt:1` the human discarded the drafted repair.' <<<"$output" || { echo "pr-sections: $output"; return 1; }
  mutant_check_tree audit-pr-sections-lib.sh -e 's/select(\.decision == "discard" or (/select((/' || return 1
  run_sections
  grep -qF -- '- `f.txt:1` the human discarded the drafted repair.' <<<"$output" && { echo "the renderer mutant still rendered the row"; return 1; }
  SCRIPT="$SCRIPTS/audit-dispositions-check.sh"
  decide 1 discard || return 1
  [ "$status" -eq 3 ] || return 1
  printf 'case: %s\n' 'refused: no enforcement_draft fix entry, an unvetoed key, a Critical or a security-class key; each guard mutant lets the discard through' >&2
  draft_stop "$(minor_rows f.txt 1 1)" false || return 1
  decide 1 discard; discard_refused || return 1
  mutant_check_tree audit-recorded-decision-lib.sh -e 's/ and \.enforcement_draft == true//' || return 1
  decide 1 discard
  [ "$status" -eq 0 ] || { echo "the draft-entry mutant still refused: $output"; return 1; }
  SCRIPT="$SCRIPTS/audit-dispositions-check.sh"
  draft_stop "$(minor_rows f.txt 1 1)" || return 1
  printf '{"version":1,"keys":[]}\n' >"$RUN_FOLDER/vetoes.json"
  decide 1 discard
  [ "$status" -eq 3 ] || { echo "an unvetoed key was discarded: $output"; return 1; }
  mutant_check_tree audit-recorded-decision-lib.sh -e 's/any(\.keys\[\]?; \[\.member, \.finding_class, \.path, \.line\] == \$key)/true/' || return 1
  decide 1 discard
  [ "$status" -eq 0 ] || { echo "the veto-presence mutant still refused: $output"; return 1; }
  SCRIPT="$SCRIPTS/audit-dispositions-check.sh"
  draft_stop "$(minor_rows f.txt 1 1 | jq -c 'map(. + {severity: "critical"})')" || return 1
  decide 1 discard; discard_refused || return 1
  draft_stop "$(minor_rows f.txt 1 1 | jq -c 'map(. + {security: true})')" || return 1
  decide 1 discard; discard_refused || return 1
  mutant_check_tree audit-recorded-decision-lib.sh -e 's/ and all(\.\[\]; security_class | not)//' || return 1
  decide 1 discard
  [ "$status" -eq 0 ] || { echo "the security-class mutant still refused: $output"; return 1; }
}

@test "pr-sections: each residual renders its own failure mode and key; a fixed vetoed key leaves while the others stay, and residual-count matches the heading" {
  local findings shown withheld
  findings="$(jq -c 'map(if .line == 3 and .path == "f.txt" then . + {failure_mode: "the import cycle survives a reload"}
    elif .line == 6 and .path == "f.txt" then . + {failure_mode: "the suggestion text is stale"} else . end)' <<<"$FINDINGS_JSON")"
  alf_sidecar "$MEMBER" "$findings" 11
  accept_at 1
  write_dispositions 1 "$(fill "$FINDINGS_JSON" "[$(disposition_entry f.txt 3 c/imp accept-residual "generic"),$(disposition_entry f.txt 6 c/sug accept-residual "generic")]")"
  recorded_row holistic/unclassified a.test.ts 4 "leaks $(secret_token) here"
  run_sections
  green || return 1
  grep -qxF -- '- `f.txt:3` the import cycle survives a reload. <!-- gaia-debt-key: v1 class=c/imp path=f.txt line=3 -->' <<<"$output" || { echo "$output"; return 1; }
  grep -qxF -- '- `f.txt:6` the suggestion text is stale. <!-- gaia-debt-key: v1 class=c/sug path=f.txt line=6 -->' <<<"$output" || { echo "$output"; return 1; }
  run bash "$SCRIPT" waiver-table --root "$ALF_ROOT" --run-folder "$RUN_FOLDER" --rounds 1-1
  grep -F -- 'f.txt:3 c/imp' <<<"$output" | grep -qF -- '| the import cycle survives a reload |' || { echo "$output"; return 1; }
  vetoes 2 c/imp f.txt 3
  run_sections
  green || return 1
  grep -qF -- 'f.txt:3' <<<"$output" && { echo "$output"; return 1; }
  grep -qF -- '`f.txt:6` the suggestion text is stale.' <<<"$output" || { echo "$output"; return 1; }
  shown="$(awk '/^## Accepted residuals/ { reading = 1; next } /^## / { reading = 0 } reading && /^- `/' <<<"$output" | wc -l | tr -d ' ')"
  withheld="$(sed -n 's/^- \([0-9]*\) accepted residual(s) withheld.*/\1/p' <<<"$output")"
  [ "$shown" -eq 1 ] && [ "${withheld:-0}" -eq 1 ] || { echo "$output"; return 1; }
  run_residual_count
  green || return 1
  [ "$(jq -r '.total' <<<"$output")" -eq $((shown + withheld)) ] || { echo "$output vs $shown + $withheld"; return 1; }
  find "$RUN_FOLDER" -name 'filing-outcomes-*' | grep -q . && return 1
  grep -qF -- issue "$GH_CALLS" 2>/dev/null && { cat "$GH_CALLS"; return 1; }
  true
}

@test "residual-count: ask counts a stop round's rows and a filing-replay row, never a worthiness row, a human-accepted round or a closing latest round (mutant counting every accept goes red)" {
  local finding="$BATS_TEST_TMPDIR/finding.json"
  stop_base
  accept_all 3 "$(minor_rows f.txt 1 2)"
  jq -n -c '{member: "code-audit-frontend", finding_class: "c/replay", path: "g.txt", line: 2, failure_mode: "the filer refused it"}' >"$finding"
  bash "$SCRIPT" record-residual --root "$ALF_ROOT" --run-folder "$RUN_FOLDER" --finding "$finding"
  recorded_row holistic/unclassified a.test.ts 4 "a weak test"
  # No snapshot: the live evaluator answers for round 3.
  run_residual_count
  green || return 1
  [ "$output" = '{"total":4,"ask":3}' ] || { echo "$output"; return 1; }
  run_check 3 --snapshot-dir "$SNAPSHOT_DIRECTORY"
  green || return 1
  # From the snapshot, a later sidecar and HEAD change nothing.
  alf_sidecar "$MEMBER" "$(minor_rows f.txt 7 7 rule/later)" 31
  alf_set_line other.txt 9 "after the round"
  alf_commit "after the round"
  run_residual_count
  [ "$output" = '{"total":4,"ask":3}' ] || { echo "snapshot: $output"; return 1; }
  # Live again on round 3's own evidence, now human-accepted.
  rm -f "$SNAPSHOT_DIRECTORY/dispositions-3.checked.json"
  alf_sidecar "$MEMBER" "$(minor_rows f.txt 1 2)" 31
  review_base_all member-clearance
  [ "$(evaluator_field 3 '.default_stop')" = true ] || return 1
  accept_at 3
  run_residual_count
  [ "$output" = '{"total":4,"ask":1}' ] || { echo "human accepted: $output"; return 1; }
  mutant_check_tree audit-pr-sections-lib.sh -e 's/or (\.round as \$round | \$asking | any(\. == \$round))/or .round > 0/' || return 1
  run_residual_count
  [ "$output" = '{"total":4,"ask":3}' ] || { echo "mutant: $output"; return 1; }
  SCRIPT="$SCRIPTS/audit-dispositions-check.sh"
  alf_add_round "[\"$MEMBER\"]" true
  run_residual_count
  [ "$output" = '{"total":4,"ask":0}' ] || { echo "closing: $output"; return 1; }
}

@test "record-residual: a replayed row on a non-stop round is outside the refusal and still counts in ask" {
  local finding="$BATS_TEST_TMPDIR/finding.json"
  jq -n -c '{member: "code-audit-frontend", finding_class: "c/replay", path: "g.txt", line: 2, failure_mode: "the filer refused it"}' >"$finding"
  bash "$SCRIPT" record-residual --root "$ALF_ROOT" --run-folder "$RUN_FOLDER" --finding "$finding"
  write_dispositions 1 "$(fill "$FINDINGS_JSON" '[]')"
  run_check 1
  green || return 1
  run_residual_count
  [ "$output" = '{"total":1,"ask":1}' ] || { echo "$output"; return 1; }
}
