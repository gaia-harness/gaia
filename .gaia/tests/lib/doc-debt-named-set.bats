#!/usr/bin/env bats
#
# Doc-conformance suite for /gaia-debt's named-issue strictness and
# operator-named batches (.claude/skills/gaia/references/debt.md and
# .claude/skills/gaia/references/debt/named.md).
#
# What it guards. A /gaia-debt argument names what the operator wants drained,
# and the playbook is followed literally by a model, so every place the prose
# lets a named number turn into a different issue is a drain nobody asked for:
# a claim, a branch, and a pull request against the wrong ticket.
#
# The invariants, each pinned to the section that owns it:
#   - argument parsing maps every output of the executable parser;
#   - a named number is validated against a fixed, first-match reason table,
#     and an ineligible one stops the run;
#   - a named set runs security pre-filter, spec pre-filter, branch-name
#     dry-run, then the scorer, in that order, and prints only fixed strings
#     about a rejected member;
#   - the budget constants are assigned in exactly one file, the scorer.
#
# Section-scoped, not whole-file: a phrase surviving elsewhere cannot green a
# section that dropped it. extract_section ends a section at the next heading
# of the same or a shallower level with no fence tracking, so a `# ` line
# inside a fenced block in debt.md truncates the haystack early. The error
# direction is over-strict: a truncated haystack fails, it never passes.
#
# Assertion style: .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  DEBT_MD="$REPO_ROOT/.claude/skills/gaia/references/debt.md"
  NAMED_MD="$REPO_ROOT/.claude/skills/gaia/references/debt/named.md"
  NAMED_SET_HEADING='## Fix a named set (two or more numbers)'
}

