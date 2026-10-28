#!/usr/bin/env bats
# Tests for the quick-versus-deep classifier: a corpus of real and constructed
# frontend changes, each marked expected deep (with the reason that must fire)
# or expected quick. The corpus is fixtures/audit-quick-corpus.json: each entry
# carries the files as they stand on main (`before`) and on the branch
# (`after`), and the `<route>\t<reason>` line the router prints for it. The
# classifier owns every reason except the router-owned rows of its header, so
# each entry is replayed through the classifier's two stages in one scratch
# repository and compared on the classifier-owned part of the line (quick, or
# deep and its reason). An entry expecting a router-owned reason is replayed
# through the real router in a light sandbox, since only the router can print
# it. A mutation inserts or rewrites one line in a must-quick entry that hosts
# it and expects the single reason that line must fire.
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
  # shellcheck source=.claude/hooks/lib/audit-light-route-lib.sh
  . "$REPO_ROOT/.claude/hooks/lib/audit-light-route-lib.sh"
  # shellcheck source=.claude/hooks/lib/audit-quick-classify-lib.sh
  . "$CLASSIFIER_LIB"
  FRONTEND="code-audit-frontend"
  TAB="$(printf '\t')"
}

teardown() {
  chmod -R u+rwx "$BATS_TEST_TMPDIR" 2>/dev/null || true
}

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
# after <line> of the scratch repository's file, or rewrite the quoted value on
# <line>. The caller commits.
apply_mutation() {
  local operation text edited
  operation="$(jq -r '.op' <<<"$1")"
  text="$(jq -j '.text' <<<"$1")"
  case "$operation" in
    insert)
      edited="$(MUTATION_TEXT="$text" awk -v target="$3" '
        { print }
        NR == target { print ENVIRON["MUTATION_TEXT"] }
      ' "$CORPUS_ROOT/$2")" || return 1
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
      ' "$CORPUS_ROOT/$2")" || return 1
      ;;
    *) printf 'unknown mutation op %s\n' "$operation" >&2; return 1 ;;
  esac
  [ "$edited" != "$(cat "$CORPUS_ROOT/$2")" ] || { printf 'mutation changed nothing in %s\n' "$2" >&2; return 1; }
  printf '%s\n' "$edited" >"$CORPUS_ROOT/$2"
}

# route_line: the line the sandbox's router prints for the frontend member on
# a first dispatch (no clearance exists, so the merge-base path runs).
route_line() {
  bash "$LSB_ROOT/.gaia/scripts/audit-light-route.sh" --root "$LSB_ROOT" --member "$FRONTEND" --check </dev/null 2>/dev/null
}

# entry_line <entry-json>: build a fresh sandbox in its own directory and print
# the route line. A build failure prints `build-failed`.
entry_line() {
  local scratch
  scratch="$(mktemp -d "$BATS_TEST_TMPDIR/entry.XXXXXX")" || return 1
  (
    BATS_TEST_TMPDIR="$scratch"
    build_entry "$1" >/dev/null 2>&1 || { printf 'build-failed\n'; exit 0; }
    route_line
  )
  rm -rf "$scratch"
}

# Sandbox builds dominate the runtime, so route jobs run a batch at a time.
ROUTE_PARALLELISM=6

# start_route_job <index> <entry-json>: run
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

# The classifier-driven cases replay each entry in a scratch repository: the
# tree is replaced with the entry's `before` files and committed, then with the
# `after` files (and a mutation, when given) and committed, so the two
# classifier stages see the same base tree and head commit the router hands
# them. Commits and the awk-heavy classifier dominate the runtime, so the jobs
# are dealt to CLASSIFIER_WORKERS workers, each with a scratch repository of its
# own.
CLASSIFIER_WORKERS=6

corpus_repo_start() {
  CORPUS_ROOT="$BATS_TEST_TMPDIR/classifier-repo-$1"
  CORPUS_PATHS="$BATS_TEST_TMPDIR/classifier-paths-$1"
  rm -rf "$CORPUS_ROOT"
  git init -q "$CORPUS_ROOT"
}

corpus_git() {
  git -C "$CORPUS_ROOT" -c user.name=corpus -c user.email=corpus@example.invalid -c commit.gpgsign=false "$@"
}

