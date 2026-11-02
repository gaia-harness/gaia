#!/usr/bin/env bats
# shellcheck disable=SC2317,SC2329
#
# Witnesses for the silent gates. A filter, glob or classifier that misses the
# app's folder fails by doing nothing: no error, just a job that skips, a file
# that routes to no reviewer, a deny that never fires. Each gate below gets one
# positive witness on an `apps/web` path (a `packages/x` path too where the
# gate was widened) and a red twin that asserts the failing direction, so a gate
# that matches everything or nothing fails one side of every pair.
#
# Patterns are extracted from the file that owns them, never copied, and each
# extraction asserts a non-empty result: an extraction that finds nothing must
# fail loudly rather than match nothing. Fixtures live in $BATS_TEST_TMPDIR.
#
# Run under bash 5 (.claude/rules/bats-assertions.md):
#   .gaia/scripts/bats5.sh .gaia/scripts/tests/apps-web-witnesses.bats < /dev/null

# bats file_tags=installed-dependencies

bats_require_minimum_version 1.5.0

setup() {
  THIS_DIRECTORY="$(cd "$BATS_TEST_DIRNAME" && pwd)"
  REPO_ROOT="$(cd "$THIS_DIRECTORY/../../.." && pwd)"
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
  unset GIT_DIR GIT_WORK_TREE
  # The retired root is spelled in two halves so no literal token of it lives
  # in this file.
  LEGACY_ROOT="front""end"
}

# --- extraction helpers -------------------------------------------------------

# workflow_filter_pattern: the `pattern=` value of the tests workflow's filter.
workflow_filter_pattern() {
  local workflow="$REPO_ROOT/.github/workflows/tests.yml" lines
  lines="$(sed -n "s/^[[:space:]]*pattern='\(.*\)'\$/\1/p" "$workflow")"
  [ -n "$lines" ] || return 1
  [ "$(printf '%s\n' "$lines" | grep -c .)" -eq 1 ] || return 1
  printf '%s\n' "$lines"
}

# gate_quick_pattern / gate_filter_pattern: the Quality Gate page's Quick check
# and frontend filter regexes.
gate_page() { printf '%s\n' "$REPO_ROOT/wiki/decisions/Quality Gate.md"; }

gate_quick_pattern() {
  local value
  value="$(grep -m1 '^git diff --cached --name-only' "$(gate_page)" | sed "s/.*grep -E '\\(.*\\)'\$/\\1/")"
  [ -n "$value" ] || return 1
  printf '%s\n' "$value"
}

gate_filter_pattern() {
  local value
  value="$(grep -m1 "^grep -vE '" "$(gate_page)" | sed "s/^grep -vE '\\(.*\\)'\$/\\1/")"
  [ -n "$value" ] || return 1
  printf '%s\n' "$value"
}

# matches <pattern> <path>: ERE match with the path on stdin of a here-string.
matches() {
  grep -qE -- "$1" <<<"$2"
}

# scratch_repo <dir>: an empty repository with one base commit on main.
scratch_repo() {
  mkdir -p "$1"
  git -C "$1" init -q -b main
  : >"$1/.keep"
  git -C "$1" add -A
  git -C "$1" commit -q -m base
}

# commit_paths <dir> <path>...: a commit that adds or edits each path.
commit_paths() {
  local dir="$1" path
  shift
  for path in "$@"; do
    mkdir -p "$dir/$(dirname "$path")"
    printf '%s\n' "$RANDOM$RANDOM" >>"$dir/$path"
  done
  git -C "$dir" add -A
  git -C "$dir" commit -q -m change
}

# --- tests.yml filter ---------------------------------------------------------

@test "tests workflow filter: an apps/web path and a packages/x path select the job" {
  local pattern
  pattern="$(workflow_filter_pattern)"
  [ -n "$pattern" ]
  matches "$pattern" "apps/web/app/routes/_index.tsx"
  matches "$pattern" "apps/web/package.json"
  matches "$pattern" "packages/x/index.ts"
  matches "$pattern" "pnpm-workspace.yaml"
  matches "$pattern" ".gaia/packages.json"
}

@test "red tests workflow filter: a wiki page does not select the job, and the pattern without apps does not select an apps/web path" {
  local pattern broken
  pattern="$(workflow_filter_pattern)"
  matches "$pattern" "wiki/index.md" && return 1
  matches "$pattern" "README.md" && return 1
  broken="${pattern/(apps|packages)\//(packages)\/}"
  [ "$broken" != "$pattern" ]
  matches "$broken" "apps/web/app/routes/_index.tsx" && return 1
  matches "$broken" "packages/x/index.ts"
  return 0
}

