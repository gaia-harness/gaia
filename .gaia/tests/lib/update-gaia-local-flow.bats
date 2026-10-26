#!/usr/bin/env bats
# The /update-gaia local-bundle flow as the skill writes it: SKILL.md routes a
# local run (`--local <tarball>`) and a release run after a local sync (a
# committed .gaia/VERSION-dev) into references/local-bundle.md at each step,
# and that reference keeps the merge on the release path (conflict-flow.md),
# labels the source a local, unverified bundle, classifies with the build
# marker, keeps the dev baseline through verify and prune, skips the update
# ping and the blend record, and writes .gaia/VERSION-dev last (or removes it
# last). The scripts these calls name are driven by their own suites; this
# suite pins the prose and the calls. Every pin has a red twin: a fixture copy
# missing or reordering the required content, or carrying the forbidden one.
#
# Assertion style per .claude/rules/bats-assertions.md: no bare mid-test
# [[ ... ]]; POSIX [ ] and grep; `&& return 1` for a non-final absence.
#
# Maintainer-only. `.gaia/tests` is wholesale release-excluded.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
  SKILL_DIR="$REPO_ROOT/.claude/skills/update-gaia"
  SKILL="$SKILL_DIR/SKILL.md"
  LOCAL_REF="$SKILL_DIR/references/local-bundle.md"
  CONFLICT_FLOW="$SKILL_DIR/references/conflict-flow.md"
  MERGE_EXECUTION="$SKILL_DIR/references/merge-execution.md"
  CLAIM_REF="$SKILL_DIR/references/claim-flow.md"
  PULL_REF="$SKILL_DIR/references/pull-mode.md"
  THIS_SUITE="$REPO_ROOT/.gaia/tests/lib/update-gaia-local-flow.bats"
  COPY="$BATS_TEST_TMPDIR/copy.md"
}

H_LABEL='## Trust label at invocation'
H_SOURCE='## The source step'
H_STEP_3_LOCAL='## Step 3 on a local run'
H_3C='## Step 3c with a local build'
H_4_LOCAL='## Step 4 on a local run'
H_4_RECORD='## Step 4 on a release run after a local sync'
H_4B='## Step 4b with a local build'
H_9D_LOCAL='## Step 9d on a local run'
H_9D_RECORD='## Step 9d on a release run after a local sync'
H_REVIEW='## Review point with a local build'
H_11='## Step 11 with a local build'

LABEL='local, unverified bundle'
NOT_RUN='not run, follow it by hand to test it'
MANIFEST_COPY='GAIA_MANIFEST_WRITE=release cp <LATEST_DIR>/.gaia/manifest.json .gaia/manifest.json'
CORE_WRITE='echo <LOCAL_CORE> > .gaia/VERSION'
BUILD_WRITE='echo <LOCAL_BUILD> > .gaia/VERSION-dev'
RECORD_REMOVE='rm .gaia/VERSION-dev'
CLASSIFY_MODE_2='bash .gaia/scripts/update-gaia-branch-state.sh classify --tag <LOCAL_TAG> --latest <LOCAL_CORE> --build <LOCAL_BUILD>'
CLASSIFY_MODE_1='bash .gaia/scripts/update-gaia-branch-state.sh classify --tag <LOCAL_TAG> --latest <LOCAL_CORE> --branch <current branch> --build <LOCAL_BUILD>'
SOURCE_RESUME='bash .gaia/scripts/update-gaia-local.sh source --tarball <tarball path> --resume'
PR_TITLE='chore(gaia): update to <LOCAL_TAG>'
PR_BODY_LINE='Syncs a local, unverified GAIA build <LOCAL_TAG> (commit <LOCAL_COMMIT>) into the project.'
SENTINEL_LINE='- **adopter-owned (implicit)**'

# The lines of the section headed `$2` in file `$1`, up to the next heading of
# level two or three.
section_of() {
  awk -v heading="$2" '
    index($0, heading) == 1 { inside = 1; print; next }
    inside && /^##+ / { exit }
    inside { print }
  ' "$1"
}

# Writes the section headed `$2` in file `$1` to a scratch file and prints its
# path; fails when the section is empty.
section_file() {
  local out
  out="$BATS_TEST_TMPDIR/section-$RANDOM.md"
  section_of "$1" "$2" > "$out"
  [ -s "$out" ] || { echo "no section: $2" >&2; return 1; }
  printf '%s\n' "$out"
}

