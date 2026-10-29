#!/usr/bin/env bash
# pr-merge-audit-check-bypass.sh: the out-of-scope bypass, the legacy clearance predicates, and the bypass status stamp.
#
# One contiguous span of the merge gate, moved here unchanged.
# pr-merge-audit-check.sh sources it from its own directory at the point the
# span stood, so it runs in the same order over the same globals; it is never
# run on its own. $root, the main checkout every marker path joins onto, is
# the one the parent derives through main-root-lib.sh (gaia_resolve_main_root).
#
# Bash 3.2 compatible (macOS-default bash).

# shellcheck disable=SC2034,SC2154  # the gate globals cross files: the parent and the other siblings set and read them

# Out-of-scope bypass: accept the merge when every file this PR changes lives
# on a surface outside audit scope. The agent has no rules that apply to wiki,
# instruction files, .gaia metadata, or prose, so there is nothing to audit and
# no marker is required. The allowlist itself lives in the
# shared classifier (audit_out_of_scope_allowlisted), the ONE place this
# literal set is defined.
# Legacy-gate only: a non-empty dispatched set never reaches this function; an in-scope path no
# member owns dispatches nobody and lands here.
#
# Strict allowlist, evaluated fail-closed: the diff base must resolve, the diff
# must be non-empty OR its emptiness must be decisive under
# gate_empty_is_decisive above, and EVERY path must be out of scope. Any
# unresolved base, diff error, or in-scope path (frontend/app/, frontend/test/, configs,
# .github/workflows/) falls through to the normal deny. A PR that touches
# auditable source therefore can never reach this bypass, it cannot mask an
# audit that withheld its marker over unresolved findings, since that PR's diff
# carries in-scope paths by definition; and a decisive empty range says the
# merge introduces no content into its base at all, so there is nothing for a
# withheld marker to have been withheld over. No dependence on a CI stamp; the
# one network read is the base branch behind gate_resolve_base() above, whose
# failure widens the diff.
#
# Sets $out_of_scope_unbound when every changed path is out of scope and only
# the command binding fails, for the same reason $chore_deps_unbound exists.
out_of_scope_unbound=0
check_out_of_scope_pr() {
  # The merge base scopes the diff to THIS PR's changes, not unrelated drift
  # already on the base branch.
  gate_resolve_base
  [ -n "$gate_base" ] || return 1

  # Newline-delimited, derived NUL-delimited so git's default core.quotePath
  # cannot C-quote a non-ASCII path into a form the classifier below reads as an
  # unrecognized string. A non-zero return is a diff that never ran, which is
  # never an empty change set, so it denies here rather than reaching the
  # emptiness arm below.
  changed="$(audit_provenance_changed_files "$tree_root" "$gate_base")" || return 1

  # This runs before gate_require_digests arms the classifier, so arm it here
  # against the same base: a release-bookkeeping change allowlists its paths
  # only once the release context has seen it, and the member resolver that
  # dispatched nobody armed the same way.
  audit_scope_release_context "$tree_root" "$gate_base"

  if [ -z "$changed" ]; then
    # A REAL empty change set. Whether it clears this gate is the record-bound
    # question above, not this function's to answer: a locally-derived base, an
    # unresolvable one, or a checkout that is not on the pull request being
    # merged all deny here.
    gate_empty_is_decisive || return 1
    # The permit itself stays a silent zero exit with empty stdout, the shape
    # every other permit in this hook has. The reason is a diagnostic line on
    # stderr, not a permissionDecision emission: an explicit allow would
    # short-circuit the permission system for every `gh pr merge` this gate
    # sees, which is a far larger concession than the one being made here.
    echo "PR merge gate: no Code Audit Team marker required for HEAD ${sha:0:12}: the base-to-HEAD range is empty and the base carries ${gate_trust} provenance (anchor ${gate_anchor}, base ${gate_base:0:12})." >&2
    return 0
  fi

  # First path the shared classifier does not allowlist makes the marker
  # mandatory.
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    audit_out_of_scope_allowlisted "$path" || return 1
  done <<< "$changed"

  # Bind to the pull request the COMMAND names, for the reason the chore(deps)
  # bypass above gives: every path checked so far belongs to the CURRENT
  # BRANCH's change set, which need not be the change set of the pull request
  # being merged. Placed here rather than at the top of this function on
  # purpose: the empty-change-set arm above routes through
  # gate_empty_is_decisive, which owns a strictly larger conjunct set including
  # this one, so hoisting would duplicate that call and blur which arm answers
  # for which conjuncts.
  if ! gate_command_names_the_record_pr; then
    out_of_scope_unbound=1
    return 1
  fi

  return 0
}

