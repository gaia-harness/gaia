#!/usr/bin/env bash
# audit-write-clearance-gates.sh: the clearance writer's pre-write gates, the
# branch-own digest derivation, the light-review router check, and the
# scope-digest staleness gate, each as a function, plus the capture release the
# staleness gate calls. audit-write-clearance.sh sources it from its own
# directory and calls the gates in order; it is never run on its own. The
# globals the gates set (digest among them) stay global for the later phases.
#
# Bash 3.2 compatible (macOS-default bash).

# shellcheck disable=SC2034,SC2154  # the phase globals cross files: the parent and the other siblings set and read them

# Branch-own digest
#   The member's digest covers the branch's own patch against the local base
#   reference (`audit_branch_digests_local`), bound to the branch. Content the
#   base brought in, by a clean catch-up merge, is not in it, so a catch-up
#   rotates no marker (barring a base edit within three lines of a branch
#   hunk) and leaves a scope capture equal to the write-time digest;
#   a change to the branch's own patch on the member's paths (including one made
#   inside a merge commit) rotates it.
#
# The member's branch-own digest is the marker's validity key. Fail closed: never
# write a marker keyed to an empty or partial digest.
_write_clearance_derive_digest() {
  command -v audit_branch_digests_local >/dev/null 2>&1 || {
    error "cannot load the digest engine (.claude/hooks/lib/audit-digest.sh)"
    exit 2
  }
  digest=""
  digest_status=0
  digests_all="$(audit_branch_digests_local "$ROOT" 2>/dev/null)" || digest_status=$?
  # The base tip not being present locally and the merge base not being unique each
  # have one next step the operator can take; every other failure is "cannot derive".
  case "$digest_status" in
    0) ;;
    4)
      error "cannot derive a branch-own digest for member '$MEMBER': the base branch tip is not present locally. Run: git fetch origin"
      exit 2
      ;;
    3)
      _merge_remedy_reference="$(audit_local_base_reference "$ROOT" 2>/dev/null || true)"
      error "cannot derive a branch-own digest for member '$MEMBER': this branch has more than one merge base with the base branch. Run: git merge --no-edit ${_merge_remedy_reference:-refs/remotes/origin/main}"
      exit 2
      ;;
  esac
  while IFS= read -r _digest_line; do
    if [ "${_digest_line%%$'\t'*}" = "$MEMBER" ]; then
      digest="${_digest_line#*$'\t'}"
      break
    fi
  done <<EOF
$digests_all
EOF
  if [ "$digest_status" -ne 0 ] || [ -z "$digest" ]; then
    error "cannot derive a branch-own digest for member '$MEMBER' at --root '$ROOT'"
    exit 2
  fi
}

# _release_forfeited_capture: drop this member's stored capture as the
# superseded refusal below exits 2.
#
# Why the refusal cannot just exit. `audit-scope-digest.sh` spends a stored
# capture when a conclusion KEYED TO IT is on disk, which is the discriminator
# that tells a finished round from a running one. A round that ends without
# publishing anything is invisible to that test: it looks exactly like a running
# review, so its capture survives, and because the digest rotated while the
# round was ending, the NEXT round's earned write refuses `review scope
# superseded` and writes no artifact -- which spends nothing either. Every round
# after it refuses identically, forever, and the AND-aggregator holds
# GAIA-Audit shut with no in-band recovery. Three routes end a round that way:
# the dirty-tree withhold (the member definitions order a withhold with no
# `.refused` artifact, then ask for a re-dispatch once the operator commits,
# which is the rotation), a superseded forfeiture itself, and a crash or a
# no-op-detected round.
#
# Publishing a `.refused` here instead would spend the capture, but at the
# WRITE-TIME digest, which is not the one the spent test looks for; keyed to the
# CAPTURED digest it would spend correctly and then sit on disk as a live
# refusal blocking the very marker the next clean round earns, which is the
# hazard the withhold prose exists to avoid. Releasing the capture is what
# actually matches the situation: the round is over and produced nothing, so the
# next dispatch should start from a fresh capture.
#
# This costs the forfeited round and nothing after it. What it deliberately does
# NOT do is let the SAME round recover: a member that re-runs its scope fence
# after this refusal gets a fresh capture and could then earn a marker for
# content it reviewed at the old digest. Nothing in-band distinguishes a
# same-round re-run from the next dispatch -- that is why the refusal message
# says the round is forfeited in as many words, and why the member definitions
# say the fence re-run is safe EXCEPT after this refusal.
# Each outcome carries its own status, because the caller's diagnostic differs
# for each and a message that asserts one of them for all of them is read as a
# description of what happened. Saying "the capture is released" on a run
# that released nothing points the operator at a deadlock they have been told
# is already cleared.
#
#   0  released: a stored capture existed and is gone.
#   1  nothing to release: no capture is stored, so none can strand a later
#      round. Not a failure.
#   2  could not resolve the scope file at all -- no key lib, no --base (the CI
#      clearance call passes none), an unresolvable key, or the capture was
#      located but could not be removed. A capture may or may not still be
#      sitting there; this arm cannot always tell, and must not claim either.
_release_forfeited_capture() {
  local key="" scope_file
  command -v gaia_audit_key >/dev/null 2>&1 || return 2
  [ -n "$BASE" ] || return 2
  key="$(gaia_audit_key "$BASE" "$ROOT" 2>/dev/null || true)"
  [ -n "$key" ] || return 2
  scope_file="${ROOT}/.gaia/local/audit/${key}.${MEMBER}.scope.json"
  [ -f "$scope_file" ] || return 1
  rm -f "$scope_file" || {
    error "warning: could not release the forfeited capture at '$scope_file'; the next round will refuse identically until it is removed"
    return 2
  }
  return 0
}

