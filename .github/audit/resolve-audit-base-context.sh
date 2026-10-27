#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2154 # stage globals are assigned and read across the resolver and its siblings
# resolve-audit-base-context.sh: the resolver's context stage. Resolves the
# main ref and the fork point, reads the version, builds the candidate list,
# loads the predicate libraries, and takes the degraded arm when any of them
# is missing. Sourced by resolve-audit-base.sh, never executed; defines
# functions only, which the parent calls in order. Every assignment is a
# global the later stages read.
#
# Base reset on machinery change
#   A version-matching candidate is not automatically safe: if any
#   gate-machinery file (the ownership classifier, the machinery matcher,
#   the digest recipe itself) changed on the branch between that candidate and
#   HEAD, the candidate's audit ran under different membership/scoping rules
#   than HEAD's, even though the version string didn't move. Reviewing only
#   <candidate>..HEAD would then leave the candidate's own pre-base content
#   unreviewed under the new rules. The argument-less form applies one flat
#   test over the whole machinery set (via the batch machinery matcher,
#   sourced from the checkout).
#
#   The delta that test reads is the branch's own change since the candidate:
#   the paths whose branch-own patch differs between the candidate and HEAD.
#   What a catch-up merge brought in from the base is not in it, so a base-only
#   edit to a machinery path resets nothing, while a branch edit to one still
#   does, including one made inside a merge commit. When that change cannot be
#   computed the reset fires.
#
# The two-tier reset, --member form only
#   The flat test is far broader than the question a single member is
#   asking. A repair to one member's own lens file, or an edit to a hook
#   that only posts a status, resets every member. So the per-member form
#   tests the same branch-own delta in two tiers (audit-rules-changed.sh):
#     global tier  the files deciding what a member owns, what counts as
#                  machinery, how a digest is computed, whether a clearance
#                  is believed, which members are dispatched, or under which
#                  version any of that was decided. Resets EVERY member.
#     member tier  a member's own agent definition or one of its companion files
#                  (AUDIT_MEMBER_COMPANION_PATHS in audit-rules-changed.sh). Resets only that member.
#   Machinery that is merely shared resets nobody. It still rotates digests,
#   so a fresh clearance is still required before the merge gate opens, but
#   the review earning it stays incremental. The tier predicate is a
#   carve-out of the machinery set and never edits it.
#
# Fail direction: an unloadable library resets to full scope
#   With the classifier, the machinery matcher, the rules-tier predicate, or
#   the base libraries unsourceable, or with no local base reference to compute
#   the fork point against (the answer then names git fetch origin), NEITHER tier can be evaluated, so the anchor's soundness
#   for the resolving member cannot be established at all and the narrowing
#   it would permit is member-specific and invisible. Both forms therefore
#   emit the full-scope main ref and log the degradation; on no path is a
#   candidate emitted. The merge gate already denies outright on the same
#   input, so this agrees with the gate rather than adding a new denial. The
#   accepted cost is that a checkout missing those libraries always reviews
#   full scope.
#
#   audit-clearance.sh is the deliberate exception. Its absence is the same
#   condition as an empty clearance store, which is every
#   continuous-integration run: the store is gitignored and never uploaded
#   between runs. Both tiers stay evaluable there, so it does not take the
#   degraded arm (which would emit a reason of its own). In the argument-less
#   form the whole-team signal still anchors; in the --member form the
#   team-signal arm refuses for want of verifiable review depth and the answer
#   is no-anchor (see the team-signal section in resolve-audit-base-scan.sh).
#   Do not "fix" this into
#   uniformity. audit-key-lib.sh is outside the degraded set for the same
#   reason: without it only the refusal link fails, and the answer falls back
#   exactly as it does when no ledger exists.
#
# Why bound the walk to merge-base..HEAD
#   The base must be one of THIS PR's commits (or the divergence point as
#   the floor). Walking into main's own history could pick a deeper main
#   commit and pull already-merged, unrelated changes into this PR's review
#   scope. The merge-base bound prevents that; reaching the floor yields the
#   main ref, i.e. the full branch-own scope. A merge base that is not unique
#   (a criss-cross) leaves no single range to walk, so it resolves degraded
#   with the remedy named.
#
# Where the main ref comes from
#   The resolver reads its base name through audit_local_base_reference, which
#   consults the per-branch cache and makes at most one `gh` lookup per branch
#   on a cache miss. That bounded lookup does not reintroduce the hazard of a
#   base that resolves only sometimes, which for a resolver that SCOPES a
#   review could land at or near HEAD, empty the reviewed delta, and let a
#   member earn a clearance having read nothing: a failed lookup writes no
#   cache and falls to origin/HEAD then main, the same answer the resolver
#   always gave, and a success is fixed thereafter. The name is never taken
#   from the environment. The fully-qualified remote-tracking spelling is the
#   only form used, so a local branch named like it cannot stand in.

