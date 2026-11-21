#!/usr/bin/env bats
# Conformance suite for .gaia/scripts/check-retired-paths.sh, the gate that fails
# on a harness citation of a root path that moved under apps/web/.
#
# Every test builds a temporary git repository holding a copy of the gate, so
# the verdict never depends on the real tree's state or on git history. One test
# runs the gate over the real working tree. The failing states (a hit, a stale
# or malformed allowlist row, a tracked retired path, an empty scan set) are
# each driven on their own, and the over-match negatives pin the other
# direction: a gate that flagged `apps/web/app/` would fail every run.
#
# Run under bash 5: `bash .gaia/scripts/bats5.sh .gaia/scripts/tests/check-retired-paths.bats`.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  SCRIPT_DIRECTORY="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  FIXTURES="$BATS_TEST_DIRNAME/fixtures/retired-paths"
}

# make_repo <name>: a git repo under BATS_TEST_TMPDIR holding a copy of the gate
# and one clean scanned hook, so the scan set is never empty by accident.
make_repo() {
  local repo="$BATS_TEST_TMPDIR/$1"
  mkdir -p "$repo/.gaia/scripts" "$repo/.claude/hooks"
  git -C "$repo" init -q
  cp "$SCRIPT_DIRECTORY/check-retired-paths.sh" "$repo/.gaia/scripts/check-retired-paths.sh"
  printf '#!/usr/bin/env bash\necho ok\n' >"$repo/.claude/hooks/ok.sh"
  printf '%s' "$repo"
}

# stage_all <repo>: track every file so the gate's git ls-files sees it.
stage_all() {
  git -C "$1" add -A
}

run_gate() {
  run bash "$1/.gaia/scripts/check-retired-paths.sh" "${@:2}"
}
# reset_repo <name>: empties a table's repo down to the gate copy and the clean
# hook, so one repository serves every case of a table.
reset_repo() {
  find "$BATS_TEST_TMPDIR/$1" -mindepth 1 -maxdepth 1 -not -name .git -exec rm -rf {} +
  make_repo "$1" >/dev/null
}

# gate_case <label> <repo> <expected status>: stages the repo, runs the gate and
# checks its status. The label names the failing case in every assertion below.
gate_case() {
  CASE_LABEL="$1"
  stage_all "$2"
  run_gate "$2"
  [ "$status" -eq "$3" ] || { echo "case $CASE_LABEL: status $status, wanted $3"; return 1; }
}

# case_has <needle>: the last run's output holds the needle.
case_has() {
  grep -qF -- "$1" <<<"$output" || { echo "case $CASE_LABEL: output lacks '$1'"; return 1; }
}

# case_has_line <line>: the last run's output holds the line whole.
case_has_line() {
  grep -qxF -- "$1" <<<"$output" || { echo "case $CASE_LABEL: output lacks the line '$1'"; return 1; }
}

# case_lacks <needle>: the last run's output does not hold the needle.
case_lacks() {
  grep -qF -- "$1" <<<"$output" && { echo "case $CASE_LABEL: output holds '$1'"; return 1; }
  return 0
}

