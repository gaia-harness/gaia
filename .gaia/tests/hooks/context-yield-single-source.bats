#!/usr/bin/env bats
#
# The sub-agent half of the context checkpoint has one tracked source for its
# numbers, .gaia/scripts/context-checkpoint-lib.sh. This suite scans four
# regions for literals that belong only there. Forbidden values are derived
# from the lib at test time (never typed here): the red, fire and skull bands
# on the default window and on a 200000 window, the default window, the three
# transcript bound constants, the yield limit L and L + 1.
#
# Regions and what each forbids:
#
# - hook: .claude/hooks/context-checkpoint-subagent.sh, the whole file with
#   comment lines included. Forbids each band value, the default window and
#   each bound as a whole word, and any assignment of a number to a name that
#   contains "yield".
# - helpers: the bodies of the lib's yield_limit, last_window, subagent_window
#   and transcript_reading functions (each from its opening line to the next
#   closing brace). Forbids the same as the hook.
# - planner: the fence holding the yield-handling sentinel in
#   .claude/skills/gaia/references/plan/planner.md. Forbids L and L + 1 as
#   numbers and as cardinal and ordinal English words, "twice", each band
#   value and the default window.
# - plan: the "#### Planner yield" subsection of
#   .claude/skills/gaia/references/plan.md, up to the next "### " heading.
#   Forbids the same as the planner region.
#
# Words match case-insensitively and numbers as whole words (grep -wi). A
# region whose begin anchor is missing fails loudly, never as an empty pass.
# Each red twin plants a literal in a scratch copy and expects the same check
# function to fail.
#
# Run: .gaia/scripts/bats5.sh .gaia/tests/hooks/context-yield-single-source.bats < /dev/null
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

# bats file_tags=whole-tree

bats_require_minimum_version 1.5.0

HOOK_PATH=".claude/hooks/context-checkpoint-subagent.sh"
LIB_PATH=".gaia/scripts/context-checkpoint-lib.sh"
PLANNER_PATH=".claude/skills/gaia/references/plan/planner.md"
PLAN_PATH=".claude/skills/gaia/references/plan.md"
HELPERS_BEGIN='^gaia_context_(yield_limit|last_window|subagent_window|transcript_reading)\(\)'
SENTINEL='<!-- gaia:orchestrator-step yield-handling -->'
PLAN_HEADING='#### Planner yield'

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  # shellcheck source=/dev/null
  . "$REPO_ROOT/$LIB_PATH"
  derive_forbidden
}

# add_band_values <window>: append that window's red, fire and skull values.
add_band_values() {
  local main_root="$BATS_TEST_TMPDIR/no-override" line red fire skull
  mkdir -p "$main_root"
  line="$(gaia_context_effective_line "$main_root" "$1")"
  read -r _ red fire skull <<<"$(gaia_context_bands "$1" "$line")"
  printf '%s\n%s\n%s\n' "$red" "$fire" "$skull" >>"$BAND_VALUES"
}

# derive_forbidden: build the forbidden word lists from the lib.
derive_forbidden() {
  local limit next
  local -a cardinals=(zero one two three four five) ordinals=(zeroth first second third fourth fifth)
  BAND_VALUES="$BATS_TEST_TMPDIR/band-values"
  HOOK_FORBIDDEN="$BATS_TEST_TMPDIR/hook-forbidden"
  TEMPLATE_FORBIDDEN="$BATS_TEST_TMPDIR/template-forbidden"
  : >"$BAND_VALUES"
  add_band_values "$GAIA_CONTEXT_DEFAULT_WINDOW"
  add_band_values 200000
  limit="$(gaia_context_yield_limit)"
  next=$((limit + 1))
  [ "$next" -le 5 ] || { printf 'yield limit %s is past the word table\n' "$limit" >&2; return 1; }
  {
    cat "$BAND_VALUES"
    printf '%s\n' "$GAIA_CONTEXT_DEFAULT_WINDOW" "$GAIA_CONTEXT_TRANSCRIPT_HEAD_BYTES" \
      "$GAIA_CONTEXT_TRANSCRIPT_TAIL_BYTES" "$GAIA_CONTEXT_TRANSCRIPT_WIDE_BYTES"
  } >"$HOOK_FORBIDDEN"
  {
    cat "$BAND_VALUES"
    printf '%s\n' "$GAIA_CONTEXT_DEFAULT_WINDOW" "$limit" "$next" \
      "${cardinals[$limit]}" "${cardinals[$next]}" "${ordinals[$limit]}" "${ordinals[$next]}" twice
  } >"$TEMPLATE_FORBIDDEN"
  YIELD_LIMIT="$limit"
  LIMIT_CARDINAL="${cardinals[$limit]}"
  NEXT_ORDINAL="${ordinals[$next]}"
  RED_DEFAULT="$(sed -n 1p "$BAND_VALUES")"
}

