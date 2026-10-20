#!/usr/bin/env bats
# Tests for the quick-versus-deep classifier through the real router: a corpus
# of real and constructed frontend changes, each marked expected deep (with the
# reason that must fire) or expected quick, replayed on a merge-base first
# dispatch in a light sandbox. The corpus is fixtures/audit-quick-corpus.json:
# each entry carries the files as they stand on main (`before`) and on the
# branch (`after`), and the exact `<route>\t<reason>` line the router must
# print. A mutation inserts or rewrites one line in a must-quick entry that
# hosts it and expects the single reason that line must fire.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

bats_require_minimum_version 1.5.0

setup_file() {
  command -v jq >/dev/null 2>&1 || skip "jq not available"
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  # shellcheck source=.gaia/scripts/tests/helpers/light-sandbox.sh
  . "$REPO_ROOT/.gaia/scripts/tests/helpers/light-sandbox.sh"
  lsb_build_templates plain
}

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  # shellcheck source=.gaia/scripts/tests/helpers/light-sandbox.sh
  . "$REPO_ROOT/.gaia/scripts/tests/helpers/light-sandbox.sh"
  command -v jq >/dev/null 2>&1 || skip "jq not available"
  CORPUS="$BATS_TEST_DIRNAME/fixtures/audit-quick-corpus.json"
  CLASSIFIER_LIB="$REPO_ROOT/.claude/hooks/lib/audit-quick-classify-lib.sh"
  ROUTER_SUITE="$BATS_TEST_DIRNAME/audit-light-route.bats"
  FRONTEND="code-audit-frontend"
  TAB="$(printf '\t')"
}

teardown() {
  chmod -R u+rwx "$BATS_TEST_TMPDIR" 2>/dev/null || true
}

# The seven router-owned reasons no file set can express; the router suite
# proves each by a named case.
ROUTER_SUITE_REASONS="anchor-unresolved refusal-newer unclassifiable-path special-file ownerless no-delta fence-collision"

# corpus_ids [expected]: the entry ids in file order, optionally only those
# marked quick or deep.
corpus_ids() {
  if [ -n "${1:-}" ]; then
    jq -r --arg expected "$1" '.entries[] | select(.expected == $expected) | .id' "$CORPUS"
  else
    jq -r '.entries[].id' "$CORPUS"
  fi
}

entry_json() {
  jq -c --arg id "$1" '.entries[] | select(.id == $id)' "$CORPUS"
}

# header_rows <unmarked|router-owned>: the reason column of the classifier
# header's signal block, filtered by whether the row carries `router-owned:`.
header_rows() {
  awk -v want="$1" '
    /^# quick-signals:start/ { inside = 1; next }
    /^# quick-signals:end/ { inside = 0 }
    inside && /^#   [a-z][a-z-]+  / {
      reason = $2
      owned = ($0 ~ /^#   [a-z][a-z-]+  router-owned:/)
      if (want == "router-owned" && owned) print reason
      if (want == "unmarked" && !owned) print reason
    }
  ' "$CLASSIFIER_LIB"
}

# expect_line_equal <actual> <expected>: the comparison every route case makes.
expect_line_equal() {
  [ "$1" = "$2" ] || { printf 'want [%s], got [%s]\n' "$2" "$1" >&2; return 1; }
}

# file_field <entry-json> <index> <before|after>: that side of the file as raw
# text, or the empty string when it is null.
file_field() {
  jq -j --argjson index "$2" --arg side "$3" '.files[$index][$side] // ""' <<<"$1"
}

file_is_null() {
  [ "$(jq -r --argjson index "$2" --arg side "$3" '.files[$index][$side] | type' <<<"$1")" = "null" ]
}

