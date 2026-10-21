#!/usr/bin/env bats
# Suite for the audit recall corpus under .gaia/tests/audit-recall: the
# committed corpus's schema, selection determinism and the base rule, the
# replay tree builder, both-bundle selection and --check, the scorer over its
# committed fixture runs, run-recall.sh's input guards and its hook dry run,
# and the planted patches.
#
# Every test runs the committed recall scripts, reads the committed corpus,
# fixtures or planted patches, or copies HEAD's harness into a fixture
# repository, so each carries the whole-tree mark. Fixture repositories live
# in $BATS_TEST_TMPDIR; no test touches the shared checkout, and none calls
# claude: gh and claude are stubs first on PATH.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  THIS_DIRECTORY="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIRECTORY/../../.." && pwd )"
  RECALL="$REPO_ROOT/.gaia/tests/audit-recall"
  CORPUS="$RECALL/corpus.json"
  SCORE_FIXTURES="$RECALL/fixtures/score"
  MARKER_PATH=".claude/rules/maintainers/harness-triage-threshold.md"
  STUB_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB_BIN"
  # gh answers "no pull request" the way the hook's fork check reads it.
  printf '#!/usr/bin/env bash\necho "no pull requests found for branch \\"replay\\"" >&2\nexit 1\n' >"$STUB_BIN/gh"
  printf '#!/usr/bin/env bash\necho called >>"%s/claude-called"\nexit 1\n' "$BATS_TEST_TMPDIR" >"$STUB_BIN/claude"
  chmod +x "$STUB_BIN/gh" "$STUB_BIN/claude"
}

fixture_git() {
  git -C "$FIXTURE" -c user.name=fixture -c user.email=fixture@example.com -c commit.gpgsign=false "$@"
}

replace_line() {
  local file="$1" from="$2" to="$3"
  sed "s/^$from\$/$to/" "$file" >"$file.next"
  mv "$file.next" "$file"
}

# build_maintainer_fixture <dir>: a maintainer-shaped repository. Its root
# commit (tag base) carries HEAD's harness, maintainer marker included, plus
# app/one.sh and a fixture rule. Tag change, on main: app line 10 and rule
# three reworded. Tag bundle-conflicting rewords rule three too; tag
# bundle-clean appends a rule. origin/main points at main.
build_maintainer_fixture() {
  FIXTURE="$1"
  git init -q -b main "$FIXTURE"
  git -C "$REPO_ROOT" archive HEAD .claude .gaia/scripts .gaia/tests/helpers .github/audit | tar -x -C "$FIXTURE"
  mkdir -p "$FIXTURE/app"
  seq 1 40 | sed 's/^/line /' >"$FIXTURE/app/one.sh"
  printf 'rule one\nrule two\nrule three\nrule four\n' >"$FIXTURE/.claude/rules/fixture-rule.md"
  fixture_git add -A
  fixture_git commit -q --no-verify -m "base"
  fixture_git tag base
  fixture_git checkout -q -b bundle-conflicting
  replace_line "$FIXTURE/.claude/rules/fixture-rule.md" "rule three" "rule three, bundle wording"
  fixture_git commit -q --no-verify -am "bundle: reword rule three"
  fixture_git tag bundle-conflicting
  fixture_git checkout -q -b bundle-clean base
  printf 'rule five\n' >>"$FIXTURE/.claude/rules/fixture-rule.md"
  fixture_git commit -q --no-verify -am "bundle: add rule five"
  fixture_git tag bundle-clean
  fixture_git checkout -q main
  replace_line "$FIXTURE/app/one.sh" "line 10" "line 10 changed"
  replace_line "$FIXTURE/.claude/rules/fixture-rule.md" "rule three" "rule three, change wording"
  fixture_git commit -q --no-verify -am "change: app line ten and rule three"
  fixture_git tag change
  fixture_git update-ref refs/remotes/origin/main main
}

