#!/usr/bin/env bash
# 24-update-roster-prune.sh
#
# Proves the update that first ships the shell member reaches an adopter's
# roster correctly from the staged bundle: the three-way roster merge adds the
# member, the previous /update-gaia (which has no prune step of its own) is
# told to prune through the after-merge migration note, and the prune leaves
# the adopter's own roster entries alone. The package.json merge path for the
# new bats pin and test script is covered too.
#
# The note is selected the way /update-gaia selects it at its migration-note
# step: the staged bundle's own update-gaia-preflight.sh select-notes
# subcommand, run against the staged bundle as the latest directory. The merge
# is applied the way the merge does (the whole list item, inserted into the
# auditors block). The staged pre-commit hook needs lint-staged and a package
# install to run end to end, so the scenario runs the roster check the hook
# runs on a roster commit instead, and asserts the hook still calls it for a
# roster change.
#
# Assertions, in order:
#   1. gaia update merge-audit-ci, given a baseline roster without the shell
#      member, the staged roster as latest and an adopter roster carrying its
#      own member and an unowned entry for scripts/**, applies exactly one
#      item: the shell member, reason added, with the release-skip key true.
#      The adopter's own member appears in no bucket.
#   2. The selector prints an AFTER_MERGE line for the note that names the
#      prune command, and no BLOCKING line.
#   3. Before the prune, the merged roster fails the roster check as an
#      overbroad unowned entry; the note's own command prints exactly one
#      REMOVED line for scripts/**, leaves the adopter's member entry
#      byte-identical and changes no other roster line, and the roster check
#      then exits 0. The hook runs that check for a roster change.
#   4. Running the note's command again prints nothing and leaves the roster
#      byte-identical (a resumed run is safe).
#   5. The staged update skill places the prune step before the step that
#      records the update (the version write).
#   6. Guard can fail (runs right after step 2): with the note removed from a
#      scratch copy of the bundle's migrations, the same selector check finds
#      no AFTER_MERGE line for it, so the assertion of step 2 would fail.
#   7. gaia update merge-package, with a baseline lacking the bats pin and the
#      shell test script, applies exactly those two keys for an adopter that
#      has neither and reports no adopter-only key in any bucket. For an
#      adopter that already defines both, neither is applied; both are
#      reported as conflicts (observed: the test script carries a keep
#      recommendation, the version-valued bats pin recommends the higher
#      version).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib/lib.sh"

require_command jq "jq is required to read merge verdicts"
require_command rsync "rsync required for staging build"

STAGING="$(mktemp -d -t gaia-dist-roster-prune-stage-XXXXXX)"
WORK="$(mktemp -d -t gaia-dist-roster-prune-work-XXXXXX)"
trap 'rm -rf "$STAGING" "$WORK"' EXIT

"$HERE/lib/build-staging.sh" "$STAGING" \
  || { fail "build-staging failed"; exit 1; }

GAIA_CLI="$STAGING/.gaia/cli/gaia"
[ -x "$GAIA_CLI" ] || { fail "the staged bundle ships no executable CLI: $GAIA_CLI"; exit 1; }
capture_cli_stderr "$WORK/cli-stderr.txt"

LATEST_ROSTER="$STAGING/.gaia/audit-ci.yml"
ADOPTER="$WORK/adopter"
mkdir -p "$ADOPTER"
cp -R "$STAGING/." "$ADOPTER/"

# Roster item boundary: the comment block that introduces the unowned list.
UNOWNED_MARKER='^# Paths that are MEANT'
grep -qE "$UNOWNED_MARKER" "$LATEST_ROSTER" \
  || { fail "the staged roster has no comment block ahead of unowned:, so the scenario cannot place a member"; exit 1; }

# --- Roster fixtures --------------------------------------------------------
BASELINE_ROSTER="$WORK/baseline-audit-ci.yml"
awk '
  /^  - name: code-audit-shell$/ { skipping = 1; next }
  skipping && /^    / { next }
  { skipping = 0; print }
' "$LATEST_ROSTER" > "$BASELINE_ROSTER"
if grep -q 'code-audit-shell' "$BASELINE_ROSTER"; then
  fail "could not build a baseline roster without the shell member"; exit 1
fi

ADOPTER_ROSTER_BEFORE="$WORK/adopter-before.yml"
awk -v marker="$UNOWNED_MARKER" '
  $0 ~ marker { print "  - name: code-audit-mine\n    globs:\n      - \"infra/**\"\n    audience: adopter\n" }
  { print }
  /^  - "frontend\/public\/\*\*"$/ { print "  - \"scripts/**\"" }
' "$BASELINE_ROSTER" > "$ADOPTER_ROSTER_BEFORE"
grep -qF '  - "scripts/**"' "$ADOPTER_ROSTER_BEFORE" \
  || { fail "could not add the scripts/** unowned entry to the adopter roster"; exit 1; }