# build_entry <entry-json>: a sandbox whose main carries every `before`, with
# the branch cut at main's tip and every `after` committed on it.
build_entry() {
  local entry="$1" count index path before after
  count="$(jq '.files | length' <<<"$entry")"
  lsb_init && lsb_main_base_begin || return 1
  index=0
  while [ "$index" -lt "$count" ]; do
    if ! file_is_null "$entry" "$index" before; then
      path="$(jq -r --argjson index "$index" '.files[$index].path' <<<"$entry")"
      lsb_commit "$path" "$(file_field "$entry" "$index" before)" || return 1
    fi
    index=$((index + 1))
  done
  lsb_main_base_end || return 1
  index=0
  while [ "$index" -lt "$count" ]; do
    path="$(jq -r --argjson index "$index" '.files[$index].path' <<<"$entry")"
    if file_is_null "$entry" "$index" after; then
      lsb_remove "$path" || return 1
    else
      after="$(file_field "$entry" "$index" after)"
      before="$(file_field "$entry" "$index" before)"
      # A context file is identical on both sides and has nothing to commit.
      if file_is_null "$entry" "$index" before || [ "$after" != "$before" ]; then
        lsb_commit "$path" "$after" || return 1
      fi
    fi
    index=$((index + 1))
  done
}

# apply_mutation <mutation-json> <path> <line>: insert the mutation's text
# after <line> of the file, or rewrite the quoted value on <line>, and commit.
apply_mutation() {
  local operation text edited
  operation="$(jq -r '.op' <<<"$1")"
  text="$(jq -j '.text' <<<"$1")"
  case "$operation" in
    insert)
      edited="$(MUTATION_TEXT="$text" awk -v target="$3" '
        { print }
        NR == target { print ENVIRON["MUTATION_TEXT"] }
      ' "$LSB_ROOT/$2")" || return 1
      ;;
    replace-value)
      edited="$(MUTATION_TEXT="$text" awk -v target="$3" '
        NR == target {
          opening = index($0, "\047")
          rest = substr($0, opening + 1)
          closing = index(rest, "\047")
          print substr($0, 1, opening) ENVIRON["MUTATION_TEXT"] substr(rest, closing)
          next
        }
        { print }
      ' "$LSB_ROOT/$2")" || return 1
      ;;
    *) printf 'unknown mutation op %s\n' "$operation" >&2; return 1 ;;
  esac
  [ "$edited" != "$(cat "$LSB_ROOT/$2")" ] || { printf 'mutation changed nothing in %s\n' "$2" >&2; return 1; }
  lsb_commit "$2" "$edited"
}

# route_line: the line the sandbox's router prints for the frontend member on
# a first dispatch (no clearance exists, so the merge-base path runs).
route_line() {
  bash "$LSB_ROOT/.gaia/scripts/audit-light-route.sh" --root "$LSB_ROOT" --member "$FRONTEND" --check </dev/null 2>/dev/null
}

# entry_line <entry-json> [<mutation-json> <path> <line>]: build a fresh
# sandbox in its own directory, optionally mutate it, and print the route
# line. A build or mutation failure prints `build-failed`.
entry_line() {
  local scratch
  scratch="$(mktemp -d "$BATS_TEST_TMPDIR/entry.XXXXXX")" || return 1
  (
    BATS_TEST_TMPDIR="$scratch"
    build_entry "$1" >/dev/null 2>&1 || { printf 'build-failed\n'; exit 0; }
    if [ -n "${2:-}" ]; then
      apply_mutation "$2" "$3" "$4" >/dev/null 2>&1 || { printf 'build-failed\n'; exit 0; }
    fi
    route_line
  )
  rm -rf "$scratch"
}

# Sandbox builds dominate the runtime, so route jobs run a batch at a time.
ROUTE_PARALLELISM=6

# start_route_job <index> <entry-json> [<mutation-json> <path> <line>]: run
# entry_line in the background and leave its line in $ROUTE_RESULTS/<index>.
# After every full batch it waits, so at most ROUTE_PARALLELISM sandboxes exist
# at once. Call `wait` after the last job.
start_route_job() {
  local index="$1"
  shift
  ( entry_line "$@" >"$ROUTE_RESULTS/$index" ) 3>&- &
  ROUTE_STARTED=$((ROUTE_STARTED + 1))
  if [ $((ROUTE_STARTED % ROUTE_PARALLELISM)) -eq 0 ]; then
    wait
  fi
}

