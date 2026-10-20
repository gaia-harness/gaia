#!/usr/bin/env bash
# shellcheck shell=bash
#
# Records the harness files an update blended, for the /gaia-fitness nudge.
#
# `/update-gaia` three-way merges the team's edits with GAIA's revisions. A
# clean both-sides merge (status auto-merged in the merge report) or an open
# item the team answered with Combine (a no-key `blend` decision) leaves two
# sets of instructions nobody has graded together. The merge report is deleted
# when the run ends, so this writer saves those files, stamped with the
# update's version, in <main-root>/.gaia/local/fitness/blend-record.json. The
# background refresher counts them once the main checkout reaches that version,
# until a fitness run answers them.
#
# Usage:
#   fitness-blend-record.sh record --main-root <abs> --tree <abs> \
#     --report <abs report.json> --decisions <abs update-decisions.json> \
#     --tag <vX.Y.Z>
#
# Outcomes (stdout, exit):
#   RECORDED <n>           the record was written; n entries now (0)
#   UNCHANGED <n>          the record already held exactly those n entries (0)
#   RECORD_FAILED <reason> the record is left as it was (3); reasons:
#                          jq-missing, report-unreadable, decisions-unreadable,
#                          fitness-check, write
#   usage on stderr        a missing or relative flag, a bad tag, an unknown
#                          subcommand (2)
#
# Entries from earlier updates stay while their update has landed on the main
# checkout and no fitness run has answered them since. A failed ledger read, an
# absent cache or an absent landing stamp keeps the entry: nudging once too
# often beats losing an unreviewed blend. bash 3.2 compatible; never `cd`.

set -u

LIBRARY_DIRECTORY="${BASH_SOURCE[0]%/*}"
# shellcheck source=.gaia/scripts/fitness-nudge-lib.sh
. "$LIBRARY_DIRECTORY/fitness-nudge-lib.sh"

SCRATCH_DIRECTORY=""
trap '[ -z "$SCRATCH_DIRECTORY" ] || rm -rf "$SCRATCH_DIRECTORY"; [ -z "${RECORD_TEMPORARY_FILE:-}" ] || rm -f "$RECORD_TEMPORARY_FILE"' EXIT

usage() {
  cat >&2 <<'USAGE'
usage: fitness-blend-record.sh record --main-root <abs> --tree <abs> --report <abs report.json> --decisions <abs update-decisions.json> --tag <vX.Y.Z>
USAGE
  exit 2
}

fail() {
  printf 'RECORD_FAILED %s\n' "$1"
  exit 3
}

[ "$#" -ge 1 ] && [ "$1" = record ] || usage
shift

MAIN_ROOT="" TREE="" REPORT="" DECISIONS="" TAG=""
while [ "$#" -gt 0 ]; do
  [ "$#" -ge 2 ] || usage
  case "$1" in
    --main-root) MAIN_ROOT=$2 ;;
    --tree) TREE=$2 ;;
    --report) REPORT=$2 ;;
    --decisions) DECISIONS=$2 ;;
    --tag) TAG=$2 ;;
    *) usage ;;
  esac
  shift 2
done