@test "a harness citation of a retired path fails naming file and line" {
  local repo name
  repo="$(make_repo hits)"

  cp "$FIXTURES/hook-cites-root-app.txt" "$repo/.claude/hooks/x.sh"
  gate_case "root app/ in a hook" "$repo" 1
  case_has 'RETIRED .claude/hooks/x.sh:2: source_file="app/routes.ts"' || return 1

  reset_repo hits
  mkdir -p "$repo/.gaia/cli/templates/route"
  cp "$FIXTURES/hook-cites-root-app.txt" "$repo/.gaia/cli/templates/route/x.ts.tmpl"
  gate_case "scaffold template" "$repo" 1
  case_has 'RETIRED .gaia/cli/templates/route/x.ts.tmpl:2: source_file="app/routes.ts"' || return 1

  reset_repo hits
  mkdir -p "$repo/.claude/commands"
  cp "$FIXTURES/command-cites-moved-instruction.md" "$repo/.claude/commands/x.md"
  gate_case "moved .claude unit" "$repo" 1
  case_has 'RETIRED .claude/commands/x.md:3:' || return 1

  reset_repo hits
  mkdir -p "$repo/.claude/commands"
  printf 'run .gaia/scripts/overlap-check.sh now\n' >"$repo/.claude/hooks/a.sh"
  printf 'see .gaia/scripts/overlap/citations.mjs\n' >"$repo/.claude/hooks/b.sh"
  printf 'dispatch .claude/agents/overlap-evaluator.md\n' >"$repo/.claude/commands/c.md"
  printf 'an overlap of two tests, see .gaia/scripts/spec/page-use.mjs\n' >"$repo/.claude/commands/d.md"
  printf 'read .claude/skills/gaia/references/overlap-pass.md first\n' >"$repo/.claude/commands/e.md"
  gate_case "retired overlap-pass paths" "$repo" 1
  case_has 'RETIRED .claude/hooks/a.sh:1:' || return 1
  case_has 'RETIRED .claude/hooks/b.sh:1:' || return 1
  case_has 'RETIRED .claude/commands/c.md:1:' || return 1
  case_has 'RETIRED .claude/commands/e.md:1:' || return 1
  case_lacks '.claude/commands/d.md' || return 1

  reset_repo hits
  mkdir -p "$repo/.claude/skills/demo"
  printf '%s\n' '# Demo' 'Read .claude/skills/gaia/references/plan/test-table.md first.' >"$repo/.claude/skills/demo/SKILL.md"
  gate_case "retired test-design file in a skill" "$repo" 1
  case_has 'RETIRED .claude/skills/demo/SKILL.md:2:' || return 1

  reset_repo hits
  mkdir -p "$repo/.claude/skills/demo" "$repo/.claude/commands"
  printf '%s\n' '# Demo' 'Read .claude/skills/gaia/references/spec/lens-dispatch.md first.' >"$repo/.claude/skills/demo/SKILL.md"
  printf '%s\n' 'run .claude/skills/gaia/references/drift-check.md' >"$repo/.claude/commands/a.md"
  printf '%s\n' 'dispatch the test-honesty-checker agent' >"$repo/.claude/commands/b.md"
  printf '%s\n' 'run .gaia/scripts/test-design/existing-tests.mjs' >"$repo/.claude/commands/c.md"
  printf '%s\n' 'run .gaia/scripts/spec/requirement-keys.sh' >"$repo/.claude/commands/d.md"
  printf '%s\n' 'read .claude/skills/gaia/references/spec/self-review-dispatch.md' >"$repo/.claude/commands/e.md"
  printf '%s\n' 'run .claude/hooks/test-row-grant.sh and .claude/hooks/test-design-merge-gate.sh and .gaia/scripts/test-drift-check.sh' >"$repo/.claude/commands/f.md"
  gate_case "retired test-design files in commands" "$repo" 1
  case_lacks 'SKILL.md' || return 1
  for name in a b c d e f; do
    case_has "RETIRED .claude/commands/$name.md:1:" || return 1
  done

  reset_repo hits
  printf '%s\n' '#!/usr/bin/env bash' 'rows="$(jq . "$plan_directory/tests.json")"' >"$repo/.claude/hooks/x.sh"
  printf '%s\n' '#!/usr/bin/env bash' 'cmp "$plan_directory/tests.approved.json" "$other"' >"$repo/.claude/hooks/y.sh"
  printf '%s\n' '#!/usr/bin/env bash' 'tail "$plan_directory/security-tests.jsonl"' >"$repo/.claude/hooks/z.sh"
  printf '%s\n' '{"hooks":[{"command":"$CLAUDE_PROJECT_DIR/.claude/hooks/test-row-grant.sh"}]}' >"$repo/.claude/settings.json"
  gate_case "kept script reading the retired test table" "$repo" 1
  case_has 'RETIRED .claude/hooks/x.sh:2:' || return 1
  case_has 'RETIRED .claude/hooks/y.sh:2:' || return 1
  case_has 'RETIRED .claude/settings.json:1:' || return 1
  case_lacks '.claude/hooks/z.sh' || return 1

  reset_repo hits
  mkdir -p "$repo/.claude/skills/demo"
  printf '%s\n' '# Demo' '* edit app/x.ts first' >"$repo/.claude/skills/demo/SKILL.md"
  gate_case "Markdown bullet line" "$repo" 1
  case_has 'RETIRED .claude/skills/demo/SKILL.md:2:' || return 1
}

