#!/usr/bin/env bash
# shellcheck disable=SC2154 # some stage globals are assigned only in the sibling stages
# resolve-audit-base.sh: resolve the incremental review base for the
# code-review-audit agent.
#
# Purpose
#   The audit reviews the diff from a "base" commit to HEAD. The base is the
#   most recent ancestor of HEAD whose content is accounted for under the
#   CURRENT agent version, in one of two ways:
#     cleared  it passed a CLEAN audit, proven by a GAIA-Audit commit status
#              or, in the --member form, that member's own earned clearance.
#     refused  --member form only: that member's own newest refusal, linked
#              to the open-finding record it left in the re-run ledger. The
#              content up to it was reviewed, and what the review found is
#              carried as open entries that the member's next clearance
#              write must account for one by one (re-reported or resolved
#              with a rationale), so nothing found there is dropped by not
#              being read again.
#   Reviewing only <base>..HEAD is then far cheaper than re-reviewing the
#   whole origin/main..HEAD diff on every push to an open PR.
#
#   That whole-team signal is posted only when NO dispatched Code Audit
#   Team member is still pending, which is what makes it trustworthy and
#   also what caps it: a member that cleared in a round where a sibling was
#   pending cannot anchor on its own clearance. Naming a member with
#   `--member` adds a second anchor arm over the same walk, reading that
#   member's own clearances and refusals out of the local audit store. The
#   whole-team signal stays the FLOOR; the per-member arm only ever improves
#   on it, never replaces it.
#
#   When no usable ancestor exists, first audit of a PR, every prior run
#   cancelled or failed (those post nothing), a .gaia/VERSION bump
#   invalidated older audits, or the version file is missing; the helper
#   emits the main ref (member form line 1) or the branch's fork point
#   (argument-less form) so the caller falls back to a full-scope review. A
#   commit nobody reviewed carries no signal to anchor on, and a refusal
#   anchors only while its open findings are on record, so neither shortcut
#   leaves content unread with nothing owed on it.
#
# Invocation
#   .github/audit/resolve-audit-base.sh [--member <name>]
#
#   The argument-less form resolves the shared pull-request-wide base. The
#   merge-time
#   findings hook is not one of them and no longer calls this script at all:
#   the block it posts selects its sidecars on the branch, across every base. `--member <name>` is the per-member form; the Code Audit Team's
#   agent definitions are the only call sites that can name a member.
#
#   Reads .gaia/VERSION, HEAD's ancestry, the local audit store's clearance
#   and refusal records and (--member form) its re-run ledger, and (when
#   `gh`, GH_TOKEN and GITHUB_REPOSITORY are all available) the GitHub Commit Status API. A commit-message
#   trailer on any commit is ignored.
#
# Output (stdout), argument-less form
#   Exactly ONE line, suitable for a `base...HEAD` diff:
#     <40-hex-sha>: resolved incremental base (an audited PR ancestor), or on
#       every unanchored arm the branch's fork point, the first parent of the
#       oldest branch commit the base does not reach
#     refs/remotes/origin/main: when the fork point cannot be computed
#       (no local base reference), with reason degraded and a stderr line
#       naming git fetch origin
#   The single line is the shared base on every arm, early ones included, so
#   the artifact key derived from it does not move when the branch merges the
#   base.
#
# Output (stdout), --member form
#   Exactly FOUR newline-terminated lines:
#     1. the per-member review base ref, which SCOPES that member's review; on
#        a full-scope answer the fully-qualified local base reference
#     2. the reason token (closed set, below)
#     3. the shared pull-request-wide base, which KEYS every artifact: the
#        whole-team anchor commit, else the branch's fork point
#     4. the recorded tree of the clearance or refusal that anchored line 1,
#        or EMPTY on every path where neither anchored it
#
#   Line 3 comes from the same code path the argument-less form prints, so
#   co-dispatched members agree on the key structurally rather than
#   incidentally. The fork point is a first-parent notion: a catch-up merge of
#   the base keeps the branch as its first parent, so the merge base of line 3
#   and HEAD, which the artifact key is built from, is the same before and
#   after the merge. Before any catch-up it equals the merge base of the base
#   reference and HEAD. each receives byte-identically what the argument-less form
#   carries, which is what makes the shared re-run ledger one file per round.
#   The findings block used to be the second beneficiary of that agreement and
#   is no longer a beneficiary at all; the ledger is the whole reason line 3
#   exists. Lines 1 and 3
#   legitimately differ, e.g. when a merely-shared machinery path changed
#   after the anchor: line 3 resets and line 1 does not. That divergence is
#   what the two-base split is for.
#
#   Line 4 lets a caller record WHICH record anchored the answer without a
#   second invocation and without parsing stderr. An empty line 4 is the
#   normal case for every reason other than member-clearance and
#   member-refusal, and an empty line is still a line.
#
# Output (stderr)
#   Exactly one decision line on every path:
#     resolve-audit-base: member=<name|-> base=<sha|ref> reason=<token> anchor_tree=<tree|->
#   plus one FURTHER explanatory line when a reset or a degradation fired,
#   naming the path or the library that forced it. Closed reason set:
#     member-clearance    anchored on this member's own earned clearance
#     member-refusal      anchored on this member's own refusal, linked to
#                         the open-finding record it left in the ledger
#     team-signal        anchored on the whole-team status floor
#     no-anchor           no usable anchor in range; full scope
#     rules-reset-global  a global-rules path changed between anchor and HEAD
#     rules-reset-member  this member's own agent definition or a companion file changed
#     machinery-reset     the argument-less flat machinery reset fired
#     degraded            classifier, machinery, rules, or version lib, or a
#                         stage sibling, not sourceable
#     no-version          .gaia/VERSION missing or empty
#
# Exit code
#   0 always, on every path, a usage error included. A non-zero exit does
#   NOT degrade the callers uniformly to full scope: it degrades the agent
#   call sites to an EMPTY review scope, because an empty base makes git
#   resolve the diff's left side to HEAD and return nothing at status 0.
#   Reviewing nothing is worse than reviewing everything. The merge-time
#   findings hook is no longer among the degraded callers: it does not call
#   this script, so a non-zero exit here costs it nothing and it still posts. This script runs under
#   `set -euo pipefail`, so every library function is probed with
#   `command -v` before it is called: an unguarded call into a library that
#   did not load is a command-not-found, which is exactly that non-zero
#   exit.
#
# Why version-match (not digest-match) gates a base
#   A commit is a usable base when its audit signal's <version> equals the
#   current .gaia/VERSION. A version mismatch means the ruleset changed
#   since that audit, so code cleared under the old version may now have
#   findings; that commit is NOT a safe base, and the walk continues,
#   ultimately falling back to a full re-audit under the new ruleset. The
#   signal's frontend-digest and tree fields are not compared here; they
#   describe content the audit already reviewed, not whether the ruleset
#   that reviewed it is still current. The per-member arm is gated the same
#   way, on the clearance body's own recorded version.
#
# Siblings
#   The stages live in siblings beside this file, which it sources from its
#   own directory: resolve-audit-base-context.sh (main ref, fork point,
#   version, candidates, predicate libraries), resolve-audit-base-scan.sh (the
#   per-member pre-scan and the roster review-depth check),
#   resolve-audit-base-walk.sh (the candidate walk) and
#   resolve-audit-base-refusal.sh (the refusal link). Each defines functions
#   only; this file calls them in order, and every exit goes through emit. A
#   missing or incomplete sibling emits the main ref with reason degraded, the
#   full-review answer.
#   The rationale for each stage sits in its sibling's header.
#
# Conventions
#   - Bash 3.2 compatible (macOS default). No associative arrays / mapfile.
#   - Never `cd`s (per .claude/rules/shell-cwd.md). Uses git -C "$repo_root".

