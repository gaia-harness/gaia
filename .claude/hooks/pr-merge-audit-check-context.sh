#!/usr/bin/env bash
# pr-merge-audit-check-context.sh: the fork refusal, the HEAD and root resolution, the roster parse, and the deny and digest helpers every later check calls.
#
# One contiguous span of the merge gate, moved here unchanged.
# pr-merge-audit-check.sh sources it from its own directory at the point the
# span stood, so it runs in the same order over the same globals; it is never
# run on its own. $root, the main checkout every marker path joins onto, is
# the one the parent derives through main-root-lib.sh (gaia_resolve_main_root).
#
# Bash 3.2 compatible (macOS-default bash).

# shellcheck disable=SC2034,SC2154  # the gate globals cross files: the parent and the other siblings set and read them

# Fork refusal, ahead of every read of the acting tree below: audit_scope_init
# reads its roster, the member resolver and the chore(deps) predicate run from
# it, and on a fork head all three are the fork's. The pull request asked about
# is the one the merge names when it names a bare number, and otherwise the
# current branch's, which is the only other pull request any permit below can
# clear (every permit binds to the record of the current branch).
_fork_check_reference=''
if type gaia_scan_gh_merge >/dev/null 2>&1 && gaia_scan_gh_merge "$command_line"; then
  case "${GAIA_GH_MERGE_REFERENCE:-}" in
    '' | *[!0-9]*) ;;
    *) _fork_check_reference="$GAIA_GH_MERGE_REFERENCE" ;;
  esac
fi
if _fork_deny_reason=$(gaia_cross_repo_deny_reason "$_fork_check_reference" '' \
  'PR merge gate: ' \
  "PR merge gate: cannot tell whether pull request ${_fork_check_reference:-for the current branch}" \
  "so it denies rather than risk merging one. Check gh (\`gh auth status\`, the network) and retry." \
  "$gate_arm_note"); then
  jq -n --arg reason "$_fork_deny_reason" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
  exit 0
fi

# Resolve HEAD SHA. If we cannot (no git, detached state we can't read),
# fall back to permissive: this hook only enforces in repos where git answers.
sha=$(git rev-parse HEAD 2>/dev/null || true)
if [ -z "$sha" ]; then
  exit 0
fi

# Resolve HEAD's TREE. This is now a plain DATA field (surfaced in deny
# messages only), never a validity key: every marker check below is keyed to
# a member's branch-own digest, derived on first need.
tree=$(git rev-parse "HEAD^{tree}" 2>/dev/null || true)

# TWO roots, because this gate spans two different questions and one root
# cannot answer both.
#
#   root       WHERE a clearance lives. Resolved to the MAIN checkout: every
#              marker clearance_member_cleared builds a path for is
#              main-anchored shared state (.gaia/state-registry.json
#              scope=shared, the symlinked audit/ store), not a property of
#              whichever tree this hook happens to run in. Sourced from this
#              hook's own on-disk location, matching the sibling lib-loads
#              above.
#   tree_root  WHAT a clearance attests to. The ACTING tree: the content
#              being merged is this tree's HEAD, not main's. Every writer
#              agrees -- the agent definitions pass
#              the acting tree's root as `--root <root>` to
#              audit-write-clearance.sh, and resolve-audit-members.sh derives the same
#              way -- so digesting main's HEAD here would compare a marker against content
#              nobody is merging. From a linked worktree the two trees
#              differ, no marker could ever match, and the gate's own remedy
#              text ("re-spawn the agents") would rewrite the same
#              non-matching marker forever.
#
# Both fall back to a bare toplevel query, then pwd, when the resolver is
# unavailable or fails -- the same fail-open direction the original
# CWD-anchored derivation had.
root=""
if command -v gaia_resolve_main_root >/dev/null 2>&1; then
  root="$(gaia_resolve_main_root 2>/dev/null)" || root=""
fi
[ -n "$root" ] || root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

tree_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

# Parse the roster ONCE per run (never once per path); the classifier module
# was sourced above. audit_branch_digests_all re-inits the same state
# internally, so this call is redundant with it in effect but kept explicit:
# check_out_of_scope_pr() run before any digest-dependent path in a future edit
# would still find the roster parsed. A config with no auditors: roster fails
# here with its own named remedy, ahead of the digest deny below, whose text
# would otherwise blame a missing sha256 tool.
if ! audit_scope_init "$tree_root" 2>/dev/null; then
  jq -n --arg reason "PR merge gate: ${tree_root}/.gaia/audit-ci.yml has no auditors: roster, so no Code Audit Team member can be resolved or cleared for HEAD ${sha:0:12}. There is no fallback roster. Restore the auditors: block from the copy of .gaia/audit-ci.yml GAIA ships, commit it, and retry.${gate_arm_note}" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
  exit 0
