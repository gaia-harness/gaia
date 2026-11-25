#!/usr/bin/env bash
# pr-review-bundle.sh: builds the one input bundle the PR reviewer reads.
#
#   pr-review-bundle.sh --root <repository-root> --pr <number> --out <directory> [--spec <path>]
#
# Exit 0 prints the bundle directory. Exit 1 prints the fork refusal line, before
# any other gh call or file read. Exit 2 is a usage error, an unreadable PR or
# closed issue, or an --out under .gaia/local/ (the reviewer may not read there).
#
# The bundle holds the changed files, the diff, the spec, the PR body without
# its audit-written sections, the selected context files, and whether CHANGELOG.md
# and a PR template exist. It carries nothing from the audit run.
#
# Bash 3.2 compatible (macOS default). Never `cd` except inside a subshell that
# points gh at --root, since gh takes its repository from its working directory.

set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
hook_library_directory="$script_directory/../../.claude/hooks/lib"

usage() {
  printf 'usage: pr-review-bundle.sh --root <root> --pr <number> --out <directory> [--spec <path>]\n' >&2
  exit 2
}

root=""
pull_request=""
out_directory=""
spec_path=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --root) [ "$#" -ge 2 ] || usage; root="$2"; shift 2 ;;
    --pr) [ "$#" -ge 2 ] || usage; pull_request="$2"; shift 2 ;;
    --out) [ "$#" -ge 2 ] || usage; out_directory="$2"; shift 2 ;;
    --spec) [ "$#" -ge 2 ] || usage; spec_path="$2"; shift 2 ;;
    *) usage ;;
  esac
done
[ -n "$root" ] && [ -n "$pull_request" ] && [ -n "$out_directory" ] || usage
case "$pull_request" in
  ''|*[!0-9]*) usage ;;
esac

# shellcheck source=/dev/null
. "$hook_library_directory/cross-repo-refusal.sh"

# Fork refusal first: nothing else is read or asked of gh before this answer.
fork_status=0
(cd "$root" && gaia_pr_is_cross_repository "$pull_request") >/dev/null 2>&1 || fork_status=$?
if [ "$fork_status" -ne 1 ]; then
  printf 'PR review: refused, PR #%s is from a fork or its origin is unknown\n' "$pull_request"
  exit 1
fi

fail() {
  printf 'PR review bundle: %s\n' "$1" >&2
  exit 2
}

is_collaborator() {
  case "$1" in
    OWNER|MEMBER|COLLABORATOR) return 0 ;;
    *) return 1 ;;
  esac
}

