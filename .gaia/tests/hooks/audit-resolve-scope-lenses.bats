#!/usr/bin/env bats
# The scope resolver's stack-aware specialist gating and LENSES= lines: a
# react-patterns or translation token needs a path under a web-stack member, and
# every path of the incremental diff gets a LENSES= line, security always on.
#
# Every case builds its own repository in $BATS_TEST_TMPDIR with a copy of the
# resolver and its libraries, so the registry under test is the fixture's.
#
# Run under bash 5 (.claude/rules/bats-assertions.md):
#   bash .gaia/scripts/bats5.sh .gaia/tests/hooks/audit-resolve-scope-lenses.bats < /dev/null
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  command -v jq >/dev/null 2>&1 || skip "jq required"
  FIXTURE="$BATS_TEST_TMPDIR/fixture"
  ORIGIN="$BATS_TEST_TMPDIR/origin.git"
  WEB_LENSES='react-patterns,translation,accessibility,project-specific-rules,security'
  REGISTRY_WEB_AND_LIBRARY='[{"name":"storefront","path":"apps/storefront"},{"name":"kit","path":"libs/kit"}]'
  unset GH_TOKEN GITHUB_REPOSITORY
}

fixture_git() {
  git -C "$FIXTURE" "$@"
}

# write_descriptor <directory> <name> [web]: a descriptor with empty glob lists.
write_descriptor() {
  mkdir -p "$FIXTURE/$1"
  {
    printf '{"schemaVersion":1,"name":"%s",' "$2"
    if [ "${3:-}" = web ]; then printf '"stack":"web",'; fi
    printf '"globs":{"tddUnitTests":[],"tddStrictCandidates":[],"emergentTests":[],"preCommitSource":[],"doctorConfigs":[],"dependencyManifests":[]},'
    printf '"wiki":{"sourcePaths":[],"inventoryPaths":[],"flowPaths":[]}}\n'
  } >"$FIXTURE/$1/gaia.package.json"
}

# build_base <registry-json>: a base commit on main carrying the resolver's
# machinery, a web member `storefront` at apps/storefront, a library `kit` at
# libs/kit, and the given registry; pushed to a bare origin.
build_base() {
  mkdir -p "$FIXTURE/.claude/hooks" "$FIXTURE/.gaia" "$FIXTURE/.github"
  git init -q -b main "$FIXTURE"
  git init -q --bare -b main "$ORIGIN"
  cp -R "$REPO_ROOT/.claude/hooks/lib" "$FIXTURE/.claude/hooks/lib"
  cp -R "$REPO_ROOT/.gaia/scripts" "$FIXTURE/.gaia/scripts"
  cp -R "$REPO_ROOT/.github/audit" "$FIXTURE/.github/audit"
  write_descriptor apps/storefront storefront web
  write_descriptor libs/kit kit
  printf '%s\n' "$1" >"$FIXTURE/.gaia/packages.json"
  fixture_git config user.email gaia-test@example.com
  fixture_git config user.name "GAIA Test"
  fixture_git config commit.gpgsign false
  fixture_git config core.hooksPath /dev/null
  fixture_git add -A
  fixture_git commit -q -m base
  fixture_git remote add origin "$ORIGIN"
  fixture_git push -q origin main
  fixture_git fetch -q origin
  fixture_git checkout -q -b feature
}

commit_files() {
  fixture_git add -A
  fixture_git commit -q -m change
}

# put <path> <text>: write a file's content.
put() {
  mkdir -p "$(dirname "$FIXTURE/$1")"
  printf '%s\n' "$2" >"$FIXTURE/$1"
}

# has_line <exact line>: 0 when the resolver output holds the line whole.
has_line() {
  printf '%s\n' "$output" | grep -qxF -- "$1"
}

# has_text <fixed text>: 0 when any output line holds the text.
has_text() {
  printf '%s\n' "$output" | grep -qF -- "$1"
}

# specialist_line_names <role> <fixed text>: 0 when the role's line holds the text.
specialist_line_names() {
  printf '%s\n' "$output" | grep -F -- "SPECIALIST=$1 " | grep -qF -- "$2"
}

# resolve: the member's literal command, from the fixture copy.
resolve() {
  bash "$FIXTURE/.gaia/scripts/audit-resolve-scope.sh" --member code-audit-frontend --root "$FIXTURE" \
    --skip-full-base --eligibility --review-path '*.ts' --review-path '*.tsx' --specialists </dev/null
}

@test "a library .tsx with an i18n call produces no react-patterns or translation token, the web member produces both" {
  build_base "$REGISTRY_WEB_AND_LIBRARY"
  put libs/kit/src/panel.tsx 'export const Panel = () => t("hello");'
  put apps/storefront/app/panel.tsx 'export const Panel = () => t("hello");'
  commit_files
  run --separate-stderr resolve
  [ "$status" -eq 0 ]
  has_line "SPECIALIST=react-patterns tsx:apps/storefront/app/panel.tsx"
  has_line "SPECIALIST=translation i18n-signal:apps/storefront/app/panel.tsx"
  has_line "SPECIALIST=typescript tsx:apps/storefront/app/panel.tsx tsx:libs/kit/src/panel.tsx"
  if specialist_line_names react-patterns "libs/kit"; then return 1; fi
  if specialist_line_names translation "libs/kit"; then return 1; fi
  true
}

