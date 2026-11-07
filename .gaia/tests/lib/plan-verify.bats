#!/usr/bin/env bats
#
# .gaia/scripts/spec/plan-verify.sh behavior: existence checks, the orchestrator
# step sentinels (match rule, order rule, per-arm requirements), the verbatim
# blocks (resume detection, yield handling, gate retry, flow checks, worthiness
# step, overlap pass, wiki promotion, code audit and post-clearance), failure
# aggregation, placeholder scanning, and the flow checks of a spec-derived plan
# (the flow-test task line, the task-stem-to-phase rule, the closing-phase
# entry that runs each flow test). Shell level only.
#
# Assertion style follows .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT_REAL="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SCRIPT="$REPO_ROOT_REAL/.gaia/scripts/spec/plan-verify.sh"
  PLAN="$BATS_TEST_TMPDIR/plan"
  SPEC="$BATS_TEST_TMPDIR/SPEC.md"
  PLANNER_MD="$REPO_ROOT_REAL/.claude/skills/gaia/references/plan/planner.md"
  mkdir -p "$PLAN"
  S_RESUME='<!-- gaia:orchestrator-step resume-detection -->'
  S_YIELD='<!-- gaia:orchestrator-step yield-handling -->'
  S_RETRY='<!-- gaia:orchestrator-step gate-retry -->'
  S_FLOW='<!-- gaia:orchestrator-step flow-checks -->'
  S_WORTH='<!-- gaia:orchestrator-step worthiness-step -->'
  S_OVERLAP='<!-- gaia:orchestrator-step overlap-pass -->'
  S_WIKI='<!-- gaia:orchestrator-step wiki-promotion -->'
  S_AUDIT='<!-- gaia:orchestrator-step code-audit -->'
  S_CLEAR='<!-- gaia:orchestrator-step post-clearance -->'
  S_CLOSE='<!-- gaia:orchestrator-step post-merge-close -->'
  SPEC_ORDER=("$S_RESUME" "$S_YIELD" "$S_RETRY" "$S_FLOW" "$S_WORTH" "$S_OVERLAP" "$S_WIKI" "$S_AUDIT" "$S_CLEAR" "$S_CLOSE")
  SPEC_LESS_ORDER=("$S_RESUME" "$S_YIELD" "$S_RETRY" "$S_WORTH" "$S_OVERLAP" "$S_WIKI" "$S_AUDIT" "$S_CLEAR" "$S_CLOSE")
  WEB_TEST_PATH='apps/web/.playwright/flows/guest-checkout.spec.ts'
  COMMAND_TEST_PATH='.gaia/tests/lib/refuse-uats-spec.bats'
  WEB_RUN_LINE='pnpm -C apps/web exec playwright test .playwright/flows/guest-checkout.spec.ts'
  COMMAND_RUN_LINE='bash .gaia/scripts/bats5.sh .gaia/tests/lib/refuse-uats-spec.bats < /dev/null'
  FLOW_RUN_LINES=''
}

# write_flow_spec [<extra frontmatter line>]: a two-flow SPEC, one web flow and
# one command flow.
write_flow_spec() {
  cat >"$SPEC" <<EOF2
---
spec_id: SPEC-901
${1:-}
flows:
  - flow_id: FLOW-901
    slug: guest-checkout
    name: A guest checks out and sees the order number
    why: Checkout is the main revenue path
    covers: [app/pages/checkout]
  - flow_id: FLOW-902
    slug: refuse-uats-spec
    name: The plan check refuses a SPEC that still carries uats
    why: A silent pass would plan a SPEC no gate can check
    test_path: $COMMAND_TEST_PATH
---

# Sample
EOF2
}

# phase_rows <n>...: README task-graph rows naming these phases (default 1).
phase_rows() {
  local phase
  for phase in "${@:-1}"; do
    printf '| Phase %s | `task-one` | sonnet | none |\n' "$phase"
  done
}

# flow_readme: a README whose Phase 1 row names the build task and whose Phase
# 2 row (the last phase) names the two flow tasks.
flow_readme() {
  cat >"$PLAN/README.md" <<'EOF2'
# Plan

| Phase | Tasks | Model | Split |
|---|---|---|---|
| Phase 1 | `task-build` | sonnet | none |
| Phase 2 | `task-flow-web`, `task-flow-command` | sonnet | none |
EOF2
}