@test "an over-match negative stays clean and its near-miss is still reported" {
  local repo
  repo="$(make_repo negatives)"

  cp "$FIXTURES/over-match-negatives.txt" "$repo/.claude/hooks/x.sh"
  gate_case "citation under apps/web" "$repo" 0
  case_has "check-retired-paths: clean" || return 1

  reset_repo negatives
  mkdir -p "$repo/.gaia/cli/src"
  printf '%s\n' "import preview from '#.storybook/preview';" >"$repo/.gaia/cli/src/x.ts"
  printf '%s\n' "const main = '.storybook/main.ts';" >"$repo/.gaia/cli/src/y.ts"
  gate_case "package imports subpath" "$repo" 1
  case_lacks 'RETIRED .gaia/cli/src/x.ts' || return 1
  case_has "RETIRED .gaia/cli/src/y.ts:1: const main = '.storybook/main.ts';" || return 1

  reset_repo negatives
  printf '%s\n' '#!/usr/bin/env bash' '# the app/ layout is package-relative' >"$repo/.claude/hooks/x.sh"
  gate_case "comment-only line" "$repo" 0
  printf '%s\n' '#!/usr/bin/env bash' 'target=app/x.ts # trailing' >"$repo/.claude/hooks/x.sh"
  gate_case "trailing comment" "$repo" 1
  case_has 'RETIRED .claude/hooks/x.sh:2:' || return 1

  reset_repo negatives
  mkdir -p "$repo/.claude/rules"
  printf '%s\n' '---' 'paths:' '  - "apps/web/app/**"' '---' 'Prose about app/x.ts in the body.' >"$repo/.claude/rules/r.md"
  gate_case "rule body prose" "$repo" 0
  printf '%s\n' '---' 'paths:' '  - "app/**"' '---' 'Body.' >"$repo/.claude/rules/r.md"
  gate_case "rule frontmatter paths" "$repo" 1
  case_has 'RETIRED .claude/rules/r.md:3:' || return 1

  reset_repo negatives
  mkdir -p "$repo/.gaia/scripts/tests/fixtures" "$repo/apps/web/.claude/hooks"
  cp "$FIXTURES/hook-cites-root-app.txt" "$repo/.gaia/scripts/tests/fixtures/x.sh"
  cp "$FIXTURES/hook-cites-root-app.txt" "$repo/.gaia/scripts/tests/y.sh"
  cp "$FIXTURES/hook-cites-root-app.txt" "$repo/apps/web/.claude/hooks/z.sh"
  gate_case "tests, fixtures and package-relative harness" "$repo" 0
}

@test "an allowlist row allows its own hit only" {
  local repo
  repo="$(make_repo allowlist)"

  mkdir -p "$repo/.gaia/cli/templates/route"
  cp "$FIXTURES/hook-cites-root-app.txt" "$repo/.gaia/cli/templates/route/x.ts.tmpl"
  printf '.gaia/cli/templates/route/x.ts.tmpl\tapp/routes.ts\tgenerated-package-relative\n' >"$repo/.gaia/retired-paths-allowlist.tsv"
  gate_case "row for a scaffold template" "$repo" 0

  reset_repo allowlist
  cp "$FIXTURES/hook-cites-root-app.txt" "$repo/.claude/hooks/x.sh"
  printf '.claude/hooks/x.sh\tapp/routes.ts\tpackage-relative default\n' >"$repo/.gaia/retired-paths-allowlist.tsv"
  gate_case "row with a matching file and needle" "$repo" 0

  reset_repo allowlist
  cp "$FIXTURES/hook-cites-root-app.txt" "$repo/.claude/hooks/x.sh"
  printf '.claude/hooks/ok.sh\tapp/routes.ts\treason\n' >"$repo/.gaia/retired-paths-allowlist.tsv"
  gate_case "row for a different file" "$repo" 1
  case_has 'RETIRED .claude/hooks/x.sh:2:' || return 1
  case_has 'STALE-ALLOW .claude/hooks/ok.sh app/routes.ts' || return 1
}

