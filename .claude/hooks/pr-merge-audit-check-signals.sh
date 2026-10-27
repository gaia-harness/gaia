#!/usr/bin/env bash
# pr-merge-audit-check-signals.sh: the code-audit-frontend clearance signals: the version literal, the GAIA-Audit status, the pull request record, the chore(deps) predicate and the review base.
#
# One contiguous span of the merge gate, moved here unchanged.
# pr-merge-audit-check.sh sources it from its own directory at the point the
# span stood, so it runs in the same order over the same globals; it is never
# run on its own. $root, the main checkout every marker path joins onto, is
# the one the parent derives through main-root-lib.sh (gaia_resolve_main_root).
#
# Bash 3.2 compatible (macOS-default bash).

# shellcheck disable=SC2034,SC2154  # the gate globals cross files: the parent and the other siblings set and read them

# --- code-audit-frontend clearance signals -----------------------------------
#
# Each check is a self-contained function so frontend_cleared() below can
# reuse it from both the legacy gate and the member-aware gate.

# _gate_current_version -> the trimmed .gaia/VERSION literal on stdout, or
# empty. Read by check_github_status to compare a stamped version field.
_gate_current_version() {
  # Rooted at the acting tree, the way every sibling caller of this reader
  # already passes it. A bare literal reads empty from any working directory
  # below the repository root, and the status check then reports a version
  # mismatch against a status that is correct, which sends the operator to
  # re-audit content nothing is wrong with.
  gaia_read_version "$tree_root/.gaia/VERSION"
}

