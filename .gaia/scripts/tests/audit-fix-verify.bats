#!/usr/bin/env bats
# audit-fix-verify.sh: the deterministic gate between a fixer sub-agent and the
# Quality Gate. Every case builds a scratch git repo under BATS_TEST_TMPDIR and
# drives the script into its refusal; AUDIT_FIX_VERIFY_SCRIPT points the suite at a mutant
# copy for the mutation proofs.

SCRIPT="${AUDIT_FIX_VERIFY_SCRIPT:-$BATS_TEST_DIRNAME/../audit-fix-verify.sh}"
REAL_STATE_LIBRARY="$BATS_TEST_DIRNAME/../audit-fix-verify-state-lib.sh"

sha() { shasum -a 256 <"$1" | cut -d' ' -f1; }

make_repo() {
  local directory="$1"
  mkdir -p "$directory"
  git -C "$directory" init -q -b main
  git -C "$directory" config user.email t@example.com
  git -C "$directory" config user.name t
  git -C "$directory" config commit.gpgsign false
  printf '.gaia/local/\n' >"$directory/.gitignore"
  local file_name
  for file_name in a.txt b.txt c.txt stray.txt "with space.txt" CHANGELOG.md; do
    printf 'base %s\n' "$file_name" >"$directory/$file_name"
  done
  git -C "$directory" add -A
  git -C "$directory" commit -q -m base
}

setup() {
  REPO="$BATS_TEST_TMPDIR/repo"
  make_repo "$REPO"
  RUN_FOLDER="$REPO/.gaia/local/runs/b"
  mkdir -p "$RUN_FOLDER"
  DISPOSITIONS_FILE="$RUN_FOLDER/dispositions-1.json"
  BASELINE_FILE="$RUN_FOLDER/baseline-1.json"
  RESULT_FILE="$RUN_FOLDER/fixer-1-audit.json"
  VERIFIER_OUTPUT_FILE="$RUN_FOLDER/verifier-1-1.json"
  ATTEMPT=1
}

# write_dispositions <entries-json> [allowed-json]
write_dispositions() {
  jq -n --argjson entries "$1" --argjson allowed_paths "${2:-[]}" \
    '{schema: 1, round: 1, tree: "abc", root: "x", enforcement_paths_allowed: $allowed_paths, entries: $entries}' >"$DISPOSITIONS_FILE"
}

# Two fix entries (a.txt, b.txt) and one accepted residual.
default_entries() {
  printf '%s' '[
    {"member":"m","finding_class":"c1","path":"a.txt","line":3,"disposition":"fix"},
    {"member":"m","finding_class":"c2","path":"b.txt","line":5,"disposition":"fix"},
    {"member":"m","finding_class":"c3","path":"c.txt","line":null,"disposition":"accept-residual"}]'
}

default_result() {
  printf '%s' '{"schema":1,"round":1,"attempt":1,"results":[
    {"member":"m","finding_class":"c1","path":"a.txt","line":3,"disposition":"fixed","reason":"r","changed_paths":["a.txt"]},
    {"member":"m","finding_class":"c2","path":"b.txt","line":5,"disposition":"fixed","reason":"r","changed_paths":["b.txt"]}],
    "changed_paths":["a.txt","b.txt"],"reverted_paths":[]}'
}

take_baseline() {
  bash "$SCRIPT" baseline --root "$REPO" --round 1 --out "$BASELINE_FILE"
}

take_digests() {
  DISPOSITIONS_SHA="$(sha "$DISPOSITIONS_FILE")"
  BASELINE_SHA="$(sha "$BASELINE_FILE")"
}

# Install the real audit roster and digest libraries into the fixture, give it
# a bare origin and a feature branch with one change of its own, so the verifier
# can resolve branch-own digests there. The fixture then has digests a marker's
# file name can collide with.
with_harness() {
  mkdir -p "$REPO/.gaia/scripts" "$REPO/.claude/hooks"
  cp "$BATS_TEST_DIRNAME/../../audit-ci.yml" "$REPO/.gaia/audit-ci.yml"
  cp -R "$BATS_TEST_DIRNAME/../../../.claude/hooks/lib" "$REPO/.claude/hooks/lib"
  cp "$BATS_TEST_DIRNAME/../audit-key-lib.sh" "$REPO/.gaia/scripts/audit-key-lib.sh"
  git -C "$REPO" add -A
  git -C "$REPO" commit -q -m harness
  . "$BATS_TEST_DIRNAME/../../tests/helpers/catchup-fixture.sh"
  # The fixture removes an existing origin first, and that removal fails under
  # errexit when none exists.
  git -C "$REPO" remote add origin "$BATS_TEST_TMPDIR/placeholder-origin.git"
  catchup_add_origin "$REPO" main --feature feat/fix-verify
  catchup_branch_commit branch-note.txt 'branch own change'
}

# with_harness_without_origin: the harness on a feature branch with no origin
# remote and no cached base name, and a gh that always fails.
with_harness_without_origin() {
  mkdir -p "$REPO/.gaia/scripts" "$REPO/.claude/hooks"
  cp "$BATS_TEST_DIRNAME/../../audit-ci.yml" "$REPO/.gaia/audit-ci.yml"
  cp -R "$BATS_TEST_DIRNAME/../../../.claude/hooks/lib" "$REPO/.claude/hooks/lib"
  cp "$BATS_TEST_DIRNAME/../audit-key-lib.sh" "$REPO/.gaia/scripts/audit-key-lib.sh"
  git -C "$REPO" add -A
  git -C "$REPO" commit -q -m harness
  git -C "$REPO" switch -q -c feat/fix-verify
  . "$BATS_TEST_DIRNAME/../../tests/helpers/gh-base-stub.sh"
  gh_base_stub_install "$BATS_TEST_TMPDIR/stub-bin"
  export PATH="$BATS_TEST_TMPDIR/stub-bin:$PATH" GH_STUB_FAIL=1 GAIA_AUDIT_GH_DEADLINE_SECONDS=1
}

# member_digest [<ref>]: one branch-own digest of the fixture at <ref>, over the
# merge base derived from HEAD.
member_digest() {
  bash -c '. "$1/.claude/hooks/lib/audit-digest.sh" && audit_branch_digests_local "$1" "$2"' _ "$REPO" "${1:-HEAD}" |
    cut -f2 | sort -u | head -1
}

# working_tree_id: a write-tree id of the fixture's working content.
working_tree_id() {
  local index_file="$BATS_TEST_TMPDIR/wt-index"
  GIT_INDEX_FILE="$index_file" git -C "$REPO" read-tree HEAD
  GIT_INDEX_FILE="$index_file" git -C "$REPO" add -A
  GIT_INDEX_FILE="$index_file" git -C "$REPO" write-tree
}

# forge <name> <body-json>: an audit file written after the baseline.
forge() {
  mkdir -p "$REPO/.gaia/local/audit"
  printf '%s\n' "$2" >"$REPO/.gaia/local/audit/$1"
  touch -t 203001010000 "$REPO/.gaia/local/audit/$1"
}

foreign_tree() { printf 'f%.0s' {1..40}; }

# Standard setup: dispositions, baseline, digests.
prepare() {
  write_dispositions "$(default_entries)" "${1:-[]}"
  take_baseline
  take_digests
}

