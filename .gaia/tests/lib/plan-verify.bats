#!/usr/bin/env bats
#
# .gaia/scripts/spec/plan-verify.sh behavior: existence checks, the orchestrator
# step sentinels (match rule, order rule, per-arm requirements), the verbatim
# blocks (resume detection, yield handling, gate retry, security writer, simplify
# pass, flow checks, wiki promotion, code audit and post-clearance), failure
# aggregation, placeholder scanning, the flow checks of a spec-derived plan (the
# flow-test task line, the task-stem-to-phase rule, the closing-phase entry that
# runs each flow test), and the test-stage record's reading: a running or ran
# record owes the closing phase its Flow test lines and a phase with a
# security-kind Test line its Security writer line, a skipped or absent record
# refuses a Flow test line and owes nothing, and a malformed record fails
# naming the file. Shell level only.
#
# Assertion style follows .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT_REAL="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SCRIPT="$REPO_ROOT_REAL/.gaia/scripts/spec/plan-verify.sh"
  PLAN="$BATS_TEST_TMPDIR/plan"
  SPEC="$BATS_TEST_TMPDIR/SPEC.md"
  TEMPLATE_MD="$REPO_ROOT_REAL/.claude/skills/gaia/references/plan/orchestrator-template.md"
  mkdir -p "$PLAN"
  S_RESUME='<!-- gaia:orchestrator-step resume-detection -->'
  S_YIELD='<!-- gaia:orchestrator-step yield-handling -->'
  S_RETRY='<!-- gaia:orchestrator-step gate-retry -->'
  S_SECWRITER='<!-- gaia:orchestrator-step security-writer -->'
  S_SIMPLIFY='<!-- gaia:orchestrator-step simplify-pass -->'
  S_FLOW='<!-- gaia:orchestrator-step flow-checks -->'
  S_WIKI='<!-- gaia:orchestrator-step wiki-promotion -->'
  S_AUDIT='<!-- gaia:orchestrator-step code-audit -->'
  S_CLEAR='<!-- gaia:orchestrator-step post-clearance -->'
  S_CLOSE='<!-- gaia:orchestrator-step post-merge-close -->'
  SPEC_ORDER=("$S_RESUME" "$S_YIELD" "$S_RETRY" "$S_SECWRITER" "$S_SIMPLIFY" "$S_FLOW" "$S_WIKI" "$S_AUDIT" "$S_CLEAR" "$S_CLOSE")
  SPEC_LESS_ORDER=("$S_RESUME" "$S_YIELD" "$S_RETRY" "$S_SECWRITER" "$S_SIMPLIFY" "$S_WIKI" "$S_AUDIT" "$S_CLEAR" "$S_CLOSE")
  WEB_TEST_PATH='apps/web/.playwright/flows/guest-checkout.spec.ts'
  COMMAND_TEST_PATH='.gaia/tests/lib/refuse-uats-spec.bats'
  WEB_RUN_LINE='pnpm -C apps/web exec playwright test .playwright/flows/guest-checkout.spec.ts'
  COMMAND_RUN_LINE='bash .gaia/scripts/bats5.sh .gaia/tests/lib/refuse-uats-spec.bats < /dev/null'
  FLOW_RUN_LINES=''
  SECURITY_WRITER_PHASES=''
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

# block_of <sentinel> [<indent>]: the block that sentinel opens, as the template
# file in BLOCK_SOURCE (default the orchestrator template) holds it, re-indented to <indent>
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
    }' "${BLOCK_SOURCE:-$TEMPLATE_MD}")"
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
    "$S_RESUME" | "$S_YIELD" | "$S_RETRY" | "$S_SECWRITER" | "$S_SIMPLIFY" | "$S_FLOW" | "$S_WIKI" | "$S_AUDIT" | "$S_CLEAR") return 0 ;;
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
      case " ${SECURITY_WRITER_PHASES:-} " in *" $phase "*) printf -- '- Security writer: 1 rows (T9)\n' ;; esac
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

# write_test_stage <status>: the plan's TEST-STAGE record.
write_test_stage() {
  printf 'status: %s\ndate: 2026-01-01T00:00:00Z\n' "$1" >"$PLAN/TEST-STAGE"
}