# route_result <index>: the line a finished job printed, or `no-result`.
route_result() {
  if [ -s "$ROUTE_RESULTS/$1" ]; then
    cat "$ROUTE_RESULTS/$1"
  else
    printf 'no-result\n'
  fi
}

# mutation_pairs: one `<mutation index><TAB><entry id><TAB><target index>` row
# for each (mutation, host target) pair whose contexts match.
mutation_pairs() {
  jq -r '
    . as $corpus
    | $corpus.mutations | to_entries[] as $mutation
    | $corpus.entries[] | select(.mutation_targets != null) | . as $entry
    | $entry.mutation_targets | to_entries[]
    | select(.value.context == $mutation.value.context)
    | [($mutation.key | tostring), $entry.id, (.key | tostring)] | @tsv
  ' "$CORPUS"
}

# bats test_tags=whole-tree
@test "the corpus file is well formed: required fields, unique ids, no working-document ids" {
  jq empty "$CORPUS"
  [ "$(jq -r '.schema' "$CORPUS")" = "1" ]
  [ "$(jq '.entries | length' "$CORPUS")" -gt 0 ]
  [ "$(jq '.mutations | length' "$CORPUS")" -gt 0 ]
  jq -e '
    all(.entries[];
      (.id | type == "string") and (.id | length > 0)
      and (.expected == "quick" or .expected == "deep")
      and (.expected_line | type == "string")
      and (.shape | type == "string") and (.shape | length > 0)
      and (.files | type == "array") and (.files | length > 0)
      and all(.files[];
        (.path | type == "string")
        and ((.before | type) == "string" or (.before | type) == "null")
        and ((.after | type) == "string" or (.after | type) == "null")
        and ((.before == null and .after == null) | not)))
  ' "$CORPUS" >/dev/null
  [ "$(jq -r '[.entries[].id] | length' "$CORPUS")" = "$(jq -r '[.entries[].id] | unique | length' "$CORPUS")" ]
  jq -e '
    all(.entries[]; select(.mutation_targets != null) | . as $entry
      | all(.mutation_targets[]; .path as $path | any($entry.files[]; .path == $path)))
  ' "$CORPUS" >/dev/null
  jq -e '
    all(.entries[]; (.expected == "quick") == (.expected_line == "light\tquick-eligible"))
    and all(.entries[]; (.expected == "deep") == (.expected_line | startswith("full\t")))
  ' "$CORPUS" >/dev/null
  jq -e '
    all(.mutations[];
      (.reason | startswith("quick-"))
      and (.context == "jsx-child" or .context == "opening-tag" or .context == "language-value")
      and ((.op == "insert") or (.op == "replace-value"))
      and (.text | type == "string"))
  ' "$CORPUS" >/dev/null
  if jq -r '.entries[] | (.id, .shape)' "$CORPUS" | grep -Eq 'SPEC-[0-9]|UAT-[0-9]|#[0-9]|github\.com'; then
    printf 'an entry id or shape names a working document\n' >&2
    return 1
  fi
  true
}

# bats test_tags=whole-tree
@test "the corpus holds enough quick and deep entries for the classifier header" {
  local quick_count deep_count unmarked_count
  quick_count="$(jq '[.entries[] | select(.expected == "quick")] | length' "$CORPUS")"
  deep_count="$(jq '[.entries[] | select(.expected == "deep")] | length' "$CORPUS")"
  unmarked_count="$(header_rows unmarked | wc -l | tr -d ' ')"
  [ "$quick_count" -gt 0 ]
  [ "$deep_count" -gt 0 ]
  [ "$quick_count" -ge 8 ] || { printf 'only %s quick entries\n' "$quick_count" >&2; return 1; }
  [ "$unmarked_count" -gt 0 ]
  [ "$deep_count" -ge "$unmarked_count" ] || { printf '%s deep entries for %s classifier reasons\n' "$deep_count" "$unmarked_count" >&2; return 1; }
}

