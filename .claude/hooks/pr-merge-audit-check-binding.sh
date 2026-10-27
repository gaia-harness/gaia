#!/usr/bin/env bash
# pr-merge-audit-check-binding.sh: the command binding: whether the gated merge names the pull request its clearance is for, and the decisive-empty rule for record-cleared permits.
#
# One contiguous span of the merge gate, moved here unchanged.
# pr-merge-audit-check.sh sources it from its own directory at the point the
# span stood, so it runs in the same order over the same globals; it is never
# run on its own. $root, the main checkout every marker path joins onto, is
# the one the parent derives through main-root-lib.sh (gaia_resolve_main_root).
#
# Bash 3.2 compatible (macOS-default bash).

# shellcheck disable=SC2034,SC2154  # the gate globals cross files: the parent and the other siblings set and read them

# gate_command_names_the_record_pr: is the pull request the gated `gh pr merge`
# names the same one whose record the conjuncts around this were checked
# against? The record comes from `gh pr view` with no number, which describes
# the CURRENT BRANCH's pull request, so without this the record conjuncts prove
# only "this checkout is on a pull request", never "on the one being merged".
#
# Everything this reads about the command comes from the shared scanner in
# repo-scope.sh, never from a parser written here, and that is the whole design
# rather than a convenience. Two hand-rolled readings were tried and both were
# wrong in the permitting direction. Skipping options by their leading `-`
# alone reads a value-taking flag's SEPARATED value as the positional, so
# `gh pr merge --body <record-number> <other-number>` compared equal to the
# record and permitted a merge of <other-number>; `gh pr merge` has six such
# flags. Counting occurrences of the literal `gh pr merge` phrase to prove no
# second merge rides along missed every spelling that breaks the literal run of
# characters, `gh pr "merge" <n>` and a line continuation inside the verb among
# them. Both were demonstrated against this hook rather than argued.
#
# The scanner tokenizes the way the shell does, so it answers two of the three
# questions exactly: which reference the merge names, and whether a separator
# or a comment put another command beside it. The third, whether an EXPANSION
# smuggled one in, is not a question about words, so no word-level tokenizer
# answers it; this function rules it out lexically instead, by admitting only
# the characters a merge invocation needs and denying every other byte. Every
# abstention denies.
gate_command_names_the_record_pr() {
  # The scanner is normally already loaded, from the repo-scope source near the
  # top of this hook. That source is cwd-relative, so it can miss from a
  # non-root cwd; reload from this hook's OWN on-disk location and deny if the
  # scanner still cannot be had. A relaxation that cannot read the command it
  # is relaxing has nothing to relax on.
  if ! type gaia_scan_gh_merge >/dev/null 2>&1; then
    [ -n "$_library_directory" ] && [ -f "$_library_directory/repo-scope.sh" ] || return 1
    # shellcheck source=/dev/null
    . "$_library_directory/repo-scope.sh" || return 1
    type gaia_scan_gh_merge >/dev/null 2>&1 || return 1
  fi

  # Abstains unless the tool call's FIRST command is the merge and every flag
  # on it is a shape the scanner models.
  gaia_scan_gh_merge "$command_line" || return 1

  # And no SEPARATOR puts a second command beside it. The scanner sets this
  # while reading the same command the call above just read, so it is that
  # read's own answer rather than a second pass: 0 means no separator and no
  # comment closed the merge.
  #
  # The allowlist above subsumes this today, since every separator character is
  # outside its set, which means no mutation of this line alone can red a test
  # while that arm stands. It is kept anyway, and the reason is stated rather
  # than left to be rediscovered: the two conjuncts answer different questions,
  # one lexical and one structural, and a future widening of the character set
  # (to admit a quoted subject, say) must not silently take the separator
  # guarantee with it.
  [ "$GAIA_FIRST_COMMAND_CLOSED" -eq 0 ] || return 1

  # And no EXPANSION runs one either. That question is not about words, so the
  # flag above does not answer it: a substitution is ordinary word text to a
  # tokenizer that models words, which reaches the end of the string having
  # found no separator while the shell runs the payload first, before the
  # permitted merge.
  #
  # This is an ALLOWLIST rather than a list of substitution spellings, and the
  # difference is the whole point. Two attempts to name the dangerous spellings
  # were both incomplete, and the second was incomplete in a way nobody could
  # have enumerated their way out of: which text makes a shell run a command is
  # a property of the shell running this tool call and of its version, not of
  # any fixed set of sequences. zsh, this platform's default, has `=(...)`;
  # bash gained `${ ...; }` in 5.3; the next release adds whatever it adds. So
  # the character set below is what a pull-request reference, a flag and a
  # branch or URL need, and every other byte denies, including `$`, a backtick,
  # every bracket, both quotes, and every separator. It cannot be outrun by a
  # spelling nobody has thought of, because it never asks what the spelling
  # means.
  #
  # Blunt in the deny direction only: a merge carrying a quoted subject denies
  # and costs a marker requirement, which is this arm's whole downside.
  case "$command_line" in
    *[!A-Za-z0-9_\ /.,:@=+-]*) return 1 ;;
  esac

  # No positional at all: the command targets the current branch, which is the
  # branch the record was read for, so the record conjuncts already bind it.
  [ -n "$GAIA_GH_MERGE_REFERENCE" ] || return 0
  # A bare number is the only spelling this gate can confirm without a second
  # network read. A branch name or a URL denies rather than resolve one: this
  # arm is a relaxation, so an unconfirmable target must not clear it.
  case "$GAIA_GH_MERGE_REFERENCE" in
    *[!0-9]*) return 1 ;;
  esac
  # The record is needed from HERE DOWN and nowhere above it, so resolve it at
  # the point of first need rather than leaning on a caller having done it.
  # Two things follow, and both are the point. The predicate is self-sufficient,
  # so a new call site cannot forget the read and get a permanent "no record"
  # answer that reads as a deny for a structural reason rather than a real one.
  # And the read stays LAZY where laziness is worth something: every return
  # above this line, a command naming no pull request and one naming a target
  # this gate cannot confirm among them, answers from the command's own bytes
  # and never reaches the network. The memo inside resolve_pr_record makes this
  # free for the callers that already made the read.
  resolve_pr_record
  [ -n "$pr_record_number" ] || return 1
  [ "$GAIA_GH_MERGE_REFERENCE" = "$pr_record_number" ]
}