# spec_fixture: a passing spec-derived plan folder with two flows.
spec_fixture() {
  rm -rf "$PLAN"
  mkdir -p "$PLAN"
  write_flow_spec
  flow_readme
  rm -f "$PLAN"/task-*.md
  FLOW_RUN_LINES="$WEB_RUN_LINE"$'\n'"$COMMAND_RUN_LINE"
  write_orchestrator "${SPEC_ORDER[@]}"
  printf '# Kickoff\n' >"$PLAN/KICKOFF.md"
  printf '# Build\n\n- builds the pages\n' >"$PLAN/task-build.md"
  printf '# Web flow\n\n- Flow test (FLOW-901): %s\n' "$WEB_TEST_PATH" >"$PLAN/task-flow-web.md"
  printf '# Command flow\n\n- Flow test (FLOW-902): %s\n' "$COMMAND_TEST_PATH" >"$PLAN/task-flow-command.md"
  write_test_stage ran
}

# spec_less_fixture: a passing spec-less plan folder.
spec_less_fixture() {
  rm -rf "$PLAN"
  mkdir -p "$PLAN"
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
# registry it reads, so a case can give it its own template.
copy_script_tree() {
  local relative
  rm -rf "$1"
  mkdir -p "$1/.gaia/scripts" "$1/.claude/skills/gaia/references/plan" "$1/.claude/hooks/lib" "$1/apps/web"
  cp -R "$REPO_ROOT_REAL/.gaia/scripts/spec" "$1/.gaia/scripts/spec"
  for relative in .gaia/scripts/machine-local-ref-lib.sh .claude/hooks/lib/gaia-packages.sh .gaia/packages.json apps/web/gaia.package.json; do
    cp "$REPO_ROOT_REAL/$relative" "$1/$relative"
  done
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

# Rewrite the fixture's ORCHESTRATOR.md through an awk program, in place.
mutate_orchestrator() {
  awk -v plan="$PLAN" "$1" "$PLAN/ORCHESTRATOR.md" >"$PLAN/ORCHESTRATOR.md.new" && mv "$PLAN/ORCHESTRATOR.md.new" "$PLAN/ORCHESTRATOR.md"
}

# marker_tree <template file>: a script tree whose orchestrator template is the given file.
marker_tree() {
  MARKER_TREE="$BATS_TEST_TMPDIR/tree"
  copy_script_tree "$MARKER_TREE"
  cp "$1" "$MARKER_TREE/.claude/skills/gaia/references/plan/orchestrator-template.md"
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

# append_after_sentinel <sentinel>: the first non-blank line after the sentinel
# line gets extra words, so that block no longer matches the template.
append_after_sentinel() {
  awk -v sentinel="$1" '
    { t = $0; sub(/^[ \t]+/, "", t); sub(/[ \t\r]+$/, "", t) }
    t == sentinel { mark = 1; print; next }
    mark && !done && t != "" { print $0 " extra words"; done = 1; next }
    { print }' "$PLAN/ORCHESTRATOR.md" >"$PLAN/ORCHESTRATOR.md.new"
  mv "$PLAN/ORCHESTRATOR.md.new" "$PLAN/ORCHESTRATOR.md"
}

# add_readme_task <phase> <stem>: name the task stem in that phase's README row.
add_readme_task() {
  sed -i.bak -E "s/^(\\| Phase $1 \\|[^|]*)\\|/\\1, \`$2\`|/" "$PLAN/README.md"
  rm -f "$PLAN/README.md.bak"
  grep -qF "\`$2\`" "$PLAN/README.md"
}

# verify_arm <spec|spec_less>: run plan-verify.sh the way that arm's plan is checked.
verify_arm() {
  if [ "$1" = spec ]; then verify_spec; else verify_spec_less; fi
}

# remove_line <literal>: drop the exact line from the fixture's ORCHESTRATOR.md.
remove_line() {
  grep -vxF -- "$1" "$PLAN/ORCHESTRATOR.md" >"$PLAN/ORCHESTRATOR.md.new"
  mv "$PLAN/ORCHESTRATOR.md.new" "$PLAN/ORCHESTRATOR.md"
}

# assert_out_of_order <arm> <sentinel the output must name, or empty> <order>...
assert_out_of_order() {
  local arm="$1" named="$2"
  shift 2
  "${arm}_fixture"
  write_orchestrator "$@"
  verify_arm "$arm"
  [ "$status" -eq 1 ] || { echo "$arm order exited $status: $output" >&2; return 1; }
  if [ -n "$named" ]; then
    grep -F 'out of order' <<<"$output" | grep -qF -- "$named" || { echo "$arm: $named not named: $output" >&2; return 1; }
  else
    grep -qF 'out of order' <<<"$output" || { echo "$arm: no out of order line: $output" >&2; return 1; }
  fi
}

@test "plan-verify passes a complete plan in each arm: spec-derived, spec-less, an absolute --spec spelled through .., no New tests line, no test-stage record and no flow lines" {
  local arm
  spec_fixture
  verify_spec
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  run bash "$SCRIPT" "$PLAN" --spec "$PLAN/../SPEC.md"
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  grep -qF 'orchestrator-step drift-check' "$PLAN/ORCHESTRATOR.md" && return 1

  spec_less_fixture
  verify_spec_less
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  grep -qF -- "$S_FLOW" "$PLAN/ORCHESTRATOR.md" && return 1
  [ "${#SPEC_LESS_ORDER[@]}" -eq "$((${#SPEC_ORDER[@]} - 1))" ] || { echo 'the spec-less order differs from the spec-derived order by more than flow-checks' >&2; return 1; }

  spec_less_fixture
  write_task '- builds the page'
  grep -rqF 'New tests' "$PLAN" && return 1
  verify_spec_less
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }

  for arm in spec spec_less; do
    "${arm}_fixture"
    rm -f "$PLAN/TEST-STAGE"
    if [ "$arm" = spec ]; then
      printf '# Web flow\n\n- nothing\n' >"$PLAN/task-flow-web.md"
      printf '# Command flow\n\n- nothing\n' >"$PLAN/task-flow-command.md"
    fi
    verify_arm "$arm"
    [ "$status" -eq 0 ] || { echo "$arm: $output" >&2; return 1; }
  done
}

@test "plan-verify fails a task doc name ending in -tests or outside the task name pattern, naming it" {
  spec_less_fixture
  printf '# Task\n' >"$PLAN/task-one-tests.md"
  verify_spec_less
  [ "$status" -eq 1 ]
  refusal_line 'task-one-tests.md'

  spec_less_fixture
  printf '# Task\n' >"$PLAN/task-Bad_Name.md"
  verify_spec_less
  [ "$status" -eq 1 ]
  refusal_line 'task-Bad_Name.md'
}

@test "plan-verify requires every sentinel (flow-checks only for a spec-derived plan), names a missing one alone, and fails a paraphrased security-writer block in both arms" {
  local literal arm
  same_set "$(script_sentinels)" "${SPEC_ORDER[@]}"
  for literal in "${SPEC_ORDER[@]}"; do
    spec_fixture
    remove_line "$literal"
    verify_spec
    [ "$status" -eq 1 ] || { echo "$literal removed exited $status" >&2; return 1; }
    refusal_line 'missing the sentinel line' "$literal"
    [ "$(echo "$output" | grep -c 'sentinel')" -eq 1 ] || { echo "$literal: $output" >&2; return 1; }
  done

  same_set "$(script_spec_less_sentinels)" "${SPEC_LESS_ORDER[@]}"
  spec_less_fixture
  verify_spec_less
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  for literal in "${SPEC_LESS_ORDER[@]}"; do
    spec_less_fixture
    remove_line "$literal"
    verify_spec_less
    [ "$status" -eq 1 ] || { echo "$literal removed exited $status" >&2; return 1; }
    refusal_line 'missing the sentinel line' "$literal"
  done

  for arm in spec spec_less; do
    "${arm}_fixture"
    append_after_sentinel "$S_SECWRITER"
    verify_arm "$arm"
    [ "$status" -eq 1 ] || { echo "$arm paraphrase exited $status" >&2; return 1; }
    grep -qF "the security-writer block does not match the template's copy" <<<"$output" || { echo "$arm: $output" >&2; return 1; }
  done
}

@test "plan-verify fails a sentinel out of order and names it: flow-checks before gate-retry, close above promotion, yield above resume in both arms, gate-retry above yield, each adjacent swap among the late sentinels" {
  local order=("$S_SECWRITER" "$S_SIMPLIFY" "$S_FLOW" "$S_WIKI" "$S_AUDIT" "$S_CLEAR" "$S_CLOSE") index swapped
  assert_out_of_order spec "$S_RETRY" "$S_RESUME" "$S_YIELD" "$S_FLOW" "$S_RETRY" "$S_SECWRITER" "$S_SIMPLIFY" "$S_WIKI" "$S_AUDIT" "$S_CLEAR" "$S_CLOSE"
  assert_out_of_order spec_less '' "$S_RESUME" "$S_YIELD" "$S_RETRY" "$S_SECWRITER" "$S_SIMPLIFY" "$S_CLOSE" "$S_WIKI" "$S_AUDIT" "$S_CLEAR"
  assert_out_of_order spec_less "$S_RESUME" "$S_YIELD" "$S_RESUME" "$S_RETRY" "$S_SECWRITER" "$S_SIMPLIFY" "$S_WIKI" "$S_AUDIT" "$S_CLEAR" "$S_CLOSE"
  assert_out_of_order spec "$S_RESUME" "$S_YIELD" "$S_RESUME" "$S_RETRY" "$S_SECWRITER" "$S_SIMPLIFY" "$S_FLOW" "$S_WIKI" "$S_AUDIT" "$S_CLEAR" "$S_CLOSE"
  assert_out_of_order spec_less "$S_YIELD" "$S_RESUME" "$S_RETRY" "$S_YIELD" "$S_WIKI" "$S_AUDIT" "$S_CLEAR" "$S_CLOSE"
  [ "${#order[@]}" -eq 7 ]
  index=0
  while [ "$index" -lt 6 ]; do
    swapped=("${order[@]}")
    swapped[index]="${order[$((index + 1))]}"
    swapped[$((index + 1))]="${order[$index]}"
    assert_out_of_order spec "${order[$index]}" "$S_RESUME" "$S_YIELD" "$S_RETRY" "${swapped[@]}" || { echo "swap at $index" >&2; return 1; }
    index=$((index + 1))
  done
}

@test "plan-verify fails a verbatim block that differs from the template and names the line and block: a reworded sentence, a dropped line, a cut-short block, a leftover placeholder, a missing fenced block, a reworded dirty-tree option, a dropped flow-checks target" {
  local line tree entry name from to arm before
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
  refusal_line "ORCHESTRATOR.md:$line:" "the flow-checks block does not match the template's copy"

  spec_less_fixture
  mutate_orchestrator '/^[[:space:]]*Sibling executors in the same wave/ { sub(/continue unaffected/, "carry on regardless") } { print }'
  grep -qF 'carry on regardless' "$PLAN/ORCHESTRATOR.md"
  verify_spec_less
  [ "$status" -eq 1 ]
  line="$(grep -nF 'carry on regardless' "$PLAN/ORCHESTRATOR.md" | cut -d: -f1)"
  echo "$output" | grep -F "ORCHESTRATOR.md:$line:" | grep -qF "yield-handling block does not match the template's copy"

  spec_less_fixture
  mutate_orchestrator '/^[[:space:]]*Each task keeps its own yield count/ { next } { print }'
  verify_spec_less
  [ "$status" -eq 1 ]
  echo "$output" | grep -qF "yield-handling block does not match the template's copy"

  spec_less_fixture
  {
    printf '# Orchestrator\n\n'
    yield_block 0 | sed -n '1,4p'
  } >"$PLAN/ORCHESTRATOR.md"
  printf '%s\n%s\n' "$S_WIKI" "$S_CLOSE" >>"$PLAN/ORCHESTRATOR.md"
  verify_spec_less
  [ "$status" -eq 1 ]
  echo "$output" | grep -qF "yield-handling block does not match the template's copy"

  spec_less_fixture
  mutate_orchestrator '{ while ((i = index($0, plan)) > 0) $0 = substr($0, 1, i - 1) "{PLAN_DIR}" substr($0, i + length(plan)) } { print }'
  grep -qF '{PLAN_DIR}' "$PLAN/ORCHESTRATOR.md"
  verify_spec_less
  [ "$status" -eq 1 ]
  echo "$output" | grep -qF "yield-handling block does not match the template's copy"
  echo "$output" | grep -qF 'unsubstituted placeholder {PLAN_DIR}'

  tree="$BATS_TEST_TMPDIR/tree"
  copy_script_tree "$tree"
  grep -vE '^[[:space:]]*```' "$TEMPLATE_MD" >"$tree/.claude/skills/gaia/references/plan/orchestrator-template.md"
  spec_less_fixture
  run bash "$tree/.gaia/scripts/spec/plan-verify.sh" "$PLAN"
  [ "$status" -eq 1 ]
  echo "$output" | grep -F 'orchestrator template' | grep -qF 'no fenced resume-detection block'
  rm "$tree/.claude/skills/gaia/references/plan/orchestrator-template.md"
  run bash "$tree/.gaia/scripts/spec/plan-verify.sh" "$PLAN"
  [ "$status" -eq 1 ]
  [ "$(grep -c 'the orchestrator template is missing' <<<"$output")" -eq 1 ]
  grep -qF 'block does not match' <<<"$output" && return 1
  grep -qF 'no fenced' <<<"$output" && return 1

  for entry in \
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
    echo "$output" | grep -F "ORCHESTRATOR.md:$line:" | grep -qF "$name block does not match the template's copy" || { echo "$name: $output" >&2; return 1; }
  done

  for arm in spec spec_less; do
    "${arm}_fixture"
    mutate_orchestrator '{ if ((i = index($0, "`Stay halted (Recommended)` first")) > 0) $0 = substr($0, 1, i - 1) "`Discuss this (Recommended)` first" substr($0, i + 33) } { print }'
    line="$(grep -nF -m1 -- '`Discuss this (Recommended)` first' "$PLAN/ORCHESTRATOR.md" | cut -d: -f1)"
    [ -n "$line" ] || { echo 'the dirty-tree option is not in the resume-detection block' >&2; return 1; }
    verify_arm "$arm"
    [ "$status" -eq 1 ] || return 1
    echo "$output" | grep -F "ORCHESTRATOR.md:$line:" | grep -qF "resume-detection block does not match the template's copy" || { echo "$arm: $output" >&2; return 1; }
  done

  spec_fixture
  before="$(cksum <"$PLAN/ORCHESTRATOR.md")"
  mutate_orchestrator '/M\+1/ { gsub(/pre-audit flow checks/, "worthiness step") } { print }'
  [ "$(cksum <"$PLAN/ORCHESTRATOR.md")" != "$before" ] || { echo 'the mutation left ORCHESTRATOR.md unchanged' >&2; return 1; }
  line="$(grep -nF -m1 -- 'M+1' "$PLAN/ORCHESTRATOR.md" | cut -d: -f1)"
  verify_spec
  [ "$status" -eq 1 ] || return 1
  echo "$output" | grep -F "ORCHESTRATOR.md:$line:" | grep -qF "resume-detection block does not match the template's copy" || { echo "$output" >&2; return 1; }
}

@test "plan-verify matches an indented sentinel, a block copied as the planner indents it and a trailing tab, and does not match a sentinel line carrying trailing prose" {
  spec_fixture
  build_indented_orchestrator spec 6
  grep -qE '^      <!-- gaia:orchestrator-step yield-handling -->$' "$PLAN/ORCHESTRATOR.md"
  verify_spec
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  spec_less_fixture
  build_indented_orchestrator spec_less 6
  verify_spec_less
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }

  spec_fixture
  write_orchestrator "$S_RESUME" "$S_YIELD" "$S_RETRY" "$S_SECWRITER" "$S_SIMPLIFY" "$S_FLOW" "$S_WIKI" "$S_AUDIT" "$S_CLEAR" "$S_CLOSE see below"
  verify_spec
  [ "$status" -eq 1 ]
  echo "$output" | grep -qF -- "$S_CLOSE"
}

@test "plan-verify fails naming a missing KICKOFF.md or no task doc, and reports every failure in one run" {
  spec_less_fixture
  rm "$PLAN/KICKOFF.md"
  verify_spec_less
  [ "$status" -eq 1 ]
  echo "$output" | grep -qF 'KICKOFF.md'

  spec_less_fixture
  rm "$PLAN/task-one.md"
  verify_spec_less
  [ "$status" -eq 1 ]
  echo "$output" | grep -qF 'task-*.md'

  spec_less_fixture
  rm "$PLAN/KICKOFF.md" "$PLAN/task-one.md"
  verify_spec_less
  [ "$status" -eq 1 ]
  echo "$output" | grep -qF 'KICKOFF.md'
  echo "$output" | grep -qF 'task-*.md'
}

# The renderer substitutes the absolute values for these tokens in every file it
# writes; a surviving token sends a cold orchestrator to a literal brace path.
@test "plan-verify fails naming the file and token for each unsubstituted placeholder in a generated plan file (both arms, one line each) and ignores files the renderer does not generate" {
  local token file
  for file in ORCHESTRATOR.md KICKOFF.md README.md task-one.md; do
    for token in '{PLAN_DIR}' '{SPEC_PATH}' '{AUDIT_PATH}' '{BRANCH_ID}'; do
      spec_less_fixture
      printf 'Read %s/README.md first.\n' "$token" >>"$PLAN/$file"
      verify_spec_less
      [ "$status" -eq 1 ] || { echo "$file with $token exited $status" >&2; return 1; }
      echo "$output" | grep -F -- "$file" | grep -qF -- "$token" || { echo "no line names $file and $token: $output" >&2; return 1; }
    done
  done

  spec_fixture
  printf 'run the check on {SPEC_PATH}\n' >>"$PLAN/ORCHESTRATOR.md"
  verify_spec
  [ "$status" -eq 1 ]
  echo "$output" | grep -F 'ORCHESTRATOR.md' | grep -qF '{SPEC_PATH}'

  spec_less_fixture
  printf '{PLAN_DIR}\n{AUDIT_PATH}\n' >>"$PLAN/KICKOFF.md"
  verify_spec_less
  [ "$status" -eq 1 ]
  [ "$(echo "$output" | grep -c 'unsubstituted')" -eq 2 ]

  spec_less_fixture
  mkdir -p "$PLAN/audit"
  printf '{PLAN_DIR}\n' >"$PLAN/PROGRESS.md"
  printf '{PLAN_DIR}\n' >"$PLAN/audit/DP.json"
  verify_spec_less
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
}

@test "plan-verify honours maintainer-only marked pairs: a plan copying a marked pair passes, a stripped template passes with stripped blocks, a plan that dropped the pair its template keeps fails naming the line" {
  local stripped="$BATS_TEST_TMPDIR/template-stripped.md"
  spec_fixture
  grep -qF 'gaia:maintainer-only:start' "$PLAN/ORCHESTRATOR.md"
  marker_tree "$TEMPLATE_MD"
  run bash "$MARKER_TREE/.gaia/scripts/spec/plan-verify.sh" "$PLAN" --spec "$SPEC"
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }

  strip_marked "$TEMPLATE_MD" "$stripped"
  grep -qF 'gaia:maintainer-only:start' "$stripped" && return 1
  BLOCK_SOURCE="$stripped"
  spec_fixture
  grep -qF 'gaia:maintainer-only:start' "$PLAN/ORCHESTRATOR.md" && return 1
  marker_tree "$stripped"
  run bash "$MARKER_TREE/.gaia/scripts/spec/plan-verify.sh" "$PLAN" --spec "$SPEC"
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }

  marker_tree "$TEMPLATE_MD"
  run bash "$MARKER_TREE/.gaia/scripts/spec/plan-verify.sh" "$PLAN" --spec "$SPEC"
  [ "$status" -eq 1 ]
  echo "$output" | grep -E 'ORCHESTRATOR.md:[0-9]+:' | grep -qF "block does not match the template's copy"
}

