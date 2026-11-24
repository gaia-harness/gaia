#!/usr/bin/env bats
# Doc pins for the audit loop: the fix round and cross-remit sections of
# `wiki/concepts/Audit Round Procedure.md` (`#### The fix round: fixer,
# verifier, gate`, `#### Cross-remit findings`), and the branch checkpoint and
# audit loop unit sections of the runbook `wiki/concepts/PR Merge Workflow.md`
# (`#### The branch checkpoint`, `## Dispatch the audit loop unit`).
# `.claude/rules/pr-merge.md` makes the merge page an executed contract, so
# each pin below holds a sentence an orchestrator acts on: who edits during
# the loop, when a round makes no commit, and what a checkpoint selection does
# not do.
#
# Prose-to-prose only. Whether the fences in those sections run as written is
# doc-merge-workflow-fences.bats's subject; whether the scripts behave as the
# sentences say is each script's own suite.
#
# Sentence-scoped checks split a section on ". " after collapsing whitespace.
# A period inside a path or a section number has no space after it, so it
# never splits a sentence.
#
# Assertion style: .claude/rules/bats-assertions.md. `.gaia/tests/` is
# release-excluded and out of wiki-style.md's scope, so SPEC-090 UAT ids in
# the test names below are traceability, not shipped prose.

# The pinned sentences carry backticks as literal Markdown, so single quotes
# are the point.
# shellcheck disable=SC2016

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  PAGE="$ROOT/wiki/concepts/Audit Round Procedure.md"
  RUNBOOK="$ROOT/wiki/concepts/PR Merge Workflow.md"
  FIXROUND='^#### The fix round: fixer, verifier, gate'
  CHECKPOINT='^#### The branch checkpoint'
  CROSSREMIT='^#### Cross-remit findings'
  UNIT='^#### The audit loop unit'
  DISPATCH_UNIT='^## Dispatch the audit loop unit'
  UNIT_AGENT="$ROOT/.claude/agents/audit-loop-unit.md"
}

# section <start_ERE> [page]: the page (the round procedure unless <page> is
# given) from the heading matching <start_ERE> up to, excluding, the next H2,
# H3 or H4. Fails loudly on a heading that matches nothing, so a renamed
# heading never passes a scoped check vacuously.
section() {
  local extracted_section source_page="${2:-$PAGE}"
  extracted_section="$(awk -v start="$1" '
    $0 ~ start { found = 1; print; next }
    found && /^#{2,4} / { exit }
    found { print }
  ' "$source_page")"
  [ -n "$extracted_section" ] || {
    echo "section anchor '$1' matched nothing in $source_page" >&2
    return 1
  }
  printf '%s\n' "$extracted_section"
}

# unit_halves: the unit's shape on the round procedure followed by the main
# thread's half on the runbook, for the pins whose sentence lives on either.
unit_halves() {
  section "$UNIT" || return 1
  section "$DISPATCH_UNIT" "$RUNBOOK"
}

# sentences: stdin as one sentence per line.
sentences() {
  tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g' | sed 's/\. /.\
/g'
}

# hand_edit_sentences: the sentences of stdin that tell the main thread to
# make a repair itself.
hand_edit_sentences() {
  sentences | grep -iE '(orchestrator|main thread) (applies|makes|edits|fixes).*(repair|fix|edit)'
}

@test "UAT-001: the cross-remit section routes an in-scope repair to the fixer, never the orchestrator" {
  local section_text
  section_text="$(section "$CROSSREMIT")" || return 1
  grep -qF -- 'marks it `fix` in the round'"'"'s dispositions file and the fixer repairs it' <<<"$section_text" || return 1
  hand_edit_sentences <<<"$section_text" && return 1
  true
}

@test "UAT-010: a checkpoint selection records only through the pinned question, and Claude never types the line" {
  local section_text
  section_text="$(section "$CHECKPOINT" "$RUNBOOK")" || return 1
  grep -qF -- 'Selecting an option changes nothing until the human types that line' <<<"$section_text" && return 1
  sentences <<<"$section_text" | grep -qF -- 'records a selection as the answer only when the question came from the main thread of an interactive session' || return 1
  sentences <<<"$section_text" | grep -qF -- "the call's \`tool_input\` equals the pinned question exactly" || return 1
  sentences <<<"$section_text" | grep -qF -- 'Any other answer records nothing and leaves the state byte-identical' || return 1
  grep -qF -- 'Claude never types, writes, or simulates the line, and never writes the branch state file.' <<<"$section_text"
}

@test "a round whose staging stages nothing runs no gate and makes no commit" {
  local section_text
  section_text="$(section "$FIXROUND")" || return 1
  sentences <<<"$section_text" | grep -qF -- 'When the staging block stages nothing (`git -C <RESOLVED_ROOT> diff --cached --quiet` exits 0) and no fixer result is `fixed`, skip the gate and the commit, run the **Round check** below, and end the round as **Zero `fix` entries** above does.' || return 1
  sentences <<<"$section_text" | grep -qF -- 'A `fixed` result with nothing staged stops the round for a human, since the fixer claimed a repair the tree does not show.' || return 1
}

