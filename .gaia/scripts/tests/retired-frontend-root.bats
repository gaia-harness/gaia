#!/usr/bin/env bats
# Conformance suite for the retired `frontend/` package root in
# .gaia/scripts/check-retired-paths.sh: the old root is scanned in rule bodies,
# wiki pages and every tracked Markdown file, so a citation of it cannot return.
#
# Failing states are driven in a temporary git repository holding a copy of the
# gate; the remaining tests read the real tree.
#
# Run under bash 5: `bash .gaia/scripts/bats5.sh .gaia/scripts/tests/retired-frontend-root.bats`.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  SCRIPT_DIRECTORY="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  REPO_ROOT="$(cd "$SCRIPT_DIRECTORY/../.." && pwd)"
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

# bats test_tags=whole-tree
@test "the real working tree passes with the retired root in the token set" {
  run bash "$SCRIPT_DIRECTORY/check-retired-paths.sh" --root "$REPO_ROOT"
  [ "$status" -eq 0 ]
  grep -qF -- "check-retired-paths: clean" <<<"$output"
}

@test "a wiki page and a rule body each citing frontend/app fail, and both are named" {
  local repo
  repo="$(make_repo both)"
  printf '# Page\n\nSee frontend/app/routes for routes.\n' >"$repo/wiki/modules/Page.md"
  printf -- '---\npaths:\n  - "apps/web/app/**"\n---\n\nEdit frontend/app/root.tsx first.\n' >"$repo/.claude/rules/body.md"
  run_gate "$repo"
  [ "$status" -eq 1 ]
  grep -qF -- 'RETIRED wiki/modules/Page.md:3:' <<<"$output"
  grep -qF -- 'RETIRED .claude/rules/body.md:6:' <<<"$output"
}

@test "a clean wiki page and rule body pass, and the scan set holds both" {
  local repo
  repo="$(make_repo clean)"
  run_gate "$repo"
  [ "$status" -eq 0 ]
  grep -qF -- "(3 files scanned)" <<<"$output"
}

@test "code-audit-frontend/ and apps/web/frontend/ do not trip" {
  local repo
  repo="$(make_repo lookalike)"
  printf 'Roster: .claude/agents/code-audit-frontend/x and apps/web/frontend/y.\n' >"$repo/wiki/modules/Lookalike.md"
  run_gate "$repo"
  [ "$status" -eq 0 ]
}

@test "a frontend/ path glob in rule frontmatter fails" {
  local repo
  repo="$(make_repo glob)"
  printf -- '---\npaths:\n  - "frontend/app/**"\n---\n\nBody.\n' >"$repo/.claude/rules/glob.md"
  run_gate "$repo"
  [ "$status" -eq 1 ]
  grep -qF -- 'RETIRED .claude/rules/glob.md:3:' <<<"$output"
}

@test "the frozen history files may cite frontend/" {
  local repo
  repo="$(make_repo frozen)"
  printf 'Moved frontend/app.\n' >"$repo/CHANGELOG.md"
  printf 'Moved frontend/app.\n' >"$repo/wiki/log.md"
  run_gate "$repo"
  [ "$status" -eq 0 ]
}

@test "a tracked path under frontend/ fails" {
  local repo
  repo="$(make_repo tracked)"
  mkdir -p "$repo/frontend"
  printf 'x\n' >"$repo/frontend/x.txt"
  run_gate "$repo"
  [ "$status" -eq 1 ]
  grep -qF -- 'TRACKED frontend/x.txt' <<<"$output"
}

# bats test_tags=whole-tree
@test "no rule frontmatter in the real tree names frontend/" {
  local rule_file line_number line
  for rule_file in "$REPO_ROOT"/.claude/rules/*.md "$REPO_ROOT"/.claude/rules/maintainers/*.md "$REPO_ROOT"/apps/web/.claude/rules/*.md; do
    [ -f "$rule_file" ] || continue
    line_number=0
    while IFS= read -r line; do
      line_number=$((line_number + 1))
      if [ "$line_number" -eq 1 ]; then
        [ "$line" = "---" ] || break
        continue
      fi
      [ "$line" = "---" ] && break
      case "$line" in
        *frontend/*)
          printf '%s:%s names frontend/\n' "$rule_file" "$line_number" >&2
          return 1
          ;;
      esac
    done <"$rule_file"
  done
  true
}

@test "the two repo-wide rules keep their intended globs and name no frontend path" {
  local comments="$REPO_ROOT/.claude/rules/code-comments.md"
  local doc_ids="$REPO_ROOT/.claude/rules/working-doc-ids.md"
  grep -qF -- "  - 'apps/web/app/**/*.{ts,tsx,js,jsx,css}'" "$comments"
  grep -qF -- "  - '.gaia/**/*.ts'" "$comments"
  grep -qF -- "  - '**/*.bats'" "$comments"
  grep -qF -- "  - 'apps/web/.claude/**/*.md'" "$doc_ids"
  grep -qF -- "  - '.claude/**/*.{md,sh}'" "$doc_ids"
  grep -qF -- "  - 'wiki/**/*.md'" "$doc_ids"
  grep -qF -- "frontend/" "$comments" && return 1
  grep -qF -- "frontend/" "$doc_ids" && return 1
  true
}

@test "allowlist rows naming frontend/ cover only the two notes and two data lines" {
  local files
  files="$(awk -F'\t' '$1 !~ /^#/ && $2 ~ /(^|[^-])frontend\// { print $1 }' "$REPO_ROOT/.gaia/retired-paths-allowlist.tsv" | LC_ALL=C sort -u)"
  [ "$files" = ".gaia/cli/src/util/gaia-packages-corpus-fixture.ts
.gaia/migrations/2.0.0.md
.gaia/migrations/2.4.0.md
.gaia/scripts/fitness-nudge-lib.sh" ]
}
