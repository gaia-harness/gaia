#!/usr/bin/env bats
#
# Doc-conformance suite for the testing doctrine's single ownership.
#
# `.claude/doctrine/testing.md` owns which test to write and at which layer.
# Every other instruction source states only how to write a test at its layer,
# plus a pointer to the doctrine. A rule copied into a second file drifts from
# the first on the next edit, and the two copies then disagree about what a
# plan, executor or reviewer must do. This suite pins that ownership two ways:
#
#   - each pinned rule sentence (one load-bearing sentence per doctrine
#     section, plus the sentences of the conflict resolutions most likely to be
#     restated) appears in the doctrine and in no other tracked Markdown file
#     under .claude/, apps/web/.claude/ or wiki/, and in none of the listed
#     non-Markdown instruction sources;
#   - every Markdown source that once stated a conflicting test rule, and still
#     states one, carries the pointer `.claude/doctrine/testing.md`.
#
# Excluded from the sentence search: the vendored playwright-cli skill (not
# GAIA's to edit), wiki/log.md (a history ledger) and CHANGELOG.md (outside the
# searched folders).
#
# Assertion style: .claude/rules/bats-assertions.md.

# bats file_tags=whole-tree

# The pinned sentences carry backticks as literal Markdown.
# shellcheck disable=SC2016

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  DOCTRINE_REL='.claude/doctrine/testing.md'
  POINTER='.claude/doctrine/testing.md'

  # One sentence per doctrine section, then the resolution sentences: the
  # anonymous write, the shared guard, the middleware guard, the hooks-only
  # fresh render, the layer rule that replaces "lowest layer that can prove
  # it", library key and focus behavior, and the later-request rule.
  PINNED_SENTENCES=(
    'This file owns which test to write and at which layer.'
    'Never plan, list or write a test for a corner case or an error path no stated requirement names.'
    'A test that only watches a guard pass cannot tell a working guard from an inert one.'
    'A play function drives the UI into the state the snapshot shows and asserts nothing.'
    'Rendered HTML is a real-server check only when the HTML itself is the requirement.'
    'A hollow test is an untested requirement.'
    'Every committed test follows this file.'
    'Prove that an authenticated write action refuses an anonymous request, with no side effect, by a route test calling the action with an anonymous `Request`.'
    'Give a module its own refusal test only when its own code wires the guard, so removing that wiring leaves the module unguarded.'
    'A route test that runs the real middleware chain proves a middleware guard; a route test that hand-calls a context provider does not'
    'A fresh render in a separate test file is for hooks only.'
    'Place each test on the layer this section assigns to what it asserts'
    'Library-supplied key and focus behavior gets no test.'
    'with a before-and-after read in one session, at the layer the layer rule picks for the rule.'
    'asserting only the served status and any `Location` header, never page content a route test shows'
    'exactly one case table holding every case, at the layer the layer rule picks. A test of that rule at another layer holds one case per outcome'
    'A real-server row for a served error status (a 404 for an unknown path or a missing record) asserts only the status and any `Location`'
    'Which route answers a path is shown by its route test and, for a guarded route, its served check (a signed-out request its guard redirects), never by a served heading.'
    'with no success-path route test of its own; an effect the flow cannot observe keeps its route test'
  )

  # The conflict sources that still state a test rule: each points at the
  # doctrine.
  POINTER_SOURCES=(
    '.claude/agents/worthiness-evaluator.md'
    '.claude/rules/coding-guidelines.md'
    '.claude/skills/gaia/references/plan/orchestrator-template.md'
    '.claude/skills/gaia/references/spec/audit.md'
    '.claude/skills/gaia/references/work-lifecycle.md'
    '.claude/skills/gaia/references/worthiness-step.md'
    '.claude/skills/tdd/SKILL.md'
    'apps/web/.claude/rules/coding-guidelines-react.md'
    'apps/web/.claude/rules/playwright.md'
    'apps/web/.claude/rules/routes.md'
    'apps/web/.claude/rules/storybook.md'
    'apps/web/.claude/skills/tdd-react/references/tests-react.md'
    'apps/web/CLAUDE.md'
    'wiki/concepts/Component Testing.md'
    'wiki/decisions/Stories as Tests.md'
    'wiki/decisions/Test Layering.md'
    'wiki/decisions/Testing Trophy Doctrine.md'
    'wiki/decisions/Worthiness Presence Gate.md'
    'wiki/dependencies/playwright-cli.md'
    'wiki/modules/Testing.md'
  )

  # Instruction sources outside the searched Markdown that carry test rules.
  CODE_SOURCES=(
    '.claude/hooks/lib/worthiness-selection.sh'
    '.claude/hooks/worthiness-presence-check.sh'
    '.gaia/scripts/worthiness-step.sh'
    '.gaia/scripts/spec/page-use.mjs'
    '.gaia/scripts/spec/flow-coverage.sh'
    '.gaia/scripts/spec/flows-lib.sh'
    '.gaia/scripts/spec/plan-verify.sh'
    '.gaia/scripts/classifier/classify-determinism.mjs'
    '.gaia/scripts/test-signals/extract-test-signals.mjs'
    'apps/web/gaia.package.json'
  )

  SOURCE_LIST="$BATS_TEST_TMPDIR/sources.txt"
  git -C "$REPO_ROOT" ls-files -z -- '.claude/*.md' 'apps/web/.claude/*.md' 'wiki/*.md' 'apps/web/CLAUDE.md' | tr '\0' '\n' >"$SOURCE_LIST"
  printf '%s\n' "${CODE_SOURCES[@]}" >>"$SOURCE_LIST"
}

