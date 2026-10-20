#!/usr/bin/env bats
#
# The blend-record writer (.gaia/scripts/fitness-blend-record.sh): which files
# an update blended, the harness filter, the union with earlier entries, the
# drop rules (never landed, already answered), every refusal leaving the record
# untouched, the usage errors, the no-ops and the atomic write. Every case
# builds a fixture main root (version file, optional ledger and cache), a
# fixture tree whose stub CLI prints a fixture fitness report, a merge report
# and a decisions file under $BATS_TEST_TMPDIR.
#
# Run under bash 5: `bash .gaia/scripts/bats5.sh
# .gaia/scripts/tests/fitness-blend-record.bats < /dev/null`.

# shellcheck disable=SC2016 # the Markdown code spans here are literal
bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  WRITER="$REPO_ROOT/.gaia/scripts/fitness-blend-record.sh"
  if ! command -v jq >/dev/null 2>&1; then
    if [ -n "${GITHUB_ACTIONS:-}" ]; then
      echo "jq not present on a CI runner; these probes would report green" >&2
      return 1
    fi
    skip "jq required"
  fi
  MAIN="$BATS_TEST_TMPDIR/main"
  TREE="$BATS_TEST_TMPDIR/tree"
  RUN_DIR="$BATS_TEST_TMPDIR/run"
  RECORD_DIR="$MAIN/.gaia/local/fitness"
  RECORD="$RECORD_DIR/blend-record.json"
  LEDGER="$MAIN/.gaia/local/telemetry/usage.jsonl"
  CACHE="$MAIN/.gaia/local/cache/shared/update-check.json"
  REPORT="$RUN_DIR/report.json"
  DECISIONS="$RUN_DIR/update-decisions.json"
  TAG="v2.0.5"
  mkdir -p "$MAIN/.gaia" "$TREE/.gaia/cli" "$RUN_DIR"
  printf '2.0.4\n' >"$MAIN/.gaia/VERSION"
  write_stub 0
}

# The stub CLI: prints the fixture report, exits with the fixture status, and
# records its arguments.
write_stub() {
  cat >"$TREE/.gaia/cli/gaia" <<'STUB'
#!/usr/bin/env bash
here="${0%/*}"
printf '%s\n' "$*" >"$here/stub-args"
cat "$here/stub-report.json"
exit "$(cat "$here/stub-exit")"
STUB
  chmod +x "$TREE/.gaia/cli/gaia"
  printf '%s\n' "$1" >"$TREE/.gaia/cli/stub-exit"
  printf '{}\n' >"$TREE/.gaia/cli/stub-report.json"
}

# inventory_from_lines: stdin lines `path kind ownership` to an inventory array.
inventory_from_lines() {
  jq -R -s -c '
    split("\n") | map(select(length > 0) | split(" "))
    | map({path: .[0], kinds: [.[1]], ownership: .[2]})'
}

# stub_report: stdin lines `path kind ownership` become the stub's report.
stub_report() {
  local inventory
  inventory="$(inventory_from_lines)"
  jq -n --argjson inventory "$inventory" \
    '{overall: "B", findings: [], upstream: [], suppressed: [], inventory: $inventory}' \
    >"$TREE/.gaia/cli/stub-report.json"
}

# stub_report_for: the stub report for plain harness paths given as arguments.
stub_report_for() {
  local path
  for path in "$@"; do printf '%s rule adopter\n' "$path"; done | stub_report
}

# merge_report: stdin lines `path status` become the merge report.
merge_report() {
  jq -R -s '
    {schemaVersion: 1, files: (split("\n") | map(select(length > 0) | split(" ")
      | {path: .[0], status: .[1]}))}' >"$REPORT"
}

# blend_report: the merge report with each argument path auto-merged.
blend_report() {
  local path
  for path in "$@"; do printf '%s auto-merged\n' "$path"; done | merge_report
}

# write_record <version> <path>...: an existing record, every entry at one version.
write_record() {
  local version=$1 path
  shift
  mkdir -p "$RECORD_DIR"
  for path in "$@"; do printf '%s\n' "$path"; done | jq -R -s -c --arg v "$version" '
    {version: 1, entries: (split("\n") | map(select(length > 0) | {path: ., version: $v}))}' \
    >"$RECORD"
}

