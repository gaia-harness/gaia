#!/usr/bin/env bats
#
# .gaia/scripts/update-gaia-report.sh against a fixture report. The fixture is a
# small baseline tree, latest tree, adopter tree, decision log and a merge
# report covering every status and every row of the option order table. Each
# report_case copies it into $BATS_TEST_TMPDIR and breaks one thing, so every refusal
# is driven into its failing state.
#
# Assertion style follows .claude/rules/bats-assertions.md; run through
# .gaia/scripts/bats5.sh.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SCRIPT="$REPO_ROOT/.gaia/scripts/update-gaia-report.sh"
  FIXTURES="$BATS_TEST_DIRNAME/fixtures/update-gaia-report"
  WORK="$BATS_TEST_TMPDIR/work"
  copy_fixture
}

# Copies the fixture into a fresh $WORK and sets the paths into it.
copy_fixture() {
  rm -rf "$WORK"
  mkdir -p "$WORK"
  cp -R "$FIXTURES/baseline" "$FIXTURES/latest" "$FIXTURES/tree" "$FIXTURES/deferred-baseline" "$FIXTURES/run" "$WORK/"
  cp "$FIXTURES/decisions.json" "$WORK/decisions.json"
  # The fixture holds the two manifests under other names: a release-generated
  # manifest path is off limits for feature edits, and this is scratch data.
  mkdir -p "$WORK/baseline/.gaia" "$WORK/latest/.gaia"
  cp "$FIXTURES/baseline-manifest.json" "$WORK/baseline/.gaia/manifest.json"
  cp "$FIXTURES/latest-manifest.json" "$WORK/latest/.gaia/manifest.json"
  BASELINE="$WORK/baseline"
  LATEST="$WORK/latest"
  TREE="$WORK/tree"
  RUN="$WORK/run"
  REPORT="$RUN/report.json"
  DECISIONS="$WORK/decisions.json"
}

helper() {
  bash "$SCRIPT" "$@"
}

# Prints a table case's label so a failing case names itself in the bats output.
start_case() {
  printf 'case: %s\n' "$1"
}

# Starts a case on a fresh copy of the fixture, since cases break one thing in it.
report_case() {
  start_case "$1"
  copy_fixture
}

run_validate() {
  run bash "$SCRIPT" validate --report "$REPORT" --run-dir "$RUN" --baseline-dir "$BASELINE" --latest-dir "$LATEST" --decisions "$DECISIONS" "$@"
}

run_both_changed() {
  run bash "$SCRIPT" both-changed --tree "$TREE" --baseline-dir "$BASELINE" --latest-dir "$LATEST" --decisions "$DECISIONS" "$@"
}

# Rewrites the scratch report through a jq filter.
edit_report() {
  jq "$1" "$REPORT" >"$REPORT.edited"
  mv "$REPORT.edited" "$REPORT"
}

assert_invalid() {
  [ "$status" -eq 1 ]
  grep -qF -- "REPORT_INVALID $1" <<<"$output"
}

# Asserts one item's options are exactly $3 in order, with the first recommended.
assert_option_row() {
  local entry_path="$1" kind="$2" expected_order="$3" actual recommended first
  actual="$(jq -r --arg p "$entry_path" --arg k "$kind" '.files[] | select(.path == $p) | .items[] | select(.kind == $k) | [.options[].id] | join(",")' "$REPORT")"
  recommended="$(jq -r --arg p "$entry_path" --arg k "$kind" '.files[] | select(.path == $p) | .items[] | select(.kind == $k) | .recommended' "$REPORT")"
  first="${expected_order%%,*}"
  [ "$actual" = "$expected_order" ]
  [ "$recommended" = "$first" ]
}

# ---------- expected set ----------

