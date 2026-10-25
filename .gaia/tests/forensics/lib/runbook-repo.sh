#!/usr/bin/env bash
# Prints the issue target the forensics runbook files against: the value after
# `--repo` on the `--repo` line of its `gh issue create` block. Reads the path
# from FORENSICS_RUNBOOK when set and non-empty (so a drift check can point at
# a scratch copy), else the real runbook relative to the suite's directory.
# Returns non-zero with a message on stderr unless exactly one value is found.
#
# Usage in a suite: RUNBOOK_REPO="$(runbook_repo "$BATS_TEST_DIRNAME")"

runbook_repo() {
  local suite_directory="$1"
  local runbook="${FORENSICS_RUNBOOK:-}"
  if [[ -z "$runbook" ]]; then
    runbook="$suite_directory/../../../.claude/skills/gaia/references/forensics.md"
  fi
  if [[ ! -f "$runbook" ]]; then
    printf 'runbook_repo: runbook not found: %s\n' "$runbook" >&2
    return 1
  fi

  local values
  values="$(sed -nE 's/^[[:space:]]*--repo[[:space:]]+([^[:space:]]+)[[:space:]]*\\?[[:space:]]*$/\1/p' "$runbook")"
  local count
  count="$(printf '%s' "$values" | grep -c . || true)"
  if [[ "$count" -ne 1 ]]; then
    printf 'runbook_repo: expected exactly one --repo value in %s, found %s\n' "$runbook" "$count" >&2
    return 1
  fi
  printf '%s\n' "$values"
}