# mined_source <file> <line>...: mined findings in the source file's shape,
# one per line, each recording the audit base the way the miner did.
mined_source() {
  local file="$1" base
  shift
  base="$(git -C "$FIXTURE" rev-parse base)"
  printf '%s\n' "$@" | jq -R -s --arg base "$base" '
    [split("\n")[] | select(. != "") | tonumber |
      {member: "code-audit-maintainer-shell", session: "fixture-session", agent_id: ("agent-" + tostring),
       head_sha: $base, class: "correctness/fixture", severity: "major", path: "app/one.sh", line: .,
       title: ("finding on line " + tostring), repo_project: "fixture"}]' >"$file"
}

run_select() {
  run node "$RECALL/select.mjs" --source "$SOURCE" --repo "$FIXTURE" "$@"
}

scratch_scaffold() {
  SCAFFOLD="$BATS_TEST_TMPDIR/scaffold"
  mkdir -p "$SCAFFOLD/.gaia/local"
  : >"$SCAFFOLD/.gaia/local/measurement-scratch"
}

# A one-entry corpus naming the fixture's change.
fixture_corpus() {
  jq -n --arg base "$(git -C "$FIXTURE" rev-parse base)" --arg head "$(git -C "$FIXTURE" rev-parse change)" \
    '{schema: 1, seed: 122, selected_against: $head, selection_bundles: {before: $base, after: $base},
      entries: [{id: "real-fixture-entry", source: "real", member: "code-audit-maintainer-shell", scorer: "member",
        path: "app/one.sh", line: 10, class_prefix: "correctness", head_sha: $head, base_sha: $base,
        origin: {session: "fixture-session", agent_id: "agent-10", title: "fixture"}}],
      skipped: []}' >"$1"
}

# bats test_tags=whole-tree
@test "the committed corpus is schema 1 with seed 122, two selection bundles and well-formed entries" {
  jq -e '.schema == 1 and .seed == 122 and (.selected_against | test("^[0-9a-f]{40}$"))' "$CORPUS"
  jq -e '(.selection_bundles | keys) == ["after", "before"] and ([.selection_bundles[] | test("^[0-9a-f]{40}$")] | all)' "$CORPUS"
  jq -e '(.skipped | type) == "array" and ([.skipped[] | (.id | type) == "string" and (.reason | type) == "string"] | all)' "$CORPUS"
  local active
  active="$(git -C "$REPO_ROOT" ls-tree --name-only HEAD .claude/agents/ | sed -n 's|^\.claude/agents/\(code-audit-[a-z-]*\)\.md$|\1|p' | grep -v '^code-audit-maintainer-prose$' | jq -R -s 'split("\n") | map(select(. != ""))')"
  [ "$(jq 'length' <<<"$active")" -gt 0 ]
  jq -e --argjson active "$active" '
    [.entries[] | select(.source == "real")] as $real
    | ($real | length) > 0
    and ([$real[] | (.head_sha | test("^[0-9a-f]{40}$")) and (.base_sha | test("^[0-9a-f]{40}$"))
          and (.origin | (.session | type) == "string" and (.agent_id | type) == "string" and (.title | type) == "string")
          and (.member as $m | $active | index($m)) != null and .scorer == "member"
          and (.class_prefix | type) == "string" and (.line | type) == "number"
          and (has("repo_project") | not)] | all)
    and ([$real | group_by(.member)[] | length] | max) <= 10' "$CORPUS"
  jq -e '[.entries[] | select(.source == "planted") | (.planted_patch | type) == "string" and (has("head_sha") | not)] | all' "$CORPUS"
  jq -e '[.entries[].id] | length == (unique | length)' "$CORPUS"
  grep -q '/Users/' "$CORPUS" && return 1
  grep -Eq '(SPEC|UAT|PLAN)-[0-9]|\.notebook/|\.gaia/local/' "$CORPUS" && return 1
  true
}

# bats test_tags=whole-tree
@test "every committed recall file is free of a home path and a working-document id" {
  local hits
  hits="$(grep -rlE '/Users/|/home/[a-z]|(SPEC|UAT|PLAN)-[0-9]' "$RECALL" || true)"
  [ -z "$hits" ] || { echo "$hits"; return 1; }
}