set -euo pipefail

# Defensive cap on the ancestry walk (PRs rarely exceed this many commits;
# the merge-base bound usually keeps the list far shorter).
# shellcheck disable=SC2034 # read by the candidate list in resolve-audit-base-context.sh
MAXIMUM_WALK_COMMIT_COUNT=50

TAB="$(printf '\t')"

# -----------------------------------------------------------------------------
# Arguments
# -----------------------------------------------------------------------------

member=""
member_form="false"
argument_error=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --member)
      if [ "$#" -lt 2 ]; then
        argument_error="--member requires a value"
        break
      fi
      if [ -z "$2" ]; then
        argument_error="--member requires a non-empty value"
        break
      fi
      member="$2"
      member_form="true"
      shift 2
      ;;
    *)
      argument_error="unknown argument '$1'"
      break
      ;;
  esac
done

# -----------------------------------------------------------------------------
# Emit: the one exit point. Writes the decision line to stderr and the
# invocation form's stdout shape. shared_base must already hold the
# argument-less resolution, since that is what line 3 carries.
# -----------------------------------------------------------------------------

emit() {
  local base="$1" reason="$2" anchor_tree="$3"
  # The argument-less form prints one line and that line is the shared base, so
  # an early arm that names the main ref for line 1 still prints the fork point
  # here: the artifact key is derived from it.
  [ "$member_form" = "true" ] || base="$shared_base"
  printf 'resolve-audit-base: member=%s base=%s reason=%s anchor_tree=%s\n' \
    "${member:--}" "$base" "$reason" "${anchor_tree:--}" >&2
  if [ "$member_form" = "true" ]; then
    printf '%s\n%s\n%s\n%s\n' "$base" "$reason" "$shared_base" "$anchor_tree"
  else
    printf '%s\n' "$base"
  fi
  exit 0
}