# The first line number in file `$1` holding fixed string `$2`; empty if none.
first_line() {
  grep -nF -- "$2" "$1" | head -n 1 | cut -d: -f1
}

# 0 when the fixed strings `$2`, `$3`, ... first appear in file `$1` in that
# order, each present.
in_order() {
  local file="$1" previous=0 needle line
  shift
  for needle in "$@"; do
    line="$(first_line "$file" "$needle")"
    [ -n "$line" ] || { echo "missing: $needle" >&2; return 1; }
    [ "$line" -gt "$previous" ] || { echo "out of order: $needle" >&2; return 1; }
    previous="$line"
  done
}

# Writes file `$1` to $COPY with every line holding fixed string `$2` dropped,
# and fails when nothing was dropped.
drop_lines() {
  grep -vF -- "$2" "$1" > "$COPY" || true
  [ "$(wc -l < "$COPY")" -lt "$(wc -l < "$1")" ]
}

# Writes file `$1` to $COPY with fixed string `$2` replaced by `$3` on every
# line, and fails when nothing changed.
replace_text() {
  awk -v from="$2" -v to="$3" '
    {
      line = $0; out = ""
      while ((at = index(line, from)) > 0) { out = out substr(line, 1, at - 1) to; line = substr(line, at + length(from)) }
      print out line
    }
  ' "$1" > "$COPY"
  cmp -s "$1" "$COPY" && return 1
  return 0
}

# Writes file `$1` to $COPY with line `$3` inserted after the first line that
# starts with `$2`.
insert_after() {
  awk -v anchor="$2" -v added="$3" '
    { print }
    !done && index($0, anchor) == 1 { print added; done = 1 }
  ' "$1" > "$COPY"
  grep -qxF -- "$3" "$COPY"
}

# Writes file `$1` to $COPY with the lines exactly `$2` and `$3` swapped.
swap_lines() {
  awk -v first="$2" -v second="$3" '
    $0 == first { print second; next }
    $0 == second { print first; next }
    { print }
  ' "$1" > "$COPY"
  cmp -s "$1" "$COPY" && return 1
  return 0
}