# bats test_tags=whole-tree
@test "the PRNG gives the same order for the same seed and a different order for another seed" {
  run node --input-type=module -e "
    import { seededShuffle } from '$RECALL/lib/prng.mjs';
    const items = Array.from({ length: 20 }, (_, index) => index);
    const first = seededShuffle(items, 122).join(',');
    const again = seededShuffle(items, 122).join(',');
    const other = seededShuffle(items, 123).join(',');
    console.log(first === again, first !== other, items.join(',') === Array.from({ length: 20 }, (_, index) => index).join(','));"
  [ "$status" -eq 0 ]
  [ "$output" = "true true true" ]
}

# bats test_tags=whole-tree
@test "selection is byte-identical on a re-run, and seed 123 gives a different entry order" {
  build_maintainer_fixture "$BATS_TEST_TMPDIR/maintainer"
  SOURCE="$BATS_TEST_TMPDIR/mined.json"
  mined_source "$SOURCE" 1 8 15 22 29 36
  run_select --bundle-before base --bundle-after bundle-clean --out "$BATS_TEST_TMPDIR/first.json"
  [ "$status" -eq 0 ]
  run_select --bundle-before base --bundle-after bundle-clean --out "$BATS_TEST_TMPDIR/second.json"
  [ "$status" -eq 0 ]
  cmp "$BATS_TEST_TMPDIR/first.json" "$BATS_TEST_TMPDIR/second.json"
  [ "$(jq '[.entries[] | select(.source == "real")] | length' "$BATS_TEST_TMPDIR/first.json")" -eq 6 ]
  run_select --bundle-before base --bundle-after bundle-clean --out "$BATS_TEST_TMPDIR/seeded.json" --seed 123
  [ "$status" -eq 0 ]
  [ "$(jq -c '[.entries[] | select(.source == "real") | .line] | sort' "$BATS_TEST_TMPDIR/seeded.json")" = "$(jq -c '[.entries[] | select(.source == "real") | .line] | sort' "$BATS_TEST_TMPDIR/first.json")" ]
  [ "$(jq -c '[.entries[] | select(.source == "real") | .line]' "$BATS_TEST_TMPDIR/seeded.json")" != "$(jq -c '[.entries[] | select(.source == "real") | .line]' "$BATS_TEST_TMPDIR/first.json")" ]
  [ "$(jq '.seed' "$BATS_TEST_TMPDIR/seeded.json")" -eq 123 ]
  # The mined sha is the audit base; the kept head is the change that touched the path.
  [ "$(jq -r '[.entries[] | select(.source == "real") | .head_sha] | unique[]' "$BATS_TEST_TMPDIR/first.json")" = "$(git -C "$FIXTURE" rev-parse change)" ]
  [ "$(jq -r '[.entries[] | select(.source == "real") | .base_sha] | unique[]' "$BATS_TEST_TMPDIR/first.json")" = "$(git -C "$FIXTURE" rev-parse base)" ]
}