@test "expected set: sorted, counts a deferred removal once, omits kept paths, absent log means none" {
  report_case 'expect-count prints the size of the expected set, derived independently'
  run helper expect-count --baseline-dir "$BASELINE" --latest-dir "$LATEST" --decisions "$DECISIONS"
  [ "$status" -eq 0 ]
  independent="$(jq -s '[.[0].files, .[1].files] | map(keys) | add | unique | length' "$BASELINE/.gaia/manifest.json" "$LATEST/.gaia/manifest.json")"
  # Plus the deferred path that is in neither manifest.
  [ "$output" -eq $((independent + 1)) ]
  [ "$output" -eq 27 ]

  report_case 'expected-paths is sorted, counts a deferred upstream removal once and omits a kept path outside the manifests'
  run helper expected-paths --baseline-dir "$BASELINE" --latest-dir "$LATEST" --decisions "$DECISIONS"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" >"$BATS_TEST_TMPDIR/paths.txt"
  LC_ALL=C sort -c "$BATS_TEST_TMPDIR/paths.txt"
  [ "$(wc -l <"$BATS_TEST_TMPDIR/paths.txt" | tr -d ' ')" -eq 27 ]
  grep -qxF 'gone.md' "$BATS_TEST_TMPDIR/paths.txt"
  grep -qxF 'add.md' "$BATS_TEST_TMPDIR/paths.txt"
  grep -qxF 'removed.md' "$BATS_TEST_TMPDIR/paths.txt"
  grep -qxF 'deferred.md' "$BATS_TEST_TMPDIR/paths.txt"
  grep -qxF 'kept-out.md' "$BATS_TEST_TMPDIR/paths.txt" && return 1
  [ "$(grep -cxF 'deferred.md' "$BATS_TEST_TMPDIR/paths.txt")" -eq 1 ]

  report_case 'an absent decision log means no deferred paths'
  run helper expect-count --baseline-dir "$BASELINE" --latest-dir "$LATEST" --decisions "$WORK/no-such-decisions.json"
  [ "$status" -eq 0 ]
  [ "$output" -eq 26 ]
}

@test "a manifest that does not parse exits 1" {
  printf 'not json\n' >"$BASELINE/.gaia/manifest.json"
  run helper expect-count --baseline-dir "$BASELINE" --latest-dir "$LATEST"
  [ "$status" -eq 1 ]
}

# ---------- validate ----------

@test "validate accepts the fixture report and rejects each shape violation, under --final too" {
  report_case 'validate accepts the fixture report'
  run_validate
  [ "$status" -eq 0 ]
  [ "$output" = "REPORT_OK 27" ]

  report_case 'validate rejects schemaVersion 2'
  edit_report '.schemaVersion = 2'
  run_validate
  assert_invalid 'schemaVersion must be 1'

  report_case 'validate rejects a report that is not JSON'
  printf 'nope\n' >"$REPORT"
  run_validate
  assert_invalid 'report is not valid JSON'

  report_case 'validate rejects a missing path'
  edit_report '.files |= map(select(.path != "skip.md"))'
  run_validate
  assert_invalid 'missing path skip.md'

  report_case 'validate rejects an extra path'
  edit_report '.files += [{"path": "extra.md", "class": null, "status": "skip"}]'
  run_validate
  assert_invalid 'unexpected path extra.md'

  report_case 'validate rejects a duplicate path'
  edit_report '.files += [.files[0]]'
  run_validate
  assert_invalid 'duplicate path skip.md'

  report_case 'validate rejects an unknown status'
  edit_report '(.files[] | select(.path == "skip.md")).status = "bogus"'
  run_validate
  assert_invalid 'skip.md: unknown status bogus'

  report_case 'validate rejects an open entry with no items'
  edit_report '(.files[] | select(.path == "oc-text-conflict.md")).items = []'
  run_validate
  assert_invalid 'oc-text-conflict.md: open entry has no items'

  report_case 'validate rejects a recommended that is not options[0]'
  edit_report '(.files[] | select(.path == "oc-text-conflict.md")).items[0].recommended = "keep"'
  run_validate
  assert_invalid 'oc-text-conflict.md: item oc-text-conflict.md recommended keep is not options[0] combine'

  report_case 'validate rejects options where defer is not last'
  edit_report '(.files[] | select(.path == "oc-text-conflict.md")).items[0].options |= (.[0:2] + [.[3]] + [.[2]])'
  run_validate
  assert_invalid 'oc-text-conflict.md: item oc-text-conflict.md last option is not defer'

  report_case 'validate rejects a required candidate field that is absent'
  edit_report '(.files[] | select(.path == "oc-text-conflict.md")).items[0].options[0] |= del(.candidate)'
  run_validate
  assert_invalid 'oc-text-conflict.md: item oc-text-conflict.md option combine needs a candidate'

  report_case 'validate rejects a required candidate file that does not exist'
  rm "$RUN/candidates/oc-text-conflict.md.combine"
  run_validate
  assert_invalid 'oc-text-conflict.md: candidate candidates/oc-text-conflict.md.combine does not exist'

  report_case 'validate rejects an autoCandidate on an open entry'
  edit_report '(.files[] | select(.path == "oc-text-conflict.md")).autoCandidate = "candidates/autoc.md.auto"'
  run_validate
  assert_invalid 'oc-text-conflict.md: autoCandidate on a status other than auto-merged'

  report_case 'validate rejects pending-judgment under --final and accepts it without'
  run_validate
  [ "$status" -eq 0 ]
  run_validate --final
  assert_invalid 'pending.md: pending-judgment is not allowed in a final report'

  report_case 'validate reports every violation, one line each'
  edit_report '.schemaVersion = 2 | .files |= map(select(.path != "skip.md"))'
  run_validate
  [ "$status" -eq 1 ]
  [ "$(grep -c '^REPORT_INVALID ' <<<"$output")" -eq 2 ]
}

