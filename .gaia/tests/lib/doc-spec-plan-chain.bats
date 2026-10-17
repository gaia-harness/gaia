#!/usr/bin/env bats
#
# Doc-conformance suite for the spec-to-plan chain. `/gaia-spec` step 11 plans
# the SPEC in the same session through the `Skill` tool and stops at the plan's
# KICKOFF report, and `/gaia-plan` reads a leading `auto` token.
#
# The invariants:
#   s. the spec playbook's step 11 carries the heading, the Skill call (bare id
#      and `auto` form), no direct planning, the recovery command as its only
#      handoff text, a hard constraint 6 that allows the chain and keeps the
#      execution stop, none of the retired terminal-handoff literals, and the
#      auto-mode rule that makes step 11 chain;
#   c. the /gaia-spec command description says it plans in the same session;
#   p. the plan playbook parses the `auto` token (argument section, step 2,
#      step 4.6, step 4.6b) and the /gaia-plan command advertises it;
#   w. the wiki pages and index no longer state the retired terminal handoff.
#
# Every check is a function taking a root laid out like the repository, so each
# red twin runs the same function against a mutated scratch copy. An empty
# extracted section fails; it never passes vacuously.
#
# Assertion style: .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  CHAIN_ROOT="${DOC_SPEC_PLAN_CHAIN_ROOT:-$REPO_ROOT}"
  REFS='.claude/skills/gaia/references'
  SPEC_MD="$REFS/spec.md"
  PLAN_MD="$REFS/plan.md"
  AUDIT_MD="$REFS/plan/decomposition-audit.md"
  SPEC_CMD='.claude/commands/gaia-spec.md'
  PLAN_CMD='.claude/commands/gaia-plan.md'
  WIKI_INDEX='wiki/index.md'
  WIKI_SPEC='wiki/concepts/GAIA Spec.md'
  WIKI_PLAN='wiki/concepts/GAIA Plan.md'
  WIKI_ORCH='wiki/concepts/Task Orchestration.md'
  ABORT_LITERAL='"/gaia-plan auto requires a description. Re-invoke as: /gaia-plan auto <description>"'
  SCRATCH_FILES=("$SPEC_MD" "$PLAN_MD" "$AUDIT_MD" "$SPEC_CMD" "$PLAN_CMD" "$WIKI_INDEX" "$WIKI_SPEC" "$WIKI_PLAN" "$WIKI_ORCH")
}

# scratch_copy: copies only the files the suite reads into a scratch root laid
# out like the repository, and prints the root.
scratch_copy() {
  local copy="$BATS_TEST_TMPDIR/root" rel
  rm -rf "$copy"
  for rel in "${SCRATCH_FILES[@]}"; do
    mkdir -p "$copy/$(dirname "$rel")"
    cp "$CHAIN_ROOT/$rel" "$copy/$rel"
  done
  printf '%s\n' "$copy"
}

# --- section and mutation helpers -------------------------------------------

# section <file> <start-regex> [end-regex]: prints from the first line matching
# start up to (not including) the next line matching end, or to end of file.
section() {
  awk -v s="$2" -v e="${3:-}" '
    !f && $0 ~ s { f = 1; print; next }
    f && e != "" && $0 ~ e { exit }
    f
  ' "$1"
}

# nonempty_section <label> <text>: fails when the extraction came back empty.
nonempty_section() {
  if [ -z "$2" ]; then
    printf 'empty section: %s\n' "$1" >&2
    return 1
  fi
}

# step11 <root>: from the step 11 heading to end of file.
step11() {
  awk '/^### 11\. /{f=1} f' "$1/$SPEC_MD"
}

# constraint6 <root>: the hard constraint 6 item line.
constraint6() {
  section "$1/$SPEC_MD" '^## Hard constraints' '^## Operational primitives' | grep -E '^6\. \*\*' | head -n 1
}

# auto_region <root>: the spec playbook's auto-mode rules.
auto_region() {
  section "$1/$SPEC_MD" '^## Auto mode$' '^## Hard constraints'
}

# require_all <label> <text> <literal>...: fails naming the first missing one.
require_all() {
  local label="$1" text="$2" literal
  shift 2
  for literal in "$@"; do
    if ! printf '%s\n' "$text" | grep -qF -- "$literal"; then
      printf '%s lacks: %s\n' "$label" "$literal" >&2
      return 1
    fi
  done
}

