# shellcheck shell=bash
#
# Which plan run a branch belongs to, and the security-row check the merge gate
# (.claude/hooks/test-design-merge-gate.sh) and the status post
# (.claude/hooks/post-audit-status.sh) share, so the two answer alike.
#
#   gaia_plan_folder_for_branch <main root> <branch>
#     Prints the plan folder whose RUNNING sentinel holds the line
#     `branch: <branch>`, searching <main>/.notebook/specs/*/plan*/RUNNING and
#     <main>/.notebook/plans/*/RUNNING. rc 0 found, 1 none, 2 more than one
#     (each claimant printed, one per line).
#
#   gaia_test_row_grants_file <main root> <branch key>
#     The maintainer's typed security-row grants for the branch, beside the
#     audit loop's round stamps in the protected folder, which only hooks write.
#
#   gaia_test_design_merge_verdict <tree root>
#     rc 0 when the merge may go ahead: the branch has no plan run, its plan
#     has no TEST-DESIGN marker, or every approved security row is covered or
#     granted. rc 1 otherwise, with the reason and the next step on stdout. It
#     fails closed: two plan runs claiming the branch, an unresolvable branch
#     key, a missing node or test-drift-check.sh, a refusal from the check, or
#     an unreadable grant file all answer rc 1.
#
#   gaia_test_design_status_verdict <tree root>
#     The same verdict for the status post: rc 0 allows; otherwise rc 1 with
#     the reason on one line, or `security-row check failed` when it gave none.
#
# A grant counts only while its recorded approved_sha256 equals the marker's,
# so a grant never outlives the approved table it was typed against.
#
# Sourcing loads main-root-lib.sh from beside this file's parent and defines
# functions only. Bash 3.2 compatible. Never `cd`s.

_gaia_plan_locate_directory="${BASH_SOURCE[0]%/*}"
[ "$_gaia_plan_locate_directory" = "${BASH_SOURCE[0]}" ] && _gaia_plan_locate_directory="."
_GAIA_PLAN_LOCATE_SCRIPTS="$_gaia_plan_locate_directory/.."
unset _gaia_plan_locate_directory
# shellcheck source=/dev/null
. "$_GAIA_PLAN_LOCATE_SCRIPTS/main-root-lib.sh"