for required_path in "$MAIN_ROOT" "$TREE" "$REPORT" "$DECISIONS"; do
  case "$required_path" in
    /*) ;;
    *) usage ;;
  esac
done
tag_pattern='^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$'
[[ $TAG =~ $tag_pattern ]] || usage
VERSION=${TAG#v}

command -v jq >/dev/null 2>&1 || fail jq-missing

SCRATCH_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/fitness-blend-record.XXXXXX")" || fail write

# Step 1: the blended paths.
jq -e 'type == "object" and (.files | type) == "array"' "$REPORT" >/dev/null 2>&1 || fail report-unreadable
combine_paths='[]'
if [ -e "$DECISIONS" ]; then
  combine_paths="$(jq -c --arg tag "$TAG" '
    (.decisions // []) as $decisions
    | if ($decisions | type) != "array" then error("decisions is not an array") else . end
    | [$decisions[] | select(type == "object" and .key == null and .decision == "blend" and .tag == $tag) | .path]
  ' "$DECISIONS" 2>/dev/null)" || fail decisions-unreadable
fi
blended_file="$SCRATCH_DIRECTORY/blended.txt"
jq -r --argjson combine "$combine_paths" '
  .files[]
  | select(type == "object" and (.path | type) == "string"
           and (.status == "auto-merged"
                or (.status == "open" and (.path as $path | $combine | index($path)))))
  | .path
' "$REPORT" | LC_ALL=C sort -u >"$blended_file" || fail report-unreadable

# Step 2: keep only the harness files.
fitness_report="$SCRATCH_DIRECTORY/fitness-report.json"
"$TREE/.gaia/cli/gaia" fitness check --json --root "$TREE" >"$fitness_report" 2>/dev/null
check_status=$?
if [ "$check_status" -gt 1 ] || ! gaia_fitness_report_usable "$fitness_report"; then
  fail fitness-check
fi
harness_file="$SCRATCH_DIRECTORY/harness.txt"
gaia_fitness_harness_paths "$fitness_report" >"$harness_file" || fail fitness-check
new_paths_file="$SCRATCH_DIRECTORY/new-paths.txt"
LC_ALL=C comm -12 "$blended_file" "$harness_file" >"$new_paths_file"
new_paths_json="$(jq -R -s -c 'split("\n") | map(select(length > 0))' "$new_paths_file")"

# Step 3: the existing record, keeping the entries still owed a review.
RECORD_DIRECTORY="$MAIN_ROOT/.gaia/local/fitness"
RECORD_FILE="$RECORD_DIRECTORY/blend-record.json"
kept_entries='[]'
if [ -e "$RECORD_FILE" ] && jq -e '
      type == "object" and .version == 1 and (.entries | type) == "array"
      and all(.entries[]; type == "object"
              and (.path | type) == "string" and (.version | type) == "string")
    ' "$RECORD_FILE" >/dev/null 2>&1; then
  main_version="$(tr -d '[:space:]' <"$MAIN_ROOT/.gaia/VERSION" 2>/dev/null)"
  close_epoch="$(gaia_fitness_newest_close "$MAIN_ROOT/.gaia/local/telemetry/usage.jsonl" 2>/dev/null)" || close_epoch=""
  kept_versions='[]'
  while IFS= read -r entry_version; do
    [ -n "$entry_version" ] || continue
    gaia_fitness_version_reached "$main_version" "$entry_version" || continue
    landed_epoch="$(jq -r --arg version "$entry_version" '
      .fitnessBlendLandedAt[$version] | if type == "number" then floor else empty end
    ' "$MAIN_ROOT/.gaia/local/cache/shared/update-check.json" 2>/dev/null)" || landed_epoch=""
    if [ -n "$close_epoch" ] && [ -n "$landed_epoch" ] && [ "$close_epoch" -gt "$landed_epoch" ]; then
      continue
    fi
    kept_versions="$(jq -c --arg version "$entry_version" '. + [$version]' <<<"$kept_versions")"
  done <<<"$(jq -r '[.entries[].version] | unique[]' "$RECORD_FILE")"
  kept_entries="$(jq -c --argjson versions "$kept_versions" \
    '[.entries[] | select(.version as $version | $versions | index($version)) | {path, version}]' "$RECORD_FILE")"
fi

# Steps 4 and 5: merge, serialize with one fixed formatting, write atomically.
new_record="$SCRATCH_DIRECTORY/new-record.json"
jq -n --indent 2 --argjson kept "$kept_entries" --argjson paths "$new_paths_json" --arg version "$VERSION" '
  {version: 1,
   entries: (([$kept[] | select(.path as $path | $paths | index($path) | not)]
              + [$paths[] | {path: ., version: $version}])
             | sort_by(.path))}
' >"$new_record" || fail write
entry_count="$(jq '.entries | length' "$new_record")"

if [ -e "$RECORD_FILE" ]; then
  if cmp -s "$new_record" "$RECORD_FILE"; then
    printf 'UNCHANGED %s\n' "$entry_count"
    exit 0
  fi
elif [ "$entry_count" -eq 0 ]; then
  printf 'UNCHANGED 0\n'
  exit 0
fi

mkdir -p "$RECORD_DIRECTORY" 2>/dev/null || fail write
RECORD_TEMPORARY_FILE="$(mktemp "$RECORD_DIRECTORY/.blend-record.XXXXXX" 2>/dev/null)" || fail write
if ! cp "$new_record" "$RECORD_TEMPORARY_FILE" 2>/dev/null || ! mv "$RECORD_TEMPORARY_FILE" "$RECORD_FILE" 2>/dev/null; then
  fail write
fi
RECORD_TEMPORARY_FILE=""
printf 'RECORDED %s\n' "$entry_count"