@test "names the template in its header and on a block mismatch, fails once when it is missing, passes a plan rendered from a release-scrubbed template, and the moved sections are in the template and absent from planner.md" {
  local stripped="$BATS_TEST_TMPDIR/template-stripped.md" line sentinel
  [ "$(grep -c 'planner.md' "$SCRIPT")" -eq 0 ]
  sed -n '1,25p' "$SCRIPT" | grep -qF 'orchestrator-template.md'

  spec_fixture
  append_after_sentinel "$S_AUDIT"
  verify_spec
  [ "$status" -eq 1 ]
  line="$(echo "$output" | grep -E 'ORCHESTRATOR.md:[0-9]+:' | grep -F 'code-audit block does not match the template' | head -n1)"
  [ -n "$line" ] || { echo "$output" >&2; return 1; }

  marker_tree "$TEMPLATE_MD"
  rm "$MARKER_TREE/.claude/skills/gaia/references/plan/orchestrator-template.md"
  run bash "$MARKER_TREE/.gaia/scripts/spec/plan-verify.sh" "$PLAN" --spec "$SPEC"
  [ "$status" -eq 1 ]
  [ "$(grep -c 'the orchestrator template is missing' <<<"$output")" -eq 1 ]
  grep -qF 'block does not match' <<<"$output" && return 1

  strip_marked "$TEMPLATE_MD" "$stripped"
  BLOCK_SOURCE="$stripped"
  spec_fixture
  marker_tree "$stripped"
  run bash "$MARKER_TREE/.gaia/scripts/spec/plan-verify.sh" "$PLAN" --spec "$SPEC"
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }

  for sentinel in "${SPEC_ORDER[@]}"; do
    grep -qxF -- "$sentinel" "$TEMPLATE_MD" || { echo "template lacks $sentinel" >&2; return 1; }
  done

  [ "$(grep -cF 'gaia:orchestrator-step' "$REPO_ROOT_REAL/.claude/skills/gaia/references/plan/planner.md")" -eq 0 ]
}

