#!/usr/bin/env bats
#
# Pins the contracts the /gaia-fitness judgment step relies on, all owned by
# .gaia/scripts/fitness-judge-input.sh:
#   1. the dispatch condition (build exits 3 when there is nothing to judge),
#   2. the input build: what enters it, per-file line numbers, parts that fit
#      one Read, and groups that keep a file's slices together, and
#   3. collect's classification: a reply that does not prove it read every
#      part to its end is a no-op, never a clean pass.
#
# Run under bash 5: `.gaia/scripts/bats5.sh .gaia/scripts/tests/fitness-judge-dispatch.bats < /dev/null`
# (.claude/rules/bats-assertions.md).

setup() {
  SCRIPTS_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPT="$SCRIPTS_DIR/fitness-judge-input.sh"
  PROJECT="$BATS_TEST_TMPDIR/project"
  OUT="$BATS_TEST_TMPDIR/judge"
  REPORT="$BATS_TEST_TMPDIR/check.json"
  mkdir -p "$PROJECT"
  git -C "$PROJECT" init -q
}

entry() {
  # entry <path> <kind> <ownership> <path_scoped>
  printf '{"path":"%s","kinds":["%s"],"words":10,"lines":3,"model":"unresolved","ownership":"%s","path_scoped":%s}' "$1" "$2" "$3" "$4"
}

write_report() {
  printf '{"scope":"adopter","findings":[],"inventory":[%s]}\n' "$1" >"$REPORT"
}

build() {
  cd "$PROJECT" || return 1
  run bash "$SCRIPT" build --check "$REPORT" --out-dir "$OUT" "$@"
}

# receipts <group>: a reply holding a correct receipt for every part of the group.
receipts() {
  jq --argjson group "$1" '[.groups[] | select(.group == $group) | .parts[] | {judgment: "input-read", file: .path, token: .token}]' "$OUT/manifest.json"
}

collect() {
  run bash "$SCRIPT" collect --manifest "$OUT/manifest.json" --out "$BATS_TEST_TMPDIR/judgment.json"
}

# small_project: two skills and a path-scoped rule, each a few lines, all
# tracked, one judge group.
small_project() {
  mkdir -p "$PROJECT/.claude/skills/a" "$PROJECT/.claude/skills/b" "$PROJECT/.claude/rules"
  printf -- '---\nname: a\ndescription: does a\n---\nfirst a\nsecond a\n' >"$PROJECT/.claude/skills/a/SKILL.md"
  printf 'first b\nsecond b\nthird b' >"$PROJECT/.claude/skills/b/SKILL.md"
  printf 'rule body\n' >"$PROJECT/.claude/rules/scoped.md"
  git -C "$PROJECT" add .claude
  write_report "$(entry .claude/skills/a/SKILL.md skill adopter false),$(entry .claude/skills/b/SKILL.md skill adopter false),$(entry .claude/rules/scoped.md rule adopter true)"
}

@test "nothing to judge: only third-party and ignored skills" {
  write_report "$(entry .claude/skills/vendored/SKILL.md skill third-party false),$(entry .claude/skills/local/SKILL.md skill ignored false)"
  build
  [ "$status" -eq 3 ]
}

@test "nothing to judge: a rule that is not path scoped" {
  write_report "$(entry .claude/rules/always.md rule adopter false)"
  build
  [ "$status" -eq 3 ]
}

@test "nothing to judge: references and wiki pages alone" {
  write_report "$(entry .claude/skills/example/references/a.md reference adopter false),$(entry wiki/page.md wiki adopter false)"
  build
  [ "$status" -eq 3 ]
}

@test "nothing to judge: an empty inventory" {
  write_report ""
  build
  [ "$status" -eq 3 ]
}

@test "nothing to judge: a listed path that is not a regular file" {
  write_report "$(entry .claude/agents/missing.md agent adopter false)"
  build
  [ "$status" -eq 3 ]
}

@test "dispatch runs for a gaia-shipped command, an unknown agent, an adopter skill and a scoped rule" {
  local kind ownership path_scoped rows_run=0
  while read -r kind ownership path_scoped; do
    rm -rf "$OUT"
    mkdir -p "$PROJECT/.claude/x"
    printf 'body\n' >"$PROJECT/.claude/x/$kind.md"
    write_report "$(entry ".claude/x/$kind.md" "$kind" "$ownership" "$path_scoped")"
    build
    [ "$status" -eq 0 ] || return 1
    rows_run=$((rows_run + 1))
  done <<'ROWS'
command gaia-shipped false
agent unknown false
skill adopter false
rule adopter true
ROWS
  [ "$rows_run" -eq 4 ]
}

@test "the input numbers each judged line within its own file" {
  local tab=$'\t'
  small_project
  build
  [ "$status" -eq 0 ]
  run bash -c "cat '$OUT'/part-*.md | grep -E '^ *[0-9]+${tab}(first|second|third) '"
  [ "${#lines[@]}" -eq 5 ]
  [[ "${lines[0]}" =~ ^\ *5${tab}first\ a$ ]]
  [[ "${lines[2]}" =~ ^\ *1${tab}first\ b$ ]]
  [[ "${lines[4]}" =~ ^\ *3${tab}third\ b$ ]]
}