# forbid_all <label> <text> <literal>...: fails naming the first one present.
forbid_all() {
  local label="$1" text="$2" literal
  shift 2
  for literal in "$@"; do
    if printf '%s\n' "$text" | grep -qF -- "$literal"; then
      printf '%s still holds: %s\n' "$label" "$literal" >&2
      return 1
    fi
  done
}

# edit_literal <file> <from> <to>: replaces every occurrence; fails when the
# literal is absent so a mutation can never be a silent no-op.
edit_literal() {
  local file="$1" from="$2" to="$3" content
  content="$(cat "$file")"
  case "$content" in
    *"$from"*) ;;
    *) printf 'mutation target missing in %s: %s\n' "$file" "$from" >&2; return 1 ;;
  esac
  printf '%s\n' "${content//"$from"/"$to"}" >"$file"
}

# replace_in_section <file> <start-regex> <end-regex-or-empty> <from> <to>:
# replaces a literal only inside the section; fails when nothing changed.
replace_in_section() {
  local file="$1" start="$2" end="$3" from="$4" to="$5" out="$1.new"
  awk -v s="$start" -v e="$end" -v from="$from" -v to="$to" '
    !over {
      if (!f && $0 ~ s) { f = 1 }
      else if (f && e != "" && $0 ~ e) { f = 0; over = 1 }
    }
    f {
      out = ""; rest = $0
      while ((n = index(rest, from)) > 0) { out = out substr(rest, 1, n - 1) to; rest = substr(rest, n + length(from)); changed = 1 }
      $0 = out rest
    }
    { print }
    END { if (!changed) exit 3 }
  ' "$file" >"$out" || { rm -f "$out"; printf 'mutation target missing in section: %s\n' "$from" >&2; return 1; }
  mv "$out" "$file"
}

# --- s. spec playbook step 11 ------------------------------------------------

check_s1() {
  local root="$1"
  grep -qxF -- '### 11. Plan the SPEC in this session' "$root/$SPEC_MD" || { printf 'step 11 heading is not exact\n' >&2; return 1; }
  [ "$(grep -c '^### ' "$root/$SPEC_MD")" -ge 1 ] || return 1
  [ "$(grep '^### ' "$root/$SPEC_MD" | tail -n 1)" = '### 11. Plan the SPEC in this session' ] || { printf 'step 11 is not the last section\n' >&2; return 1; }
}

check_s2() {
  local text
  text="$(step11 "$1")"
  nonempty_section 'step 11' "$text" || return 1
  require_all 'step 11' "$text" 'the `Skill` tool' '`skill: "gaia-plan"`' '`args: "SPEC-NNN"`' '`args: "auto SPEC-NNN"`'
}

check_s3() {
  local text
  text="$(step11 "$1")"
  nonempty_section 'step 11' "$text" || return 1
  forbid_all 'step 11' "$text" 'plan.md' 'planner.md' 'general-purpose' '/clear' || return 1
  if printf '%s\n' "$text" | grep -qwF -- Agent; then
    printf 'step 11 still holds the word: Agent\n' >&2
    return 1
  fi
}

check_s4() {
  local text count verdict
  text="$(step11 "$1")"
  nonempty_section 'step 11' "$text" || return 1
  count="$(printf '%s\n' "$text" | grep -cF -- '/gaia-plan SPEC-NNN' || true)"
  [ "$count" -eq 1 ] || { printf 'step 11 holds %s recovery lines, want 1\n' "$count" >&2; return 1; }
  verdict="$(printf '%s\n' "$text" | awk '
    index($0, "**If the plan run stops before its report.**") == 1 { label = 1 }
    /^```/ {
      if (infence) { infence = 0 } else { infence = 1; valid = (label && $0 == "```text") }
      next
    }
    index($0, "/gaia-plan SPEC-NNN") { print (infence && valid) ? "ok" : "bad" }
  ')"
  [ "$verdict" = ok ] || { printf 'recovery line is not in a text fence after the recovery label\n' >&2; return 1; }
}

check_s5() {
  local line
  line="$(constraint6 "$1")"
  nonempty_section 'hard constraint 6' "$line" || return 1
  require_all 'constraint 6' "$line" '**This holds no matter what the instruction that reached this skill asked for.**' 'KICKOFF' || return 1
  forbid_all 'constraint 6' "$line" 'Never chain' 'terminal'
}

