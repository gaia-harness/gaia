#!/usr/bin/env bats
# merge-report.md, the contract between the /update-gaia execution agent and
# the orchestrator, against the validator that enforces it. The statuses are
# derived from update-gaia-report.sh's own list, so prose and validator cannot
# name different sets; the open item kinds, option ids and option order table
# are pinned row by row; and a fixture report written to the contract
# validates with `validate --final`. Each pin has a red twin: a scratch copy
# of merge-report.md missing a status, or with a row's order swapped, fails
# the same check.
#
# Assertion style per .claude/rules/bats-assertions.md: no bare mid-test
# [[ ... ]]; POSIX [ ] and grep; `&& return 1` for a non-final absence.
#
# Maintainer-only. `.gaia/tests` is wholesale release-excluded.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
  MERGE_REPORT="$REPO_ROOT/.claude/skills/update-gaia/references/merge-report.md"
  SCRIPT="$REPO_ROOT/.gaia/scripts/update-gaia-report.sh"
  FIXTURES="$BATS_TEST_DIRNAME/fixtures/update-gaia-report"
  COPY="$BATS_TEST_TMPDIR/merge-report-copy.md"
}

# The statuses the validator accepts, one per line, read from its own list.
validator_statuses() {
  sed -n 's/^ *def statuses: \[\(.*\)\];$/\1/p' "$SCRIPT" | tr ',' '\n' | tr -d '" '
}

KINDS='text-conflict same-concern-gaia same-concern-adopter contradictory binary merge-error absent-baseline version-pin field-conflict removal'

# Each option's row prefix in the options table: id, label, decision.
# shellcheck disable=SC2016  # literal markdown, nothing expands
OPTION_ROWS=(
  '| `combine` | Combine both | `blend` |'
  '| `keep` | Keep mine | `keep` |'
  '| `gaia` | Take GAIA'"'"'s | `gaia` |'
  '| `higher` | Use the higher version | `gaia` when the value is GAIA'"'"'s, `keep` when it is the adopter'"'"'s |'
  '| `remove` | Remove | `gaia` |'
  '| `defer` | Decide later | `deferred` |'
)

# The option order table, row for row.
# shellcheck disable=SC2016  # literal markdown, nothing expands
ORDER_ROWS=(
  '| `text-conflict` (combining meaningful) | `combine` | `combine, keep, gaia, defer` |'
  '| `text-conflict` (combining not meaningful) | class fallback: `keep` for shared and wiki-owned, `gaia` for owned | recommended, then the other of `keep`/`gaia`, then `defer` (no `combine`) |'
  '| `same-concern-gaia` | `combine` (GAIA'"'"'s version of that concern, the adopter'"'"'s other edits kept) | `combine, keep, gaia, defer` |'
  '| `same-concern-adopter` | `combine` (both parts kept), with `suggestion` set | `combine, keep, gaia, defer` |'
  '| `contradictory` | whichever fits, with `reason` | recommended, then the rest of `combine, keep, gaia` in that order, then `defer` |'
  '| `binary`, `merge-error` | class fallback as above | recommended, then the other of `keep`/`gaia`, then `defer` |'
  '| `absent-baseline` | `keep` | `keep, gaia, defer` |'
  '| `version-pin` with a strictly higher side | `higher` | `higher, keep, gaia, defer` |'
  '| `version-pin` without one (equal lower bounds, a non-semver spec) | `keep` | `keep, gaia, defer` |'
  '| `field-conflict` (any non-version key) | `keep` | `keep, gaia, defer` |'
  '| `removal`, nothing references the file | `remove` | `remove, keep, defer` |'
  '| `removal`, a tracked file references it | `keep` | `keep, remove, defer` |'
)

# Prints each contract element missing from merge-report.md copy `$1`.
contract_violations() {
  local file="$1" status kind row
  while IFS= read -r status; do
    [ -n "$status" ] || continue
    grep -q "^- \`$status\`: " "$file" || printf 'status %s\n' "$status"
  done <<EOF
$(validator_statuses)
EOF
  for kind in $KINDS; do
    grep -q "^- \`$kind\`: " "$file" || printf 'kind %s\n' "$kind"
  done
  for row in "${OPTION_ROWS[@]}"; do
    grep -qF -- "$row" "$file" || printf 'option row %s\n' "$row"
  done
  for row in "${ORDER_ROWS[@]}"; do
    grep -qxF -- "$row" "$file" || printf 'order row %s\n' "$row"
  done
}