do_check() {
  run bash "$SCRIPT" check --root "$REPO" --round 1 --attempt "$ATTEMPT" \
    --dispositions "$DISPOSITIONS_FILE" --dispositions-sha "$DISPOSITIONS_SHA" \
    --baseline "$BASELINE_FILE" --baseline-sha "$BASELINE_SHA" \
    --result "$RESULT_FILE" --out "$VERIFIER_OUTPUT_FILE" "$@"
}

edit() { printf 'fixer edit\n' >>"$REPO/$1"; }

# reset_case: return the fixture to its committed state between the rows of a
# merged case table, so each row starts clean.
reset_case() {
  git -C "$REPO" reset -q --hard HEAD
  git -C "$REPO" clean -fdq
  rm -rf "$REPO/.gaia/local/audit" "$RUN_FOLDER"
  mkdir -p "$RUN_FOLDER"
  ATTEMPT=1
  VERIFIER_OUTPUT_FILE="$RUN_FOLDER/verifier-1-1.json"
}

# prepare_with_dirty_record <path>: a baseline that records <path> as dirty
# with its edited content. The real baseline subcommand refuses a dirty tree,
# so this forges the record to keep the check's revert and further-edit
# comparison proven against a baseline that carries a dirty entry.
prepare_with_dirty_record() {
  write_dispositions "$(default_entries)"
  take_baseline
  edit "$1"
  local blob
  blob="$(git -C "$REPO" hash-object -- "$1")"
  jq --arg dirty_path "$1" --arg blob "$blob" '.dirty[$dirty_path] = $blob' "$BASELINE_FILE" >"$BASELINE_FILE.new"
  mv "$BASELINE_FILE.new" "$BASELINE_FILE"
  take_digests
}

assert_fail_kind() {
  local kind="$1" needle="${2:-}"
  [ "$status" -eq 1 ] || {
    echo "status=$status output=$output"
    return 1
  }
  [ "$(jq -r '.pass' "$VERIFIER_OUTPUT_FILE")" = false ] || return 1
  jq -e --arg kind "$kind" '[.errors[].kind] | index($kind) != null' "$VERIFIER_OUTPUT_FILE" >/dev/null || {
    echo "no $kind error: $(cat "$VERIFIER_OUTPUT_FILE")"
    return 1
  }
  case "$output" in
    *"$kind"*) ;;
    *)
      echo "stderr lacks $kind: $output"
      return 1
      ;;
  esac
  if [ -n "$needle" ]; then
    case "$output" in
      *"$needle"*) ;;
      *)
        echo "stderr lacks '$needle': $output"
        return 1
        ;;
    esac
  fi
  return 0
}

@test "clean pass: clean baseline, two declared fixer edits, one result per fix entry" {
  prepare
  edit a.txt
  edit b.txt
  default_result >"$RESULT_FILE"
  do_check
  [ "$status" -eq 0 ]
  [ "$(jq -r '.pass' "$VERIFIER_OUTPUT_FILE")" = true ]
  [ "$(jq -r '.errors | length' "$VERIFIER_OUTPUT_FILE")" = 0 ]
}

@test "missing-disposition: an omitted fix entry and an out-of-set disposition each fail naming the key" {
  # row: a result omitting one fix entry (UAT-002a)
  prepare
  edit a.txt
  default_result | jq 'del(.results[1])' >"$RESULT_FILE"
  do_check
  assert_fail_kind missing-disposition "m c2 b.txt 5"
  # row: a disposition outside the allowed set counts as missing (UAT-002a)
  reset_case
  prepare
  edit a.txt
  edit b.txt
  default_result | jq '.results[0].disposition = "done"' >"$RESULT_FILE"
  do_check
  assert_fail_kind missing-disposition "m c1 a.txt 3"
}

@test "declaration rule: undeclared edits, new files and reverts fail, declared ones pass (case table incl. a spaced path)" {
  # row: an undeclared edit to a tracked file fails undeclared-path (UAT-002b)
  prepare
  edit a.txt
  edit b.txt
  edit c.txt
  default_result >"$RESULT_FILE"
  do_check
  assert_fail_kind undeclared-path c.txt
  # row: a new undeclared untracked file fails undeclared-path (UAT-002c)
  reset_case
  prepare
  edit a.txt
  edit b.txt
  printf 'new\n' >"$REPO/new.txt"
  default_result >"$RESULT_FILE"
  do_check
  assert_fail_kind undeclared-path new.txt
  # row: a declared new untracked file passes
  reset_case
  prepare
  edit a.txt
  edit b.txt
  printf 'new\n' >"$REPO/new.txt"
  default_result | jq '.changed_paths += ["new.txt"]' >"$RESULT_FILE"
  do_check
  [ "$status" -eq 0 ]
  # row: reverting a baseline-dirty path, undeclared, fails undeclared-revert (UAT-002d, UAT-023)
  reset_case
  prepare_with_dirty_record stray.txt
  edit a.txt
  edit b.txt
  printf 'base stray.txt\n' >"$REPO/stray.txt"
  default_result >"$RESULT_FILE"
  do_check
  assert_fail_kind undeclared-revert stray.txt
  # row: a revert of a baseline-dirty path declared in reverted_paths passes
  reset_case
  prepare_with_dirty_record stray.txt
  edit a.txt
  edit b.txt
  printf 'base stray.txt\n' >"$REPO/stray.txt"
  default_result | jq '.reverted_paths = ["stray.txt"]' >"$RESULT_FILE"
  do_check
  [ "$status" -eq 0 ]
  # row: a further undeclared edit to a baseline-dirty path fails undeclared-path (UAT-002e)
  reset_case
  prepare_with_dirty_record stray.txt
  edit a.txt
  edit b.txt
  edit stray.txt
  default_result >"$RESULT_FILE"
  do_check
  assert_fail_kind undeclared-path stray.txt
  # row: paths with spaces are hashed and compared correctly
  reset_case
  write_dispositions '[{"member":"m","finding_class":"c1","path":"with space.txt","line":1,"disposition":"fix"}]'
  take_baseline
  take_digests
  edit "with space.txt"
  printf '%s' '{"schema":1,"round":1,"attempt":1,"results":[{"member":"m","finding_class":"c1","path":"with space.txt","line":1,"disposition":"fixed","reason":"r","changed_paths":["with space.txt"]}],"changed_paths":["with space.txt"],"reverted_paths":[]}' >"$RESULT_FILE"
  do_check
  [ "$status" -eq 0 ]
  printf 'x\n' >"$REPO/other space.txt"
  do_check
  assert_fail_kind undeclared-path "other space.txt"
}

@test "UAT-002f: HEAD moved by a commit fails head-moved" {
  prepare
  edit a.txt
  edit b.txt
  git -C "$REPO" add -A
  git -C "$REPO" commit -q -m fixer
  default_result >"$RESULT_FILE"
  do_check
  assert_fail_kind head-moved
}

@test "UAT-002g: a staged change fails index-changed" {
  prepare
  edit a.txt
  edit b.txt
  git -C "$REPO" add a.txt
  default_result >"$RESULT_FILE"
  do_check
  assert_fail_kind index-changed
}

