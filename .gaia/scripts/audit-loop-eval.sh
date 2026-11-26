#!/usr/bin/env bash
# shellcheck shell=bash
#
# Audit loop evaluator: the single owner of the loop's round-count defaults,
# the allowance fold, the verdict and rubric-signal formulas, the gate
# decisions and the checkpoint recommendation. The PR Merge Workflow page and
# the hooks point here rather than restating any of them. The context line,
# the statusline bands and K (rounds per unit) are owned by
# context-checkpoint-lib.sh, sourced here. The signal block and the decision
# functions are implemented in audit-loop-signals-lib.sh, also sourced here;
# their formulas are the ones below. The allowance and gate decision, the
# finding set and round snapshot, and the CLI's reports are implemented in
# audit-loop-allowance-lib.sh, audit-loop-round-lib.sh and
# audit-loop-report-lib.sh, also sourced here.
#
# Dual-mode. Sourced (audit-loop-bound.sh), it defines functions only:
#   gaia_loop_evaluate_round <main-root> <state-json> <r> [<audited-root>]   round r's snapshot
#   gaia_loop_findings <main-root> <state-json> <r>     F(r)
#   gaia_loop_allowed <state-json>                      the round-count allowance
#   gaia_loop_decide <state-json> <r-snapshot-json>     `allow` or `deny <reason>`
#   gaia_loop_decide_unit, gaia_loop_decide_member      see DECISION
#   gaia_loop_knobs_initial                             knobs frozen at round 1
#   gaia_loop_context_config_initial <main-root>        line config frozen at round 1
#   gaia_loop_context_config_effective <main-root> <state-json>
# Run (the main thread), it is a read-only CLI: it never writes a file, never
# takes the state lock, never calls gaia_loop_write_state.
#   audit-loop-eval.sh findings|evaluate-round|brief|record-values|state-path|current-round
#                      |next-unit|unit-window|pinned-question|round-history
#                      |veto-state|reopened-round|accepted-keys --root <audited-root> [--round <r>]
# accepted-keys prints {key, lines} for each identity key a human accepted, [] with
# no loop state (gaia_loop_accepted_keys in audit-loop-stop-lib.sh).
# round-history prints one {round, tree, members, keys, counted_keys, closing, reopened,
# human_accept, human_accepted_keys} per recorded round (keys and counted_keys as identity
# keys, null when not stored; human_accept: closing, or an accept answering a checkpoint at
# round r-1 or r; human_accepted_keys: audit-accept-finding keys of a checkpoint at round r or earlier). veto-state prints audit-veto-lib.sh's
# {satisfied, unsatisfied, reviewers} for round r. reopened-round prints the latest
# round's number when it is reopened on HEAD's tree, else 0.
# unit-window prints `<unit> <start_round> <through_round> <closing>` for the
# latest unit; closing is `true` when an accept admitted it: the human stopped
# fixing, so audit-loop-unit runs no fixer in it.
# record-values adds optional `light` (post-clearance light reviews) and `quick`
# (merge-base clears, so a quick clear never also counts as light) objects of
# per-member counts, read from the branch's light-review ledger; each is left
# out when it has no positive count, and `total` never includes either. `quick`
# also omits any member that has a full round in `members`, since that member
# was not cleared by a quick review alone. It also adds a `review` object from
# audit-code-review-record.sh publish-values (a missing record reads `no record`
# once a round exists), and leaves the key out when that prints nothing. With a
# recorded round it adds `budget_grants`, the units the autonomy budget spent on
# the branch or its pull request (gaia_audit_budget_count), left out at zero;
# `grants` counts human answers only.
# Exit 0 ok, 2 usage or no recorded round (unit-window: no unit;
# pinned-question: no pending pinned question), 4 detached HEAD, 5 corrupt
# state, an unreadable vetoes.json, or a branch that is not keyable, 6 jq or
# git missing.
#
# DEFAULTS. Checkpoint round 6, grant 3, hard cap 10. The round-count
# checkpoint decides only when no fresh context reading exists; the context
# line is the primary gate. 6 is unit-aligned (two units of 3), and in the
# round distribution measured when this was written 6.7% of branches needed
# more than 5 rounds and 1.8% more than 6, so it interrupts only the long tail;
# the signals below catch non-convergence earlier. A grant of 3 is the
# smallest that lets both evidence windows below see fresh rounds before the
# next checkpoint. The cap: a unit admitted below round 10 ends at round 10,
# and past it every unit needs a human answer to the checkpoint the cap pins,
# whatever the context line or the fold says.
#
# KNOBS. GAIA_AUDIT_CHECKPOINT_ROUND and GAIA_AUDIT_GRANT_ROUNDS remain, as
# lower-only knobs for the round-count fallback only, integers 1..99; anything
# else is ignored with a stderr note. At round 1 the bound hook freezes them
# into `history.knobs`, each capped at its default: a raised value is never
# honoured, because `.claude/settings*.json` `env` is editable by the session
# the bound exists to stop. Afterwards a live checkpoint value may only lower
# the frozen one, and only while no answer is recorded. A branch frozen at the
# old checkpoint 5 keeps 5. The context line has its own override in
# context-checkpoint-lib.sh; its config values (never a token count) are
# frozen into `history.context_config`, ask_tokens as the override's clamped value
# and the window share at the lib default, and the effective config is the
# per-field min of that frozen value and the live override, so a lowering
# applies live and a raise waits for the next branch. ask_tokens 0 is the
# checkpoint off, the loosest value: a live 0 never lifts a frozen line, and a
# frozen 0 takes the live value (removing the key or setting a number re-arms
# the bound on that branch). A branch with no frozen config reads the initial one.
#
# ALLOWANCE. base = the frozen checkpoint round (lowered as above). Answers
# fold in order: a grant of n answering the checkpoint at round g sets
# allowed = g + n; an accept answering the checkpoint at round c sets
# allowed = c + 1 and makes that next round the closing round. used = recorded
# rounds, every verdict counted (an unknown round included, so deleting a
# sidecar never buys a round). The fold is uncapped (a grant of 10 at round 5
# folds to 15): the hard cap is a decision rule, applied below.
#
# DECISION. No decision function reads a file: the bound hook passes the
# context reading (exactly what gaia_context_read printed) and the effective line
# config. s = used + 1; k = K; <eligible> is the snapshot's accept_eligible (false
# with no snapshot). The order of the steps is the security property. Enriching,
# stalled, nitpicky and small-tail deny nowhere with stop_override true (the hook
# adds it in memory, see DEFAULT STOP), nor in the unit and member decisions in a
# grant window (latest unit admitted on a grant, no checkpoint since, through_round
# >= s): a grant of K buys up to K rounds. stop_override also makes gaia_loop_decide
# skip its allowance and verdict steps, and step 6 allow `fallback s min(s+k-1, 10)`.
#   gaia_loop_decide (a new-tree dispatch outside the unit protocol): deny
#   `cap` when used >= 10; deny `allowance` when used >= allowed; else deny
#   `stalled` or `enriching` when that is round r = used's verdict and no
#   answer exists for a checkpoint at round >= r; else allow.
#   gaia_loop_decide_unit, first match wins:
#     1. used >= 10: the latest checkpoint's unconsumed answer (as in step 3)
#        admits one unit, a grant `allow grant s s+k-1` and an accept `allow
#        accept s s`; with none, `deny cap <eligible> true`.
#     2. a denying signal not lifted above, with no checkpoint at round >= used
#        answered: `deny rubric:<signal> <eligible> false`, first in SIGNALS order.
#     3. the latest checkpoint is answered and its index is greater than the
#        latest unit's after_checkpoint (or no unit exists), or the latest answer is an
#        accept whose closing round is unrecorded (gaia_loop_next_closing): a grant gives `allow grant s min(s+k-1, 10)`,
#        an accept `allow accept s s`; else a grant window gives `allow grant s min(s+k-1, through_round)`.
#     4. the latest answer is an accept and a round is recorded after the
#        checkpoint it answers (its closing round is spent): `deny fallback
#        <eligible> false`, whatever the reading. An accept never re-arms the loop.
#     5. a `fresh <tokens> <window>` reading with ask_tokens above 0: tokens >=
#        the line computed against that reading's own window denies `context
#        <eligible> false`; else `allow context s min(s+k-1, 10)`.
#     6. any other reading, or ask_tokens 0: the fallback fold, `deny fallback <eligible> false`
#        when used >= allowed, else `allow fallback s min(s+k-1, 10, allowed)`.
#   gaia_loop_decide_member, in a unit: used >= 10 denies `cap` first unless
#   the latest unit runs past round 10 (an answer admitted it there); then
#   the latest unit's through_round must reach s, else `deny window`; then a
#   denying signal unanswered denies as in step 2; else `allow`. A member
#   dispatched outside a unit is judged by gaia_loop_decide_unit with k = 1, a
#   fail-safe bound on a stray direct dispatch, not a supported way to run
#   the loop.
#   A window can start off a 3-round boundary after a unit stops early;
#   nothing here assumes alignment.
#
# VERDICTS for round r, first match wins:
#   unknown    a dispatched member left no readable findings sidecar for the
#              round; A(r) = null. Missing evidence is never quiet.
#   quiet      A(r) = 0. A stop heuristic only: the merge page's own judgment
#              of what this change authored decides the disposition.
#   enriching  r >= 3, r >= g + 1, A(r-1) non-null, and some entry counted in
#              A(r) has an identity key absent from round r-1's keys and a
#              line inside a new-side hunk of `diff -U0 -M tree_{r-1} tree_r`.
#   stalled    r >= 3, r >= g + 2, A(r-2), A(r-1), A(r) non-null,
#              A(r-2) >= 1, A(r-1) >= A(r-2) and A(r) >= A(r-1). A quiet
#              round resets the window: a series that sits at zero and then
#              reports one finding (0, 0, 1) is convergence, not a stall.
#   continue   otherwise.
# g is the round of the checkpoint the latest grant answered (0 when none), so
# a grant always buys one round of fresh evidence before enriching and two
# before stalled. A(r-1) and A(r-2) and round r-1's keys are read from the
# stored snapshots, never recomputed: each snapshot keeps its own merge base.
#
# SIGNALS for round r, each independent, in this order:
#   cap           r >= 10.
#   quiet         the verdict is quiet. The one signal that never denies: the
#                 loop ends on its own.
#   enriching     the verdict is enriching.
#   stalled       the verdict is stalled.
#   nitpicky      r >= 6, and A(r) and A(r-1) are both non-empty with every
#                 entry of each severity minor.
#   reintroduced  r >= 3, A(r), A(r-1), A(r-2) non-null, and any of: a key of
#                 A(r-2) absent from A(r-1), which ran its member, and back in
#                 A(r); a triple
#                 (member, finding_class, path) of A(r) counted in an earlier
#                 round i with a gap, a round j, i < j < r, that ran the member
#                 and did not count it; a triple in all three whose line set
#                 gains a line each round (it moved); a triple of A(r) disposed
#                 fix in some dispositions-<k>.json, k < r, at any line.
#   small-tail    r >= 6, 1 <= A(r) <= 2, no A(r) entry is severity critical,
#                 A(r-1) non-null and A(r) >= A(r-1) (no progress last round).
# gaia:maintainer-only:start
#   waiver-drift  maintainer repo only (<main>/.claude/rules/maintainers/
#                 harness-triage-threshold.md exists), r >= 2, and in each of
#                 rounds r and r-1 at least half of F's entries (raw_count > 0)
#                 are disposed waive-out-of-scope with basis triage-threshold
#                 in that round's own dispositions file (waived_count).
# gaia:maintainer-only:end
# accept_eligible: some signal holds, no A(r) entry is severity critical or
# security true, the verdict is not unknown, and no stored snapshot a signal
# reads is legacy. accept_reasons: exactly the signals that hold. Severity is
# the sidecar vocabulary: critical, major, minor. An entry's security reads true unless the sidecar holds the
# boolean false (absent or non-boolean reads true); cross_remit is true only
# when the sidecar holds true. A(r-1), A(r-2) and their counted_keys,
# raw_count and waived_count come from the stored snapshots, never
# recomputed. A stored snapshot without counted_keys predates the signals:
# nitpicky, reintroduced, small-tail and waiver-drift stay off where they need
# it, and accept_eligible is false.
#
# DEFAULT STOP. S = A(r)'s keys minus honored triage marks (audit-triage-lib.sh)
# and cross-remit entries. default_stop holds when all of: 3 <= r <= 9; S
# non-empty; every F(r) entry but an honored mark is severity minor and
# security false; every stored snapshot of rounds 1..r-1 has counted_keys;
# reintroduced false; the verdict not unknown; A(r), A(r-1), A(r-2) non-null;
# every member's review_bases reason is member-clearance, member-refusal or
# team-signal; each member has an earned marker for its digest at round r's
# tree; no veto is unsatisfied (audit-veto-lib.sh). default_stop_keys is S when
# it holds, else []. stop_override, never stored, is default_stop with no fix
# on an S key in round r's dispositions file.
#
# FINDING SET AND A(r). F(r): for each member of round r, the newest
# `*.<raw_branch_slug>.<member>.findings.json` under <MAIN>/.gaia/local/audit/
# newer than the round's stamp and, when the round's baseline-<r>.json exists,
# not newer than it (a later sidecar is the fixer's era, never evidence). An
# entry is branch-authored when its path is in `diff --name-only -M
# merge_base_r tree_r` and its line is null or 0 or inside a new-side hunk of
# `diff -U0 -M merge_base_r tree_r`; a row with an invalid path or line, or a
# merge base that cannot be computed, counts as authored (fail closed: more
# counted, never fewer). A(r) = authored entries minus identity keys
# (member, finding_class, path, line) disposed accept-residual,
# waive-out-of-scope, file or divert in any dispositions-<k>.json with k < r, except
# a key listed in <RUN_FOLDER>/vetoes.json with effective_from_round <= r,
# which stays counted whatever was disposed. An absent vetoes.json vetoes
# nothing; an unreadable one fails the evaluation, since dropping a veto
# would count fewer findings.
#
# RECOMMENDATION (brief): continue -> grant, unknown -> grant,
# enriching -> accept, quiet -> accept, stalled -> stop, except that a stalled
# round where small-tail holds and the snapshot is accept_eligible -> accept
# (what remains is a tail the evaluator already judges acceptable, and stop
# would leave the PR open over it); at a pending checkpoint whose trigger is
# context, grant unless a denying signal holds. Any accept is a grant instead
# unless the snapshot is accept_eligible and an Accept closing round could end
# clean at HEAD: no veto open after the latest round, and every member owed
# a review of the branch (the resolve-audit-members.sh set plus the latest
# round's members) holds an earned marker or a refusal for its digest at
# HEAD's tree (gaia_loop_accept_blockers in audit-loop-stop-lib.sh; the brief
# prints its accept_blockers).
# Spend is shown as information only and never changes any other field.