# The reviewer may not read under .gaia/local/, so the bundle never lives there.
# The path is checked as written and as resolved, since in a linked worktree
# .gaia/local is a symlink into the main checkout.
case "$out_directory" in
  */.gaia/local|*/.gaia/local/*|.gaia/local|.gaia/local/*) fail "--out resolves under .gaia/local/" ;;
esac
mkdir -p "$out_directory" || fail "cannot create --out"
out_directory="$(cd "$out_directory" && pwd -P)"
case "$out_directory" in
  */.gaia/local|*/.gaia/local/*) fail "--out resolves under .gaia/local/" ;;
esac
if [ -n "$(ls -A "$out_directory")" ]; then
  fail "--out is not empty"
fi

for library in \
  "$hook_library_directory/audit-scope.sh" \
  "$hook_library_directory/pr-body-stamp.sh" \
  "$script_directory/pr-body-sections-lib.sh" \
  "$script_directory/pr-review-bundle-lib.sh"; do
  [ -f "$library" ] || fail "missing library $library"
  # shellcheck source=/dev/null
  . "$library"
done

if [ -n "$spec_path" ]; then
  case "$spec_path" in
    /*) ;;
    *) spec_path="$root/$spec_path" ;;
  esac
  [ -f "$spec_path" ] || fail "--spec file not found"
fi

pull_request_json="$(cd "$root" && gh pr view "$pull_request" --json baseRefName,body)" \
  || fail "gh could not read PR #$pull_request"
base_branch="$(printf '%s' "$pull_request_json" | jq -r '.baseRefName')"
pull_request_body="$(printf '%s' "$pull_request_json" | jq -r '.body // ""')"
[ -n "$base_branch" ] && [ "$base_branch" != "null" ] || fail "PR #$pull_request names no base branch"

reviewed_head="$(git -C "$root" rev-parse HEAD)" || fail "cannot resolve HEAD"
merge_base="$(git -C "$root" merge-base HEAD "origin/$base_branch")" \
  || fail "no merge base with origin/$base_branch"

git -C "$root" diff --no-renames --name-only -z "$merge_base" HEAD | tr '\0' '\n' >"$out_directory/changed-files.txt"
git -C "$root" diff --no-renames "$merge_base" HEAD >"$out_directory/diff.patch"

printf '%s\n' "$pull_request_body" | prb_strip_body >"$out_directory/pr-body.md"

# --- Spec: the --spec sections, then each closed issue's Done-when ----------

spec_present="none"
author_not_collaborator="false"
spec_file="$out_directory/spec.md"
: >"$spec_file"

if [ -n "$spec_path" ]; then
  prb_spec_sections "$spec_path" >>"$spec_file"
  spec_present="present"
fi

while IFS= read -r issue_number; do
  [ -n "$issue_number" ] || continue
  issue_json="$(cd "$root" && gh issue view "$issue_number" --json body,authorAssociation)" \
    || fail "gh could not read closed issue #$issue_number"
  issue_body="$(printf '%s' "$issue_json" | jq -r '.body // ""')"
  association="$(printf '%s' "$issue_json" | jq -r '.authorAssociation // ""')"
  section="$(printf '%s\n' "$issue_body" | prb_done_when)"
  if [ -z "$(printf '%s' "$section" | tr -d '[:space:]')" ]; then
    section="$issue_body"
  fi
  collaborator=1
  is_collaborator "$association" || { collaborator=0; author_not_collaborator="true"; }
  {
    printf '\n#%s\n' "$issue_number"
    [ "$collaborator" -eq 1 ] || printf 'spec author: not a collaborator\n'
    printf '%s\n' "$section"
  } >>"$spec_file"
  spec_present="present"
done <<EOF_ISSUES
$(prb_closed_issues "$pull_request_body")
EOF_ISSUES

if [ "$spec_present" = "none" ]; then
  printf 'spec: none\n' >"$spec_file"
fi

# --- Context files, CHANGELOG, template ---------------------------------------

prb_select_rules "$root" "$out_directory/changed-files.txt" >"$out_directory/rules.txt"

changelog_present="false"
if git -C "$root" ls-files --error-unmatch CHANGELOG.md >/dev/null 2>&1; then
  changelog_present="true"
fi

template_path=""
for template_candidate in \
  .github/pull_request_template.md \
  .github/PULL_REQUEST_TEMPLATE.md \
  pull_request_template.md \
  docs/pull_request_template.md; do
  if git -C "$root" ls-files --error-unmatch "$template_candidate" >/dev/null 2>&1; then
    template_path="$template_candidate"
    break
  fi
done

jq -n \
  --argjson pr "$pull_request" \
  --arg reviewed_head "$reviewed_head" \
  --arg base "$base_branch" \
  --arg spec "$spec_present" \
  --argjson spec_author_not_collaborator "$author_not_collaborator" \
  --argjson changelog_present "$changelog_present" \
  --argjson template_present "$([ -n "$template_path" ] && printf true || printf false)" \
  '{pr: $pr, reviewed_head: $reviewed_head, base: $base, spec: $spec,
    spec_author_not_collaborator: $spec_author_not_collaborator,
    changelog_present: $changelog_present, template_present: $template_present}' \
  >"$out_directory/meta.json"

{
  printf '# PR review input bundle\n\n'
  printf 'PR: #%s\n' "$pull_request"
  printf 'Reviewed head: %s\n' "$reviewed_head"
  printf 'Base: %s\n\n' "$base_branch"
  printf 'Files in this directory:\n'
  printf -- '- changed-files.txt: the changed paths, no rename detection; read each whole at HEAD\n'
  printf -- '- diff.patch: the diff from the merge base\n'
  printf -- '- spec.md: the spec to cover\n'
  printf -- '- pr-body.md: the PR body without its audit-written sections\n'
  printf -- '- rules.txt: CLAUDE.md and rule files to read whole\n'
  printf -- '- meta.json\n\n'
  if [ "$changelog_present" = true ]; then printf 'CHANGELOG.md: present\n'; else printf 'CHANGELOG.md: absent\n'; fi
  printf 'PR template: %s\n' "${template_path:-absent}"
} >"$out_directory/bundle.md"

printf '%s\n' "$out_directory"