@test "plan-verify checks a spec-derived plan's flow lines: each flow has exactly one task line with the expected path and runner in the last phase, a command flow path matches test_path, no unknown flow ids, every task stem names exactly one README phase row, a uats SPEC is refused, and every refusal is reported in one run (a spec-less plan is not asked)" {
  # a flow's run command line removed
  spec_fixture
  grep -vF -- 'refuse-uats-spec.bats' "$PLAN/ORCHESTRATOR.md" >"$PLAN/ORCHESTRATOR.md.new"
  mv "$PLAN/ORCHESTRATOR.md.new" "$PLAN/ORCHESTRATOR.md"
  verify_spec
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -qxF 'plan-verify: ORCHESTRATOR.md: the Phase 2 entry runs no flow test for FLOW-902: no line holds refuse-uats-spec.bats with a runner (playwright test, test:shell, bats5.sh, test --run)' || { echo "$output" >&2; return 1; }
  grep -F 'runs no flow test' <<<"$output" | grep -qF 'FLOW-901' && return 1

  # a basename without a runner
  spec_fixture
  FLOW_RUN_LINES="$WEB_RUN_LINE"$'\n'"see .gaia/tests/lib/refuse-uats-spec.bats for the cases"
  write_orchestrator "${SPEC_ORDER[@]}"
  verify_spec
  [ "$status" -eq 1 ]
  refusal_line 'runs no flow test for FLOW-902'

  # no entry for the last phase
  spec_fixture
  grep -vE '^\*\*Phase 2, ' "$PLAN/ORCHESTRATOR.md" >"$PLAN/ORCHESTRATOR.md.new"
  mv "$PLAN/ORCHESTRATOR.md.new" "$PLAN/ORCHESTRATOR.md"
  verify_spec
  [ "$status" -eq 1 ]
  refusal_line 'ORCHESTRATOR.md has no **Phase 2, entry for the last phase'

  # a flow with no task line
  spec_fixture
  printf '# Web flow\n\n- nothing\n' >"$PLAN/task-flow-web.md"
  verify_spec
  [ "$status" -eq 1 ]
  refusal_line 'FLOW-901'

  # a flow line in an earlier phase's task doc
  spec_fixture
  printf '# Web flow\n\n- nothing\n' >"$PLAN/task-flow-web.md"
  printf '# Build\n\n- Flow test (FLOW-901): %s\n' "$WEB_TEST_PATH" >"$PLAN/task-build.md"
  verify_spec
  [ "$status" -eq 1 ]
  refusal_line 'FLOW-901' 'task-build.md'

  # the same flow on two lines
  spec_fixture
  add_readme_task 2 task-flow-extra
  printf '# Extra\n\n- Flow test (FLOW-901): %s\n' "$WEB_TEST_PATH" >"$PLAN/task-flow-extra.md"
  verify_spec
  [ "$status" -eq 1 ]
  refusal_line 'FLOW-901'

  # one last-phase task doc carrying two flow lines
  spec_fixture
  printf '# Web flow\n\n- Flow test (FLOW-901): %s\n- Flow test (FLOW-902): %s\n' "$WEB_TEST_PATH" "$COMMAND_TEST_PATH" >"$PLAN/task-flow-web.md"
  printf '# Command flow\n\n- nothing\n' >"$PLAN/task-flow-command.md"
  verify_spec
  [ "$status" -eq 1 ]
  refusal_line 'task-flow-web.md'

  # a last-phase task doc with no flow line
  spec_fixture
  add_readme_task 2 task-flow-extra
  printf '# Extra\n\n- builds more\n' >"$PLAN/task-flow-extra.md"
  verify_spec
  [ "$status" -eq 1 ]
  refusal_line 'task-flow-extra.md'

  # a path that is not the expected path, for a web flow and a command flow
  spec_fixture
  printf '# Web flow\n\n- Flow test (FLOW-901): apps/web/.playwright/flows/other-name.spec.ts\n' >"$PLAN/task-flow-web.md"
  verify_spec
  [ "$status" -eq 1 ]
  refusal_line 'FLOW-901' "$WEB_TEST_PATH"
  spec_fixture
  printf '# Command flow\n\n- Flow test (FLOW-902): .gaia/tests/lib/other-name.bats\n' >"$PLAN/task-flow-command.md"
  verify_spec
  [ "$status" -eq 1 ]
  refusal_line 'FLOW-902' "$COMMAND_TEST_PATH"

  # a flow id absent from the SPEC
  spec_fixture
  add_readme_task 2 task-flow-extra
  printf '# Extra\n\n- Flow test (FLOW-999): apps/web/.playwright/flows/ghost.spec.ts\n' >"$PLAN/task-flow-extra.md"
  verify_spec
  [ "$status" -eq 1 ]
  refusal_line 'FLOW-999'

  # a task stem no README phase row names
  spec_fixture
  printf '# Orphan\n\n- builds\n' >"$PLAN/task-orphan.md"
  verify_spec
  [ "$status" -eq 1 ]
  refusal_line 'task-orphan.md'

  # a flow line in a task doc no phase row names adds no false findings
  spec_fixture
  printf '# Web flow\n\n- nothing\n' >"$PLAN/task-flow-web.md"
  printf '# Orphan\n\n- Flow test (FLOW-901): %s\n' "$WEB_TEST_PATH" >"$PLAN/task-orphan.md"
  verify_spec
  [ "$status" -eq 1 ]
  refusal_line 'task-orphan.md'
  grep -qF '(Phase FLOW-' <<<"$output" && return 1
  grep -qF 'does not define' <<<"$output" && return 1

  # a task stem two README phase rows name
  spec_fixture
  add_readme_task 1 task-flow-web
  verify_spec
  [ "$status" -eq 1 ]
  refusal_line 'task-flow-web.md'

  # a SPEC with a uats key
  spec_fixture
  write_flow_spec 'uats:'
  verify_spec
  [ "$status" -eq 1 ]
  refusal_line 'the SPEC carries a top-level uats: key'

  # every refusal in one run
  spec_fixture
  printf '# Web flow\n\n- nothing\n' >"$PLAN/task-flow-web.md"
  printf '# Command flow\n\n- nothing\n' >"$PLAN/task-flow-command.md"
  verify_spec
  [ "$status" -eq 1 ]
  refusal_line 'FLOW-901'
  refusal_line 'FLOW-902'

  # a spec-less plan is not asked
  spec_less_fixture
  write_task '- Flow test (FLOW-999): nowhere.spec.ts'
  write_test_stage ran
  verify_spec_less
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
}

