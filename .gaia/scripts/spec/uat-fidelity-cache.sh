#!/usr/bin/env bash
# Verdict cache for the uat-fidelity-judge at a spec-derived plan's pre-audit UAT
# checks. The orchestrator runs it from the resolved isolation root, per
# .claude/skills/gaia/references/spec/lifecycle.md `## Pre-audit UAT checks`.
#
#   uat-fidelity-cache.sh select <cache> --spec <SPEC> --brief <brief> --pending <out> --carried <out>
#   uat-fidelity-cache.sh record <cache> --spec <SPEC> --brief <brief> --carried <file> --verdicts <file> --out <out>
#
# <brief> holds the judge dispatch's `Spec:`, `Surface:` and `Guard:` lines for
# every owned test. `select` writes to --pending the lines of each test whose key
# has no cached verdict, writes the cached verdicts of the rest to --carried as a
# JSON array, and prints the pending `Spec:` count. `record` merges the judge's
# verdict file with --carried into --out, in brief order, and rewrites <cache>
# with those verdicts and their keys.
#
# A key covers what the judge reads to reach its verdict: the test file, the
# whole SPEC, the guard file, the surface, and the judge's own agent file. A
# SPEC reopen edits the SPEC, so it re-judges every test. Both verdicts are
# carried: re-judging an unchanged `diverges` would only re-roll it, and every
# fix for one changes the key. Honest limit: a wrong first `asserts` stays
# carried until its key changes, as it would on a run that never resumed.
#
# Exit codes: 0 done; 2 invalid input (usage, an unreadable file, a malformed
# brief or verdict file, a brief test with no verdict at record). A missing or
# unparseable cache is not an error: every test is pending.
set -uo pipefail

judge_agent_file='.claude/agents/uat-fidelity-judge.md'

fail() {
  printf 'uat-fidelity-cache.sh: %s\n' "$1" >&2
  exit 2
}

[ "$#" -ge 2 ] || fail 'usage: uat-fidelity-cache.sh select|record <cache> --spec <SPEC> --brief <brief> ...'
mode="$1"
cache_path="$2"
shift 2
case "$mode" in
  select | record) ;;
  *) fail "unknown subcommand: $mode" ;;
esac

spec_path=''
brief_path=''
pending_path=''
carried_path=''
verdicts_path=''
out_path=''
while [ "$#" -gt 0 ]; do
  [ "$#" -ge 2 ] || fail "$1 needs a value"
  case "$1" in
    --spec) spec_path="$2" ;;
    --brief) brief_path="$2" ;;
    --pending) pending_path="$2" ;;
    --carried) carried_path="$2" ;;
    --verdicts) verdicts_path="$2" ;;
    --out) out_path="$2" ;;
    *) fail "unknown option: $1" ;;
  esac
  shift 2
done
[ -n "$spec_path" ] || fail '--spec is required'
[ -n "$brief_path" ] || fail '--brief is required'
[ -n "$carried_path" ] || fail '--carried is required'
if [ "$mode" = select ]; then
  [ -n "$pending_path" ] || fail '--pending is required'
else
  [ -n "$verdicts_path" ] || fail '--verdicts is required'
  [ -n "$out_path" ] || fail '--out is required'
fi
[ -f "$brief_path" ] || fail "brief not found: $brief_path"

hash_file() {
  git hash-object -- "$1" 2>/dev/null || fail "cannot read $1"
}

spec_hash=$(hash_file "$spec_path") || exit 2
judge_hash=$(hash_file "$judge_agent_file") || exit 2

# One TSV row per Spec line, in brief order: uat_id, test path, surface, guard path.
brief_rows=$(awk '
  /^[ \t]*$/ { next }
  $1 == "Spec:" && NF == 3 { order[++count] = $2; test_path[$2] = $3; next }
  $1 == "Surface:" && NF == 3 { surface[$2] = $3; next }
  $1 == "Guard:" && NF == 3 { guard[$2] = $3; next }
  { printf "malformed brief line: %s\n", $0 > "/dev/stderr"; bad = 1 }
  END {
    if (bad || count == 0) exit 1
    for (index_number = 1; index_number <= count; index_number++) {
      id = order[index_number]
      printf "%s\t%s\t%s\t%s\n", id, test_path[id], surface[id], guard[id]
    }
  }
' "$brief_path") || fail "malformed brief: $brief_path"

entries='[]'
while IFS=$'\t' read -r uat_id test_path surface guard_path; do
  test_hash=$(hash_file "$test_path") || exit 2
  guard_hash='none'
  [ -z "$guard_path" ] || guard_hash=$(hash_file "$guard_path") || exit 2
  key=$(printf 'spec %s\ntest %s\nsurface %s\nguard %s\njudge %s\n' \
    "$spec_hash" "$test_hash" "$surface" "$guard_hash" "$judge_hash" | git hash-object --stdin)
  entries=$(jq -c --arg uat_id "$uat_id" --arg file "$test_path" --arg surface "$surface" \
    --arg guard "$guard_path" --arg key "$key" \
    '. + [{uat_id: $uat_id, file: $file, surface: $surface, guard: $guard, key: $key}]' <<<"$entries")
done <<<"$brief_rows"

if [ "$mode" = select ]; then
  cache='[]'
  if [ -f "$cache_path" ] && jq -e 'type == "array"' "$cache_path" >/dev/null 2>&1; then
    cache=$(jq -c '.' "$cache_path")
  fi
  carried=$(jq -c --argjson cache "$cache" '
    [ .[] as $entry
      | ($cache | map(select(.uat_id == $entry.uat_id and .file == $entry.file and .key == $entry.key)) | first)
      | select(. != null)
      | {uat_id, file, verdict, reason} ]' <<<"$entries")
  jq -r --argjson carried "$carried" '
    .[]
    | select(.uat_id as $id | $carried | map(.uat_id) | index($id) | not)
    | "Spec: \(.uat_id) \(.file)",
      (if .surface != "" then "Surface: \(.uat_id) \(.surface)" else empty end),
      (if .guard != "" then "Guard: \(.uat_id) \(.guard)" else empty end)' <<<"$entries" >"$pending_path" ||
    fail "cannot write $pending_path"
  printf '%s\n' "$carried" >"$carried_path" || fail "cannot write $carried_path"
  grep -c '^Spec: ' "$pending_path"
  exit 0
fi

jq -e 'type == "array"' "$verdicts_path" >/dev/null 2>&1 || fail "verdict file is not a JSON array: $verdicts_path"
jq -e 'type == "array"' "$carried_path" >/dev/null 2>&1 || fail "carried file is not a JSON array: $carried_path"
merged=$(jq -c --slurpfile judged "$verdicts_path" --slurpfile carried "$carried_path" '
  [ .[] as $entry
    | ((($judged[0] + $carried[0]) | map(select(.uat_id == $entry.uat_id)) | first)
       // error("no verdict for \($entry.uat_id)"))
    | {uat_id, file: $entry.file, verdict, reason, key: $entry.key} ]' <<<"$entries") ||
  fail 'a brief test has no verdict in the judge file or the carried file'

jq '[.[] | del(.key)]' <<<"$merged" >"$out_path" || fail "cannot write $out_path"
cache_directory=$(dirname -- "$cache_path")
temporary_cache=$(mktemp "$cache_directory/.uat-fidelity-cache.XXXXXX") || fail "cannot write in $cache_directory"
if ! jq '.' <<<"$merged" >"$temporary_cache" || ! mv -f -- "$temporary_cache" "$cache_path"; then
  rm -f -- "$temporary_cache"
  fail "cannot write $cache_path"
fi
exit 0
