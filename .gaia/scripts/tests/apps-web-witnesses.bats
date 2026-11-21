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

@test "tests workflow filter: selects apps/web, packages/x and workspace manifests, and not wiki or README paths" {
  local pattern path
  pattern="$(workflow_filter_pattern)"
  [ -n "$pattern" ]
  for path in apps/web/app/routes/_index.tsx apps/web/package.json packages/x/index.ts pnpm-workspace.yaml .gaia/packages.json; do
    matches "$pattern" "$path" || { echo "not selected: $path"; return 1; }
  done
  for path in wiki/index.md README.md; do
    matches "$pattern" "$path" && { echo "selected: $path"; return 1; }
  done
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

@test "quick classifier: path class per input (apps/web language and component, packages/.gaia/retired root none, stack-less member none, stack-declared member language)" {
  local scratch="$BATS_TEST_TMPDIR/classifier" row path expected
  for row in \
    "apps/web/app/languages/en/x.ts|language" \
    "apps/web/app/components/card/index.tsx|component" \
    "packages/x/app/languages/en/x.ts|none" \
    ".gaia/cli/src/x.ts|none" \
    "$LEGACY_ROOT/app/languages/en/x.ts|none"; do
    path=${row%%|*}
    expected=${row#*|}
    run classify "$REPO_ROOT" "$path"
    [ "$status" -eq 0 ] || { echo "row $row: status $status"; return 1; }
    [ "$output" = "$expected" ] || { echo "row $row: got '$output'"; return 1; }
  done
  # The same web path under a registry whose member lacks `stack: web`.
  mkdir -p "$scratch/.gaia" "$scratch/apps/web"
  printf '%s\n' '[{"name":"web","path":"apps/web"}]' >"$scratch/.gaia/packages.json"
  printf '%s\n' '{"schemaVersion":1,"name":"web","globs":{"tddUnitTests":[],"tddStrictCandidates":[],"emergentTests":[],"preCommitSource":[],"doctorConfigs":[],"dependencyManifests":[]},"wiki":{"sourcePaths":[],"inventoryPaths":[],"flowPaths":[]}}' >"$scratch/apps/web/gaia.package.json"
  run classify "$scratch" "apps/web/app/languages/en/x.ts"
  [ "$output" = "none" ] || { echo "stack-less member: got '$output'"; return 1; }
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

@test "roster owner: apps/web and packages/x resolve to the default member, an out-of-remit path to no owner" {
  local default_member entry
  run roster_owner "apps/web/app/x.ts" "packages/x/index.ts" "apps/web/package.json" "no-such-top-level/x.ts"
  [ "$status" -eq 0 ]
  default_member="$(printf '%s\n' "$output" | sed -n 's/^DEFAULT=//p')"
  [ -n "$default_member" ]
  for entry in "apps/web/app/x.ts=$default_member" "packages/x/index.ts=$default_member" "apps/web/package.json=$default_member" "no-such-top-level/x.ts="; do
    printf '%s\n' "$output" | grep -qxF "$entry" || { echo "missing: $entry"; return 1; }
  done
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

@test "lint delta plan per change: apps/web source delta, eslint config full, wiki and retired-root none" {
  local repo="$BATS_TEST_TMPDIR/lint-delta" red="$BATS_TEST_TMPDIR/lint-delta-red"
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
  scratch_repo "$red"
  commit_paths "$red" wiki/index.md
  run lint_plan "$red"
  [ "$status" -eq 0 ]
  [ "$output" = "none" ]
  commit_paths "$red" "$LEGACY_ROOT/app/x.ts" "$LEGACY_ROOT/eslint.config.mjs"
  run lint_plan "$red"
  [ "$output" = "none" ]
}

# --- worktree ports -----------------------------------------------------------

ports_directory() {
  bash -c '
    . "$1/.gaia/scripts/worktree-ports-lib.sh" || exit 9
    gaia_ports_package_directory "$2"
  ' _ "$REPO_ROOT" "$1"
}

@test "worktree ports: package directory found with a router config, refused without one" {
  local tree="$BATS_TEST_TMPDIR/ports-tree" empty="$BATS_TEST_TMPDIR/ports-tree-empty"
  mkdir -p "$tree/.gaia" "$tree/apps/web"
  printf '%s\n' '[{"name":"web","path":"apps/web"}]' >"$tree/.gaia/packages.json"
  : >"$tree/apps/web/react-router.config.ts"
  run ports_directory "$tree"
  [ "$status" -eq 0 ]
  [ "$output" = "$tree/apps/web" ]
  mkdir -p "$empty/.gaia" "$empty/apps/web" "$empty/packages/x"
  printf '%s\n' '[{"name":"web","path":"apps/web"}]' >"$empty/.gaia/packages.json"
  run ports_directory "$empty"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

# --- Quality Gate Quick check -------------------------------------------------

@test "quality gate quick check: matches manifests, configs and sources at any member depth, not docs or assets" {
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
  for path in wiki/index.md README.md .claude/settings.json apps/web/public/logo.png apps/web/app/x.md; do
    matches "$pattern" "$path" && { printf 'unexpected match: %s\n' "$path" >&2; return 1; }
  done
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

@test "owed gate: apps/web manifest and packages/x tsconfig owe the web steps, wiki and harness edits owe nothing" {
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

  # A wiki edit and a harness script edit owe nothing, in a fresh repository.
  OWED_REPO="$BATS_TEST_TMPDIR/owed-repo-clear"
  scratch_repo "$OWED_REPO"
  rm -rf "$OWED_FOLDER"
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
  # A pnpm stand-in for `pnpm -C <dir> <script>`: it runs <dir>'s package.json
  # script, so the root scripts still have to name apps/web to reach the
  # marker, without needing a pnpm the suite's CI leg may not install.
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat >"$BATS_TEST_TMPDIR/bin/pnpm" <<'STUB'
#!/usr/bin/env bash
[ "$1" = "-C" ] && [ "$#" -eq 3 ] || exit 64
command_text="$(jq -er --arg script "$3" '.scripts[$script]' "$2/package.json")" || exit 1
cd "$2" || exit 1
exec sh -c "$command_text"
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/pnpm"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"
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

# --- deny entries -------------------------------------------------------------

invoke() {
  run bash -c 'printf %s "$1" | bash "$2"' _ "$1" "$2"
}

denied() { [ "$status" -eq 0 ] && grep -qF -- '"permissionDecision": "deny"' <<<"$output"; }

# bats test_tags=protected
@test "deny hooks: dotenv under apps, packages and a second app denied as Read, Bash and Write; .env.example allowed for each" {
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

@test "debt probe: legacy-root key maps to tracked apps/web file, else gone (untracked counterpart, unrelated path)" {
  local repo="$BATS_TEST_TMPDIR/probe-repo" red="$BATS_TEST_TMPDIR/probe-repo-red"
  scratch_repo "$repo"
  commit_paths "$repo" apps/web/x
  [ "$(probe_status "$repo" "$LEGACY_ROOT/x")" = "tracked" ]
  [ "$(probe_status "$repo" "apps/web/x")" = "tracked" ]
  scratch_repo "$red"
  commit_paths "$red" apps/web/y
  [ "$(probe_status "$red" "$LEGACY_ROOT/x")" = "gone" ]
  [ "$(probe_status "$red" "elsewhere/x")" = "gone" ]
  printf 'x\n' >"$red/apps/web/untracked"
  [ "$(probe_status "$red" "$LEGACY_ROOT/untracked")" = "gone" ]
}
