#!/usr/bin/env bash
# 25-csf4-migration.sh
# distribution-runner: exclusive
#
# Adopter-flow regression for `gaia migrate-csf4`, proven in a staged release
# tree by the adopter's own toolchain (its TypeScript, ESLint, and Storybook
# Vitest run). Every assertion about the command's outcome reads its --json
# object. Each case resets the staged tree to the shipped state, builds the
# pre-migration state it needs, and commits it so the tree starts clean.
#
#   1. A CSF3 project (render-function story with assignments, custom args, a
#      factory-built set, a leading comment, a parameters.msw story) converts to
#      CSF Next: every export is a meta.story( or .extend( call, the preview is
#      rewired, main gains the test-syntax flag, typecheck and lint pass, and
#      each file's loaded/passed matches a separate Storybook Vitest run. The
#      msw story keeps its handlers in a beforeEach and its play still finds the
#      handler's text.
#   2. A rerun on the migrated, committed tree converts nothing, verifies, and
#      leaves the tree clean.
#   3. A staged, an unstaged, and an untracked change each refuse with
#      dirty-tree and exit 3, and nothing changes.
#   4. CSF2 files refuse with csf2 and exit 3, naming each file and csf-2-to-3.
#   5. A story file that cannot load exits 1 with loaded false while the others
#      stay converted; the restore command names exactly the changed files.
#   6. Verification alone fails that file again though every assertion that ran
#      passed; a failing test and a story type error each exit 1.
#   7. A mixed tree (shipped CSF4 files plus adopter CSF3 stories) converts only
#      the CSF3 stories and leaves every CSF4 file byte-identical.
#   8. --update-merge on a committed tree ignores uncommitted changes outside
#      its write set, refuses one inside it, and converts a preview without
#      i18next with no i18next addon.
#   9. --update-merge on a real post-merge tree (the update's CSF4 files laid
#      over a committed CSF3-era tree, uncommitted) converts only the adopter
#      stories and leaves every overlaid file byte-identical.
#
# Layer 0: needs host pnpm and network access for the install, the codemod
# fetch, and Chromium.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib/lib.sh"
source "$HERE/lib/data-layer.sh"
source "$HERE/lib/csf4-migration.sh"

require_command pnpm "pnpm required for the CSF4 migration scenario (Layer 0)"
require_command rsync "rsync required to copy fixtures"
require_command node "node required to read the command's JSON output"

SECONDS=0
GAIA_CLI_FIXTURES="$HERE/../../cli/test-fixtures/migrate-csf4"
STORY="frontend/app/components"
csf4_stage_tree

# Clean CSF3 project with only the small status-badge component.
lean_csf3_tree() {
  csf4_reset_tree
  csf4_drop_stories
  csf4_use_config preview.csf3.ts
  csf4_install_component adopter status-badge
}

# Every story file, relative to the frontend package.
frontend_stories() {
  csf4_story_files | sed 's#^frontend/##'
}

# Fails unless the last report's per-file status matches the Vitest report.
assert_files_match_report() {
  local report="$1" story loaded passed
  # shellcheck disable=SC2016 # a JavaScript template string, not a shell expansion
  while IFS=' ' read -r story loaded passed; do
    [ "$(csf4_report_status "$report" "$story")" = "$loaded $passed" ] \
      || { fail "$story differs between the command's report and a separate Vitest run"; exit 1; }
  done < <(csf4_field 'parsed.files.map((file) => `${file.path} ${file.loaded} ${file.passed}`).join("\n")')
}

assert_all_loaded_and_passed() {
  csf4_assert "$1" 'parsed.files.every((file) => file.loaded && file.passed)' true
  csf4_assert "$1" 'parsed.files.length > 0' true
  csf4_assert "$1" 'parsed.typecheck.result + parsed.lint.result' passpass
}

# Hashes only, sorted by path.
file_hashes() {
  csf4_fingerprint | grep -E '^[0-9a-f]{64}  '
}

