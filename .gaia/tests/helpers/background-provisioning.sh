#!/usr/bin/env bash
# Reads the background job provision-worktree.sh starts for a hook-triggered
# entry: its log path, and a bounded wait for the line it ends with.

# background_provisioning_log <tree>: the job's log, in the tree's own git directory.
background_provisioning_log() {
  printf '%s/gaia-provision.log\n' "$(git -C "$1" rev-parse --absolute-git-dir)"
}

# wait_for_background_provisioning <tree>: returns 0 once the job's log carries
# its finished line, 1 after ten seconds without it. The stubs a suite installs
# finish in milliseconds, so the bound only matters when the job never ends.
wait_for_background_provisioning() {
  local log_path remaining_attempts=100
  log_path="$(background_provisioning_log "$1")"
  while [ "$remaining_attempts" -gt 0 ]; do
    grep -qF -- "provision-worktree: provisioning finished" "$log_path" 2>/dev/null && return 0
    sleep 0.1
    remaining_attempts=$((remaining_attempts - 1))
  done
  return 1
}