# bats test_tags=protected
@test "validate rejects a candidate or autoCandidate that escapes the run directory" {
  report_case 'validate rejects a candidate with a .. segment'
  edit_report '(.files[] | select(.path == "oc-text-conflict.md")).items[0].options[0].candidate = "candidates/../../outside.txt"'
  run_validate
  assert_invalid 'oc-text-conflict.md: candidate candidates/../../outside.txt has a .. segment'

  report_case 'validate rejects an absolute candidate'
  edit_report '(.files[] | select(.path == "oc-text-conflict.md")).items[0].options[0].candidate = "/etc/hosts"'
  run_validate
  assert_invalid 'oc-text-conflict.md: candidate /etc/hosts is an absolute path'

  report_case 'validate rejects a candidate symlink that points outside the run directory'
  printf 'outside\n' >"$BATS_TEST_TMPDIR/outside.txt"
  rm "$RUN/candidates/oc-text-conflict.md.combine"
  ln -s "$BATS_TEST_TMPDIR/outside.txt" "$RUN/candidates/oc-text-conflict.md.combine"
  run_validate
  assert_invalid 'oc-text-conflict.md: candidate candidates/oc-text-conflict.md.combine resolves outside the run directory'

  report_case 'validate rejects an autoCandidate outside the run directory'
  edit_report '(.files[] | select(.path == "autoc.md")).autoCandidate = "../escape"'
  run_validate
  assert_invalid 'autoc.md: autoCandidate ../escape has a .. segment'
}

# bats test_tags=protected
@test "validate rejects conflict markers and accepts a setext heading" {
  report_case 'validate rejects a combine candidate holding a conflict marker line'
  printf 'kept\n<<<<<<< ours\nmine\n' >"$RUN/candidates/oc-text-conflict.md.combine"
  run_validate
  assert_invalid 'oc-text-conflict.md: candidate candidates/oc-text-conflict.md.combine holds a conflict marker'

  report_case 'validate rejects a closing conflict marker line too'
  printf 'kept\n>>>>>>> theirs\n' >"$RUN/candidates/oc-text-conflict.md.gaia"
  run_validate
  assert_invalid 'oc-text-conflict.md: candidate candidates/oc-text-conflict.md.gaia holds a conflict marker'

  report_case 'validate accepts a candidate with a bare equals line, a Markdown setext heading'
  printf 'Title\n=======\nbody\n' >"$RUN/candidates/oc-text-conflict.md.combine"
  run_validate
  [ "$status" -eq 0 ]
}

# ---------- option order table ----------