fi

# gate_emit_deny <reason>: print the deny decision for <reason> and exit.
gate_emit_deny() {
  jq -n --arg reason "$1$gate_arm_note" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
  exit 0
}

# The per-member digests, the frontend marker path and the frontend refusal are
# derived together, on first need, by gate_require_digests below. Nothing above
# the first signal that reads a digest touches the network, which is what keeps a
# bypass pull request (out of scope, chore(deps) manifest-only) from ever
# looking up the base.
_DIGEST_MEMBER=()
_DIGEST_VALUE=()
frontend_digest=""
marker=""
frontend_refused=0
refusal_note=""
gate_digests_resolved=""

# member_digest <member> -> that member's branch-own digest on stdout, exit 0;
# exit 1 (empty stdout) when the member is absent from the batch.
member_digest() {
  local want="$1" i=0
  while [ "$i" -lt "${#_DIGEST_MEMBER[@]}" ]; do
    if [ "${_DIGEST_MEMBER[$i]}" = "$want" ]; then
      printf '%s\n' "${_DIGEST_VALUE[$i]}"
      return 0
    fi
    i=$((i + 1))
  done
  return 1
}

# gate_require_digests: derive, once per run, every roster member's branch-own
# digest against the base GitHub reports, or print the deny decision naming the
# one next step and exit. Call it directly, never inside a `$( )`, so the memo
# and the exit both act on the parent shell.
#
# The trusted base is the PR record's base branch name plus that branch's tip
# from the GitHub branches endpoint. It is never read from a local ref: a stale
# or forged `refs/remotes/origin/*` would otherwise decide what counts as the
# branch's own change. The tip must be present locally and HEAD must have exactly
# one merge base with it; each failure has its own next step.
gate_require_digests() {
  [ -z "$gate_digests_resolved" ] || return 0
  gate_digests_resolved=yes

  resolve_pr_record

  local gh_remedy="Check gh (\`gh auth status\`, the network) and retry gh pr merge."
  local base_error_file base_detail repository tip merge_base lookup_status=0 digest_batch stale_cache_fix

  if [ -z "$pr_record_base" ]; then
    gate_emit_deny "PR merge gate: cannot verify the base branch for HEAD ${sha:0:12}: gh returned no pull request record naming a base branch for the current branch. Markers are keyed to the branch's own change against the base branch GitHub reports, and this gate never substitutes a local ref for it, so it denies. ${gh_remedy}"
  fi

  stale_cache_fix="$(audit_stale_cached_base "$tree_root" "$pr_record_base")" || stale_cache_fix=""
  if [ -n "$stale_cache_fix" ]; then
    gate_emit_deny "PR merge gate: this branch's cached audit base differs from base branch ${pr_record_base} that GitHub reports (the pull request was retargeted), so markers written locally are keyed to a different base than this gate measures for HEAD ${sha:0:12}. Run \`${stale_cache_fix}\`, re-run the audit writers, and retry gh pr merge."
  fi

  base_error_file="$(mktemp "${TMPDIR:-/tmp}/gate-base.XXXXXX" 2>/dev/null)" || base_error_file=/dev/null
  repository="$(audit_github_repository "$tree_root" 2>"$base_error_file")" || lookup_status=$?
  if [ "$lookup_status" -eq 0 ]; then
    tip="$(audit_github_base_tip "$tree_root" "$repository" "$pr_record_base" 2>"$base_error_file")" || lookup_status=$?
  fi
  if [ "$lookup_status" -ne 0 ]; then
    base_detail="$(head -n 1 "$base_error_file" 2>/dev/null || true)"
    [ "$base_error_file" = /dev/null ] || rm -f "$base_error_file"
    gate_emit_deny "PR merge gate: cannot read the tip of base branch ${pr_record_base} from GitHub for HEAD ${sha:0:12}: ${base_detail:-gh failed}. Markers are keyed to the branch's own change against the base GitHub reports, and this gate never substitutes a local ref for it, so it denies. ${gh_remedy}"
  fi
  [ "$base_error_file" = /dev/null ] || rm -f "$base_error_file"

  merge_base="$(audit_branch_patch_merge_base "$tree_root" "$tip" 2>/dev/null)" || lookup_status=$?
  case "$lookup_status" in
    0) ;;
    4)
      gate_emit_deny "PR merge gate: the tip of base branch ${pr_record_base} that GitHub reports (${tip:0:12}) is not a commit in this checkout, so the branch's own change cannot be measured against it for HEAD ${sha:0:12}. Run \`git fetch origin\` and retry gh pr merge."
      ;;
    3)
      gate_emit_deny "PR merge gate: HEAD ${sha:0:12} has more than one merge base with the tip of base branch ${pr_record_base} (${tip:0:12}), so the branch's own change is ambiguous. Run \`git merge --no-edit refs/remotes/origin/${pr_record_base}\` to make the merge base unique, then retry gh pr merge."
      ;;
    *)
      gate_emit_deny "PR merge gate: cannot derive the merge base of HEAD ${sha:0:12} and the tip of base branch ${pr_record_base} (${tip:0:12}). This usually means a shallow or damaged checkout. Run \`git fetch origin\` and retry gh pr merge."
      ;;
  esac

  # Arms this shell's classifier against the base the digests below measure,
  # the first point that base is known. The owner sets this gate trusts are
  # computed where they arm themselves (the digest library and the member
  # resolver); this keeps any direct classification here in agreement with them.
  audit_scope_release_context "$tree_root" "$merge_base" HEAD "$merge_base"

  digest_batch="$(audit_branch_digests_all "$tree_root" "$merge_base" 2>/dev/null)" || digest_batch=""
  if [ -z "$digest_batch" ]; then
    gate_emit_deny "PR merge gate: cannot derive per-member branch-own digests for HEAD ${sha:0:12} (audit_branch_digests_all failed or returned nothing). This usually means a missing sha256 tool (sha256sum / shasum -a 256), a git failure, a detached HEAD with no branch name to bind the digest to, or a corrupted checkout. Every Code Audit Team marker is keyed to a member's digest, so this gate denies rather than match against an empty or partial one. Restore the missing tool or checkout and retry."
  fi

  # Parse the batch into parallel arrays (bash 3.2 has no associative arrays,
  # mirroring the digest engine's own convention).
  local digest_line
  while IFS= read -r digest_line; do
    [ -n "$digest_line" ] || continue
    _DIGEST_MEMBER[${#_DIGEST_MEMBER[@]}]="${digest_line%%$'\t'*}"
    _DIGEST_VALUE[${#_DIGEST_VALUE[@]}]="${digest_line#*$'\t'}"
  done <<EOF
$digest_batch
EOF

  frontend_digest="$(member_digest code-audit-frontend)" || frontend_digest=""
  marker="$root/.gaia/local/audit/${frontend_digest}.ok"

  # A refusal for the frontend's CURRENT digest is checked before any earned
  # signal and is absolute: denies regardless of a same-digest earned marker.
  if [ -n "$frontend_digest" ] && clearance_member_refused "$root" "$frontend_digest" code-audit-frontend; then
    frontend_refused=1
    refusal_note="
A live refusal exists for this exact branch-own digest: $(clearance_refused_path "$root" "$frontend_digest" code-audit-frontend). A refusal always takes precedence over any earned marker for the same digest, and a bare re-spawn does NOT clear it: an ordinary earned write leaves the refusal in place, so re-running the agent against an unchanged, still-unaddressed patch refuses again. Clear it by resolving the finding with an edit to the branch's own patch on that member's paths (that rotates the digest, retiring this refusal); a fix that arrives only through a catch-up merge of the base branch does not rotate it, barring a base edit within three lines of a branch hunk on that member's paths. Or, when the operator acknowledges a Major with a stated reason and the digest does not move, re-spawn code-audit-frontend so it writes its earned marker with --supersede-refusal \"<reason>\", which removes its own refusal as an explicit, recorded act.
"
  fi
}

# Human-readable state of a local marker file for a deny message. The gate now
# accepts only a writer-produced clearance, so a file that exists but is not
# writer-shaped is neither "cleared" nor "missing": name that third state so an
# operator staring at a present marker while the gate says "missing" is not
# left guessing.
marker_state() {
  if [ -f "$1" ]; then
    printf '(present but not a valid clearance; re-run the member'\''s agent)'
  else
    printf '(missing)'
  fi
}