# Paths whose hash differs between two file_hashes dumps, one per line.
changed_paths() {
  { diff <(sort -k2 "$1") <(sort -k2 "$2") || true; } \
    | { grep -E '^[<>] ' || true; } | sed -E 's/^[<>] [0-9a-f]{64}  //' | sort -u
}

# --- 1. UAT: a CSF3 project converts ----------------------------------------

csf4_reset_tree
csf4_drop_stories
csf4_install_fixture "$FIXTURES/adopter"
csf4_use_config preview.csf3.ts
csf4_commit "csf3 project"
STORY_COUNT="$(frontend_stories | wc -l | tr -d ' ')"
[ "$STORY_COUNT" = 4 ] || { fail "expected four adopter story files, found $STORY_COUNT"; exit 1; }

log "migrate-csf4 on the CSF3 project"
csf4_migrate
csf4_expect "csf3 project" 0
csf4_assert "csf3 project" 'parsed.refused === null && parsed.unexpectedChanges.length === 0' true
csf4_assert "csf3 project" 'parsed.files.length' "$STORY_COUNT"
assert_all_loaded_and_passed "csf3 project"

# shellcheck disable=SC2046 # one path per story file, none with whitespace
csf4_story_check shape $(frontend_stories) \
  || { fail "a migrated story file is not in CSF Next form"; exit 1; }
grep -q 'preview.type<' "$FRONTEND/app/components/signup-form/tests/index.stories.tsx" \
  || { fail "custom-args story does not go through preview.type"; exit 1; }
[ "$(node -p 'require(process.argv[1]).imports["#.storybook/preview"]' "$FRONTEND/package.json")" = "./.storybook/preview.ts" ] \
  || { fail "package.json does not map #.storybook/preview"; exit 1; }
head -1 "$FRONTEND/app/components/status-badge/tests/index.stories.tsx" | grep -q '^// Each badge story' \
  || { fail "the story file lost its opening comment"; exit 1; }
head -1 "$FRONTEND/.storybook/main.ts" | grep -q '^// The preview inlines' \
  || { fail "main lost its opening comment"; exit 1; }
for pattern in 'addonMsw()' 'definePreviewAddon<AddonTypes>' 'darkMode:' 'addonLinks()' "from '@storybook/addon-links'"; do
  grep -qF "$pattern" "$FRONTEND/.storybook/preview.ts" \
    || { fail "migrated preview lacks $pattern"; exit 1; }
done
for pattern in 'mswLoader' '@vueless/storybook-dark-mode'; do
  if grep -qF "$pattern" "$FRONTEND/.storybook/preview.ts"; then
    fail "migrated preview still mentions $pattern"
    exit 1
  fi
done
grep -qF '@vueless/storybook-dark-mode' "$FRONTEND/.storybook/main.ts" \
  || { fail "main lost the dark-mode addon"; exit 1; }
grep -qF 'experimentalTestSyntax: true' "$FRONTEND/.storybook/main.ts" \
  || { fail "main lacks experimentalTestSyntax: true"; exit 1; }

run_pnpm_steps "" "after migration" typecheck
run_logged "eslint without fix" "$WORK/eslint.log" \
  pnpm -C "$FRONTEND" exec eslint --max-warnings=0 app .storybook

csf4_vitest_report "$WORK/uat1-report.json"
assert_files_match_report "$WORK/uat1-report.json"

# The parameters.msw story: handlers moved into a beforeEach, and its play
# still finds the handler's own text, so the handlers are installed.
MSW_STORY="app/components/item-list/tests/index.stories.tsx"
csf4_story_check msw "$MSW_STORY" \
  || { fail "the msw story did not move its handlers into a beforeEach"; exit 1; }
grep -qF 'Handler A item' "$FRONTEND/$MSW_STORY" \
  || { fail "the msw story no longer asserts the handler's text"; exit 1; }
[ "$(csf4_report_status "$WORK/uat1-report.json" "$MSW_STORY")" = "true true" ] \
  || { fail "the msw story did not pass in the Vitest run"; exit 1; }

# --- 2. Rerun on the migrated tree ------------------------------------------

csf4_commit "migrated"
log "migrate-csf4 rerun on the migrated tree"
csf4_migrate
csf4_expect "rerun" 0
csf4_assert "rerun" 'parsed.converted.length' 0
assert_all_loaded_and_passed "rerun"
[ -z "$(csf4_git status --porcelain)" ] || { fail "rerun left the tree dirty"; exit 1; }

# --- 3. Dirty trees refuse ---------------------------------------------------

STORY_FILE="$FRONTEND/app/components/status-badge/tests/index.stories.tsx"
for dirt in staged unstaged untracked; do
  lean_csf3_tree
  csf4_commit "clean csf3 tree"
  case "$dirt" in
    staged) printf '// staged\n' >> "$STORY_FILE"; csf4_git add -A ;;
    unstaged) printf '// unstaged\n' >> "$STORY_FILE" ;;
    untracked) printf 'note\n' > "$FRONTEND/notes.txt" ;;
  esac
  csf4_fingerprint > "$WORK/dirty-before.txt"
  csf4_migrate
  csf4_expect "$dirt change" 3
  csf4_assert "$dirt change" 'parsed.refused.reason' dirty-tree
  grep -q 'clean' "$MIGRATE_STDERR" || { fail "$dirt refusal does not say the tree must be clean"; exit 1; }
  csf4_fingerprint > "$WORK/dirty-after.txt"
  diff "$WORK/dirty-before.txt" "$WORK/dirty-after.txt" >&2 \
    || { fail "$dirt refusal changed the tree"; exit 1; }