@test "directive 2: a declared edit to CHANGELOG.md fails forbidden-path" {
  prepare
  edit a.txt
  edit b.txt
  edit CHANGELOG.md
  default_result | jq '.changed_paths += ["CHANGELOG.md"]' >"$RESULT_FILE"
  do_check
  assert_fail_kind forbidden-path CHANGELOG.md
}

enforcement_paths() {
  sed -n '/^ENFORCEMENT_PATHS=(/,/^)/p' "$REAL_STATE_LIBRARY" | sed -n "s/^  '\([^']*\)'.*/\1/p"
}

# The SPEC-093 additions; each is expected on the list when it exists in the tree.
spec093_enforcement_paths() {
  printf '%s\n' \
    '.claude/hooks/audit-loop-ask-grant.sh' \
    '.gaia/scripts/context-checkpoint-lib.sh' \
    '.gaia/scripts/audit-dispositions-check.sh' \
    '.gaia/scripts/audit-loop-signals-lib.sh' \
    '.claude/agents/audit-loop-unit.md' \
    '.gaia/statusline/gaia-statusline.sh' \
    '.gaia/statusline/context-reading.sh' \
    '.gaia/statusline/gaia-statusline-left.sh' \
    '.gaia/statusline/gaia-statusline-right.sh' \
    '.gaia/statusline/setup-owed.sh'
}

@test "each named enforcement path is on the enforcement list, and an unallowed fixer edit to the moved libraries fails enforcement-path" {
  local file_path listed entries_json
  # row: the local settings file
  enforcement_paths | grep -Fxq '.claude/settings.local.json' || {
    echo ".claude/settings.local.json: not on the verifier's enforcement list"
    return 1
  }
  # row: each moved library is listed
  listed=0
  while IFS= read -r file_path; do
    listed=$((listed + 1))
    enforcement_paths | grep -Fxq -- "$file_path" || {
      echo "$file_path: not on the verifier's enforcement list"
      return 1
    }
  done < <(moved_library_paths)
  [ "$listed" -eq "$(moved_library_paths | wc -l | tr -d ' ')" ] || return 1
  # row: each loop and statusline addition is listed (the all-paths refusal test below
  # builds the repository and runs the check)
  listed=0
  while IFS= read -r file_path; do
    listed=$((listed + 1))
    enforcement_paths | grep -Fxq -- "$file_path" || {
      echo "$file_path: not on the verifier's enforcement list"
      return 1
    }
  done < <(spec093_enforcement_paths)
  [ "$listed" -eq 10 ] || return 1
  # row: a fixer edit to every moved library with no allowance fails
  # enforcement-path, one repository and one check for all of them
  while IFS= read -r file_path; do
    mkdir -p "$REPO/$(dirname "$file_path")"
    printf 'orig\n' >"$REPO/$file_path"
  done < <(moved_library_paths)
  git -C "$REPO" add -A
  git -C "$REPO" commit -q -m moved-libraries
  entries_json="$(moved_library_paths | jq -R . | jq -s 'map({member: "m", finding_class: "c1", path: ., line: 1, disposition: "fix"})')"
  write_dispositions "$entries_json"
  take_baseline
  take_digests
  while IFS= read -r file_path; do
    edit "$file_path"
  done < <(moved_library_paths)
  jq -n --argjson entries "$entries_json" '{schema: 1, round: 1, attempt: 1,
    results: ($entries | map({member, finding_class, path, line, disposition: "fixed", reason: "r", changed_paths: [.path]})),
    changed_paths: ($entries | map(.path)), reverted_paths: []}' >"$RESULT_FILE"
  do_check
  [ "$status" -eq 1 ] || {
    echo "the batch did not fail: $output"
    return 1
  }
  while IFS= read -r file_path; do
    jq -e --arg file_path "$file_path" \
      '[.errors[] | select(.kind == "enforcement-path" and .detail == $file_path)] | length == 1' \
      "$VERIFIER_OUTPUT_FILE" >/dev/null || {
      echo "$file_path: no enforcement-path error naming it"
      return 1
    }
  done < <(moved_library_paths)
}

# bats test_tags=protected
@test "directive 2: a declared edit to every enforcement-set path fails enforcement-path" {
  local path_count=0 file_path entries_json result_json
  # One repository holds every enforcement path (force-added: the local
  # settings file is gitignored), every path is edited, and one check runs.
  REPO="$BATS_TEST_TMPDIR/enforcement-all"
  make_repo "$REPO"
  while IFS= read -r file_path; do
    path_count=$((path_count + 1))
    mkdir -p "$REPO/$(dirname "$file_path")"
    printf 'orig\n' >"$REPO/$file_path"
  done < <(enforcement_paths)
  [ "$path_count" -eq "$(enforcement_paths | wc -l | tr -d ' ')" ]
  git -C "$REPO" add -f -A
  git -C "$REPO" commit -q -m enforcement
  RUN_FOLDER="$REPO/.gaia/local/runs/b"
  mkdir -p "$RUN_FOLDER"
  DISPOSITIONS_FILE="$RUN_FOLDER/dispositions-1.json"
  BASELINE_FILE="$RUN_FOLDER/baseline-1.json"
  RESULT_FILE="$RUN_FOLDER/fixer-1-audit.json"
  VERIFIER_OUTPUT_FILE="$RUN_FOLDER/verifier-1-1.json"
  entries_json="$(enforcement_paths | jq -R . | jq -s 'map({member: "m", finding_class: "c1", path: ., line: 1, disposition: "fix"})')"
  result_json="$(jq -n --argjson entries "$entries_json" '{schema: 1, round: 1, attempt: 1,
    results: ($entries | map({member, finding_class, path, line, disposition: "fixed", reason: "r", changed_paths: [.path]})),
    changed_paths: ($entries | map(.path)), reverted_paths: []}')"
  write_dispositions "$entries_json"
  take_baseline
  take_digests
  while IFS= read -r file_path; do
    edit "$file_path"
  done < <(enforcement_paths)
  printf '%s' "$result_json" >"$RESULT_FILE"
  do_check
  [ "$status" -eq 1 ] || {
    echo "the batch did not fail: $output"
    return 1
  }
  while IFS= read -r file_path; do
    jq -e --arg file_path "$file_path" \
      '[.errors[] | select(.kind == "enforcement-path" and .detail == $file_path)] | length == 1' \
      "$VERIFIER_OUTPUT_FILE" >/dev/null || {
      echo "$file_path: no enforcement-path error naming it"
      return 1
    }
  done < <(enforcement_paths)
}

# The libraries the disposition check, the audit loop and the filer source
# stay under the fixer bound, or the actor the loop bounds could edit them.
moved_library_paths() {
  printf '%s\n' \
    '.gaia/scripts/branch-authorship-lib.sh' \
    '.gaia/scripts/audit-pr-sections-lib.sh' \
    '.gaia/scripts/audit-dispositions-grade-lib.sh' \
    '.gaia/scripts/audit-dispositions-snapshot-lib.sh' \
    '.gaia/scripts/audit-recorded-decision-lib.sh' \
    '.gaia/scripts/filing-outcomes-lib.sh' \
    '.gaia/scripts/audit-veto-lib.sh' \
    '.gaia/scripts/audit-loop-stop-lib.sh' \
    '.gaia/scripts/audit-loop-allowance-lib.sh' \
    '.gaia/scripts/audit-loop-round-lib.sh' \
    '.gaia/scripts/audit-loop-report-lib.sh' \
    '.gaia/scripts/audit-triage-lib.sh' \
    '.gaia/scripts/audit-gate-owed.sh'
}