_GAIA_LOOP_EVAL_DIRECTORY="${BASH_SOURCE[0]%/*}"
[ "$_GAIA_LOOP_EVAL_DIRECTORY" = "${BASH_SOURCE[0]}" ] && _GAIA_LOOP_EVAL_DIRECTORY="."
# shellcheck source=/dev/null
. "$_GAIA_LOOP_EVAL_DIRECTORY/audit-loop-state-lib.sh"
# A missing sibling must fail the source: the bound hook reads a failed source
# as a lib-load deny, while a silent miss would leave the gate functions
# undefined.
# shellcheck source=/dev/null
. "$_GAIA_LOOP_EVAL_DIRECTORY/context-checkpoint-lib.sh" || return 6 2>/dev/null || exit 6
# shellcheck source=/dev/null
. "$_GAIA_LOOP_EVAL_DIRECTORY/audit-loop-signals-lib.sh" || return 6 2>/dev/null || exit 6
# shellcheck source=/dev/null
. "$_GAIA_LOOP_EVAL_DIRECTORY/audit-triage-lib.sh" || return 6 2>/dev/null || exit 6
# shellcheck source=/dev/null
. "$_GAIA_LOOP_EVAL_DIRECTORY/audit-veto-lib.sh" || return 6 2>/dev/null || exit 6
# shellcheck source=/dev/null
. "$_GAIA_LOOP_EVAL_DIRECTORY/audit-loop-stop-lib.sh" || return 6 2>/dev/null || exit 6
# shellcheck source=/dev/null
. "$_GAIA_LOOP_EVAL_DIRECTORY/audit-loop-allowance-lib.sh" || return 6 2>/dev/null || exit 6
# shellcheck source=/dev/null
. "$_GAIA_LOOP_EVAL_DIRECTORY/audit-loop-round-lib.sh" || return 6 2>/dev/null || exit 6
# shellcheck source=/dev/null
. "$_GAIA_LOOP_EVAL_DIRECTORY/audit-loop-report-lib.sh" || return 6 2>/dev/null || exit 6
# shellcheck source=/dev/null
. "$_GAIA_LOOP_EVAL_DIRECTORY/audit-budget-lib.sh" || return 6 2>/dev/null || exit 6