# GitHub commit status fallback: post-audit-status.sh stamps a GAIA-Audit
# commit status off a member marker, which carries a clearance earned on one
# machine to a merge run on another. Query the API for a matching status on
# HEAD. The status must be state: success; its description shape is
# "<version> <frontend-digest> <tree>", and version + digest must both
# match (the tree field is data only, never compared), so a bypass stamp
# (`skipped: ...`) never reads as cleared here. A non-success status is
# filtered out at the source, so a pending status carrying HEAD's
# version+digest is not treated as cleared. Falls through silently on any
# error (no gh, no token, no GITHUB_REPOSITORY, API failure), the deny path
# below fires as normal.
#
# With "any-digest" the status's digest field is not compared, which needs no
# branch-own digest and so no base lookup. Only the bypass stamp decision uses
# it: it asks whether the head already carries a cleared status, not whether
# that status clears this gate. A status recorded under another digest recipe
# does not clear the gate (the default form compares the digest) but still
# satisfies the status check branch protection waits on.
check_github_status() {
  local digest_mode="${1:-}"
  command -v gh >/dev/null 2>&1 || return 1

  # Derive repo slug. GITHUB_REPOSITORY is set inside Actions; derive from
  # the current directory's git remote for local runs via `gh repo view`
  # (avoids BSD-vs-GNU sed portability issues with lazy quantifiers).
  repo="${GITHUB_REPOSITORY:-}"
  if [ -z "$repo" ]; then
    repo=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)
    [ -n "$repo" ] || return 1
    case "$repo" in
      */*) ;;  # must contain a slash (owner/name)
      *) return 1 ;;
    esac
  fi

  # Read .gaia/VERSION (same "no stamp without VERSION" invariant as CI).
  current_version="$(_gate_current_version)"
  [ -n "$current_version" ] || return 1

  [ "$digest_mode" = any-digest ] || [ -n "$frontend_digest" ] || return 1

  status_description=$(gh api \
    "repos/${repo}/commits/${sha}/statuses" \
    --jq 'map(select(.context == "GAIA-Audit")) | first | select(.state == "success") | .description' \
    2>/dev/null || true)

  [ -n "$status_description" ] && [ "$status_description" != "null" ] || return 1

  status_version=$(printf '%s' "$status_description" | awk '{print $1}')
  status_digest=$(printf '%s' "$status_description" | awk '{print $2}')

  [ -n "$status_version" ] && [ -n "$status_digest" ] || return 1
  [ "$status_version" = "$current_version" ] || return 1
  [ "$digest_mode" = any-digest ] || [ "$status_digest" = "$frontend_digest" ] || return 1

  return 0
}

# resolve_pr_record: read this pull request's record once into
# $pr_record_title, $pr_record_base, $pr_record_head, $pr_record_number and
# $pr_record_files. Memoized on $pr_record_read, which is what distinguishes
# "not read yet" from "read, and the answer was nothing".
#
# One read rather than one per field. `gh` carries no request timeout of its
# own, so a second round-trip is a second OS-length stall on a blackholed
# network, and the memo is what keeps every consumer to the first one. Every
# failure (no gh, no auth, no PR for this branch, network error) leaves every
# field empty and each consumer takes its own no-answer path.
#
# The consumers are the two record-based bypasses, the legacy deny reason, and
# gate_command_names_the_record_pr, which every permit reaches through
# gate_permit_binds_to_named_pr. That last one is the reason this read is no
# longer confined to the uncleared path: a permit issued off a purely local
# clearance still has to establish which pull request it is a permit FOR. See
# gate_permit_binds_to_named_pr for why that is worth a network read.
#
# Every field is initialized HERE, at parent level, and that placement is
# load-bearing rather than cosmetic. This script runs under `set -uo
# pipefail`, and this function returns early before reaching any jq assignment
# on its two most common paths: no `gh` on PATH, and a `gh` that answers with
# nothing. A reader that dereferences $pr_record_head after either of those
# returns would trip `set -u` and kill the hook outright, so the gate would emit
# no JSON at all exactly where it owes a deny. Initializing inside the function
# body would not fix that; the early returns sit above it.
pr_record_read=""
pr_record_title=""
pr_record_base=""
pr_record_head=""
pr_record_number=""
pr_record_files=""
resolve_pr_record() {
  [ -z "$pr_record_read" ] || return 0
  pr_record_read=yes

  command -v gh >/dev/null 2>&1 || return 0
  pr_record=$(gh pr view --json title,baseRefName,headRefOid,number,files 2>/dev/null || true)
  [ -n "$pr_record" ] || return 0

  # `// ""` so a JSON null reaches the callers as the same empty string an
  # absent record does; both are "no answer" and neither is a branch name nor a
  # commit sha. A record carrying no head sha (an older stub, a trimmed
  # response) therefore reads as no answer, which FAILS the record-bound
  # conjunction below rather than passing it by default.
  pr_record_title=$(printf '%s' "$pr_record" | jq -r '.title // ""' 2>/dev/null || true)
  pr_record_base=$(printf '%s' "$pr_record" | jq -r '.baseRefName // ""' 2>/dev/null || true)
  pr_record_head=$(printf '%s' "$pr_record" | jq -r '.headRefOid // ""' 2>/dev/null || true)
  pr_record_number=$(printf '%s' "$pr_record" | jq -r '.number // ""' 2>/dev/null || true)
  pr_record_files=$(printf '%s' "$pr_record" | jq -r '(.files // [])[] | .path // empty' 2>/dev/null || true)
}

# chore(deps) bypass: PRs whose title matches `^chore\(deps(-dev)?\):` AND
# whose recorded file list is confined to a dependency manifest are
# pre-verified by the /update-deps wrapper's local quality gate (typecheck +
# lint + vitest + playwright + build), so the audit-marker requirement is
# waived for this PR class. The predicate itself lives in one place,
# .gaia/scripts/chore-deps-skip.sh, shared with the CI workflows that skip
# the same pull requests. A dep-bump PR that also
# carries a non-manifest path (a migration edit, a rebuilt bundle) does not
# waive; it runs the normal member-aware gate below.
#
# The title and file list come from the shared PR-record read above. On any
# failure (no gh, no auth, no PR for the current branch, network error, an
# empty file list, or an unresolved repo root) the bypass does not fire and the
# normal deny path runs, the bypass is opt-in proof, not a fallback.
#
# Sets $chore_deps_unbound when the record qualifies and only the command
# binding fails, so a deny can name the spelling that binds instead of
# claiming the title or file list disqualified the pull request.
chore_deps_unbound=0
check_chore_deps_pr() {
  resolve_pr_record
  [ -n "$pr_record_title" ] || return 1
  # tree_root, not root: the predicate is executable code, so it comes from the
  # ACTING tree that carries it. root is the main checkout, which from a linked
  # worktree is a different branch entirely and need not have the script at all.
  [ -n "$tree_root" ] || return 1
  [ "$(bash "$tree_root/.gaia/scripts/chore-deps-skip.sh" "$pr_record_title" <<<"$pr_record_files")" = "true" ] || return 1
  # Bind the bypass to the pull request the COMMAND names. The title above came
  # from `gh pr view` with no number, so on its own it proves a property of the
  # CURRENT BRANCH's pull request while the merge being gated names one this
  # function never parsed: from a checkout sitting on a dep-bump branch, a merge
  # naming an arbitrary unaudited number cleared with no marker at all.
  # A command carrying no positional still permits,
  # since that is gh's current-branch default and therefore the very pull
  # request the title was read for, which is what leaves the turnkey
  # `gh pr merge --squash` dep-bump path unaffected.
  if ! gate_command_names_the_record_pr; then
    chore_deps_unbound=1
    return 1
  fi
  return 0
}

# gate_resolve_base: resolve, ONCE per run, the diff base that scopes this pull
# request's own changes, together with the provenance that says how much that
# base deserves to be trusted. Both bypasses below read $gate_trust,
# $gate_anchor and $gate_base and nothing else, so the two cannot drift.
#
# The resolution itself lives in the shared library
# (.claude/hooks/lib/audit-base-provenance.sh), the one place tree-wide that
# walks the supplied/record/default-branch ladder and the one definition of
# whether an empty range at a given trust level is decisive. This gate owns no
# copy of either, which is what keeps it from reaching a verdict the audit spawn
# oracle would contradict about the same base.
#
# Every git call runs against $tree_root, the ACTING tree resolved from cwd
# above. The derivation this replaced used a bare cwd-relative `git`; anchoring
# it makes explicit what was implicit, and matches the anchoring the member
# dispatch block below already uses.
#
# The supplied-base argument is ALWAYS the empty string, deliberately. No
# gate-side consumer accepts a base override and none may gain one: a
# caller-chosen base is a caller-chosen diff, and a fail-closed check whose diff
# the caller picks is not fail-closed. Do not add one here for symmetry with the
# dispatch resolver, which is a dispatch-side consumer answering a different
# question.
#
# The answer comes from the pull request record, never from the environment. An
# exported base-ref variable would let a caller shrink a fail-closed check's
# diff until every remaining path looked out of scope; a PR's base ref is the
# branch it actually merges into, so scoping to it concedes nothing that merging
# the PR would not already concede. The shared resolver reads no environment
# variable naming a base branch on any path, so that refusal survives the move
# into it intact.
#
# Both checks below scope their diff to a merge base, and the branch that merge
# base is taken against decides what "this PR changes" means. The remote's
# advertised default is that branch only when the PR targets it: a PR stacked on
# another branch merges into THAT branch, and diffing against the default hands
# the check the base branch's own history instead, denying a bypass the PR had
# earned.
#
# When the record's remote-tracking ref does not verify (no gh, no auth, no PR
# for this branch, network error, a base branch this checkout has never
# fetched), the resolver falls through to the advertised default and reports
# anchor `default-branch`. That is usually the wider diff but not always: a
# backport forked from current main and targeting an older maintenance branch
# merge-bases NEARER to HEAD against main than against its own base. It is the
# safe direction regardless, for a reason that does not rest on the geometry.
# Whatever the narrower answer drops sits on commits already merged to the
# default branch, which is where they were already audited.
#
# That fall-through describes the ref-does-not-verify case ONLY. A record ref
# that verifies but whose merge-base fails (unrelated histories, a shallow HEAD)
# does not fall through at all: the resolver answers `unresolvable` with an
# empty base, the guards below fire, and the gate denies. That is exactly the
# answer the derivation this replaced gave, and falling through there would hand
# this gate a resolved, wider base on a path where it previously refused
# outright.
#
# The memo is parent-level, and calling this function DIRECTLY (never inside a
# `$( )`) is what keeps it that way. The per-subshell memo it replaced existed
# only because both bypasses reached the base through a command substitution,
# which also made its two variables a coupled pair whose half-set state was the
# one combination that derivation existed to forbid. Both bypasses are invoked
# from the parent shell, so a direct call retires that hazard.
#
# Resolution stays LAZY, and this is the more expensive read of the two: on top
# of resolve_pr_record it derives the base's provenance and, in its callers,
# diffs the whole base-to-HEAD range. A cleared run now pays the record read
# (see gate_permit_binds_to_named_pr) but must not pay this one. Call it only
# from inside the two bypasses and the legacy deny reason, never at the top
# level of this script.
gate_provenance_read=""
gate_trust=""
gate_anchor=""
gate_base=""
gate_resolve_base() {
  [ -z "$gate_provenance_read" ] || return 0
  gate_provenance_read=yes

  resolve_pr_record

  local base_provenance
  base_provenance="$(audit_resolve_base_provenance "$tree_root" pr-record "" "$pr_record_base")" || base_provenance=""
  # An empty $base_provenance leaves all three fields empty, which every guard below reads
  # as unresolvable and fails closed on.
  IFS=$'\t' read -r gate_trust gate_anchor gate_base <<< "$base_provenance" || true
}

