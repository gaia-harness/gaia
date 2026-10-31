#!/usr/bin/env bats
#
# .gaia/scripts/spec/plan-verify.sh behavior: existence checks, the routing
# table, the story test criterion line, the orchestrator step
# sentinels (match rule, order rule, per-arm requirements), the verbatim
# blocks (yield handling, worthiness step, wiki promotion, code audit and
# post-clearance), failure aggregation and the misrouting warning. Shell
# level only.
#
# Assertion style follows .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT_REAL="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SCRIPT="$REPO_ROOT_REAL/.gaia/scripts/spec/plan-verify.sh"
  PLAN="$BATS_TEST_TMPDIR/plan"
  SPEC="$BATS_TEST_TMPDIR/SPEC.md"
  PLANNER_MD="$REPO_ROOT_REAL/.claude/skills/gaia/references/plan/planner.md"
  mkdir -p "$PLAN"
  S_RENDER='<!-- gaia:orchestrator-step uat-render -->'
  S_GATE='<!-- gaia:orchestrator-step uat-gate -->'
  S_YIELD='<!-- gaia:orchestrator-step yield-handling -->'
  S_PRE='<!-- gaia:orchestrator-step uat-pre-audit -->'
  S_WORTH='<!-- gaia:orchestrator-step worthiness-step -->'
  S_WIKI='<!-- gaia:orchestrator-step wiki-promotion -->'
  S_AUDIT='<!-- gaia:orchestrator-step code-audit -->'
  S_CLEAR='<!-- gaia:orchestrator-step post-clearance -->'
  S_CLOSE='<!-- gaia:orchestrator-step post-merge-close -->'
  SPEC_ORDER=("$S_RENDER" "$S_GATE" "$S_YIELD" "$S_PRE" "$S_WORTH" "$S_WIKI" "$S_AUDIT" "$S_CLEAR" "$S_CLOSE")
  SPEC_LESS_ORDER=("$S_YIELD" "$S_WORTH" "$S_WIKI" "$S_AUDIT" "$S_CLEAR" "$S_CLOSE")
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
    then: the confirmation page shows the order number
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
| UAT-001 | e2e | 2 | checkout | guest-checkout-confirms-order.spec.ts |
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
    "$S_YIELD" | "$S_WORTH" | "$S_WIKI" | "$S_AUDIT" | "$S_CLEAR") return 0 ;;
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
}

# spec_less_fixture: a passing spec-less plan folder.
spec_less_fixture() {
  printf '# Plan\n' >"$PLAN/README.md"
  write_orchestrator "${SPEC_LESS_ORDER[@]}"
  printf '# Kickoff\n' >"$PLAN/KICKOFF.md"
  write_task '- nothing'
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
  [ "${#SPEC_ORDER[@]}" -eq 9 ]
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

@test "a spec-less plan does not require the UAT sentinels but requires the other six" {
  local literal
  spec_less_fixture
  verify_spec_less
  [ "$status" -eq 0 ]
  [ "${#SPEC_LESS_ORDER[@]}" -eq 6 ]
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
    printf '      %s\n\n' "$S_RENDER" "$S_GATE"
    yield_block 6
    printf '\n      %s\n\n' "$S_PRE"
    for literal in "$S_WORTH" "$S_WIKI" "$S_AUDIT" "$S_CLEAR"; do
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
  write_orchestrator "$S_RENDER" "$S_GATE" "$S_YIELD" "$S_PRE" "$S_WORTH" "$S_WIKI" "$S_AUDIT" "$S_CLEAR" "$S_CLOSE see below"
  verify_spec
  [ "$status" -eq 1 ]
  echo "$output" | grep -qF -- "$S_CLOSE"
}

@test "the render sentinel below the gate sentinel is out of order and named" {
  spec_fixture
  write_orchestrator "$S_GATE" "$S_RENDER" "$S_YIELD" "$S_PRE" "$S_WORTH" "$S_WIKI" "$S_AUDIT" "$S_CLEAR" "$S_CLOSE"
  verify_spec
  [ "$status" -eq 1 ]
  echo "$output" | grep -F 'out of order' | grep -qF -- "$S_RENDER"
}

@test "a spec-less plan with the close sentinel above the promotion sentinel fails" {
  spec_less_fixture
  write_orchestrator "$S_YIELD" "$S_WORTH" "$S_CLOSE" "$S_WIKI" "$S_AUDIT" "$S_CLEAR"
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
    printf '      %s\n\n' "$S_RENDER" "$S_GATE"
    yield_block 6
    printf '\n      %s\n\n' "$S_PRE"
    for literal in "$S_WORTH" "$S_WIKI" "$S_AUDIT" "$S_CLEAR"; do
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
    yield_block 6
    printf '\n'
    for literal in "$S_WORTH" "$S_WIKI" "$S_AUDIT" "$S_CLEAR"; do
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
  write_orchestrator "$S_RENDER" "$S_YIELD" "$S_GATE" "$S_PRE" "$S_WORTH" "$S_WIKI" "$S_AUDIT" "$S_CLEAR" "$S_CLOSE"
  verify_spec
  [ "$status" -eq 1 ]
  echo "$output" | grep -F 'out of order' | grep -qF -- "$S_GATE"
}

@test "red twin: a planner.md without the fenced block fails naming planner.md" {
  local tree="$BATS_TEST_TMPDIR/tree"
  mkdir -p "$tree/.gaia/scripts/spec" "$tree/.claude/skills/gaia/references/plan"
  cp "$SCRIPT" "$REPO_ROOT_REAL/.gaia/scripts/spec/uat-lib.sh" "$tree/.gaia/scripts/spec/"
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

# ---------- the other verbatim blocks and the order of the six late sentinels ----------

@test "red twin: each adjacent swap among the late sentinels is out of order and named" {
  local order=("$S_PRE" "$S_WORTH" "$S_WIKI" "$S_AUDIT" "$S_CLEAR" "$S_CLOSE") index swapped
  [ "${#order[@]}" -eq 6 ]
  index=0
  while [ "$index" -lt 5 ]; do
    swapped=("${order[@]}")
    swapped[index]="${order[$((index + 1))]}"
    swapped[$((index + 1))]="${order[$index]}"
    spec_fixture
    write_orchestrator "$S_RENDER" "$S_GATE" "$S_YIELD" "${swapped[@]}"
    verify_spec
    [ "$status" -eq 1 ] || { echo "swap at $index exited $status" >&2; return 1; }
    echo "$output" | grep -F 'out of order' | grep -qF -- "${order[$index]}" || { echo "swap at $index not named: $output" >&2; return 1; }
    index=$((index + 1))
  done
}

@test "red twin: a reworded line in each new block fails naming the line and the block" {
  local entry name from to line
  for entry in \
    'worthiness-step|skip-safe|resumable' \
    'wiki-promotion|no re-consolidation|maybe re-consolidation' \
    'code-audit|the late pass from|the early pass from' \
    'post-clearance|costs no commit|costs a commit'; do
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
  cp "$SCRIPT" "$REPO_ROOT_REAL/.gaia/scripts/spec/uat-lib.sh" "$MARKER_TREE/.gaia/scripts/spec/"
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
