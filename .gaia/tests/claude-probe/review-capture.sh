#!/usr/bin/env bash
# Runs the review child's exact argv once over a chosen range and writes a capture
# directory the measured constants are read from. Paid, by hand only; nothing runs
# it in CI.
#
#   review-capture.sh --root <abs> --base <sha> --head <sha> --out <abs> --guard-script <abs>
#
# --root is the checkout under review and --out is the attempt directory. The flags
# and settings come from this checkout's audit-code-review.sh, so a capture from the
# build branch measures the shipped flags over any range, including a merged head
# holding no such script. --guard-script names the build checkout's guard for the
# same reason. The child runs with no supervisor deadline, since the deadline is
# what the capture's duration exists to set.
#
# Writes: result.json, child-settings.json, guard-denials.jsonl, stderr.txt,
# argv.txt, tree-before.txt, tree-after.txt, exit.txt, duration-seconds.txt.
set -euo pipefail

ROOT="" BASE="" HEAD="" OUT="" GUARD_SCRIPT=""
while [ $# -gt 0 ]; do
  [ $# -ge 2 ] || { printf 'review-capture: %s needs a value\n' "$1" >&2; exit 2; }
  case "$1" in
    --root) ROOT="$2" ;;
    --base) BASE="$2" ;;
    --head) HEAD="$2" ;;
    --out) OUT="$2" ;;
    --guard-script) GUARD_SCRIPT="$2" ;;
    *) printf 'review-capture: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
  shift 2
done
for required in "$ROOT" "$BASE" "$HEAD" "$OUT" "$GUARD_SCRIPT"; do
  [ -n "$required" ] || { printf 'review-capture: --root --base --head --out --guard-script are all required\n' >&2; exit 2; }
done

REVIEW_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../scripts" && pwd)/audit-code-review.sh"

mkdir -p "$OUT"
: >"$OUT/guard-denials.jsonl"
bash "$REVIEW_SCRIPT" settings --root "$ROOT" --attempt-dir "$OUT" --guard-script "$GUARD_SCRIPT" >"$OUT/child-settings.json"

child_argv=()
while IFS= read -r argument; do
  child_argv+=("$argument")
done < <(bash "$REVIEW_SCRIPT" child-argv --target "$BASE...$HEAD" --settings-file "$OUT/child-settings.json")
printf '%s\n' ${child_argv[@]+"${child_argv[@]}"} >"$OUT/argv.txt"

tree_snapshot() {
  git -C "$ROOT" branch --show-current
  git -C "$ROOT" rev-parse HEAD 'HEAD^{tree}'
  git -C "$ROOT" status --porcelain --untracked-files=all
}

tree_snapshot >"$OUT/tree-before.txt"
started_at="$(date +%s)"
child_status=0
# The working directory is part of the shipped route, so the child starts there
# the way the supervisor starts it.
( cd "$ROOT" && exec ${child_argv[@]+"${child_argv[@]}"} ) >"$OUT/result.json" 2>"$OUT/stderr.txt" </dev/null || child_status=$?
printf '%s\n' "$(($(date +%s) - started_at))" >"$OUT/duration-seconds.txt"
printf '%s\n' "$child_status" >"$OUT/exit.txt"
tree_snapshot >"$OUT/tree-after.txt"

printf 'capture: exit %s, %s seconds, %s\n' "$child_status" "$(cat "$OUT/duration-seconds.txt")" "$OUT"