@test "a gate-repair result with no fix entries passes check, and an undeclared changed path still fails" {
  write_dispositions '[]'
  take_baseline
  take_digests
  edit a.txt
  printf '%s' '{"schema":1,"round":1,"attempt":1,"results":[{"member":"gate-repair","finding_class":"gate/pw","path":"apps/web","line":0,"disposition":"fixed","reason":"r","changed_paths":["a.txt"]}],"changed_paths":["a.txt"],"reverted_paths":[]}' >"$RESULT_FILE"
  do_check
  [ "$status" -eq 0 ] || {
    echo "status=$status output=$output"
    return 1
  }
  edit b.txt
  do_check
  [ "$status" -ne 0 ]
}

@test "non-fix dispositions (waive-out-of-scope with cross-remit, divert) need no fixer result" {
  # row: a waive-out-of-scope entry carrying basis cross-remit passes the shape check
  write_dispositions '[
    {"member":"m","finding_class":"c1","path":"a.txt","line":3,"disposition":"fix"},
    {"member":"m","finding_class":"c2","path":"b.txt","line":5,"disposition":"waive-out-of-scope","basis":"cross-remit","reason":"r"}]'
  take_baseline
  take_digests
  edit a.txt
  printf '%s' '{"schema":1,"round":1,"attempt":1,"results":[{"member":"m","finding_class":"c1","path":"a.txt","line":3,"disposition":"fixed","reason":"r","changed_paths":["a.txt"]}],"changed_paths":["a.txt"],"reverted_paths":[]}' >"$RESULT_FILE"
  do_check
  [ "$status" -eq 0 ] || {
    echo "cross-remit: status $status: $output"
    return 1
  }
  # row: a divert entry passes the shape check and needs no fixer result
  reset_case
  write_dispositions '[
    {"member":"m","finding_class":"c1","path":"a.txt","line":3,"disposition":"fix"},
    {"member":"m","finding_class":"c2","path":"b.txt","line":5,"disposition":"divert","reason":"security class from outside the branch"}]'
  take_baseline
  take_digests
  edit a.txt
  printf '%s' '{"schema":1,"round":1,"attempt":1,"results":[{"member":"m","finding_class":"c1","path":"a.txt","line":3,"disposition":"fixed","reason":"r","changed_paths":["a.txt"]}],"changed_paths":["a.txt"],"reverted_paths":[]}' >"$RESULT_FILE"
  do_check
  [ "$status" -eq 0 ] || {
    echo "divert: status $status: $output"
    return 1
  }
}

@test "enforcement allowance: an allowed path a fix entry names passes, an allowance no fix entry names fails bad-input" {
  # row: directive 3, an enforcement edit passes when allowed and a fix entry names it
  local file_path='.gaia/scripts/audit-loop-eval.sh'
  mkdir -p "$REPO/.gaia/scripts"
  printf 'orig\n' >"$REPO/$file_path"
  git -C "$REPO" add -A
  git -C "$REPO" commit -q -m enforcement
  write_dispositions '[{"member":"m","finding_class":"c1","path":"'"$file_path"'","line":1,"disposition":"fix"}]' '["'"$file_path"'"]'
  take_baseline
  take_digests
  edit "$file_path"
  printf '%s' '{"schema":1,"round":1,"attempt":1,"results":[{"member":"m","finding_class":"c1","path":"'"$file_path"'","line":1,"disposition":"fixed","reason":"r","changed_paths":["'"$file_path"'"]}],"changed_paths":["'"$file_path"'"],"reverted_paths":[]}' >"$RESULT_FILE"
  do_check
  [ "$status" -eq 0 ] || {
    echo "allowed edit: status $status: $output"
    return 1
  }
  # row: directive 3, an enforcement_paths_allowed entry no fix entry names fails bad-input
  reset_case
  write_dispositions "$(default_entries)" '[".gaia/scripts/audit-loop-eval.sh"]'
  take_baseline
  take_digests
  edit a.txt
  edit b.txt
  default_result >"$RESULT_FILE"
  do_check
  assert_fail_kind bad-input "no fix entry names"
}

