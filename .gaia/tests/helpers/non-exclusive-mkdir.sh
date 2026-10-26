#!/usr/bin/env bash
# Shared bats primitive: a PATH whose `mkdir` is not exclusive.
#
#   . "$REPO_ROOT/.gaia/tests/helpers/non-exclusive-mkdir.sh"
#   PATH="$(non_exclusive_mkdir_path)"
#
# uutils coreutils (Ubuntu 26.04's /usr/bin/mkdir) lets two racing
# `mkdir DIR` calls both exit 0, so a lock that treats mkdir's exit status as
# ownership admits two holders. The race only shows under contention, so a
# suite cannot rely on hitting it. This shim makes the failure deterministic:
# every call creates what is missing and exits 0, even when the directory
# already exists, which is the worst case any non-exclusive mkdir can produce.
# A lock that stays exclusive on this PATH does not depend on mkdir's exit
# status for ownership.

# non_exclusive_mkdir_path: print $PATH with the shim's directory first.
non_exclusive_mkdir_path() {
  local shim_directory="$BATS_TEST_TMPDIR/non-exclusive-mkdir" real_mkdir
  real_mkdir="$(command -v mkdir)" || return 1
  "$real_mkdir" -p "$shim_directory" || return 1
  printf '#!/bin/sh\n"%s" -p "$@" 2>/dev/null\nexit 0\n' "$real_mkdir" >"$shim_directory/mkdir" || return 1
  chmod +x "$shim_directory/mkdir" || return 1
  printf '%s:%s\n' "$shim_directory" "$PATH"
}