# block_of <sentinel> [<indent>]: the block that sentinel opens, as the planner
# file in BLOCK_SOURCE (default planner.md) holds it, re-indented to <indent>
# spaces, with the plan-directory and SPEC-path placeholders replaced by this
# fixture's values.
block_of() {
  local want="$1" indent="${2:-0}" pad block
  pad="$(printf '%*s' "$indent" '')"
  block="$(awk -v want="$want" -v pad="$pad" '
    { t = $0; sub(/^[ \t]+/, "", t); sub(/[ \t\r]+$/, "", t) }
    t ~ /^```/ {
      if (in_fence) { if (hit) { printf "%s", buffer; exit } in_fence = 0 }
      else { in_fence = 1; buffer = ""; hit = 0 }
      next
    }
    in_fence {
      if (t == want) hit = 1
      line = $0
      sub(/^ {6}/, "", line)
      buffer = buffer (line == "" ? "" : pad line) "\n"
    }' "${BLOCK_SOURCE:-$PLANNER_MD}")"
  [ -n "$block" ] || return 1
  block="${block//\{PLAN_DIR\}/$PLAN}"
  printf '%s\n' "${block//\{SPEC_PATH\}/$SPEC}"
}

yield_block() {
  block_of "$S_YIELD" "${1:-0}"
}

# is_verbatim <sentinel>: the sentinels whose whole block is copied.
is_verbatim() {
  case "$1" in
    "$S_RESUME" | "$S_YIELD" | "$S_RETRY" | "$S_FLOW" | "$S_WORTH" | "$S_OVERLAP" | "$S_WIKI" | "$S_AUDIT" | "$S_CLEAR") return 0 ;;
  esac
  return 1
}

# write_orchestrator <sentinel>...: ORCHESTRATOR.md with these lines in this
# order; a verbatim sentinel stands for the whole copied block. One phase entry
# per README phase row comes first, outside every block; the last phase's entry
# holds FLOW_RUN_LINES, and a heading closes it before the blocks.
write_orchestrator() {
  local entry phase last_phase run_line
  last_phase="$(sed -nE 's/^[|][[:space:]]*Phase[[:space:]]+([0-9]+).*/\1/p' "$PLAN/README.md" 2>/dev/null | sort -n | tail -n 1)"
  {
    printf '# Orchestrator\n\n'
    for phase in $(sed -nE 's/^[|][[:space:]]*Phase[[:space:]]+([0-9]+).*/\1/p' "$PLAN/README.md" 2>/dev/null | grep . || echo 1); do
      printf '**Phase %s, x.**\n' "$phase"
      if [ "$phase" = "${last_phase:-1}" ] && [ -n "$FLOW_RUN_LINES" ]; then
        while IFS= read -r run_line; do
          printf 'Gate: %s\n' "$run_line"
        done <<<"$FLOW_RUN_LINES"
      fi
      printf '\n'
    done
    printf '## Steps\n\n'
    for entry in "$@"; do
      if is_verbatim "$entry"; then
        block_of "$entry" 0 || return 1
      else
        printf '%s\n' "$entry"
      fi
      printf '\nprose between steps\n\n'
    done
  } >"$PLAN/ORCHESTRATOR.md"
}

write_task() {
  printf '# Task\n\n%s\n' "$1" >"$PLAN/task-one.md"
}

# spec_fixture: a passing spec-derived plan folder with two flows.
spec_fixture() {
  write_flow_spec
  flow_readme
  rm -f "$PLAN"/task-*.md
  FLOW_RUN_LINES="$WEB_RUN_LINE"$'\n'"$COMMAND_RUN_LINE"
  write_orchestrator "${SPEC_ORDER[@]}"
  printf '# Kickoff\n' >"$PLAN/KICKOFF.md"
  printf '# Build\n\n- builds the pages\n' >"$PLAN/task-build.md"
  printf '# Web flow\n\n- Flow test (FLOW-901): %s\n' "$WEB_TEST_PATH" >"$PLAN/task-flow-web.md"
  printf '# Command flow\n\n- Flow test (FLOW-902): %s\n' "$COMMAND_TEST_PATH" >"$PLAN/task-flow-command.md"
}

# spec_less_fixture: a passing spec-less plan folder.
spec_less_fixture() {
  { printf '# Plan\n\n'; phase_rows 1; } >"$PLAN/README.md"
  rm -f "$PLAN"/task-*.md
  FLOW_RUN_LINES=''
  write_orchestrator "${SPEC_LESS_ORDER[@]}"
  printf '# Kickoff\n' >"$PLAN/KICKOFF.md"
  write_task '- nothing'
}

# same_set <expected-newline-list> <name>...: the names form exactly the set.
same_set() {
  local expected="$1" actual
  shift
  [ -n "$expected" ] || { echo 'derived an empty sentinel set' >&2; return 1; }
  actual="$(printf '%s\n' "$@" | sort)"
  [ "$actual" = "$(printf '%s\n' "$expected" | sort)" ] || { printf 'fixture order differs from plan-verify.sh:\n%s\n---\n%s\n' "$actual" "$expected" >&2; return 1; }
}

# script_sentinels: every sentinel plan-verify.sh requires of a spec-derived
# plan; script_spec_less_sentinels: the same without the flow-checks sentinel.
script_sentinels() {
  awk '/^sentinels=\(/,/^verbatim_sentinels=/' "$SCRIPT" | grep -oE "'<!-- gaia:orchestrator-step [a-z-]+ -->'" | tr -d "'" | awk '!seen[$0]++'
}
script_spec_less_sentinels() {
  script_sentinels | grep -vxF -e "$S_FLOW"
}

verify_spec() {
  run bash "$SCRIPT" "$PLAN" --spec "$SPEC"
}

verify_spec_less() {
  run bash "$SCRIPT" "$PLAN"
}

# refusal_line <fragment>...: some line of the last run's output holds every
# fragment, and no line asks for a New tests line (a requirement the script no
# longer has, whose complaint would otherwise name any task doc).
refusal_line() {
  local line fragment all_present
  case "$output" in
    *'New tests'*)
      printf 'the output still asks for a New tests line:\n%s\n' "$output" >&2
      return 1
      ;;
  esac
  while IFS= read -r line; do
    all_present=1
    for fragment in "$@"; do
      case "$line" in
        *"$fragment"*) ;;
        *) all_present=0 ;;
      esac
    done
    [ "$all_present" -eq 0 ] || return 0
  done <<<"$output"
  printf 'no output line holds: %s\n--- output:\n%s\n' "$*" "$output" >&2
  return 1
}

# copy_script_tree <root>: a tree holding plan-verify.sh and the libraries and
# registry it reads, so a case can give it its own planner.md.
copy_script_tree() {
  local relative
  mkdir -p "$1/.gaia/scripts/spec" "$1/.claude/skills/gaia/references/plan" "$1/.claude/hooks/lib" "$1/apps/web"
  for relative in .gaia/scripts/spec/plan-verify.sh .gaia/scripts/spec/flows-lib.sh .gaia/scripts/machine-local-ref-lib.sh .claude/hooks/lib/gaia-packages.sh .gaia/packages.json apps/web/gaia.package.json; do
    cp "$REPO_ROOT_REAL/$relative" "$1/$relative"
  done
}

@test "a complete spec-derived plan passes" {
  spec_fixture
  verify_spec
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
}

@test "a complete spec-less plan passes" {
  spec_less_fixture
  verify_spec_less
  [ "$status" -eq 0 ]
}

@test "a spec-less plan with no New tests line anywhere passes" {
  spec_less_fixture
  printf '# Task\n\n- builds the page\n' >"$PLAN/task-one.md"
  grep -rqF 'New tests' "$PLAN" && return 1
  verify_spec_less
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
}

@test "usage errors exit 2" {
  run bash "$SCRIPT"
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" "$BATS_TEST_TMPDIR/no-such-folder"
  [ "$status" -eq 2 ]
  spec_less_fixture
  run bash "$SCRIPT" "$PLAN" --spec "$BATS_TEST_TMPDIR/no-such-spec.md"
  [ "$status" -eq 2 ]
}

@test "a task doc name ending in -tests fails naming it" {
  spec_less_fixture
  printf '# Task\n' >"$PLAN/task-one-tests.md"
  verify_spec_less
  [ "$status" -eq 1 ]
  refusal_line 'task-one-tests.md'
}

@test "a task doc name outside the task name pattern fails naming it" {
  spec_less_fixture
  printf '# Task\n' >"$PLAN/task-Bad_Name.md"
  verify_spec_less
  [ "$status" -eq 1 ]
  refusal_line 'task-Bad_Name.md'
}

@test "each spec-derived sentinel is required and a missing one is named alone" {
  local literal
  same_set "$(script_sentinels)" "${SPEC_ORDER[@]}"
  for literal in "${SPEC_ORDER[@]}"; do
    spec_fixture
    grep -vxF -- "$literal" "$PLAN/ORCHESTRATOR.md" >"$PLAN/ORCHESTRATOR.md.new"
    mv "$PLAN/ORCHESTRATOR.md.new" "$PLAN/ORCHESTRATOR.md"
    verify_spec
    [ "$status" -eq 1 ] || return 1
    echo "$output" | grep -qF -- "$literal" || return 1
    [ "$(echo "$output" | grep -c 'sentinel')" -eq 1 ] || return 1
  done
}

@test "a spec-less plan does not require flow-checks but requires every other sentinel" {
  local literal
  spec_less_fixture
  verify_spec_less
  [ "$status" -eq 0 ]
  same_set "$(script_spec_less_sentinels)" "${SPEC_LESS_ORDER[@]}"
  for literal in "${SPEC_LESS_ORDER[@]}"; do
    spec_less_fixture
    grep -vxF -- "$literal" "$PLAN/ORCHESTRATOR.md" >"$PLAN/ORCHESTRATOR.md.new"
    mv "$PLAN/ORCHESTRATOR.md.new" "$PLAN/ORCHESTRATOR.md"
    verify_spec_less
    [ "$status" -eq 1 ] || return 1
    echo "$output" | grep -qF -- "$literal" || return 1
  done
}

@test "a spec-derived plan missing the flow-checks sentinel fails naming it" {
  spec_fixture
  grep -vxF -- "$S_FLOW" "$PLAN/ORCHESTRATOR.md" >"$PLAN/ORCHESTRATOR.md.new"
  mv "$PLAN/ORCHESTRATOR.md.new" "$PLAN/ORCHESTRATOR.md"
  verify_spec
  [ "$status" -eq 1 ]
  refusal_line 'missing the sentinel line' "$S_FLOW"
}

@test "flow-checks placed before gate-retry is out of order and named" {
  spec_fixture
  write_orchestrator "$S_RESUME" "$S_YIELD" "$S_FLOW" "$S_RETRY" "$S_WORTH" "$S_OVERLAP" "$S_WIKI" "$S_AUDIT" "$S_CLEAR" "$S_CLOSE"
  verify_spec
  [ "$status" -eq 1 ]
  refusal_line 'out of order' "$S_RETRY"
}

@test "a paraphrased flow-checks block fails naming the block" {
  local line
  spec_fixture
  awk -v flow="$S_FLOW" '
    { t = $0; sub(/^[ \t]+/, "", t); sub(/[ \t\r]+$/, "", t) }
    t == flow { inside = 1 }
    inside && !done && index($0, "flow-coverage.sh") > 0 { sub(/flow-coverage\.sh/, "flow-coverage-check.sh"); done = 1 }
    { print }' "$PLAN/ORCHESTRATOR.md" >"$PLAN/ORCHESTRATOR.md.new"
  mv "$PLAN/ORCHESTRATOR.md.new" "$PLAN/ORCHESTRATOR.md"
  line="$(grep -nF -m1 -- 'flow-coverage-check.sh' "$PLAN/ORCHESTRATOR.md" | cut -d: -f1)"
  [ -n "$line" ] || { echo 'the flow-checks block holds no flow-coverage.sh line' >&2; return 1; }
  verify_spec
  [ "$status" -eq 1 ]
  refusal_line "ORCHESTRATOR.md:$line:" 'the flow-checks block does not match planner.md'
}

# build_indented_orchestrator <spec|spec_less> <indent>: ORCHESTRATOR.md with
# every verbatim block re-indented as a planner indents it and the close
# sentinel indented with a trailing tab.
build_indented_orchestrator() {
  local arm="$1" indent="$2" pad entry
  local -a order
  pad="$(printf '%*s' "$indent" '')"
  if [ "$arm" = spec ]; then order=("${SPEC_ORDER[@]}"); else order=("${SPEC_LESS_ORDER[@]}"); fi
  {
    printf '# Orchestrator\n\n**Phase 1, x.**\n**Phase 2, x.**\n'
    if [ "$arm" = spec ]; then printf 'Gate: %s\nGate: %s\n' "$WEB_RUN_LINE" "$COMMAND_RUN_LINE"; fi
    printf '\n## Steps\n\n'
    for entry in "${order[@]}"; do
      if is_verbatim "$entry"; then
        block_of "$entry" "$indent"
      else
        printf '%s%s\t\n' "$pad" "$entry"
      fi
      printf '\n'
    done
  } >"$PLAN/ORCHESTRATOR.md"
}

@test "indented sentinels, blocks copied as a planner indents them and a trailing tab still match, with and without the spec" {
  spec_fixture
  build_indented_orchestrator spec 6
  grep -qE '^      <!-- gaia:orchestrator-step yield-handling -->$' "$PLAN/ORCHESTRATOR.md"
  verify_spec
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  spec_less_fixture
  build_indented_orchestrator spec_less 6
  verify_spec_less
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
}

@test "a sentinel line carrying trailing prose does not match" {
  spec_fixture
  write_orchestrator "$S_RESUME" "$S_YIELD" "$S_RETRY" "$S_FLOW" "$S_WORTH" "$S_OVERLAP" "$S_WIKI" "$S_AUDIT" "$S_CLEAR" "$S_CLOSE see below"
  verify_spec
  [ "$status" -eq 1 ]
  echo "$output" | grep -qF -- "$S_CLOSE"
}

@test "a spec-less plan with the close sentinel above the promotion sentinel fails" {
  spec_less_fixture
  write_orchestrator "$S_RESUME" "$S_YIELD" "$S_RETRY" "$S_WORTH" "$S_OVERLAP" "$S_CLOSE" "$S_WIKI" "$S_AUDIT" "$S_CLEAR"
  verify_spec_less
  [ "$status" -eq 1 ]
  echo "$output" | grep -qF 'out of order'
}

@test "a missing KICKOFF.md fails naming it" {
  spec_less_fixture
  rm "$PLAN/KICKOFF.md"
  verify_spec_less
  [ "$status" -eq 1 ]
  echo "$output" | grep -qF 'KICKOFF.md'
}

@test "a plan with no task doc fails naming the task files" {
  spec_less_fixture
  rm "$PLAN/task-one.md"
  verify_spec_less
  [ "$status" -eq 1 ]
  echo "$output" | grep -qF 'task-*.md'
}

@test "every failure is reported in one run" {
  spec_less_fixture
  rm "$PLAN/KICKOFF.md" "$PLAN/task-one.md"
  verify_spec_less
  [ "$status" -eq 1 ]
  echo "$output" | grep -qF 'KICKOFF.md'
  echo "$output" | grep -qF 'task-*.md'
}

# The planner substitutes the absolute values for these tokens in every file it
# writes; a surviving token sends a cold orchestrator to a literal brace path.
@test "an unsubstituted placeholder in any generated plan file fails naming the file and token" {
  local token file
  for file in ORCHESTRATOR.md KICKOFF.md README.md task-one.md; do
    for token in '{PLAN_DIR}' '{SPEC_PATH}' '{AUDIT_PATH}'; do
      rm -rf "$PLAN"
      mkdir -p "$PLAN"
      spec_less_fixture
      printf 'Read %s/README.md first.\n' "$token" >>"$PLAN/$file"
      verify_spec_less
      [ "$status" -eq 1 ] || { echo "$file with $token exited $status" >&2; return 1; }
      echo "$output" | grep -F -- "$file" | grep -qF -- "$token" || { echo "no line names $file and $token: $output" >&2; return 1; }
    done
  done
}

@test "a placeholder in the spec-derived arm fails the same way" {
  spec_fixture
  printf 'run the check on {SPEC_PATH}\n' >>"$PLAN/ORCHESTRATOR.md"
  verify_spec
  [ "$status" -eq 1 ]
  echo "$output" | grep -F 'ORCHESTRATOR.md' | grep -qF '{SPEC_PATH}'
}

@test "every surviving placeholder is reported, one line each" {
  spec_less_fixture
  printf '{PLAN_DIR}\n{AUDIT_PATH}\n' >>"$PLAN/KICKOFF.md"
  verify_spec_less
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | grep -c 'unsubstituted')" -eq 2 ]
}

@test "a placeholder in a file the planner does not generate is not scanned" {
  spec_less_fixture
  mkdir -p "$PLAN/audit"
  printf '{PLAN_DIR}\n' >"$PLAN/PROGRESS.md"
  printf '{PLAN_DIR}\n' >"$PLAN/audit/DP.json"
  verify_spec_less
  [ "$status" -eq 0 ]
}

# ---------- the yield-handling block is checked verbatim ----------

# Rewrite the fixture's ORCHESTRATOR.md through an awk program, in place.
mutate_orchestrator() {
  awk -v plan="$PLAN" "$1" "$PLAN/ORCHESTRATOR.md" >"$PLAN/ORCHESTRATOR.md.new" && mv "$PLAN/ORCHESTRATOR.md.new" "$PLAN/ORCHESTRATOR.md"
}

@test "red twin: a yield-handling block with one sentence reworded fails naming the line" {
  local line
  spec_less_fixture
  mutate_orchestrator '/^[[:space:]]*Sibling executors in the same wave/ { sub(/continue unaffected/, "carry on regardless") } { print }'
  grep -qF 'carry on regardless' "$PLAN/ORCHESTRATOR.md"
  verify_spec_less
  [ "$status" -eq 1 ]
  line="$(grep -nF 'carry on regardless' "$PLAN/ORCHESTRATOR.md" | cut -d: -f1)"
  echo "$output" | grep -F "ORCHESTRATOR.md:$line:" | grep -qF "yield-handling block does not match planner.md"
}

@test "red twin: a yield-handling block with one line dropped fails" {
  spec_less_fixture
  mutate_orchestrator '/^[[:space:]]*Each task keeps its own yield count/ { next } { print }'
  verify_spec_less
  [ "$status" -eq 1 ]
  echo "$output" | grep -qF "yield-handling block does not match planner.md"
}

@test "red twin: a yield-handling block cut short by the end of the file fails" {
  spec_less_fixture
  {
    printf '# Orchestrator\n\n'
    yield_block 0 | sed -n '1,4p'
  } >"$PLAN/ORCHESTRATOR.md"
  printf '%s\n%s\n' "$S_WIKI" "$S_CLOSE" >>"$PLAN/ORCHESTRATOR.md"
  verify_spec_less
  [ "$status" -eq 1 ]
  echo "$output" | grep -qF "yield-handling block does not match planner.md"
}

@test "red twin: a yield-handling block with the plan-directory placeholder left in fails twice over" {
  spec_less_fixture
  mutate_orchestrator '{ while ((i = index($0, plan)) > 0) $0 = substr($0, 1, i - 1) "{PLAN_DIR}" substr($0, i + length(plan)) } { print }'
  grep -qF '{PLAN_DIR}' "$PLAN/ORCHESTRATOR.md"
  verify_spec_less
  [ "$status" -eq 1 ]
  echo "$output" | grep -qF "yield-handling block does not match planner.md"
  echo "$output" | grep -qF 'unsubstituted placeholder {PLAN_DIR}'
}

@test "red twin: the yield-handling block above the resume block is out of order" {
  spec_less_fixture
  write_orchestrator "$S_YIELD" "$S_RESUME" "$S_RETRY" "$S_WORTH" "$S_OVERLAP" "$S_WIKI" "$S_AUDIT" "$S_CLEAR" "$S_CLOSE"
  verify_spec_less
  [ "$status" -eq 1 ]
  echo "$output" | grep -F 'out of order' | grep -qF -- "$S_RESUME"
}

@test "red twin: a planner.md without the fenced block fails naming planner.md" {
  local tree="$BATS_TEST_TMPDIR/tree"
  copy_script_tree "$tree"
  grep -vE '^[[:space:]]*```' "$PLANNER_MD" >"$tree/.claude/skills/gaia/references/plan/planner.md"
  spec_less_fixture
  run bash "$tree/.gaia/scripts/spec/plan-verify.sh" "$PLAN"
  [ "$status" -eq 1 ]
  echo "$output" | grep -F 'planner.md' | grep -qF 'no fenced resume-detection block'
  rm "$tree/.claude/skills/gaia/references/plan/planner.md"
  run bash "$tree/.gaia/scripts/spec/plan-verify.sh" "$PLAN"
  [ "$status" -eq 1 ]
  echo "$output" | grep -F 'planner.md' | grep -qF 'no fenced resume-detection block'
}