done

# --- 4. CSF2 refuses ---------------------------------------------------------

lean_csf3_tree
csf4_install_fixture "$FIXTURES/csf2"
csf4_commit "csf2 files"
csf4_fingerprint > "$WORK/csf2-before.txt"
csf4_migrate
csf4_expect "csf2" 3
csf4_assert "csf2" 'parsed.refused.reason' csf2
csf4_assert "csf2" 'parsed.refused.paths.length' 2
for csf2_file in legacy-card legacy-list; do
  csf4_assert "csf2" "parsed.refused.paths.includes('$STORY/$csf2_file/tests/index.stories.tsx')" true
done
grep -q 'csf-2-to-3' "$MIGRATE_STDERR" || { fail "csf2 refusal does not name csf-2-to-3"; exit 1; }
csf4_fingerprint > "$WORK/csf2-after.txt"
diff "$WORK/csf2-before.txt" "$WORK/csf2-after.txt" >&2 || { fail "csf2 refusal changed a file"; exit 1; }

# --- 5. A story file that cannot load ---------------------------------------

lean_csf3_tree
csf4_install_fixture "$FIXTURES/load-failure"
csf4_commit "load-failure project"
FRAGILE="frontend/app/components/fragile/tests/index.stories.tsx"
file_hashes > "$WORK/load-before.txt"
log "migrate-csf4 on the load-failure project"
csf4_migrate
csf4_expect "load failure" 1
csf4_assert "load failure" "parsed.files.find((file) => file.path === '$FRAGILE').loaded" false
csf4_assert "load failure" "parsed.files.find((file) => file.path === '$STORY/status-badge/tests/index.stories.tsx').passed" true
csf4_assert "load failure" "parsed.converted.includes('$FRAGILE')" true
csf4_assert "load failure" "parsed.converted.includes('$STORY/status-badge/tests/index.stories.tsx')" true
# shellcheck disable=SC2046
csf4_story_check shape $(frontend_stories) || { fail "a story file stopped being converted"; exit 1; }
file_hashes > "$WORK/load-after.txt"
changed_paths "$WORK/load-before.txt" "$WORK/load-after.txt" > "$WORK/load-changed.txt"
csf4_field 'parsed.converted.slice().sort().join("\n") + "\n"' > "$WORK/load-converted.txt"
diff "$WORK/load-changed.txt" "$WORK/load-converted.txt" >&2 \
  || { fail "the converted list is not exactly the set of files that changed"; exit 1; }
csf4_field 'parsed.restore.replace(/^.* -- /, "").split(" ").sort().join("\n") + "\n"' > "$WORK/load-restored.txt"
diff "$WORK/load-restored.txt" "$WORK/load-converted.txt" >&2 \
  || { fail "the restore command does not name exactly the converted files"; exit 1; }