# -----------------------------------------------------------------------------
# Resolve repo root
# -----------------------------------------------------------------------------

repo_root=$(git rev-parse --show-toplevel 2>/dev/null || true)
if [ -z "$repo_root" ]; then
  # Defensive: not in a git repo, so nothing can be sourced out of the
  # checkout either. Full scope; the caller's git will error loudly on the
  # broken environment.
  main_reference="refs/remotes/origin/main"
  shared_base="$main_reference"
  echo "resolve-audit-base: not inside a git checkout; resetting to full scope (${main_reference})." >&2
  emit "$main_reference" degraded ""
fi

# -----------------------------------------------------------------------------
# Load the siblings, from this file's own directory, never the working
# directory. A sibling that is missing or unparseable takes the degraded arm
# like an unloadable library: the full-scope main ref, so the review widens to
# the whole branch and never narrows, and the exit stays 0 rather than the 127
# a call into an absent stage would give. Bracketed for the reason given at
# the version-normalizer load (resolve-audit-base-context.sh), and checked by
# the LAST function each sibling defines, since bash 3.2 can stop partway
# through an unparseable file with the earlier definitions already made.
# -----------------------------------------------------------------------------

# No `cd` to absolutize it: this script never changes directory, so a relative
# invocation path still names the same directory at every load.
resolver_directory="$(dirname "${BASH_SOURCE[0]}")"

# load_resolver_sibling <stage> <last function it defines>
load_resolver_sibling() {
  local sibling_file="${resolver_directory}/resolve-audit-base-$1.sh"
  set +e
  # shellcheck source=/dev/null
  [ -f "$sibling_file" ] && . "$sibling_file" 2>/dev/null
  set -e
  if ! declare -F "$2" >/dev/null 2>&1; then
    main_reference="refs/remotes/origin/main"
    shared_base="$main_reference"
    echo "resolve-audit-base: sibling resolve-audit-base-$1.sh unavailable; resetting to full scope (${main_reference})." >&2
    emit "$main_reference" degraded ""
  fi
}