# ---------- the other verbatim blocks and the order of the late sentinels ----------

@test "red twin: each adjacent swap among the late sentinels is out of order and named" {
  local order=("$S_FLOW" "$S_WORTH" "$S_OVERLAP" "$S_WIKI" "$S_AUDIT" "$S_CLEAR" "$S_CLOSE") index swapped
  [ "${#order[@]}" -eq 7 ]
  index=0
  while [ "$index" -lt 6 ]; do
    swapped=("${order[@]}")
    swapped[index]="${order[$((index + 1))]}"
    swapped[$((index + 1))]="${order[$index]}"
    spec_fixture
    write_orchestrator "$S_RESUME" "$S_YIELD" "$S_RETRY" "${swapped[@]}"
    verify_spec
    [ "$status" -eq 1 ] || { echo "swap at $index exited $status" >&2; return 1; }
    echo "$output" | grep -F 'out of order' | grep -qF -- "${order[$index]}" || { echo "swap at $index not named: $output" >&2; return 1; }
    index=$((index + 1))
  done
}

@test "red twin: a reworded line in the worthiness-step, wiki-promotion, code-audit, post-clearance or gate-retry block fails naming the line and the block" {
  local entry name from to line
  for entry in \
    'worthiness-step|skip-safe|resumable' \
    'wiki-promotion|no re-consolidation|maybe re-consolidation' \
    'code-audit|the late pass from|the early pass from' \
    'post-clearance|it is untracked|it is tracked' \
    'gate-retry|Never fix it on the main thread|Fix it on the main thread'; do
    name="${entry%%|*}"
    entry="${entry#*|}"
    from="${entry%%|*}"
    to="${entry#*|}"
    spec_fixture
    awk -v from="$from" -v to="$to" '{ if ((i = index($0, from)) > 0) $0 = substr($0, 1, i - 1) to substr($0, i + length(from)) } { print }' "$PLAN/ORCHESTRATOR.md" >"$PLAN/ORCHESTRATOR.md.new"
    mv "$PLAN/ORCHESTRATOR.md.new" "$PLAN/ORCHESTRATOR.md"
    line="$(grep -nF -m1 -- "$to" "$PLAN/ORCHESTRATOR.md" | cut -d: -f1)"
    [ -n "$line" ] || { echo "'$from' is not in the $name block" >&2; return 1; }
    verify_spec
    [ "$status" -eq 1 ] || { echo "$name reworded exited $status" >&2; return 1; }
    echo "$output" | grep -F "ORCHESTRATOR.md:$line:" | grep -qF "$name block does not match planner.md" || { echo "$name: $output" >&2; return 1; }
  done
}

