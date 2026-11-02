#!/usr/bin/env bats
#
# Web rules and scaffolding reach only web-stack members, on every shape of the
# crossed monorepo: the default web member, a web member under another name at
# its own path, and two web-stack members. Each case builds its fixture with
# the real crossing verbs (lib/crossed-fixture.sh), so the registry, the stack
# marker, the opt-in and the roster are what the crossing writes.
#
# The CLI runs from source through a wrapper in $BATS_TEST_TMPDIR, so the suite
# needs no rebuilt bundle. GAIA_CROSSING_CLI points the same assertions at a
# built binary.
#
# Run under bash 5 (.claude/rules/bats-assertions.md):
#   bash .gaia/scripts/bats5.sh .gaia/scripts/tests/web-stack-reach.bats < /dev/null

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  command -v jq >/dev/null 2>&1 || skip "jq required"
  # shellcheck source=../../tests/distribution/lib/crossed-fixture.sh
  source "$REPO_ROOT/.gaia/tests/distribution/lib/crossed-fixture.sh"
  CLI_DIR="$REPO_ROOT/.gaia/cli"
  CONFIG_INVALID=30
  WEB_LENSES='react-patterns,translation,accessibility,project-specific-rules,security'
  if [ -n "${GAIA_CROSSING_CLI:-}" ]; then
    GAIA="$GAIA_CROSSING_CLI"
  else
    GAIA="$BATS_TEST_TMPDIR/gaia"
    printf '#!/usr/bin/env bash\nexec "%s/node_modules/.bin/tsx" "%s/src/index.ts" "$@"\n' \
      "$CLI_DIR" "$CLI_DIR" >"$GAIA"
    chmod +x "$GAIA"
  fi
  export GAIA CROSSED_FIXTURE_GAIA="$GAIA"
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
  unset GIT_DIR GIT_WORK_TREE GH_TOKEN GITHUB_REPOSITORY
  FIXTURE="$BATS_TEST_TMPDIR/fixture"
}

# gaia_in <dir> <args...>: runs the CLI with <dir> as the working directory.
gaia_in() {
  local dir="$1"
  shift
  run --separate-stderr bash -c 'cd "$1" && shift && "$GAIA" "$@"' _ "$dir" "$@"
}

# tree_digest <dir>: every file outside .git, by path and content digest.
tree_digest() {
  (cd "$1" && find . -path ./.git -prune -o -type f -print | LC_ALL=C sort | while IFS= read -r file; do
    printf '%s %s\n' "$(shasum -a 256 <"$file" | cut -d' ' -f1)" "$file"
  done)
}

# make_second_web <dir>: gives apps/mobile the web stack, for the two-member shape.
make_second_web() {
  jq '. + {stack: "web"}' "$1/apps/mobile/gaia.package.json" >"$1/apps/mobile/next.json"
  mv "$1/apps/mobile/next.json" "$1/apps/mobile/gaia.package.json"
}

# ========== the fixture helper ==========

@test "the fixture helper stops at a crossing binary that fails and leaves no tree" {
  printf '#!/usr/bin/env bash\nexit 1\n' >"$BATS_TEST_TMPDIR/broken"
  chmod +x "$BATS_TEST_TMPDIR/broken"
  CROSSED_FIXTURE_GAIA="$BATS_TEST_TMPDIR/broken"
  run --separate-stderr crossed_fixture_build "$FIXTURE"
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"crossing preflight failed"* ]]
  [ ! -e "$FIXTURE" ]
}

@test "the fixture helper refuses to run with no crossing binary named" {
  unset CROSSED_FIXTURE_GAIA GAIA_CROSSING_CLI
  run --separate-stderr crossed_fixture_build "$FIXTURE"
  [ "$status" -ne 0 ]
  [[ "$stderr" == *"CROSSED_FIXTURE_GAIA"* ]]
  [ ! -e "$FIXTURE" ]
}

