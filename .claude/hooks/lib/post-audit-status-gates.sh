#!/usr/bin/env bash
# The preconditions .claude/hooks/post-audit-status.sh runs between resolving
# its two roots and building the status description: the SUCCESS arm's
# version, trusted base and digests, the pushed-head guards both arms share,
# then the SUCCESS arm's caller's own refusal, the chore(deps) waiver, the
# member-aware gate, the owed-gate check and the PR body stamp. Sourced, never
# executed; defines functions only.
#
# Contract with the hook. post_audit_status_gates reads the hook's globals
# post_state, marker_member, marker_digest, repo_root, store_root and
# _repository_root_directory, and calls its emit_decline. It returns 0 when
# every precondition holds, and 1 after emitting exactly one decline line, on
# which the hook exits 0. It leaves version, frontend_digest, head_sha, tree_sha
# and pr_view set as globals, which the hook's description, POST and draft flip
# read, so none of them is declared local.
#
# The checks run in the order the hook has always run them, and that order is
# what makes the SUCCESS arm fail closed: keep it.
#
# The hook calls this inside an `||` list, where bash suspends errexit for the
# whole function body. Every command here that can fail carries its own guard;
# the version read, the one that relied on errexit, exits with the status
# errexit would have exited with.

# shellcheck disable=SC2154  # the marker, mode and root globals come from post-audit-status.sh

# digest_for_member <member>: the member's digest out of branch_digest_lines
# (`<member>\t<digest>` per line), or nothing when the member is not listed.
digest_for_member() {
  local line
  while IFS= read -r line; do
    if [ "${line%%$'\t'*}" = "$1" ]; then
      printf '%s' "${line#*$'\t'}"
      return 0
    fi
  done <<<"$branch_digest_lines"
  return 0
}