check_s6() {
  local text
  text="$(cat "$1/$SPEC_MD")"
  nonempty_section 'spec playbook' "$text" || return 1
  forbid_all 'spec playbook' "$text" \
    'Never chain into' \
    'This skill is terminal' \
    'To plan it, /clear and paste' \
    'never a command you run' \
    'do not plan anything' \
    'neither runs plan' \
    '11 /gaia-plan handoff, then STOP' \
    'Downstream (plan → implement → merge) owns the feature'
}

check_s7() {
  local region line
  region="$(auto_region "$1")"
  nonempty_section 'auto mode region' "$region" || return 1
  line="$(printf '%s\n' "$region" | grep -E '^13\. \*\*Step 11 chains in auto mode\.\*\*' || true)"
  nonempty_section 'auto-mode rule 13' "$line" || return 1
  require_all 'rule 13' "$line" '`auto SPEC-NNN`'
}

# --- c. command description --------------------------------------------------

check_c1() {
  local line
  line="$(grep -m 1 '^description:' "$1/$SPEC_CMD" || true)"
  nonempty_section 'gaia-spec description' "$line" || return 1
  require_all 'gaia-spec description' "$line" 'then plans it in the same session' || return 1
  forbid_all 'gaia-spec description' "$line" 'Never runs /gaia-plan' 'pastes into a fresh session'
}

# --- p. plan playbook --------------------------------------------------------

check_p1() {
  local file="$1/$PLAN_MD" heading steps
  heading="$(grep -nxF -- '## Argument parsing' "$file" | head -n 1 | cut -d: -f1)"
  steps="$(grep -nE '^## Steps' "$file" | head -n 1 | cut -d: -f1)"
  [ -n "$heading" ] || { printf 'no ## Argument parsing heading\n' >&2; return 1; }
  [ -n "$steps" ] || { printf 'no ## Steps heading\n' >&2; return 1; }
  [ "$heading" -lt "$steps" ] || { printf 'argument parsing does not precede steps\n' >&2; return 1; }
}

args_section() {
  section "$1/$PLAN_MD" '^## Argument parsing$' '^## Steps'
}

check_p2() {
  local text
  text="$(args_section "$1")"
  nonempty_section 'argument parsing' "$text" || return 1
  require_all 'argument parsing' "$text" '`auto_mode = true`' '`auto_mode = false`' "$ABORT_LITERAL"
}

check_p3() {
  local text
  text="$(args_section "$1")"
  nonempty_section 'argument parsing' "$text" || return 1
  require_all 'argument parsing' "$text" '$ARGUMENTS' 'remainder'
}

check_p4() {
  local text
  text="$(section "$1/$PLAN_MD" '^### 2\. ' '^### ')"
  nonempty_section 'step 2' "$text" || return 1
  require_all 'step 2' "$text" 'auto_mode'
}

check_p5() {
  local text
  text="$(section "$1/$PLAN_MD" '^### 4\.6\. ' '^### ')"
  nonempty_section 'step 4.6' "$text" || return 1
  require_all 'step 4.6' "$text" 'auto_mode'
}

check_p6() {
  grep -qxF -- 'argument-hint: "[auto] [feature description]"' "$1/$PLAN_CMD" || { printf 'gaia-plan argument-hint is not exact\n' >&2; return 1; }
}

check_p7() {
  local text
  text="$(section "$1/$AUDIT_MD" '^## 4\.6b\. ')"
  nonempty_section 'step 4.6b' "$text" || return 1
  require_all 'step 4.6b' "$text" 'auto_mode'
}

# --- w. wiki literals gone ---------------------------------------------------

check_w_index() {
  local text
  text="$(cat "$1/$WIKI_INDEX")"
  nonempty_section 'wiki index' "$text" || return 1
  forbid_all 'wiki index' "$text" 'a guard enforces the stop' 'printing a `/gaia-plan` prompt for a fresh session'
}

check_w_spec() {
  local text
  text="$(cat "$1/$WIKI_SPEC")"
  nonempty_section 'GAIA Spec page' "$text" || return 1
  forbid_all 'GAIA Spec page' "$text" 'Planning is always a new session' 'the downstream handoff target' 'pastes into a fresh [[GAIA Plan]] session'
}