@test "the crossed fixture carries what the crossing writes" {
  crossed_fixture_build "$FIXTURE"
  [ "$CROSSED_WEB_NAME" = web ]
  [ "$CROSSED_WEB_PATH" = apps/web ]
  [ "$(jq -r '.stack' "$FIXTURE/apps/web/gaia.package.json")" = web ]
  [ "$(jq -r '.generatedSettings' "$FIXTURE/apps/api/gaia.package.json")" = true ]
  [ "$(jq -r '.[] | select(.name == "mobile") | .path' "$FIXTURE/.gaia/packages.json")" = apps/mobile ]
  grep -qF 'infra' "$FIXTURE/.gaia/audit-ci.yml"
  [ "$(jq -c '.globs.tddUnitTests' "$FIXTURE/packages/kit/gaia.package.json")" = '[]' ]
}

# ========== rule locations ==========

# assert_rule_locations <dir> <web path...>: web rule files resolve to the
# listed web-stack members and to no other location.
assert_rule_locations() {
  local dir="$1" owner location listed expected
  shift
  # shellcheck source=../../../.claude/hooks/lib/gaia-packages.sh
  source "$REPO_ROOT/.claude/hooks/lib/gaia-packages.sh"
  gaia_packages_load "$dir"
  listed="$(gaia_packages_web_members | cut -f2 | sort | tr '\n' ' ')"
  expected="$(printf '%s\n' "$@" | sort | tr '\n' ' ')"
  [ "$listed" = "$expected" ]
  for location in apps/web apps/storefront apps/mobile packages packages/kit; do
    owner="$(gaia_package_for_path "$location/.claude/rules/rule.md" || true)"
    if printf '%s\n' "$@" | grep -qxF "$location"; then
      [ -n "$owner" ]
      gaia_package_is_web "$owner"
    elif [ -n "$owner" ]; then
      if gaia_package_is_web "$owner"; then return 1; fi
    fi
  done
}

@test "rule locations: only apps/web is a web rule location on the default fixture" {
  crossed_fixture_build "$FIXTURE"
  assert_rule_locations "$FIXTURE" apps/web
}

@test "rule locations: the storefront variant resolves web rules to apps/storefront only" {
  crossed_fixture_build "$FIXTURE" storefront
  [ "$CROSSED_WEB_PATH" = apps/storefront ]
  assert_rule_locations "$FIXTURE" apps/storefront
}

@test "rule locations: two web-stack members both resolve, a library still does not" {
  crossed_fixture_build "$FIXTURE"
  make_second_web "$FIXTURE"
  assert_rule_locations "$FIXTURE" apps/web apps/mobile
}

# ========== scaffold and rename ==========

# assert_non_web_refused <dir> <member> <web name>: scaffold and rename refuse a
# non-web member with CONFIG_INVALID, name the web member, and change no file.
assert_non_web_refused() {
  local dir="$1" member="$2" web="$3" before after
  before="$(tree_digest "$dir")"
  gaia_in "$dir" scaffold component Widget --package "$member"
  [ "$status" -eq "$CONFIG_INVALID" ]
  [[ "$stderr" == *"$web"* ]]
  gaia_in "$dir" init rename --title Renamed --kebab renamed --package "$member"
  [ "$status" -eq "$CONFIG_INVALID" ]
  [[ "$stderr" == *"$web"* ]]
  after="$(tree_digest "$dir")"
  [ "$before" = "$after" ]
}

# assert_writes_under_web <dir> <web path>: with no flag, scaffold from apps/mobile (rename needs the project root),
# scaffold and rename write under the web member.
assert_writes_under_web() {
  local dir="$1" web_path="$2"
  gaia_in "$dir/apps/mobile" scaffold component Widget
  [ "$status" -eq 0 ]
  [ -f "$dir/$web_path/app/components/widget/index.tsx" ]
  [ ! -e "$dir/apps/mobile/app" ]
  gaia_in "$dir" init rename --title Renamed --kebab renamed
  [ "$status" -eq 0 ]
  grep -qF "siteName: 'Renamed'" "$dir/$web_path/app/languages/en/common.ts"
}