# marker_tree <planner file>: a script tree whose planner.md is the given file.
marker_tree() {
  MARKER_TREE="$BATS_TEST_TMPDIR/tree"
  copy_script_tree "$MARKER_TREE"
  cp "$1" "$MARKER_TREE/.claude/skills/gaia/references/plan/planner.md"
}

# strip_marked <in> <out>: the file with each maintainer-only marker pair and
# the lines between them removed, as the release's strip does.
strip_marked() {
  awk '
    { t = $0; sub(/^[ \t]+/, "", t); sub(/[ \t\r]+$/, "", t) }
    t == "<!-- gaia:maintainer-only:start -->" { skipping = 1; next }
    t == "<!-- gaia:maintainer-only:end -->" { skipping = 0; next }
    !skipping { print }' "$1" >"$2"
}

@test "marker case: a plan copying a marked pair passes against the planner that holds it" {
  spec_fixture
  grep -qF 'gaia:maintainer-only:start' "$PLAN/ORCHESTRATOR.md"
  marker_tree "$PLANNER_MD"
  run bash "$MARKER_TREE/.gaia/scripts/spec/plan-verify.sh" "$PLAN" --spec "$SPEC"
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
}

@test "marker case: the stripped planner and a plan copying its stripped blocks pass" {
  local stripped="$BATS_TEST_TMPDIR/planner-stripped.md"
  strip_marked "$PLANNER_MD" "$stripped"
  grep -qF 'gaia:maintainer-only:start' "$stripped" && return 1
  BLOCK_SOURCE="$stripped"
  spec_fixture
  grep -qF 'gaia:maintainer-only:start' "$PLAN/ORCHESTRATOR.md" && return 1
  marker_tree "$stripped"
  run bash "$MARKER_TREE/.gaia/scripts/spec/plan-verify.sh" "$PLAN" --spec "$SPEC"
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
}