check_w_orchestration() {
  local text
  text="$(cat "$1/$WIKI_ORCH")"
  nonempty_section 'Task Orchestration page' "$text" || return 1
  forbid_all 'Task Orchestration page' "$text" 'ends by printing a `/gaia-plan` handoff prompt and stops'
}

check_w_plan() {
  local text
  text="$(cat "$1/$WIKI_PLAN")"
  nonempty_section 'GAIA Plan page' "$text" || return 1
  forbid_all 'GAIA Plan page' "$text" 'the standard [[GAIA Spec]] handoff'
}

# --- green tests on the real tree --------------------------------------------

@test "step 11 heading is exact and step 11 is the last section" { check_s1 "$CHAIN_ROOT"; }
@test "step 11 invokes the gaia-plan skill with the bare and the auto args" { check_s2 "$CHAIN_ROOT"; }
@test "step 11 never plans directly" { check_s3 "$CHAIN_ROOT"; }
@test "step 11 holds the recovery command once, in a text fence after the recovery label" { check_s4 "$CHAIN_ROOT"; }
@test "hard constraint 6 allows the chain and keeps the execution stop" { check_s5 "$CHAIN_ROOT"; }
@test "the spec playbook holds none of the retired terminal-handoff literals" { check_s6 "$CHAIN_ROOT"; }
@test "auto mode carries the rule that makes step 11 chain" { check_s7 "$CHAIN_ROOT"; }
@test "the gaia-spec command description says it plans in the same session" { check_c1 "$CHAIN_ROOT"; }
@test "the plan playbook has an argument section before its steps" { check_p1 "$CHAIN_ROOT"; }
@test "the argument section sets both auto_mode values and the abort literal" { check_p2 "$CHAIN_ROOT"; }
@test "the argument section routes the remainder to steps 1 and 1a" { check_p3 "$CHAIN_ROOT"; }
@test "plan step 2 branches on auto_mode" { check_p4 "$CHAIN_ROOT"; }
@test "plan step 4.6 branches on auto_mode" { check_p5 "$CHAIN_ROOT"; }
@test "the gaia-plan command advertises the auto token" { check_p6 "$CHAIN_ROOT"; }
@test "plan step 4.6b branches on auto_mode" { check_p7 "$CHAIN_ROOT"; }
@test "the wiki index no longer states the terminal handoff" { check_w_index "$CHAIN_ROOT"; }
@test "the GAIA Spec page no longer states the terminal handoff" { check_w_spec "$CHAIN_ROOT"; }
@test "the Task Orchestration page no longer states the handoff-and-stop" { check_w_orchestration "$CHAIN_ROOT"; }
@test "the GAIA Plan page no longer calls the spec handoff standard" { check_w_plan "$CHAIN_ROOT"; }

# --- red twins ---------------------------------------------------------------

@test "red twin: renaming the step 11 heading fails the heading check" {
  copy="$(scratch_copy)"
  edit_literal "$copy/$SPEC_MD" '### 11. Plan the SPEC in this session' '### 11. Hand off'
  run check_s1 "$copy"
  [ "$status" -ne 0 ]
}

@test "red twin: deleting the auto args text fails the Skill call check" {
  copy="$(scratch_copy)"
  edit_literal "$copy/$SPEC_MD" '`args: "auto SPEC-NNN"`' ''
  run check_s2 "$copy"
  [ "$status" -ne 0 ]
}

@test "red twin: reading plan.md inside step 11 fails the no-direct-planning check" {
  copy="$(scratch_copy)"
  printf 'Read the plan.md reference now.\n' >>"$copy/$SPEC_MD"
  run check_s3 "$copy"
  [ "$status" -ne 0 ]
}

@test "red twin: the word Agent inside step 11 fails the no-direct-planning check" {
  copy="$(scratch_copy)"
  printf 'Dispatch an Agent to plan.\n' >>"$copy/$SPEC_MD"
  run check_s3 "$copy"
  [ "$status" -ne 0 ]
}

@test "red twin: a second fenced recovery command fails the single-handoff check" {
  copy="$(scratch_copy)"
  printf '\n```text\n/gaia-plan SPEC-NNN\n```\n' >>"$copy/$SPEC_MD"
  run check_s4 "$copy"
  [ "$status" -ne 0 ]
}