@test "scaffold and rename: a non-web member is refused naming the web member, nothing changes" {
  crossed_fixture_build "$FIXTURE"
  assert_non_web_refused "$FIXTURE" mobile web
  assert_non_web_refused "$FIXTURE" kit web
  assert_non_web_refused "$FIXTURE" no-such-member web
}

@test "scaffold and rename: no flag writes under the web member from apps/mobile" {
  crossed_fixture_build "$FIXTURE"
  assert_writes_under_web "$FIXTURE" apps/web
}

@test "scaffold and rename: --package naming the web member writes under it" {
  crossed_fixture_build "$FIXTURE"
  gaia_in "$FIXTURE" scaffold component Widget --package web
  [ "$status" -eq 0 ]
  [ -f "$FIXTURE/apps/web/app/components/widget/index.tsx" ]
}

@test "scaffold and rename: the storefront variant behaves the same" {
  crossed_fixture_build "$FIXTURE" storefront
  assert_non_web_refused "$FIXTURE" mobile storefront
  assert_non_web_refused "$FIXTURE" web storefront
  assert_writes_under_web "$FIXTURE" apps/storefront
}

@test "scaffold and rename: two web members with no flag refuse naming both and change nothing" {
  crossed_fixture_build "$FIXTURE"
  make_second_web "$FIXTURE"
  local before after
  before="$(tree_digest "$FIXTURE")"
  gaia_in "$FIXTURE/apps/api" scaffold component Widget
  [ "$status" -eq "$CONFIG_INVALID" ]
  [[ "$stderr" == *web* ]]
  [[ "$stderr" == *mobile* ]]
  gaia_in "$FIXTURE" init rename --title Renamed --kebab renamed
  [ "$status" -eq "$CONFIG_INVALID" ]
  [[ "$stderr" == *web* ]]
  [[ "$stderr" == *mobile* ]]
  [ "$before" = "$(tree_digest "$FIXTURE")" ]
}

@test "scaffold and rename: two web members resolve once --package names one" {
  crossed_fixture_build "$FIXTURE"
  make_second_web "$FIXTURE"
  mkdir -p "$FIXTURE/apps/mobile/app/components"
  gaia_in "$FIXTURE" scaffold component Widget --package mobile
  [ "$status" -eq 0 ]
  [ -f "$FIXTURE/apps/mobile/app/components/widget/index.tsx" ]
  [ ! -e "$FIXTURE/apps/web/app/components/widget" ]
}

# ========== wiki classification ==========

# commit_file <dir> <path> <subject>: commits one new file under that subject.
commit_file() {
  mkdir -p "$(dirname "$1/$2")"
  printf 'export const x = 1;\n' >"$1/$2"
  git -C "$1" add -A
  git -C "$1" commit -q -m "$3"
}

# reason_of <subject>: the classification reason recorded for a commit subject.
reason_of() {
  jq -r --arg subject "$1" '.commits[] | select(.subject == $subject) | .suggestion_reason' <<<"$output"
}

# classify_after <dir> <base sha>: runs commit-classify over <base>..HEAD.
classify_after() {
  gaia_in "$1" wiki commit-classify --since "$2" --json
  [ "$status" -eq 0 ]
}

@test "wiki classification: source under the web member is source-bearing, a library is not" {
  crossed_fixture_build "$FIXTURE"
  local base
  base="$(git -C "$FIXTURE" rev-parse HEAD)"
  commit_file "$FIXTURE" apps/web/app/panel.ts 'feat: web panel'
  commit_file "$FIXTURE" packages/shared/src/panel.ts 'feat: shared panel'
  classify_after "$FIXTURE" "$base"
  [[ "$(reason_of 'feat: web panel')" == *'source-bearing path'* ]]
  [[ "$(reason_of 'feat: shared panel')" == *'defer to human review'* ]]
}