# corpus_write_side <entry-json> <before|after>: that side's files, replacing
# whatever the previous entry left in the tree.
corpus_write_side() {
  local count index path
  find "$CORPUS_ROOT" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
  count="$(jq '.files | length' <<<"$1")"
  index=0
  while [ "$index" -lt "$count" ]; do
    if ! file_is_null "$1" "$index" "$2"; then
      path="$(jq -r --argjson index "$index" '.files[$index].path' <<<"$1")"
      mkdir -p "$(dirname "$CORPUS_ROOT/$path")" || return 1
      printf '%s\n' "$(file_field "$1" "$index" "$2")" >"$CORPUS_ROOT/$path" || return 1
    fi
    index=$((index + 1))
  done
}

# corpus_commit_entry <entry-json> [<mutation-json> <path> <line>]
corpus_commit_entry() {
  corpus_write_side "$1" before || return 1
  corpus_git add -A && corpus_git commit -q --allow-empty -m before || return 1
  CORPUS_FROM="$(corpus_git rev-parse 'HEAD^{tree}')" || return 1
  corpus_write_side "$1" after || return 1
  if [ -n "${2:-}" ]; then
    apply_mutation "$2" "$3" "$4" || return 1
  fi
  corpus_git add -A && corpus_git commit -q --allow-empty -m after || return 1
  CORPUS_HEAD="$(corpus_git rev-parse HEAD)" || return 1
  corpus_git diff --name-only --no-renames "$CORPUS_FROM" "$CORPUS_HEAD" >"$CORPUS_PATHS"
}

# corpus_verdict: the classifier-owned part of the router's line for the
# committed entry, in the corpus's own spelling. Both stages run, the paths
# stage first, as the router runs them.
corpus_verdict() {
  local result
  result="$(quick_classify_paths "$CORPUS_ROOT" "$CORPUS_FROM" "$CORPUS_HEAD" "$CORPUS_PATHS" 2>/dev/null)" \
    || { printf 'classifier-failed\n'; return 0; }
  if [ "$result" = quick ]; then
    result="$(quick_classify_lines "$CORPUS_ROOT" "$CORPUS_FROM" "$CORPUS_HEAD" "$CORPUS_PATHS" 2>/dev/null)" \
      || { printf 'classifier-failed\n'; return 0; }
  fi
  case "$result" in
    quick) printf 'light\tquick-eligible\n' ;;
    deep"$TAB"*) printf 'full\t%s\n' "$(cut -f2 <<<"$result")" ;;
    *) printf 'classifier-malformed\n' ;;
  esac
}

# classifier_worker <worker> <jobs-file>: run every CLASSIFIER_WORKERS-th job of
# the file, one JSON object per line ({entry, mutation, path, line}; the last
# three are null for a plain entry), leaving each verdict in
# $CLASSIFIER_RESULTS/<job number>.
classifier_worker() {
  local job number=0 entry mutation path line
  corpus_repo_start "$1" || return 1
  while IFS= read -r job; do
    if [ $((number % CLASSIFIER_WORKERS)) -eq "$1" ]; then
      entry="$(jq -c '.entry' <<<"$job")"
      mutation="$(jq -c '.mutation // empty' <<<"$job")"
      path="$(jq -r '.path // empty' <<<"$job")"
      line="$(jq -r '.line // empty' <<<"$job")"
      if corpus_commit_entry "$entry" "$mutation" "$path" "$line"; then
        corpus_verdict >"$CLASSIFIER_RESULTS/$number"
      else
        printf 'build-failed\n' >"$CLASSIFIER_RESULTS/$number"
      fi
    fi
    number=$((number + 1))
  done <"$2"
}

# run_classifier_jobs <jobs-file>
run_classifier_jobs() {
  local worker=0
  CLASSIFIER_RESULTS="$BATS_TEST_TMPDIR/classifier-results"
  mkdir -p "$CLASSIFIER_RESULTS"
  while [ "$worker" -lt "$CLASSIFIER_WORKERS" ]; do
    ( classifier_worker "$worker" "$1" ) 3>&- &
    worker=$((worker + 1))
  done
  wait
}

# classifier_result <job number>: the verdict a finished job left, or `no-result`.
classifier_result() {
  if [ -s "$CLASSIFIER_RESULTS/$1" ]; then
    cat "$CLASSIFIER_RESULTS/$1"
  else
    printf 'no-result\n'
  fi
}