# -----------------------------------------------------------------------------
# Resolve the main ref and the branch's fork point. The main ref scopes the
# full-scope fallback and bounds the ancestry walk; the fork point is what line
# 3 carries on every arm that is not anchored, because the artifact key is
# derived from it.
# -----------------------------------------------------------------------------

resolve_base_main_reference() {
  # Bracketed for the reason given at the version-normalizer load below. Absence
  # of either library leaves the base unresolved, which takes the degraded arm
  # further down, the same way an absent predicate library does.
  for base_library_file in audit-base-provenance.sh audit-branch-patch.sh; do
    set +e
    # shellcheck source=/dev/null
    [ -f "${repo_root}/.claude/hooks/lib/${base_library_file}" ] && . "${repo_root}/.claude/hooks/lib/${base_library_file}" 2>/dev/null
    set -e
  done

  main_reference="refs/remotes/origin/main"
  fork_point="$main_reference"
  base_tip=""
  base_failure=""
  if ! command -v audit_local_base_reference >/dev/null 2>&1 \
    || ! command -v audit_branch_patch_fork_point >/dev/null 2>&1 \
    || ! command -v audit_branch_patch_merge_base >/dev/null 2>&1 \
    || ! command -v audit_branch_patch_changed_paths >/dev/null 2>&1; then
    base_failure="the base libraries (audit-base-provenance.sh, audit-branch-patch.sh) are unavailable"
  elif ! resolved_reference="$(audit_local_base_reference "$repo_root" 2>/dev/null)"; then
    base_failure="no local base reference ${main_reference} to compute against"
  else
    main_reference="$resolved_reference"
    base_tip="$(git -C "$repo_root" rev-parse --verify --quiet "${main_reference}^{commit}" 2>/dev/null || true)"
    if [ -z "$base_tip" ]; then
      base_failure="${main_reference} does not resolve to a commit"
    elif computed_fork_point="$(audit_branch_patch_fork_point "$repo_root" "$base_tip" HEAD 2>/dev/null)" \
      && [ -n "$computed_fork_point" ]; then
      fork_point="$computed_fork_point"
    else
      base_failure="the branch's fork point from ${main_reference} could not be computed"
      main_reference="refs/remotes/origin/main"
    fi
  fi
  shared_base="$fork_point"
}

# -----------------------------------------------------------------------------
# Read .gaia/VERSION: missing/empty means no base can be validated, on either
# anchor arm.
# -----------------------------------------------------------------------------

resolve_base_read_version() {
  # Sourced here rather than in the library block below, because that block sits
  # after this read and the version gate has to answer before the walk starts.
  # Bracketed rather than `if [ -f ]; then . X || true; fi`: the existence test
  # admits a file that is present but UNPARSEABLE, and on bash 3.2.57 -- the
  # /bin/bash stock macOS ships, and the floor the parent's Conventions block
  # claims -- errexit abandons the shell AT the load, so the `|| true` is never
  # reached and the resolver exits emitting nothing instead of degrading to full
  # scope. Dropping errexit across the load is what lets the failure reach the
  # `command -v` degrade below. The flat `set -e` restore matches the parent's own
  # errexit arming, rather than the state-preserving form a library uses.
  version_library="${repo_root}/.claude/hooks/lib/gaia-version.sh"
  set +e
  # shellcheck source=/dev/null
  [ -f "$version_library" ] && . "$version_library" 2>/dev/null
  set -e
  if ! command -v gaia_read_version >/dev/null 2>&1; then
    echo "resolve-audit-base: version normalizer unavailable (gaia-version.sh); resetting to full scope (${main_reference})." >&2
    emit "$main_reference" degraded ""
  fi

  current_version="$(gaia_read_version "${repo_root}/.gaia/VERSION")"
  if [ -z "$current_version" ]; then
    emit "$main_reference" no-version ""
  fi
}

# -----------------------------------------------------------------------------
# Build the candidate list (PR commits, newest first).
# -----------------------------------------------------------------------------

resolve_base_build_candidates() {
  head_sha=$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || true)
  if [ -z "$head_sha" ]; then
    emit "$main_reference" no-anchor ""
  fi

  # A unique merge base bounds the walk. More than one (a criss-cross) leaves no
  # single PR range to walk, so the answer is full scope with the remedy named.
  merge_base=""
  if [ -n "$base_tip" ]; then
    if merge_base=$(audit_branch_patch_merge_base "$repo_root" "$base_tip" HEAD 2>/dev/null); then
      :
    else
      merge_base_status=$?
      merge_base=""
      if [ "$merge_base_status" -eq 3 ]; then
        echo "resolve-audit-base: HEAD has more than one merge base with ${main_reference}; merge the base branch (git merge --no-edit ${main_reference}) to make it unique. Resetting to full scope (${main_reference})." >&2
        emit "$main_reference" degraded ""
      fi
    fi
  fi
  if [ -n "$merge_base" ]; then
    candidates=$(git -C "$repo_root" rev-list --max-count="$MAXIMUM_WALK_COMMIT_COUNT" "${merge_base}..HEAD" 2>/dev/null || true)
  else
    candidates=$(git -C "$repo_root" rev-list --max-count="$MAXIMUM_WALK_COMMIT_COUNT" HEAD 2>/dev/null || true)
  fi
}

