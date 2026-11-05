#!/usr/bin/env bats
#
# .gaia/scripts/spec/plan-verify.sh behavior: existence checks, the routing
# table, the story test criterion line, the orchestrator step
# sentinels (match rule, order rule, per-arm requirements), the verbatim
# blocks (resume detection, yield handling, gate retry, worthiness step,
# overlap pass, wiki promotion, code audit and post-clearance), failure aggregation, the story and non-ui misrouting
# warning and the browser capability refusals. Shell level only.
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
  S_RENDER='<!-- gaia:orchestrator-step uat-render -->'
  S_GATE='<!-- gaia:orchestrator-step uat-gate -->'
  S_YIELD='<!-- gaia:orchestrator-step yield-handling -->'
  S_RETRY='<!-- gaia:orchestrator-step gate-retry -->'
  S_PRE='<!-- gaia:orchestrator-step uat-pre-audit -->'
  S_WORTH='<!-- gaia:orchestrator-step worthiness-step -->'
  S_OVERLAP='<!-- gaia:orchestrator-step overlap-pass -->'
  S_WIKI='<!-- gaia:orchestrator-step wiki-promotion -->'
  S_AUDIT='<!-- gaia:orchestrator-step code-audit -->'
  S_CLEAR='<!-- gaia:orchestrator-step post-clearance -->'
  S_CLOSE='<!-- gaia:orchestrator-step post-merge-close -->'
  SPEC_ORDER=("$S_RESUME" "$S_RENDER" "$S_GATE" "$S_YIELD" "$S_RETRY" "$S_PRE" "$S_WORTH" "$S_OVERLAP" "$S_WIKI" "$S_AUDIT" "$S_CLEAR" "$S_CLOSE")
  SPEC_LESS_ORDER=("$S_RESUME" "$S_YIELD" "$S_RETRY" "$S_WORTH" "$S_OVERLAP" "$S_WIKI" "$S_AUDIT" "$S_CLEAR" "$S_CLOSE")
}

# write_spec [<story then-clause>]: three UATs, one per surface.
write_spec() {
  cat >"$SPEC" <<EOF2
---
spec_id: SPEC-901
uats:
  - uat_id: UAT-001
    given: a visitor with items in the cart
    when: they check out as a guest
    then: focus lands on the order number after checkout
  - uat_id: UAT-002
    given: the save button is shown
    when: the user presses save
    then: ${1:-the toast reads Saved}
  - uat_id: UAT-003
    given: a corrupted cache file
    when: the rebuild script runs
    then: the script exits zero
---
EOF2
}

write_routing() {
  cat >"$PLAN/README.md" <<EOF2
# Plan

<!-- gaia:uat-routing:start -->
| uat_id | surface | phase | feature_folder | file_name |
|---|---|---|---|---|
| UAT-001 | browser | 2 | checkout | guest-checkout-confirms-order.spec.ts |
| UAT-002 | story | 3 | - | - |
| UAT-003 | non-ui | 1 | - | - |
<!-- gaia:uat-routing:end -->
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
    "$S_RESUME" | "$S_YIELD" | "$S_RETRY" | "$S_WORTH" | "$S_OVERLAP" | "$S_WIKI" | "$S_AUDIT" | "$S_CLEAR") return 0 ;;
  esac
  return 1
}