iso_of() {
  date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ
}

write_close_row() {
  mkdir -p "${LEDGER%/*}"
  printf '{"kind":"binding","type":"close","workflow":"gaia-fitness","ts":"%s"}\n' "$(iso_of "$1")" >"$LEDGER"
}

write_landed_cache() {
  mkdir -p "${CACHE%/*}"
  printf '%s\n' "$1" >"$CACHE"
}

run_writer() {
  run bash "$WRITER" record --main-root "$MAIN" --tree "$TREE" --report "$REPORT" \
    --decisions "$DECISIONS" --tag "$TAG"
}

record_paths() { jq -r '[.entries[].path] | join(",")' "$RECORD"; }
record_versions() { jq -r '[.entries[].version] | unique | join(",")' "$RECORD"; }

# The two-file base case: both a.md and b.md blended at the default tag.
blend_two() {
  stub_report_for .claude/rules/a.md .claude/rules/b.md .claude/rules/c.md
  blend_report .claude/rules/a.md .claude/rules/b.md
}

@test "the exact set comes from auto-merged files and Combine answers, filtered to harness" {
  {
    printf '%s\n' \
      '.claude/rules/auto-one.md auto-merged' \
      '.claude/rules/auto-two.md auto-merged' \
      '.claude/rules/combine-now.md open' \
      '.claude/rules/combine-old.md open' \
      '.claude/rules/answered-keep.md open' \
      '.claude/rules/answered-gaia.md open' \
      '.claude/rules/deferred.md open' \
      'package.json field-aware' \
      '.claude/rules/overwritten.md overwrite' \
      '.claude/rules/added.md add' \
      '.claude/rules/removed.md removed' \
      '.claude/rules/skipped.md skip' \
      '.claude/rules/merged.md merge' \
      'wiki/Some Page.md auto-merged' \
      '.gaia/tests/fixtures/.claude/rules/x.md auto-merged' \
      '.claude/skills/vendored/SKILL.md auto-merged'
  } | merge_report
  printf '%s\n' \
    '.claude/rules/auto-one.md rule adopter' \
    '.claude/rules/auto-two.md rule adopter' \
    '.claude/rules/combine-now.md rule adopter' \
    '.claude/rules/combine-old.md rule adopter' \
    '.claude/rules/answered-keep.md rule adopter' \
    '.claude/rules/answered-gaia.md rule adopter' \
    '.claude/rules/deferred.md rule adopter' \
    'package.json config adopter' \
    '.claude/rules/overwritten.md rule adopter' \
    '.claude/rules/added.md rule adopter' \
    '.claude/rules/removed.md rule adopter' \
    '.claude/rules/skipped.md rule adopter' \
    '.claude/rules/merged.md rule adopter' \
    'wiki/Some Page.md wiki adopter' \
    '.gaia/tests/fixtures/.claude/rules/x.md rule adopter' \
    '.claude/skills/vendored/SKILL.md skill third-party' | stub_report
  jq -n '{schemaVersion: 1, decisions: [
    {path: ".claude/rules/combine-now.md", decision: "blend", tag: "v2.0.5", baselineTag: "v2.0.4"},
    {path: ".claude/rules/combine-old.md", decision: "blend", tag: "v2.0.4", baselineTag: "v2.0.3"},
    {path: ".claude/rules/answered-keep.md", decision: "keep", tag: "v2.0.5", baselineTag: "v2.0.4"},
    {path: ".claude/rules/answered-gaia.md", decision: "gaia", tag: "v2.0.5", baselineTag: "v2.0.4"},
    {path: ".claude/rules/deferred.md", decision: "deferred", tag: "v2.0.5", baselineTag: "v2.0.4"},
    {path: "package.json", key: "scripts.build", decision: "blend", tag: "v2.0.5", baselineTag: "v2.0.4"}
  ]}' >"$DECISIONS"
  run_writer
  [ "$status" -eq 0 ]
  [ "$output" = "RECORDED 3" ]
  [ "$(record_paths)" = ".claude/rules/auto-one.md,.claude/rules/auto-two.md,.claude/rules/combine-now.md" ]
  [ "$(record_versions)" = "2.0.5" ]
  [ "$(jq -r '.version' "$RECORD")" = "1" ]
}