@test "the member's literal command gives every diff path a LENSES line with security while CHANGED stays TypeScript" {
  put libs/kit/src/doomed.ts 'export const x = 1;'
  build_base "$REGISTRY_WEB_AND_LIBRARY"
  put libs/kit/src/index.ts 'export const y = 2;'
  put libs/kit/main.tf 'resource "x" "y" {}'
  put libs/kit/run.sh 'echo hi'
  put apps/storefront/app/app.css 'a { color: red; }'
  fixture_git rm -q libs/kit/src/doomed.ts
  commit_files
  run --separate-stderr resolve
  [ "$status" -eq 0 ]
  has_line "LENSES=libs/kit/src/index.ts"$'\t'"security"
  has_line "LENSES=libs/kit/main.tf"$'\t'"security"
  has_line "LENSES=libs/kit/run.sh"$'\t'"security"
  has_line "LENSES=libs/kit/src/doomed.ts"$'\t'"security"
  has_line "LENSES=apps/storefront/app/app.css"$'\t'"$WEB_LENSES"
  has_line "CHANGED=libs/kit/src/index.ts"
  if has_line "CHANGED=libs/kit/run.sh"; then return 1; fi
  if has_line "CHANGED=apps/storefront/app/app.css"; then return 1; fi
  true
}

@test "a language file under a web member is a language-file token, the same shape under a library is not" {
  build_base "$REGISTRY_WEB_AND_LIBRARY"
  put apps/storefront/app/languages/en/common.ts 'export default { a: "b" };'
  put libs/kit/app/languages/en/common.ts 'export default { a: "b" };'
  commit_files
  run --separate-stderr resolve
  [ "$status" -eq 0 ]
  has_line "SPECIALIST=translation language-file:apps/storefront/app/languages/en/common.ts"
  if has_text "language-file:libs/kit"; then return 1; fi
  true
}

@test "a language file under a sole web member at the repository root is a language-file token" {
  write_descriptor . root web
  build_base '[{"name":"root","path":"."}]'
  put app/languages/en/common.ts 'export default { a: "b" };'
  commit_files
  run --separate-stderr resolve
  [ "$status" -eq 0 ]
  has_line "SPECIALIST=translation language-file:app/languages/en/common.ts"
}

@test "a root web member beside apps/storefront keeps a language-file token for both" {
  write_descriptor . root web
  build_base '[{"name":"root","path":"."},{"name":"storefront","path":"apps/storefront"}]'
  put app/languages/en/common.ts 'export default { a: "b" };'
  put apps/storefront/app/languages/en/common.ts 'export default { a: "b" };'
  commit_files
  run --separate-stderr resolve
  [ "$status" -eq 0 ]
  specialist_line_names translation "language-file:app/languages/en/common.ts"
  specialist_line_names translation "language-file:apps/storefront/app/languages/en/common.ts"
}

@test "a path owned by no member reads as not web" {
  build_base '[{"name":"storefront","path":"apps/storefront"}]'
  put scripts/orphan.tsx 'export const O = () => t("x");'
  commit_files
  run --separate-stderr resolve
  [ "$status" -eq 0 ]
  has_line "LENSES=scripts/orphan.tsx"$'\t'"security"
  if has_text "SPECIALIST=react-patterns"; then return 1; fi
  if has_text "SPECIALIST=translation"; then return 1; fi
  true
}

@test "a registry read failure keeps every lens on and says so on stderr" {
  build_base "$REGISTRY_WEB_AND_LIBRARY"
  printf 'not json' >"$FIXTURE/.gaia/packages.json"
  put libs/kit/src/panel.tsx 'export const Panel = () => t("hello");'
  commit_files
  run --separate-stderr resolve
  [ "$status" -eq 0 ]
  has_line "SPECIALIST=react-patterns tsx:libs/kit/src/panel.tsx"
  has_line "SPECIALIST=translation i18n-signal:libs/kit/src/panel.tsx"
  has_line "LENSES=libs/kit/src/panel.tsx"$'\t'"$WEB_LENSES"
  [[ "$stderr" == *"could not read the package registry"* ]]
}

@test "text check: the agent file scopes the web lenses by LENSES and splits the typescript dispatch (prose, not behavior)" {
  agent="$REPO_ROOT/.claude/agents/code-audit-frontend.md"
  grep -qF 'whose `LENSES=` line lists `accessibility`' "$agent"
  grep -qF 'lists `project-specific-rules`' "$agent"
  grep -qF 'splits the `typescript` dispatch in two' "$agent"
  grep -qF 'goes only to a specialist reviewing a path whose `LENSES=` line' "$agent"
}

@test "emitting LENSES over CHANGED instead of the diff drops the .sh path (mutation)" {
  build_base "$REGISTRY_WEB_AND_LIBRARY"
  put libs/kit/run.sh 'echo hi'
  commit_files
  sed 's/\${lens_paths\[@\]+"\${lens_paths\[@\]}"}/${changed[@]+"${changed[@]}"}/' \
    "$FIXTURE/.gaia/scripts/audit-resolve-scope.sh" >"$BATS_TEST_TMPDIR/mutant.sh"
  if cmp -s "$BATS_TEST_TMPDIR/mutant.sh" "$FIXTURE/.gaia/scripts/audit-resolve-scope.sh"; then return 1; fi
  cp "$BATS_TEST_TMPDIR/mutant.sh" "$FIXTURE/.gaia/scripts/audit-resolve-scope.sh"
  run --separate-stderr resolve
  if has_text "LENSES=libs/kit/run.sh"; then return 1; fi
  true
}