# bats test_tags=whole-tree
@test "the base rule: a merged branch, a squash merge and a direct commit each get the expected base" {
  FIXTURE="$BATS_TEST_TMPDIR/history"
  git init -q -b main "$FIXTURE"
  local step
  echo c0 >"$FIXTURE/c0"; fixture_git add -A; fixture_git commit -q --no-verify -m c0; fixture_git tag c0
  fixture_git checkout -q -b feature
  for step in f1 f2; do echo "$step" >"$FIXTURE/$step"; fixture_git add -A; fixture_git commit -q --no-verify -m "$step"; fixture_git tag "$step"; done
  fixture_git checkout -q main
  echo q1 >"$FIXTURE/q1"; fixture_git add -A; fixture_git commit -q --no-verify -m q1; fixture_git tag q1
  fixture_git merge -q --no-ff --no-edit feature
  fixture_git tag m1
  fixture_git checkout -q -b squashed
  for step in s1 s2; do echo "$step" >"$FIXTURE/$step"; fixture_git add -A; fixture_git commit -q --no-verify -m "$step"; fixture_git tag "$step"; done
  fixture_git checkout -q main
  fixture_git merge -q --squash squashed
  fixture_git commit -q --no-verify -m "squash of s1 and s2"
  fixture_git tag squash
  echo d1 >"$FIXTURE/d1"; fixture_git add -A; fixture_git commit -q --no-verify -m d1; fixture_git tag d1
  fixture_git update-ref refs/remotes/origin/main main
  run node --input-type=module -e "
    import { baseShaFor } from '$RECALL/lib/replay-range.mjs';
    for (const head of ['f2', 'f1', 'squash', 'd1', 's2']) console.log(head, baseShaFor('$FIXTURE', head) ?? 'null');"
  [ "$status" -eq 0 ]
  sha_of() { git -C "$FIXTURE" rev-parse "$1"; }
  [ "$(sed -n 1p <<<"$output")" = "f2 $(sha_of c0)" ]
  [ "$(sed -n 2p <<<"$output")" = "f1 $(sha_of c0)" ]
  [ "$(sed -n 3p <<<"$output")" = "squash $(sha_of m1)" ]
  [ "$(sed -n 4p <<<"$output")" = "d1 $(sha_of squash)" ]
  [ "$(sed -n 5p <<<"$output")" = "s2 null" ]
}

# bats test_tags=whole-tree
@test "build-tree commits main and replay in a standalone, marker-free clone, and a conflicting overlay exits 4" {
  build_maintainer_fixture "$BATS_TEST_TMPDIR/maintainer"
  local clone="$BATS_TEST_TMPDIR/clean"
  run bash "$RECALL/build-tree.sh" --repo "$FIXTURE" --bundle bundle-clean --base base --head change --clone "$clone"
  [ "$status" -eq 0 ]
  [ "$(git -C "$clone" rev-parse --abbrev-ref HEAD)" = replay ]
  [ "$(git -C "$clone" rev-parse replay^)" = "$(git -C "$clone" rev-parse main)" ]
  [ "$(git -C "$clone" rev-parse --git-common-dir)" = .git ]
  [ -d "$clone/.git" ]
  git -C "$clone" cat-file -e "main:.claude/rules/fixture-rule.md"
  git -C "$clone" show main:.claude/rules/fixture-rule.md | grep -qx 'rule five'
  git -C "$clone" show replay:app/one.sh | grep -qx 'line 10 changed'
  git -C "$clone" cat-file -e "main:$MARKER_PATH" 2>/dev/null && return 1
  [ ! -e "$clone/$MARKER_PATH" ]
  [ -f "$clone/.gaia/local/measurement-scratch" ]
  # The source fixture still carries the marker: only the clone was stripped.
  git -C "$FIXTURE" cat-file -e "change:$MARKER_PATH"
  run bash "$RECALL/build-tree.sh" --repo "$FIXTURE" --bundle bundle-conflicting --base base --head change --clone "$BATS_TEST_TMPDIR/conflict"
  [ "$status" -eq 4 ]
  [ "$(tail -n 1 <<<"$output")" = "build-tree: failed: patch-conflicts-overlay" ]
}

