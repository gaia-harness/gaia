#!/usr/bin/env bats
#
# .gaia/scripts/spec/orchestrator-render.sh behavior: a spec-derived and a
# spec-less render (sentinels once each in template order, flow-checks only
# with --spec, literal substitution of values holding & and backslash, the
# double-brace tokens and phase entries kept, a flag holding a newline
# refused), the part refusals that leave both outputs unchanged, and the
# restore of the first output when the second replace fails. The script path
# defaults to the real one; ORCHESTRATOR_RENDER_SCRIPT points the suite at a
# scratch copy.
#
# Assertion style follows .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT_REAL="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SCRIPT="${ORCHESTRATOR_RENDER_SCRIPT:-$REPO_ROOT_REAL/.gaia/scripts/spec/orchestrator-render.sh}"
  VERIFY="$REPO_ROOT_REAL/.gaia/scripts/spec/plan-verify.sh"
  TEMPLATE_MD="$REPO_ROOT_REAL/.claude/skills/gaia/references/plan/orchestrator-template.md"
  WORK="$BATS_TEST_TMPDIR/work"
  PARTS="$WORK/parts.md"
  SPEC="$WORK/SPEC.md"
  FLOW_TEST_PATH='.gaia/tests/lib/refuse-uats-spec.bats'
  mkdir -p "$WORK"
  write_parts
  write_spec
}