# bats test_tags=protected
@test "marker/refusal ownership: case table over body tree, sha, file-name digest and digest resolvability" {
  local body digest worktree_tree mine sibling
  # Plain-repository rows first: the harness fixture below commits to the same repository.
  # row: directive 2, a *.ok marker written under .gaia/local/audit after the baseline fails
  prepare
  edit a.txt
  edit b.txt
  mkdir -p "$REPO/.gaia/local/audit"
  printf 'ok\n' >"$REPO/.gaia/local/audit/x.ok"
  touch -t 203001010000 "$REPO/.gaia/local/audit/x.ok"
  default_result >"$RESULT_FILE"
  do_check
  assert_fail_kind audit-artifact-written x.ok
  # row: when member digests cannot be resolved a foreign-tree marker counts
  reset_case
  prepare
  edit a.txt
  edit b.txt
  forge foreign.ok "$(printf '{"tree":"%s","sha":"abc"}' "$(foreign_tree)")"
  default_result >"$RESULT_FILE"
  do_check
  assert_fail_kind audit-artifact-written foreign.ok
  # row: a marker carrying this root's HEAD tree fails
  reset_case
  prepare
  edit a.txt
  edit b.txt
  mkdir -p "$REPO/.gaia/local/audit"
  printf '{"tree":"%s","sha":"x"}\n' "$(git -C "$REPO" rev-parse 'HEAD^{tree}')" >"$REPO/.gaia/local/audit/own.ok"
  touch -t 203001010000 "$REPO/.gaia/local/audit/own.ok"
  default_result >"$RESULT_FILE"
  do_check
  assert_fail_kind audit-artifact-written own.ok
  # Harness rows share one fixture with a bare origin and a feature branch.
  reset_case
  with_harness
  # row: a foreign root's marker and refusal written after the baseline still pass
  prepare
  edit a.txt
  edit b.txt
  body="$(printf '{"tree":"%s","sha":"%s"}' "$(foreign_tree)" "$(printf 'e%.0s' {1..40})")"
  forge foreign.ok "$body"
  forge foreign.refused "$body"
  default_result >"$RESULT_FILE"
  do_check
  [ "$status" -eq 0 ] || {
    echo "foreign root: status $status: $output"
    return 1
  }
  # row: a marker whose body has neither a tree nor a sha fails
  reset_case
  prepare
  edit a.txt
  edit b.txt
  forge "$(printf 'a%.0s' {1..64}).ok" '{"digest":"x","member":"code-audit-frontend","provenance":"earned"}'
  default_result >"$RESULT_FILE"
  do_check
  assert_fail_kind audit-artifact-written
  # row: a marker whose tree is not a well-formed object id fails
  reset_case
  prepare
  edit a.txt
  edit b.txt
  forge bad-tree.ok '{"tree":"not-a-tree","sha":"abc"}'
  default_result >"$RESULT_FILE"
  do_check
  assert_fail_kind audit-artifact-written bad-tree.ok
  # row: a foreign-tree marker named by one of this branch's branch-own digests fails
  reset_case
  prepare
  edit a.txt
  edit b.txt
  digest="$(member_digest HEAD)"
  [ -n "$digest" ]
  forge "$digest.ok" "$(printf '{"digest":"%s","tree":"%s","sha":"abc"}' "$digest" "$(foreign_tree)")"
  forge "$digest.code-audit-frontend.refused" "$(printf '{"digest":"%s","tree":"%s","sha":"abc"}' "$digest" "$(foreign_tree)")"
  default_result >"$RESULT_FILE"
  do_check
  assert_fail_kind audit-artifact-written "$digest"
  # row: a foreign-tree marker named by a branch-own digest of the working content fails
  reset_case
  prepare
  edit a.txt
  edit b.txt
  # A change to the shared machinery rotates every member digest.
  printf '# fixer edit\n' >>"$REPO/.claude/hooks/lib/audit-digest.sh"
  worktree_tree="$(working_tree_id)"
  digest="$(member_digest "$worktree_tree")"
  [ -n "$digest" ]
  [ "$digest" != "$(member_digest HEAD)" ]
  forge "$digest.ok" "$(printf '{"digest":"%s","tree":"%s","sha":"abc"}' "$digest" "$(foreign_tree)")"
  default_result >"$RESULT_FILE"
  jq '.changed_paths += [".claude/hooks/lib/audit-digest.sh"]' "$RESULT_FILE" >"$RESULT_FILE.n"
  mv "$RESULT_FILE.n" "$RESULT_FILE"
  do_check
  assert_fail_kind audit-artifact-written "$digest"
  # row: a sibling branch's marker, named by its own branch-own digest, still passes
  reset_case
  prepare
  edit a.txt
  edit b.txt
  mine="$(member_digest HEAD)"
  git -C "$REPO" branch -m feat/fix-verify feat/sibling
  sibling="$(member_digest HEAD)"
  git -C "$REPO" branch -m feat/sibling feat/fix-verify
  [ -n "$sibling" ]
  [ "$sibling" != "$mine" ]
  forge "$sibling.ok" "$(printf '{"digest":"%s","tree":"%s","sha":"%s"}' "$sibling" "$(foreign_tree)" "$(printf 'e%.0s' {1..40})")"
  default_result >"$RESULT_FILE"
  do_check
  [ "$status" -eq 0 ] || {
    echo "sibling: status $status: $output"
    return 1
  }
  # row: without an origin ref no digest resolves and every new marker is reported
  # (a fresh repository, last: the stub gh it puts on PATH would reach the rows above)
  rm -rf "$REPO"
  make_repo "$REPO"
  with_harness_without_origin
  reset_case
  prepare
  edit a.txt
  edit b.txt
  forge foreign.ok "$(printf '{"tree":"%s","sha":"%s"}' "$(foreign_tree)" "$(printf 'e%.0s' {1..40})")"
  forge foreign.refused "$(printf '{"tree":"%s","sha":"%s"}' "$(foreign_tree)" "$(printf 'e%.0s' {1..40})")"
  default_result >"$RESULT_FILE"
  do_check
  assert_fail_kind audit-artifact-written foreign.ok
  jq -e '[.errors[] | select(.kind == "audit-artifact-written")] | length == 2' "$VERIFIER_OUTPUT_FILE" >/dev/null
}

@test "sidecar audit artifacts: own-slug sidecar after baseline fails, foreign-slug passes, pre-baseline file passes" {
  local slug
  # row: directive 2, a *.findings.json sidecar written after the baseline fails
  prepare
  edit a.txt
  edit b.txt
  mkdir -p "$REPO/.gaia/local/audit"
  slug="$(git -C "$REPO" branch --show-current)"
  printf '{}\n' >"$REPO/.gaia/local/audit/t.$slug.m.findings.json"
  touch -t 203001010000 "$REPO/.gaia/local/audit/t.$slug.m.findings.json"
  default_result >"$RESULT_FILE"
  do_check
  assert_fail_kind audit-artifact-written findings.json
  # row: a foreign branch's sidecar written after the baseline still passes
  reset_case
  prepare
  edit a.txt
  edit b.txt
  mkdir -p "$REPO/.gaia/local/audit"
  printf '{}\n' >"$REPO/.gaia/local/audit/t.other-branch.m.findings.json"
  touch -t 203001010000 "$REPO/.gaia/local/audit/t.other-branch.m.findings.json"
  default_result >"$RESULT_FILE"
  do_check
  [ "$status" -eq 0 ] || {
    echo "foreign sidecar: status $status: $output"
    return 1
  }
  # row: an audit file older than the baseline does not fail
  reset_case
  mkdir -p "$REPO/.gaia/local/audit"
  printf 'ok\n' >"$REPO/.gaia/local/audit/old.ok"
  touch -t 200001010000 "$REPO/.gaia/local/audit/old.ok"
  prepare
  edit a.txt
  edit b.txt
  default_result >"$RESULT_FILE"
  do_check
  [ "$status" -eq 0 ]
}

@test "COV-004: an input file edited after its digest fails bad-input; with fresh digests it is judged on merits" {
  # row: a dispositions file edited after its digest fails bad-input
  prepare
  edit a.txt
  edit b.txt
  default_result >"$RESULT_FILE"
  jq '.enforcement_paths_allowed += [".claude/settings.json"]' "$DISPOSITIONS_FILE" >"$DISPOSITIONS_FILE.new"
  mv "$DISPOSITIONS_FILE.new" "$DISPOSITIONS_FILE"
  do_check
  assert_fail_kind bad-input "dispositions file digest"
  # row: a baseline file edited after its digest fails bad-input
  reset_case
  prepare
  edit a.txt
  edit b.txt
  default_result >"$RESULT_FILE"
  jq '.dirty = {"a.txt": "deleted"}' "$BASELINE_FILE" >"$BASELINE_FILE.new"
  mv "$BASELINE_FILE.new" "$BASELINE_FILE"
  do_check
  assert_fail_kind bad-input "baseline file digest"
  # row: with correct digests the edited inputs are judged on their merits
  reset_case
  prepare
  edit a.txt
  edit b.txt
  default_result >"$RESULT_FILE"
  jq '.enforcement_paths_allowed += [".claude/settings.json"]' "$DISPOSITIONS_FILE" >"$DISPOSITIONS_FILE.new"
  mv "$DISPOSITIONS_FILE.new" "$DISPOSITIONS_FILE"
  take_digests
  do_check
  assert_fail_kind bad-input "no fix entry names"
}

@test "--extra-declared: an autofix-changed path in the file passes, without the flag it fails undeclared-path" {
  prepare
  edit a.txt
  edit b.txt
  edit c.txt
  default_result >"$RESULT_FILE"
  printf 'c.txt\n' >"$RUN_FOLDER/gate-1-1.paths"
  do_check
  assert_fail_kind undeclared-path c.txt
  do_check --extra-declared "$RUN_FOLDER/gate-1-1.paths"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.pass' "$VERIFIER_OUTPUT_FILE")" = true ]
}

