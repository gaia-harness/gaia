#!/usr/bin/env bats
#
# Doc-conformance suite for the budget batch in /gaia-debt's playbook
# (.claude/skills/gaia/references/debt.md and debt/recommend.md): the
# optional last option of the no-argument offer, and what a picked budget
# batch does at the claim, the commit split, and the drop of a member.
#
# The playbook is executed by a model, so every clause is an instruction. Each
# pin names one clause, is scoped to the section that owns it, and has a red
# twin that deletes the clause from a scratch copy and proves the check fails.
# A compound clause is split into one pin each.
#
# The scratch copy is made by copying the references directory;
# DOC_DEBT_BUDGET_BATCH_DIR points the suite at one, so a seeded copy can be
# checked without touching the real files.
#
# Assertion style: .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  REFS="${DOC_DEBT_BUDGET_BATCH_DIR:-$REPO_ROOT/.claude/skills/gaia/references}"
  OFFER_HEADING='## Recommend and present'
  CLAIM_HEADING='## Claim the fix unit'
  RESOLVE_HEADING='## Resolve the selected unit'
  DROP_HEADING='### Dropping a member after its commits are written'
  GUARD_HEADING='## Guardrails'
}

# extract_section <file> <heading-line-prefix>: the first matching section's
# body, heading included, up to the next heading of the same or shallower
# level. Prints nothing when no heading matches.
extract_section() {
  awk -v want="$2" '
    !found && index($0, want) == 1 {
      found = 1
      match($0, /^#+/)
      level = RLENGTH
      print
      next
    }
    found && /^#+ / {
      match($0, /^#+/)
      if (RLENGTH <= level) exit
    }
    found { print }
  ' "$1"
}

scratch_copy() {
  local copy="$BATS_TEST_TMPDIR/references"
  rm -rf "$copy"
  mkdir -p "$copy"
  cp "$REFS/debt.md" "$copy/debt.md"
  cp -R "$REFS/debt" "$copy/debt"
  printf '%s\n' "$copy"
}

# remove_text <file> <marker> <needle>: deletes the first occurrence of the
# needle on the first line containing the marker (any line when the marker is
# empty). Fails when the needle is absent, so a twin never mutates nothing.
remove_text() {
  NEEDLE="$3" MARKER="$2" awk '
    BEGIN { needle = ENVIRON["NEEDLE"]; marker = ENVIRON["MARKER"] }
    {
      line = $0
      if (!done && (marker == "" || index(line, marker))) {
        at = index(line, needle)
        if (at) {
          line = substr(line, 1, at - 1) substr(line, at + length(needle))
          done = 1
        }
      }
      print line
    }
    END { exit done ? 0 : 1 }
  ' "$1" >"$1.new" || {
    rm -f "$1.new"
    return 1
  }
  mv "$1.new" "$1"
}

# section_has <dir> <file> <heading> <marker> <needle>: the section is
# non-empty and, among its lines containing the marker (all lines when the
# marker is empty), one contains the needle.
section_has() {
  local section lines
  section="$(extract_section "$1/$2" "$3")"
  [ -n "$section" ] || return 1
  if [ -n "$4" ]; then
    lines="$(grep -F -- "$4" <<<"$section")" || return 1
  else
    lines="$section"
  fi
  grep -qF -- "$5" <<<"$lines"
}

# check_pin <file> <heading> <marker> <needle>: the clause is present, and the
# same check goes red on a scratch copy with the clause deleted.
check_pin() {
  local copy
  section_has "$REFS" "$1" "$2" "$3" "$4" || return 1
  copy="$(scratch_copy)"
  remove_text "$copy/$1" "$3" "$4" || return 1
  if section_has "$copy" "$1" "$2" "$3" "$4"; then
    return 1
  fi
  return 0
}

# check_pin_removing <file> <heading> <needle> <fragment>: the needle is
# present, and the check goes red when only the fragment inside it is deleted.
check_pin_removing() {
  local copy
  section_has "$REFS" "$1" "$2" "" "$3" || return 1
  copy="$(scratch_copy)"
  remove_text "$copy/$1" "" "$4" || return 1
  if section_has "$copy" "$1" "$2" "" "$3"; then
    return 1
  fi
  return 0
}

# --- the offer: shapes and option rules -------------------------------------

