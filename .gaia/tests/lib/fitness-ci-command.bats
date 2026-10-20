#!/usr/bin/env bats
#
# Runs the fitness lint exactly as the `cli-tests` job in
# .github/workflows/cli-tests.yml runs it, against scratch copies of the
# tracked tree, and proves the job fails on a frontmatter defect, holds when
# the pull request edits its own suppression file, and stays red when the CI
# line loses a flag.
#
# The command line is read out of the workflow, not restated here, so an edit
# to the workflow is what this suite sees. Scratch trees come from the index
# (`git write-tree`), not HEAD, so a gate that stages before it runs bats grades
# the staged state.
#
# Assertion style: .claude/rules/bats-assertions.md.
#
setup_file() {
  local repo_root tree
  repo_root="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  tree="$BATS_FILE_TMPDIR/base"
  mkdir -p "$tree"
  git -C "$repo_root" archive "$(git -C "$repo_root" write-tree)" | tar -x -C "$tree"
  git -C "$tree" init -q
  git -C "$tree" add -A
  git -C "$tree" -c user.email=bats@example.com -c user.name=bats -c commit.gpgsign=false commit -q -m base
  cp "$tree/.claude/gaia-fitness.json" "$BATS_FILE_TMPDIR/base-config.json"
}

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  WORKFLOW="$REPO_ROOT/.github/workflows/cli-tests.yml"
  BASE_CONFIG="$BATS_FILE_TMPDIR/base-config.json"
  TREE="$BATS_TEST_TMPDIR/tree"
  cp -R "$BATS_FILE_TMPDIR/base" "$TREE"
}

# ci_command_line <workflow>: the one line that starts the fitness check.
ci_command_line() {
  local matches count
  matches="$(grep -E '^[[:space:]]*\.gaia/cli/gaia fitness check ' "$1")" || return 1
  count="$(printf '%s\n' "$matches" | wc -l | tr -d ' ')"
  [ "$count" -eq 1 ] || return 1
  printf '%s\n' "$matches"
}

# ci_arguments <workflow>: the line's words after `.gaia/cli/gaia`, with the
# config value and the output redirect removed so the caller supplies them.
ci_arguments() {
  local line
  line="$(ci_command_line "$1")" || return 1
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%% > *}"
  line="${line% --config*}"
  line="${line#.gaia/cli/gaia }"
  printf '%s\n' "$line"
}

# run_ci_lint <workflow> <tree> <config>: the committed bundle with the CI
# line's flags against <tree>, suppressions from <config>.
run_ci_lint() {
  local -a words
  read -r -a words <<<"$(ci_arguments "$1")"
  [ "${#words[@]}" -ge 1 ] || return 1
  "$REPO_ROOT/.gaia/cli/gaia" "${words[@]}" --root "$2" --config "$3"
}

commit_tree() {
  git -C "$TREE" add -A
  git -C "$TREE" -c user.email=bats@example.com -c user.name=bats -c commit.gpgsign=false commit -q -m change
}

@test "the CI line is found once and enforces the frontmatter category and both line caps" {
  line="$(ci_command_line "$WORKFLOW")"
  for flag in '--scope all' '--fail-on error' '--enforce frontmatter' '--enforce authoring.skill.body.max-lines' '--enforce authoring.playbook.max-lines'; do
    grep -qF -- "$flag" <<<"$line" || return 1
  done
}

# bats test_tags=whole-tree
@test "the unmodified tree passes" {
  run run_ci_lint "$WORKFLOW" "$TREE" "$BASE_CONFIG"
  [ "$status" -eq 0 ]
}

# bats test_tags=whole-tree
@test "a skill description past 1024 characters fails and names the file and rule" {
  skill=".claude/skills/tdd/SKILL.md"
  long="$(printf 'x%.0s' $(seq 1 1100))"
  sed -i.bak -E "s|^description: .*|description: ${long}|" "$TREE/$skill"
  rm "$TREE/$skill.bak"
  commit_tree
  run run_ci_lint "$WORKFLOW" "$TREE" "$BASE_CONFIG"
  [ "$status" -ne 0 ]
  grep -qF -- "$skill" <<<"$output" || return 1
  grep -qF -- "frontmatter.skill.description.max-length" <<<"$output" || return 1
}

# bats test_tags=whole-tree
@test "a skill name that gains the reserved word claude fails and names the rule" {
  skill=".claude/skills/tdd/SKILL.md"
  sed -i.bak -E "s|^name: tdd\$|name: claude-tdd|" "$TREE/$skill"
  rm "$TREE/$skill.bak"
  commit_tree
  run run_ci_lint "$WORKFLOW" "$TREE" "$BASE_CONFIG"
  [ "$status" -ne 0 ]
  grep -qF -- "frontmatter.skill.name.reserved-word" <<<"$output" || return 1
}

# bats test_tags=whole-tree
@test "a pull request that suppresses its own violation still fails, because suppressions come from the base" {
  skill=".claude/skills/tdd/SKILL.md"
  long="$(printf 'x%.0s' $(seq 1 1100))"
  sed -i.bak -E "s|^description: .*|description: ${long}|" "$TREE/$skill"
  rm "$TREE/$skill.bak"
  jq --arg path "$skill" '.ignore += [{rule_id: "frontmatter.skill.description.max-length", path: $path, reason: "Suppressed by the change itself."}]' \
    "$TREE/.claude/gaia-fitness.json" >"$TREE/.claude/gaia-fitness.json.new"
  mv "$TREE/.claude/gaia-fitness.json.new" "$TREE/.claude/gaia-fitness.json"
  commit_tree
  run run_ci_lint "$WORKFLOW" "$TREE" "$BASE_CONFIG"
  [ "$status" -ne 0 ]
  grep -qF -- "frontmatter.skill.description.max-length" <<<"$output" || return 1
}

# bats test_tags=whole-tree
@test "red twin: a workflow copy without --enforce frontmatter changes the extracted line and lets the reserved-word case pass" {
  broken="$BATS_TEST_TMPDIR/cli-tests.yml"
  sed 's| --enforce frontmatter||' "$WORKFLOW" >"$broken"
  [ "$(ci_command_line "$broken")" != "$(ci_command_line "$WORKFLOW")" ]
  skill=".claude/skills/tdd/SKILL.md"
  sed -i.bak -E "s|^name: tdd\$|name: claude-tdd|" "$TREE/$skill"
  rm "$TREE/$skill.bak"
  commit_tree
  run run_ci_lint "$broken" "$TREE" "$BASE_CONFIG"
  [ "$status" -eq 0 ]
}

@test "red twin: a workflow with no fitness line fails the extraction" {
  broken="$BATS_TEST_TMPDIR/cli-tests.yml"
  grep -v 'gaia fitness check' "$WORKFLOW" >"$broken"
  run ci_command_line "$broken"
  [ "$status" -ne 0 ]
}

@test "the suppression file is release-excluded" {
  grep -qxF '.claude/gaia-fitness.json' "$REPO_ROOT/.gaia/release-exclude"
}