@test "red twin: moving the recovery fence above its label fails the single-handoff check" {
  copy="$(scratch_copy)"
  awk '
    { line[NR] = $0 }
    END {
      for (i = 1; i <= NR; i++) if (index(line[i], "**If the plan run stops before its report.**") == 1) { label = i; break }
      for (i = label; i <= NR; i++) if (line[i] == "```text") { fence = i; break }
      for (i = 1; i <= NR; i++) {
        if (i == label) { print line[fence]; print line[fence + 1]; print line[fence + 2]; print "" }
        if (i >= fence && i <= fence + 2) continue
        print line[i]
      }
    }
  ' "$copy/$SPEC_MD" >"$copy/spec.new"
  mv "$copy/spec.new" "$copy/$SPEC_MD"
  run check_s4 "$copy"
  [ "$status" -ne 0 ]
}

@test "red twin: restoring the never-chain clause on constraint 6 fails the constraint check" {
  copy="$(scratch_copy)"
  awk '/^## Hard constraints/ { f = 1 } f && !done && /^6\. \*\*/ { $0 = $0 " Never chain into /gaia-plan."; done = 1 } { print }' "$copy/$SPEC_MD" >"$copy/spec.new"
  mv "$copy/spec.new" "$copy/$SPEC_MD"
  run check_s5 "$copy"
  [ "$status" -ne 0 ]
}

@test "red twin: restoring the terminal wording on constraint 6 fails the constraint check" {
  copy="$(scratch_copy)"
  awk '/^## Hard constraints/ { f = 1 } f && !done && /^6\. \*\*/ { $0 = $0 " This skill is terminal."; done = 1 } { print }' "$copy/$SPEC_MD" >"$copy/spec.new"
  mv "$copy/spec.new" "$copy/$SPEC_MD"
  run check_s5 "$copy"
  [ "$status" -ne 0 ]
}

@test "red twin: each retired spec playbook literal fails the stale-literal check" {
  local literals=(
    'Never chain into'
    'This skill is terminal'
    'To plan it, /clear and paste'
    'never a command you run'
    'do not plan anything'
    'neither runs plan'
    '11 /gaia-plan handoff, then STOP'
    'Downstream (plan → implement → merge) owns the feature'
  )
  local literal
  for literal in "${literals[@]}"; do
    copy="$(scratch_copy)"
    printf '%s\n' "$literal" >>"$copy/$SPEC_MD"
    run check_s6 "$copy"
    [ "$status" -ne 0 ] || { printf 'check_s6 passed with: %s\n' "$literal" >&2; return 1; }
  done
}

@test "red twin: deleting auto-mode rule 13 fails the auto rule check" {
  copy="$(scratch_copy)"
  grep -vE '^13\. \*\*Step 11 chains in auto mode\.\*\*' "$copy/$SPEC_MD" >"$copy/spec.new"
  mv "$copy/spec.new" "$copy/$SPEC_MD"
  run check_s7 "$copy"
  [ "$status" -ne 0 ]
}

@test "red twin: moving rule 13 into step 11 fails the auto rule check" {
  copy="$(scratch_copy)"
  line="$(grep -E '^13\. \*\*Step 11 chains in auto mode\.\*\*' "$copy/$SPEC_MD")"
  grep -vE '^13\. \*\*Step 11 chains in auto mode\.\*\*' "$copy/$SPEC_MD" >"$copy/spec.new"
  printf '%s\n' "$line" >>"$copy/spec.new"
  mv "$copy/spec.new" "$copy/$SPEC_MD"
  run check_s7 "$copy"
  [ "$status" -ne 0 ]
}

@test "red twin: deleting step 11 entirely fails every step 11 check instead of passing" {
  copy="$(scratch_copy)"
  awk '/^### 11\. /{exit} {print}' "$copy/$SPEC_MD" >"$copy/spec.new"
  mv "$copy/spec.new" "$copy/$SPEC_MD"
  local name
  for name in check_s1 check_s2 check_s3 check_s4; do
    run "$name" "$copy"
    [ "$status" -ne 0 ] || { printf '%s passed on an empty step 11\n' "$name" >&2; return 1; }
  done
}

@test "red twin: restoring the never-runs wording fails the command description check" {
  copy="$(scratch_copy)"
  awk '!done && /^description:/ { $0 = $0 " Never runs /gaia-plan."; done = 1 } { print }' "$copy/$SPEC_CMD" >"$copy/cmd.new"
  mv "$copy/cmd.new" "$copy/$SPEC_CMD"
  run check_c1 "$copy"
  [ "$status" -ne 0 ]
}