@test "baseline refusals: staged index exits 3, dirty tracked/untracked paths exit 4 naming each, ignored files pass" {
  # row: a staged change exits 3 and writes nothing
  edit a.txt
  git -C "$REPO" add a.txt
  write_dispositions "$(default_entries)"
  run bash "$SCRIPT" baseline --root "$REPO" --round 1 --out "$BASELINE_FILE"
  [ "$status" -eq 3 ]
  [ ! -e "$BASELINE_FILE" ]
  case "$output" in
    *"index differs from HEAD"*) ;;
    *)
      echo "$output"
      return 1
      ;;
  esac
  # row: UAT-007, a modified tracked file exits 4, prints member-wave-dirty and a dirty line, writes nothing
  reset_case
  edit a.txt
  write_dispositions "$(default_entries)"
  run bash "$SCRIPT" baseline --root "$REPO" --round 1 --out "$BASELINE_FILE"
  [ "$status" -eq 4 ]
  [ ! -e "$BASELINE_FILE" ]
  [ ! -e "$RUN_FOLDER/verifier-bin-1" ]
  printf '%s\n' "$output" | grep -qx 'member-wave-dirty' || return 1
  printf '%s\n' "$output" | grep -qx 'dirty a.txt' || return 1
  # row: UAT-007, an untracked non-ignored file exits 4 and names it
  reset_case
  printf 'new\n' >"$REPO/fresh.txt"
  run bash "$SCRIPT" baseline --root "$REPO" --round 1 --out "$BASELINE_FILE"
  [ "$status" -eq 4 ]
  [ ! -e "$BASELINE_FILE" ]
  printf '%s\n' "$output" | grep -qx 'member-wave-dirty' || return 1
  printf '%s\n' "$output" | grep -qx 'dirty fresh.txt' || return 1
  # row: UAT-007, every dirty path is named, modified and untracked together
  reset_case
  edit a.txt
  edit "with space.txt"
  printf 'new\n' >"$REPO/fresh.txt"
  run bash "$SCRIPT" baseline --root "$REPO" --round 1 --out "$BASELINE_FILE"
  [ "$status" -eq 4 ]
  printf '%s\n' "$output" | grep -qx 'dirty a.txt' || return 1
  printf '%s\n' "$output" | grep -qx 'dirty with space.txt' || return 1
  printf '%s\n' "$output" | grep -qx 'dirty fresh.txt' || return 1
  # row: new files that are all git-ignored let the baseline pass
  reset_case
  mkdir -p "$REPO/.gaia/local/audit"
  printf 'x\n' >"$REPO/.gaia/local/audit/sidecar.json"
  printf 'ignored.log\n' >>"$REPO/.git/info/exclude"
  printf 'x\n' >"$REPO/ignored.log"
  run bash "$SCRIPT" baseline --root "$REPO" --round 1 --out "$BASELINE_FILE"
  [ "$status" -eq 0 ]
  [ -e "$BASELINE_FILE" ]
}

@test "bad-input: wrong result round, wrong dispositions round, attempt mismatch, unparseable JSON, .. / absolute / dash-leading paths" {
  # row: the wrong round fails
  prepare
  edit a.txt
  edit b.txt
  default_result | jq '.round = 2' >"$RESULT_FILE"
  do_check
  assert_fail_kind bad-input "wrong round"
  # row: a dispositions file with the wrong round fails
  reset_case
  write_dispositions "$(default_entries)"
  jq '.round = 2' "$DISPOSITIONS_FILE" >"$DISPOSITIONS_FILE.new"
  mv "$DISPOSITIONS_FILE.new" "$DISPOSITIONS_FILE"
  take_baseline
  take_digests
  default_result >"$RESULT_FILE"
  do_check
  assert_fail_kind bad-input "wrong round"
  # row: a result attempt 1 against --attempt 2 (the continuation case) fails
  reset_case
  prepare
  edit a.txt
  edit b.txt
  default_result >"$RESULT_FILE"
  ATTEMPT=2
  VERIFIER_OUTPUT_FILE="$RUN_FOLDER/verifier-1-2.json"
  do_check
  assert_fail_kind bad-input "attempt"
  [ "$(jq -r '.attempt' "$VERIFIER_OUTPUT_FILE")" = 2 ] || return 1
  # row: unparseable JSON fails
  reset_case
  prepare
  edit a.txt
  printf '{not json' >"$RESULT_FILE"
  do_check
  assert_fail_kind bad-input "result file"
  # row: a result path with a .. segment fails
  reset_case
  prepare
  edit a.txt
  edit b.txt
  default_result | jq '.changed_paths += ["../x"]' >"$RESULT_FILE"
  do_check
  assert_fail_kind bad-input "../x"
  # row: an absolute and a dash-leading result path fail
  reset_case
  prepare
  edit a.txt
  edit b.txt
  default_result | jq '.changed_paths += ["/etc/passwd", "-rf"]' >"$RESULT_FILE"
  do_check
  assert_fail_kind bad-input "/etc/passwd"
  case "$output" in
    *"-rf"*) ;;
    *)
      echo "$output"
      return 1
      ;;
  esac
}

@test "round-check: passing verifiers or no logs of this round exit 0, a missing or failing verifier exits 1 naming the log" {
  local runs_directory="$BATS_TEST_TMPDIR/runs" attempt_number
  # row: no gate logs, or logs of another round, exit 0
  mkdir -p "$runs_directory"
  run bash "$SCRIPT" round-check --run-folder "$runs_directory" --round 3
  [ "$status" -eq 0 ]
  : >"$runs_directory/gate-2-1.log"
  run bash "$SCRIPT" round-check --run-folder "$runs_directory" --round 3
  [ "$status" -eq 0 ]
  # row: gate logs with passing verifiers exit 0, a missing or failing verifier exits 1 naming the log
  rm -rf "$runs_directory"
  mkdir -p "$runs_directory"
  for attempt_number in 1 2 3; do
    : >"$runs_directory/gate-3-$attempt_number.log"
    printf '{"pass":true}\n' >"$runs_directory/verifier-3-$attempt_number.json"
  done
  run bash "$SCRIPT" round-check --run-folder "$runs_directory" --round 3
  [ "$status" -eq 0 ]
  rm "$runs_directory/verifier-3-2.json"
  run bash "$SCRIPT" round-check --run-folder "$runs_directory" --round 3
  [ "$status" -eq 1 ]
  case "$output" in
    *gate-3-2.log*) ;;
    *)
      echo "$output"
      return 1
      ;;
  esac
  printf '{"pass":false}\n' >"$runs_directory/verifier-3-2.json"
  run bash "$SCRIPT" round-check --run-folder "$runs_directory" --round 3
  [ "$status" -eq 1 ]
  case "$output" in
    *gate-3-2.log*) ;;
    *)
      echo "$output"
      return 1
      ;;
  esac
}