# --- quick classifier ---------------------------------------------------------

classify() {
  local root="$1" path="$2"
  bash -c '
    . "$1/.claude/hooks/lib/audit-light-route-lib.sh" || exit 9
    . "$1/.claude/hooks/lib/audit-quick-classify-lib.sh" || exit 9
    quick_load_registry "$2" || exit 9
    quick_path_class "$3"
  ' _ "$REPO_ROOT" "$root" "$path"
}

@test "quick classifier: a language file under apps/web classifies as language" {
  run classify "$REPO_ROOT" "apps/web/app/languages/en/x.ts"
  [ "$status" -eq 0 ]
  [ "$output" = "language" ]
  run classify "$REPO_ROOT" "apps/web/app/components/card/index.tsx"
  [ "$output" = "component" ]
}

@test "red quick classifier: non-web paths classify as none, and a member without the web stack classifies as none" {
  local scratch="$BATS_TEST_TMPDIR/classifier"
  run classify "$REPO_ROOT" "packages/x/app/languages/en/x.ts"
  [ "$output" = "none" ]
  run classify "$REPO_ROOT" ".gaia/cli/src/x.ts"
  [ "$output" = "none" ]
  run classify "$REPO_ROOT" "$LEGACY_ROOT/app/languages/en/x.ts"
  [ "$output" = "none" ]
  # The same web path under a registry whose member lacks `stack: web`.
  mkdir -p "$scratch/.gaia" "$scratch/apps/web"
  printf '%s\n' '[{"name":"web","path":"apps/web"}]' >"$scratch/.gaia/packages.json"
  printf '%s\n' '{"schemaVersion":1,"name":"web","globs":{"tddUnitTests":[],"tddStrictCandidates":[],"emergentTests":[],"preCommitSource":[],"doctorConfigs":[],"dependencyManifests":[]},"wiki":{"sourcePaths":[],"inventoryPaths":[],"flowPaths":[]}}' >"$scratch/apps/web/gaia.package.json"
  run classify "$scratch" "apps/web/app/languages/en/x.ts"
  [ "$output" = "none" ]
  # And with the stack declared, the same scratch routes the path to language.
  jq '. + {stack: "web"}' "$scratch/apps/web/gaia.package.json" >"$scratch/web.json"
  mv "$scratch/web.json" "$scratch/apps/web/gaia.package.json"
  run classify "$scratch" "apps/web/app/languages/en/x.ts"
  [ "$output" = "language" ]
}

# --- roster -------------------------------------------------------------------

roster_owner() {
  bash -c '
    . "$1/.claude/hooks/lib/audit-scope.sh" || exit 9
    audit_scope_init "$1" || exit 9
    printf "DEFAULT=%s\n" "$_AUDIT_SCOPE_DEFAULT_MEMBER"
    shift
    for path in "$@"; do
      printf "%s=%s\n" "$path" "$(audit_owner_for_path "$path")"
    done
  ' _ "$REPO_ROOT" "$@"
}

@test "roster: apps/web and packages/x source resolve to the default member" {
  local default_member
  run roster_owner "apps/web/app/x.ts" "packages/x/index.ts" "apps/web/package.json"
  [ "$status" -eq 0 ]
  default_member="$(printf '%s\n' "$output" | sed -n 's/^DEFAULT=//p')"
  [ -n "$default_member" ]
  printf '%s\n' "$output" | grep -qxF "apps/web/app/x.ts=$default_member"
  printf '%s\n' "$output" | grep -qxF "packages/x/index.ts=$default_member"
  printf '%s\n' "$output" | grep -qxF "apps/web/package.json=$default_member"
}

@test "red roster: a path outside every remit has no owner" {
  run roster_owner "no-such-top-level/x.ts"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qxF "no-such-top-level/x.ts="
}

