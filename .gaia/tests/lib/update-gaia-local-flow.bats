#!/usr/bin/env bats
# The /update-gaia local-bundle reference (references/local-bundle.md) as the
# skill writes it: every command block in the shape a worktree session admits,
# the local run's pull request title and first body line (the title becomes the
# update commit subject that fitness-nudge-lib.sh matches as a GAIA update),
# no working-document id or em dash in the files the local flow touches, and the
# reference's size limit. The scripts these calls name are driven by their own
# suites.
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

H_11='## Step 11 with a local build'

SOURCE_RESUME='bash .gaia/scripts/update-gaia-local.sh source --tarball <tarball path> --resume'
PR_TITLE='chore(gaia): update to <LOCAL_TAG>'
PR_BODY_LINE='Syncs a local, unverified GAIA build <LOCAL_TAG> (commit <LOCAL_COMMIT>) into the project.'

# The lines of the section headed `$2` in file `$1`, up to the next heading of
# level two or three.
section_of() {
  awk -v heading="$2" '
    index($0, heading) == 1 { inside = 1; print; next }
    inside && /^##+ / { exit }
    inside { print }
  ' "$1"
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