# Prints each line of a fenced bash block in file `$1` that a worktree session
# refuses: a command substitution, a backtick, a heredoc, or a shell variable;
# and each block that holds more than one command line.
fence_violations() {
  awk '
    !inside && /^```bash$/ { inside = 1; count = 0; next }
    inside && /^```$/ { inside = 0; if (count != 1) print NR ": block of " count " lines"; next }
    inside {
      if ($0 != "") count++
      if (index($0, "$(") || index($0, "`") || index($0, "<<") || $0 ~ /\$[A-Za-z_{]/) print NR ": " $0
    }
  ' "$1"
}

# The fenced block lines of file `$1`, in order.
fenced_lines() {
  awk '
    !inside && /^```/ { inside = 1; print; next }
    inside && /^```$/ { inside = 0; print; next }
    inside { print }
  ' "$1"
}

# --- The merge path ---------------------------------------------------------------

# 0 when reference copy `$1` routes the merge to conflict-flow.md and carries no
# merge procedure of its own.
same_merge_path_holds() {
  grep -qF 'conflict-flow.md' "$1" || return 1
  grep -qE 'git merge-file|merge-package|update-gaia-report\.sh' "$1" && return 1
  return 0
}

@test "the local reference routes the merge to the conflict flow and holds no merge of its own" {
  same_merge_path_holds "$LOCAL_REF"
  insert_after "$LOCAL_REF" "$H_SOURCE" 'git merge-file -p a b c'
  same_merge_path_holds "$COPY" && return 1
  replace_text "$LOCAL_REF" 'conflict-flow.md' 'elsewhere.md'
  same_merge_path_holds "$COPY" && return 1
  true
}

# --- The trust label ----------------------------------------------------------------

# 0 when reference copy `$1` names the source a local, unverified bundle at
# invocation, in the Proceed question and in the review summary.
label_holds() {
  section_of "$1" "$H_LABEL" | grep -qF -- "$LABEL" || return 1
  section_of "$1" "$H_4_LOCAL" | grep -F '**Question**' | grep -qF -- "$LABEL" || return 1
  section_of "$1" "$H_REVIEW" | grep -qF -- "$LABEL" || return 1
  return 0
}

@test "the label: invocation, the Proceed question and the review summary name a local, unverified bundle" {
  label_holds "$LOCAL_REF"
  local line
  line="$(section_of "$LOCAL_REF" "$H_4_LOCAL" | grep -F '**Question**')"
  [ -n "$line" ]
  replace_text "$LOCAL_REF" "$line" '- **Question**: "Sync GAIA?"'
  label_holds "$COPY" && return 1
  drop_lines "$LOCAL_REF" "$H_LABEL"
  label_holds "$COPY" && return 1
  true
}

# --- Not-run notes ------------------------------------------------------------------

not_run_holds() {
  section_of "$1" "$H_4_LOCAL" | grep -qF -- "$NOT_RUN" || return 1
  section_of "$1" "$H_REVIEW" | grep -qF -- "$NOT_RUN" || return 1
  return 0
}

@test "not-run notes: the Step 4 section and the review section each name them" {
  not_run_holds "$LOCAL_REF"
  local heading
  for heading in "$H_4_LOCAL" "$H_REVIEW"; do
    awk -v heading="$heading" -v needle="$NOT_RUN" '
      index($0, heading) == 1 { inside = 1; print; next }
      inside && /^##+ / { inside = 0 }
      inside && index($0, needle) { next }
      { print }
    ' "$LOCAL_REF" > "$COPY"
    not_run_holds "$COPY" && { echo "not enforced in: $heading" >&2; return 1; }
  done
  true
}

# --- The uncached-baseline fallback -------------------------------------------------

fallback_holds() {
  local line
  line="$(section_of "$1" "$H_4_LOCAL" | grep -F 'BASELINE_FALLBACK')"
  [ -n "$line" ] || return 1
  grep -qF '<build id>' <<<"$line" || return 1
  grep -qF 'plain release `v<BASELINE>`' <<<"$line" || return 1
  grep -qF 'not cached' <<<"$line" || return 1
  return 0
}

@test "fallback: the Proceed text for an uncached recorded build names its id and the plain release" {
  fallback_holds "$LOCAL_REF"
  replace_text "$LOCAL_REF" 'plain release `v<BASELINE>`' 'baseline'
  fallback_holds "$COPY" && return 1
  replace_text "$LOCAL_REF" '<build id>' 'build'
  fallback_holds "$COPY" && return 1
  true
}

# --- Step 9d --------------------------------------------------------------------

# 0 when reference copy `$1` records a local run with the manifest copy, the
# core write and the build write last, and no update ping or blend record.
local_record_holds() {
  local section
  section="$(section_file "$1" "$H_9D_LOCAL")" || return 1
  grep -qxF -- "$MANIFEST_COPY" "$section" || return 1
  grep -qxF -- "$CORE_WRITE" "$section" || return 1
  grep -qxF -- "$BUILD_WRITE" "$section" || return 1
  in_order "$section" "$MANIFEST_COPY" "$CORE_WRITE" "$BUILD_WRITE" || return 1
  grep -qE 'gaia ping|fitness-blend-record' "$section" && return 1
  return 0
}

@test "Step 9d on a local run: manifest copy, core write, build write last, and no ping or blend record" {
  local_record_holds "$LOCAL_REF"
  insert_after "$LOCAL_REF" "$MANIFEST_COPY" '.gaia/cli/gaia ping --event update --from <BASELINE> --to <LOCAL_CORE> || true'
  local_record_holds "$COPY" && return 1
  insert_after "$LOCAL_REF" "$MANIFEST_COPY" 'bash <main checkout path>/.gaia/scripts/fitness-blend-record.sh record'
  local_record_holds "$COPY" && return 1
  swap_lines "$LOCAL_REF" "$CORE_WRITE" "$BUILD_WRITE"
  local_record_holds "$COPY" && return 1
  true
}

record_removal_holds() {
  local section
  section="$(section_file "$1" "$H_9D_RECORD")" || return 1
  grep -qxF -- "$RECORD_REMOVE" "$section" || return 1
  in_order "$section" 'echo <LATEST> > .gaia/VERSION' "$RECORD_REMOVE" || return 1
}

@test "Step 9d on a release run after a local sync: the record is removed after the version write" {
  record_removal_holds "$LOCAL_REF"
  awk -v removal="$RECORD_REMOVE" -v heading="$H_9D_RECORD" '
    index($0, heading) == 1 { print; print ""; print "```bash"; print removal; print "```"; next }
    $0 == removal { next }
    { print }
  ' "$LOCAL_REF" > "$COPY"
  record_removal_holds "$COPY" && return 1
  true
}

# --- Step 4: the build commit in place of the changelog ------------------------------

build_commit_holds() {
  local section
  section="$(section_file "$1" "$H_4_LOCAL")" || return 1
  grep -qF 'Build commit: <LOCAL_COMMIT>' "$section" || return 1
  grep -qF 'update-gaia-preflight.sh changelog' "$section" && return 1
  return 0
}

@test "Step 4 on a local run: prints the build commit and never fetches the changelog" {
  build_commit_holds "$LOCAL_REF"
  insert_after "$LOCAL_REF" "$H_4_LOCAL" 'bash .gaia/scripts/update-gaia-preflight.sh changelog --baseline <BASELINE> --latest <LATEST> --latest-tag <LATEST_TAG>'
  build_commit_holds "$COPY" && return 1
  replace_text "$LOCAL_REF" 'Build commit: <LOCAL_COMMIT>' 'Build: unknown'
  build_commit_holds "$COPY" && return 1
  true
}

# --- The build marker ------------------------------------------------------------

marker_holds() {
  local skill_ref="$1" claim="$2"
  section_of "$skill_ref" "$H_STEP_3_LOCAL" | grep -qxF -- "$CLASSIFY_MODE_2" || return 1
  section_of "$skill_ref" "$H_STEP_3_LOCAL" | grep -qxF -- "$CLASSIFY_MODE_1" || return 1
  section_of "$skill_ref" "$H_11" | grep -F 'update-gaia-branch-state.sh classify' | grep -qF -- '--build <LOCAL_BUILD>' || return 1
  section_of "$skill_ref" "$H_SOURCE" | grep -qxF -- "$SOURCE_RESUME" || return 1
  grep -F -- '--build <LOCAL_BUILD>' "$claim" | grep -qF 'local-bundle.md' || return 1
  return 0
}

@test "the build marker: Step 3, Step 11 and the own-claim classify carry --build, and mode 1 resumes the source" {
  marker_holds "$LOCAL_REF" "$CLAIM_REF"
  drop_lines "$LOCAL_REF" "$CLASSIFY_MODE_2"
  marker_holds "$COPY" "$CLAIM_REF" && return 1
  drop_lines "$LOCAL_REF" "$CLASSIFY_MODE_1"
  marker_holds "$COPY" "$CLAIM_REF" && return 1
  awk -v heading="$H_11" '
    index($0, heading) == 1 { inside = 1 }
    inside && /^##+ / && index($0, heading) != 1 { inside = 0 }
    inside { gsub(/ --build <LOCAL_BUILD>/, "") }
    { print }
  ' "$LOCAL_REF" > "$COPY"
  marker_holds "$COPY" "$CLAIM_REF" && return 1
  drop_lines "$LOCAL_REF" "$SOURCE_RESUME"
  marker_holds "$COPY" "$CLAIM_REF" && return 1
  drop_lines "$CLAIM_REF" '--build <LOCAL_BUILD>'
  marker_holds "$LOCAL_REF" "$COPY" && return 1
  true
}

# --- Verify and prune keep the dev baseline -----------------------------------------

dev_baseline_kept() {
  section_of "$1" "$H_3C" | grep -F 'verify-bundles' | grep -qF -- '--baseline-tag <BASELINE_TAG>' || return 1
  section_of "$1" "$H_4B" | grep -F 'prune' | grep -qF -- '--baseline-tag <BASELINE_TAG>' || return 1
  return 0
}

@test "verify and prune: the Step 3c and Step 4b calls carry the dev baseline tag" {
  dev_baseline_kept "$LOCAL_REF"
  local heading
  for heading in "$H_3C" "$H_4B"; do
    awk -v heading="$heading" '
      index($0, heading) == 1 { inside = 1; print; next }
      inside && /^##+ / { inside = 0 }
      inside { gsub(/ --baseline-tag <BASELINE_TAG>/, "") }
      { print }
    ' "$LOCAL_REF" > "$COPY"
    dev_baseline_kept "$COPY" && { echo "not enforced in: $heading" >&2; return 1; }
  done
  true
}

# --- The release path stays as it was ------------------------------------------------

# Prints each line of SKILL.md copy `$1` that carries local wording without
# naming the reference, the adopter-owned sentinel line excepted.
unrouted_local_lines() {
  grep -nE 'local, unverified|VERSION-dev|--local' "$1" \
    | grep -vF 'local-bundle.md' \
    | grep -vF -- "$SENTINEL_LINE" || true
}

@test "release path: local wording in SKILL.md always routes to the local reference" {
  [ "$(grep -cE 'local, unverified|VERSION-dev|--local' "$SKILL")" -gt 3 ]
  [ -z "$(unrouted_local_lines "$SKILL")" ]
  insert_after "$SKILL" '## Step 2: Resolve latest release' 'The source is a local, unverified bundle.'
  [ -n "$(unrouted_local_lines "$COPY")" ]
}

@test "release path: the flow suite is unmodified and SKILL.md's fenced blocks match the committed copy" {
  git -C "$REPO_ROOT" diff --quiet HEAD -- .gaia/tests/lib/update-gaia-flow.bats
  local committed="$BATS_TEST_TMPDIR/committed-skill.md"
  git -C "$REPO_ROOT" show HEAD:.claude/skills/update-gaia/SKILL.md > "$committed"
  [ "$(fenced_lines "$SKILL")" = "$(fenced_lines "$committed")" ]
  # Failing state: a fenced command reworded.
  replace_text "$SKILL" 'echo <LATEST> > .gaia/VERSION' 'echo <LOCAL_CORE> > .gaia/VERSION'
  [ "$(fenced_lines "$COPY")" = "$(fenced_lines "$committed")" ] && return 1
  true
}

sentinel_holds() {
  grep -F -- "$SENTINEL_LINE" "$1" | grep -qF '`.gaia/VERSION-dev`'
}

@test "the adopter-owned sentinel list names .gaia/VERSION-dev" {
  sentinel_holds "$SKILL"
  replace_text "$SKILL" '`.gaia/VERSION-dev`, ' ''
  sentinel_holds "$COPY" && return 1
  true
}

# --- The baseline tag reaches the merge ------------------------------------------

baseline_tag_passed() {
  local merge="$1" conflict="$2"
  section_of "$merge" '## Inputs' | grep -qF '`BASELINE_TAG`' || return 1
  grep -qF "Every other entry's \`baselineTag\` is \`\$BASELINE_TAG\`." "$merge" || return 1
  grep -F 'Its prompt passes' "$conflict" | grep -qF '`BASELINE_TAG`' || return 1
  return 0
}

@test "the baseline tag: merge-execution names it for a non-deferred entry and the dispatch passes it" {
  baseline_tag_passed "$MERGE_EXECUTION" "$CONFLICT_FLOW"
  replace_text "$MERGE_EXECUTION" "is \`\$BASELINE_TAG\`." 'is `v$BASELINE`.'
  baseline_tag_passed "$COPY" "$CONFLICT_FLOW" && return 1
  replace_text "$CONFLICT_FLOW" '`BASELINE_TAG`, ' ''
  baseline_tag_passed "$MERGE_EXECUTION" "$COPY" && return 1
  true
}

# --- Pull mode ---------------------------------------------------------------------

pull_local_holds() {
  section_of "$1" '## Step 7' | grep -F 'Continue to the local sync (Recommended)' | grep -qF '/update-gaia --local <tarball path>'
}

@test "pull mode: the continue offer on a local run re-invokes with --local" {
  pull_local_holds "$PULL_REF"
  replace_text "$PULL_REF" '/update-gaia --local <tarball path>' '/update-gaia'
  pull_local_holds "$COPY" && return 1
  true
}

# --- Command shape --------------------------------------------------------------------

@test "command shape: every local reference block is one plain command with no substitution" {
  [ "$(grep -cxF '```bash' "$LOCAL_REF")" -gt 8 ]
  [ -z "$(fence_violations "$LOCAL_REF")" ]
  insert_after "$LOCAL_REF" "$SOURCE_RESUME" 'cat "$(pwd)/.gaia/VERSION"'
  [ -n "$(fence_violations "$COPY")" ]
}

# --- No working-document ids, no em dashes, the size limit -----------------------------

# Prints each line of the files given that carries a working-document id or an
# em dash. The needles are built from parts so this suite carries none.
banned_lines() {
  local em_dash spec_needle uat_needle issue_needle
  em_dash="$(printf '\342\200\224')"
  spec_needle='SPEC''-[0-9]'
  uat_needle='UAT''-[0-9]'
  issue_needle='#''[0-9]{3,}'
  grep -nE -- "$spec_needle|$uat_needle|$issue_needle" "$@" || true
  grep -nF -- "$em_dash" "$@" || true
}

@test "the touched files carry no working-document id and no em dash" {
  local files=("$SKILL" "$LOCAL_REF" "$CONFLICT_FLOW" "$MERGE_EXECUTION" "$CLAIM_REF" "$PULL_REF" "$THIS_SUITE")
  local file
  for file in "${files[@]}"; do [ -s "$file" ] || { echo "missing: $file" >&2; return 1; }; done
  [ -z "$(banned_lines "${files[@]}")" ]
  cp "$LOCAL_REF" "$COPY"
  printf 'See %s.\n' "$(printf 'SP''EC-1''38')" >> "$COPY"
  [ -n "$(banned_lines "$COPY")" ]
  cp "$LOCAL_REF" "$COPY"
  printf 'a %s b\n' "$(printf '\342\200\224')" >> "$COPY"
  [ -n "$(banned_lines "$COPY")" ]
}

@test "the local reference stays at or under 400 lines" {
  [ "$(wc -l < "$LOCAL_REF")" -le 400 ]
}

# --- Routing presence ----------------------------------------------------------------

# Writes SKILL.md copy `$1` to $COPY with every line naming the reference
# dropped from the section headed `$2`.
drop_routing_in() {
  awk -v heading="$2" '
    index($0, heading) == 1 { inside = 1; print; next }
    inside && /^##+ / { inside = 0 }
    inside && index($0, "local-bundle.md") { next }
    { print }
  ' "$1" > "$COPY"
  cmp -s "$1" "$COPY" && return 1
  return 0
}

routing_holds() {
  section_of "$1" '## Step 1: Read baseline version' | grep -F -- '--local' | grep -qF 'references/local-bundle.md' || return 1
  section_of "$1" '## Step 2: Resolve latest release' | grep -qF 'local-bundle.md' || return 1
  section_of "$1" '## Step 9d: Record the update' | grep -qF 'local-bundle.md' || return 1
  return 0
}

@test "routing: Step 1 names --local and the reference, and Step 2 and Step 9d route to it" {
  routing_holds "$SKILL"
  local heading
  for heading in '## Step 1: Read baseline version' '## Step 2: Resolve latest release' '## Step 9d: Record the update'; do
    drop_routing_in "$SKILL" "$heading"
    routing_holds "$COPY" && { echo "not enforced in: $heading" >&2; return 1; }
  done
  true
}

# --- A release run after a local sync ------------------------------------------------

record_proceed_holds() {
  local section
  section="$(section_file "$1" "$H_4_RECORD")" || return 1
  grep -qF 'recorded local build `<BASELINE_TAG>`' "$section" || return 1
  grep -qF 'checked only against a locally computed checksum' "$section" || return 1
  return 0
}

@test "Step 4 on a release run after a local sync: names the recorded build and its local checksum" {
  record_proceed_holds "$LOCAL_REF"
  replace_text "$LOCAL_REF" 'checked only against a locally computed checksum' 'verified'
  record_proceed_holds "$COPY" && return 1
  replace_text "$LOCAL_REF" 'recorded local build `<BASELINE_TAG>`' 'baseline'
  record_proceed_holds "$COPY" && return 1
  true
}

# --- The pull request -------------------------------------------------------------

pr_surfaces_hold() {
  section_of "$1" "$H_11" | grep -qF -- "$PR_TITLE" || return 1
  section_of "$1" "$H_11" | grep -qF -- "$PR_BODY_LINE" || return 1
  return 0
}

@test "Step 11 on a local run: the PR title and the body's first line" {
  pr_surfaces_hold "$LOCAL_REF"
  replace_text "$LOCAL_REF" "$PR_TITLE" 'chore(gaia): update'
  pr_surfaces_hold "$COPY" && return 1
  replace_text "$LOCAL_REF" "$PR_BODY_LINE" 'Pulls GAIA into the project.'
  pr_surfaces_hold "$COPY" && return 1
  true
}

# --- Mode 1 on a release run -----------------------------------------------------------

release_prefix_holds() {
  local reference="$1" skill="$2"
  grep -F 'update/<LATEST_TAG>-dev.' "$reference" | grep -qF 'release run' || return 1
  section_of "$skill" '### Step 3, worktree run in place' | grep -F 'update/<LATEST_TAG>-dev.' | grep -qF 'local-bundle.md' || return 1
  return 0
}

@test "mode 1 on a release run: a local sync's branch stops, and SKILL.md routes the rule" {
  release_prefix_holds "$LOCAL_REF" "$SKILL"
  drop_lines "$LOCAL_REF" 'update/<LATEST_TAG>-dev.'
  release_prefix_holds "$COPY" "$SKILL" && return 1
  drop_routing_in "$SKILL" '### Step 3, worktree run in place'
  release_prefix_holds "$LOCAL_REF" "$COPY" && return 1
  true
}