# A light clearance is licensed by a fresh router decision and by nothing else.
# Every check refuses before anything is written or touched, so a refused light
# attempt leaves the audit directory exactly as it found it.
_write_clearance_check_light_route() {
  if [ "$REVIEW" = "light" ]; then
    command -v jq >/dev/null 2>&1 || {
      error "jq is required to write a clearance marker"
      exit 2
    }
    if [ ! -r "$ROUTE_RECORD" ] || ! jq -e 'type == "object"' "$ROUTE_RECORD" >/dev/null 2>&1; then
      error "route record '$ROUTE_RECORD' is unreadable or not a JSON object"
      exit 2
    fi
    _light_head_tree="$(git -C "$ROOT" rev-parse "HEAD^{tree}" 2>/dev/null || true)"
    if [ -z "$_light_head_tree" ]; then
      error "cannot resolve HEAD tree for --root '$ROOT'"
      exit 2
    fi
    _light_refusal="$(jq -r --arg member "$MEMBER" --arg digest "$digest" --arg tree "$_light_head_tree" '
      if .route != "light" then "route is not light"
      elif .member != $member then "route record names a different member"
      elif .digest != $digest then "route record digest is stale"
      elif .tree != $tree then "route record tree is stale"
      else "" end' "$ROUTE_RECORD" 2>/dev/null || echo "route record cannot be evaluated")"
    if [ -n "$_light_refusal" ]; then
      error "--review light refused: $_light_refusal"
      exit 2
    fi
    if [ -f "$refused_path" ]; then
      error "--review light refused: a same-digest refusal exists; a light clearance never supersedes a refusal"
      exit 2
    fi
  fi
}

# Scope-digest staleness gate. Gated on a PLAIN earned write, a category
# that includes a --supersede-refusal write with no sibling refusal on disk:
# the flag exists so a member can retire its OWN prior same-digest refusal,
# and that act requires the refusal to actually be there. A write carrying the
# flag with nothing to retire is, by this writer's own filename family, an
# ordinary earned write, so it takes the ordinary earned write's gate rather
# than skipping it. A --provenance refused write is exempt throughout: a
# refusal is a claim that content should not merge, and suppressing THAT is
# the one genuinely fail-open outcome available here. Each arm below is its
# own explicit refusal rather than a `[ -n "$SCOPE_DIGEST" ] && …` guard, so
# an absent value refuses instead of silently skipping the comparison.
#
# This gate does not make a stale-scope marker unreachable. A --provenance
# refused write is itself exempt and needs no digest, so the same outcome
# reaches an .ok marker in two calls: write a refusal, then supersede it with
# a mismatched --scope-digest. What this gate removes is the one-call form
# that left nothing behind; for a blocking member the surviving two-call
# route leaves a `.refused` artifact on disk on the way and publishes a body
# carrying a `supersedes` block with a stated reason and a timestamp, so it
# cannot be taken silently.
_write_clearance_check_scope_digest() {
  if [ "$PROVENANCE" = "earned" ] && [ "$supersede_retires_refusal" -ne 1 ]; then
    if [ "$SCOPE_DIGEST_SEEN" -ne 1 ]; then
      error "scope digest not supplied"
      # A member dispatched into a worktree loads the agent definition the
      # session resolved from the MAIN checkout, not from the worktree under
      # review. On a branch that edits that member's own definition the prompt it
      # is running therefore predates the edit, and a prompt predating this
      # handshake never learned to capture or pass a scope digest -- so its
      # earned write lands here. This refusal is the only channel that reaches
      # such a member, and without naming the cause it reads as the member's own
      # mistake: it retries identically, and if every dispatched member is in
      # that state the AND-aggregator holds the merge gate shut with nothing left
      # that can clear it. Naming the cause is what makes the stall self-clearing.
      error "If you were dispatched into a worktree whose branch edits your own agent definition, the definition you are running was resolved from the main checkout and predates that edit. Re-read your own definition from --root ('$ROOT'), follow it, and retry."
      exit 2
    elif [ "$SCOPE_DIGEST" != "$digest" ]; then
      error "review scope superseded: scope=$SCOPE_DIGEST write=$digest"
      _release_forfeited_capture
      case "$?" in
        0) error "this round is forfeited and its capture is released; the next dispatch captures fresh." ;;
        1) error "this round is forfeited; no stored capture was found to release, so nothing carries into the next dispatch." ;;
        *) error "this round is forfeited, but the stored capture could not be located or removed (no --base, an unresolvable audit key, the key library not being loaded, or the removal itself failed). If one is present, the next dispatch inherits it and refuses identically; clear it with audit-scope-digest.sh --capture --recapture." ;;
      esac
      error "Do NOT re-run the scope fence to obtain a new capture in this round: you reviewed the superseded content, and a marker earned on a fresh capture would attest content you never read."
      exit 2
    fi
  fi
}