# cluster_headed_block <dir>: the cluster-headed bullet and its options.
cluster_headed_block() {
  extract_section "$1/debt/recommend.md" "$OFFER_HEADING" |
    awk '
      index($0, "- **Top candidate heads a public-batch-eligible cluster") == 1 { on = 1 }
      on && index($0, "- **Top candidate is a singleton") == 1 { exit }
      on { print }
    '
}

# last_item_is_budget_batch <dir>: the last numbered option of the
# cluster-headed list is the budget batch and carries no recommended mark.
last_item_is_budget_batch() {
  local block last
  block="$(cluster_headed_block "$1")"
  [ -n "$block" ] || return 1
  last="$(grep -E '^[[:space:]]+[0-9]+\. ' <<<"$block" | tail -1)"
  [ -n "$last" ] || return 1
  grep -qF -- 'The budget batch' <<<"$last" || return 1
  grep -qF -- '(Recommended)' <<<"$last" && return 1
  return 0
}

@test "the last numbered item of the cluster-headed list is the budget batch" {
  last_item_is_budget_batch "$REFS"
}

@test "the cluster-headed check goes red when the budget batch carries the recommended mark" {
  copy="$(scratch_copy)"
  awk '
    index($0, "  4. The budget batch") == 1 { $0 = $0 " (Recommended)" }
    { print }
  ' "$copy/debt/recommend.md" >"$copy/debt/recommend.md.new"
  mv "$copy/debt/recommend.md.new" "$copy/debt/recommend.md"
  grep -F -- '  4. The budget batch' "$copy/debt/recommend.md" | grep -qF -- '(Recommended)'
  run last_item_is_budget_batch "$copy"
  [ "$status" -ne 0 ]
}

@test "the cluster-headed check goes red when the budget batch item is removed" {
  copy="$(scratch_copy)"
  grep -vF -- '  4. The budget batch,' "$copy/debt/recommend.md" >"$copy/debt/recommend.md.new"
  mv "$copy/debt/recommend.md.new" "$copy/debt/recommend.md"
  run last_item_is_budget_batch "$copy"
  [ "$status" -ne 0 ]
}

@test "the singleton-headed shape places the budget batch last" {
  check_pin debt/recommend.md "$OFFER_HEADING" 'Top candidate is a singleton' 'add the budget batch as the last option'
}

@test "the option label takes its members and total from the scorer's output" {
  check_pin debt/recommend.md "$OFFER_HEADING" 'The budget batch is the' "carries those members and the scorer's total against its budget, both read from the scorer's output"
}

# singleton_headed_block <dir>: the singleton-headed bullet.
singleton_headed_block() {
  extract_section "$1/debt/recommend.md" "$OFFER_HEADING" |
    awk '
      index($0, "- **Top candidate is a singleton") == 1 { print; exit }
    '
}

# shapes_hold_at_most_four_options <dir>: each offer shape lists at most four
# options with the budget batch among them and the top issue alone present.
# Both shapes are derived from the file and an empty derivation fails.
shapes_hold_at_most_four_options() {
  local block count single
  block="$(cluster_headed_block "$1")"
  [ -n "$block" ] || return 1
  count="$(grep -cE '^[[:space:]]+[0-9]+\. ' <<<"$block")"
  [ "$count" -ge 1 ] && [ "$count" -le 4 ] || return 1
  grep -qF -- 'The budget batch' <<<"$block" || return 1
  grep -qF -- '`#<A> only`' <<<"$block" || return 1
  single="$(singleton_headed_block "$1")"
  [ -n "$single" ] || return 1
  grep -qF -- 'present the top three candidates' <<<"$single" || return 1
  grep -qF -- 'top candidate first' <<<"$single" || return 1
  grep -qF -- 'add the budget batch as the last option' <<<"$single" || return 1
  return 0
}

@test "each offer shape lists at most four options with the budget batch and the top issue alone" {
  shapes_hold_at_most_four_options "$REFS"
}

@test "the shapes check goes red when the top-issue-alone option is removed" {
  copy="$(scratch_copy)"
  grep -vF -- '`#<A> only`' "$copy/debt/recommend.md" >"$copy/debt/recommend.md.new"
  mv "$copy/debt/recommend.md.new" "$copy/debt/recommend.md"
  run shapes_hold_at_most_four_options "$copy"
  [ "$status" -ne 0 ]
}