@test "the input also judges a Markdown file that names AskUserQuestion, never a vendored or worktree copy" {
  mkdir -p "$PROJECT/.claude/skills/a" "$PROJECT/.claude/skills/b" "$PROJECT/wiki" "$PROJECT/.claude/skills/vendored" \
    "$PROJECT/.claude/worktrees/other/.claude/skills/c" "$PROJECT/apps/web/.claude/rules"
  printf 'plain\n' >"$PROJECT/.claude/skills/a/SKILL.md"
  printf 'asks via AskUserQuestion\n' >"$PROJECT/.claude/skills/b/SKILL.md"
  printf 'wiki page using AskUserQuestion\n' >"$PROJECT/wiki/page.md"
  printf 'unrelated\n' >"$PROJECT/wiki/other.md"
  printf 'vendored AskUserQuestion\n' >"$PROJECT/.claude/skills/vendored/SKILL.md"
  printf 'sibling worktree AskUserQuestion\n' >"$PROJECT/.claude/worktrees/other/.claude/skills/c/SKILL.md"
  printf 'app rule AskUserQuestion\n' >"$PROJECT/apps/web/.claude/rules/r.md"
  git -C "$PROJECT" add .claude/skills/a .claude/skills/b .claude/skills/vendored apps wiki
  write_report "$(entry .claude/skills/a/SKILL.md skill adopter false),$(entry .claude/skills/vendored/SKILL.md skill third-party false)"
  build
  [ "$status" -eq 0 ]
  run bash -c "cat '$OUT'/part-*.md | grep '^<<<GAIA-FITNESS-FILE-BEGIN ' | sort -u"
  [ "${#lines[@]}" -eq 4 ]
  [ "${lines[0]}" = "<<<GAIA-FITNESS-FILE-BEGIN .claude/skills/a/SKILL.md" ]
  [ "${lines[1]}" = "<<<GAIA-FITNESS-FILE-BEGIN .claude/skills/b/SKILL.md" ]
  [ "${lines[2]}" = "<<<GAIA-FITNESS-FILE-BEGIN apps/web/.claude/rules/r.md" ]
  [ "${lines[3]}" = "<<<GAIA-FITNESS-FILE-BEGIN wiki/page.md" ]
}

@test "the first part is a digest of every skill's frontmatter, and only that" {
  small_project
  build
  [ "$status" -eq 0 ]
  [ "$(jq -r '.groups[0].parts[0].path' "$OUT/manifest.json")" = "$OUT/part-001.md" ]
  grep -q '^This part is the skill-descriptions digest' "$OUT/part-001.md"
  run grep -c '^<<<GAIA-FITNESS-FILE-BEGIN ' "$OUT/part-001.md"
  [ "$output" = "1" ]
  grep -qF 'description: does a' "$OUT/part-001.md"
  grep -qF 'first a' "$OUT/part-001.md" && return 1
  grep -q '^This part is the skill-descriptions digest' "$OUT/part-002.md" && return 1
  true
}

@test "every part fits its budget, ends with its own token, and every judged line appears exactly once" {
  local file line expected actual part budget=600
  mkdir -p "$PROJECT/.claude/agents"
  for file in one two three; do
    for line in $(seq 1 40); do printf '%s line %s\n' "$file" "$line"; done >"$PROJECT/.claude/agents/$file.md"
  done
  git -C "$PROJECT" add .claude
  write_report "$(entry .claude/agents/one.md agent adopter false),$(entry .claude/agents/two.md agent adopter false),$(entry .claude/agents/three.md agent adopter false)"
  build --part-bytes "$budget" --group-bytes 100000
  [ "$status" -eq 0 ]
  [ "$(jq '[.groups[].parts[]] | length' "$OUT/manifest.json")" -gt 3 ]
  while IFS=$'\t' read -r part token; do
    [ "$(LC_ALL=C wc -c <"$part" | tr -d ' ')" -le "$budget" ] || return 1
    [ "$(tail -n 1 "$part")" = "<<<GAIA-FITNESS-PART-END $token" ] || return 1
  done < <(jq -r '.groups[].parts[] | "\(.path)\t\(.token)"' "$OUT/manifest.json")
  [ "$(jq '[.groups[].parts[].token] | unique | length' "$OUT/manifest.json")" = "$(jq '[.groups[].parts[]] | length' "$OUT/manifest.json")" ]
  expected="$(cat "$PROJECT"/.claude/agents/*.md | sort)"
  actual="$(cat "$OUT"/part-*.md | grep -E $'^ *[0-9]+\t' | cut -f2- | sort)"
  [ "$actual" = "$expected" ]
}