@test "the harness check runs against the update tree and its arguments are the documented ones" {
  blend_two
  run_writer
  [ "$status" -eq 0 ]
  [ "$(cat "$TREE/.gaia/cli/stub-args")" = "fitness check --json --root $TREE" ]
}

@test "entries from an earlier update stay and a re-blended path moves to the new version" {
  write_record 2.0.4 .claude/rules/a.md .claude/rules/z.md
  stub_report_for .claude/rules/a.md .claude/rules/z.md .claude/rules/n.md
  blend_report .claude/rules/a.md .claude/rules/n.md
  run_writer
  [ "$status" -eq 0 ]
  [ "$output" = "RECORDED 3" ]
  [ "$(record_paths)" = ".claude/rules/a.md,.claude/rules/n.md,.claude/rules/z.md" ]
  [ "$(jq -r '.entries[] | select(.path == ".claude/rules/a.md") | .version' "$RECORD")" = "2.0.5" ]
  [ "$(jq -r '.entries[] | select(.path == ".claude/rules/z.md") | .version' "$RECORD")" = "2.0.4" ]
}

@test "entries a fitness run answered after their landing drop; entries answered before it stay" {
  write_record 2.0.4 .claude/rules/old-one.md .claude/rules/old-two.md
  write_landed_cache '{"fitnessBlendLandedAt":{"2.0.4":1000}}'
  stub_report_for .claude/rules/new.md
  blend_report .claude/rules/new.md
  write_close_row 2000
  run_writer
  [ "$status" -eq 0 ]
  [ "$output" = "RECORDED 1" ]
  [ "$(record_paths)" = ".claude/rules/new.md" ]
  write_record 2.0.4 .claude/rules/old-one.md .claude/rules/old-two.md
  write_close_row 900
  run_writer
  [ "$status" -eq 0 ]
  [ "$output" = "RECORDED 3" ]
  [ "$(record_paths)" = ".claude/rules/new.md,.claude/rules/old-one.md,.claude/rules/old-two.md" ]
}

@test "entries of an update that never reached the main checkout drop" {
  printf '2.0.3\n' >"$MAIN/.gaia/VERSION"
  write_record 2.0.4 .claude/rules/old-one.md .claude/rules/old-two.md
  stub_report_for .claude/rules/new.md
  blend_report .claude/rules/new.md
  run_writer
  [ "$status" -eq 0 ]
  [ "$output" = "RECORDED 1" ]
  [ "$(record_paths)" = ".claude/rules/new.md" ]
}

@test "an unreadable ledger keeps the landed entries" {
  [ "$(id -u)" -ne 0 ] || skip "root reads a mode 000 file"
  write_record 2.0.4 .claude/rules/old-one.md .claude/rules/old-two.md
  write_landed_cache '{"fitnessBlendLandedAt":{"2.0.4":1000}}'
  write_close_row 2000
  chmod 000 "$LEDGER"
  stub_report_for .claude/rules/new.md
  blend_report .claude/rules/new.md
  run_writer
  chmod 644 "$LEDGER"
  [ "$status" -eq 0 ]
  [ "$output" = "RECORDED 3" ]
}

@test "an absent cache and an absent landing stamp keep the landed entries" {
  write_record 2.0.4 .claude/rules/old-one.md .claude/rules/old-two.md
  write_close_row 2000
  stub_report_for .claude/rules/new.md
  blend_report .claude/rules/new.md
  run_writer
  [ "$status" -eq 0 ]
  [ "$output" = "RECORDED 3" ]
  write_record 2.0.4 .claude/rules/old-one.md .claude/rules/old-two.md
  write_landed_cache '{"fitnessBlendLandedAt":{"2.0.3":1000}}'
  run_writer
  [ "$status" -eq 0 ]
  [ "$output" = "RECORDED 3" ]
}

