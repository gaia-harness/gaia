#!/usr/bin/env bats
# Conformance suite for the retired `frontend/` package root in
# .gaia/scripts/check-retired-paths.sh: the old root is scanned in rule bodies,
# wiki pages and every tracked Markdown file, so a citation of it cannot return.
#
# Failing states are driven in a temporary git repository holding a copy of the
# gate.
#
# Run under bash 5: `bash .gaia/scripts/bats5.sh .gaia/scripts/tests/retired-frontend-root.bats`.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  SCRIPT_DIRECTORY="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
}

make_repo() {
  local repo="$BATS_TEST_TMPDIR/$1"
  mkdir -p "$repo/.gaia/scripts" "$repo/.claude/hooks" "$repo/.claude/rules" "$repo/wiki/modules"
  git -C "$repo" init -q
  cp "$SCRIPT_DIRECTORY/check-retired-paths.sh" "$repo/.gaia/scripts/check-retired-paths.sh"
  printf '#!/usr/bin/env bash\necho ok\n' >"$repo/.claude/hooks/ok.sh"
  printf -- '---\npaths:\n  - "apps/web/app/**"\n---\n\nClean body.\n' >"$repo/.claude/rules/clean.md"
  printf '# Clean\n\nNothing retired here.\n' >"$repo/wiki/modules/Clean.md"
  printf '%s' "$repo"
}

run_gate() {
  git -C "$1" add -A
  run bash "$1/.gaia/scripts/check-retired-paths.sh"
}

# bats test_tags=protected
@test "a retired frontend/ citation or tracked path fails and is named" {
  local repo
  repo="$(make_repo retired)"
  printf '# Page\n\nSee frontend/app/routes for routes.\n' >"$repo/wiki/modules/Page.md"
  printf -- '---\npaths:\n  - "apps/web/app/**"\n---\n\nEdit frontend/app/root.tsx first.\n' >"$repo/.claude/rules/body.md"
  printf -- '---\npaths:\n  - "frontend/app/**"\n---\n\nBody.\n' >"$repo/.claude/rules/glob.md"
  mkdir -p "$repo/frontend"
  printf 'x\n' >"$repo/frontend/x.txt"
  run_gate "$repo"
  [ "$status" -eq 1 ]
  local expected
  for expected in 'RETIRED wiki/modules/Page.md:3:' 'RETIRED .claude/rules/body.md:6:' \
    'RETIRED .claude/rules/glob.md:3:' 'TRACKED frontend/x.txt'; do
    grep -qF -- "$expected" <<<"$output" || { echo "missing: $expected"; return 1; }
  done
}

@test "clean, lookalike and frozen-history files pass" {
  local repo
  repo="$(make_repo allowed)"
  run_gate "$repo"
  [ "$status" -eq 0 ]
  grep -qF -- "(3 files scanned)" <<<"$output"
  printf 'Roster: .claude/agents/code-audit-frontend/x and apps/web/frontend/y.\n' >"$repo/wiki/modules/Lookalike.md"
  printf 'Moved frontend/app.\n' >"$repo/CHANGELOG.md"
  printf 'Moved frontend/app.\n' >"$repo/wiki/log.md"
  run_gate "$repo"
  [ "$status" -eq 0 ]
}