@test "the shapes check goes red when the cluster-headed list grows a fifth option" {
  copy="$(scratch_copy)"
  awk '
    { print }
    index($0, "  4. The budget batch") == 1 { print "  5. An extra option." }
  ' "$copy/debt/recommend.md" >"$copy/debt/recommend.md.new"
  mv "$copy/debt/recommend.md.new" "$copy/debt/recommend.md"
  grep -qF -- '  5. An extra option.' "$copy/debt/recommend.md"
  run shapes_hold_at_most_four_options "$copy"
  [ "$status" -ne 0 ]
}

@test "the shapes check goes red when the singleton-headed shape drops the top three" {
  copy="$(scratch_copy)"
  remove_text "$copy/debt/recommend.md" 'Top candidate is a singleton' 'present the top three candidates'
  run shapes_hold_at_most_four_options "$copy"
  [ "$status" -ne 0 ]
}

@test "the budget option shows only when members is not empty" {
  check_pin debt/recommend.md "$OFFER_HEADING" 'The budget batch is the' 'shown only when `members` is not empty'
}

@test "a top candidate heading no eligible cluster takes the singleton-headed shape" {
  check_pin debt/recommend.md "$OFFER_HEADING" 'Top candidate is a singleton' 'Any top candidate that heads no public-batch-eligible cluster takes this singleton-headed shape'
}

@test "the printed backlog annotates each budget batch member" {
  check_pin debt/recommend.md "$OFFER_HEADING" 'When the full backlog prints' 'annotate each budget batch member'
}

@test "a reason an issue was left out is never printed, committed or put in the pull request body" {
  check_pin debt/recommend.md "$OFFER_HEADING" 'When the full backlog prints' 'Never print a reason an issue was left out'
}

@test "neither a left-out reason nor the annotation enters a commit or the pull request body" {
  check_pin debt/recommend.md "$OFFER_HEADING" 'When the full backlog prints' 'never put that reason or the annotation in a commit or pull request body'
}

# --- the budget batch rules region holds no weight or limit -----------------

# budget_region <dir>: from the `Budget batch rules:` anchor line to the
# section's next list item (or the section's end).
budget_region() {
  extract_section "$1/debt/recommend.md" "$OFFER_HEADING" |
    awk '
      !on && $0 == "Budget batch rules:" { on = 1; next }
      on && /^[[:space:]]*([-*]|[0-9]+\.) / { exit }
      on { print }
    '
}

# scorer_constant_values: the distinct numeric values the scorer assigns to
# its DEBT_BUDGET_ constants, one per line.
scorer_constant_values() {
  sed -n 's/^DEBT_BUDGET_[A-Z_]*=\([0-9][0-9]*\).*/\1/p' "$REPO_ROOT/.gaia/scripts/debt-batch-budget.sh" | sort -u
}

# region_has_no_scorer_value <dir>: the region is non-empty and no scorer
# constant value appears in it as a whole word.
region_has_no_scorer_value() {
  local region value values count
  region="$(budget_region "$1")"
  [ -n "$region" ] || return 1
  values="$(scorer_constant_values)"
  count="$(grep -c . <<<"$values")"
  [ "$count" -ge 4 ] || return 1
  while IFS= read -r value; do
    grep -qw -- "$value" <<<"$region" && return 1
  done <<<"$values"
  return 0
}

@test "the budget batch region is non-empty and holds no scorer weight or limit" {
  region_has_no_scorer_value "$REFS"
}

@test "the budget batch region check goes red when the limit is seeded into it" {
  copy="$(scratch_copy)"
  limit="$(sed -n 's/^DEBT_BUDGET_LIMIT=\([0-9][0-9]*\).*/\1/p' "$REPO_ROOT/.gaia/scripts/debt-batch-budget.sh")"
  [ -n "$limit" ]
  LIMIT_VALUE="$limit" awk '
    { print }
    $0 == "Budget batch rules:" { print ""; print "The batch fits a budget of " ENVIRON["LIMIT_VALUE"] "." }
  ' "$copy/debt/recommend.md" >"$copy/debt/recommend.md.new"
  mv "$copy/debt/recommend.md.new" "$copy/debt/recommend.md"
  grep -qF -- "budget of ${limit}." "$copy/debt/recommend.md"
  run region_has_no_scorer_value "$copy"
  [ "$status" -ne 0 ]
}

@test "the budget batch region check goes red when the anchor line is gone" {
  copy="$(scratch_copy)"
  grep -vxF -- 'Budget batch rules:' "$copy/debt/recommend.md" >"$copy/debt/recommend.md.new"
  mv "$copy/debt/recommend.md.new" "$copy/debt/recommend.md"
  run region_has_no_scorer_value "$copy"
  [ "$status" -ne 0 ]
}