mkdir -p "$WORK/migrated"
# shellcheck disable=SC2046 # one path per line, none with whitespace
(cd "$SCAFFOLD" && rsync -R $(cat "$WORK/load-converted.txt") "$WORK/migrated/")
(cd "$SCAFFOLD" && bash -c "$(csf4_field 'parsed.restore')")
[ -z "$(csf4_git status --porcelain)" ] || { fail "the restore command left changes behind"; exit 1; }
rsync -a "$WORK/migrated"/ "$SCAFFOLD"/
csf4_commit "migrated load-failure project"

# --- 6. Verification alone ---------------------------------------------------

log "migrate-csf4 verification on the migrated load-failure project"
csf4_migrate
csf4_expect "load failure rerun" 1
csf4_assert "load failure rerun" 'parsed.converted.length' 0
csf4_assert "load failure rerun" "parsed.files.find((file) => file.path === '$FRAGILE').loaded" false
csf4_vitest_report "$WORK/load-report.json"
[ "$(node -p 'JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).numPassedTests' "$WORK/load-report.json")" -gt 0 ] \
  || { fail "no assertion passed beside the file that failed to load"; exit 1; }

csf4_reset_tree
csf4_drop_stories
csf4_install_fixture "$FIXTURES/failing-test"
csf4_commit "failing-test project"
csf4_migrate
csf4_expect "failing test" 1
csf4_assert "failing test" "parsed.files.find((file) => file.path.endsWith('gauge/tests/index.stories.tsx')).passed" false
csf4_assert "failing test" "parsed.files.find((file) => file.path.endsWith('gauge/tests/index.stories.tsx')).failures.includes('Half   claims the wrong level')" true

csf4_reset_tree
csf4_drop_stories
csf4_install_fixture "$FIXTURES/type-error"
csf4_commit "type-error project"
csf4_migrate
csf4_expect "type error" 1
csf4_assert "type error" 'parsed.typecheck.result' fail
csf4_assert "type error" "parsed.typecheck.files.includes('$STORY/meter/tests/index.stories.tsx')" true

# --- 7. Mixed tree -----------------------------------------------------------

csf4_reset_tree
csf4_install_fixture "$FIXTURES/adopter"
csf4_commit "mixed tree"
csf4_git ls-files 'frontend/app/**/*.stories.tsx' 'frontend/.storybook/preview.ts' 'frontend/.storybook/main.ts' \
  | grep -vE 'counter|signup-form|status-badge|item-list' > "$WORK/csf4-files.txt"
csf4_hash_list "$WORK/csf4-files.txt" > "$WORK/csf4-before.sha256"
log "migrate-csf4 on the mixed tree"
csf4_migrate
csf4_expect "mixed tree" 0
assert_all_loaded_and_passed "mixed tree"
csf4_assert "mixed tree" 'parsed.converted.length' 4
# shellcheck disable=SC2046
csf4_story_check shape $(frontend_stories) || { fail "a story file is not in CSF Next form"; exit 1; }
csf4_hash_list "$WORK/csf4-files.txt" | diff "$WORK/csf4-before.sha256" - >&2 \
  || { fail "the migration changed an already-CSF4 file"; exit 1; }

# --- 8. --update-merge on a committed tree -----------------------------------

csf4_reset_tree
csf4_install_fixture "$FIXTURES/adopter"
csf4_commit "mixed tree"
printf '\n// outside the write set\n' >> "$FRONTEND/app/components/ui/tests/alert.stories.tsx"
printf 'note\n' > "$FRONTEND/notes.txt"
printf '\n// uncommitted adopter edit\n' >> "$FRONTEND/app/components/counter/tests/index.stories.tsx"
csf4_fingerprint > "$WORK/merge-before.txt"
csf4_migrate --update-merge
csf4_expect "update-merge dirty write set" 3
csf4_assert "update-merge dirty write set" 'parsed.refused.reason' dirty-write-set
csf4_assert "update-merge dirty write set" "parsed.refused.paths.includes('$STORY/counter/tests/index.stories.tsx')" true
csf4_fingerprint | diff "$WORK/merge-before.txt" - >&2 || { fail "the refusal changed a file"; exit 1; }

