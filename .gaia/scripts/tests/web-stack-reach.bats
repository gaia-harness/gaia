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

# bats file_tags=installed-dependencies

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
    . "$BATS_TEST_DIRNAME/../../tests/hooks/helpers/require-node-typescript.sh"
    require_node_typescript "$REPO_ROOT"
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

@test "rule locations: web rule files resolve to web-stack members only (default, storefront, two-web case table)" {
  echo "case: only apps/web is a web rule location on the default fixture"
  crossed_fixture_build "$FIXTURE"
  cp -R "$FIXTURE" "$BATS_TEST_TMPDIR/two-web"
  assert_rule_locations "$FIXTURE" apps/web

  echo "case: the storefront variant resolves web rules to apps/storefront only"
  crossed_fixture_build "$BATS_TEST_TMPDIR/storefront" storefront
  [ "$CROSSED_WEB_PATH" = apps/storefront ]
  assert_rule_locations "$BATS_TEST_TMPDIR/storefront" apps/storefront

  echo "case: two web-stack members both resolve, a library still does not"
  make_second_web "$BATS_TEST_TMPDIR/two-web"
  assert_rule_locations "$BATS_TEST_TMPDIR/two-web" apps/web apps/mobile
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

# assert_writes_under_web <dir> <web path>: with no flag, scaffold run from
# apps/mobile and rename run from the project root both write under the web member.
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

@test "scaffold and rename: target resolves by stack (non-web refused, no-flag, --package, storefront, two-web refused, two-web with --package)" {
  crossed_fixture_build "$FIXTURE"
  cp -R "$FIXTURE" "$BATS_TEST_TMPDIR/no-flag"
  cp -R "$FIXTURE" "$BATS_TEST_TMPDIR/package-flag"
  cp -R "$FIXTURE" "$BATS_TEST_TMPDIR/two-web"

  echo "case: a non-web member is refused naming the web member, nothing changes"
  assert_non_web_refused "$FIXTURE" mobile web
  assert_non_web_refused "$FIXTURE" kit web
  assert_non_web_refused "$FIXTURE" no-such-member web

  echo "case: no flag writes under the web member from apps/mobile"
  assert_writes_under_web "$BATS_TEST_TMPDIR/no-flag" apps/web

  echo "case: --package naming the web member writes under it"
  gaia_in "$BATS_TEST_TMPDIR/package-flag" scaffold component Widget --package web
  [ "$status" -eq 0 ]
  [ -f "$BATS_TEST_TMPDIR/package-flag/apps/web/app/components/widget/index.tsx" ]

  echo "case: the storefront variant behaves the same"
  crossed_fixture_build "$BATS_TEST_TMPDIR/storefront" storefront
  assert_non_web_refused "$BATS_TEST_TMPDIR/storefront" mobile storefront
  assert_non_web_refused "$BATS_TEST_TMPDIR/storefront" web storefront
  assert_writes_under_web "$BATS_TEST_TMPDIR/storefront" apps/storefront

  echo "case: two web members with no flag refuse naming both and change nothing"
  make_second_web "$BATS_TEST_TMPDIR/two-web"
  local before
  before="$(tree_digest "$BATS_TEST_TMPDIR/two-web")"
  gaia_in "$BATS_TEST_TMPDIR/two-web/apps/api" scaffold component Widget
  [ "$status" -eq "$CONFIG_INVALID" ]
  [[ "$stderr" == *web* ]]
  [[ "$stderr" == *mobile* ]]
  gaia_in "$BATS_TEST_TMPDIR/two-web" init rename --title Renamed --kebab renamed
  [ "$status" -eq "$CONFIG_INVALID" ]
  [[ "$stderr" == *web* ]]
  [[ "$stderr" == *mobile* ]]
  [ "$before" = "$(tree_digest "$BATS_TEST_TMPDIR/two-web")" ]

  echo "case: two web members resolve once --package names one"
  mkdir -p "$BATS_TEST_TMPDIR/two-web/apps/mobile/app/components"
  gaia_in "$BATS_TEST_TMPDIR/two-web" scaffold component Widget --package mobile
  [ "$status" -eq 0 ]
  [ -f "$BATS_TEST_TMPDIR/two-web/apps/mobile/app/components/widget/index.tsx" ]
  [ ! -e "$BATS_TEST_TMPDIR/two-web/apps/web/app/components/widget" ]
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

@test "wiki classification: source under a web-stack member is source-bearing (default, storefront, two-web)" {
  local base

  echo "case: source under the web member is source-bearing, a library is not"
  crossed_fixture_build "$FIXTURE"
  cp -R "$FIXTURE" "$BATS_TEST_TMPDIR/two-web"
  base="$(git -C "$FIXTURE" rev-parse HEAD)"
  commit_file "$FIXTURE" apps/web/app/panel.ts 'feat: web panel'
  commit_file "$FIXTURE" packages/shared/src/panel.ts 'feat: shared panel'
  classify_after "$FIXTURE" "$base"
  [[ "$(reason_of 'feat: web panel')" == *'source-bearing path'* ]]
  [[ "$(reason_of 'feat: shared panel')" == *'defer to human review'* ]]

  echo "case: the storefront variant classifies by stack, not by name"
  crossed_fixture_build "$BATS_TEST_TMPDIR/storefront" storefront
  base="$(git -C "$BATS_TEST_TMPDIR/storefront" rev-parse HEAD)"
  commit_file "$BATS_TEST_TMPDIR/storefront" apps/storefront/app/panel.ts 'feat: storefront panel'
  commit_file "$BATS_TEST_TMPDIR/storefront" packages/shared/src/panel.ts 'feat: shared panel'
  classify_after "$BATS_TEST_TMPDIR/storefront" "$base"
  [[ "$(reason_of 'feat: storefront panel')" == *'source-bearing path'* ]]
  [[ "$(reason_of 'feat: shared panel')" == *'defer to human review'* ]]

  echo "case: with two web members each one's source counts"
  make_second_web "$BATS_TEST_TMPDIR/two-web"
  git -C "$BATS_TEST_TMPDIR/two-web" commit -q -am 'second web member'
  base="$(git -C "$BATS_TEST_TMPDIR/two-web" rev-parse HEAD)"
  commit_file "$BATS_TEST_TMPDIR/two-web" apps/web/app/panel.ts 'feat: web panel'
  commit_file "$BATS_TEST_TMPDIR/two-web" apps/mobile/app/panel.ts 'feat: mobile panel'
  commit_file "$BATS_TEST_TMPDIR/two-web" apps/api/src/panel.ts 'feat: api panel'
  classify_after "$BATS_TEST_TMPDIR/two-web" "$base"
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

@test "web lenses: only web-stack members take them, security everywhere (default, storefront, two-web)" {
  echo "case: only the web member's paths take them, security stays on everywhere"
  crossed_fixture_build "$FIXTURE"
  cp -R "$FIXTURE" "$BATS_TEST_TMPDIR/two-web"
  assert_lenses_follow_stack "$FIXTURE" apps/web

  echo "case: the storefront variant follows the stack"
  rm -rf "$BATS_TEST_TMPDIR/origin.git"
  crossed_fixture_build "$BATS_TEST_TMPDIR/storefront" storefront
  assert_lenses_follow_stack "$BATS_TEST_TMPDIR/storefront" apps/storefront

  echo "case: a second web-stack member takes them too"
  rm -rf "$BATS_TEST_TMPDIR/origin.git"
  make_second_web "$BATS_TEST_TMPDIR/two-web"
  git -C "$BATS_TEST_TMPDIR/two-web" commit -q -am 'second web member'
  build_review_branch "$BATS_TEST_TMPDIR/two-web" apps/web
  resolve_scope "$BATS_TEST_TMPDIR/two-web"
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