# --- the offer-mode call ----------------------------------------------------

OFFER_COMMAND='bash .gaia/scripts/debt-batch-budget.sh --offer --backlog "<offer directory>/backlog.json" --report "<offer directory>/report.json" --withheld "<withheld numbers>" --probe-report "<offer directory>/probe.json" > "<offer directory>/offer.json"'

@test "the section holds the exact offer-mode command" {
  check_pin_removing debt/recommend.md "$OFFER_HEADING" "$OFFER_COMMAND" 'bash .gaia/scripts/debt-batch-budget.sh --offer'
}

@test "the offer-mode command carries the report input" {
  check_pin_removing debt/recommend.md "$OFFER_HEADING" "$OFFER_COMMAND" ' --report "<offer directory>/report.json"'
}

@test "the offer-mode command carries the withheld input" {
  check_pin_removing debt/recommend.md "$OFFER_HEADING" "$OFFER_COMMAND" ' --withheld "<withheld numbers>"'
}

@test "the offer-mode command carries the probe-report input" {
  check_pin_removing debt/recommend.md "$OFFER_HEADING" "$OFFER_COMMAND" ' --probe-report "<offer directory>/probe.json"'
}

@test "the offer-mode command follows the offer-time reads" {
  check_pin debt/recommend.md "$OFFER_HEADING" 'Offer-mode call.' 'after the offer-time reads, run the scorer'"'"'s offer mode'
}

@test "the offer-mode command is saved as the offer carrier" {
  check_pin_removing debt/recommend.md "$OFFER_HEADING" "$OFFER_COMMAND" ' > "<offer directory>/offer.json"'
}

# --- the withheld list ------------------------------------------------------

@test "the withheld list comes from the offer-time security read" {
  check_pin debt/recommend.md "$OFFER_HEADING" 'The withheld list comes from' 'The withheld list comes from the offer-time security read'
}

@test "an empty list without classifying is the confirmed-PRIVATE arm only" {
  check_pin debt/recommend.md "$OFFER_HEADING" 'Confirmed PRIVATE' 'pass an empty list, with no classification'
}

@test "a completed classification that finds nothing passes an empty list and the option still shows" {
  check_pin debt/recommend.md "$OFFER_HEADING" 'classification complete on every candidate' 'The list may be empty, and the budget option still shows'
}

@test "PUBLIC counts as non-PRIVATE" {
  check_pin debt/recommend.md "$OFFER_HEADING" 'count as non-PRIVATE' 'PUBLIC'
}

@test "INTERNAL counts as non-PRIVATE" {
  check_pin debt/recommend.md "$OFFER_HEADING" 'count as non-PRIVATE' 'INTERNAL'
}

@test "a failed visibility read counts as non-PRIVATE" {
  check_pin debt/recommend.md "$OFFER_HEADING" 'count as non-PRIVATE' 'a failed visibility read'
}

@test "a failed or absent classification withholds the option and makes no call" {
  check_pin debt/recommend.md "$OFFER_HEADING" 'classification failed or absent' 'make no offer-mode call and show no budget option'
}

@test "the offer-time security read yields the withheld list" {
  check_pin debt.md '### Offer-time reads' 'The same read yields' 'withheld list'
}

@test "the offer-time security read points at the offer-mode call for the withheld list arms" {
  check_pin debt.md '### Offer-time reads' 'The same read yields' '`debt/recommend.md` owns its arms'
}

@test "every budget batch member passes the fix-time security screen" {
  check_pin debt.md '## Fix-time security screen' 'This member-level screen is the' 'Every budget batch member passes this screen too'
}

# --- failed probe and failed run --------------------------------------------

@test "a failed probe runs offer mode without the probe report" {
  check_pin debt/recommend.md "$OFFER_HEADING" 'A failed probe' 'run offer mode without `--probe-report`'
}

@test "a failed probe is covered by the fix-time staleness screen" {
  check_pin debt/recommend.md "$OFFER_HEADING" 'A failed probe' 'the fix-time staleness screen re-checks the selected part'
}

@test "a failed run costs one reported line" {
  check_pin debt/recommend.md "$OFFER_HEADING" 'A failed run' 'report one line saying the budget option could not be computed'
}

@test "a failed run presents the offer without the option" {
  check_pin debt/recommend.md "$OFFER_HEADING" 'A failed run' 'present the offer without it'
}

