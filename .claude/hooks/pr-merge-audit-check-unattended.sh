#!/usr/bin/env bash
# pr-merge-audit-check-unattended.sh: the merge gate's unattended-run arm, the autonomy switch's may_merge.
#
# One contiguous span of the merge gate. pr-merge-audit-check.sh sources it
# from its own directory before the repo-scope check, so it runs over the
# parent's globals ($GAIA_HOOK_CWD, $GAIA_HOOK_SESSION_ID, $command_line,
# $gate_arm_note); it is never run on its own. The parent denies when this file
# is missing or did not define _gate_log_unattended_merge.
#
# Bash 3.2 compatible (macOS-default bash).

# shellcheck disable=SC2034,SC2154  # the gate globals cross files: the parent sets and reads them

# While the autonomy switch is live, may_merge decides whether Claude merges at
# all; autonomy-lib.sh reads it and this gate never parses the switch.
# may_merge false denies every merge this gate arms on, `--auto` and another
# repository's included, before and independent of the clearance check.
# may_merge true leaves the merge to that check, and a merge it allows is
# appended to the decision log first; a failed append turns the allow into a
# deny, so the log never misses an unattended merge. The switch is resolved
# from the payload cwd, the checkout the session runs in, as the autonomy gate
# resolves it. A library that will not load denies: without it the gate cannot
# tell an unattended run from an attended one.

# Every decision after the arm goes to the decision file; this EXIT trap reads
# it, logs an allow, and prints the decision to the harness.
# shellcheck disable=SC2329 # invoked by the EXIT trap below
_gate_log_unattended_merge() {
  local decision
  exec 1>&3 3>&-
  decision=$(cat "$_gate_decision_file" 2>/dev/null)
  rm -f "$_gate_decision_file"
  case "$decision" in
    *'"permissionDecision"'*) printf '%s\n' "$decision" ;;
    *)
      if autonomy_log_decision "$GAIA_HOOK_SESSION_ID" "$(git -C "$_gate_payload_cwd" branch --show-current 2>/dev/null)" \
        'Unattended merge' "Allowed by the PR merge gate: $(printf '%.300s' "$command_line")" "$_gate_payload_cwd"; then
        [ -z "$decision" ] || printf '%s\n' "$decision"
      else
        jq -n --arg reason "Unattended run: the PR merge gate allows this merge but cannot append it to the decision log, so it denies. Park this run: bash $_gate_tree/.gaia/scripts/autonomy-park.sh --reason merge-ready --pr <n> --root $_gate_tree, then stop." '{
          hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}
        }'
      fi
      ;;
  esac
}

_gate_payload_cwd=$GAIA_HOOK_CWD
case "$_gate_payload_cwd" in /*) ;; *) _gate_payload_cwd=$PWD ;; esac
_gate_autonomy_library="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)/.gaia/scripts/autonomy-lib.sh"
# shellcheck source=/dev/null
if [ ! -f "$_gate_autonomy_library" ] || ! . "$_gate_autonomy_library" 2>/dev/null || ! type autonomy_log_decision >/dev/null 2>&1; then
  jq -n --arg reason "PR merge gate: cannot load .gaia/scripts/autonomy-lib.sh, so it cannot tell whether an unattended run is merging, and it denies. Restore the library (it ships with the framework) and retry.${gate_arm_note}" '{
    hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}
  }'
  exit 0
fi
if autonomy_active "$_gate_payload_cwd"; then
  _gate_tree=$(git -C "$_gate_payload_cwd" rev-parse --show-toplevel 2>/dev/null) || _gate_tree=$_gate_payload_cwd
  if [ "$(autonomy_field may_merge "$_gate_payload_cwd" 2>/dev/null)" != true ]; then
    jq -n --arg reason "Unattended run (the autonomy switch is live) with may_merge false: the PR is ready for you, and only a human merges it. Park this run: bash $_gate_tree/.gaia/scripts/autonomy-park.sh --reason merge-ready --pr <n> --root $_gate_tree (the pull request this merge names), then stop. Do not retry the merge by another command or spelling.${gate_arm_note}" '{
      hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}
    }'
    exit 0
  fi
  _gate_decision_file=$(mktemp "${TMPDIR:-/tmp}/pr-merge-gate.XXXXXX") || {
    jq -n --arg reason "PR merge gate: cannot create a temporary file, so it cannot log this unattended merge, and it denies. Check TMPDIR and retry.${gate_arm_note}" '{
      hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}
    }'
    exit 0
  }
  exec 3>&1 1>"$_gate_decision_file"
  trap '_gate_log_unattended_merge' EXIT
fi