@test "option order per conflict kind" {
  start_case 'text-conflict with a meaningful combine'
  assert_option_row oc-text-conflict.md text-conflict combine,keep,gaia,defer

  start_case 'text-conflict without a meaningful combine falls back to the class'
  assert_option_row oc-fallback.md text-conflict keep,gaia,defer

  start_case 'same-concern-gaia'
  assert_option_row oc-same-gaia.md same-concern-gaia combine,keep,gaia,defer

  start_case 'same-concern-adopter carries a suggestion'
  assert_option_row oc-same-adopter.md same-concern-adopter combine,keep,gaia,defer
  [ -n "$(jq -r '.files[] | select(.path == "oc-same-adopter.md") | .items[0].suggestion // empty' "$REPORT")" ]

  start_case 'contradictory puts the recommendation first, then the rest in order'
  assert_option_row oc-contradictory.md contradictory gaia,combine,keep,defer

  start_case 'binary on an owned file falls back to gaia'
  assert_option_row oc-binary.md binary gaia,keep,defer

  start_case 'merge-error on a shared file falls back to keep'
  assert_option_row oc-merge-error.md merge-error keep,gaia,defer

  start_case 'absent-baseline'
  assert_option_row oc-absent-baseline.md absent-baseline keep,gaia,defer

  start_case 'version-pin with a strictly higher side'
  assert_option_row package.json version-pin higher,keep,gaia,defer

  start_case 'version-pin without a higher side'
  assert_option_row apps/web/package.json version-pin keep,gaia,defer

  start_case 'field-conflict'
  assert_option_row package.json field-conflict keep,gaia,defer

  start_case 'removal nothing references'
  assert_option_row rm-unref.md removal remove,keep,defer

  start_case 'removal a tracked file references'
  assert_option_row rm-ref.md removal keep,remove,defer
}

# ---------- both-changed and chunk ----------

@test "both-changed lists the both-changed text files and honors extras, registry and design paths" {
  report_case 'both-changed lists exactly the both-changed text files, using the deferred baseline'
  run_both_changed --extra "v2.0.0=$WORK/deferred-baseline"
  [ "$status" -eq 0 ]
  expected="$(printf '%s\n' auto.md autoc.md merge.md oc-text-conflict.md pending.md)"
  [ "$output" = "$expected" ]

  report_case 'both-changed reads B from the extra tree for a deferred path'
  # The deferred path differs from the current baseline copy but not from the
  # deferred baseline copy.
  if cmp -s "$TREE/deferred.md" "$BASELINE/deferred.md"; then return 1; fi
  cmp -s "$TREE/deferred.md" "$WORK/deferred-baseline/deferred.md"
  run_both_changed
  [ "$status" -eq 0 ]
  grep -qxF 'deferred.md' <<<"$output"
  run_both_changed --extra "v2.0.0=$WORK/deferred-baseline"
  [ "$status" -eq 0 ]
  grep -qxF 'deferred.md' <<<"$output" && return 1

  report_case 'both-changed excludes field-aware files that differ on every side'
  for field_aware in package.json apps/web/package.json pnpm-workspace.yaml .gaia/audit-ci.yml; do
    if cmp -s "$TREE/$field_aware" "$BASELINE/$field_aware"; then return 1; fi
    if cmp -s "$BASELINE/$field_aware" "$LATEST/$field_aware"; then return 1; fi
  done
  run_both_changed --extra "v2.0.0=$WORK/deferred-baseline"
  [ "$status" -eq 0 ]
  for field_aware in package.json apps/web/package.json pnpm-workspace.yaml .gaia/audit-ci.yml; do
    grep -qxF "$field_aware" <<<"$output" && return 1
  done

  report_case 'both-changed follows the package registry'
  mkdir -p "$TREE/.gaia" "$TREE/web" "$BASELINE/web" "$LATEST/web"
  printf '[{"name":"web","path":"web"}]\n' >"$TREE/.gaia/packages.json"
  printf '{"m":"adopter"}\n' >"$TREE/web/package.json"
  printf '{"m":"base"}\n' >"$BASELINE/web/package.json"
  printf '{"m":"latest"}\n' >"$LATEST/web/package.json"
  for side in baseline latest; do
    jq '.files["web/package.json"] = "shared"' "$WORK/$side/.gaia/manifest.json" >"$WORK/$side.json"
    mv "$WORK/$side.json" "$WORK/$side/.gaia/manifest.json"
  done
  run_both_changed --extra "v2.0.0=$WORK/deferred-baseline"
  [ "$status" -eq 0 ]
  grep -qxF 'web/package.json' <<<"$output" && return 1
  # frontend is no longer registered, so its package.json is an ordinary file.
  grep -qxF 'apps/web/package.json' <<<"$output"

  report_case 'both-changed excludes the design-system paths only when established'
  for design_path in 'wiki/concepts/Design System.md' apps/web/.claude/rules/design-baseline.md; do
    if cmp -s "$TREE/$design_path" "$BASELINE/$design_path"; then return 1; fi
    if cmp -s "$BASELINE/$design_path" "$LATEST/$design_path"; then return 1; fi
  done
  run_both_changed --extra "v2.0.0=$WORK/deferred-baseline"
  grep -qxF 'wiki/concepts/Design System.md' <<<"$output" && return 1
  grep -qxF 'apps/web/.claude/rules/design-baseline.md' <<<"$output" && return 1
  printf -- '---\nestablished: false\n---\nadopter\n' >"$TREE/wiki/concepts/Design System.md"
  run_both_changed --extra "v2.0.0=$WORK/deferred-baseline"
  [ "$status" -eq 0 ]
  grep -qxF 'wiki/concepts/Design System.md' <<<"$output"
  grep -qxF 'apps/web/.claude/rules/design-baseline.md' <<<"$output"
}