# --- the audit loop unit ----------------------------------------------------

# anchors_resolve <page> <agent>: every `#### ...` anchor the agent names
# resolves to exactly one heading line in the page. Derived from the agent
# file; an empty derivation is a failure, never a pass.
anchors_resolve() {
  local page="$1" agent="$2" anchors anchor count=0
  anchors="$(grep -oE '`#### [^`]+`' "$agent" | tr -d '`')"
  [ -n "$anchors" ] || {
    echo "no #### anchor derived from $agent" >&2
    return 1
  }
  while IFS= read -r anchor; do
    count=$((count + 1))
    [ "$(grep -cxF -- "$anchor" "$page")" -eq 1 ] || {
      echo "anchor does not resolve to exactly one heading: $anchor" >&2
      return 1
    }
  done <<<"$anchors"
  [ "$count" -ge 4 ] || {
    echo "derived only $count anchors from $agent" >&2
    return 1
  }
}

@test "every anchor the unit agent names resolves to exactly one heading" {
  anchors_resolve "$PAGE" "$UNIT_AGENT" || return 1
  grep -qxF -- '#### The audit loop unit' "$PAGE"
}

@test "the unit section maps every stop_reason and every deny class the agent classifies" {
  local section_text reason
  section_text="$(unit_halves)" || return 1
  for reason in clean window-end checkpoint-deny dispositions-check-failed needs-human member-wave-dirty failure; do
    grep -qF -- "\`$reason\`" <<<"$section_text" || { echo "stop_reason missing: $reason" >&2; return 1; }
  done
  grep -qF -- 'PreToolUse:Agent hook error: BLOCKED: ...' <<<"$section_text" || return 1
  grep -qF -- '`BLOCKED: audit checkpoint` maps to `checkpoint-deny`, `BLOCKED: audit window` to `window-end`, `BLOCKED: audit dispositions` to `dispositions-check-failed`, and any other `BLOCKED:` to `failure`' <<<"$section_text" || return 1
  grep -qF -- "audit-loop-bound.sh\`'s header owns the deny text" <<<"$section_text" || return 1
  grep -qF -- 'A unit that finds the Agent tool absent stops `needs-human` and its `stop_detail` names Claude Code 2.1.287 or later and the upgrade step (`claude update`, then relaunch the session).' <<<"$section_text" || return 1
  ! grep -qF -- 'nesting-''unavailable' <<<"$section_text" || return 1
  grep -qF -- 'audit-dispositions-check.sh check-all --root <RESOLVED_ROOT> --run-folder <RUN_FOLDER>' <<<"$section_text" || return 1
}

@test "UAT-007: the unit section maps member-wave-dirty to its own main-thread action and a dirty closing wave to the same stop" {
  local section_text
  section_text="$(unit_halves)" || return 1
  grep -qF -- '| `member-wave-dirty` | Asks the human what to do through `AskUserQuestion`, naming the wave'"'"'s members and the dirty paths from `stop_detail`' <<<"$section_text" || return 1
  sentences <<<"$section_text" | grep -qF -- 'a dirty tree after the closing wave stops the unit the same way.' || return 1
}

@test "the unit section never lets the unit merge, and a missing unit file stops for the human" {
  local section_text
  section_text="$(unit_halves)" || return 1
  sentences <<<"$section_text" | grep -qF -- 'It runs no `gh pr merge`, posts no `GAIA-Audit` status, writes no marker, edits no `CHANGELOG.md`, and never writes the loop state or `vetoes.json`.' || return 1
  sentences <<<"$section_text" | grep -qF -- 'A unit that returns with no `unit-<u>.json` stops the main thread for the human; it never falls back inline on its own.' || return 1
  grep -qF -- 'While a unit is available the main thread reads this page and does not read [[Audit Round Procedure]]' <<<"$(sentences <<<"$section_text" | tr '\n' ' ')" || return 1
}

@test "the clean-stop last guard is read-only and reads the branch's frozen snapshots" {
  local row
  row="$(grep -F -- 'audit-dispositions-check.sh check-all --root <RESOLVED_ROOT> --run-folder <RUN_FOLDER>` once more as a last guard' "$RUNBOOK")" || return 1
  grep -qF -- 'read-only: with no `--snapshot-dir` it re-grades each round from the branch'"'"'s frozen snapshots' <<<"$row" || return 1
  grep -qF -- 'it writes nothing' <<<"$row" || return 1
  grep -qF -- 'no snapshot directory)' <<<"$row" && return 1
  true
}

# digest_statement_passes <page>: rc 0 when the late worthiness statement
# folds nothing in, settling the test as a residual because its re-dispatch
# would be Full, and never says Light.
digest_statement_passes() {
  local statement
  statement="$(section '^#### Applying the audit.s own Minor findings' "$1" | grep -F -- 'A late worthiness verdict')" || return 1
  grep -qF -- 'folds nothing in' <<<"$statement" || return 1
  grep -qF -- 'recommends settling a branch test it would repair or delete as a residual' <<<"$statement" || return 1
  grep -qF -- 'recommends the repair' <<<"$statement" && return 1
  grep -qF -- 'Full under the Hard-Full floor' <<<"$statement" || return 1
  grep -qF -- 'Light' <<<"$statement" && return 1
  true
}