@test "red twin: restoring the paste wording fails the command description check" {
  copy="$(scratch_copy)"
  awk '!done && /^description:/ { $0 = $0 " It pastes into a fresh session."; done = 1 } { print }' "$copy/$SPEC_CMD" >"$copy/cmd.new"
  mv "$copy/cmd.new" "$copy/$SPEC_CMD"
  run check_c1 "$copy"
  [ "$status" -ne 0 ]
}

@test "red twin: deleting the argument parsing heading fails the section check" {
  copy="$(scratch_copy)"
  grep -vxF -- '## Argument parsing' "$copy/$PLAN_MD" >"$copy/plan.new"
  mv "$copy/plan.new" "$copy/$PLAN_MD"
  run check_p1 "$copy"
  [ "$status" -ne 0 ]
}

@test "red twin: deleting the abort literal fails the argument literals check" {
  copy="$(scratch_copy)"
  edit_literal "$copy/$PLAN_MD" "$ABORT_LITERAL" ''
  run check_p2 "$copy"
  [ "$status" -ne 0 ]
}

@test "red twin: deleting remainder fails the argument routing check" {
  copy="$(scratch_copy)"
  edit_literal "$copy/$PLAN_MD" 'remainder' 'rest'
  run check_p3 "$copy"
  [ "$status" -ne 0 ]
}

@test "red twin: replacing auto_mode in step 2 fails the step 2 check" {
  copy="$(scratch_copy)"
  replace_in_section "$copy/$PLAN_MD" '^### 2\. ' '^### ' 'auto_mode' 'auto_flag'
  run check_p4 "$copy"
  [ "$status" -ne 0 ]
}

@test "red twin: replacing auto_mode in step 4.6 fails the step 4.6 check" {
  copy="$(scratch_copy)"
  replace_in_section "$copy/$PLAN_MD" '^### 4\.6\. ' '^### ' 'auto_mode' 'auto_flag'
  run check_p5 "$copy"
  [ "$status" -ne 0 ]
}

@test "red twin: restoring the old argument hint fails the command check" {
  copy="$(scratch_copy)"
  edit_literal "$copy/$PLAN_CMD" '[auto] [feature description]' '[feature description]'
  run check_p6 "$copy"
  [ "$status" -ne 0 ]
}

@test "red twin: replacing auto_mode in step 4.6b fails the 4.6b check" {
  copy="$(scratch_copy)"
  replace_in_section "$copy/$AUDIT_MD" '^## 4\.6b\. ' '' 'auto_mode' 'auto_flag'
  run check_p7 "$copy"
  [ "$status" -ne 0 ]
}

@test "red twin: re-inserting a stale wiki index literal fails the index check" {
  local literals=('a guard enforces the stop' 'printing a `/gaia-plan` prompt for a fresh session')
  local literal
  for literal in "${literals[@]}"; do
    copy="$(scratch_copy)"
    printf '%s\n' "$literal" >>"$copy/$WIKI_INDEX"
    run check_w_index "$copy"
    [ "$status" -ne 0 ] || { printf 'check_w_index passed with: %s\n' "$literal" >&2; return 1; }
  done
}

@test "red twin: re-inserting a stale GAIA Spec page literal fails the page check" {
  local literals=('Planning is always a new session' 'the downstream handoff target' 'pastes into a fresh [[GAIA Plan]] session')
  local literal
  for literal in "${literals[@]}"; do
    copy="$(scratch_copy)"
    printf '%s\n' "$literal" >>"$copy/$WIKI_SPEC"
    run check_w_spec "$copy"
    [ "$status" -ne 0 ] || { printf 'check_w_spec passed with: %s\n' "$literal" >&2; return 1; }
  done
}

@test "red twin: re-inserting the stale Task Orchestration literal fails the page check" {
  copy="$(scratch_copy)"
  printf '%s\n' 'ends by printing a `/gaia-plan` handoff prompt and stops' >>"$copy/$WIKI_ORCH"
  run check_w_orchestration "$copy"
  [ "$status" -ne 0 ]
}

@test "red twin: re-inserting the stale GAIA Plan page literal fails the page check" {
  copy="$(scratch_copy)"
  printf '%s\n' 'the standard [[GAIA Spec]] handoff' >>"$copy/$WIKI_PLAN"
  run check_w_plan "$copy"
  [ "$status" -ne 0 ]
}