@test "wiki classification: the storefront variant classifies by stack, not by name" {
  crossed_fixture_build "$FIXTURE" storefront
  local base
  base="$(git -C "$FIXTURE" rev-parse HEAD)"
  commit_file "$FIXTURE" apps/storefront/app/panel.ts 'feat: storefront panel'
  commit_file "$FIXTURE" packages/shared/src/panel.ts 'feat: shared panel'
  classify_after "$FIXTURE" "$base"
  [[ "$(reason_of 'feat: storefront panel')" == *'source-bearing path'* ]]
  [[ "$(reason_of 'feat: shared panel')" == *'defer to human review'* ]]
}

@test "wiki classification: with two web members each one's source counts" {
  crossed_fixture_build "$FIXTURE"
  make_second_web "$FIXTURE"
  git -C "$FIXTURE" commit -q -am 'second web member'
  local base
  base="$(git -C "$FIXTURE" rev-parse HEAD)"
  commit_file "$FIXTURE" apps/web/app/panel.ts 'feat: web panel'
  commit_file "$FIXTURE" apps/mobile/app/panel.ts 'feat: mobile panel'
  commit_file "$FIXTURE" apps/api/src/panel.ts 'feat: api panel'
  classify_after "$FIXTURE" "$base"
  [[ "$(reason_of 'feat: web panel')" == *'source-bearing path'* ]]
  [[ "$(reason_of 'feat: mobile panel')" == *'source-bearing path'* ]]
  [[ "$(reason_of 'feat: api panel')" == *'defer to human review'* ]]
}

# ========== web lenses ==========

# build_review_branch <dir>: pushes the fixture to a bare origin, carrying the
# resolver and its libraries, then branches with one change per member.
build_review_branch() {
  local dir="$1" origin="$BATS_TEST_TMPDIR/origin.git" web_path="$2"
  mkdir -p "$dir/.claude/hooks" "$dir/.github"
  cp -R "$REPO_ROOT/.claude/hooks/lib" "$dir/.claude/hooks/lib"
  cp -R "$REPO_ROOT/.gaia/scripts" "$dir/.gaia/scripts"
  cp -R "$REPO_ROOT/.github/audit" "$dir/.github/audit"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m 'resolver machinery'
  git init -q --bare -b main "$origin"
  git -C "$dir" remote add origin "$origin"
  git -C "$dir" push -q origin main
  git -C "$dir" fetch -q origin
  git -C "$dir" checkout -q -b feature
  mkdir -p "$dir/$web_path/app" "$dir/apps/mobile/src" "$dir/packages/shared/src" "$dir/infra"
  printf 'export const Panel = () => t("hello");\n' >"$dir/$web_path/app/panel.tsx"
  printf 'export const Panel = () => t("hello");\n' >"$dir/apps/mobile/src/panel.tsx"
  printf 'export const shared = 1;\n' >"$dir/packages/shared/src/index.ts"
  printf 'resource "x" "y" {}\n' >"$dir/infra/main.tf"
  printf 'echo hi\n' >"$dir/infra/run.sh"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m change
}

resolve_scope() {
  run --separate-stderr bash "$1/.gaia/scripts/audit-resolve-scope.sh" --member code-audit-frontend --root "$1" \
    --skip-full-base --eligibility --review-path '*.ts' --review-path '*.tsx' --specialists </dev/null
}

has_line() {
  printf '%s\n' "$output" | grep -qxF -- "$1"
}