load_resolver_sibling context resolve_base_load_predicates
load_resolver_sibling scan resolve_base_read_roster
load_resolver_sibling walk resolve_base_walk_candidates
load_resolver_sibling refusal refusal_link_holds

resolve_base_main_reference

# A mis-invocation cannot be trusted to be a member call site, so it degrades
# to the argument-less full-scope shape rather than guessing a four-line one.
if [ -n "$argument_error" ]; then
  member=""
  member_form="false"
  echo "resolve-audit-base: ${argument_error}; resolving full scope (${main_reference})." >&2
  emit "$main_reference" no-anchor ""
fi

resolve_base_read_version
resolve_base_build_candidates
resolve_base_load_predicates
resolve_base_scan_member_records
resolve_base_read_roster
resolve_base_walk_candidates

# -----------------------------------------------------------------------------
# The shared, pull-request-wide resolution: the whole-team arm plus the flat
# machinery reset. This is what the argument-less form prints and what the
# --member form carries on line 3; there is one code path so the two cannot
# drift.
# -----------------------------------------------------------------------------

shared_reason="no-anchor"
if [ -n "$team_anchor" ]; then
  if ! shared_delta="$(delta_for "$team_anchor")"; then
    echo "resolve-audit-base: the branch's own change since ${team_anchor} could not be computed; treating it as a machinery change." >&2
    shared_reason="machinery-reset"
  elif [ -n "$shared_delta" ] && audit_delta_has_machinery >/dev/null <<<"$shared_delta"; then
    shared_reason="machinery-reset"
  else
    shared_base="$team_anchor"
    shared_reason="team-signal"
  fi
fi

if [ "$member_form" != "true" ]; then
  if [ "$shared_reason" = "machinery-reset" ]; then
    echo "resolve-audit-base: machinery changed on this branch between ${team_anchor} and HEAD; resetting to full scope (${main_reference})." >&2
  fi
  emit "$shared_base" "$shared_reason" ""
fi

link_failure_cause=""

# -----------------------------------------------------------------------------
# The per-member resolution: the walk's winner, then the two-tier reset.
# -----------------------------------------------------------------------------

if [ -n "$refusal_candidate" ]; then
  if refusal_link_holds; then
    winner="$refusal_candidate"
    winner_reason="member-refusal"
    winner_tree="$refusal_candidate_tree"
  else
    echo "resolve-audit-base: ${member} refused content at ${refusal_candidate} (${link_failure_cause}); per-member anchoring disabled for this run." >&2
  fi
fi

if [ -z "$winner" ] && [ -n "$team_winner" ]; then
  winner="$team_winner"
  winner_reason="team-signal"
  winner_tree=""
fi

if [ -z "$winner" ]; then
  emit "$main_reference" no-anchor ""
fi

reset_hit=""
if ! member_delta="$(delta_for "$winner")"; then
  echo "resolve-audit-base: the branch's own change since ${winner} could not be computed; treating it as a global rules change." >&2
  reset_hit="global${TAB}-"
elif [ -n "$member_delta" ]; then
  reset_hit="$(audit_rules_reset_for "$member" <<<"$member_delta" || true)"
fi

if [ -n "$reset_hit" ]; then
  reset_tier=""
  reset_path=""
  IFS="$TAB" read -r reset_tier reset_path <<<"$reset_hit"
  if [ "$reset_tier" = "member" ]; then
    echo "resolve-audit-base: ${member}'s own agent definition or a companion file changed on this branch between ${winner} and HEAD (${reset_path}); resetting to full scope (${main_reference})." >&2
    emit "$main_reference" rules-reset-member ""
  fi
  echo "resolve-audit-base: a global rules path changed on this branch between ${winner} and HEAD (${reset_path}); resetting to full scope (${main_reference})." >&2
  emit "$main_reference" rules-reset-global ""
fi

emit "$winner" "$winner_reason" "$winner_tree"