# extract_section <heading-line-prefix> [file]
# Prints the first section whose heading line starts with the literal prefix
# (heading included), up to but excluding the next heading of the same or a
# shallower level. Prints nothing when no heading matches.
extract_section() {
  awk -v want="$1" '
    !found && index($0, want) == 1 {
      found = 1
      match($0, /^#+/)
      level = RLENGTH
      print
      next
    }
    found && /^#+ / {
      match($0, /^#+/)
      if (RLENGTH <= level) exit
    }
    found { print }
  ' "${2:-$DEBT_MD}"
}

# extract_between <start-prefix> <stop-prefix>  (haystack on stdin)
# Prints from the first line whose leading-whitespace-stripped text starts
# with start-prefix up to but excluding the next line whose stripped text
# starts with stop-prefix. Prints nothing when start-prefix is absent.
extract_between() {
  awk -v start="$1" -v stop="$2" '
    { line = $0; sub(/^[[:space:]]+/, "", line) }
    on && index(line, stop) == 1 { exit }
    !on && index(line, start) == 1 { on = 1 }
    on { print }
  '
}

# line_of <fixed-string>  (haystack on stdin): first matching line number.
line_of() {
  grep -n -F -- "$1" | head -1 | cut -d: -f1
}

named_set_section() {
  extract_section "$NAMED_SET_HEADING" "$NAMED_MD"
}

# case_row <case name> <command...>: runs the command and names the case that
# failed.
case_row() {
  local case_name="$1"
  shift
  "$@" || {
    printf 'failed case: %s\n' "$case_name" >&2
    return 1
  }
}

@test "argument parsing maps every parser output" {
  section="$(extract_section '## Argument parsing')"
  [ -n "$section" ]
  grep -qF -- '- `top`' <<<"$section"
  grep -qF -- '- `numbers <N>`' <<<"$section"
  grep -qF -- '- `numbers <N1> <N2> ...`' <<<"$section"
  grep -qF -- '- `unrecognized <token>`' <<<"$section"
}

# validate_has_row <literal>: the validation section holds the row.
validate_has_row() {
  local section
  section="$(extract_section '## Validate named numbers' "$NAMED_MD")"
  [ -n "$section" ] || return 1
  grep -qF -- "$1" <<<"$section"
}

# validate_has_row_ci <literal>: the same, case-insensitive.
validate_has_row_ci() {
  local section
  section="$(extract_section '## Validate named numbers' "$NAMED_MD")"
  [ -n "$section" ] || return 1
  grep -qiF -- "$1" <<<"$section"
}

@test "a named number that is not an eligible tech-debt issue stops the run" {
  case_row "not an issue in this repository" validate_has_row '`#<N> is not an issue in this repository`'
  case_row "could not be read" validate_has_row '`#<N> could not be read: <gh error, one line>`'
  case_row "already closed" validate_has_row '`#<N> is already closed`'
  case_row "no tech-debt label" validate_has_row '`#<N> doesn'"'"'t carry the tech-debt label`'
  case_row "already being fixed" validate_has_row '`#<N> is already being fixed by another session`'
  case_row "parked pending a SPEC handoff" validate_has_row '`#<N> is parked pending a SPEC handoff`'
  case_row "parked with a SPEC underway" validate_has_row '`#<N> is parked with a SPEC underway or holding it open`'
  case_row "graded severity:investigate" validate_has_row '`#<N> is graded severity:investigate: answer its question and re-grade it before fixing it`'
  case_row "first matching row wins" validate_has_row_ci 'first matching row wins'
  case_row "reads url" validate_has_row 'gh issue view <n> --json state,labels,url'
  case_row "pull request apart by url" validate_has_row '`url` contains `/pull/`'
  case_row "unresolvable number" validate_has_row 'Could not resolve to an issue or pull request'
  case_row "ineligible number ends the run" validate_has_row_ci 'any ineligible number ends the run with nothing claimed'
  case_row "no fall-through" validate_has_row_ci 'no fall-through'
}

# section_has_ci <literal>: the named-set section holds the literal,
# case-insensitive.
section_has_ci() {
  local section
  section="$(named_set_section)"
  [ -n "$section" ] || return 1
  grep -qiF -- "$1" <<<"$section"
}

# named_set_order_holds: security, spec, branch-name, then the scorer.
named_set_order_holds() {
  local section security spec branch score
  section="$(named_set_section)"
  [ -n "$section" ] || return 1
  security=$(line_of '**Security pre-filter.**' <<<"$section")
  spec=$(line_of '**Spec pre-filter.**' <<<"$section")
  branch=$(line_of 'bash .gaia/scripts/branch-name-lib.sh name debt' <<<"$section")
  score=$(line_of 'bash .gaia/scripts/debt-batch-budget.sh' <<<"$section")
  [ -n "$security" ] && [ -n "$spec" ] && [ -n "$branch" ] && [ -n "$score" ] || return 1
  [ "$security" -lt "$spec" ] && [ "$spec" -lt "$branch" ] && [ "$branch" -lt "$score" ]
}

# security_arm_has <literal>: the security pre-filter arm holds the literal.
security_arm_has() {
  local section security
  section="$(named_set_section)"
  [ -n "$section" ] || return 1
  security="$(extract_between '1. **Security pre-filter.**' '2. **Spec pre-filter.**' <<<"$section")"
  [ -n "$security" ] || return 1
  grep -qiF -- "$1" <<<"$security"
}

@test "a named set screens security, spec and branch name before the scorer and prints only fixed strings about a rejected member" {
  case_row "security, spec, branch-name, then the scorer, in order" named_set_order_holds
  case_row "fixed security rejection line" section_has_ci "\`#<P> can't join a batch on a non-private repo; drain it alone.\`"
  case_row "no-disclosure covers printed messages" section_has_ci 'covers the run'"'"'s printed messages'
  case_row "no printed message names a security-class member" section_has_ci 'no printed message names a security-class member'"'"'s title, body, or path'
  case_row "staleness annotation never printed for a security-class member" section_has_ci 'staleness probe'"'"'s annotation is never printed for a named set'"'"'s security-class member'
  case_row "benign member passes" security_arm_has 'a **benign member** passes'
  case_row "confirmed-PRIVATE filters nothing" security_arm_has 'on a **confirmed-PRIVATE** repo nothing is filtered: a security-class member passes and batches normally'
}

# budget_constant_owners <root>: every tracked or untracked (not ignored) file
# under <root> that assigns a DEBT_BUDGET_ constant at column 0, one
# repo-relative path per line, sorted.
budget_constant_owners() {
  {
    git -C "$1" grep -l -E '^DEBT_BUDGET_[A-Z_]+=' -- 2>/dev/null || true
    while IFS= read -r -d '' path; do
      [ -f "$1/$path" ] || continue
      if grep -qE '^DEBT_BUDGET_[A-Z_]+=' "$1/$path"; then
        printf '%s\n' "$path"
      fi
    done < <(git -C "$1" ls-files -z --others --exclude-standard 2>/dev/null)
  } | sort -u
}

# bats test_tags=whole-tree
@test "the budget constants are assigned in exactly one file, the scorer" {
  # Read the scorer directly as well, so an empty owner list (an unstaged
  # scorer, a git failure) cannot pass for "exactly one".
  grep -qE '^DEBT_BUDGET_LIMIT=' "$REPO_ROOT/.gaia/scripts/debt-batch-budget.sh"
  owners="$(budget_constant_owners "$REPO_ROOT")"
  [ "$owners" = ".gaia/scripts/debt-batch-budget.sh" ]
}