@test "red twin: a plan that dropped the marked pair its planner keeps fails naming the line" {
  local stripped="$BATS_TEST_TMPDIR/planner-stripped.md"
  strip_marked "$PLANNER_MD" "$stripped"
  BLOCK_SOURCE="$stripped"
  spec_fixture
  marker_tree "$PLANNER_MD"
  run bash "$MARKER_TREE/.gaia/scripts/spec/plan-verify.sh" "$PLAN" --spec "$SPEC"
  [ "$status" -eq 1 ]
  echo "$output" | grep -E 'ORCHESTRATOR.md:[0-9]+:' | grep -qF 'block does not match planner.md'
}

# ---------- the overlap-pass sentinel ----------

@test "overlap-pass: a plan with the block in order passes, spec-derived and spec-less, from the planner's own block" {
  spec_fixture
  verify_spec
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  grep -qF -- "$S_OVERLAP" "$PLAN/ORCHESTRATOR.md"
  spec_less_fixture
  verify_spec_less
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  grep -qF -- "$S_OVERLAP" "$PLAN/ORCHESTRATOR.md"
}

@test "red twin: overlap-pass missing, after wiki-promotion or before worthiness-step fails naming it, in both arms" {
  local arm
  for arm in spec spec_less; do
    "${arm}_fixture"
    grep -vxF -- "$S_OVERLAP" "$PLAN/ORCHESTRATOR.md" >"$PLAN/ORCHESTRATOR.md.new"
    mv "$PLAN/ORCHESTRATOR.md.new" "$PLAN/ORCHESTRATOR.md"
    if [ "$arm" = spec ]; then verify_spec; else verify_spec_less; fi
    [ "$status" -eq 1 ] || return 1
    echo "$output" | grep -F 'missing the sentinel line' | grep -qF -- "$S_OVERLAP" || return 1
  done
  spec_fixture
  write_orchestrator "$S_RESUME" "$S_YIELD" "$S_RETRY" "$S_FLOW" "$S_WORTH" "$S_WIKI" "$S_OVERLAP" "$S_AUDIT" "$S_CLEAR" "$S_CLOSE"
  verify_spec
  [ "$status" -eq 1 ] || return 1
  echo "$output" | grep -F 'out of order' | grep -qF -- "$S_OVERLAP" || return 1
  spec_fixture
  write_orchestrator "$S_RESUME" "$S_YIELD" "$S_RETRY" "$S_FLOW" "$S_OVERLAP" "$S_WORTH" "$S_WIKI" "$S_AUDIT" "$S_CLEAR" "$S_CLOSE"
  verify_spec
  [ "$status" -eq 1 ] || return 1
  echo "$output" | grep -F 'out of order' | grep -qF -- "$S_WORTH" || return 1
  spec_less_fixture
  write_orchestrator "$S_RESUME" "$S_YIELD" "$S_RETRY" "$S_WORTH" "$S_WIKI" "$S_OVERLAP" "$S_AUDIT" "$S_CLEAR" "$S_CLOSE"
  verify_spec_less
  [ "$status" -eq 1 ] || return 1
  echo "$output" | grep -F 'out of order' | grep -qF -- "$S_OVERLAP" || return 1
}