@test "a stale or malformed allowlist row fails the gate" {
  local repo
  repo="$(make_repo bad-allowlist)"

  printf '.claude/hooks/ok.sh\tapp/gone.ts\ta citation that no longer exists\n' >"$repo/.gaia/retired-paths-allowlist.tsv"
  gate_case "stale row" "$repo" 1
  case_has 'STALE-ALLOW .claude/hooks/ok.sh app/gone.ts' || return 1

  reset_repo bad-allowlist
  cp "$FIXTURES/hook-cites-root-app.txt" "$repo/.claude/hooks/x.sh"
  printf '.claude/hooks/x.sh\tapp/routes.ts\t\n' >"$repo/.gaia/retired-paths-allowlist.tsv"
  gate_case "row with an empty reason" "$repo" 1
  case_has 'BAD-ALLOW 1:' || return 1

  reset_repo bad-allowlist
  cp "$FIXTURES/hook-cites-root-app.txt" "$repo/.claude/hooks/x.sh"
  printf '.claude/hooks/x.sh\tapp/routes.ts\n' >"$repo/.gaia/retired-paths-allowlist.tsv"
  gate_case "row with no reason column" "$repo" 1
  case_has 'BAD-ALLOW 1:' || return 1
}

@test "a tracked retired path fails with TRACKED" {
  local repo
  repo="$(make_repo tracked)"

  mkdir -p "$repo/app"
  printf 'export {};\n' >"$repo/app/x.ts"
  gate_case "root app/ file" "$repo" 1
  case_has_line 'TRACKED app/x.ts' || return 1

  reset_repo tracked
  mkdir -p "$repo/.claude/skills/tailwind"
  printf '{}\n' >"$repo/tsconfig.json"
  printf 'x\n' >"$repo/.claude/skills/tailwind/SKILL.md"
  gate_case "moved root config file and moved unit" "$repo" 1
  case_has_line 'TRACKED tsconfig.json' || return 1
  case_has_line 'TRACKED .claude/skills/tailwind/SKILL.md' || return 1

  reset_repo tracked
  mkdir -p "$repo/apps/web/.claude/skills/typescript"
  printf 'x\n' >"$repo/apps/web/.claude/skills/typescript/SKILL.md"
  gate_case "retired web typescript skill" "$repo" 1
  case_has_line 'TRACKED apps/web/.claude/skills/typescript/SKILL.md' || return 1
}

@test "a tracked file under apps/web/ and an untracked root app/ file do not trip TRACKED" {
  local repo
  repo="$(make_repo tracked-negative)"
  mkdir -p "$repo/apps/web/app" "$repo/app"
  printf 'export {};\n' >"$repo/apps/web/app/x.ts"
  printf '{}\n' >"$repo/.gaia/packages-sample.json"
  stage_all "$repo"
  printf 'export {};\n' >"$repo/app/untracked.ts"
  run_gate "$repo"
  [ "$status" -eq 0 ]
}


@test "an unscannable input exits 2 and never reports clean" {
  local repo="$BATS_TEST_TMPDIR/empty" plain="$BATS_TEST_TMPDIR/plain"
  mkdir -p "$repo/.gaia/scripts" "$repo/docs"
  git -C "$repo" init -q
  cp "$SCRIPT_DIRECTORY/check-retired-paths.sh" "$repo/.gaia/scripts/check-retired-paths.sh"
  printf 'note\n' >"$repo/docs/a.txt"
  stage_all "$repo"
  run bash "$repo/.gaia/scripts/check-retired-paths.sh" --root "$repo"
  [ "$status" -eq 2 ] || { echo "empty scan set: status $status"; return 1; }
  grep -qF -- "the scan set is empty" <<<"$output" || { echo "empty scan set: no refusal message"; return 1; }
  grep -qF -- "clean" <<<"$output" && { echo "empty scan set: reported clean"; return 1; }

  mkdir -p "$plain/.claude/hooks"
  printf 'echo ok\n' >"$plain/.claude/hooks/ok.sh"
  run bash "$SCRIPT_DIRECTORY/check-retired-paths.sh" --root "$plain"
  [ "$status" -eq 2 ] || { echo "not a git repository: status $status"; return 1; }
}