# ---------- helpers ----------

# Whitespace-normalized text of file $1: several sources are hard-wrapped.
normalized() { tr '\n' ' ' <"$1" | tr -s ' '; }

# check_sentences_owned <root> <source list>: every pinned sentence is in the
# doctrine and in no listed source but the doctrine and the exclusions.
check_sentences_owned() {
  local root="$1" list="$2" sentence file
  for sentence in "${PINNED_SENTENCES[@]}"; do
    normalized "$root/$DOCTRINE_REL" | grep -qF -- "$sentence" || {
      printf 'doctrine lacks: %s\n' "$sentence" >&2
      return 1
    }
    while IFS= read -r file; do
      case "$file" in
        "$DOCTRINE_REL" | wiki/log.md | apps/web/.claude/skills/playwright-cli/*) continue ;;
      esac
      normalized "$root/$file" | grep -qF -- "$sentence" && {
        printf '%s restates: %s\n' "$file" "$sentence" >&2
        return 1
      }
    done <"$list"
  done
  return 0
}

# check_pointers <root>: every pointer source exists and names the doctrine.
check_pointers() {
  local root="$1" file
  for file in "${POINTER_SOURCES[@]}"; do
    [ -f "$root/$file" ] || { printf 'missing source: %s\n' "$file" >&2; return 1; }
    grep -qF -- "$POINTER" "$root/$file" || { printf '%s lacks the doctrine pointer\n' "$file" >&2; return 1; }
  done
  return 0
}

# ---------- arming ----------

@test "the pinned sentences, the pointer sources and the searched sources are non-empty and exist" {
  [ "${#PINNED_SENTENCES[@]}" -gt 0 ] || return 1
  [ "${#POINTER_SOURCES[@]}" -gt 0 ] || return 1
  [ "${#CODE_SOURCES[@]}" -gt 0 ] || return 1
  local file
  for file in "${POINTER_SOURCES[@]}" "${CODE_SOURCES[@]}"; do
    [ -f "$REPO_ROOT/$file" ] || { printf 'missing: %s\n' "$file" >&2; return 1; }
  done
  # The derived list reached the doctrine and every Markdown pointer source.
  grep -qxF -- "$DOCTRINE_REL" "$SOURCE_LIST" || { echo 'source list lacks the doctrine' >&2; return 1; }
  for file in "${POINTER_SOURCES[@]}"; do
    grep -qxF -- "$file" "$SOURCE_LIST" || { printf 'source list lacks: %s\n' "$file" >&2; return 1; }
  done
}

# ---------- current tree ----------

@test "every pinned rule sentence lives in the doctrine alone" {
  check_sentences_owned "$REPO_ROOT" "$SOURCE_LIST"
}

@test "every conflict source that states a test rule points at the doctrine" {
  check_pointers "$REPO_ROOT"
}

@test "doctrine carries no table sections and nothing points to one" {
  local doctrine="$REPO_ROOT/$DOCTRINE_REL" heading term hits
  for heading in '## Test-design table' '## Honesty'; do
    if grep -qxF -- "$heading" "$doctrine"; then
      printf 'doctrine still has: %s\n' "$heading" >&2
      return 1
    fi
  done
  for term in '**Security row.**' '**Story security row.**' '**One kind per case.**' 'tests.json' 'caseKinds' 'caseKey'; do
    if grep -qF -- "$term" "$doctrine"; then
      printf 'doctrine still names: %s\n' "$term" >&2
      return 1
    fi
  done
  # The heading other files cite by name stays.
  grep -qxF -- '## Guards and security rows' "$doctrine"
  # No loaded instruction points to a removed section: a pointer names the
  # doctrine and a removed heading or paragraph in one line.
  hits="$(git -C "$REPO_ROOT" grep -nE 'doctrine/testing\.md.*(Test-design table|## Honesty|Security row|One kind per case)' -- '.claude/skills/tdd' '.claude/rules' 'apps/web/.claude' || true)"
  if [ -n "$hits" ]; then
    printf 'pointer to a removed section:\n%s\n' "$hits" >&2
    return 1
  fi
}