# post_audit_status_gates: run every precondition in order; return 1 after
# emitting the one decline line, 0 when the POST may proceed.
post_audit_status_gates() {
  # The version, the trusted base and the digests are inputs to the SUCCESS
  # description and to the member-aware gate, and the refusal arm reads none of
  # them: its description is built from the caller's own member and digest, and it
  # skips the gate. So these preconditions are scoped to the success arm rather
  # than applied to both. Declining a refusal over a field it never reads, or over
  # a base it never measures against, would be the wrong direction: it withholds a
  # retraction while the stale success it exists to retract stands.
  version=""
  frontend_digest=""
  branch_digest_lines=""
  if [ "$post_state" = "success" ]; then
    version_file="${repo_root}/.gaia/VERSION"
    if [ ! -f "$version_file" ]; then
      emit_decline "version file missing"
      return 1
    fi

    if ! command -v gaia_read_version >/dev/null 2>&1; then
      emit_decline "version normalizer unavailable (lib/gaia-version.sh)"
      return 1
    fi

    version="$(gaia_read_version "$version_file")" || exit "$?"
    if [ -z "$version" ]; then
      emit_decline "version file empty"
      return 1
    fi

    # Fail closed when any function the trusted-base derivation needs is missing:
    # a partial library set must decline, never fall through to a weaker base.
    if ! command -v audit_branch_patch_merge_base >/dev/null 2>&1 \
       || ! command -v audit_github_repository >/dev/null 2>&1 \
       || ! command -v audit_github_pr_base_branch >/dev/null 2>&1 \
       || ! command -v audit_github_base_tip >/dev/null 2>&1 \
       || ! command -v audit_branch_digests_all >/dev/null 2>&1; then
      emit_decline "branch patch library unavailable (lib/audit-branch-patch.sh)"
      return 1
    fi

    # The trusted base comes from GitHub, never from a local ref. On a failure a
    # library call prints nothing on stdout and one line on stderr, so the
    # captured text is a message only when the call failed.
    base_failure=""
    base_repository=""
    base_tip=""
    base_branch="$(audit_github_pr_base_branch "$repo_root" 2>&1)" || base_failure="$base_branch"
    if [ -z "$base_failure" ]; then
      base_repository="$(audit_github_repository "$repo_root" 2>&1)" || base_failure="$base_repository"
    fi
    if [ -z "$base_failure" ]; then
      base_tip="$(audit_github_base_tip "$repo_root" "$base_repository" "$base_branch" 2>&1)" || base_failure="$base_tip"
    fi
    if [ -n "$base_failure" ]; then
      # gh answered the hook's `gh auth status` check, so a failed read from a
      # checkout on the default branch or a detached HEAD, neither of which can
      # head a pull request, means the hook ran from the wrong tree, not that
      # auth broke.
      current_branch="$(git -C "$repo_root" symbolic-ref --quiet --short HEAD 2>/dev/null)" || current_branch=""
      default_branch="$(git -C "$repo_root" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null)" || default_branch=""
      default_branch="${default_branch#refs/remotes/origin/}"
      [ -n "$default_branch" ] || default_branch="main"
      if [ -z "$current_branch" ] || [ "$current_branch" = "$default_branch" ]; then
        emit_decline "trusted base unverified, this checkout is on ${current_branch:-a detached HEAD}, which holds no pull request; next step: run this hook from the checkout that holds the pull request branch (git worktree list names it)"
        return 1
      fi
      emit_decline "trusted base unverified, ${base_failure}; next step: gh auth status"
      return 1
    fi

    stale_cache_fix="$(audit_stale_cached_base "$repo_root" "$base_branch" 2>/dev/null)" || stale_cache_fix=""
    if [ -n "$stale_cache_fix" ]; then
      emit_decline "trusted base unverified, the cached audit base differs from the base GitHub reports; next step: ${stale_cache_fix}"
      return 1
    fi

    merge_base_status=0
    merge_base="$(audit_branch_patch_merge_base "$repo_root" "$base_tip" HEAD 2>/dev/null)" || merge_base_status=$?
    case "$merge_base_status" in
      0) ;;
      4)
        emit_decline "trusted base unverified, the base tip is not present locally; next step: git fetch origin"
        return 1
        ;;
      3)
        emit_decline "trusted base unverified, more than one merge base with the base branch; next step: git merge --no-edit refs/remotes/origin/${base_branch}"
        return 1
        ;;
      *)
        emit_decline "trusted base unverified, no unique merge base could be derived"
        return 1
        ;;
    esac

    # Every member's digest in one pass, so one identities listing serves the
    # frontend digest below and the member-aware gate. Fail closed: never post a
    # status without a real digest.
    branch_digest_lines="$(audit_branch_digests_all "$repo_root" "$merge_base" 2>/dev/null || true)"
    frontend_digest="$(digest_for_member code-audit-frontend)"
    if [ -z "$frontend_digest" ]; then
      emit_decline "frontend digest unavailable"
      return 1
    fi
  fi

  # The sha branch protection checks is the PR head on the REMOTE, not local HEAD.
  # When local HEAD is an un-pushed commit origin has never seen, a status posted
  # there 422s and never lands. Target the pushed PR head instead (the same sha a pull_request event reports as head.sha).
  #
  # `gh` resolves BOTH the repository and the current branch from its working
  # directory, so it runs anchored on $repo_root. Be precise about what that
  # buys: $repo_root is itself a toplevel query against the ambient cwd, so this
  # normalizes a run from a SUBDIRECTORY up to the checkout root. It cannot
  # repoint the hook at a different tree, because the root it anchors on is
  # derived from the cwd it already had. Choosing which tree this hook answers
  # for is the caller's job, done by invoking the hook from that tree.
  #
  # The same read carries the pull request's title, on a second line, and its
  # file list on the lines after that, for the chore(deps) waiver in the
  # member-aware gate below. GitHub titles are single line, so the first two
  # newlines are an unambiguous split.
  pr_view="$( cd "$repo_root" && gh pr view --json headRefOid,title,files --jq '.headRefOid, .title, (.files[]?.path)' 2>/dev/null || true )"
  head_sha="${pr_view%%$'\n'*}"
  pr_title=""
  pr_files=""
  case "$pr_view" in
    *$'\n'*)
      pr_view_rest="${pr_view#*$'\n'}"
      pr_title="${pr_view_rest%%$'\n'*}"
      case "$pr_view_rest" in
        *$'\n'*) pr_files="${pr_view_rest#*$'\n'}" ;;
      esac
      ;;
  esac
  if [ -z "$head_sha" ]; then
    # No PR resolvable: fall back to the upstream tracking tip, then local HEAD.
    head_sha="$(git -C "$repo_root" rev-parse '@{u}' 2>/dev/null || true)"
  fi
  if [ -z "$head_sha" ]; then
    head_sha="$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || true)"
  fi

  tree_sha=$(git -C "$repo_root" rev-parse "HEAD^{tree}" 2>/dev/null || true)
  if [ -z "$head_sha" ] || [ -z "$tree_sha" ]; then
    emit_decline "repo slug unresolved"
    return 1
  fi

  # Never green a tree the target sha does not carry. The audited tree (local
  # HEAD's tree) must equal the target sha's tree; otherwise the audited content
  # is not on the remote head yet (un-pushed tree-changing work)
  # and posting would falsely clear a stale head. Decline instead.
  target_tree="$(git -C "$repo_root" rev-parse "${head_sha}^{tree}" 2>/dev/null || true)"
  if [ -z "$target_tree" ] || [ "$target_tree" != "$tree_sha" ]; then
    emit_decline "audited tree not on pushed head"
    return 1
  fi

  # The tree guard above cannot see an un-pushed content-preserving commit
  # (an empty commit): every blob stays byte-identical and local HEAD's tree
  # equals the target sha's tree even while that commit exists only locally.
  # Require the COMMIT sha to match too. Without this the status posts on the
  # older head, the commit is pushed afterwards, the PR head advances, and the
  # success status is stranded on a sha no reader checks, so a required
  # GAIA-Audit check waits forever. head_sha here is the live PR head read
  # fresh from `gh`. When no PR and no upstream resolve, head_sha IS local
  # HEAD, so this guard does not fire on that path.
  head_local="$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || true)"
  if [ "$head_local" != "$head_sha" ]; then
    emit_decline "stamp not pushed"
    return 1
  fi

  # Member-aware gate: require EVERY dispatched Code Audit
  # Team member's marker, not just the caller's own, before posting success.
  # Otherwise a frontend-only POST on a mixed diff would flip the GAIA-Audit
  # status green (and unlock the github.com merge button) while a co-dispatched
  # maintainer member still withholds over an unresolved finding. An ABSENT or
  # non-executable resolver falls back to the hook's single-marker POST, so a
  # partial/early-resume tree is never bricked. Each member is keyed to its OWN
  # branch-own digest, not the frontend digest or the tree; there
  # is no carried provenance, so every dispatched member's clearance is earned.
  #
  # The resolver derives its own root from cwd, so it runs anchored on
  # $repo_root, the acting tree it measures. A NON-ZERO exit is the third state
  # and it takes neither of the other two paths: the resolver ran and could not
  # answer, so the member set is unknown, and posting success on an unknown
  # member set is the vacuous pass this gate exists to prevent. That arm
  # declines.
  # The refusal reader is required for BOTH checks below, probed once here rather
  # than per member and OUTSIDE the resolver branch. A clearance lib carrying
  # clearance_member_cleared without clearance_member_refused makes a refusal call
  # exit 127, and the surrounding `||` chain consumes that as "not refused",
  # reverting the gate to cleared-only and posting success on a head where a
  # member holds a live refusal. That is the one degradation direction this gate
  # must never take, so an unavailable reader declines instead of falling open.
  # The earned reader's own probe sits at the hook's marker-mode branch, where
  # absence degrades to a decline on its own.
  if [ "$post_state" = "success" ] && ! command -v clearance_member_refused >/dev/null 2>&1; then
    emit_decline "clearance reader unavailable"
    return 1
  fi

  # The CALLER'S OWN refusal, checked without the roster. An earned write never
  # clears a same-digest refusal (only --supersede-refusal does, as an explicit
  # recorded act), so a member that refused this digest and was then re-run with a
  # plain earned write holds BOTH artifacts. The member-aware gate below catches
  # that for every dispatched member, but it is armed only when the resolver is
  # executable, and the no-resolver fallback posts on the caller's marker alone.
  # Left to that fallback this hook retracts the failure the refusal writer
  # posted, and auto-merge completes over a live refusal, which is the whole
  # incident the refusal arm exists to prevent. The caller's own member and digest
  # are already in hand, so this needs nothing the roster provides.
  if [ "$post_state" = "success" ] \
     && clearance_member_refused "$store_root" "$marker_digest" "$marker_member"; then
    emit_decline "caller holds a live refusal"
    return 1
  fi

  # The chore(deps) waiver: a dep-bump pull
  # request whose recorded file list is confined to a dependency manifest waives
  # code-audit-frontend, through the same predicate the merge hook
  # already reads, so a co-dispatched member's earned marker completes the
  # handshake. It waives the missing frontend marker only and sits after the
  # loop's refusal read, so a frontend refusal stays pending under a dep-bump
  # title. Fail-closed: no pull request, an unreadable title, an empty or
  # non-manifest file list, or an absent predicate leave frontend pending. No
  # extra tree binding is needed here: the pushed-head guards above (target_tree
  # == tree_sha, head_local == head_sha) already proved local HEAD equals this
  # same read's headRefOid before this point, so the file list already describes
  # exactly the tree being posted about.
  frontend_waived="false"
  chore_deps_predicate="${repo_root}/.gaia/scripts/chore-deps-skip.sh"
  if [ -n "$pr_title" ] && [ -f "$chore_deps_predicate" ] \
     && [ "$(bash "$chore_deps_predicate" "$pr_title" <<<"$pr_files" 2>/dev/null || true)" = "true" ]; then
    frontend_waived="true"
  fi

  resolver="${repo_root}/.gaia/scripts/resolve-audit-members.sh"
  if [ "$post_state" = "success" ] && [ -x "$resolver" ]; then
    resolver_exit_status=0
    members="$( cd "$repo_root" && bash "$resolver" 2>/dev/null )" || resolver_exit_status=$?
    if [ "$resolver_exit_status" -ne 0 ]; then
      emit_decline "member resolver could not answer"
      return 1
    fi

    pending=""
    while IFS= read -r roster_member; do
      [ -n "$roster_member" ] || continue
      member_digest="$(digest_for_member "$roster_member")"
      # Refusal-first, mirroring the merge hook's own precedence
      # (pr-merge-audit-check.sh's member loop). A member that cleared a digest in
      # one wave and refused the SAME digest in a later one holds both artifacts,
      # because the writer publishes a refusal beside an earned marker rather than
      # replacing it. Read cleared alone and that member counts as cleared, so the
      # next member's earned handshake posts success on the same head and
      # latest-status-wins retracts the failure the refusal just posted. The local
      # gate would still deny, which is the divergence: the two readers must agree
      # about one state, and the gate's answer is the one that governs.
      if [ -z "$member_digest" ] \
         || clearance_member_refused "$store_root" "$member_digest" "$roster_member"; then
        pending="${pending}${pending:+ }${roster_member}"
      elif ! clearance_member_cleared "$store_root" "$member_digest" "$roster_member" \
           && { [ "$roster_member" != "code-audit-frontend" ] || [ "$frontend_waived" != "true" ]; }; then
        pending="${pending}${pending:+ }${roster_member}"
      fi
    done <<< "$members"

    if [ -n "$pending" ]; then
      emit_decline "members pending ${pending}"
      return 1
    fi
  fi

  # Any non-zero exit (a missing script's 127 too) reads as owed; auto-merge acts
  # on this status alone.
  if [ "$post_state" = "success" ] \
     && ! bash "$_repository_root_directory/.gaia/scripts/audit-gate-owed.sh" status --root "$repo_root" >/dev/null 2>&1; then
    emit_decline "gate steps owed (Playwright, dev smoke test, build); next step: run .gaia/scripts/audit-gate-owed.sh run --root <root> --run-folder <run folder>"
    return 1
  fi

  # The PR body's head stamp, for the same auto-merge reason, fail-closed. With
  # no pull request resolved there is no body, and nothing for a merge to land.
  if [ "$post_state" = "success" ] && [ -n "$pr_view" ]; then
    stamp_library="$_repository_root_directory/.claude/hooks/lib/pr-body-stamp.sh"
    # shellcheck source=lib/pr-body-stamp.sh
    if [ -z "$_repository_root_directory" ] || [ ! -f "$stamp_library" ] || ! . "$stamp_library"; then
      emit_decline "PR body stamp check unavailable (.claude/hooks/lib/pr-body-stamp.sh)"
      return 1
    fi
    # One read carries the number and head branch the review check below needs,
    # on the first two lines; everything after them is the body.
    if ! pr_body="$( cd "$repo_root" && gh pr view --json number,headRefName,body --jq '.number, .headRefName, .body' 2>/dev/null )"; then
      emit_decline "PR body unreadable; next step: gh auth status"
      return 1
    fi
    pr_number="${pr_body%%$'\n'*}"
    pr_body="${pr_body#"$pr_number"}"
    pr_body="${pr_body#$'\n'}"
    pr_head_ref="${pr_body%%$'\n'*}"
    pr_body="${pr_body#"$pr_head_ref"}"
    pr_body="${pr_body#$'\n'}"
    if ! stamp_reason="$(pr_body_stamp_verdict "$pr_body" "$head_sha")"; then
      emit_decline "${stamp_reason}; next step: re-check the PR summary against the branch's commits and diff, then run .gaia/scripts/pr-body-stamp.sh write"
      return 1
    fi

    # The PR review record, last: GitHub auto-merge completes on this status
    # alone and never runs the merge hook, so success is withheld while a
    # finding is undecided or an accepted fix is not yet made. A failure post
    # never reaches here, so a refusal is never held back by a disposition.
    # A waived dependency bump records its review before its merge, which the
    # merge hook still enforces, and a release pull request needs none. A
    # missing waiver library waives nothing.
    review_library="$_repository_root_directory/.claude/hooks/lib/pr-review-verdict.sh"
    review_waived="$frontend_waived"
    waiver_library="$_repository_root_directory/.claude/hooks/lib/pr-review-waiver.sh"
    # shellcheck source=lib/pr-review-waiver.sh
    if [ "$review_waived" != "true" ] && [ -n "$_repository_root_directory" ] && [ -f "$waiver_library" ] \
       && . "$waiver_library" && pr_review_release_waived "$repo_root" "$pr_title" "$merge_base" "$head_sha"; then
      review_waived="true"
    fi
    if [ "$review_waived" != "true" ]; then
      # shellcheck source=lib/pr-review-verdict.sh
      if [ -z "$_repository_root_directory" ] || [ ! -f "$review_library" ] || ! . "$review_library"; then
        emit_decline "PR review check unavailable (.claude/hooks/lib/pr-review-verdict.sh)"
        return 1
      fi
      review_record=""
      review_path="$(pr_review_record_path "$store_root" "$pr_head_ref" 2>/dev/null)" || review_path=""
      if [ -n "$review_path" ] && [ -f "$review_path" ]; then
        review_record="$(cat "$review_path" 2>/dev/null)" || review_record=""
      fi
      if ! pr_review_verdict "$review_record" "$pr_number" "$pr_body" 0 "$repo_root" "$head_sha" "" >/dev/null; then
        emit_decline "PR review: no complete review record for PR #${pr_number}; GAIA-Audit not posted."
        return 1
      fi
    fi
  fi
  return 0
}