@test "a file larger than a part is sliced with its own line numbers, all in one group" {
  local tab=$'\t'
  mkdir -p "$PROJECT/.claude/agents"
  seq 1 200 | sed 's/^/big line /' >"$PROJECT/.claude/agents/big.md"
  printf 'small\n' >"$PROJECT/.claude/agents/small.md"
  git -C "$PROJECT" add .claude
  write_report "$(entry .claude/agents/big.md agent adopter false),$(entry .claude/agents/small.md agent adopter false)"
  build --part-bytes 800 --group-bytes 3000
  [ "$status" -eq 0 ]
  run bash -c "grep -l '^<<<GAIA-FITNESS-FILE-BEGIN .claude/agents/big.md' '$OUT'/part-*.md"
  [ "${#lines[@]}" -gt 1 ]
  run jq -r --arg first "${lines[0]}" --arg last "${lines[${#lines[@]}-1]}" '[.groups[] | select(any(.parts[]; .path == $first or .path == $last)) | .group] | unique | length' "$OUT/manifest.json"
  [ "$output" = "1" ]
  run bash -c "cat '$OUT'/part-*.md | grep -E '^ *200${tab}big line 200$'"
  [ "$status" -eq 0 ]
  [ "$(jq '.groups | length' "$OUT/manifest.json")" -gt 1 ]
}

@test "build refuses a non-empty output folder" {
  small_project
  mkdir -p "$OUT"
  : >"$OUT/stale"
  build
  [ "$status" -eq 2 ]
}

@test "prompt prints one Input line per part, then the Rule line" {
  small_project
  build
  [ "$status" -eq 0 ]
  run bash "$SCRIPT" prompt --manifest "$OUT/manifest.json" --group 1 --rule /abs/user-questions.md
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "Input: $OUT/part-001.md" ]
  [ "${lines[${#lines[@]}-1]}" = "Rule: /abs/user-questions.md" ]
  [ "${#lines[@]}" -eq "$(($(jq '.groups[0].parts | length' "$OUT/manifest.json") + 1))" ]
}

# bats test_tags=protected
@test "collect: an empty array is a no-op, never a clean pass" {
  small_project
  build
  printf '[]\n' >"$OUT/reply-1.json"
  collect
  [ "$status" -eq 1 ]
  [[ "$output" == "no-op group 1: "* ]]
  [ ! -e "$BATS_TEST_TMPDIR/judgment.json" ]
}

@test "collect: an absent reply is a no-op" {
  small_project
  build
  collect
  [ "$status" -eq 1 ]
}

@test "collect: a reply missing one part's receipt is a no-op" {
  small_project
  build
  receipts 1 | jq '.[1:] + [{"judgment":"terminology","file":"a.md","line":3,"message":"m","remediation":"r"}]' >"$OUT/reply-1.json"
  collect
  [ "$status" -eq 1 ]
  [[ "$output" == *"receipts do not match"* ]]
}

@test "collect: a receipt with a wrong token is a no-op" {
  small_project
  build
  receipts 1 | jq '.[0].token = "guessed"' >"$OUT/reply-1.json"
  collect
  [ "$status" -eq 1 ]
}

@test "collect: a could-not-read element is a no-op" {
  small_project
  build
  receipts 1 | jq '. + [{"judgment":"input-unreadable","file":"part","line":1,"message":"too large","remediation":"r"}]' >"$OUT/reply-1.json"
  collect
  [ "$status" -eq 1 ]
  [[ "$output" == *"could not read"* ]]
}

@test "collect: a finding of an unknown judgment or a string line is a no-op" {
  small_project
  build
  receipts 1 | jq '. + [{"judgment":"vibes","file":"a.md","line":3,"message":"m","remediation":"r"}]' >"$OUT/reply-1.json"
  collect
  [ "$status" -eq 1 ]
  receipts 1 | jq '. + [{"judgment":"terminology","file":"a.md","line":"3","message":"m","remediation":"r"}]' >"$OUT/reply-1.json"
  collect
  [ "$status" -eq 1 ]
}

@test "collect: full receipts merge every group's findings with receipts removed" {
  mkdir -p "$PROJECT/.claude/agents"
  seq 1 60 | sed 's/^/a line /' >"$PROJECT/.claude/agents/a.md"
  seq 1 60 | sed 's/^/b line /' >"$PROJECT/.claude/agents/b.md"
  git -C "$PROJECT" add .claude
  write_report "$(entry .claude/agents/a.md agent adopter false),$(entry .claude/agents/b.md agent adopter false)"
  build --part-bytes 1200 --group-bytes 1200
  [ "$status" -eq 0 ]
  [ "$(jq '.groups | length' "$OUT/manifest.json")" -eq 2 ]
  receipts 1 | jq '. + [{"judgment":"recommendation-authority","file":"a.md","line":3,"message":"m","remediation":"r"}]' >"$OUT/reply-1.json"
  receipts 2 >"$OUT/reply-2.json"
  collect
  [ "$status" -eq 0 ]
  [ "$(jq -c 'map(.judgment)' "$BATS_TEST_TMPDIR/judgment.json")" = '["recommendation-authority"]' ]
}