cp "$ADOPTER_ROSTER_BEFORE" "$ADOPTER/.gaia/audit-ci.yml"

mkdir -p "$ADOPTER/scripts" "$ADOPTER/infra"
printf '#!/usr/bin/env bash\necho deploy\n' > "$ADOPTER/scripts/deploy.sh"
printf 'resource "x" "y" {}\n' > "$ADOPTER/infra/main.tf"
git -C "$ADOPTER" init -q
git -C "$ADOPTER" add -A >/dev/null

# --- Assertion 1: the roster merge applies exactly the shell member ---------
ROSTER_MERGE="$(cd "$ADOPTER" && run_cli "$GAIA_CLI" update merge-audit-ci \
  --baseline "$BASELINE_ROSTER" --latest "$LATEST_ROSTER" --current "$ADOPTER_ROSTER_BEFORE" --json)" \
  || fail_with_stderr "gaia update merge-audit-ci failed"
printf '%s' "$ROSTER_MERGE" | jq -e '
    (.applied | length) == 1
    and .applied[0].key == "code-audit-shell"
    and .applied[0].reason == "added"
    and .applied[0].latest.skip_gaia_release_changes == true' >/dev/null \
  || { fail "the roster merge did not apply exactly the shell member with the release-skip key: $ROSTER_MERGE"; exit 1; }
if [ "$(printf '%s' "$ROSTER_MERGE" | jq '[.[][]? | select(.key == "code-audit-mine")] | length')" -ne 0 ]; then
  fail "the adopter's own member appears in a merge bucket: $ROSTER_MERGE"; exit 1
fi

# --- Assertion 2: the selector hands the previous update the prune note ------
NOTE_FILES="$(grep -l 'roster-prune-overbroad.sh' "$STAGING"/.gaia/migrations/*.md || true)"
[ "$(grep -c . <<<"$NOTE_FILES")" -eq 1 ] \
  || { fail "expected exactly one staged migration note naming the prune script, got: $NOTE_FILES"; exit 1; }
NOTE_FILE="$NOTE_FILES"
NOTE_VERSION="$(basename "$NOTE_FILE" .md)"
# The baseline is the newest release below the note's, so only the note's own
# release falls in the selected range.
SELECT_BASELINE="$(for migration_note in "$STAGING"/.gaia/migrations/*.md; do basename "$migration_note" .md; done \
  | sort -t. -k1,1n -k2,2n -k3,3n \
  | awk -v note="$NOTE_VERSION" '$0 == note { print previous; exit } { previous = $0 }')"
[ -n "$SELECT_BASELINE" ] || SELECT_BASELINE="0.0.0"

# selected_notes LATEST_DIR: the selector's output for the staged range.
selected_notes() {
  bash "$STAGING/.gaia/scripts/update-gaia-preflight.sh" select-notes \
    --latest-dir "$1" --baseline "$SELECT_BASELINE" --latest "$NOTE_VERSION"
}

# note_is_selected LATEST_DIR: succeeds when the selector prints an AFTER_MERGE
# line for the prune note and no BLOCKING line.
note_is_selected() {
  local selection
  selection="$(selected_notes "$1")" || return 1
  grep -q "^AFTER_MERGE $NOTE_VERSION " <<<"$selection" || return 1
  grep -q '^BLOCKING' <<<"$selection" && return 1
  return 0
}
note_is_selected "$STAGING" \
  || { fail "the selector printed no AFTER_MERGE $NOTE_VERSION line (or printed BLOCKING) for the prune note: $(selected_notes "$STAGING" || true)"; exit 1; }

# --- Assertion 6 (guard can fail): without the note the selection fails -----
GUARD_BUNDLE="$WORK/guard-bundle"
mkdir -p "$GUARD_BUNDLE/.gaia"
cp -R "$STAGING/.gaia/scripts" "$GUARD_BUNDLE/.gaia/scripts"
cp -R "$STAGING/.gaia/migrations" "$GUARD_BUNDLE/.gaia/migrations"
rm -f "$GUARD_BUNDLE/.gaia/migrations/$NOTE_VERSION.md"
if note_is_selected "$GUARD_BUNDLE"; then
  fail "guard-can-fail: the selection check passed with the prune note removed from the bundle"; exit 1
fi

# --- Assertion 3: apply the merge, then the note's command -------------------
MINE_ITEM_BEFORE="$WORK/mine-before.yml"
member_item() {
  awk -v name="$2" '
    $0 == "  - name: " name { printing = 1 }
    printing && $0 == "" { exit }
    printing { print }
  ' "$1"
}
member_item "$ADOPTER/.gaia/audit-ci.yml" code-audit-mine > "$MINE_ITEM_BEFORE"
[ -s "$MINE_ITEM_BEFORE" ] || { fail "could not read the adopter member's roster item"; exit 1; }