# code-audit-frontend clearance: the chore(deps) waiver first, since it needs no
# digest; then, with the digests derived, a live refusal for the current digest
# (absolute, ahead of every earned signal), then the marker, then the GitHub
# status. The waiver therefore outranks a refusal: honoring one needs the digest,
# hence the GitHub base lookup, which a manifest-only bump never makes. Reused by
# both the legacy gate and the member-aware gate below.
# Records which signal cleared in $frontend_cleared_by, because only the
# chore(deps) arm earns a bypass stamp.
frontend_cleared_by=""
frontend_cleared() {
  frontend_cleared_by=""
  # The chore(deps) waiver reads no digest, so it is asked first: a manifest-only
  # dependency bump never reaches the base lookup the digest signals below make.
  if check_chore_deps_pr; then
    frontend_cleared_by=chore-deps
    return 0
  fi
  gate_require_digests
  [ "$frontend_refused" -eq 1 ] && return 1
  if clearance_member_cleared "$root" "$frontend_digest" code-audit-frontend; then
    frontend_cleared_by=marker
    return 0
  fi
  if github_status_cleared; then
    frontend_cleared_by=github-status
    return 0
  fi
  return 1
}

# github_status_cleared [any-digest]: check_github_status, asked at most once
# per run and form. The stamp decision asks the any-digest form, which needs no
# digest, so a bypass pull request never derives one.
github_status_answer=""
github_status_any_digest_answer=""
github_status_cleared() {
  if [ "${1:-}" = any-digest ]; then
    if [ -z "$github_status_any_digest_answer" ]; then
      github_status_any_digest_answer=no
      check_github_status any-digest && github_status_any_digest_answer=yes
    fi
    [ "$github_status_any_digest_answer" = yes ]
    return
  fi
  if [ -z "$github_status_answer" ]; then
    github_status_answer=no
    check_github_status && github_status_answer=yes
  fi
  [ "$github_status_answer" = yes ]
}

# gate_post_bypass_stamp <description>: post the GAIA-Audit bypass status for
# the pull request this run classified. Every caller has already established,
# through gate_command_names_the_record_pr, that the merge names the record's pull
# request, so the record's number is the one to stamp. The record's head must
# also be local HEAD, the content the classification read; otherwise the
# status would attest a head nobody classified, so it is skipped with the
# manual command instead. The POST goes to that verified sha ($sha), never to a
# second read of the pull request head, which a push could have moved.
gate_post_bypass_stamp() {
  local description="$1"
  resolve_pr_record
  if [ -z "$pr_record_number" ] || [ "$pr_record_head" != "$sha" ]; then
    printf 'GAIA-Audit bypass status not posted: pull request %s records head %s, not local HEAD %s, so this gate did not classify the head GitHub would mark. Push the branch and retry the merge, or post it by hand once the head is the classified one: gh api -X POST repos/{owner}/{repo}/statuses/<sha> -f state=success -f context=GAIA-Audit -f description='"'"'%s'"'"'\n' \
      "${pr_record_number:-<unknown>}" "${pr_record_head:-<unknown>}" "$sha" "$description" >&2
    return 0
  fi
  audit_post_bypass_status "$pr_record_number" "$sha" "$description"
}