_GAIA_LOOP_CHECKPOINT_DEFAULT=6
_GAIA_LOOP_GRANT_DEFAULT=3
# usage.sh reads every ledger; a slow read must never hold up the checkpoint.
_GAIA_LOOP_SPEND_TIMEOUT=5

_gaia_loop_usage() {
  printf 'usage: audit-loop-eval.sh findings|evaluate-round|brief|record-values|state-path|current-round|next-unit|unit-window|pinned-question|round-history|veto-state|reopened-round|accepted-keys --root <audited-root> [--round <r>]\n' >&2
  return 2
}

_gaia_loop_cli() {
  local subcommand="${1-}" root="" round="" branch_key main file state exit_status used subcommand_output budget_key_line
  local -a budget_keys
  [ $# -gt 0 ] && shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --root) [ $# -ge 2 ] || { _gaia_loop_usage; return 2; }; root="$2"; shift 2 ;;
      --round) [ $# -ge 2 ] || { _gaia_loop_usage; return 2; }; round="$2"; shift 2 ;;
      *) _gaia_loop_usage; return 2 ;;
    esac
  done
  case "$subcommand" in
    findings | evaluate-round | brief | record-values | state-path | current-round | next-unit | unit-window | pinned-question | round-history | veto-state | reopened-round | accepted-keys) ;;
    *) _gaia_loop_usage; return 2 ;;
  esac
  case "$root" in /*) ;; *) printf 'audit-loop-eval: --root must be an absolute path\n' >&2; return 2 ;; esac
  command -v jq >/dev/null 2>&1 || { printf 'audit-loop-eval: jq is required and was not found on PATH\n' >&2; return 6; }
  command -v git >/dev/null 2>&1 || { printf 'audit-loop-eval: git is required and was not found on PATH\n' >&2; return 6; }
  exit_status=0
  branch_key="$(gaia_loop_key "$root")" || exit_status=$?
  case "$exit_status" in
    0) ;;
    4) printf 'audit-loop-eval: detached HEAD at %s has no branch key\n' "$root" >&2; return 4 ;;
    6) printf 'audit-loop-eval: git is required and was not found on PATH\n' >&2; return 6 ;;
    *) printf 'audit-loop-eval: the branch at %s is not keyable\n' "$root" >&2; return 5 ;;
  esac
  main="$(gaia_resolve_main_root "$root" 2>/dev/null)" || { printf 'audit-loop-eval: cannot resolve the main checkout of %s\n' "$root" >&2; return 2; }
  file="$(gaia_loop_state_file "$main" "$branch_key")"
  if [ "$subcommand" = state-path ]; then printf '%s\n' "$file"; return 0; fi
  exit_status=0
  state="$(gaia_loop_read_state "$file")" || exit_status=$?
  case "$exit_status" in
    0) ;;
    1)
      case "$subcommand" in
        current-round | reopened-round) printf '0\n'; return 0 ;;
        round-history | accepted-keys) printf '[]\n'; return 0 ;;
        next-unit) printf '1 1\n'; return 0 ;;
        # A first-dispatch quick review needs no earlier full clearance, so the
        # ledger can hold a clear while no round exists. This branch is reached
        # when no unit was admitted; a quick-only unit normally has state with an
        # admitted unit and no rounds.
        record-values)
          subcommand_output="$(_gaia_loop_with_review_counts "$root" '{"total":0,"members":{},"grants":0}')"
          _gaia_loop_with_review_object "$root" "$(gaia_loop_run_directory "$main" "$branch_key")" 0 "" "$subcommand_output"
          return 0
          ;;
      esac
      printf 'audit-loop-eval: no recorded round for %s\n' "$branch_key" >&2
      return 2
      ;;
    6) printf 'audit-loop-eval: jq is required and was not found on PATH\n' >&2; return 6 ;;
    *) printf 'audit-loop-eval: corrupt state file %s\n' "$file" >&2; return 5 ;;
  esac
  used="$(printf '%s' "$state" | jq -r '.history.rounds | length')"
  case "$subcommand" in
    current-round) printf '%s\n' "$used"; return 0 ;;
    next-unit)
      printf '%s' "$state" | jq -r '"\(((.history.units // []) | length) + 1) \((.history.rounds | length) + 1)"'
      return 0
      ;;
    unit-window)
      subcommand_output="$(printf '%s' "$state" | jq -r '(.history.units // []) | last
        | if . == null then empty else "\(.unit) \(.start_round) \(.through_round) \(.admitted_on == "accept")" end')"
      [ -n "$subcommand_output" ] || { printf 'audit-loop-eval: no unit recorded for %s\n' "$branch_key" >&2; return 2; }
      printf '%s\n' "$subcommand_output"
      return 0
      ;;
    pinned-question)
      subcommand_output="$(gaia_loop_pending_checkpoint "$state" | jq -c 'select(.question != null) | .question')"
      [ -n "$subcommand_output" ] || { printf 'audit-loop-eval: no pending pinned question for %s\n' "$branch_key" >&2; return 2; }
      printf '%s\n' "$subcommand_output"
      return 0
      ;;
    record-values)
      subcommand_output="$(printf '%s' "$state" | jq -c '{total: (.history.rounds | length),
        members: (reduce .history.rounds[] as $round_entry ({}; reduce ($round_entry.members[]) as $member (.; .[$member] += [$round_entry.tree]))
                  | map_values(unique | length) | to_entries | sort_by(.key) | from_entries),
        grants: ([.allowance.answers[] | select(.kind == "grant")] | length)}')" || return 1
      budget_keys=()
      while IFS= read -r budget_key_line; do budget_keys+=("$budget_key_line"); done < <(gaia_audit_budget_keys "$state" "$branch_key")
      subcommand_output="$(printf '%s' "$subcommand_output" | jq -c --argjson budget_grants "$(gaia_audit_budget_count "$main" ${budget_keys[@]+"${budget_keys[@]}"})" \
        'if $budget_grants > 0 then . + {budget_grants: $budget_grants} else . end')" || return 1
      subcommand_output="$(_gaia_loop_with_review_counts "$root" "$subcommand_output")"
      _gaia_loop_with_review_object "$root" "$(gaia_loop_run_directory "$main" "$branch_key")" "$used" \
        "$(printf '%s' "$state" | jq -r '(.pr // 0) | if . > 0 then . else empty end')" "$subcommand_output"
      return 0
      ;;
    brief) _gaia_loop_brief "$root" "$main" "$state"; return $? ;;
    round-history) gaia_loop_round_history "$state"; return $? ;;
    accepted-keys) gaia_loop_accepted_keys "$main" "$state" "$(_gaia_loop_git -C "$root" rev-parse 'HEAD^{tree}' 2>/dev/null)"; return $? ;;
    reopened-round)
      subcommand_output="$(_gaia_loop_git -C "$root" rev-parse 'HEAD^{tree}' 2>/dev/null)" || subcommand_output=""
      printf '%s' "$state" | jq -r --arg head_tree "$subcommand_output" \
        '.history.rounds | if (last | .reopened == true and $head_tree != "" and .tree == $head_tree) then length else 0 end'
      return $?
      ;;
  esac
  [ -n "$round" ] || round="$used"
  if ! gaia_loop_is_uint "$round" || [ "$round" -lt 1 ] || [ "$round" -gt "$used" ]; then
    printf 'audit-loop-eval: no recorded round %s for %s\n' "$round" "$branch_key" >&2
    return 2
  fi
  if [ "$subcommand" = findings ]; then gaia_loop_findings "$main" "$state" "$round"; return $?; fi
  if [ "$subcommand" = veto-state ]; then
    # Round r's keys: the stored snapshot's, else F(r) read afresh.
    subcommand_output="$(printf '%s' "$state" | jq -c --argjson round "$round" '.history.rounds[$round - 1].snapshot.keys? // empty')"
    [ -n "$subcommand_output" ] || subcommand_output="$(_gaia_loop_raw_findings "$main" "$state" "$round" | jq -c '.entries | map([.member, .finding_class, .path, .line]) | unique')" || return 2
    if subcommand_output="$(gaia_veto_keys_state "$main" "$branch_key" "$state" "$round" "$subcommand_output" "$root")" && gaia_veto_reviewers "$main" "$branch_key" "$root" "$subcommand_output"; then return 0; fi
    printf 'audit-loop-eval: %s/vetoes.json is unreadable or malformed\n' "$(gaia_loop_run_directory "$main" "$branch_key")" >&2; return 5
  fi
  gaia_loop_evaluate_round "$main" "$state" "$round" "$root"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -uo pipefail
  _gaia_loop_cli "$@"
  exit $?
fi