SHELL_ITEM="$WORK/shell-item.yml"
member_item "$LATEST_ROSTER" code-audit-shell > "$SHELL_ITEM"
[ -s "$SHELL_ITEM" ] || { fail "could not read the shell member's item from the staged roster"; exit 1; }
MERGED_ROSTER="$WORK/merged.yml"
awk -v marker="$UNOWNED_MARKER" '
  FNR == NR { item = item $0 "\n"; next }
  $0 ~ marker { printf "%s\n", item }
  { print }
' "$SHELL_ITEM" "$ADOPTER_ROSTER_BEFORE" > "$MERGED_ROSTER"
cp "$MERGED_ROSTER" "$ADOPTER/.gaia/audit-ci.yml"
git -C "$ADOPTER" add -A >/dev/null

PRE_PRUNE_STATUS=0
PRE_PRUNE_OUTPUT="$(bash "$ADOPTER/.gaia/scripts/verify-audit-roster.sh" --root "$ADOPTER" 2>&1)" || PRE_PRUNE_STATUS=$?
if [ "$PRE_PRUNE_STATUS" -eq 0 ] || ! grep -qF 'overbroad-unowned-glob' <<<"$PRE_PRUNE_OUTPUT"; then
  printf '%s\n' "$PRE_PRUNE_OUTPUT" >&2
  fail "the merged roster should fail the roster check as an overbroad unowned entry before the prune"; exit 1
fi

# The note's own command: the fenced line that names the prune script, with its
# root placeholder replaced by the adopter tree.
NOTE_COMMAND="$(grep -E '^bash \.gaia/scripts/roster-prune-overbroad\.sh ' "$NOTE_FILE" | head -n 1)"
[ -n "$NOTE_COMMAND" ] || { fail "the note carries no prune command line"; exit 1; }
NOTE_COMMAND="${NOTE_COMMAND//<update worktree root>/$ADOPTER}"
case "$NOTE_COMMAND" in
  *'<'*) fail "the note's prune command still holds a placeholder after substituting the root: $NOTE_COMMAND"; exit 1 ;;
esac

run_note_command() {
  (cd "$ADOPTER" && bash -c "$NOTE_COMMAND")
}
PRUNE_OUTPUT="$(run_note_command)" \
  || { fail "the note's prune command exited non-zero: $NOTE_COMMAND"; exit 1; }