@test "a failed run does not stop the run" {
  check_pin debt/recommend.md "$OFFER_HEADING" 'A failed run' 'The run does not stop'
}

# --- the backlog read and the staleness probe -------------------------------

@test "the backlog pass reads the one written ordering read" {
  check_pin debt.md '## Read and order the backlog' 'bash .gaia/scripts/debt-backlog.sh' 'bash .gaia/scripts/debt-backlog.sh --backlog "<offer directory>/backlog.json"'
}

@test "a non-zero backlog pass still stops the run before anything is claimed" {
  check_pin debt.md '## Read and order the backlog' 'A non-zero exit stops the run' 'A non-zero exit stops the run before anything is claimed'
}

@test "a named set keeps its pipe into the scorer" {
  check_pin debt.md '## Read and order the backlog' 'A named set skips the backlog pass' 'keeps its own pipe into the scorer'
}

@test "the staleness probe excludes a gone issue from the budget batch only" {
  check_pin debt.md '### Staleness probe' 'This probe is **advisory' 'Only the budget batch leaves out a `gone` issue'
}

@test "the staleness probe still offers a gone issue one at a time or in a cluster" {
  check_pin debt.md '### Staleness probe' 'This probe is **advisory' 'the drain still offers a `gone` issue as a one-at-a-time or cluster option'
}

@test "the spec read keeps a withheld or spec member's whole cluster out of a budget batch" {
  check_pin debt.md '### Offer-time reads' 'Offer-time spec read' 'a withheld or spec-class member keeps its whole cluster out of the batch at the pick'
}

# --- claim, resolve, drop, cost record, guardrails --------------------------

@test "a budget batch is a non-named selection" {
  check_pin debt.md "$CLAIM_HEADING" 'A budget batch is a non-named selection' 'A budget batch is a non-named selection'
}

@test "a budget batch member lost at the claim drops with no refill" {
  check_pin debt.md "$CLAIM_HEADING" 'A budget batch is a non-named selection' 'drops with no refill'
}

@test "a claim-time drop or a screen peel may split a cluster" {
  check_pin debt.md "$CLAIM_HEADING" 'A budget batch is a non-named selection' 'leaves its survivors as one batch part'
}

@test "a batch part is one cluster or one singleton inside the selection" {
  check_pin debt.md "$RESOLVE_HEADING" 'A **batch part**' 'A **batch part** is one cluster or one singleton inside the selection'
}

@test "the fix unit stays the whole selection" {
  check_pin debt.md "$RESOLVE_HEADING" 'A **batch part**' 'The fix unit stays the whole selection'
}

@test "the whole combined diff is staged at gate time" {
  check_pin debt.md "$RESOLVE_HEADING" 'Run the Quality Gate' 'the whole combined diff is staged at gate time'
}

@test "the Quality Gate runs once over the combined diff" {
  check_pin debt.md "$RESOLVE_HEADING" 'Run the Quality Gate' 'the Quality Gate runs once over it'
}

@test "one commit per batch part follows in sequence" {
  check_pin debt.md "$RESOLVE_HEADING" 'Run the Quality Gate' 'one commit per batch part follows, in sequence, in `parts` order'
}

@test "the commit parts are the offer parts minus every member lost before the commit step" {
  check_pin debt.md "$RESOLVE_HEADING" 'Run the Quality Gate' 'minus every member lost before this step'
}

@test "a part with no survivor has no commit" {
  check_pin debt.md "$RESOLVE_HEADING" 'Run the Quality Gate' 'a part with no survivor has no commit'
}

@test "a split cluster's survivors stay one part" {
  check_pin debt.md "$RESOLVE_HEADING" 'Run the Quality Gate' "a split cluster's survivors stay one part"
}

@test "a cluster is one batch part and one commit" {
  check_pin debt.md "$RESOLVE_HEADING" 'Run the Quality Gate' 'A cluster is one batch part and one commit'
}

@test "implementation records each part's changed paths" {
  check_pin debt.md "$RESOLVE_HEADING" 'Implement all fixes in the unit' 'Before staging each part, record what it changed since the last stage'
}

@test "the recorded paths come from the working tree diff and the untracked files" {
  check_pin debt.md "$RESOLVE_HEADING" 'Implement all fixes in the unit' '`git diff --name-only` plus `git ls-files --others --exclude-standard`'
}