# -----------------------------------------------------------------------------
# Signal extractor (the GAIA-Audit commit status shape).
# -----------------------------------------------------------------------------

# status_version_for <sha> → echoes the GAIA-Audit commit status version, or
# empty. Only a state: success status counts; a non-success status (e.g. a
# local-mode stand-down's pending status on this SHA) is filtered out at the
# source, so such a commit is not a usable base from the status path. Needs
# gh + GH_TOKEN + repo slug; a missing token / absent gh / API failure / no
# success status all yield empty (the walk continues).
status_version_for() {
  local sha="$1" repo description
  [ -n "${GH_TOKEN:-}" ] || return 0
  command -v gh >/dev/null 2>&1 || return 0
  repo="${GITHUB_REPOSITORY:-}"
  [ -n "$repo" ] || return 0
  description=$(gh api "repos/${repo}/commits/${sha}/statuses" \
    --jq 'map(select(.context == "GAIA-Audit" and .state == "success")) | last | .description' \
    2>/dev/null || true)
  if [ -z "$description" ] || [ "$description" = "null" ]; then
    return 0
  fi
  printf '%s' "$description" | awk '{print $1}'
}

# delta_for <anchor> → the branch's own change since the anchor, one path per
# line; non-zero when it cannot be computed.
#
# The branch's own change excludes whatever a catch-up merge of the base brought
# in, so a base-only edit to a machinery or rules path resets nothing while a
# branch edit to one still does. Callers treat a failure as a reset.
#
# Fed to the batch matchers by here-string, never by pipe: they return on the
# first match without draining stdin, so a piped producer writing past the
# ~64KB pipe buffer takes SIGPIPE (141), and under `set -o pipefail` the
# pipeline status collapses to false -- silently skipping the reset.
#
# The listing is NUL-terminated because the matchers compare their prefixes
# literally: a path carrying non-ASCII or control bytes would come back wrapped
# in literal double quotes under git's default core.quotePath, and a token
# starting with `"` prefix-matches nothing. The `tr` puts back the newlines the
# here-string feed reads by; pipefail carries the producer's status through it.
delta_for() {
  local listing
  listing="$(audit_branch_patch_changed_paths "$repo_root" "$base_tip" "$1" "$head_sha" 2>/dev/null | tr '\0' '\n')" || return 1
  printf '%s' "$listing"
}

# -----------------------------------------------------------------------------
# Load the predicate libraries. This happens BEFORE the walk, not lazily on
# first need, because their availability now decides the answer rather than
# merely qualifying it.
# -----------------------------------------------------------------------------

resolve_base_load_predicates() {
  library_directory="${repo_root}/.claude/hooks/lib"
  for library_file in audit-scope.sh audit-machinery.sh audit-rules-changed.sh audit-clearance.sh; do
    # Bracketed for the reason given at the version-normalizer load above: an
    # existence test admits an unparseable lib, and under errexit bash 3.2.57
    # dies at the load rather than at the `||`. Same shape, same reason.
    set +e
    # shellcheck source=/dev/null
    [ -f "${library_directory}/${library_file}" ] && . "${library_directory}/${library_file}" 2>/dev/null
    set -e
  done

  # The key library builds the re-run ledger's path for the refusal link. Same
  # bracketed load; its absence fails only that link and never sets
  # missing_library below.
  key_library="${repo_root}/.gaia/scripts/audit-key-lib.sh"
  set +e
  # shellcheck source=/dev/null
  [ -f "$key_library" ] && . "$key_library" 2>/dev/null
  set -e

  if [ -n "$base_failure" ]; then
    echo "resolve-audit-base: ${base_failure}; run git fetch origin. Resetting to full scope (${main_reference})." >&2
    emit "$main_reference" degraded ""
  fi

  missing_library=""
  if ! command -v audit_owner_for_path >/dev/null 2>&1; then
    missing_library="audit-scope.sh"
  elif ! command -v audit_path_is_machinery >/dev/null 2>&1 \
    || ! command -v audit_delta_has_machinery >/dev/null 2>&1; then
    missing_library="audit-machinery.sh"
  elif ! command -v audit_rules_reset_for >/dev/null 2>&1; then
    missing_library="audit-rules-changed.sh"
  fi
  if [ -n "$missing_library" ]; then
    echo "resolve-audit-base: classifier/machinery/rules libs unavailable (${missing_library}); resetting to full scope (${main_reference})." >&2
    emit "$main_reference" degraded ""
  fi
}