# bats test_tags=whole-tree
@test "every classifier reason in the header is some deep entry's expected reason" {
  local unmarked reason missing=""
  unmarked="$(header_rows unmarked)"
  [ -n "$unmarked" ] || { printf 'no unmarked rows read from the header\n' >&2; return 1; }
  for reason in $unmarked; do
    jq -e --arg line "full${TAB}${reason}" 'any(.entries[]; .expected == "deep" and .expected_line == $line)' "$CORPUS" >/dev/null \
      || missing="$missing $reason"
  done
  [ -z "$missing" ] || { printf 'no deep entry for:%s\n' "$missing" >&2; return 1; }
}

# bats test_tags=whole-tree
@test "every router-owned header row is a deep entry's reason or one the router suite proves by name" {
  local owned reason missing="" unnamed=""
  owned="$(header_rows router-owned)"
  [ -n "$owned" ] || { printf 'no router-owned rows read from the header\n' >&2; return 1; }
  for reason in $owned; do
    case " $ROUTER_SUITE_REASONS " in
      *" $reason "*) continue ;;
    esac
    jq -e --arg line "full${TAB}${reason}" 'any(.entries[]; .expected == "deep" and .expected_line == $line)' "$CORPUS" >/dev/null \
      || missing="$missing $reason"
  done
  [ -z "$missing" ] || { printf 'router-owned and neither in the corpus nor in the router suite list:%s\n' "$missing" >&2; return 1; }
  for reason in $ROUTER_SUITE_REASONS; do
    grep -Eq "^@test .*${reason}" "$ROUTER_SUITE" || unnamed="$unnamed $reason"
  done
  [ -z "$unnamed" ] || { printf 'no router suite test name carries:%s\n' "$unnamed" >&2; return 1; }
}