# bats test_tags=whole-tree
@test "both-bundle selection skips an entry that conflicts with the after bundle and --check names it; a clean after bundle keeps it" {
  build_maintainer_fixture "$BATS_TEST_TMPDIR/maintainer"
  SOURCE="$BATS_TEST_TMPDIR/mined.json"
  mined_source "$SOURCE" 10
  run_select --bundle-before base --bundle-after bundle-conflicting --out "$BATS_TEST_TMPDIR/conflicting.json"
  [ "$status" -eq 0 ]
  [ "$(jq '[.entries[] | select(.source == "real")] | length' "$BATS_TEST_TMPDIR/conflicting.json")" -eq 0 ]
  [ "$(jq -r '.skipped[] | select(.member == "code-audit-maintainer-shell") | .reason' "$BATS_TEST_TMPDIR/conflicting.json")" = "patch-conflicts-overlay (after)" ]
  # Red twin: a clean after bundle keeps the same finding.
  run_select --bundle-before base --bundle-after bundle-clean --out "$BATS_TEST_TMPDIR/clean.json"
  [ "$status" -eq 0 ]
  [ "$(jq '[.entries[] | select(.source == "real")] | length' "$BATS_TEST_TMPDIR/clean.json")" -eq 1 ]
  local kept_id
  kept_id="$(jq -r '.entries[] | select(.source == "real") | .id' "$BATS_TEST_TMPDIR/clean.json")"
  [ "$(jq -r '.selection_bundles.after' "$BATS_TEST_TMPDIR/clean.json")" = "$(git -C "$FIXTURE" rev-parse bundle-clean)" ]
  run node "$RECALL/select.mjs" --repo "$FIXTURE" --bundle-before base --bundle-after bundle-clean --out "$BATS_TEST_TMPDIR/clean.json" --check
  [ "$status" -eq 0 ]
  run node "$RECALL/select.mjs" --repo "$FIXTURE" --bundle-before base --bundle-after bundle-conflicting --out "$BATS_TEST_TMPDIR/clean.json" --check
  [ "$status" -eq 2 ]
  [ "$output" = "check: $kept_id: patch-conflicts-overlay (after)" ]
}

# bats test_tags=whole-tree
@test "score over the fixture runs fails exactly the entries expected.json lists, and passes the passing corpus" {
  local runs="$SCORE_FIXTURES/runs"
  run node "$RECALL/score.mjs" --corpus "$SCORE_FIXTURES/corpus.json" --before "$runs/before-1" "$runs/before-2" --after "$runs/after-1" "$runs/after-2"
  [ "$status" -eq "$(jq '."corpus.json".exit' "$SCORE_FIXTURES/expected.json")" ]
  [ "$status" -eq 1 ]
  [ "$(jq '.gating' <<<"$output")" -eq "$(jq '."corpus.json".gating' "$SCORE_FIXTURES/expected.json")" ]
  [ "$(jq -c '[.failures[].id] | sort' <<<"$output")" = "$(jq -c '."corpus.json".failures | sort' "$SCORE_FIXTURES/expected.json")" ]
  # (a) found in both before runs, neither after run.
  jq -e '[.failures[].id] | index("m-lost") != null' <<<"$output"
  # (b) found in both before runs and one after run; (c) found in one before run only.
  jq -e '[.failures[].id] | (index("m-kept") == null) and (index("m-flaky") == null)' <<<"$output"
  # (d) 5 lines away matches in the before runs (gating), 6 away misses after; (e) another class prefix misses.
  jq -e '[.failures[].id] | (index("m-window") != null) and (index("m-class") != null)' <<<"$output"
  # (f) a specialist entry found only in the member's merged report is a miss.
  jq -e '.failures[] | select(.id == "s-merged") | .scorer == "specialist" and .role == "typescript"' <<<"$output"
  # (g) a refuter entry whose after verdicts both differ fails; a stable one does not.
  jq -e '[.failures[].id] | (index("r-flip") != null) and (index("r-stable") == null)' <<<"$output"
  # (j) the before-bundle "Translation rules audit" child scores as the translation role: gating, then lost.
  jq -e '.failures[] | select(.id == "s-translation") | .role == "translation"' <<<"$output"
  jq -e '.specialist_failures_only == false' <<<"$output"
  run node "$RECALL/score.mjs" --corpus "$SCORE_FIXTURES/corpus-pass.json" --before "$runs/before-1" "$runs/before-2" --after "$runs/after-1" "$runs/after-2"
  [ "$status" -eq 0 ]
  [ "$(jq '.gating' <<<"$output")" -eq "$(jq '."corpus-pass.json".gating' "$SCORE_FIXTURES/expected.json")" ]
  [ "$(jq '.failures | length' <<<"$output")" -eq 0 ]
}