@test "red twin: a paraphrased overlap-pass block fails naming the block, in both arms" {
  local arm
  for arm in spec spec_less; do
    "${arm}_fixture"
    sed 's/Its first action/X/; s/skip-safe/resumable/' "$PLAN/ORCHESTRATOR.md" >"$PLAN/ORCHESTRATOR.md.new"
    mv "$PLAN/ORCHESTRATOR.md.new" "$PLAN/ORCHESTRATOR.md"
    if [ "$arm" = spec ]; then verify_spec; else verify_spec_less; fi
    [ "$status" -eq 1 ] || return 1
    echo "$output" | grep -qF 'the overlap-pass block does not match planner.md' || return 1
  done
}

@test "red twin: gate-retry missing or above yield-handling fails naming it, in both arms" {
  local arm
  for arm in spec spec_less; do
    "${arm}_fixture"
    grep -vxF -- "$S_RETRY" "$PLAN/ORCHESTRATOR.md" >"$PLAN/ORCHESTRATOR.md.new"
    mv "$PLAN/ORCHESTRATOR.md.new" "$PLAN/ORCHESTRATOR.md"
    if [ "$arm" = spec ]; then verify_spec; else verify_spec_less; fi
    [ "$status" -eq 1 ] || return 1
    echo "$output" | grep -F 'missing the sentinel line' | grep -qF -- "$S_RETRY" || return 1
  done
  spec_less_fixture
  write_orchestrator "$S_RESUME" "$S_RETRY" "$S_YIELD" "$S_WORTH" "$S_OVERLAP" "$S_WIKI" "$S_AUDIT" "$S_CLEAR" "$S_CLOSE"
  verify_spec_less
  [ "$status" -eq 1 ] || return 1
  echo "$output" | grep -F 'out of order' | grep -qF -- "$S_YIELD" || return 1
}