# write_orchestrator <sentinel>...: ORCHESTRATOR.md with these lines in this
# order; a verbatim sentinel stands for the whole copied block.
write_orchestrator() {
  local entry
  {
    printf '# Orchestrator\n\n'
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

# spec_fixture: a passing spec-derived plan folder.
spec_fixture() {
  write_spec
  write_routing
  write_orchestrator "${SPEC_ORDER[@]}"
  printf '# Kickoff\n' >"$PLAN/KICKOFF.md"
  write_task '- Story test criterion (UAT-002): the toast reads Saved'
  printf '# Browser\n\n- Browser capability (UAT-001): focus or keyboard: focus lands on the order number\n' >"$PLAN/task-browser.md"
}

# spec_less_fixture: a passing spec-less plan folder.
spec_less_fixture() {
  printf '# Plan\n' >"$PLAN/README.md"
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
# plan; script_spec_less_sentinels: the same without the three UAT sentinels.
script_sentinels() {
  awk '/^sentinels=\(/,/^verbatim_sentinels=/' "$SCRIPT" | grep -oE "'<!-- gaia:orchestrator-step [a-z-]+ -->'" | tr -d "'" | awk '!seen[$0]++'
}
script_spec_less_sentinels() {
  script_sentinels | grep -vxF -e "$S_RENDER" -e "$S_GATE" -e "$S_PRE"
}

verify_spec() {
  run bash "$SCRIPT" "$PLAN" --spec "$SPEC"
}

verify_spec_less() {
  run bash "$SCRIPT" "$PLAN"
}

@test "a complete spec-derived plan passes" {
  spec_fixture
  verify_spec
  [ "$status" -eq 0 ]
}

@test "a complete spec-less plan passes" {
  spec_less_fixture
  verify_spec_less
  [ "$status" -eq 0 ]
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

@test "a story UAT with no criterion line fails naming its id" {
  spec_fixture
  write_task '- nothing relevant'
  verify_spec
  [ "$status" -eq 1 ]
  echo "$output" | grep -qF 'UAT-002'
}

@test "a criterion line for the right id with a different then-clause fails" {
  spec_fixture
  write_task '- Story test criterion (UAT-002): the toast reads Failed'
  verify_spec
  [ "$status" -eq 1 ]
  echo "$output" | grep -qF 'UAT-002'
}

@test "a criterion line for a different id does not satisfy the story UAT" {
  spec_fixture
  write_task '- Story test criterion (UAT-003): the toast reads Saved'
  verify_spec
  [ "$status" -eq 1 ]
  echo "$output" | grep -qF 'UAT-002'
}

@test "whitespace-only differences in the criterion line pass" {
  spec_fixture
  write_task "-   Story test criterion (UAT-002):	the   toast  reads   Saved   "
  verify_spec
  [ "$status" -eq 0 ]
}

@test "a then-clause that begins and ends with a double quote passes verbatim and is not quote-stripped" {
  spec_fixture
  write_spec "'\"Saved\" toast reads \"Done\"'"
  write_task '- Story test criterion (UAT-002): "Saved" toast reads "Done"'
  verify_spec
  [ "$status" -eq 0 ]
  write_task '- Story test criterion (UAT-002): Saved" toast reads "Done'
  verify_spec
  [ "$status" -eq 1 ]
}

@test "the criterion line may live in any task doc" {
  spec_fixture
  write_task '- nothing relevant'
  printf '%s\n' '- Story test criterion (UAT-002): the toast reads Saved' >"$PLAN/task-two.md"
  verify_spec
  [ "$status" -eq 0 ]
}

@test "an invalid routing table fails and carries the library problem line" {
  spec_fixture
  sed -i.bak '/| UAT-003 |/d' "$PLAN/README.md"
  rm -f "$PLAN/README.md.bak"
  verify_spec
  [ "$status" -eq 1 ]
  echo "$output" | grep -qF 'UAT-003 has no routing row'
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

@test "a spec-less plan does not require the UAT sentinels but requires every other sentinel" {
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

@test "indented sentinels and a trailing tab still match" {
  local literal
  spec_fixture
  {
    block_of "$S_RESUME" 6
    printf '\n      %s\n\n' "$S_RENDER" "$S_GATE"
    yield_block 6
    printf '\n'
    block_of "$S_RETRY" 6
    printf '\n      %s\n\n' "$S_PRE"
    for literal in "$S_WORTH" "$S_OVERLAP" "$S_WIKI" "$S_AUDIT" "$S_CLEAR"; do
      block_of "$literal" 6
      printf '\n'
    done
    printf '%s\t\n' "$S_CLOSE"
  } >"$PLAN/ORCHESTRATOR.md"
  verify_spec
  [ "$status" -eq 0 ]
}

@test "a sentinel line carrying trailing prose does not match" {
  spec_fixture
  write_orchestrator "$S_RESUME" "$S_RENDER" "$S_GATE" "$S_YIELD" "$S_RETRY" "$S_PRE" "$S_WORTH" "$S_WIKI" "$S_AUDIT" "$S_CLEAR" "$S_CLOSE see below"
  verify_spec
  [ "$status" -eq 1 ]
  echo "$output" | grep -qF -- "$S_CLOSE"
}

@test "the render sentinel below the gate sentinel is out of order and named" {
  spec_fixture
  write_orchestrator "$S_RESUME" "$S_GATE" "$S_RENDER" "$S_YIELD" "$S_RETRY" "$S_PRE" "$S_WORTH" "$S_WIKI" "$S_AUDIT" "$S_CLEAR" "$S_CLOSE"
  verify_spec
  [ "$status" -eq 1 ]
  echo "$output" | grep -F 'out of order' | grep -qF -- "$S_RENDER"
}

@test "a spec-less plan with the close sentinel above the promotion sentinel fails" {
  spec_less_fixture
  write_orchestrator "$S_RESUME" "$S_YIELD" "$S_RETRY" "$S_WORTH" "$S_CLOSE" "$S_WIKI" "$S_AUDIT" "$S_CLEAR"
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

@test "a story row whose then-clause mentions navigation warns without changing the exit code" {
  spec_fixture
  write_spec 'the page navigates to /checkout'
  write_task '- Story test criterion (UAT-002): the page navigates to /checkout'
  verify_spec
  [ "$status" -eq 0 ]
  echo "$output" | grep -qE '^WARN: UAT-002'
}

@test "a story row without route words prints no warning" {
  spec_fixture
  verify_spec
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF 'WARN:' && return 1
  true
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
  printf 'bash uat-write.sh {SPEC_PATH}\n' >>"$PLAN/ORCHESTRATOR.md"
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

@test "a block copied from planner.md and indented as a planner indents it passes, with and without the spec" {
  local literal
  spec_fixture
  {
    printf '# Orchestrator\n\n'
    block_of "$S_RESUME" 6
    printf '\n      %s\n\n' "$S_RENDER" "$S_GATE"
    yield_block 6
    printf '\n'
    block_of "$S_RETRY" 6
    printf '\n      %s\n\n' "$S_PRE"
    for literal in "$S_WORTH" "$S_OVERLAP" "$S_WIKI" "$S_AUDIT" "$S_CLEAR"; do
      block_of "$literal" 6
      printf '\n'
    done
    printf '      %s\n\n' "$S_CLOSE"
  } >"$PLAN/ORCHESTRATOR.md"
  grep -qE '^      <!-- gaia:orchestrator-step yield-handling -->$' "$PLAN/ORCHESTRATOR.md"
  verify_spec
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  spec_less_fixture
  {
    printf '# Orchestrator\n\n'
    block_of "$S_RESUME" 6
    printf '\n'
    yield_block 6
    printf '\n'
    block_of "$S_RETRY" 6
    printf '\n'
    for literal in "$S_WORTH" "$S_OVERLAP" "$S_WIKI" "$S_AUDIT" "$S_CLEAR"; do
      block_of "$literal" 6
      printf '\n'
    done
    printf '      %s\n\n' "$S_CLOSE"
  } >"$PLAN/ORCHESTRATOR.md"
  verify_spec_less
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
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

@test "red twin: the yield-handling block above the gate block is out of order" {
  spec_fixture
  write_orchestrator "$S_RESUME" "$S_RENDER" "$S_YIELD" "$S_GATE" "$S_RETRY" "$S_PRE" "$S_WORTH" "$S_WIKI" "$S_AUDIT" "$S_CLEAR" "$S_CLOSE"
  verify_spec
  [ "$status" -eq 1 ]
  echo "$output" | grep -F 'out of order' | grep -qF -- "$S_GATE"
}

@test "red twin: a planner.md without the fenced block fails naming planner.md" {
  local tree="$BATS_TEST_TMPDIR/tree"
  mkdir -p "$tree/.gaia/scripts/spec" "$tree/.claude/skills/gaia/references/plan"
  cp "$SCRIPT" "$REPO_ROOT_REAL/.gaia/scripts/spec/uat-lib.sh" "$REPO_ROOT_REAL/.gaia/scripts/spec/uat-code-only.sh" "$REPO_ROOT_REAL/.gaia/scripts/spec/browser-capability-lib.sh" "$tree/.gaia/scripts/spec/"
  grep -vE '^[[:space:]]*```' "$PLANNER_MD" >"$tree/.claude/skills/gaia/references/plan/planner.md"
  spec_less_fixture
  run bash "$tree/.gaia/scripts/spec/plan-verify.sh" "$PLAN"
  [ "$status" -eq 1 ]
  echo "$output" | grep -F 'planner.md' | grep -qF 'no fenced yield-handling block'
  rm "$tree/.claude/skills/gaia/references/plan/planner.md"
  run bash "$tree/.gaia/scripts/spec/plan-verify.sh" "$PLAN"
  [ "$status" -eq 1 ]
  echo "$output" | grep -F 'planner.md' | grep -qF 'no fenced yield-handling block'
}

# ---------- the other verbatim blocks and the order of the late sentinels ----------

@test "red twin: each adjacent swap among the late sentinels is out of order and named" {
  local order=("$S_PRE" "$S_WORTH" "$S_OVERLAP" "$S_WIKI" "$S_AUDIT" "$S_CLEAR" "$S_CLOSE") index swapped
  [ "${#order[@]}" -eq 7 ]
  index=0
  while [ "$index" -lt 6 ]; do
    swapped=("${order[@]}")
    swapped[index]="${order[$((index + 1))]}"
    swapped[$((index + 1))]="${order[$index]}"
    spec_fixture
    write_orchestrator "$S_RESUME" "$S_RENDER" "$S_GATE" "$S_YIELD" "$S_RETRY" "${swapped[@]}"
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
  mkdir -p "$MARKER_TREE/.gaia/scripts/spec" "$MARKER_TREE/.claude/skills/gaia/references/plan"
  cp "$SCRIPT" "$REPO_ROOT_REAL/.gaia/scripts/spec/uat-lib.sh" "$REPO_ROOT_REAL/.gaia/scripts/spec/uat-code-only.sh" "$REPO_ROOT_REAL/.gaia/scripts/spec/browser-capability-lib.sh" "$MARKER_TREE/.gaia/scripts/spec/"
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
  write_orchestrator "$S_RESUME" "$S_RENDER" "$S_GATE" "$S_YIELD" "$S_RETRY" "$S_PRE" "$S_WORTH" "$S_WIKI" "$S_OVERLAP" "$S_AUDIT" "$S_CLEAR" "$S_CLOSE"
  verify_spec
  [ "$status" -eq 1 ] || return 1
  echo "$output" | grep -F 'out of order' | grep -qF -- "$S_OVERLAP" || return 1
  spec_fixture
  write_orchestrator "$S_RESUME" "$S_RENDER" "$S_GATE" "$S_YIELD" "$S_RETRY" "$S_PRE" "$S_OVERLAP" "$S_WORTH" "$S_WIKI" "$S_AUDIT" "$S_CLEAR" "$S_CLOSE"
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

@test "red twin: resume-detection after the first later step is out of order and named, in both arms" {
  spec_fixture
  write_orchestrator "$S_RENDER" "$S_RESUME" "$S_GATE" "$S_YIELD" "$S_RETRY" "$S_PRE" "$S_WORTH" "$S_OVERLAP" "$S_WIKI" "$S_AUDIT" "$S_CLEAR" "$S_CLOSE"
  verify_spec
  [ "$status" -eq 1 ] || return 1
  echo "$output" | grep -F 'out of order' | grep -qF -- "$S_RESUME" || return 1
  spec_less_fixture
  write_orchestrator "$S_YIELD" "$S_RESUME" "$S_RETRY" "$S_WORTH" "$S_OVERLAP" "$S_WIKI" "$S_AUDIT" "$S_CLEAR" "$S_CLOSE"
  verify_spec_less
  [ "$status" -eq 1 ] || return 1
  echo "$output" | grep -F 'out of order' | grep -qF -- "$S_RESUME" || return 1
}

@test "the misrouting warning names a route before a browser UAT" {
  spec_fixture
  write_spec 'the page navigates to /checkout'
  write_task '- Story test criterion (UAT-002): the page navigates to /checkout'
  verify_spec
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF 'confirm it is not a route or, when only a browser shows it, a browser UAT'
}

# one_uat_plan <surface> <then-clause> [<capability-line>] [<given>]: a
# spec-derived plan with the one UAT routed to <surface>; the SPEC and routing
# file are written fresh. A non-empty third argument becomes a task-doc line.
one_uat_plan() {
  local file_cells='checkout | guest-checkout-confirms-order.spec.ts'
  cat >"$SPEC" <<EOF2
---
spec_id: SPEC-901
uats:
  - uat_id: UAT-001
    given: ${4:-a visitor}
    when: they act
    then: $2
---
EOF2
  cat >"$PLAN/README.md" <<EOF2
# Plan

<!-- gaia:uat-routing:start -->
| uat_id | surface | phase | feature_folder | file_name |
|---|---|---|---|---|
| UAT-001 | $1 | 1 | $file_cells |
<!-- gaia:uat-routing:end -->
EOF2
  write_orchestrator "${SPEC_ORDER[@]}"
  printf '# Kickoff\n' >"$PLAN/KICKOFF.md"
  write_task '- nothing'
  if [ -n "${3:-}" ]; then
    write_task "- nothing"$'\n'"$3"
  fi
}

# scratch_verifier <edit-expression>: a copy of plan-verify.sh (with the
# libraries it sources and planner.md) in the test tmp dir. The edit runs over
# plan-verify.sh and the capability-line lib, since a guard can live in either;
# an edit that matches neither leaves the guard in place, so a twin fails loud.
scratch_verifier() {
  local root="$BATS_TEST_TMPDIR/scratch"
  mkdir -p "$root/.gaia/scripts/spec" "$root/.claude/skills/gaia/references/plan"
  cp "$REPO_ROOT_REAL/.gaia/scripts/spec/uat-lib.sh" "$REPO_ROOT_REAL/.gaia/scripts/spec/uat-code-only.sh" "$root/.gaia/scripts/spec/"
  cp "$PLANNER_MD" "$root/.claude/skills/gaia/references/plan/planner.md"
  sed "$1" "$REPO_ROOT_REAL/.gaia/scripts/spec/browser-capability-lib.sh" >"$root/.gaia/scripts/spec/browser-capability-lib.sh"
  sed "$1" "$SCRIPT" >"$root/.gaia/scripts/spec/plan-verify.sh"
  SCRATCH_SCRIPT="$root/.gaia/scripts/spec/plan-verify.sh"
}

@test "a plan with a real-server row and its reason line passes" {
  one_uat_plan real-server 'the sign-in response sets the session cookie' '- Real-server reason (UAT-001): the cookie the served response sets, which a direct action call never sends'
  verify_spec
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
}

@test "reason: a real-server row with no reason line is refused naming the UAT and the line" {
  one_uat_plan real-server 'the sign-in response sets the session cookie'
  verify_spec
  expect_refusal 'plan-verify: UAT-001 is routed real-server but no task doc carries its line: - Real-server reason (UAT-001): <what a route test cannot show>'
}

@test "reason: an empty or blank reason is refused" {
  local reason_line
  for reason_line in '- Real-server reason (UAT-001):' '- Real-server reason (UAT-001):   '; do
    one_uat_plan real-server 'the sign-in response sets the session cookie' "$reason_line"
    verify_spec
    expect_refusal 'UAT-001 is routed real-server but no task doc carries its line' || return 1
  done
}

@test "reason: one blanket line naming two real-server rows satisfies neither" {
  cat >"$SPEC" <<'EOF2'
---
spec_id: SPEC-901
uats:
  - uat_id: UAT-001
    given: a visitor
    when: they sign in
    then: the response sets the session cookie
  - uat_id: UAT-002
    given: a visitor
    when: they sign out
    then: the response clears the session cookie
---
EOF2
  cat >"$PLAN/README.md" <<'EOF2'
# Plan

<!-- gaia:uat-routing:start -->
| uat_id | surface | phase | feature_folder | file_name |
|---|---|---|---|---|
| UAT-001 | real-server | 1 | auth | sign-in-sets-cookie.spec.ts |
| UAT-002 | real-server | 1 | auth | sign-out-clears-cookie.spec.ts |
<!-- gaia:uat-routing:end -->
EOF2
  write_orchestrator "${SPEC_ORDER[@]}"
  printf '# Kickoff\n' >"$PLAN/KICKOFF.md"
  write_task '- Real-server reason (UAT-001, UAT-002): these need the live stack'
  verify_spec
  expect_refusal 'UAT-001 is routed real-server but no task doc carries its line' || return 1
  echo "$output" | grep -qF 'UAT-002 is routed real-server but no task doc carries its line' || { echo "$output" >&2; return 1; }
}

@test "red twin: without the reason check a real-server row with no line exits 0" {
  scratch_verifier 's/^        real-server)$/        real-server-disabled)/'
  one_uat_plan real-server 'the sign-in response sets the session cookie'
  run bash "$SCRATCH_SCRIPT" "$PLAN" --spec "$SPEC"
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
}

@test "a new plan with an e2e row exits 1, naming the UAT and both replacement surfaces" {
  one_uat_plan e2e 'focus moves to the first field of the dialog'
  verify_spec
  [ "$status" -eq 1 ]
  echo "$output" | grep -qF 'plan-verify: uat-routing: UAT-001 uses the e2e surface, which a new plan no longer takes; route it real-server (the live stack with no page) or browser (only a real browser shows it)'
}

@test "red twin: without the e2e refusal the same plan exits 0" {
  one_uat_plan e2e 'focus moves to the first field of the dialog'
  scratch_verifier 's/^          fail "uat-routing: \$uat_id uses the e2e surface.*$/          :/'
  run bash "$SCRATCH_SCRIPT" "$PLAN" --spec "$SPEC"
  [ "$status" -eq 0 ]
}

@test "the shared validator accepts an e2e row, refuses a real-server and browser row on one path, and names an unknown surface" {
  one_uat_plan e2e 'focus moves'
  run bash -c ". '$REPO_ROOT_REAL/.gaia/scripts/spec/uat-lib.sh'; uat_lib_validate_routing '$SPEC' '$PLAN/README.md'"
  [ "$status" -eq 0 ]
  cat >"$SPEC" <<'EOF2'
---
spec_id: SPEC-901
uats:
  - uat_id: UAT-001
    given: a
    when: b
    then: c
  - uat_id: UAT-002
    given: a
    when: b
    then: d
---
EOF2
  cat >"$PLAN/README.md" <<'EOF2'
<!-- gaia:uat-routing:start -->
| uat_id | surface | phase | feature_folder | file_name |
|---|---|---|---|---|
| UAT-001 | real-server | 1 | checkout | one.spec.ts |
| UAT-002 | browser | 1 | checkout | one.spec.ts |
<!-- gaia:uat-routing:end -->
EOF2
  run bash -c ". '$REPO_ROOT_REAL/.gaia/scripts/spec/uat-lib.sh'; uat_lib_validate_routing '$SPEC' '$PLAN/README.md'"
  [ "$status" -eq 2 ]
  echo "$output" | grep -qF 'UAT-002 resolves to checkout/one.spec.ts, a path another real-server, browser or e2e row already claims'
  sed -i.bak 's/| browser |/| desktop |/' "$PLAN/README.md"
  run bash -c ". '$REPO_ROOT_REAL/.gaia/scripts/spec/uat-lib.sh'; uat_lib_validate_routing '$SPEC' '$PLAN/README.md'"
  [ "$status" -eq 2 ]
  echo "$output" | grep -qF "uat-routing: UAT-002 has surface 'desktop'; expected real-server, browser, route, story or non-ui"
}

# ---------- the browser capability refusals ----------

capability_tokens_of() {
  sed -n 's/^capability_tokens=(\(.*\))$/\1/p' "$1" | grep -oE '"[^"]+"' | tr -d '"'
}

capability_cues_of() {
  sed -n "s/^capability_cues=(\(.*\))\$/\1/p" "$1" | grep -oE "'[^']+'" | tr -d "'"
}

# two_browser_plan <then-1> <then-2> <task-text>: two browser rows over one
# task doc.
two_browser_plan() {
  cat >"$SPEC" <<EOF2
---
spec_id: SPEC-901
uats:
  - uat_id: UAT-001
    given: a visitor
    when: they act
    then: $1
  - uat_id: UAT-002
    given: a visitor
    when: they act again
    then: $2
---
EOF2
  cat >"$PLAN/README.md" <<'EOF2'
# Plan

<!-- gaia:uat-routing:start -->
| uat_id | surface | phase | feature_folder | file_name |
|---|---|---|---|---|
| UAT-001 | browser | 1 | checkout | first.spec.ts |
| UAT-002 | browser | 1 | checkout | second.spec.ts |
<!-- gaia:uat-routing:end -->
EOF2
  write_orchestrator "${SPEC_ORDER[@]}"
  printf '# Kickoff\n' >"$PLAN/KICKOFF.md"
  write_task "$3"
}

# expect_refusal <message-fragment>: the last run exited 1 with this fragment.
expect_refusal() {
  [ "$status" -eq 1 ] || { echo "$output" >&2; return 1; }
  echo "$output" | grep -qF -- "$1" || { echo "$output" >&2; return 1; }
}

@test "capability: a browser row with no line is refused naming the closed list while the row with a line is not named" {
  two_browser_plan 'focus moves to the first field' 'focus moves to the second field' '- Browser capability (UAT-001): focus or keyboard: focus moves to the first field'
  verify_spec
  expect_refusal 'UAT-002 is routed browser but no task doc carries its line'
  echo "$output" | grep -qF 'a browser row needs a capability from the closed list' || return 1
  echo "$output" | grep -F 'plan-verify: UAT-001' && return 1
  true
}

@test "capability: an unknown capability is refused naming the UAT and all five tokens" {
  local tokens token count=0
  tokens=$(capability_tokens_of "$SCRIPT")
  while IFS= read -r token; do count=$((count + 1)); done <<<"$tokens"
  [ "$count" -eq 5 ] || return 1
  one_uat_plan browser 'focus moves to the first field' '- Browser capability (UAT-001): hover: focus moves to the first field'
  verify_spec
  expect_refusal "UAT-001 names browser capability 'hover', which is not in the closed list"
  while IFS= read -r token; do
    echo "$output" | grep -qF -- "$token" || { echo "missing $token" >&2; return 1; }
  done <<<"$tokens"
}

@test "capability: an absent phrase and a phrase with no cue word are each refused on their own line" {
  two_browser_plan 'focus moves to the first field' 'focus moves to the second field' '- Browser capability (UAT-001): focus or keyboard: the cursor lands in the field
- Browser capability (UAT-002): focus or keyboard: the second field'
  verify_spec
  [ "$status" -eq 1 ] || return 1
  echo "$output" | grep -F 'UAT-001 cites the phrase' | grep -qF 'the capability phrase must appear verbatim in its then-clause and contain a cue word of that capability' || return 1
  echo "$output" | grep -F 'UAT-002 cites the phrase' | grep -qF 'the capability phrase must appear verbatim in its then-clause and contain a cue word of that capability' || return 1
}

@test "capability: a strict sub-phrase of a longer then-clause passes" {
  one_uat_plan browser 'after saving, focus moves to the first field of the dialog' '- Browser capability (UAT-001): focus or keyboard: focus moves to the first field'
  verify_spec
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
}

@test "red twin: with the grounding inverted to the story direction the sub-phrase fixture exits 1" {
  one_uat_plan browser 'after saving, focus moves to the first field of the dialog' '- Browser capability (UAT-001): focus or keyboard: focus moves to the first field'
  scratch_verifier 's/phrase_is_word_bounded "\$phrase_text" "\$then_text" &&/[[ "$phrase_text" == *"$then_text"* ]] \&\&/'
  run bash "$SCRATCH_SCRIPT" "$PLAN" --spec "$SPEC"
  expect_refusal 'UAT-001 cites the phrase'
}

@test "capability: an empty phrase, a bare trailing colon and a mid-word start are refused as ungrounded" {
  one_uat_plan browser 'focus moves to the first field' '- Browser capability (UAT-001): focus or keyboard: '
  verify_spec
  expect_refusal 'UAT-001 cites the phrase'
  one_uat_plan browser 'focus moves to the first field' '- Browser capability (UAT-001): focus or keyboard:'
  verify_spec
  expect_refusal 'UAT-001 cites the phrase'
  echo "$output" | grep -qF 'not in the closed list' && return 1
  one_uat_plan browser 'focus moves to the first field' '- Browser capability (UAT-001): focus or keyboard: ocus moves'
  verify_spec
  expect_refusal 'UAT-001 cites the phrase'
}

@test "capability: a phrase holding a colon, an enclosing quote pair, backticks or a backslash passes" {
  one_uat_plan browser 'the hint: beside the field' '- Browser capability (UAT-001): layout or visual position: the hint: beside the field'
  verify_spec
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  one_uat_plan browser 'focus moves to the first field' '- Browser capability (UAT-001): focus or keyboard: "focus moves to the first field"'
  verify_spec
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  one_uat_plan browser 'focus moves to the first field' '- Browser capability (UAT-001): focus or keyboard: `focus moves to the first field`'
  verify_spec
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  one_uat_plan browser 'focus moves to a\b' '- Browser capability (UAT-001): focus or keyboard: focus moves to a\b'
  verify_spec
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
}

@test "capability: a token with different case is refused as unknown" {
  one_uat_plan browser 'focus moves to the first field' '- Browser capability (UAT-001): Focus or keyboard: focus moves to the first field'
  verify_spec
  expect_refusal "UAT-001 names browser capability 'Focus or keyboard', which is not in the closed list"
}

@test "capability: the line in a second task doc, not the one holding the story line, satisfies the row" {
  one_uat_plan browser 'focus moves to the first field'
  printf '# Other\n\n- Browser capability (UAT-001): focus or keyboard: focus moves to the first field\n' >"$PLAN/task-two.md"
  verify_spec
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
}

@test "capability: with several lines the row passes when any one validates" {
  one_uat_plan browser 'focus moves to the first field' '- Browser capability (UAT-001): hover: nothing
- Browser capability (UAT-001): focus or keyboard: focus moves to the first field'
  verify_spec
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
}

js_disabled_case() {
  one_uat_plan browser 'focus moves to the first field' '- Browser capability (UAT-001): focus or keyboard: focus moves to the first field' "$1"
  verify_spec
}

@test "JavaScript-disabled Given: JavaScript is disabled is refused" {
  js_disabled_case 'JavaScript is disabled'
  expect_refusal 'UAT-001 is routed browser but its Given says JavaScript is disabled; a JavaScript-disabled UAT routes by the ladder'"'"'s route and real-server steps'
}

@test "JavaScript-disabled Given: JS off is refused" {
  js_disabled_case 'a visitor with JS off'
  expect_refusal 'a JavaScript-disabled UAT routes by the ladder'"'"'s route and real-server steps'
}

@test "JavaScript-disabled Given: JavaScript turned off is refused" {
  js_disabled_case 'a visitor with JavaScript turned off'
  expect_refusal 'a JavaScript-disabled UAT routes by the ladder'"'"'s route and real-server steps'
}

@test "JavaScript-disabled Given: JavaScript not enabled is refused" {
  js_disabled_case 'JavaScript not enabled'
  expect_refusal 'a JavaScript-disabled UAT routes by the ladder'"'"'s route and real-server steps'
}

@test "JavaScript-disabled Given: the hyphenated JavaScript-disabled is refused" {
  js_disabled_case 'a JavaScript-disabled browser'
  expect_refusal 'a JavaScript-disabled UAT routes by the ladder'"'"'s route and real-server steps'
}

@test "JavaScript-disabled Given: without JavaScript is refused" {
  js_disabled_case 'a visitor without JavaScript'
  expect_refusal 'a JavaScript-disabled UAT routes by the ladder'"'"'s route and real-server steps'
}

@test "JavaScript-disabled Given: no-JS is refused" {
  js_disabled_case 'a no-JS visitor'
  expect_refusal 'a JavaScript-disabled UAT routes by the ladder'"'"'s route and real-server steps'
}

@test "JavaScript-disabled Given: JavaScript enabled and a JSON body are not refused" {
  js_disabled_case 'a visitor with JavaScript enabled'
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  js_disabled_case 'a JSON body is posted'
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
}

@test "JavaScript-disabled Given: the console shows no JavaScript errors is refused, the false positive the header documents" {
  js_disabled_case 'the console shows no JavaScript errors'
  expect_refusal 'a JavaScript-disabled UAT routes by the ladder'"'"'s route and real-server steps'
  grep -qF 'no JavaScript errors' "$SCRIPT" || return 1
}

@test "a browser row with a layout capability draws no warning and exits 0" {
  one_uat_plan browser 'the error message shows beside its field' '- Browser capability (UAT-001): layout or visual position: beside its field'
  verify_spec
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  echo "$output" | grep -qE '^WARN: UAT-001' && return 1
  true
}

@test "red twin: a re-inserted rendered-word warning arm makes the same fixture print a warning" {
  one_uat_plan browser 'the error message shows beside its field' '- Browser capability (UAT-001): layout or visual position: beside its field'
  scratch_verifier 's/^          browser_row_check \(.*\)$/          printf "WARN: %s is routed browser but its then-clause names only server-rendered text\\n" "$uat_id" >\&2; browser_row_check \1/'
  run bash "$SCRATCH_SCRIPT" "$PLAN" --spec "$SPEC"
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
  echo "$output" | grep -qE '^WARN: UAT-001' || return 1
}

# guard_twin <sed-expression> <fixture-fn>: the fixture fails on the real
# script and passes once the guard is replaced by a no-op.
guard_twin() {
  "$2"
  verify_spec
  [ "$status" -eq 1 ] || { echo "$output" >&2; return 1; }
  scratch_verifier "$1"
  run bash "$SCRATCH_SCRIPT" "$PLAN" --spec "$SPEC"
  [ "$status" -eq 0 ] || { echo "$output" >&2; return 1; }
}

fixture_without_line() {
  one_uat_plan browser 'focus moves to the first field'
}

fixture_unknown_capability() {
  one_uat_plan browser 'focus moves to the first field' '- Browser capability (UAT-001): hover: focus moves to the first field'
}

fixture_ungrounded_phrase() {
  one_uat_plan browser 'focus moves to the first field' '- Browser capability (UAT-001): focus or keyboard: the cursor lands'
}

fixture_javascript_disabled() {
  one_uat_plan browser 'focus moves to the first field' '- Browser capability (UAT-001): focus or keyboard: focus moves to the first field' 'JavaScript is disabled'
}

@test "red twin: without the missing-line refusal the no-line fixture exits 0" {
  guard_twin 's/^      fail "\$uat is routed browser but no task doc.*$/      :/' fixture_without_line
}

@test "red twin: without the unknown-capability refusal the fixture exits 0" {
  guard_twin 's/^    printf "%s names browser capability.*$/    :/' fixture_unknown_capability
}

@test "red twin: without the ungrounded refusal the fixture exits 0" {
  guard_twin 's/^  printf "%s cites the phrase.*$/  :/' fixture_ungrounded_phrase
}

@test "red twin: without the JavaScript-disabled refusal the fixture exits 0" {
  guard_twin 's/^    fail "\$uat is routed browser but its Given.*$/    :/' fixture_javascript_disabled
}

# header_lists_capabilities <script>: the header comment names every code
# token with its cue ERE, and no word-list label survives.
header_lists_capabilities() {
  local script="$1" header tokens cues token cue count=0
  header=$(awk '/^#/ { print; next } { exit }' "$script")
  tokens=$(capability_tokens_of "$script")
  cues=$(capability_cues_of "$script")
  while IFS= read -r token; do
    count=$((count + 1))
    cue=$(printf '%s\n' "$cues" | sed -n "${count}p")
    [ -n "$cue" ] || return 1
    printf '%s\n' "$header" | grep -qFx -- "#   capability: $token | cues: $cue" || { echo "header lacks $token" >&2; return 1; }
  done <<<"$tokens"
  [ "$count" -eq 5 ] || return 1
  [ "$(printf '%s\n' "$cues" | wc -l | tr -d ' ')" -eq 5 ] || return 1
  grep -qE 'CLIENT|RENDERED|STATUS|is routed browser but its then-clause names only' "$script" && return 1
  true
}

@test "the header lists the five capabilities with the code's own cue words and drops the word lists" {
  header_lists_capabilities "$SCRIPT"
}

@test "red twin: a header missing a token or carrying an altered cue ERE fails the header check" {
  scratch_verifier '/^#   capability: focus or keyboard/d'
  run header_lists_capabilities "$SCRATCH_SCRIPT"
  [ "$status" -ne 0 ]
  scratch_verifier '/^#   capability: focus or keyboard/s/tab key$/tab keyz/'
  run header_lists_capabilities "$SCRATCH_SCRIPT"
  [ "$status" -ne 0 ]
}