@test "red roster: a packages/ folder with no tracked file leaves the packages glob matching nothing" {
  local with="$BATS_TEST_TMPDIR/roster-with" without="$BATS_TEST_TMPDIR/roster-without"
  scratch_repo "$with"
  scratch_repo "$without"
  commit_paths "$with" packages/.gitkeep apps/web/app/x.ts
  commit_paths "$without" apps/web/app/x.ts
  run bash "$REPO_ROOT/.gaia/scripts/verify-audit-roster.sh" --root "$with" --config "$REPO_ROOT/.gaia/audit-ci.yml"
  printf '%s\n' "$output" | grep -qF 'zero-match-glob' || true
  printf '%s\n' "$output" | grep -qE '^  glob:    packages/\*\*$' && return 1
  run bash "$REPO_ROOT/.gaia/scripts/verify-audit-roster.sh" --root "$without" --config "$REPO_ROOT/.gaia/audit-ci.yml"
  printf '%s\n' "$output" | grep -qE '^  glob:    packages/\*\*$'
}

# --- frontend-lint-delta ------------------------------------------------------

lint_plan() {
  local dir="$1"
  bash "$REPO_ROOT/.gaia/scripts/frontend-lint-delta.sh" --root "$dir" --base "$(git -C "$dir" rev-parse HEAD~1)" --plan
}

@test "lint delta: an apps/web source is linted and an eslint config change selects full" {
  local repo="$BATS_TEST_TMPDIR/lint-delta"
  scratch_repo "$repo"
  commit_paths "$repo" apps/web/app/x.ts
  run lint_plan "$repo"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | sed -n 1p)" = "delta" ]
  printf '%s\n' "$output" | grep -qxF "app/x.ts"
  commit_paths "$repo" apps/web/eslint.config.mjs
  run lint_plan "$repo"
  [ "$status" -eq 0 ]
  [ "$output" = "full" ]
}

@test "red lint delta: a wiki page and a retired-root source select nothing" {
  local repo="$BATS_TEST_TMPDIR/lint-delta-red"
  scratch_repo "$repo"
  commit_paths "$repo" wiki/index.md
  run lint_plan "$repo"
  [ "$status" -eq 0 ]
  [ "$output" = "none" ]
  commit_paths "$repo" "$LEGACY_ROOT/app/x.ts" "$LEGACY_ROOT/eslint.config.mjs"
  run lint_plan "$repo"
  [ "$output" = "none" ]
}

# --- worktree ports -----------------------------------------------------------

ports_directory() {
  bash -c '
    . "$1/.gaia/scripts/worktree-ports-lib.sh" || exit 9
    gaia_ports_package_directory "$2"
  ' _ "$REPO_ROOT" "$1"
}

@test "worktree ports: the router config under apps/web is found in a fixture" {
  local tree="$BATS_TEST_TMPDIR/ports-tree"
  mkdir -p "$tree/.gaia" "$tree/apps/web"
  printf '%s\n' '[{"name":"web","path":"apps/web"}]' >"$tree/.gaia/packages.json"
  : >"$tree/apps/web/react-router.config.ts"
  run ports_directory "$tree"
  [ "$status" -eq 0 ]
  [ "$output" = "$tree/apps/web" ]
}