@test "chunk splits the both-changed set and refuses a bad size" {
  report_case 'chunk --size 2 writes three chunks, both-changed.txt and clears a stale chunk'
  printf 'stale.md\n' >"$RUN/chunk-4.txt"
  run helper chunk --tree "$TREE" --baseline-dir "$BASELINE" --latest-dir "$LATEST" --decisions "$DECISIONS" \
    --extra "v2.0.0=$WORK/deferred-baseline" --run-dir "$RUN" --size 2
  [ "$status" -eq 0 ]
  [ "$output" = "CHUNKS 3 5" ]
  [ "$(cat "$RUN/chunk-1.txt")" = "$(printf '%s\n' auto.md autoc.md)" ]
  [ "$(cat "$RUN/chunk-2.txt")" = "$(printf '%s\n' merge.md oc-text-conflict.md)" ]
  [ "$(cat "$RUN/chunk-3.txt")" = "pending.md" ]
  [ "$(wc -l <"$RUN/both-changed.txt" | tr -d ' ')" -eq 5 ]
  [ -e "$RUN/chunk-4.txt" ] && return 1

  report_case 'chunk with nothing both-changed prints CHUNKS 0 0 and writes no chunk file'
  printf 'stale.md\n' >"$RUN/chunk-1.txt"
  run helper chunk --tree "$BASELINE" --baseline-dir "$BASELINE" --latest-dir "$LATEST" --decisions "$DECISIONS" \
    --run-dir "$RUN" --size 2
  [ "$status" -eq 0 ]
  [ "$output" = "CHUNKS 0 0" ]
  [ -e "$RUN/chunk-1.txt" ] && return 1

  report_case 'chunk refuses a size that is not a positive integer'
  run helper chunk --tree "$TREE" --baseline-dir "$BASELINE" --latest-dir "$LATEST" --run-dir "$RUN" --size 0
  [ "$status" -eq 2 ]
}

# ---------- merge-judgments ----------