if [ "$(printf '%s\n' "$PRUNE_OUTPUT" | grep -c .)" -ne 1 ] \
  || [ "$(printf '%s\n' "$PRUNE_OUTPUT" | awk -F'\t' '$1 == "REMOVED" && $2 == "scripts/**" { count++ } END { print count + 0 }')" -ne 1 ]; then
  fail "expected exactly one REMOVED line for scripts/**, got: $PRUNE_OUTPUT"; exit 1
fi

MINE_ITEM_AFTER="$WORK/mine-after.yml"
member_item "$ADOPTER/.gaia/audit-ci.yml" code-audit-mine > "$MINE_ITEM_AFTER"
cmp -s "$MINE_ITEM_BEFORE" "$MINE_ITEM_AFTER" \
  || { fail "the adopter's code-audit-mine entry changed during the prune"; exit 1; }
changed_roster_lines="$(diff "$MERGED_ROSTER" "$ADOPTER/.gaia/audit-ci.yml" | grep -c '^[<>]' || true)"
[ "$changed_roster_lines" -eq 1 ] \
  || { fail "the prune changed $changed_roster_lines roster lines, expected exactly the one scripts/** entry"; exit 1; }

POST_PRUNE_STATUS=0
POST_PRUNE_OUTPUT="$(bash "$ADOPTER/.gaia/scripts/verify-audit-roster.sh" --root "$ADOPTER" 2>&1)" || POST_PRUNE_STATUS=$?
if [ "$POST_PRUNE_STATUS" -ne 0 ]; then
  printf '%s\n' "$POST_PRUNE_OUTPUT" >&2
  fail "the roster check exited $POST_PRUNE_STATUS after the prune, expected 0"; exit 1
fi
if ! grep -q 'verify-audit-roster.sh' "$ADOPTER/.githooks/pre-commit" \
  || ! grep -q 'audit-ci' "$ADOPTER/.githooks/pre-commit"; then
  fail "the staged pre-commit hook no longer runs the roster check for a roster change"; exit 1
fi

# --- Assertion 4: a second run is idempotent ---------------------------------
ROSTER_BEFORE_SECOND_RUN="$WORK/roster-before-second-run.yml"
cp "$ADOPTER/.gaia/audit-ci.yml" "$ROSTER_BEFORE_SECOND_RUN"
SECOND_OUTPUT="$(run_note_command)" \
  || { fail "the note's prune command failed on its second run"; exit 1; }
[ -z "$SECOND_OUTPUT" ] || { fail "the second prune run printed output: $SECOND_OUTPUT"; exit 1; }
cmp -s "$ROSTER_BEFORE_SECOND_RUN" "$ADOPTER/.gaia/audit-ci.yml" \
  || { fail "the second prune run changed the roster"; exit 1; }

# --- Assertion 5: the skill prunes before it records the update -------------
SKILL="$STAGING/.claude/skills/update-gaia/SKILL.md"
prune_heading_line="$(grep -n '^## Step [0-9a-z]*: Prune overbroad unowned entries' "$SKILL" | head -n 1 | cut -d: -f1)"
record_heading_line="$(grep -n '^## Step 9d: ' "$SKILL" | head -n 1 | cut -d: -f1)"
[ -n "$prune_heading_line" ] && [ -n "$record_heading_line" ] \
  || { fail "the update skill lacks the prune step heading or the Step 9d heading"; exit 1; }
[ "$prune_heading_line" -lt "$record_heading_line" ] \
  || { fail "the prune step (line $prune_heading_line) does not precede Step 9d (line $record_heading_line)"; exit 1; }

# --- Assertion 7: the package.json merge path --------------------------------
LATEST_PACKAGE="$STAGING/package.json"
BASELINE_PACKAGE="$WORK/baseline-package.json"
jq 'del(.devDependencies.bats) | del(.scripts["test:shell"])' "$LATEST_PACKAGE" > "$BASELINE_PACKAGE"
if [ "$(jq '[.devDependencies.bats, .scripts["test:shell"]] | map(select(. != null)) | length' "$LATEST_PACKAGE")" -ne 2 ]; then
  fail "the staged package.json lacks the bats pin or the test:shell script"; exit 1
fi
PINNED_BATS="$(jq -r '.devDependencies.bats' "$LATEST_PACKAGE")"

merge_package_for() {
  (cd "$ADOPTER" && run_cli "$GAIA_CLI" update merge-package \
    --baseline "$BASELINE_PACKAGE" --latest "$LATEST_PACKAGE" --current "$1" --json)
}

ADOPTER_PLAIN_PACKAGE="$WORK/adopter-plain-package.json"
jq '.scripts["deploy"] = "sh deploy.sh" | .devDependencies["adopter-only-tool"] = "1.0.0"' "$BASELINE_PACKAGE" > "$ADOPTER_PLAIN_PACKAGE"
PLAIN_MERGE="$(merge_package_for "$ADOPTER_PLAIN_PACKAGE")" \
  || fail_with_stderr "gaia update merge-package failed for the plain adopter package.json"
printf '%s' "$PLAIN_MERGE" | jq -e --arg pin "$PINNED_BATS" '
    (.applied | length) == 2
    and ([.applied[] | select(.section == "devDependencies" and .key == "bats" and .latest == $pin)] | length) == 1
    and ([.applied[] | select(.section == "scripts" and .key == "test:shell")] | length) == 1' >/dev/null \
  || { fail "the package merge did not apply exactly the bats pin and the test:shell script: $PLAIN_MERGE"; exit 1; }
if [ "$(printf '%s' "$PLAIN_MERGE" | jq '[.[][]? | select(.key == "deploy" or .key == "adopter-only-tool")] | length')" -ne 0 ]; then
  fail "an adopter-only package key appears in a merge bucket: $PLAIN_MERGE"; exit 1
fi

ADOPTER_HOLDING_PACKAGE="$WORK/adopter-holding-package.json"
jq '.scripts["test:shell"] = "my-runner" | .devDependencies.bats = "0.9.0"' "$BASELINE_PACKAGE" > "$ADOPTER_HOLDING_PACKAGE"
HOLDING_MERGE="$(merge_package_for "$ADOPTER_HOLDING_PACKAGE")" \
  || fail_with_stderr "gaia update merge-package failed for the adopter that holds its own keys"
printf '%s' "$HOLDING_MERGE" | jq -e '
    ([.applied[] | select(.key == "bats" or .key == "test:shell")] | length) == 0
    and ([.conflicts[] | select(.section == "devDependencies" and .key == "bats" and .adopter == "0.9.0")] | length) == 1
    and ([.conflicts[] | select(.section == "scripts" and .key == "test:shell" and .adopter == "my-runner" and .recommendation.option == "keep")] | length) == 1' >/dev/null \
  || { fail "an adopter-held bats pin or test:shell script was applied or not reported as a conflict: $HOLDING_MERGE"; exit 1; }

pass "shell member roster merge, after-merge prune note, prune idempotence and package.json merge hold on the staged bundle"