# refusal_leaves_record <reason>: exit 3, the reason line, record bytes as before.
refusal_leaves_record() {
  local before
  before="$(cksum <"$RECORD")"
  run_writer
  [ "$status" -eq 3 ]
  [ "$output" = "RECORD_FAILED $1" ]
  [ "$(cksum <"$RECORD")" = "$before" ]
}

@test "an unparsable merge report is refused and the record stays" {
  write_record 2.0.4 .claude/rules/a.md
  printf 'not json{' >"$REPORT"
  refusal_leaves_record report-unreadable
}

@test "a merge report without a files array is refused and the record stays" {
  write_record 2.0.4 .claude/rules/a.md
  printf '{"schemaVersion":1}\n' >"$REPORT"
  refusal_leaves_record report-unreadable
}

@test "an unparsable decisions file is refused and the record stays" {
  write_record 2.0.4 .claude/rules/a.md
  blend_two
  printf 'not json{' >"$DECISIONS"
  refusal_leaves_record decisions-unreadable
}

@test "a stub CLI that exits 2 is refused and the record stays" {
  write_record 2.0.4 .claude/rules/a.md
  blend_two
  write_stub 2
  stub_report_for .claude/rules/a.md
  refusal_leaves_record fitness-check
}

@test "a fitness report whose inventory is all unknown is refused and the record stays" {
  write_record 2.0.4 .claude/rules/a.md
  blend_two
  printf '%s\n' '.claude/rules/a.md rule unknown' '.claude/rules/b.md rule unknown' | stub_report
  refusal_leaves_record fitness-check
}

@test "a missing jq is refused and the record stays" {
  local bin="$BATS_TEST_TMPDIR/nojq-bin" tool
  mkdir -p "$bin"
  for tool in bash cat cmp date dirname grep mkdir mktemp mv rm sed sort tr comm; do
    ln -s "$(command -v "$tool")" "$bin/$tool"
  done
  write_record 2.0.4 .claude/rules/a.md
  blend_two
  local before
  before="$(cksum <"$RECORD")"
  run env PATH="$bin" "$(command -v bash)" "$WRITER" record --main-root "$MAIN" --tree "$TREE" \
    --report "$REPORT" --decisions "$DECISIONS" --tag "$TAG"
  [ "$status" -eq 3 ]
  [ "$output" = "RECORD_FAILED jq-missing" ]
  [ "$(cksum <"$RECORD")" = "$before" ]
}

@test "an unwritable record directory is refused as a write failure and leaves no temp file" {
  [ "$(id -u)" -ne 0 ] || skip "root writes anywhere"
  write_record 2.0.4 .claude/rules/old.md
  blend_two
  chmod 555 "$RECORD_DIR"
  run_writer
  chmod 755 "$RECORD_DIR"
  [ "$status" -eq 3 ]
  [ "$output" = "RECORD_FAILED write" ]
  [ "$(ls -A "$RECORD_DIR")" = "blend-record.json" ]
  [ "$(record_paths)" = ".claude/rules/old.md" ]
}

# usage_error <args>...: exit 2, usage on stderr, nothing written in the main root.
usage_error() {
  run --separate-stderr bash "$WRITER" "$@"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  printf '%s\n' "$stderr" | grep -qF 'usage' || return 1
  [ ! -e "$MAIN/.gaia/local" ]
}

@test "each missing required flag is a usage error" {
  blend_two
  local flag
  for flag in --main-root --tree --report --decisions --tag; do
    local -a args=(record)
    local pair name value
    for pair in "--main-root=$MAIN" "--tree=$TREE" "--report=$REPORT" "--decisions=$DECISIONS" "--tag=$TAG"; do
      name="${pair%%=*}"
      value="${pair#*=}"
      [ "$name" = "$flag" ] || args+=("$name" "$value")
    done
    usage_error "${args[@]}" || { echo "flag not required: $flag" >&2; return 1; }
  done
}

@test "a relative path for any path flag is a usage error" {
  blend_two
  local flag
  for flag in --main-root --tree --report --decisions; do
    local -a args=(record --main-root "$MAIN" --tree "$TREE" --report "$REPORT" --decisions "$DECISIONS" --tag "$TAG")
    local index
    for index in "${!args[@]}"; do
      if [ "${args[$index]}" = "$flag" ]; then args[index + 1]="relative/path"; fi
    done
    usage_error "${args[@]}" || { echo "relative accepted: $flag" >&2; return 1; }
  done
}