@test "merge-judgments replaces judged entries and refuses an unknown path or non-array" {
  report_case 'merge-judgments replaces the judged entries and keeps the rest'
  printf '[{"path":"pending.md","class":"shared","baselineTag":"v2.0.4","status":"merge"}]\n' >"$WORK/judgment-2.json"
  before="$(jq -c '.files | map(select(.path != "pending.md"))' "$REPORT")"
  run helper merge-judgments --report "$REPORT" --judgment "$WORK/judgment-2.json"
  [ "$status" -eq 0 ]
  [ "$output" = "MERGED 1" ]
  [ "$(jq -r '.files[] | select(.path == "pending.md") | .status' "$REPORT")" = "merge" ]
  [ "$(jq -c '.files | map(select(.path != "pending.md"))' "$REPORT")" = "$before" ]
  [ "$(jq '.files | length' "$REPORT")" -eq 27 ]

  report_case 'merge-judgments takes several judgment files'
  printf '[{"path":"pending.md","class":"shared","baselineTag":"v2.0.4","status":"merge"}]\n' >"$WORK/judgment-2.json"
  printf '[{"path":"auto.md","class":"shared","baselineTag":"v2.0.4","status":"skip"}]\n' >"$WORK/judgment-3.json"
  run helper merge-judgments --report "$REPORT" --judgment "$WORK/judgment-2.json" "$WORK/judgment-3.json"
  [ "$status" -eq 0 ]
  [ "$output" = "MERGED 2" ]
  [ "$(jq -r '.files[] | select(.path == "auto.md") | .status' "$REPORT")" = "skip" ]

  report_case 'merge-judgments exits 1 and leaves the report unchanged for a path absent from it'
  printf '[{"path":"pending.md","status":"merge"},{"path":"nope.md","status":"merge"}]\n' >"$WORK/judgment-2.json"
  cp "$REPORT" "$WORK/report.before"
  run helper merge-judgments --report "$REPORT" --judgment "$WORK/judgment-2.json"
  [ "$status" -eq 1 ]
  cmp -s "$REPORT" "$WORK/report.before"

  report_case 'merge-judgments exits 1 for a judgment that is not an array'
  printf '{"path":"pending.md"}\n' >"$WORK/judgment-2.json"
  cp "$REPORT" "$WORK/report.before"
  run helper merge-judgments --report "$REPORT" --judgment "$WORK/judgment-2.json"
  [ "$status" -eq 1 ]
  cmp -s "$REPORT" "$WORK/report.before"
}

# ---------- apply-auto ----------

# bats test_tags=protected
@test "apply-auto copies only contained marker-free candidates and is all-or-nothing" {
  report_case 'apply-auto copies the auto candidate over its path'
  run helper apply-auto --report "$REPORT" --run-dir "$RUN" --tree "$TREE"
  [ "$status" -eq 0 ]
  [ "$output" = "APPLIED_AUTO 1" ]
  cmp -s "$RUN/candidates/autoc.md.auto" "$TREE/autoc.md"

  report_case 'apply-auto copies nothing and exits 1 when an autoCandidate escapes the run directory'
  edit_report '(.files[] | select(.path == "autoc.md")).autoCandidate = "../escape"'
  printf 'escaped\n' >"$WORK/escape"
  cp -R "$TREE" "$WORK/tree.before"
  run helper apply-auto --report "$REPORT" --run-dir "$RUN" --tree "$TREE"
  [ "$status" -eq 1 ]
  diff -r "$WORK/tree.before" "$TREE"

  report_case 'apply-auto copies nothing when one of two autoCandidates fails containment'
  edit_report '(.files[] | select(.path == "auto.md")) |= (.autoCandidate = "candidates/auto.md.auto")'
  printf 'good\n' >"$RUN/candidates/auto.md.auto"
  edit_report '(.files[] | select(.path == "autoc.md")).autoCandidate = "/etc/hosts"'
  cp -R "$TREE" "$WORK/tree.before"
  run helper apply-auto --report "$REPORT" --run-dir "$RUN" --tree "$TREE"
  [ "$status" -eq 1 ]
  diff -r "$WORK/tree.before" "$TREE"

  report_case 'apply-auto refuses a candidate holding a conflict marker'
  printf '<<<<<<< ours\n' >"$RUN/candidates/autoc.md.auto"
  cp -R "$TREE" "$WORK/tree.before"
  run helper apply-auto --report "$REPORT" --run-dir "$RUN" --tree "$TREE"
  [ "$status" -eq 1 ]
  diff -r "$WORK/tree.before" "$TREE"
}

# ---------- references ----------