# ---------- the resume-detection sentinel ----------

@test "red twin: resume-detection missing fails naming it, in both arms" {
  local arm
  for arm in spec spec_less; do
    "${arm}_fixture"
    grep -vxF -- "$S_RESUME" "$PLAN/ORCHESTRATOR.md" >"$PLAN/ORCHESTRATOR.md.new"
    mv "$PLAN/ORCHESTRATOR.md.new" "$PLAN/ORCHESTRATOR.md"
    if [ "$arm" = spec ]; then verify_spec; else verify_spec_less; fi
    [ "$status" -eq 1 ] || return 1
    echo "$output" | grep -F 'missing the sentinel line' | grep -qF -- "$S_RESUME" || return 1
  done
}

@test "red twin: a reworded dirty-tree option fails naming the line and the resume-detection block, in both arms" {
  local arm line
  for arm in spec spec_less; do
    "${arm}_fixture"
    mutate_orchestrator '{ if ((i = index($0, "`Stay halted (Recommended)` first")) > 0) $0 = substr($0, 1, i - 1) "`Discuss this (Recommended)` first" substr($0, i + 33) } { print }'
    line="$(grep -nF -m1 -- '`Discuss this (Recommended)` first' "$PLAN/ORCHESTRATOR.md" | cut -d: -f1)"
    [ -n "$line" ] || { echo 'the dirty-tree option is not in the resume-detection block' >&2; return 1; }
    if [ "$arm" = spec ]; then verify_spec; else verify_spec_less; fi
    [ "$status" -eq 1 ] || return 1
    echo "$output" | grep -F "ORCHESTRATOR.md:$line:" | grep -qF 'resume-detection block does not match planner.md' || { echo "$arm: $output" >&2; return 1; }
  done
}

@test "a spec-derived plan's resume-detection block names the pre-audit flow checks as where a fully complete plan resumes" {
  spec_fixture
  verify_spec
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  grep -F 'M+1' "$PLAN/ORCHESTRATOR.md" | grep -qF 'pre-audit flow checks' || { echo 'no line holds M+1 and pre-audit flow checks' >&2; return 1; }
}

@test "red twin: a resume-detection line that drops the flow-checks target fails the verbatim comparison" {
  local before line
  spec_fixture
  before="$(cksum <"$PLAN/ORCHESTRATOR.md")"
  mutate_orchestrator '/M\+1/ { gsub(/pre-audit flow checks/, "worthiness step") } { print }'
  [ "$(cksum <"$PLAN/ORCHESTRATOR.md")" != "$before" ] || { echo 'the mutation left ORCHESTRATOR.md unchanged' >&2; return 1; }
  line="$(grep -nF -m1 -- 'M+1' "$PLAN/ORCHESTRATOR.md" | cut -d: -f1)"
  verify_spec
  [ "$status" -eq 1 ] || return 1
  echo "$output" | grep -F "ORCHESTRATOR.md:$line:" | grep -qF 'resume-detection block does not match planner.md' || { echo "$output" >&2; return 1; }
}

@test "red twin: resume-detection after the first later step is out of order and named, in both arms" {
  spec_fixture
  write_orchestrator "$S_YIELD" "$S_RESUME" "$S_RETRY" "$S_FLOW" "$S_WORTH" "$S_OVERLAP" "$S_WIKI" "$S_AUDIT" "$S_CLEAR" "$S_CLOSE"
  verify_spec
  [ "$status" -eq 1 ] || return 1
  echo "$output" | grep -F 'out of order' | grep -qF -- "$S_RESUME" || return 1
  spec_less_fixture
  write_orchestrator "$S_YIELD" "$S_RESUME" "$S_RETRY" "$S_WORTH" "$S_OVERLAP" "$S_WIKI" "$S_AUDIT" "$S_CLEAR" "$S_CLOSE"
  verify_spec_less
  [ "$status" -eq 1 ] || return 1
  echo "$output" | grep -F 'out of order' | grep -qF -- "$S_RESUME" || return 1
}

# ---------- the flow checks of a spec-derived plan ----------

# add_readme_task <phase> <stem>: name the task stem in that phase's README row.
add_readme_task() {
  sed -i.bak -E "s/^(\\| Phase $1 \\|[^|]*)\\|/\\1, \`$2\`|/" "$PLAN/README.md"
  rm -f "$PLAN/README.md.bak"
  grep -qF "\`$2\`" "$PLAN/README.md"
}

@test "flows: removing the command flow's run command line fails naming that flow and the README's line" {
  spec_fixture
  grep -vF -- 'refuse-uats-spec.bats' "$PLAN/ORCHESTRATOR.md" >"$PLAN/ORCHESTRATOR.md.new"
  mv "$PLAN/ORCHESTRATOR.md.new" "$PLAN/ORCHESTRATOR.md"
  verify_spec
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -qxF 'plan-verify: ORCHESTRATOR.md: the Phase 2 entry runs no flow test for FLOW-902: no line holds refuse-uats-spec.bats with a runner (playwright test, test:shell, bats5.sh, test --run)' || { echo "$output" >&2; return 1; }
  grep -F 'runs no flow test' <<<"$output" | grep -qF 'FLOW-901' && return 1
  true
}