@test "a tag without the leading v or with garbage is a usage error" {
  blend_two
  local bad
  for bad in 2.0.5 vgarbage v2.0 v2.0.5.1; do
    usage_error record --main-root "$MAIN" --tree "$TREE" --report "$REPORT" \
      --decisions "$DECISIONS" --tag "$bad" || { echo "tag accepted: $bad" >&2; return 1; }
  done
}

@test "a prerelease tag is accepted and its version is recorded without the v" {
  stub_report_for .claude/rules/a.md
  blend_report .claude/rules/a.md
  TAG="v2.1.0-rc.1"
  run_writer
  [ "$status" -eq 0 ]
  [ "$(record_versions)" = "2.1.0-rc.1" ]
}

@test "an unknown subcommand is a usage error" {
  usage_error refresh --main-root "$MAIN"
  usage_error
}

@test "nothing blended and no record is UNCHANGED 0 and creates no directory" {
  stub_report_for .claude/rules/a.md
  printf '%s\n' '.claude/rules/a.md overwrite' | merge_report
  run_writer
  [ "$status" -eq 0 ]
  [ "$output" = "UNCHANGED 0" ]
  [ ! -e "$MAIN/.gaia/local" ]
}

@test "the same inputs twice report UNCHANGED and do not touch the file" {
  blend_two
  run_writer
  [ "$output" = "RECORDED 2" ]
  touch -t 202001010000 "$RECORD"
  touch -t 202001020000 "$BATS_TEST_TMPDIR/reference"
  run_writer
  [ "$status" -eq 0 ]
  [ "$output" = "UNCHANGED 2" ]
  [ -z "$(find "$RECORD" -newer "$BATS_TEST_TMPDIR/reference")" ]
}

@test "a malformed existing record is replaced by one holding only this run's entries" {
  mkdir -p "$RECORD_DIR"
  printf '{"version":1,"entries":[{"path":".claude/rules/old.md"}]}\n' >"$RECORD"
  blend_two
  run_writer
  [ "$status" -eq 0 ]
  [ "$output" = "RECORDED 2" ]
  [ "$(record_paths)" = ".claude/rules/a.md,.claude/rules/b.md" ]
  printf 'not json{' >"$RECORD"
  run_writer
  [ "$status" -eq 0 ]
  [ "$output" = "RECORDED 2" ]
  [ "$(record_paths)" = ".claude/rules/a.md,.claude/rules/b.md" ]
}

@test "no temp file is left in the record directory after a success or a refusal" {
  blend_two
  run_writer
  [ "$status" -eq 0 ]
  [ "$(ls -A "$RECORD_DIR")" = "blend-record.json" ]
  printf 'not json{' >"$REPORT"
  run_writer
  [ "$status" -eq 3 ]
  [ "$(ls -A "$RECORD_DIR")" = "blend-record.json" ]
}

@test "a Combine answer is read only from the no-key decision at the run's tag" {
  printf '%s\n' '.claude/rules/a.md open' '.claude/rules/b.md open' | merge_report
  stub_report_for .claude/rules/a.md .claude/rules/b.md
  jq -n '{schemaVersion: 1, decisions: [
    {path: ".claude/rules/a.md", key: "k", decision: "blend", tag: "v2.0.5", baselineTag: "v2.0.4"},
    {path: ".claude/rules/b.md", decision: "blend", tag: "v2.0.5", baselineTag: "v2.0.4"}
  ]}' >"$DECISIONS"
  run_writer
  [ "$status" -eq 0 ]
  [ "$output" = "RECORDED 1" ]
  [ "$(record_paths)" = ".claude/rules/b.md" ]
}

@test "the real registry and the writer agree: the record directory is a registered shared path" {
  run bash "$REPO_ROOT/.gaia/scripts/state-registry-lint.sh"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.entries[] | select(.id == "fitness-blend-record") | .path + " " + .scope + " " + .retention.class' \
    "$REPO_ROOT/.gaia/state-registry.json")" = "fitness/ shared keep" ]
}