# assert_lenses_follow_stack <dir> <web path>
assert_lenses_follow_stack() {
  local dir="$1" web_path="$2"
  build_review_branch "$dir" "$web_path"
  resolve_scope "$dir"
  [ "$status" -eq 0 ]
  has_line "LENSES=$web_path/app/panel.tsx"$'\t'"$WEB_LENSES"
  has_line "LENSES=apps/mobile/src/panel.tsx"$'\t'security
  has_line "LENSES=packages/shared/src/index.ts"$'\t'security
  has_line "LENSES=infra/main.tf"$'\t'security
  has_line "LENSES=infra/run.sh"$'\t'security
  has_line "SPECIALIST=react-patterns tsx:$web_path/app/panel.tsx"
  has_line "SPECIALIST=translation i18n-signal:$web_path/app/panel.tsx"
  if printf '%s\n' "$output" | grep -F 'SPECIALIST=react-patterns' | grep -qF apps/mobile; then return 1; fi
  if printf '%s\n' "$output" | grep -F 'SPECIALIST=translation' | grep -qF apps/mobile; then return 1; fi
}

@test "web lenses: only the web member's paths take them, security stays on everywhere" {
  crossed_fixture_build "$FIXTURE"
  assert_lenses_follow_stack "$FIXTURE" apps/web
}

@test "web lenses: the storefront variant follows the stack" {
  crossed_fixture_build "$FIXTURE" storefront
  assert_lenses_follow_stack "$FIXTURE" apps/storefront
}

@test "web lenses: a second web-stack member takes them too" {
  crossed_fixture_build "$FIXTURE"
  make_second_web "$FIXTURE"
  git -C "$FIXTURE" commit -q -am 'second web member'
  build_review_branch "$FIXTURE" apps/web
  resolve_scope "$FIXTURE"
  [ "$status" -eq 0 ]
  has_line "LENSES=apps/mobile/src/panel.tsx"$'\t'"$WEB_LENSES"
  has_line "LENSES=packages/shared/src/index.ts"$'\t'security
}

# ========== generated settings ==========

@test "generated settings: web and opted-in members get the full file, others the stub, and the drift check passes" {
  crossed_fixture_build "$FIXTURE"
  mkdir -p "$FIXTURE/.claude/hooks/lib" "$FIXTURE/.gaia/scripts" "$FIXTURE/.gaia/cli"
  cp "$REPO_ROOT/.claude/settings.json" "$FIXTURE/.claude/settings.json"
  cp "$REPO_ROOT/.claude/hooks/lib/gaia-packages.sh" "$FIXTURE/.claude/hooks/lib/gaia-packages.sh"
  cp "$REPO_ROOT/.gaia/scripts/check-settings-drift.sh" "$FIXTURE/.gaia/scripts/check-settings-drift.sh"
  cp "$GAIA" "$FIXTURE/.gaia/cli/gaia"
  chmod +x "$FIXTURE/.gaia/cli/gaia"

  gaia_in "$FIXTURE" packages sync-settings
  [ "$status" -eq 0 ]

  local marker='# gaia-member-guards-stub'
  # The web-stack member and the opted-in member carry the full file.
  jq -e '.hooks.PreToolUse | length > 0' "$FIXTURE/apps/web/.claude/settings.json" >/dev/null
  jq -e '.hooks.PreToolUse | length > 0' "$FIXTURE/apps/api/.claude/settings.json" >/dev/null
  if grep -qF "$marker" "$FIXTURE/apps/web/.claude/settings.json"; then return 1; fi
  if grep -qF "$marker" "$FIXTURE/apps/api/.claude/settings.json"; then return 1; fi
  # A member that is neither carries the one-hook stub.
  grep -qF "$marker" "$FIXTURE/apps/mobile/.claude/settings.json"
  grep -qF "$marker" "$FIXTURE/packages/shared/.claude/settings.json"
  grep -qF "$marker" "$FIXTURE/infra/.claude/settings.json"

  run --separate-stderr bash "$FIXTURE/.gaia/scripts/check-settings-drift.sh" "$FIXTURE"
  [ "$status" -eq 0 ]
  [[ "$stderr" == *"clean"* ]]
}