@test "drift: equal tree exits 0; further edit, new untracked file, staged change each exit 1 naming the cause" {
  # row: exit 0 on a tree equal to the baseline
  take_baseline
  run bash "$SCRIPT" drift --root "$REPO" --baseline "$BASELINE_FILE"
  [ "$status" -eq 0 ]
  # row: exit 1 naming the path after a further edit
  reset_case
  take_baseline
  edit stray.txt
  run bash "$SCRIPT" drift --root "$REPO" --baseline "$BASELINE_FILE"
  [ "$status" -eq 1 ]
  case "$output" in
    *stray.txt*) ;;
    *)
      echo "$output"
      return 1
      ;;
  esac
  # row: exit 1 naming the path after a new untracked file
  reset_case
  take_baseline
  printf 'n\n' >"$REPO/fresh.txt"
  run bash "$SCRIPT" drift --root "$REPO" --baseline "$BASELINE_FILE"
  [ "$status" -eq 1 ]
  case "$output" in
    *fresh.txt*) ;;
    *)
      echo "$output"
      return 1
      ;;
  esac
  # row: exit 1 after a staged change
  reset_case
  take_baseline
  edit a.txt
  git -C "$REPO" add a.txt
  run bash "$SCRIPT" drift --root "$REPO" --baseline "$BASELINE_FILE"
  [ "$status" -eq 1 ]
  case "$output" in
    *index-changed*) ;;
    *)
      echo "$output"
      return 1
      ;;
  esac
}

@test "usage: a missing option and an unknown subcommand exit 2" {
  run bash "$SCRIPT" check --root "$REPO"
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" nope
  [ "$status" -eq 2 ]
}

@test "the verifier output is written atomically with the C9 shape on failure" {
  prepare
  edit c.txt
  default_result >"$RESULT_FILE"
  do_check
  [ "$status" -eq 1 ]
  jq -e '.schema == 1 and .round == 1 and .attempt == 1 and .pass == false and (.errors | length > 0)' "$VERIFIER_OUTPUT_FILE" >/dev/null
  [ -z "$(find "$RUN_FOLDER" -name 'verifier-1-1.json.*')" ]
}

# --- the pinned verifier ---

@test "baseline pins the verifier and its libraries beside the baseline file and records their digest" {
  prepare
  for file_name in audit-fix-verify.sh main-root-lib.sh audit-key-lib.sh \
    audit-fix-verify-state-lib.sh audit-fix-verify-check-lib.sh; do
    cmp "$RUN_FOLDER/verifier-bin-1/$file_name" "$BATS_TEST_DIRNAME/../$file_name"
  done
  jq -e '(.verifier_files | sort) == ["audit-fix-verify-check-lib.sh","audit-fix-verify-state-lib.sh","audit-fix-verify.sh","audit-key-lib.sh","main-root-lib.sh"]
    and (.verifier_digest | test("^[0-9a-f]{64}$"))' "$BASELINE_FILE" >/dev/null
}

@test "check, drift and round-check run from the pinned copy and pass" {
  prepare
  edit a.txt
  edit b.txt
  default_result >"$RESULT_FILE"
  run bash "$RUN_FOLDER/verifier-bin-1/audit-fix-verify.sh" check --root "$REPO" --round 1 --attempt 1 \
    --dispositions "$DISPOSITIONS_FILE" --dispositions-sha "$DISPOSITIONS_SHA" --baseline "$BASELINE_FILE" --baseline-sha "$BASELINE_SHA" \
    --result "$RESULT_FILE" --out "$VERIFIER_OUTPUT_FILE"
  [ "$status" -eq 0 ]
  run bash "$RUN_FOLDER/verifier-bin-1/audit-fix-verify.sh" round-check --run-folder "$RUN_FOLDER" --round 1
  [ "$status" -eq 0 ]
}

@test "pin integrity: a tampered pinned script, a tampered pinned library, or a baseline with no pin each refuse" {
  # row: a tampered pinned copy fails check with bad-input
  prepare
  edit a.txt
  edit b.txt
  default_result >"$RESULT_FILE"
  printf '# edited\n' >>"$RUN_FOLDER/verifier-bin-1/audit-fix-verify.sh"
  run bash "$RUN_FOLDER/verifier-bin-1/audit-fix-verify.sh" check --root "$REPO" --round 1 --attempt 1 \
    --dispositions "$DISPOSITIONS_FILE" --dispositions-sha "$DISPOSITIONS_SHA" --baseline "$BASELINE_FILE" --baseline-sha "$BASELINE_SHA" \
    --result "$RESULT_FILE" --out "$VERIFIER_OUTPUT_FILE"
  [ "$status" -eq 1 ]
  jq -e '[.errors[].kind] | index("bad-input") != null' "$VERIFIER_OUTPUT_FILE" >/dev/null
  [[ "$output" == *"pinned"* ]] || return 1
  # row: a tampered pinned library fails drift and round-check
  reset_case
  prepare
  printf '# edited\n' >>"$RUN_FOLDER/verifier-bin-1/main-root-lib.sh"
  run bash "$RUN_FOLDER/verifier-bin-1/audit-fix-verify.sh" drift --root "$REPO" --baseline "$BASELINE_FILE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"pinned"* ]] || return 1
  run bash "$RUN_FOLDER/verifier-bin-1/audit-fix-verify.sh" round-check --run-folder "$RUN_FOLDER" --round 1
  [ "$status" -eq 1 ]
  [[ "$output" == *"pinned"* ]] || return 1
  # row: a baseline that records no pin fails check with bad-input
  reset_case
  prepare
  jq 'del(.verifier_digest)' "$BASELINE_FILE" >"$BASELINE_FILE.n"
  mv "$BASELINE_FILE.n" "$BASELINE_FILE"
  take_digests
  edit a.txt
  edit b.txt
  default_result >"$RESULT_FILE"
  do_check
  assert_fail_kind bad-input pinned
}

# --- settled: the tree the check judged is the tree the round stages ---

do_settled() {
  local security_args=()
  if [[ " $* " != *" --security-paths "* ]]; then
    : >"$RUN_FOLDER/security-none.paths"
    security_args=(--security-paths "$RUN_FOLDER/security-none.paths")
  fi
  run bash "$SCRIPT" settled --root "$REPO" --baseline "$BASELINE_FILE" --baseline-sha "$(sha "$BASELINE_FILE")" \
    --verifier "$VERIFIER_OUTPUT_FILE" --verifier-sha "$(sha "$VERIFIER_OUTPUT_FILE")" \
    --result "$RESULT_FILE" "${security_args[@]}" "$@"
}

# passing_check: a clean pass over two declared edits, its judged record set.
passing_check() {
  prepare
  edit a.txt
  edit b.txt
  default_result >"$RESULT_FILE"
  do_check
  [ "$status" -eq 0 ] || return 1
  jq -e '.judged.paths | has("a.txt") and has("b.txt")' "$VERIFIER_OUTPUT_FILE" >/dev/null
}