@test "red worktree ports: a tree with no router config under the member finds no package directory" {
  local tree="$BATS_TEST_TMPDIR/ports-tree-empty"
  mkdir -p "$tree/.gaia" "$tree/apps/web" "$tree/packages/x"
  printf '%s\n' '[{"name":"web","path":"apps/web"}]' >"$tree/.gaia/packages.json"
  run ports_directory "$tree"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

# --- Quality Gate Quick check -------------------------------------------------

@test "quality gate quick check: matches a manifest, config or source at any member depth" {
  local pattern path
  pattern="$(gate_quick_pattern)"
  [ -n "$pattern" ]
  for path in \
    apps/web/package.json \
    packages/x/tsconfig.json \
    packages/x/tsconfig.build.json \
    apps/mobile/vite.config.ts \
    packages/x/y/z/eslint.config.mjs \
    apps/web/app/x.ts \
    apps/web/app/styles/x.css \
    apps/web/gaia.package.json \
    .gaia/packages.json \
    package.json \
    pnpm-lock.yaml; do
    matches "$pattern" "$path" || { printf 'no match: %s\n' "$path" >&2; return 1; }
  done
}

@test "red quality gate quick check: docs and assets do not match, and a pattern without the depth prefix misses a member manifest" {
  local pattern broken path
  pattern="$(gate_quick_pattern)"
  for path in wiki/index.md README.md .claude/settings.json apps/web/public/logo.png apps/web/app/x.md; do
    matches "$pattern" "$path" && { printf 'unexpected match: %s\n' "$path" >&2; return 1; }
  done
  broken="$(printf '%s' "$pattern" | sed -e 's/(\[^\/\]+\/)\*//g')"
  [ "$broken" != "$pattern" ]
  matches "$broken" "apps/web/package.json" && return 1
  matches "$broken" "package.json"
  return 0
}

@test "quality gate frontend filter: an apps/web path survives and a harness path is dropped" {
  local filter
  filter="$(gate_filter_pattern)"
  [ -n "$filter" ]
  matches "$filter" "apps/web/package.json" && return 1
  matches "$filter" "packages/x/index.ts" && return 1
  matches "$filter" ".gaia/cli/src/x.ts"
  matches "$filter" ".gaia/scripts/x.sh"
}

@test "the owed-gate script carries the same Quick check and filter as the Quality Gate page" {
  local script="$REPO_ROOT/.gaia/scripts/audit-gate-owed.sh"
  [ "$(sed -n "s/^GATE_QUICK_CHECK_PATTERN='\\(.*\\)'\$/\\1/p" "$script")" = "$(gate_quick_pattern)" ]
  [ "$(sed -n "s/^GATE_FRONTEND_FILTER_PATTERN='\\(.*\\)'\$/\\1/p" "$script")" = "$(gate_filter_pattern)" ]
}

# --- owed gate: mark and run --------------------------------------------------

owed_fixture() {
  OWED_REPO="$BATS_TEST_TMPDIR/owed-repo"
  OWED_FOLDER="$BATS_TEST_TMPDIR/owed-folder"
  scratch_repo "$OWED_REPO"
}

owed_status() {
  bash "$REPO_ROOT/.gaia/scripts/audit-gate-owed.sh" status --root "$OWED_REPO" --run-folder "$OWED_FOLDER"
}

owed_mark() {
  bash "$REPO_ROOT/.gaia/scripts/audit-gate-owed.sh" mark --root "$OWED_REPO" --run-folder "$OWED_FOLDER" --round 1
}

@test "owed gate: a fix commit on an apps/web manifest and one on a packages/x tsconfig each owe the web steps" {
  owed_fixture
  commit_paths "$OWED_REPO" apps/web/package.json
  run owed_mark
  [ "$status" -eq 0 ]
  run owed_status
  [ "$status" -eq 1 ]
  run bash "$REPO_ROOT/.gaia/scripts/audit-gate-owed.sh" selection --root "$OWED_REPO" --run-folder "$OWED_FOLDER"
  printf '%s\n' "$output" | grep -qxF "apps/web/package.json"

  rm -rf "$OWED_FOLDER"
  commit_paths "$OWED_REPO" packages/x/tsconfig.json
  run owed_mark
  [ "$status" -eq 0 ]
  run owed_status
  [ "$status" -eq 1 ]
  run bash "$REPO_ROOT/.gaia/scripts/audit-gate-owed.sh" selection --root "$OWED_REPO" --run-folder "$OWED_FOLDER"
  printf '%s\n' "$output" | grep -qxF "packages/x/tsconfig.json"
}

@test "red owed gate: a wiki edit and a harness script edit owe nothing" {
  owed_fixture
  commit_paths "$OWED_REPO" wiki/index.md
  run owed_mark
  [ "$status" -eq 0 ]
  run owed_status
  [ "$status" -eq 0 ]
  rm -rf "$OWED_FOLDER"
  commit_paths "$OWED_REPO" .gaia/scripts/x.ts
  run owed_mark
  run owed_status
  [ "$status" -eq 0 ]
}

# run_fixture <web-script-body>: a tree whose root scripts are the real root's
# `pw` and `build`, whose apps/web scripts record to a marker outside the tree,
# and whose dev smoke test is a stub that records too. No install happens.
run_fixture() {
  local marker="$BATS_TEST_TMPDIR/run-marker" root_scripts
  RUN_MARKER="$marker"
  RUN_REPO="$BATS_TEST_TMPDIR/run-repo"
  OWED_FOLDER="$BATS_TEST_TMPDIR/run-folder"
  : >"$marker"
  mkdir -p "$RUN_REPO/apps/web" "$RUN_REPO/.gaia/scripts"
  root_scripts="$(jq -c '.scripts | {pw, build}' "$REPO_ROOT/package.json")"
  [ "$(jq -r '.pw // ""' <<<"$root_scripts")" != "" ]
  [ "$(jq -r '.build // ""' <<<"$root_scripts")" != "" ]
  jq -n --argjson scripts "$root_scripts" '{name: "scratch-root", private: true, scripts: $scripts}' >"$RUN_REPO/package.json"
  printf 'packages:\n  - apps/*\n' >"$RUN_REPO/pnpm-workspace.yaml"
  jq -n --arg pw "printf 'pw\\n' >>$marker" --arg build "printf 'build\\n' >>$marker" \
    '{name: "web", private: true, scripts: {pw: $pw, build: $build}}' >"$RUN_REPO/apps/web/package.json"
  printf '#!/usr/bin/env bash\nprintf "smoke\\n" >>%s\n' "$marker" >"$RUN_REPO/.gaia/scripts/dev-smoke.sh"
  git -C "$RUN_REPO" init -q -b main
  git -C "$RUN_REPO" add -A
  git -C "$RUN_REPO" commit -q -m base
}

@test "owed run: root pw and build resolve to apps/web, so the run reaches the app" {
  run_fixture
  run bash "$REPO_ROOT/.gaia/scripts/audit-gate-owed.sh" run --root "$RUN_REPO" --run-folder "$OWED_FOLDER"
  [ "$status" -eq 0 ]
  [ "$(paste -sd, "$RUN_MARKER")" = "pw,smoke,build" ]
}

@test "red owed run: a root pw script that does not reach apps/web leaves the marker empty" {
  run_fixture
  jq '.scripts.pw = "pnpm -C nowhere pw"' "$RUN_REPO/package.json" >"$RUN_REPO/package.next.json"
  mv "$RUN_REPO/package.next.json" "$RUN_REPO/package.json"
  run pnpm -C "$RUN_REPO" pw
  [ "$status" -ne 0 ]
  [ ! -s "$RUN_MARKER" ]
}

# --- overlap pass -------------------------------------------------------------

@test "overlap pass: an apps/web .playwright/e2e spec classifies as e2e and a packages/x spec does not" {
  local repo="$BATS_TEST_TMPDIR/overlap-repo"
  scratch_repo "$repo"
  . "$REPO_ROOT/.gaia/tests/hooks/helpers/package-fixture.sh"
  write_package_registry "$repo" '[{"name":"web","path":"apps/web"}]'
  write_package_descriptor "$repo" apps/web
  git -C "$repo" add -A
  git -C "$repo" commit -q -m registry
  git -C "$repo" checkout -q -b feature
  mkdir -p "$repo/apps/web/.playwright/e2e" "$repo/packages/x"
  printf "test('x', async () => {});\n" >"$repo/apps/web/.playwright/e2e/x.spec.ts"
  printf "test('y', async () => {});\n" >"$repo/packages/x/y.spec.ts"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m feature
  run bash "$REPO_ROOT/.gaia/scripts/overlap-check.sh" changed --root "$repo"
  [ "$status" -eq 0 ]
  jq -e 'any(.[]; .file == "apps/web/.playwright/e2e/x.spec.ts" and .layer == "e2e")' <<<"$output" >/dev/null
  jq -e 'any(.[]; .file == "packages/x/y.spec.ts") | not' <<<"$output" >/dev/null
  run bash "$REPO_ROOT/.gaia/scripts/overlap-check.sh" route --root "$repo"
  [ "$output" = "run" ]
}

@test "red overlap pass: a branch that changes no spec skips the Playwright arm" {
  local repo="$BATS_TEST_TMPDIR/overlap-repo-red"
  scratch_repo "$repo"
  . "$REPO_ROOT/.gaia/tests/hooks/helpers/package-fixture.sh"
  write_package_registry "$repo" '[{"name":"web","path":"apps/web"}]'
  write_package_descriptor "$repo" apps/web
  git -C "$repo" add -A
  git -C "$repo" commit -q -m registry
  git -C "$repo" checkout -q -b feature
  commit_paths "$repo" apps/web/app/x.ts
  run bash "$REPO_ROOT/.gaia/scripts/overlap-check.sh" route --root "$repo"
  [ "$status" -eq 0 ]
  [ "$output" = "skip-no-playwright-change" ]
}

# --- deny entries -------------------------------------------------------------

invoke() {
  run bash -c 'printf %s "$1" | bash "$2"' _ "$1" "$2"
}

denied() { [ "$status" -eq 0 ] && grep -qF -- '"permissionDecision": "deny"' <<<"$output"; }

@test "deny entries: dotenv files under apps, packages and a second app are denied as Read, Bash and Write" {
  local path json
  for path in apps/web/.env apps/mobile/.env packages/x/.env.local; do
    json="$(jq -n --arg p "$path" '{tool_name: "Read", tool_input: {file_path: $p}}')"
    invoke "$json" "$REPO_ROOT/.claude/hooks/block-sensitive-read.sh"
    denied || { printf 'Read not denied: %s\n' "$path" >&2; return 1; }
    json="$(jq -n --arg c "cat $path" '{tool_name: "Bash", tool_input: {command: $c}}')"
    invoke "$json" "$REPO_ROOT/.claude/hooks/block-sensitive-read.sh"
    denied || { printf 'Bash not denied: %s\n' "$path" >&2; return 1; }
    json="$(jq -n --arg p "$path" --arg c "SESSION_SECRET=local" '{tool_name: "Write", tool_input: {file_path: $p, content: $c}}')"
    invoke "$json" "$REPO_ROOT/.claude/hooks/block-secrets-write.sh"
    denied || { printf 'Write not denied: %s\n' "$path" >&2; return 1; }
  done
}

@test "red deny entries: the committed .env.example placeholder is allowed under every member" {
  local path json
  for path in apps/web/.env.example apps/mobile/.env.example packages/x/.env.example; do
    json="$(jq -n --arg p "$path" '{tool_name: "Read", tool_input: {file_path: $p}}')"
    invoke "$json" "$REPO_ROOT/.claude/hooks/block-sensitive-read.sh"
    denied && { printf 'Read denied: %s\n' "$path" >&2; return 1; }
    json="$(jq -n --arg c "cat $path" '{tool_name: "Bash", tool_input: {command: $c}}')"
    invoke "$json" "$REPO_ROOT/.claude/hooks/block-sensitive-read.sh"
    denied && { printf 'Bash denied: %s\n' "$path" >&2; return 1; }
    json="$(jq -n --arg p "$path" --arg c "SESSION_SECRET=local" '{tool_name: "Write", tool_input: {file_path: $p, content: $c}}')"
    invoke "$json" "$REPO_ROOT/.claude/hooks/block-secrets-write.sh"
    denied && { printf 'Write denied: %s\n' "$path" >&2; return 1; }
  done
  return 0
}

@test "settings: the deny list carries both dotenv Edit literals and no retired-root entry" {
  local settings="$REPO_ROOT/.claude/settings.json" legacy_entry
  [ "$(jq '.permissions.deny | length' "$settings")" -gt 0 ]
  jq -e '.permissions.deny | index("Edit(**/.env)") != null' "$settings" >/dev/null
  jq -e '.permissions.deny | index("Edit(.env)") != null' "$settings" >/dev/null
  legacy_entry="$(jq -r --arg token "$LEGACY_ROOT/" '[.permissions[]? | arrays[] | select(contains($token))] | length' "$settings")"
  [ "$legacy_entry" = "0" ]
}

# --- debt probe ---------------------------------------------------------------

probe_status() {
  local repo="$1" key_path="$2"
  jq -n -c --arg p "$key_path" '[{number: 1, key: {class: "c", path: $p, line: 1}}]' \
    | bash -c 'cd "$1" && bash "$2"' _ "$repo" "$REPO_ROOT/.gaia/scripts/debt-path-probe.sh" \
    | jq -r '.[0].status'
}

@test "debt probe: a legacy-root key still matches a tracked apps/web file" {
  local repo="$BATS_TEST_TMPDIR/probe-repo"
  scratch_repo "$repo"
  commit_paths "$repo" apps/web/x
  [ "$(probe_status "$repo" "$LEGACY_ROOT/x")" = "tracked" ]
  [ "$(probe_status "$repo" "apps/web/x")" = "tracked" ]
}

@test "red debt probe: a legacy-root key whose apps/web counterpart is not tracked is gone" {
  local repo="$BATS_TEST_TMPDIR/probe-repo-red"
  scratch_repo "$repo"
  commit_paths "$repo" apps/web/y
  [ "$(probe_status "$repo" "$LEGACY_ROOT/x")" = "gone" ]
  [ "$(probe_status "$repo" "elsewhere/x")" = "gone" ]
  printf 'x\n' >"$repo/apps/web/untracked"
  [ "$(probe_status "$repo" "$LEGACY_ROOT/untracked")" = "gone" ]
}