@test "a late worthiness verdict folds nothing in by default and recommends a residual: the statement says so and never says Light" {
  digest_statement_passes "$PAGE" || return 1
}

# in_round_worthiness_passes <page>: rc 0 when the fix round runs the
# worthiness step after a committing round, before returning to step 1, as an
# unattended caller whose step stop stops the unit.
in_round_worthiness_passes() {
  local fix_round
  fix_round="$(section "$FIXROUND" "$1" | sentences)" || return 1
  grep -qF -- 'On a round that committed, run the worthiness step below.' <<<"$fix_round" || return 1
  grep -qF -- 'Then return to step 1 on the new HEAD.' <<<"$fix_round" || return 1
  grep -qF -- 'After every round that committed, the window'"'"'s last included, and before the next member wave or the unit'"'"'s stop, the round'"'"'s orchestrator runs `.claude/skills/gaia/references/worthiness-step.md` `## The step`' <<<"$fix_round" || return 1
  grep -qF -- 'a `delete` settles as a residual' <<<"$fix_round" || return 1
  grep -qF -- 'stops the unit `needs-human`, naming it' <<<"$fix_round"
}

@test "the fix round judges a committing round's tests before the next member wave" {
  in_round_worthiness_passes "$PAGE"
}

@test "the veto paragraph disposes a vetoed key fix until satisfied, and the checkpoint never reaches a qualifying round" {
  local section_text
  section_text="$(section "$DISPATCH_UNIT" "$RUNBOOK")" || return 1
  sentences <<<"$section_text" | grep -qF -- 'A vetoed key is disposed `fix` until its veto is satisfied' || return 1
  sentences <<<"$section_text" | grep -qF -- 'A veto after a default stop reopens a round' || return 1
  sentences <<<"$section_text" | grep -qF -- 'A veto can also name a `refused-authored` `file` row, which is how that stop clears.' || return 1
  grep -qF -- 'A vetoed key is disposed `fix` from then on' <<<"$section_text" && return 1
  section_text="$(section "$CHECKPOINT" "$RUNBOOK")" || return 1
  grep -qF -- 'A round the default stop qualifies never reaches the checkpoint, and a grant does not suspend the stop.' <<<"$section_text"
}

# enforcement_draft_passes <page> <runbook>: rc 0 when the fixer may draft a
# vetoed enforcement-path repair, the verifier failure on it stops with no
# continuation, and the runbook shows the fixer's whole diff, asks the human
# with no recommendation after a plain-language explanation,
# offers Keep and Decline (Redo in place of Decline on a Critical or
# security-class key), and has Decline withdraw each veto through the script
# before restoring the tree.
enforcement_draft_passes() {
  local fix_round row
  fix_round="$(section "$FIXROUND" "$1" | sentences)" || return 1
  grep -qF -- 'unless the dispositions file names it in enforcement_paths_allowed or a fix entry on that path carries enforcement_draft: true' <<<"$fix_round" || return 1
  grep -qF -- 'a failure whose every error is `enforcement-path` on such an entry'"'"'s path gets no continuation: the edits stay uncommitted and the round stops `needs-human` with `enforcement-draft`' <<<"$fix_round" || return 1
  row="$(grep -F -- '| `dispositions-check-failed`, `needs-human`, `failure` |' "$2")" || return 1
  grep -qF -- 'then explain the change in plain language a reader with no harness knowledge can decide from, neutral, stating in this order what the guard is for in one line, whether the edit makes it stricter or looser (before versus after), which finding asked for it and what that finding said, and anything the edit touches beyond what the finding asked.' <<<"$row" || return 1
  grep -qF -- 'ask one `AskUserQuestion` that recommends nothing, its options in this order: `Keep` (run the Quality Gate, commit' <<<"$row" || return 1
  grep -qF -- 'show `git -C <RESOLVED_ROOT> status --short` and `git -C <RESOLVED_ROOT> diff`, every path the fixer touched,' <<<"$row" || return 1
  grep -qF -- 'and `Decline` (first run `record-residual --decision discard` for each named key, which removes its veto and records it as an accepted residual; once every key is recorded, restore every path shown' <<<"$row" || return 1
  grep -qF -- 'so when a named key'"'"'s finding is Critical or security-class (its `severity` and `security` in the round'"'"'s findings; `stop_detail` names neither) the second option is `Redo` in place of `Decline`; `Redo` also follows a `discard` refused on a key no round reports.' <<<"$row" || return 1
  grep -qF -- 'with that non-blank note as its reason, which becomes the veto'"'"'s direction' <<<"$row" || return 1
  grep -qE -- '`Hold`|`Commit`|`Discard`' <<<"$row" && return 1
  return 0
}

@test "a vetoed enforcement-path repair is drafted, stops uncommitted, and the human picks Keep or Decline after a plain explanation" {
  enforcement_draft_passes "$PAGE" "$RUNBOOK"
}