# extract_helpers <lib file>: print the four helper bodies; fail if one is missing.
extract_helpers() {
  local count
  count="$(grep -cE "$HELPERS_BEGIN" "$1")"
  [ "$count" -eq 4 ] || { printf 'helper begin anchor not found in %s: %s of 4 helpers (%s)\n' "$1" "$count" "$HELPERS_BEGIN" >&2; return 1; }
  awk -v begin="$HELPERS_BEGIN" '$0 ~ begin {inside = 1} inside {print} inside && /^}/ {inside = 0}' "$1"
}

# extract_fence <planner file>: print the fence holding the sentinel, fences excluded.
extract_fence() {
  grep -qF -- "$SENTINEL" "$1" || { printf 'begin anchor not found in %s: %s\n' "$1" "$SENTINEL" >&2; return 1; }
  awk -v sentinel="$SENTINEL" '
    { lines[NR] = $0 }
    index($0, sentinel) && !target { target = NR }
    END {
      first = 0
      for (i = target; i >= 1; i--) if (lines[i] ~ /^[ \t]*```/) { first = i; break }
      if (!first) exit 3
      for (i = first + 1; i <= NR; i++) {
        if (lines[i] ~ /^[ \t]*```/) break
        print lines[i]
      }
    }' "$1"
}

# extract_subsection <plan file>: print from the heading to before the next "### " line.
extract_subsection() {
  grep -qxF -- "$PLAN_HEADING" "$1" || { printf 'begin anchor not found in %s: %s\n' "$1" "$PLAN_HEADING" >&2; return 1; }
  awk -v heading="$PLAN_HEADING" '$0 == heading {inside = 1} inside && /^### / {exit} inside {print}' "$1"
}

# forbidden_hits <forbidden list> <region text file>: print every hit; exit 0 when none.
forbidden_hits() {
  local hits
  hits="$(grep -nwiFf "$1" "$2" || true)"
  if [ -n "$hits" ]; then printf '%s\n' "$hits"; return 1; fi
}

# check_region <hook|helpers|planner|plan> <file>: exit 0 when the region is clean,
# 1 with the offending lines (or the missing anchor) on stderr otherwise.
check_region() {
  local region_file="$BATS_TEST_TMPDIR/region.txt" hits
  case "$1" in
    hook) cp "$2" "$region_file" ;;
    helpers) extract_helpers "$2" >"$region_file" || return 1 ;;
    planner) extract_fence "$2" >"$region_file" || return 1 ;;
    plan) extract_subsection "$2" >"$region_file" || return 1 ;;
    *) printf 'unknown region %s\n' "$1" >&2; return 2 ;;
  esac
  [ -s "$region_file" ] || { printf 'region %s is empty in %s\n' "$1" "$2" >&2; return 1; }
  case "$1" in
    hook | helpers)
      hits="$(forbidden_hits "$HOOK_FORBIDDEN" "$region_file")" || { printf 'forbidden literal in %s:\n%s\n' "$1" "$hits" >&2; return 1; }
      hits="$(grep -nE '[A-Za-z_]*[Yy][Ii][Ee][Ll][Dd][A-Za-z_]*=[0-9]' "$region_file" || true)"
      [ -z "$hits" ] || { printf 'yield-limit assignment in %s:\n%s\n' "$1" "$hits" >&2; return 1; }
      ;;
    *)
      hits="$(forbidden_hits "$TEMPLATE_FORBIDDEN" "$region_file")" || { printf 'forbidden literal in %s:\n%s\n' "$1" "$hits" >&2; return 1; }
      ;;
  esac
}

# scratch_copy <repo-relative path>: copy it into the scratch tree, print the copy's path.
scratch_copy() {
  local target="$BATS_TEST_TMPDIR/copy/$1"
  mkdir -p "$(dirname "$target")"
  cp "$REPO_ROOT/$1" "$target"
  printf '%s\n' "$target"
}

