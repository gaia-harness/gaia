#!/usr/bin/env bash
# bounded-install.sh: run one dependency install under a wall-clock bound, and
# retry it once when the bound ends it.
#
# Usage:
#   bounded-install.sh --attempt-seconds <n> -- <install command...>
#
# Why a wall-clock bound: pnpm's `fetch-timeout` ends a request only after it
# goes that long without receiving any data, so a registry response that keeps
# trickling in is never cut off, and pnpm has no setting that bounds a
# request's total time. The lockfile's supply-chain check fetches registry
# metadata before anything installs, and one such response has held an install
# for almost ten minutes. A fresh attempt opens new connections, so a retry
# usually finishes in the normal tens of seconds.
#
# `--kill-after` gives the install 15 seconds to exit on TERM before KILL, so
# a hung pnpm cannot outlive the bound by more than that.
#
# Exit status: 0 installed; the install's own status when it failed for any
# reason but the bound; timeout's 124 (or 137 when KILL was needed) when the
# bound ended both attempts; 2 usage error.

set -uo pipefail

usage() {
  echo "usage: bounded-install.sh --attempt-seconds <n> -- <install command...>" >&2
  exit 2
}

attempt_seconds=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --attempt-seconds) [ "$#" -ge 2 ] || usage; attempt_seconds="$2"; shift 2 ;;
    --) shift; break ;;
    *) usage ;;
  esac
done
case "$attempt_seconds" in '' | *[!0-9]*) usage ;; esac
[ "$attempt_seconds" -gt 0 ] && [ "$#" -gt 0 ] || usage

for attempt in 1 2; do
  exit_status=0
  timeout --kill-after=15 "$attempt_seconds" "$@" || exit_status=$?
  case "$exit_status" in
    0) exit 0 ;;
    124 | 137) ;;
    *) exit "$exit_status" ;;
  esac
  if [ "$attempt" -eq 1 ]; then
    echo "::warning::The install exceeded its ${attempt_seconds}s bound, most likely on a slow npm registry response; retrying once."
  fi
done
echo "::error::The install exceeded its ${attempt_seconds}s bound on both attempts, so the npm registry is slow or unreachable. Re-run the failed jobs once it recovers, or raise the gaia-setup-node install-attempt-seconds input if installs here legitimately take longer."
exit "$exit_status"
