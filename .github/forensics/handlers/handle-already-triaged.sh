#!/usr/bin/env bash
# handle-already-triaged.sh: the idempotency early-exit.
#
# Logs a `::notice::` line and exits 0. No comment, no label, no PR.
# Called when the workflow finds the `gaia-triaged` label already on the
# issue (e.g. a concurrency-queued re-fire after a label add/remove).
#
# Usage:
#   handle-already-triaged.sh <issue-num>

set -euo pipefail

usage() {
  echo "usage: handle-already-triaged.sh <issue-num>" >&2
  exit 2
}

[ "$#" -eq 1 ] || usage
issue_number="$1"

printf '::notice::issue #%s already triaged; skipping\n' "$issue_number"

exit 0