csf4_git checkout -q -- frontend/app/components/counter/tests/index.stories.tsx
OUTSIDE_BEFORE="$(hash_file "$FRONTEND/app/components/ui/tests/alert.stories.tsx") $(hash_file "$FRONTEND/notes.txt")"
log "migrate-csf4 --update-merge on the committed mixed tree"
csf4_migrate --update-merge
csf4_expect "update-merge" 0
csf4_assert "update-merge" 'parsed.unexpectedChanges.length' 0
[ "$OUTSIDE_BEFORE" = "$(hash_file "$FRONTEND/app/components/ui/tests/alert.stories.tsx") $(hash_file "$FRONTEND/notes.txt")" ] \
  || { fail "update-merge touched an uncommitted file outside its write set"; exit 1; }

csf4_reset_tree
csf4_drop_stories
csf4_use_config preview-no-i18n.csf3.ts no-i18n
csf4_install_component adopter status-badge
csf4_commit "no-i18n project"
log "migrate-csf4 --update-merge on a preview without i18next"
csf4_migrate --update-merge
csf4_expect "no-i18n" 0
if grep -qiE 'i18n|definePreviewAddon' "$FRONTEND/.storybook/preview.ts"; then
  fail "a preview without i18next gained an i18next addon"
  exit 1
fi
grep -qF 'addonMsw()' "$FRONTEND/.storybook/preview.ts" || { fail "no-i18n preview lost msw"; exit 1; }

# --- 9. --update-merge on a real post-merge tree -----------------------------

csf4_reset_tree
csf4_drop_stories
csf4_use_config preview.csf3.ts
csf4_install_fixture "$FIXTURES/adopter"
for gaia_story in \
  "components/errors/error-stack/tests/index:error-stack" \
  "components/form/tests/composed-form:composed-form" \
  "pages/index/tests/page:index-page" \
  "components/ui/tests/toast:toast"; do
  mkdir -p "$(dirname "$FRONTEND/app/${gaia_story%%:*}")"
  cp "$GAIA_CLI_FIXTURES/${gaia_story##*:}.stories.tsx.csf3" "$FRONTEND/app/${gaia_story%%:*}.stories.tsx"
done
csf4_commit "pre-update tree"

# The update's three-way merge leaves GAIA's CSF4 files over HEAD, uncommitted.
csf4_git ls-tree -r --name-only "$BASE_COMMIT" -- frontend/app \
  | grep '\.stories\.tsx$' > "$WORK/overlay.txt"
printf '%s\n' frontend/.storybook/preview.ts frontend/.storybook/main.ts frontend/package.json >> "$WORK/overlay.txt"
# shellcheck disable=SC2046 # one path per line, none with whitespace
csf4_git checkout -q "$BASE_COMMIT" -- $(cat "$WORK/overlay.txt")
csf4_hash_list "$WORK/overlay.txt" > "$WORK/overlay-before.sha256"
log "migrate-csf4 --update-merge on the post-merge tree"
csf4_migrate --update-merge
csf4_expect "post-merge" 0
csf4_assert "post-merge" 'parsed.unexpectedChanges.length' 0
assert_all_loaded_and_passed "post-merge"
csf4_assert "post-merge" 'parsed.converted.length' 4
csf4_assert "post-merge" "parsed.restore.split(' -- ')[1].split(' ').every((file) => /(counter|signup-form|status-badge|item-list)/.test(file))" true
# shellcheck disable=SC2046
csf4_story_check shape $(frontend_stories) || { fail "a story file is not in CSF Next form"; exit 1; }
csf4_hash_list "$WORK/overlay.txt" | diff "$WORK/overlay-before.sha256" - >&2 \
  || { fail "the migration changed an overlaid file"; exit 1; }

pass "migrate-csf4: conversion, rerun, refusals, load failure, verification failures, mixed tree, and both update paths all green (${SECONDS}s)"