# gate_permit_binds_to_named_pr: the last conjunct on every permit this gate
# issues off a CLEARANCE signal, as opposed to off the pull-request record.
#
# A clearance proves a property of THIS CHECKOUT's content: a member's own
# branch-own digest marker, a GAIA-Audit commit
# status on HEAD's sha. Not one of them reads the pull-request reference the
# gated command carries, so on a branch whose dispatched members have all
# cleared, `gh pr merge <other-number>` used to be permitted and merged a pull
# request nothing here audited.
#
# It sits at the two PERMIT SITES rather than inside the three signals, and
# that placement is what makes it complete rather than merely correct. A
# clearance becomes a merge at exactly two places, the legacy single-signal
# gate and the AND-aggregator, and every route through both, the frontend
# signals and each specialized member's own marker alike, passes through one of
# them. Binding the three signals individually would leave the specialized
# members' markers reachable and unbound, and closing that would take more code
# than this does, not less. The record-based bypasses each keep their own call:
# they need the answer to decide whether they fire at all, this needs it to
# decide whether a decision to permit may stand, and the memo makes the second
# ask free.
#
# WHAT IT COSTS, since the comment this replaces treated the cost as decisive.
# The predicate reaches the network through resolve_pr_record, which the
# clearance path otherwise never does. That read is now lazy to the point of
# first need, so a merge naming no pull request still decides entirely from
# local files; the prescribed `gh pr merge <N>` spelling does name one and pays
# one memoized `gh pr view`. The reason that is affordable is that the command
# being gated is itself an unbounded network round-trip: a permit issued
# network-free is a permit for an operation that immediately makes its own
# network calls, so keeping this path local moves a stall a few milliseconds
# later rather than avoiding one. The read is unbounded exactly as every other
# `gh` read in this hook is; bounding this one alone would buy nothing while
# the merge it clears stays unbounded.
#
# Prints the deny JSON and returns 1 when the binding does not hold; returns 0
# silently when it does.
gate_permit_binds_to_named_pr() {
  gate_command_names_the_record_pr && return 0

  local named record reason
  # Four of the predicate's five failure arms return ABOVE its own record read,
  # so reaching here says nothing about whether the record was ever queried.
  # Without this call the reason below would print an unread empty field as a
  # resolved negative, telling an operator whose pull request is perfectly
  # healthy that this checkout has no record: they go chase gh auth instead of
  # the command spelling that actually denied. resolve_pr_record memoizes, and
  # this is a deny path, so the read costs nothing the refused merge would not
  # have cost anyway, and it buys a reason that can name the real number.
  resolve_pr_record
  named="${GAIA_GH_MERGE_REFERENCE:-}"
  record="${pr_record_number:-}"

  local unreadable=0
  if [ -z "$named" ]; then
    # No positional means gh's current-branch default, which the conjunct above
    # permits outright, so reaching here without one means the command itself
    # was unreadable: not the first command in its tool call, carrying a flag
    # shape the scanner declines to model, a separator or comment putting a
    # second command beside it, or a byte outside the small set a merge needs.
    unreadable=1
    named="<unreadable>"
  fi

  # The predicate abstains for two materially different reasons and one message
  # cannot serve both. When the reference the command names IS the record's,
  # the target was never the problem: the gate could not read the command
  # exactly, so it abstained above the comparison. Telling that operator the
  # merge "does not name the pull request that clearance is for" is false, and
  # the repair that wording prescribes, name the record's number, is the exact
  # command that just denied. Split the headline and the remedy; the closing
  # paragraphs are true of both arms and stay shared.
  #
  # The spelling arm is the one reached in practice. A quoted `--subject` or
  # `--body` is an ordinary thing to type, while naming another pull request by
  # number is the rare case, so the message must not be written for the rare
  # one alone.
  local spelling_shared
  spelling_shared="The merge must be the first command in its tool call with nothing beside it,
and a separator, a comment, a flag shape the command scanner declines to model,
a branch name or URL in place of a number, or any byte outside the small set a
merge invocation needs each deny on their own. A quoted flag value is the common
case: drop it, or set it on the pull request before merging."

  # Which arm, and the sentinel belongs on the SPELLING side. An unreadable
  # command named no target the gate could read, so it never established a
  # wrong one; telling that operator the merge "does not name the pull request
  # that clearance is for" points at a target that was probably right, and the
  # mismatch remedy then offers them the no-number spelling they may have just
  # used. `<unreadable>` never equals a record, so keying on the comparison
  # alone would silently route it to the mismatch arm.
  local head_line names_line repair_lead
  if [ "$unreadable" -eq 1 ] || { [ -n "$record" ] && [ "$named" = "$record" ]; }; then
    if [ "$unreadable" -eq 1 ]; then
      head_line="PR merge gate: HEAD ${sha:0:12} is cleared, but this gate cannot read the merge command well enough to tell which pull request it targets."
      names_line="  Merge names:      no target this gate could read"
      repair_lead="To unblock, respell the merge. The target was never established, so this says
nothing about which pull request you meant."
    else
      head_line="PR merge gate: HEAD ${sha:0:12} is cleared and the merge names the right pull request (${record}), but the command is not one this gate can read exactly."
      names_line="  Merge names:      ${named}, which is this checkout's own pull request"
      repair_lead="To unblock, respell the merge; naming ${record} again is the one repair that
cannot work, because the number was never the problem."
    fi

    reason="${head_line}

  Clearance:        present for this checkout's content
${names_line}
  Blocked by:       how the command is spelled, not what it targets

This gate confirms a merge names the pull request its clearance is for by
reading the command itself, and it denies on every abstention rather than read
a command approximately. It abstained here, so it never reached the comparison
that would have passed.

${repair_lead} ${spelling_shared}
A bare \`gh pr merge --squash --delete-branch\`, with no number and no other
flag, is always readable and targets this checkout's own pull request."
  else
    reason="PR merge gate: HEAD ${sha:0:12} is cleared, but the merge does not name the pull request that clearance is for.

  Clearance:        present for this checkout's content
  Merge names:      ${named}
  This checkout is on: ${record:-<no pull-request record>}

Every clearance signal, a member's branch-own digest marker and the GAIA-Audit
commit status, proves that a member read THIS
CHECKOUT's content. None of them says anything about another pull request, so
merging one on their strength would merge a pull request nothing here audited.

To unblock:
  1. Merge the pull request this checkout is actually on: run
     \`gh pr merge --squash --delete-branch\` with no number, or name
     ${record:-the pull request for this branch} explicitly.
  2. To merge a different pull request, check that branch out and let its own
     Code Audit Team members clear it.

The spelling has to be one this gate can read exactly. ${spelling_shared}"
  fi

  reason="${reason}

This denial is UNCONDITIONAL and no clearance lifts it. Re-spawning the Code
Audit Team rewrites the same markers for the same unrotated digest and this
command denies identically; the repair is to respell the merge, never to obtain
another clearance.

See wiki/concepts/PR Merge Workflow.md for the full contract."

  jq -n --arg reason "$reason$gate_arm_note" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
  return 1
}

# gate_deny_unbound_bypass <what qualifies>: the deny for a record-based bypass
# whose content qualified and whose command binding alone failed. The marker
# deny below it would be false here twice over: its reason says the pull
# request disqualified itself, and its remedy, an audit run, produces a marker
# this diff never owed while the respelled merge still binds the same way.
gate_deny_unbound_bypass() {
  local qualification="$1" named record reason
  resolve_pr_record
  named="${GAIA_GH_MERGE_REFERENCE:-no target this gate could read}"
  record="${pr_record_number:-}"

  reason="PR merge gate: this checkout's pull request ${record:-<no pull-request record>} needs no Code Audit Team marker (${qualification}), but this gate could not bind the merge command to that pull request, so the bypass did not fire.

  Merge names:         ${named}
  This checkout is on: ${record:-<no pull-request record>}

A bypass clears a merge only once it has read the command and confirmed it
targets this checkout's own pull request, and it denies on every abstention.
It abstains when the merge is not the first and only command in its tool call
(a \`cd\` before it, a \`;\` or \`&&\` after it, a pipe into \`tail\`), when the
command carries a quoted flag value or any other byte outside the small set a
merge needs, and when it names a branch, a URL, or a different number.

To unblock, run the merge as its own command, with nothing beside it:
  gh pr merge ${record:-<N>} --squash --delete-branch
or with no number at all, \`gh pr merge --squash --delete-branch\`; \`--auto\` may
be added to either. No marker and no audit run is needed. To merge a different
pull request, check out its branch so this gate reads that pull request's own
diff.

See wiki/concepts/PR Merge Workflow.md for the full contract."

  jq -n --arg reason "$reason$gate_arm_note" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
}

# gate_empty_is_decisive: may an EMPTY base-to-HEAD range clear this gate on its
# own? Five conjuncts, and the last four are why this is a named predicate
# rather than a bare call to the shared trust check.
#
# The trust conjunct is the shared library's, never a local copy: an empty range
# means "nothing left to audit" only when the base it was taken against is one
# this checkout could not have invented.
#
# The other four bind the relaxation to the pull-request record AND to the
# command being gated. This gate scopes its range to LOCAL HEAD, so without
# them a checkout sitting on a synced default branch, where `merge-base HEAD
# refs/remotes/origin/<default>` IS HEAD so the range holds zero files on remote
# provenance, would clear `gh pr merge <N>` for an arbitrary, entirely unaudited
# pull request. Requiring a `pr-record` anchor means the base was actually taken
# against the pull request's own recorded base branch; requiring HEAD to equal
# the record's head sha means this checkout is on the pull request the RECORD
# describes; and requiring the command's own reference to match the record's
# number means that pull request is the one being merged. On a synced default
# branch there is no pull request for the current branch, the record is empty,
# the anchor is `default-branch`, and this returns 1.
#
# The last conjunct reads the command through the shared scanner and denies on
# every abstention, so what it proves is bounded to the shapes that scanner
# reads exactly: the merge is the first command in the tool call, it carries no
# flag shape the scanner declines to model, no separator or comment puts a
# second command beside it, and every byte of it is in the small set a merge
# invocation needs, so no expansion of any spelling can run a second command.
# Anything else denies rather than being read approximately.
#
# The command-binding conjunct is NOT scoped to this arm, and it now IS a
# whole-gate invariant: no path through this gate clears a merge without
# establishing that the merge names the pull request the clearance is for. The
# arms that clear off the current-branch RECORD each ask at their own site, the
# chore(deps) bypass above and both arms of this function's own caller, because
# each needs the answer to decide whether it fires at all; keep it that way when
# adding a record-based arm, since they reach that record by different routes.
# The arms that clear off a
# CLEARANCE instead ask once, at the permit site, through
# gate_permit_binds_to_named_pr above; that function owns the reasoning for why
# the question sits there and what the network read costs.
gate_empty_is_decisive() {
  audit_provenance_empty_is_decisive "$gate_trust" || return 1
  [ "$gate_anchor" = "pr-record" ] || return 1
  [ -n "$pr_record_head" ] || return 1
  [ "$pr_record_head" = "$sha" ] || return 1
  gate_command_names_the_record_pr || return 1
  return 0
}