@test "the derived and pinned sets are the size the contract defines" {
  [ "$(validator_statuses | grep -c .)" -eq 10 ]
  [ "$(printf '%s\n' $KINDS | grep -c .)" -eq 10 ]
  [ "${#OPTION_ROWS[@]}" -eq 6 ]
  [ "${#ORDER_ROWS[@]}" -eq 12 ]
}

@test "merge-report.md defines every status, kind and option, and carries every option order row" {
  [ -z "$(contract_violations "$MERGE_REPORT")" ]
}

@test "a copy missing one status definition is reported" {
  grep -v '^- `pending-judgment`: ' "$MERGE_REPORT" > "$COPY"
  contract_violations "$COPY" | grep -qxF 'status pending-judgment'
}

@test "a copy with one option order row swapped is reported" {
  sed 's/^| `removal`, nothing references the file | `remove` | `remove, keep, defer` |$/| `removal`, nothing references the file | `remove` | `keep, remove, defer` |/' "$MERGE_REPORT" > "$COPY"
  cmp -s "$MERGE_REPORT" "$COPY" && return 1
  contract_violations "$COPY" | grep -qF 'order row | `removal`, nothing references the file'
}

@test "a copy mapping an option to the wrong decision is reported" {
  sed 's/^| `remove` | Remove | `gaia` |/| `remove` | Remove | `deferred` |/' "$MERGE_REPORT" > "$COPY"
  cmp -s "$MERGE_REPORT" "$COPY" && return 1
  contract_violations "$COPY" | grep -qF 'option row | `remove`'
}

# --- A fixture report written to the contract validates -----------------------

# Copies the fixture trees, manifests, decision log and run directory into
# $BATS_TEST_TMPDIR, resolving the fixture's one pending-judgment entry the way
# the orchestrator's chunk fold does, so the report is a final one.
final_fixture_setup() {
  WORK="$BATS_TEST_TMPDIR/work"
  mkdir -p "$WORK"
  cp -R "$FIXTURES/baseline" "$FIXTURES/latest" "$FIXTURES/tree" "$FIXTURES/deferred-baseline" "$FIXTURES/run" "$WORK/"
  cp "$FIXTURES/decisions.json" "$WORK/decisions.json"
  mkdir -p "$WORK/baseline/.gaia" "$WORK/latest/.gaia"
  cp "$FIXTURES/baseline-manifest.json" "$WORK/baseline/.gaia/manifest.json"
  cp "$FIXTURES/latest-manifest.json" "$WORK/latest/.gaia/manifest.json"
  REPORT="$WORK/run/report.json"
  jq '(.files[] | select(.status == "pending-judgment")) |= (.status = "auto-merged")' "$FIXTURES/run/report.json" > "$REPORT"
  [ "$(jq '[.files[] | select(.status == "pending-judgment")] | length' "$REPORT")" -eq 0 ]
}

run_final_validate() {
  run bash "$SCRIPT" validate --report "$REPORT" --run-dir "$WORK/run" \
    --baseline-dir "$WORK/baseline" --latest-dir "$WORK/latest" --decisions "$WORK/decisions.json" --final
}

@test "a fixture report written to the contract validates as final" {
  final_fixture_setup
  run_final_validate
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qE '^REPORT_OK [0-9]+$'
}

@test "every kind and status the fixture report uses is one merge-report.md defines" {
  final_fixture_setup
  local value
  while IFS= read -r value; do
    [ -n "$value" ] || continue
    grep -q "^- \`$value\`: " "$MERGE_REPORT" || { echo "undocumented: $value" >&2; return 1; }
  done <<EOF
$(jq -r '[.files[].status, (.files[].items // [] | .[].kind)] | unique | .[]' "$REPORT")
EOF
}

@test "a fixture item whose last option is not defer fails final validation" {
  final_fixture_setup
  local scratch="$BATS_TEST_TMPDIR/report.json"
  jq '(.files[] | select(.path == "oc-text-conflict.md") | .items[0].options) |= (.[:-1])' "$REPORT" > "$scratch"
  mv "$scratch" "$REPORT"
  run_final_validate
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -qF 'oc-text-conflict.md: item oc-text-conflict.md last option is not defer'
}