@test "each part's changes stay unstaged until its record" {
  check_pin debt.md "$RESOLVE_HEADING" 'Implement all fixes in the unit' 'no `git mv`, `git rm` or `git add` before its record'
}

@test "a part is staged only after its paths are recorded" {
  check_pin debt.md "$RESOLVE_HEADING" 'Implement all fixes in the unit' 'Then stage the paths (`git add -A -- <paths>`)'
}

@test "a path the gate changed joins the list of the part whose change caused it" {
  check_pin debt.md "$RESOLVE_HEADING" 'Run the Quality Gate' 'that no part recorded to the list of the part whose change caused it'
}

@test "the working tree is clean after the last part" {
  check_pin debt.md "$RESOLVE_HEADING" 'Run the Quality Gate' 'after the last part `git status --porcelain` must be empty'
}

@test "two batch parts that touch one file merge into one part" {
  check_pin debt.md "$RESOLVE_HEADING" 'Implement all fixes in the unit' 'merge this part into that earlier part'
}

@test "the closes-carrier sentences stay in the resolve section" {
  section="$(extract_section "$REFS/debt.md" "$RESOLVE_HEADING")"
  [ -n "$section" ]
  grep -qF -- 'closing keyword' <<<"$section"
  grep -qF -- 'No commit message on the branch carries' <<<"$section"
  grep -qF -- '`fixes` / `resolves`' <<<"$section"
  grep -qF -- 'A squash merge concatenates' <<<"$section"
  grep -qF -- 'sole carrier' <<<"$section"
}

@test "a revert comes first on a budget batch" {
  check_pin debt.md "$DROP_HEADING" 'Three corrections' 'a revert comes first, ahead of them'
}

@test "a dropped singleton's commit is reverted" {
  check_pin debt.md "$DROP_HEADING" "A dropped singleton's commit" "A dropped singleton's commit is reverted"
}

@test "a dropped cluster member's cluster commit is reverted with its siblings dropped alongside" {
  check_pin debt.md "$DROP_HEADING" "A dropped singleton's commit" "the cluster's siblings are dropped alongside it, since they share that commit"
}

@test "each dropped cluster member takes the three corrections" {
  check_pin debt.md "$DROP_HEADING" "A dropped singleton's commit" 'each dropped member takes the three corrections below'
}

@test "parts that touch one file revert together and drop alongside" {
  check_pin debt.md "$DROP_HEADING" "A dropped singleton's commit" 'so they revert together and every member of that commit is dropped alongside'
}

@test "a revert that conflicts is resolved by hand" {
  check_pin debt.md "$DROP_HEADING" 'A part'"'"'s commit normally reverts alone' 'the revert can conflict; resolve it by hand'
}

@test "a revert uses a Conventional Commits revert subject naming what was dropped" {
  check_pin debt.md "$DROP_HEADING" "The revert's subject" '`revert:` subject that names what was dropped'
}

@test "a member found security-class after its commit needs a history rewrite with a count-only pointer" {
  check_pin debt.md "$DROP_HEADING" 'found security-class after its commit' 'requires a history rewrite that removes the commit from the branch, force-pushed, and leaves a count-only pointer'
}

@test "every part dropped strips every claim and closes the draft pull request unmerged" {
  check_pin debt.md "$DROP_HEADING" '**Every part dropped.**' 'strip every member'"'"'s claim (correction 1 below), close an open draft pull request unmerged, report it'
}

@test "every part dropped ends the run through the cost record" {
  check_pin debt.md "$DROP_HEADING" '**Every part dropped.**' 'end the run through `## Cost record (run end)`, passing `--pr` only when one was opened'
}

@test "every part dropped follows the unmerged-ending release" {
  check_pin debt.md "$DROP_HEADING" '**Every part dropped.**' '`## Releasing the claim on an unmerged ending`'
}

@test "the cost record lists the every-part-dropped ending" {
  check_pin debt.md '## Cost record (run end)' 'Every batch part of a budget batch dropped' 'the draft pull request is closed unmerged'
}

@test "the guardrails list the budget batch as a user-chosen batch" {
  check_pin debt.md "$GUARD_HEADING" 'One fix unit per invocation' 'a budget batch the offer proposes and the user picks'
}

@test "the guardrails state both uses of the scorer's difficulty cost" {
  check_pin debt.md "$GUARD_HEADING" 'Difficulty feeds' "decides both the named-batch budget and the budget batch's eligibility"
}