# write_parts: a parts file whose second phase entry runs the flow test.
write_parts() {
  cat >"$PARTS" <<EOF2
## Title

Sample plan
Type: feat
Slug: sample thing

## Phase loop

Loop text.

## Phase entries

**Phase 1, Build**

- Tasks: \`task-build\`

**Phase 2, Flow**

- Tasks: \`task-flow-command\`
- Run: \`bash .gaia/scripts/bats5.sh $FLOW_TEST_PATH < /dev/null\`

## Kickoff goal

Goal text.

## Kickoff outline

Outline text.
EOF2
}

write_spec() {
  cat >"$SPEC" <<EOF2
---
spec_id: SPEC-901
flows:
  - flow_id: FLOW-902
    slug: refuse-uats-spec
    name: The plan check refuses a SPEC
    why: A silent pass
    test_path: $FLOW_TEST_PATH
---

# Sample
EOF2
}

# write_plan <dir> <spec|spec-less>: the plan folder files plan-verify reads.
write_plan() {
  local dir="$1"
  mkdir -p "$dir"
  if [ "$2" = spec ]; then
    printf '# Plan\n\n| Phase | Tasks | Model | Split |\n|---|---|---|---|\n| Phase 1 | `task-build` | sonnet | none |\n| Phase 2 | `task-flow-command` | sonnet | none |\n' >"$dir/README.md"
    printf '# t\n\n- Flow test (FLOW-902): %s\n' "$FLOW_TEST_PATH" >"$dir/task-flow-command.md"
    echo 'status: ran' >"$dir/TEST-STAGE"
  else
    printf '# Plan\n\n| Phase | Tasks | Model | Split |\n|---|---|---|---|\n| Phase 1 | `task-build` | sonnet | none |\n' >"$dir/README.md"
  fi
  echo '# t' >"$dir/task-build.md"
}

# sentinel_lines <file>: every sentinel line of the file, trimmed, in file order.
sentinel_lines() {
  awk '{ t = $0; sub(/^[ \t]+/, "", t); sub(/[ \t\r]+$/, "", t) }
    t ~ /^<!-- gaia:orchestrator-step [a-z-]+ -->$/ { print t }' "$1"
}

# the template's sentinels in order; spec-less drops flow-checks.
expected_sentinels() {
  if [ "$1" = spec ]; then
    sentinel_lines "$TEMPLATE_MD"
  else
    sentinel_lines "$TEMPLATE_MD" | grep -vF -- 'flow-checks'
  fi
}

# expected_lines <kind> <plan> <branch> <spec>: every template line below the
# first region marker that holds a plan token and that this kind of render
# emits (a spec run only with a SPEC; this fixture has no audit or pushes run),
# with every token replaced by the value this suite renders with, literally.
# The values ride in the environment because awk -v would interpret backslashes.
expected_lines() {
  EXPECT_PLAN="$2" EXPECT_BRANCH="$3" EXPECT_SPEC="$4" awk -v kind="$1" '
    function replace_all(text, token, value,    out, at) {
      out = ""
      while ((at = index(text, token)) > 0) {
        out = out substr(text, 1, at - 1) value
        text = substr(text, at + length(token))
      }
      return out text
    }
    /^<!-- gaia:template orchestrator -->$/ { in_template = 1 }
    /^<!-- gaia:render-if / { skipping = ($0 !~ /render-if spec/ || kind != "spec"); next }
    /^<!-- gaia:render-end -->$/ { skipping = 0; next }
    in_template && !skipping && $0 ~ /\{(PLAN_DIR|SPEC_PATH|BRANCH_ID)\}/ {
      line = replace_all($0, "{PLAN_DIR}", ENVIRON["EXPECT_PLAN"])
      line = replace_all(line, "{BRANCH_ID}", ENVIRON["EXPECT_BRANCH"])
      line = replace_all(line, "{SPEC_PATH}", ENVIRON["EXPECT_SPEC"])
      line = replace_all(line, "{TITLE}", "Sample plan")
      line = replace_all(line, "{BRANCH_TYPE}", "feat")
      line = replace_all(line, "{BRANCH_SLUG}", "sample thing")
      line = replace_all(line, "{PHASE_COUNT}", "2")
      print line
    }' "$TEMPLATE_MD"
}

@test "a spec-derived and a spec-less render each carry the sentinels once in template order (flow-checks only with --spec) and pass plan-verify, substitute values holding & and backslash byte for byte, keep double-brace tokens and phase entries, refuse a flag holding a newline, and a leftover branch token fails plan-verify" {
  local tricky_base='a&b\c' branch='br&x\y' kind plan expected actual
  for kind in spec spec-less; do
    plan="$BATS_TEST_TMPDIR/$kind/$tricky_base"
    write_plan "$plan" "$kind"
    if [ "$kind" = spec ]; then
      run bash "$SCRIPT" "$plan" --parts "$PARTS" --audit unset --branch "$branch" --spec "$SPEC"
    else
      run bash "$SCRIPT" "$plan" --parts "$PARTS" --audit unset --branch "$branch"
    fi
    [ "$status" -eq 0 ] || { echo "$kind render: $output"; return 1; }
    [ -z "$output" ] || { echo "$kind render printed: $output"; return 1; }

    expected="$(expected_sentinels "$kind")"
    actual="$(sentinel_lines "$plan/ORCHESTRATOR.md")"
    [ -n "$expected" ] || return 1
    [ "$actual" = "$expected" ] || { echo "$kind sentinels differ: expected [$expected] got [$actual]"; return 1; }
    if [ "$kind" = spec-less ]; then
      grep -qF -- 'orchestrator-step flow-checks' "$plan/ORCHESTRATOR.md" && return 1
    fi

    # Values holding & and backslash land byte for byte.
    grep -qF -- "$plan" "$plan/ORCHESTRATOR.md" || { echo "$kind: plan path not byte for byte"; return 1; }
    grep -qF -- "$branch" "$plan/ORCHESTRATOR.md" "$plan/KICKOFF.md" || { echo "$kind: branch id not byte for byte"; return 1; }
    local checked_value expected_line checked_lines
    for checked_value in "$branch" "$plan"; do
      checked_lines="$(expected_lines "$kind" "$plan" "$branch" "$SPEC" | grep -F -- "$checked_value")"
      [ -n "$checked_lines" ] || { echo "$kind: no template line holds $checked_value"; return 1; }
      while IFS= read -r expected_line; do
        grep -qFx -- "$expected_line" "$plan/ORCHESTRATOR.md" "$plan/KICKOFF.md" || { echo "$kind: line not byte for byte: $expected_line"; return 1; }
      done <<<"$checked_lines"
    done

    # Double-brace tokens the template holds pass through; phase entries land verbatim.
    local token
    for token in '{{SUBJECT}}' '{{WORKER}}' '{{OWNER}}' '{{SIBLING}}'; do
      if grep -qF -- "$token" "$TEMPLATE_MD"; then
        grep -qF -- "$token" "$plan/ORCHESTRATOR.md" "$plan/KICKOFF.md" || { echo "$kind: $token dropped"; return 1; }
      fi
    done
    grep -qF -- '**Phase 1, Build**' "$plan/ORCHESTRATOR.md" || return 1
    grep -qF -- '**Phase 2, Flow**' "$plan/ORCHESTRATOR.md" || return 1

    if [ "$kind" = spec ]; then
      run bash "$VERIFY" "$plan" --spec "$SPEC"
    else
      run bash "$VERIFY" "$plan"
    fi
    [ "$status" -eq 0 ] || { echo "$kind plan-verify: $output"; return 1; }
  done

  # A flag holding a newline is refused with its exact line.
  run bash "$SCRIPT" "$BATS_TEST_TMPDIR/spec/$tricky_base" --parts "$PARTS" --audit unset --branch $'a\nb'
  [ "$status" -eq 1 ] || return 1
  [ "$output" = 'orchestrator-render: --branch holds a newline' ] || { echo "$output"; return 1; }

  # A leftover branch token fails plan-verify.
  printf '{BRANCH_ID}\n' >>"$BATS_TEST_TMPDIR/spec-less/$tricky_base/ORCHESTRATOR.md"
  run bash "$VERIFY" "$BATS_TEST_TMPDIR/spec-less/$tricky_base"
  [ "$status" -eq 1 ] || return 1
  grep -qF -- '{BRANCH_ID}' <<<"$output" || { echo "$output"; return 1; }
  true
}

# parts_without <heading>: the parts file minus the whole part under that heading.
parts_without() {
  awk -v drop="$1" '
    /^## / { skipping = ($0 == drop) }
    !skipping { print }' "$PARTS"
}

@test "refuses a parts file missing any required part, carrying an unknown part or a part holding a sentinel, with the exact line and both outputs unchanged" {
  local plan="$BATS_TEST_TMPDIR/plan" heading before_orchestrator before_kickoff cases=0 bad
  write_plan "$plan" spec-less
  run bash "$SCRIPT" "$plan" --parts "$PARTS" --audit unset --branch plan-x
  [ "$status" -eq 0 ] || return 1
  before_orchestrator="$(shasum -a 256 "$plan/ORCHESTRATOR.md")"
  before_kickoff="$(shasum -a 256 "$plan/KICKOFF.md")"

  # One case per required heading, derived from the parts file.
  while IFS= read -r heading; do
    [ "$heading" != '## Pushes' ] || continue
    parts_without "$heading" >"$WORK/bad-parts.md"
    run bash "$SCRIPT" "$plan" --parts "$WORK/bad-parts.md" --audit unset --branch plan-x
    [ "$status" -eq 1 ] || { echo "$heading: status $status"; return 1; }
    [ "$output" = "orchestrator-render: missing part: $heading" ] || { echo "$heading: $output"; return 1; }
    cases=$((cases + 1))
  done < <(grep '^## ' "$PARTS")
  [ "$cases" -eq 5 ] || { echo "expected 5 required parts, saw $cases"; return 1; }

  # An unknown part.
  { cat "$PARTS"; printf '\n## Mystery\n\nbody\n'; } >"$WORK/bad-parts.md"
  run bash "$SCRIPT" "$plan" --parts "$WORK/bad-parts.md" --audit unset --branch plan-x
  [ "$status" -eq 1 ] || return 1
  [ "$output" = 'orchestrator-render: unknown part: ## Mystery' ] || { echo "$output"; return 1; }

  # A part holding a sentinel line.
  bad='<!-- gaia:orchestrator-step resume-detection -->'
  { cat "$PARTS"; printf '\n## Pushes\n\n%s\n' "$bad"; } >"$WORK/bad-parts.md"
  run bash "$SCRIPT" "$plan" --parts "$WORK/bad-parts.md" --audit unset --branch plan-x
  [ "$status" -eq 1 ] || return 1
  [ "$output" = 'orchestrator-render: part ## Pushes holds a gaia:orchestrator-step sentinel' ] || { echo "$output"; return 1; }

  [ "$(shasum -a 256 "$plan/ORCHESTRATOR.md")" = "$before_orchestrator" ] || return 1
  [ "$(shasum -a 256 "$plan/KICKOFF.md")" = "$before_kickoff" ] || return 1
  [ -z "$(find "$plan" -name '.orchestrator-render.*')" ] || return 1
  true
}

@test "leaves ORCHESTRATOR.md and KICKOFF.md byte-identical when the second replace fails" {
  local plan="$BATS_TEST_TMPDIR/plan" before_orchestrator
  write_plan "$plan" spec-less
  run bash "$SCRIPT" "$plan" --parts "$PARTS" --audit unset --branch plan-x
  [ "$status" -eq 0 ] || return 1

  # KICKOFF.md becomes a directory, so replacing it fails after ORCHESTRATOR.md
  # was replaced; the changed title makes an unrestored first output differ.
  rm -f "$plan/KICKOFF.md"
  mkdir "$plan/KICKOFF.md"
  before_orchestrator="$(shasum -a 256 "$plan/ORCHESTRATOR.md")"
  sed 's/^Sample plan$/A different title/' "$PARTS" >"$WORK/changed-parts.md"
  run bash "$SCRIPT" "$plan" --parts "$WORK/changed-parts.md" --audit unset --branch plan-x
  [ "$status" -ne 0 ] || return 1
  [ "$output" = "orchestrator-render: cannot write $plan/KICKOFF.md" ] || { echo "$output"; return 1; }
  [ "$(shasum -a 256 "$plan/ORCHESTRATOR.md")" = "$before_orchestrator" ] || return 1
  [ -d "$plan/KICKOFF.md" ] || return 1
  [ -z "$(find "$plan" -maxdepth 1 -name '.orchestrator-render.*')" ] || return 1
  true
}