# expects_router_owned_reason <expected-line>: whether the line names a reason
# the classifier header marks router-owned.
expects_router_owned_reason() {
  local reason
  for reason in $ROUTER_OWNED_REASONS; do
    [ "$1" = "full${TAB}${reason}" ] && return 0
  done
  return 1
}

# bats test_tags=whole-tree
@test "every entry routes to its expected line" {
  local entry expected failures="" index total jobs_file driven=0 routed=0
  local -a driven_labels=() driven_expected=() router_labels=() router_expected=()
  ROUTER_OWNED_REASONS="$(header_rows router-owned)"
  [ -n "$ROUTER_OWNED_REASONS" ] || { printf 'no router-owned rows read from the header\n' >&2; return 1; }
  total="$(jq '.entries | length' "$CORPUS")"
  [ "$total" -gt 0 ]
  jobs_file="$BATS_TEST_TMPDIR/classifier-jobs"
  : >"$jobs_file"
  ROUTE_RESULTS="$BATS_TEST_TMPDIR/route-results"
  ROUTE_STARTED=0
  mkdir -p "$ROUTE_RESULTS"
  while IFS= read -r entry; do
    expected="$(jq -r '.expected_line' <<<"$entry")"
    if expects_router_owned_reason "$expected"; then
      router_labels[routed]="$(jq -r '.id' <<<"$entry")"
      router_expected[routed]="$expected"
      start_route_job "$routed" "$entry"
      routed=$((routed + 1))
    else
      driven_labels[driven]="$(jq -r '.id' <<<"$entry")"
      driven_expected[driven]="$expected"
      jq -n -c --argjson entry "$entry" '{entry: $entry}' >>"$jobs_file"
      driven=$((driven + 1))
    fi
  done < <(jq -c '.entries[]' "$CORPUS")
  run_classifier_jobs "$jobs_file"
  index=0
  while [ "$index" -lt "$driven" ]; do
    expect_line_equal "$(classifier_result "$index")" "${driven_expected[index]}" 2>/dev/null \
      || failures="$failures${driven_labels[index]}: want [${driven_expected[index]}], got [$(classifier_result "$index")]"$'\n'
    index=$((index + 1))
  done
  index=0
  while [ "$index" -lt "$routed" ]; do
    expect_line_equal "$(route_result "$index")" "${router_expected[index]}" 2>/dev/null \
      || failures="$failures${router_labels[index]}: want [${router_expected[index]}], got [$(route_result "$index")]"$'\n'
    index=$((index + 1))
  done
  [ "$((driven + routed))" -eq "$total" ] || { printf 'drove %s of %s entries\n' "$((driven + routed))" "$total" >&2; return 1; }
  [ -z "$failures" ] || { printf '%s' "$failures" >&2; return 1; }
}

# bats test_tags=whole-tree
@test "a mutation line fires its one reason in every must-quick entry that hosts its context" {
  local pair mutation_index id target_index entry mutation path line failures="" index jobs_file
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
  jobs_file="$BATS_TEST_TMPDIR/classifier-jobs"
  : >"$jobs_file"
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
    jq -n -c --argjson entry "$entry" --argjson mutation "$mutation" --arg path "$path" --arg line "$line" \
      '{entry: $entry, mutation: $mutation, path: $path, line: $line}' >>"$jobs_file"
    index=$((index + 1))
  done
  [ "$index" -gt 0 ]
  [ "$index" -eq "$derived_count" ] || { printf 'ran %s pairs, derived %s\n' "$index" "$derived_count" >&2; return 1; }
  run_classifier_jobs "$jobs_file"
  index=0
  while [ "$index" -lt "$derived_count" ]; do
    expect_line_equal "$(classifier_result "$index")" "${job_expected[index]}" 2>/dev/null \
      || failures="$failures${job_label[index]}: want [${job_expected[index]}], got [$(classifier_result "$index")]"$'\n'
    index=$((index + 1))
  done
  mutation_position=0
  while [ "$mutation_position" -lt "$mutation_count" ]; do
    [ "${ran_per_mutation[mutation_position]}" -gt 0 ] || failures="$failures mutation $mutation_position ($(jq -r --argjson index "$mutation_position" '.mutations[$index].reason' "$CORPUS")) ran against no target"$'\n'
    mutation_position=$((mutation_position + 1))
  done
  [ -z "$failures" ] || { printf '%s' "$failures" >&2; return 1; }
}