# bats test_tags=whole-tree
@test "score exits 2 on a missing run directory and on a run missing one entry's result, never a pass" {
  local runs="$SCORE_FIXTURES/runs"
  run node "$RECALL/score.mjs" --corpus "$SCORE_FIXTURES/corpus.json" --before "$runs/before-1" "$runs/before-2" --after "$runs/after-1" "$BATS_TEST_TMPDIR/no-such-run"
  [ "$status" -eq 2 ]
  # after-2 holds no m-absent directory.
  [ ! -e "$runs/after-2/m-absent" ]
  run node "$RECALL/score.mjs" --corpus "$SCORE_FIXTURES/corpus-missing.json" --before "$runs/before-1" "$runs/before-2" --after "$runs/after-1" "$runs/after-2"
  [ "$status" -eq "$(jq '."corpus-missing.json".exit' "$SCORE_FIXTURES/expected.json")" ]
  [ "$status" -eq 2 ]
  run node "$RECALL/score.mjs" --before "$runs/before-1" --after "$runs/after-1" "$runs/after-2"
  [ "$status" -eq 2 ]
}

# bats test_tags=whole-tree
@test "run-recall refuses a missing --max-usd, an unknown --bundle and a scaffold without the sentinel" {
  scratch_scaffold
  run bash "$RECALL/run-recall.sh" --bundle before --run 1 --clone "$BATS_TEST_TMPDIR/clones" --scaffold "$SCAFFOLD" --out "$BATS_TEST_TMPDIR/out"
  [ "$status" -eq 2 ]
  [[ "$output" == *usage:* ]]
  run bash "$RECALL/run-recall.sh" --bundle sideways --run 1 --clone "$BATS_TEST_TMPDIR/clones" --scaffold "$SCAFFOLD" --out "$BATS_TEST_TMPDIR/out" --max-usd 1
  [ "$status" -eq 2 ]
  [[ "$output" == *"--bundle must be before or after"* ]]
  mkdir -p "$BATS_TEST_TMPDIR/bare-scaffold"
  run bash "$RECALL/run-recall.sh" --bundle before --run 1 --clone "$BATS_TEST_TMPDIR/clones" --scaffold "$BATS_TEST_TMPDIR/bare-scaffold" --out "$BATS_TEST_TMPDIR/out" --max-usd 1
  [ "$status" -eq 2 ]
  [[ "$output" == *"measurement-scratch sentinel"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/out" ]
}

# bats test_tags=whole-tree
@test "a replay tree that fails to build at run time exits 2 naming the entry and records no result" {
  FIXTURE="$BATS_TEST_TMPDIR/source"
  git init -q -b main "$FIXTURE"
  scratch_scaffold
  local corpus="$BATS_TEST_TMPDIR/corpus.json"
  jq -n '{schema: 1, seed: 122, selection_bundles: {before: "0000000", after: "0000000"},
    entries: [{id: "real-stubbed-entry", source: "real", member: "code-audit-maintainer-shell", scorer: "member",
      path: "app/one.sh", line: 1, class_prefix: "correctness", head_sha: "1111111", base_sha: "2222222",
      origin: {session: "s", agent_id: "a", title: "t"}}], skipped: []}' >"$corpus"
  printf '#!/usr/bin/env bash\necho "build-tree: failed: patch-conflicts-overlay" >&2\nexit 4\n' >"$STUB_BIN/build-tree.sh"
  chmod +x "$STUB_BIN/build-tree.sh"
  PATH="$STUB_BIN:$PATH" AUDIT_RECALL_BUILD_TREE="$STUB_BIN/build-tree.sh" run bash "$RECALL/run-recall.sh" --bundle before --run 1 \
    --clone "$BATS_TEST_TMPDIR/clones" --scaffold "$SCAFFOLD" --out "$BATS_TEST_TMPDIR/out" --max-usd 1 \
    --repo "$FIXTURE" --bundle-sha 0000000 --corpus "$corpus"
  [ "$status" -eq 2 ]
  [[ "$output" == *"real-stubbed-entry: the replay tree did not build (exit 4)"* ]]
  [ ! -e "$BATS_TEST_TMPDIR/out/real-stubbed-entry" ]
  [ ! -e "$BATS_TEST_TMPDIR/claude-called" ]
}

# bats test_tags=whole-tree
@test "the dry run reaches the member dispatch without a BLOCKED deny, and a tree that keeps the maintainer marker is denied" {
  build_maintainer_fixture "$BATS_TEST_TMPDIR/maintainer"
  scratch_scaffold
  local corpus="$BATS_TEST_TMPDIR/corpus.json"
  fixture_corpus "$corpus"
  PATH="$STUB_BIN:$PATH" run bash "$RECALL/run-recall.sh" --bundle after --run 1 --clone "$BATS_TEST_TMPDIR/dry" \
    --scaffold "$SCAFFOLD" --out "$BATS_TEST_TMPDIR/out" --max-usd 1 --dry-run --repo "$FIXTURE" --bundle-sha bundle-clean --corpus "$corpus"
  [ "$status" -eq 0 ]
  [[ "$output" == *"real-fixture-entry: code-audit-maintainer-shell dispatch allowed"* ]]
  [[ "$output" == *BLOCKED* ]] && return 1
  [ ! -e "$BATS_TEST_TMPDIR/out" ]
  [ ! -e "$BATS_TEST_TMPDIR/claude-called" ]
  # Red twin: the same build with the marker restored and no verify-pass record.
  cat >"$STUB_BIN/build-keeping-marker.sh" <<EOF
#!/usr/bin/env bash
set -e
bash "$RECALL/build-tree.sh" "\$@"
while [ "\$#" -gt 0 ]; do [ "\$1" = --clone ] && clone="\$2"; shift; done
mkdir -p "\$clone/.claude/rules/maintainers"
: >"\$clone/$MARKER_PATH"
EOF
  chmod +x "$STUB_BIN/build-keeping-marker.sh"
  PATH="$STUB_BIN:$PATH" AUDIT_RECALL_BUILD_TREE="$STUB_BIN/build-keeping-marker.sh" run bash "$RECALL/run-recall.sh" --bundle after --run 1 \
    --clone "$BATS_TEST_TMPDIR/dry-marker" --scaffold "$SCAFFOLD" --out "$BATS_TEST_TMPDIR/out" --max-usd 1 --dry-run \
    --repo "$FIXTURE" --bundle-sha bundle-clean --corpus "$corpus"
  [ "$status" -eq 1 ]
  [[ "$output" == *"BLOCKED: audit verify"* ]]
}

# bats test_tags=whole-tree
@test "every planted entry names a path its patch touches, and every planted patch applies to HEAD's frontend" {
  local entries="$RECALL/planted/entries.json" patch path count
  count="$(jq 'length' "$entries")"
  [ "$count" -gt 0 ]
  [ "$(jq '[.[] | select(.source == "planted")] | length' "$entries")" -eq "$count" ]
  for patch in rule-violations holistic-true holistic-false; do
    [ "$(jq --arg patch "planted/$patch.patch" '[.[] | select(.planted_patch == $patch)] | length' "$entries")" -gt 0 ]
  done
  [ "$(jq '[.[] | select(.scorer == "refuter" and .planted_patch == "planted/holistic-true.patch")] | length' "$entries")" -ge 2 ]
  [ "$(jq '[.[] | select(.scorer == "refuter" and .planted_patch == "planted/holistic-false.patch")] | length' "$entries")" -ge 2 ]
  local checked=0
  while IFS=$'\t' read -r patch path; do
    grep -qxF -- "+++ b/$path" "$RECALL/$patch" || { echo "$path is not touched by $patch"; return 1; }
    checked=$((checked + 1))
  done < <(jq -r '.[] | [.planted_patch, .path] | @tsv' "$entries")
  [ "$checked" -eq "$count" ]
  local export_directory="$BATS_TEST_TMPDIR/export"
  mkdir -p "$export_directory"
  git -C "$REPO_ROOT" archive HEAD frontend | tar -x -C "$export_directory"
  for patch in "$RECALL"/planted/*.patch; do
    git -C "$export_directory" apply --check "$patch" || { echo "$patch does not apply"; return 1; }
  done
}