@test "flows: a last-phase entry with a flow's basename but no runner fails naming that flow" {
  spec_fixture
  FLOW_RUN_LINES="$WEB_RUN_LINE"$'\n'"see .gaia/tests/lib/refuse-uats-spec.bats for the cases"
  write_orchestrator "${SPEC_ORDER[@]}"
  verify_spec
  [ "$status" -eq 1 ]
  refusal_line 'runs no flow test for FLOW-902'
}

@test "flows: a plan with no entry for the last phase fails naming it" {
  spec_fixture
  grep -vE '^\*\*Phase 2, ' "$PLAN/ORCHESTRATOR.md" >"$PLAN/ORCHESTRATOR.md.new"
  mv "$PLAN/ORCHESTRATOR.md.new" "$PLAN/ORCHESTRATOR.md"
  verify_spec
  [ "$status" -eq 1 ]
  refusal_line 'ORCHESTRATOR.md has no **Phase 2, entry for the last phase'
}

@test "flows: a flow with no task line fails naming the flow" {
  spec_fixture
  printf '# Web flow\n\n- nothing\n' >"$PLAN/task-flow-web.md"
  verify_spec
  [ "$status" -eq 1 ]
  refusal_line 'FLOW-901'
}

@test "flows: a flow line moved into an earlier phase's task doc fails" {
  spec_fixture
  printf '# Web flow\n\n- nothing\n' >"$PLAN/task-flow-web.md"
  printf '# Build\n\n- Flow test (FLOW-901): %s\n' "$WEB_TEST_PATH" >"$PLAN/task-build.md"
  verify_spec
  [ "$status" -eq 1 ]
  refusal_line 'FLOW-901' 'task-build.md'
}

@test "flows: the same flow on two lines fails naming the flow" {
  spec_fixture
  add_readme_task 2 task-flow-extra
  printf '# Extra\n\n- Flow test (FLOW-901): %s\n' "$WEB_TEST_PATH" >"$PLAN/task-flow-extra.md"
  verify_spec
  [ "$status" -eq 1 ]
  refusal_line 'FLOW-901'
}

@test "flows: one last-phase task doc carrying two flow lines fails naming the file" {
  spec_fixture
  printf '# Web flow\n\n- Flow test (FLOW-901): %s\n- Flow test (FLOW-902): %s\n' "$WEB_TEST_PATH" "$COMMAND_TEST_PATH" >"$PLAN/task-flow-web.md"
  printf '# Command flow\n\n- nothing\n' >"$PLAN/task-flow-command.md"
  verify_spec
  [ "$status" -eq 1 ]
  refusal_line 'task-flow-web.md'
}

@test "flows: a last-phase task doc with no flow line fails naming the file" {
  spec_fixture
  add_readme_task 2 task-flow-extra
  printf '# Extra\n\n- builds more\n' >"$PLAN/task-flow-extra.md"
  verify_spec
  [ "$status" -eq 1 ]
  refusal_line 'task-flow-extra.md'
}

@test "flows: a line whose path is not the expected path fails naming the flow and the expected path" {
  spec_fixture
  printf '# Web flow\n\n- Flow test (FLOW-901): apps/web/.playwright/flows/other-name.spec.ts\n' >"$PLAN/task-flow-web.md"
  verify_spec
  [ "$status" -eq 1 ]
  refusal_line 'FLOW-901' "$WEB_TEST_PATH"
}

@test "flows: a command flow line whose path differs from the flow's test_path fails naming the flow" {
  spec_fixture
  printf '# Command flow\n\n- Flow test (FLOW-902): .gaia/tests/lib/other-name.bats\n' >"$PLAN/task-flow-command.md"
  verify_spec
  [ "$status" -eq 1 ]
  refusal_line 'FLOW-902' "$COMMAND_TEST_PATH"
}

@test "flows: a line naming a flow id absent from the SPEC fails naming that id" {
  spec_fixture
  add_readme_task 2 task-flow-extra
  printf '# Extra\n\n- Flow test (FLOW-999): apps/web/.playwright/flows/ghost.spec.ts\n' >"$PLAN/task-flow-extra.md"
  verify_spec
  [ "$status" -eq 1 ]
  refusal_line 'FLOW-999'
}

@test "flows: a task stem that no README phase row names fails naming the task doc" {
  spec_fixture
  printf '# Orphan\n\n- builds\n' >"$PLAN/task-orphan.md"
  verify_spec
  [ "$status" -eq 1 ]
  refusal_line 'task-orphan.md'
}

@test "flows: a task stem two README phase rows name fails naming the task doc" {
  spec_fixture
  add_readme_task 1 task-flow-web
  verify_spec
  [ "$status" -eq 1 ]
  refusal_line 'task-flow-web.md'
}

@test "flows: a SPEC with a uats key fails with the refusal reason" {
  spec_fixture
  write_flow_spec 'uats:'
  verify_spec
  [ "$status" -eq 1 ]
  refusal_line 'the SPEC carries a top-level uats: key'
}

@test "flows: every flow refusal in one plan is reported in one run" {
  spec_fixture
  printf '# Web flow\n\n- nothing\n' >"$PLAN/task-flow-web.md"
  printf '# Command flow\n\n- nothing\n' >"$PLAN/task-flow-command.md"
  verify_spec
  [ "$status" -eq 1 ]
  refusal_line 'FLOW-901'
  refusal_line 'FLOW-902'
}

@test "flows: a spec-less plan is not asked for flow lines or a last-phase run entry" {
  spec_less_fixture
  printf '# Task\n\n- Flow test (FLOW-999): nowhere.spec.ts\n' >"$PLAN/task-one.md"
  verify_spec_less
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
}