# plant_after <file> <fixed line to follow> <text>: insert a line after the first match.
plant_after() {
  awk -v anchor="$2" -v text="$3" '{print} !done && index($0, anchor) == 1 {print text; done = 1}' "$1" >"$1.new"
  mv "$1.new" "$1"
  grep -qF -- "$3" "$1"
}

@test "the hook spells no band value, window, bound or yield-limit assignment" {
  check_region hook "$REPO_ROOT/$HOOK_PATH"
}

@test "the new lib helper bodies spell no band value, window, bound or yield-limit assignment" {
  check_region helpers "$REPO_ROOT/$LIB_PATH"
}

@test "the planner yield-handling block spells no limit, count word, band value or window" {
  check_region planner "$REPO_ROOT/$PLANNER_PATH"
}

@test "the plan Planner yield subsection spells no limit, count word, band value or window" {
  check_region plan "$REPO_ROOT/$PLAN_PATH"
}

@test "red twin: the default window planted in a comment of the hook copy fails" {
  local copy
  copy="$(scratch_copy "$HOOK_PATH")"
  printf '# the default window is %s\n' "$GAIA_CONTEXT_DEFAULT_WINDOW" >>"$copy"
  run -1 check_region hook "$copy"
  [[ $output == *"forbidden literal in hook"* ]]
}

@test "red twin: a red value planted in a helper body copy fails" {
  local copy
  copy="$(scratch_copy "$LIB_PATH")"
  plant_after "$copy" 'gaia_context_last_window()' "  : $RED_DEFAULT"
  run -1 check_region helpers "$copy"
  [[ $output == *"forbidden literal in helpers"* ]]
}

@test "red twin: a yield-limit assignment planted in the hook copy fails" {
  local copy
  copy="$(scratch_copy "$HOOK_PATH")"
  printf 'GAIA_YIELD_MAX=%s\n' "$YIELD_LIMIT" >>"$copy"
  run -1 check_region hook "$copy"
  [[ $output == *"yield-limit assignment in hook"* ]]
}

@test "red twin: the yield limit number planted in the planner region copy fails" {
  local copy
  copy="$(scratch_copy "$PLANNER_PATH")"
  plant_after "$copy" "$(grep -F -- "$SENTINEL" "$REPO_ROOT/$PLANNER_PATH" | head -1)" "Halt after $YIELD_LIMIT yields."
  run -1 check_region planner "$copy"
  [[ $output == *"forbidden literal in planner"* ]]
}

@test "red twin: the ordinal for the limit plus one planted in the planner region copy fails" {
  local copy
  copy="$(scratch_copy "$PLANNER_PATH")"
  plant_after "$copy" "$(grep -F -- "$SENTINEL" "$REPO_ROOT/$PLANNER_PATH" | head -1)" "Halt on the $NEXT_ORDINAL yield."
  run -1 check_region planner "$copy"
  [[ $output == *"forbidden literal in planner"* ]]
}

@test "red twin: the cardinal for the limit planted in the plan region copy fails" {
  local copy
  copy="$(scratch_copy "$PLAN_PATH")"
  plant_after "$copy" "$PLAN_HEADING" "Allow $LIMIT_CARDINAL yields."
  run -1 check_region plan "$copy"
  [[ $output == *"forbidden literal in plan"* ]]
}

@test "a planner copy without the sentinel fails naming the missing anchor" {
  local copy
  copy="$(scratch_copy "$PLANNER_PATH")"
  grep -vF -- "$SENTINEL" "$copy" >"$copy.new"
  mv "$copy.new" "$copy"
  run -1 check_region planner "$copy"
  [[ $output == *"begin anchor not found"*"$SENTINEL"* ]]
}

@test "a plan copy without the Planner yield heading fails naming the missing anchor" {
  local copy
  copy="$(scratch_copy "$PLAN_PATH")"
  grep -vxF -- "$PLAN_HEADING" "$copy" >"$copy.new"
  mv "$copy.new" "$copy"
  run -1 check_region plan "$copy"
  [[ $output == *"begin anchor not found"*"$PLAN_HEADING"* ]]
}

@test "a lib copy missing a helper fails naming the begin anchor" {
  local copy
  copy="$(scratch_copy "$LIB_PATH")"
  sed 's/^gaia_context_last_window()/renamed_helper()/' "$copy" >"$copy.new"
  mv "$copy.new" "$copy"
  run -1 check_region helpers "$copy"
  [[ $output == *"helper begin anchor not found"* ]]
}