gaia_plan_folder_for_branch() {
  local main="${1-}" branch="${2-}" sentinel line found='' count=0
  [ -n "$main" ] && [ -n "$branch" ] || return 1
  for sentinel in "$main"/.notebook/specs/*/plan*/RUNNING "$main"/.notebook/plans/*/RUNNING; do
    [ -f "$sentinel" ] || continue
    while IFS= read -r line || [ -n "$line" ]; do
      line="${line%$'\r'}"
      if [ "$line" = "branch: $branch" ]; then
        found="${found}${sentinel%/RUNNING}
"
        count=$((count + 1))
        break
      fi
    done <"$sentinel"
  done
  [ "$count" -gt 0 ] || return 1
  printf '%s' "$found"
  [ "$count" -eq 1 ] || return 2
  return 0
}

gaia_test_row_grants_file() {
  printf '%s/.gaia/local/protected/audit-loop/%s.d/test-row-grants.json\n' "$1" "$2"
}

# gaia_marker_approved_sha256 <plan dir>: the marker's approved_sha256, or nothing.
gaia_marker_approved_sha256() {
  local line value
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      approved_sha256:*)
        value="${line#approved_sha256:}"
        value="${value//[[:space:]]/}"
        printf '%s' "$value"
        return 0
        ;;
    esac
  done <"$1/TEST-DESIGN"
  return 0
}

gaia_test_design_merge_verdict() {
  local tree="${1-}" main branch plan locate_status key drift output drift_status
  local grants_file approved_sha granted='' ungranted='' row reason line
  local next_step="Next step: have the security writer write the missing test, or, when the maintainer rules the row satisfied, the maintainer types the whole prompt test-row-grant <row id> in an interactive session in this branch's checkout."
  main="$(gaia_resolve_main_root "$tree" 2>/dev/null)" || {
    printf 'Security-row merge gate: cannot resolve the main checkout of %s, so its plan run is unknown. Next step: run the merge from the checkout that holds the branch.\n' "$tree"
    return 1
  }
  branch="$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR git -C "$tree" branch --show-current 2>/dev/null)" || {
    printf 'Security-row merge gate: git cannot read the branch of %s. Next step: confirm the checkout is a working git repository and retry.\n' "$tree"
    return 1
  }
  # A detached HEAD is no branch, so no plan run can claim it.
  [ -n "$branch" ] || return 0
  locate_status=0
  plan="$(gaia_plan_folder_for_branch "$main" "$branch")" || locate_status=$?
  case "$locate_status" in
    0) ;;
    1) return 0 ;;
    *)
      printf 'Security-row merge gate: more than one plan run claims branch %s, so its test-design table is ambiguous:\n%s\nNext step: remove the RUNNING sentinel from every plan folder but the one that owns this branch.\n' "$branch" "$plan"
      return 1
      ;;
  esac
  [ -f "$plan/TEST-DESIGN" ] || return 0

  # shellcheck source=/dev/null
  key="$(. "$_GAIA_PLAN_LOCATE_SCRIPTS/audit-loop-state-lib.sh" 2>/dev/null && gaia_loop_key "$tree" 2>/dev/null)" || key=''
  if [ -z "$key" ]; then
    printf 'Security-row merge gate: cannot derive the branch key for %s from .gaia/scripts/audit-loop-state-lib.sh, so its grants cannot be read. Next step: restore the GAIA scripts and retry.\n' "$branch"
    return 1
  fi
  drift="$_GAIA_PLAN_LOCATE_SCRIPTS/test-drift-check.sh"
  if [ ! -f "$drift" ]; then
    printf 'Security-row merge gate: .gaia/scripts/test-drift-check.sh is missing, so the approved security rows of %s cannot be checked. Next step: restore it from the GAIA release and retry.\n' "$plan"
    return 1
  fi
  if ! command -v node >/dev/null 2>&1; then
    printf 'Security-row merge gate: node is not on PATH, so the approved security rows of %s cannot be checked. Next step: install node and retry.\n' "$plan"
    return 1
  fi

  drift_status=0
  output="$(bash "$drift" security --root "$tree" --plan-dir "$plan" 2>&1)" || drift_status=$?
  case "$drift_status" in
    0) return 0 ;;
    1) ;;
    *)
      printf 'Security-row merge gate: the security check refused the test-design table in %s (exit %s): %s\nNext step: restore the plan folder files (TEST-DESIGN, tests.json, tests.approved.json) so the approved copy matches the marker, then retry.\n' "$plan" "$drift_status" "$output"
      return 1
      ;;
  esac

  grants_file="$(gaia_test_row_grants_file "$main" "$key")"
  approved_sha="$(gaia_marker_approved_sha256 "$plan")"
  if [ -e "$grants_file" ]; then
    if ! command -v jq >/dev/null 2>&1; then
      printf 'Security-row merge gate: jq is missing, so the grant file %s cannot be read. Next step: install jq and retry.\n' "$grants_file"
      return 1
    fi
    granted="$(jq -r --arg sha "$approved_sha" '.grants[] | select(.approved_sha256 == $sha) | .row' "$grants_file" 2>/dev/null)" || {
      printf 'Security-row merge gate: the grant file %s is unreadable. Next step: a human repairs or moves it aside outside Claude, then the maintainer types the grant again.\n' "$grants_file"
      return 1
    }
  fi
  while IFS= read -r line; do
    case "$line" in
      'uncovered '*) ;;
      *) continue ;;
    esac
    line="${line#uncovered }"
    row="${line%% *}"
    reason="${line#"$row"}"
    reason="${reason# }"
    case "
$granted
" in
      *"
$row
"*) continue ;;
    esac
    ungranted="${ungranted}  ${row}: ${reason}
"
  done <<<"$output"
  [ -n "$ungranted" ] || return 0
  printf 'Security-row merge gate: an approved security row of %s has no matching test on this branch:\n%s%s\n' "$plan" "$ungranted" "$next_step"
  return 1
}

gaia_test_design_status_verdict() {
  local verdict
  verdict="$(gaia_test_design_merge_verdict "${1-}")" && return 0
  printf '%s' "${verdict:-security-row check failed}" | tr '\n' ' '
  return 1
}