make_reference_repo() {
  REFERENCE_REPO="$BATS_TEST_TMPDIR/reference-repo"
  rm -rf "$REFERENCE_REPO"
  mkdir -p "$REFERENCE_REPO/docs"
  git -C "$REFERENCE_REPO" init -q
  printf 'self mention: docs/old-tool.md\n' >"$REFERENCE_REPO/docs/old-tool.md"
  printf 'unrelated\n' >"$REFERENCE_REPO/other.md"
}

@test "references reports REFERENCED or UNREFERENCED and fails outside git" {
  report_case 'references prints REFERENCED and the first tracked file naming the path'
  make_reference_repo
  printf 'see docs/old-tool.md for details\n' >"$REFERENCE_REPO/readme.md"
  git -C "$REFERENCE_REPO" add -A
  run helper references --tree "$REFERENCE_REPO" --path docs/old-tool.md
  [ "$status" -eq 0 ]
  [ "$output" = "REFERENCED readme.md" ]

  report_case 'references finds a mention of the basename alone'
  make_reference_repo
  printf 'run old-tool.md first\n' >"$REFERENCE_REPO/readme.md"
  git -C "$REFERENCE_REPO" add -A
  run helper references --tree "$REFERENCE_REPO" --path docs/old-tool.md
  [ "$output" = "REFERENCED readme.md" ]

  report_case 'references prints UNREFERENCED when only the file itself and an untracked file name it'
  make_reference_repo
  git -C "$REFERENCE_REPO" add docs/old-tool.md other.md
  printf 'docs/old-tool.md\n' >"$REFERENCE_REPO/untracked.md"
  run helper references --tree "$REFERENCE_REPO" --path docs/old-tool.md
  [ "$status" -eq 0 ]
  [ "$output" = "UNREFERENCED" ]

  report_case 'references exits 1 outside a git repository instead of answering UNREFERENCED'
  mkdir -p "$BATS_TEST_TMPDIR/not-a-repo"
  run env GIT_CEILING_DIRECTORIES="$BATS_TEST_TMPDIR" bash "$SCRIPT" references --tree "$BATS_TEST_TMPDIR/not-a-repo" --path docs/old-tool.md
  [ "$status" -eq 1 ]
}

# ---------- prepare ----------

# bats test_tags=protected
@test "prepare empties a valid run directory and refuses any other path" {
  report_case 'prepare creates candidates and instructions and empties a populated run directory'
  prepared="$BATS_TEST_TMPDIR/project/.gaia/local/cache/shared/update-gaia/run"
  mkdir -p "$prepared/candidates/sub"
  printf 'old\n' >"$prepared/report.json"
  printf 'old\n' >"$prepared/candidates/sub/stale"
  run helper prepare --run-dir "$prepared"
  [ "$status" -eq 0 ]
  [ "$output" = "PREPARED $prepared" ]
  [ -d "$prepared/candidates" ]
  [ -d "$prepared/instructions" ]
  [ -e "$prepared/report.json" ] && return 1
  [ -e "$prepared/candidates/sub" ] && return 1

  report_case 'prepare refuses a path without the run directory suffix and deletes nothing'
  other="$BATS_TEST_TMPDIR/other"
  mkdir -p "$other"
  printf 'keep\n' >"$other/precious"
  run helper prepare --run-dir "$other"
  [ "$status" -eq 2 ]
  [ -f "$other/precious" ]

  report_case 'prepare refuses a suffix match that climbs with .. and a relative path'
  victim="$BATS_TEST_TMPDIR/victim"
  mkdir -p "$victim/.gaia/local/cache/shared/update-gaia/run"
  printf 'keep\n' >"$victim/.gaia/local/cache/shared/update-gaia/run/precious"
  run helper prepare --run-dir "$BATS_TEST_TMPDIR/a/../victim/.gaia/local/cache/shared/update-gaia/run"
  [ "$status" -eq 2 ]
  [ -f "$victim/.gaia/local/cache/shared/update-gaia/run/precious" ]
  run helper prepare --run-dir ".gaia/local/cache/shared/update-gaia/run"
  [ "$status" -eq 2 ]
}