# bats test_tags=whole-tree
@test "every entry routes to its expected line" {
  local id entry actual expected failures="" index
  local -a ids=()
  while IFS= read -r id; do ids[${#ids[@]}]="$id"; done < <(corpus_ids)
  [ "${#ids[@]}" -gt 0 ]
  [ "${#ids[@]}" -eq "$(jq '.entries | length' "$CORPUS")" ]
  ROUTE_RESULTS="$BATS_TEST_TMPDIR/route-results"
  ROUTE_STARTED=0
  mkdir -p "$ROUTE_RESULTS"
  index=0
  for id in "${ids[@]}"; do
    start_route_job "$index" "$(entry_json "$id")"
    index=$((index + 1))
  done
  wait
  index=0
  for id in "${ids[@]}"; do
    expected="$(jq -r --arg id "$id" '.entries[] | select(.id == $id) | .expected_line' "$CORPUS")"
    actual="$(route_result "$index")"
    expect_line_equal "$actual" "$expected" 2>/dev/null \
      || failures="$failures$id: want [$expected], got [$actual]"$'\n'
    index=$((index + 1))
  done
  [ "$index" -eq "${#ids[@]}" ]
  [ -z "$failures" ] || { printf '%s' "$failures" >&2; return 1; }
}

# bats test_tags=whole-tree
@test "a mutation line fires its one reason in every must-quick entry that hosts its context" {
  local pair mutation_index id target_index entry mutation path line failures="" index
  local -a pairs=() job_label=() job_expected=() ran_per_mutation=()
  local mutation_count derived_count mutation_position
  mutation_count="$(jq '.mutations | length' "$CORPUS")"
  derived_count="$(jq '
    . as $corpus
    | [ $corpus.mutations[] | .context as $context
        | [ $corpus.entries[] | select(.mutation_targets != null)
            | .mutation_targets[] | select(.context == $context) ] | length ]
    | add
  ' "$CORPUS")"
  [ "$derived_count" -gt 0 ]
  mutation_position=0
  while [ "$mutation_position" -lt "$mutation_count" ]; do
    ran_per_mutation[mutation_position]=0
    mutation_position=$((mutation_position + 1))
  done
  while IFS= read -r pair; do pairs[${#pairs[@]}]="$pair"; done < <(mutation_pairs)
  [ "${#pairs[@]}" -eq "$derived_count" ] || { printf '%s pairs listed, %s derived\n' "${#pairs[@]}" "$derived_count" >&2; return 1; }
  ROUTE_RESULTS="$BATS_TEST_TMPDIR/route-results"
  ROUTE_STARTED=0
  mkdir -p "$ROUTE_RESULTS"
  index=0
  for pair in "${pairs[@]}"; do
    mutation_index="${pair%%"$TAB"*}"
    pair="${pair#*"$TAB"}"
    id="${pair%%"$TAB"*}"
    target_index="${pair#*"$TAB"}"
    entry="$(entry_json "$id")"
    [ "$(jq -r '.expected' <<<"$entry")" = "quick" ] || { failures="$failures$id: hosts a mutation but is not must-quick"$'\n'; continue; }
    mutation="$(jq -c --argjson index "$mutation_index" '.mutations[$index]' "$CORPUS")"
    path="$(jq -r --argjson index "$target_index" '.mutation_targets[$index].path' <<<"$entry")"
    line="$(jq -r --argjson index "$target_index" '.mutation_targets[$index].after_line' <<<"$entry")"
    job_label[index]="$id + $(jq -r '.reason' <<<"$mutation") at $path:$line"
    job_expected[index]="full${TAB}$(jq -r '.reason' <<<"$mutation")"
    ran_per_mutation[mutation_index]=$((ran_per_mutation[mutation_index] + 1))
    start_route_job "$index" "$entry" "$mutation" "$path" "$line"
    index=$((index + 1))
  done
  wait
  [ "$index" -gt 0 ]
  [ "$index" -eq "$derived_count" ] || { printf 'ran %s pairs, derived %s\n' "$index" "$derived_count" >&2; return 1; }
  index=0
  while [ "$index" -lt "$derived_count" ]; do
    expect_line_equal "$(route_result "$index")" "${job_expected[index]}" 2>/dev/null \
      || failures="$failures${job_label[index]}: want [${job_expected[index]}], got [$(route_result "$index")]"$'\n'
    index=$((index + 1))
  done
  mutation_position=0
  while [ "$mutation_position" -lt "$mutation_count" ]; do
    [ "${ran_per_mutation[mutation_position]}" -gt 0 ] || failures="$failures mutation $mutation_position ($(jq -r --argjson index "$mutation_position" '.mutations[$index].reason' "$CORPUS")) ran against no target"$'\n'
    mutation_position=$((mutation_position + 1))
  done
  [ -z "$failures" ] || { printf '%s' "$failures" >&2; return 1; }
}

# bats test_tags=whole-tree
@test "red twin: the route comparison reports a mismatch against a deliberately wrong line" {
  local id entry actual wrong
  id="$(corpus_ids deep | head -n 1)"
  [ -n "$id" ]
  entry="$(entry_json "$id")"
  actual="$(entry_line "$entry")"
  # Green side: the comparator accepts the entry's own expected line.
  expect_line_equal "$actual" "$(jq -r '.expected_line' <<<"$entry")" 2>/dev/null
  # Red side: the same route against a wrong line must be reported.
  wrong="light${TAB}quick-eligible"
  [ "$(jq -r '.expected_line' <<<"$entry")" != "$wrong" ]
  if expect_line_equal "$actual" "$wrong" 2>/dev/null; then
    printf 'the comparison accepted a wrong expected line for %s\n' "$id" >&2
    return 1
  fi
  true
}
