# shellcheck shell=bash
#
# The one way GAIA takes a lock directory. Every mkdir-style lock calls
# gaia_exclusive_lock_take instead of treating `mkdir`'s exit status as
# ownership; each caller keeps its own deadline, poll and stale-reclaim rules.
#
# Why mkdir alone is not a lock: uutils coreutils (the /usr/bin/mkdir Ubuntu
# 26.04 ships) lets two racing `mkdir DIR` calls both exit 0, so both callers
# believed they held the lock and one read-modify-write was lost. Ownership is
# instead the creation of `<lock>/owner` under bash's noclobber, which bash
# opens with O_CREAT|O_EXCL itself (on every version back to 3.2), so exactly
# one contender creates it whatever mkdir reports. mkdir only has to create a
# missing directory, which every implementation does.
#
# Why not flock: macOS has none, so the portable path has to be exclusive on
# its own, and most callers hold the lock across function returns or for a
# whole process, which a flock needs a long-lived file descriptor for; bash
# 3.2 cannot allocate one without hard-coding a number a caller may already
# use. with-ledger-lock.sh, which runs one command inside the lock, keeps
# flock first and falls back to this.
#
# Honest limit: a bare directory with no owner file (a lock left by an older
# GAIA, or one caught between its taker's mkdir and owner write) is held only
# as long as a contender's mkdir fails on it. Every mkdir does when it is not
# racing a creation of the same directory, and the racing case is the one the
# owner file decides.
#
# Release removes the directory and its owner file, so a plain `rmdir` no
# longer releases a lock this took.
#
# Sourcing defines functions only and runs no external command. Bash 3.2
# compatible. Never `cd`s.

# gaia_exclusive_lock_take <lock-directory>: rc 0 when this call now owns it,
# with this shell's $$ in <lock-directory>/owner; rc 1 when anyone else does.
gaia_exclusive_lock_take() {
  local lock_directory="${1-}"
  [ -n "$lock_directory" ] || return 1
  mkdir "$lock_directory" 2>/dev/null || return 1
  ( set -C; printf '%s\n' "$$" >"$lock_directory/owner" ) 2>/dev/null
}

# gaia_exclusive_lock_release <lock-directory>: remove the lock; rc 0 even when
# it is already gone.
gaia_exclusive_lock_release() {
  rm -rf "${1-}" 2>/dev/null
  return 0
}