# bats test_tags=protected
@test "settled: an unchanged tree passes; a later edit, a new file, or a rewritten result each exit 1 naming it" {
  passing_check
  do_settled
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  # row: the fixer edits a judged path after the check
  edit a.txt
  do_settled
  [ "$status" -eq 1 ]
  [[ "$output" == *"tree-moved: a.txt"* ]] || return 1
  # row: the fixer adds a file after the check
  reset_case
  passing_check
  printf 'late\n' >"$REPO/late.txt"
  do_settled
  [ "$status" -eq 1 ]
  [[ "$output" == *"tree-moved: late.txt"* ]] || return 1
  # row: the fixer edits a file it created before the check
  reset_case
  passing_check
  printf 'new\n' >"$REPO/new.txt"
  jq '.changed_paths += ["new.txt"] | .results[0].changed_paths += ["new.txt"]' "$RESULT_FILE" >"$RESULT_FILE.n"
  mv "$RESULT_FILE.n" "$RESULT_FILE"
  do_check
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  printf 'edited later\n' >>"$REPO/new.txt"
  do_settled
  [ "$status" -eq 1 ]
  [[ "$output" == *"tree-moved: new.txt"* ]] || return 1
  # row: the fixer rewrites its result file after the check, tree unchanged
  reset_case
  passing_check
  jq '.changed_paths += ["c.txt"]' "$RESULT_FILE" >"$RESULT_FILE.n"
  mv "$RESULT_FILE.n" "$RESULT_FILE"
  do_settled
  [ "$status" -eq 1 ]
  [[ "$output" == *"result-moved"* ]] || return 1
  [[ "$output" == *"tree-moved"* ]] && return 1
  true
}

@test "settled: --security-paths exempts only the writer's tests, --gate-paths only the post-gate re-check's, --extra-declared is a usage error" {
  passing_check
  printf 'security test\n' >"$REPO/sec.test.txt"
  edit a.txt
  printf 'sec.test.txt' >"$RUN_FOLDER/security-1.paths"
  do_settled --security-paths "$RUN_FOLDER/security-1.paths"
  [ "$status" -eq 1 ]
  [[ "$output" == *"tree-moved: a.txt"* ]] || return 1
  [[ "$output" == *"sec.test.txt"* ]] && return 1
  # row: a gate path is exempt only through --gate-paths, and a file with no
  # trailing newline does not fuse with the next one
  printf 'a.txt\n' >"$RUN_FOLDER/gate-1-1.paths"
  do_settled --security-paths "$RUN_FOLDER/security-1.paths" --gate-paths "$RUN_FOLDER/gate-1-1.paths"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  # row: a path the check already judged and a gate autofix rewrote is not exempt before the gate
  reset_case
  passing_check
  edit a.txt
  printf 'a.txt\n' >"$RUN_FOLDER/gate-1-1.paths"
  do_settled
  [ "$status" -eq 1 ]
  [[ "$output" == *"tree-moved: a.txt"* ]] || return 1
  # row: a gate path outside the judged record (a late fixer file) is not exempt
  reset_case
  passing_check
  printf 'late\n' >"$REPO/late.txt"
  printf 'late.txt\n' >"$RUN_FOLDER/gate-1-1.paths"
  do_settled --gate-paths "$RUN_FOLDER/gate-1-1.paths"
  [ "$status" -eq 1 ]
  [[ "$output" == *"tree-moved: late.txt"* ]] || return 1
  # row: the removed option is refused, and so is a run without --security-paths
  do_settled --extra-declared "$RUN_FOLDER/security-1.paths"
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" settled --root "$REPO" --baseline "$BASELINE_FILE" --baseline-sha "$(sha "$BASELINE_FILE")" \
    --verifier "$VERIFIER_OUTPUT_FILE" --verifier-sha "$(sha "$VERIFIER_OUTPUT_FILE")" --result "$RESULT_FILE"
  [ "$status" -eq 2 ]
}

@test "settled refuses a baseline file rewritten after it was recorded" {
  passing_check
  local recorded_sha
  recorded_sha="$(sha "$BASELINE_FILE")"
  jq '.untracked += ["forged"]' "$BASELINE_FILE" >"$BASELINE_FILE.n"
  mv "$BASELINE_FILE.n" "$BASELINE_FILE"
  : >"$RUN_FOLDER/security-none.paths"
  run bash "$SCRIPT" settled --root "$REPO" --baseline "$BASELINE_FILE" --baseline-sha "$recorded_sha" \
    --verifier "$VERIFIER_OUTPUT_FILE" --verifier-sha "$(sha "$VERIFIER_OUTPUT_FILE")" \
    --result "$RESULT_FILE" --security-paths "$RUN_FOLDER/security-none.paths"
  [ "$status" -eq 1 ]
  [[ "$output" == *"bad-input"* ]] || return 1
  [[ "$output" == *"baseline digest"* ]] || return 1
}

@test "settled refuses a verifier output rewritten after the check" {
  passing_check
  local recorded_sha
  recorded_sha="$(sha "$VERIFIER_OUTPUT_FILE")"
  edit a.txt
  jq --argjson paths "$(jq -c '.judged.paths' "$VERIFIER_OUTPUT_FILE" | jq -c '.["a.txt"] = "forged"')" \
    '.judged.paths = $paths' "$VERIFIER_OUTPUT_FILE" >"$VERIFIER_OUTPUT_FILE.n"
  mv "$VERIFIER_OUTPUT_FILE.n" "$VERIFIER_OUTPUT_FILE"
  : >"$RUN_FOLDER/security-none.paths"
  run bash "$SCRIPT" settled --root "$REPO" --baseline "$BASELINE_FILE" --baseline-sha "$(sha "$BASELINE_FILE")" \
    --verifier "$VERIFIER_OUTPUT_FILE" --verifier-sha "$recorded_sha" \
    --result "$RESULT_FILE" --security-paths "$RUN_FOLDER/security-none.paths"
  [ "$status" -eq 1 ]
  [[ "$output" == *"bad-input"* ]] || return 1
}

@test "settled refuses a failing verifier output, one with no judged record, a moved HEAD and a tampered pin" {
  # row: a failing check records no judged tree, and settled refuses it
  prepare
  edit c.txt
  default_result >"$RESULT_FILE"
  do_check
  [ "$status" -eq 1 ]
  [ "$(jq -r '.judged' "$VERIFIER_OUTPUT_FILE")" = null ]
  do_settled
  [ "$status" -eq 1 ]
  [[ "$output" == *"bad-input"* ]] || return 1
  # row: a passing output stripped of its judged record
  reset_case
  passing_check
  jq 'del(.judged)' "$VERIFIER_OUTPUT_FILE" >"$VERIFIER_OUTPUT_FILE.n"
  mv "$VERIFIER_OUTPUT_FILE.n" "$VERIFIER_OUTPUT_FILE"
  do_settled
  [ "$status" -eq 1 ]
  [[ "$output" == *"bad-input"* ]] || return 1
  # row: HEAD moved after the check
  reset_case
  passing_check
  git -C "$REPO" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m late
  do_settled
  [ "$status" -eq 1 ]
  [[ "$output" == *"head-moved"* ]] || return 1
  # row: settled from a tampered pinned copy
  reset_case
  passing_check
  printf '# edited\n' >>"$RUN_FOLDER/verifier-bin-1/audit-fix-verify-check-lib.sh"
  : >"$RUN_FOLDER/security-none.paths"
  run bash "$RUN_FOLDER/verifier-bin-1/audit-fix-verify.sh" settled --root "$REPO" --baseline "$BASELINE_FILE" --baseline-sha "$(sha "$BASELINE_FILE")" \
    --verifier "$VERIFIER_OUTPUT_FILE" --verifier-sha "$(sha "$VERIFIER_OUTPUT_FILE")" \
    --result "$RESULT_FILE" --security-paths "$RUN_FOLDER/security-none.paths"
  [ "$status" -eq 1 ]
  [[ "$output" == *"pinned"* ]] || return 1
}
