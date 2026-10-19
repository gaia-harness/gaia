#!/usr/bin/env bash
# Writes the advisory id set `pnpm audit` reports for the current directory's
# tree, one id per line, sorted, to the given file, and only when the audit
# answered. The update-deps override audit diffs two of these sets to decide
# whether removing an override reintroduced an advisory, so an audit that
# errored (offline, rate limit, registry outage) must never read as an empty
# set: against an empty baseline no advisory is ever "introduced", and every
# security-floor override would be deleted as obsolete.
#
# Usage: bash .gaia/scripts/override-audit-advisory-ids.sh <output-file>
#
# Exit 0: the audit answered with an `advisories` object; the file holds its
#   keys (empty when there are none).
# Exit 1: the audit did not answer; the file is left empty and one stderr line
#   names the reason. The caller treats the set as unknown, never as empty.
# Exit 2: usage error, jq is missing, or the output file or its temporary
#   files cannot be written.
#
# `pnpm audit` exits non-zero whenever an advisory is open, so its exit status
# says nothing about whether it answered; the JSON shape is the only signal.
# A future pnpm that reports advisories under another key reads as not
# answered, which retains overrides rather than deleting them.
set -uo pipefail

output_file="${1-}"
if [ -z "$output_file" ]; then
  echo "usage: override-audit-advisory-ids.sh <output-file>" >&2
  exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "override-audit-advisory-ids: jq is required" >&2
  exit 2
fi

: >"$output_file" || exit 2

raw_json="$(mktemp "${output_file}.raw.XXXXXX")" || exit 2
raw_stderr="$(mktemp "${output_file}.err.XXXXXX")" || {
  rm -f "$raw_json"
  exit 2
}
trap 'rm -f "$raw_json" "$raw_stderr"' EXIT

pnpm audit --json >"$raw_json" 2>"$raw_stderr"

if jq -e '.advisories | type == "object"' "$raw_json" >/dev/null 2>&1; then
  if jq -r '.advisories | keys[]' "$raw_json" | LC_ALL=C sort -u >"$output_file"; then
    exit 0
  fi
  : >"$output_file"
  echo "pnpm audit did not answer: its advisory ids could not be read" >&2
  exit 1
fi

reason="$(jq -r '.error.message // empty' "$raw_json" 2>/dev/null | head -n 1)"
[ -n "$reason" ] || reason="$(grep -m 1 . "$raw_stderr")"
[ -n "$reason" ] || reason="pnpm audit produced no JSON"
echo "pnpm audit did not answer: ${reason}" >&2
exit 1