SECURITY_TEST_LINE='- Test (task-one:AC1, unit, access): apps/web/app/utils/guard.test.ts › refuses a stranger'

@test "plan-verify reads the test-stage record: a running or ran stage owes flow and security-writer lines, a skipped or absent stage refuses a Flow test line, a malformed record fails naming the file" {
  local state
  for state in skipped absent; do
    spec_less_fixture
    write_task '- Flow test (FLOW-999): nowhere.spec.ts'
    if [ "$state" = skipped ]; then write_test_stage skipped; else rm -f "$PLAN/TEST-STAGE"; fi
    verify_spec_less
    [ "$status" -eq 1 ] || { echo "$state: a flow line exited $status: $output" >&2; return 1; }
    refusal_line 'task-one.md' 'Flow test line'
    write_task '- nothing'
    verify_spec_less
    [ "$status" -eq 0 ] || { echo "$state: no flow line: $output" >&2; return 1; }
  done
  for state in running ran; do
    # the flow line, absent: refused naming the flow
    spec_fixture
    write_test_stage "$state"
    printf '# Web flow\n\n- nothing\n' >"$PLAN/task-flow-web.md"
    verify_spec
    [ "$status" -eq 1 ] || { echo "$state: missing flow line exited $status" >&2; return 1; }
    refusal_line 'FLOW-901'
    # a security-kind Test line: refused naming the phase, passes with the writer line
    spec_fixture
    write_test_stage "$state"
    printf '# Build\n\n%s\n' "$SECURITY_TEST_LINE" >"$PLAN/task-build.md"
    verify_spec
    [ "$status" -eq 1 ] || { echo "$state: missing writer line exited $status" >&2; return 1; }
    refusal_line 'Phase 1' "'- Security writer:'"
    SECURITY_WRITER_PHASES=1
    write_orchestrator "${SPEC_ORDER[@]}"
    SECURITY_WRITER_PHASES=''
    verify_spec
    [ "$status" -eq 0 ] || { echo "$state: both lines present: $output" >&2; return 1; }
  done
  # a none-kind Test line owes no writer line
  spec_fixture
  printf '# Build\n\n- Test (task-build:AC1, unit, none): apps/web/app/utils/a.test.ts › a\n' >"$PLAN/task-build.md"
  verify_spec
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  # skipped and absent: a task doc carrying a Flow test line fails naming the file
  for state in skipped absent; do
    spec_fixture
    if [ "$state" = skipped ]; then write_test_stage skipped; else rm -f "$PLAN/TEST-STAGE"; fi
    verify_spec
    [ "$status" -eq 1 ] || { echo "$state: a flow line exited $status" >&2; return 1; }
    refusal_line 'task-flow-web.md' 'Flow test line'
    refusal_line 'task-flow-command.md' 'Flow test line'
    printf '# Web flow\n\n- nothing\n' >"$PLAN/task-flow-web.md"
    printf '# Command flow\n\n- nothing\n' >"$PLAN/task-flow-command.md"
    printf '# Build\n\n%s\n' "$SECURITY_TEST_LINE" >"$PLAN/task-build.md"
    verify_spec
    [ "$status" -eq 0 ] || { echo "$state: no lines owed: $output" >&2; return 1; }
  done
  # a malformed record fails naming the file and refuses nothing else
  spec_fixture
  printf 'status: done\ndate: 2026-01-01T00:00:00Z\n' >"$PLAN/TEST-STAGE"
  verify_spec
  [ "$status" -eq 1 ] || return 1
  refusal_line 'TEST-STAGE is malformed' "$PLAN/TEST-STAGE"
  [ "$(echo "$output" | grep -c .)" -eq 1 ] || { echo "$output" >&2; return 1; }
}
