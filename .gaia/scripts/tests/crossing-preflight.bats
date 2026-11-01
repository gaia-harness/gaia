#!/usr/bin/env bats
#
# Suite for `gaia update crossing preflight`, and for the resume arm it opens:
# `move`, `rekey` and `roster` run from a half-crossed tree end equal to an
# uninterrupted run of the same three verbs. Every stop row prints its own
# reason and a next step and leaves the status, HEAD, branch list and index
# untouched. The toolchain floors are not here: they run through
# toolchain-check.sh before preflight, and crossing-note.bats covers them.
#
# The verbs run from source through a wrapper in $BATS_TEST_TMPDIR, so the
# suite needs no rebuilt bundle. GAIA_CROSSING_CLI points the same assertions at
# a built binary.
#
# Run under bash 5 (.claude/rules/bats-assertions.md):
#   bash .gaia/scripts/bats5.sh .gaia/scripts/tests/crossing-preflight.bats < /dev/null

bats_require_minimum_version 1.5.0

setup() {
  CLI_DIR="$(cd "$BATS_TEST_DIRNAME/../../cli" && pwd)"
  LEGACY=frontend
  GAIA="${GAIA_CROSSING_CLI:-$BATS_TEST_TMPDIR/gaia}"
  if [ -z "${GAIA_CROSSING_CLI:-}" ]; then
    printf '#!/usr/bin/env bash\nexec "%s/node_modules/.bin/tsx" "%s/src/index.ts" "$@"\n' \
      "$CLI_DIR" "$CLI_DIR" >"$GAIA"
    chmod +x "$GAIA"
  fi
  REPO="$BATS_TEST_TMPDIR/repo"
  export GAIA LEGACY
  make_repo "$REPO"
}

# make_repo <dir>: a committed 2.x-shaped project on main.
make_repo() {
  local repo="$1"
  mkdir -p "$repo/$LEGACY/app" "$repo/.gaia"
  git -C "$repo" init -q -b main
  git -C "$repo" config user.email test@example.com
  git -C "$repo" config user.name Test
  git -C "$repo" config commit.gpgsign false
  printf '{\n  "name": "frontend",\n  "private": true\n}\n' >"$repo/$LEGACY/package.json"
  printf '{\n  "schemaVersion": 1,\n  "name": "frontend",\n  "globs": {\n    "tddUnitTests": [],\n    "tddStrictCandidates": [],\n    "emergentTests": [],\n    "preCommitSource": [],\n    "doctorConfigs": [],\n    "dependencyManifests": []\n  },\n  "wiki": {\n    "sourcePaths": [],\n    "inventoryPaths": [],\n    "flowPaths": []\n  }\n}\n' \
    >"$repo/$LEGACY/gaia.package.json"
  printf 'export const x = 1;\n' >"$repo/$LEGACY/app/x.ts"
  printf '.env\n' >"$repo/$LEGACY/.gitignore"
  printf 'SECRET=abc\n' >"$repo/$LEGACY/.env"
  printf 'packages:\n  - %s\n  - .gaia/cli\n\nminimumReleaseAge: 4320\n' "$LEGACY" >"$repo/pnpm-workspace.yaml"
  printf 'auditors:\n  - name: code-audit-frontend\n    globs:\n      - "%s/app/**"\n      - "package.json"\n    audience: adopter\n    default: true\nunowned:\n  - "*.md"\n' "$LEGACY" \
    >"$repo/.gaia/audit-ci.yml"
  jq -n --arg k "$LEGACY/app/x.ts" '{files: {($k): "owned", ".gaia/VERSION": "owned"}, version: "2.3.1"}' \
    >"$repo/.gaia/manifest.json"
  printf '[{"name":"frontend","path":"%s"}]\n' "$LEGACY" >"$repo/.gaia/packages.json"
  printf '.gaia/local\n.notebook\n' >"$repo/.gitignore"
  git -C "$repo" add -A
  git -C "$repo" commit -q -m seed
  add_cache_tree "$repo"
}

# add_cache_tree <dir>: the verified baseline tree rekey reads.
add_cache_tree() {
  local tree="$1/.gaia/local/cache/shared/update-gaia/v2.3.0/tree"
  mkdir -p "$tree/$LEGACY/app" "$tree/.gaia"
  printf 'export const x = 0;\n' >"$tree/$LEGACY/app/x.ts"
  jq -n --arg k "$LEGACY/app/x.ts" '{files: {($k): "owned"}, version: "2.3.0"}' >"$tree/.gaia/manifest.json"
}

# crossing <dir> <verb> [args]: runs a verb with <dir> as the working directory.
crossing() {
  local dir="$1"
  shift
  run --separate-stderr bash -c 'cd "$1" && shift && "$GAIA" update crossing "$@"' _ "$dir" "$@"
}

# observed <dir>: what a stop must leave alone.
observed() {
  git -C "$1" status --porcelain
  git -C "$1" rev-parse HEAD
  git -C "$1" branch --list
  git -C "$1" ls-files -s -z | tr '\0' '\n'
}

# assert_stop <reason> [launch dir]: the preflight prints its own reason and a
# next step, exits 3, and changes nothing.
assert_stop() {
  local reason="$1" launch="${2:-$REPO}" before after
  before="$(observed "$REPO")"
  crossing "$launch" preflight
  [ "$status" -eq 3 ]
  [ "${lines[0]}" = "CROSSING_STOP $reason" ]
  [[ "${lines[1]}" == "Next step: "?* ]]
  after="$(observed "$REPO")"
  [ "$before" = "$after" ]
}

# commit_all <dir>: commits every change in the tree.
commit_all() {
  git -C "$1" add -A
  git -C "$1" commit -q -m change
}

# tree_digest <dir>: every file outside .git, by path and content digest.
tree_digest() {
  (cd "$1" && find . -path ./.git -prune -o -type f -print | LC_ALL=C sort | while IFS= read -r file; do
    printf '%s %s\n' "$(shasum -a 256 <"$file" | cut -d' ' -f1)" "$file"
  done)
}

# ========== stops ==========

@test "dirty-tree: an untracked file" {
  printf 'x\n' >"$REPO/stray.txt"
  assert_stop dirty-tree
}

@test "linked-worktree: a launch from a linked worktree" {
  git -C "$REPO" worktree add -q -b side "$BATS_TEST_TMPDIR/linked"
  assert_stop linked-worktree "$BATS_TEST_TMPDIR/linked"
}

@test "not-root-launch: a launch from a subdirectory" {
  assert_stop not-root-launch "$REPO/$LEGACY/app"
}

@test "plan-in-execution: a RUNNING file under the notebook" {
  mkdir -p "$REPO/.notebook/specs/SPEC-1/plan"
  : >"$REPO/.notebook/specs/SPEC-1/plan/RUNNING"
  assert_stop plan-in-execution
}

@test "default-branch-behind: a branch that is not the default" {
  git -C "$REPO" checkout -q -b topic
  assert_stop default-branch-behind
}

@test "default-branch-behind: a default branch that is not level with origin" {
  local head
  head="$(git -C "$REPO" rev-parse HEAD)"
  printf 'x\n' >"$REPO/later.txt"
  commit_all "$REPO"
  git -C "$REPO" update-ref refs/remotes/origin/main "$head"
  git -C "$REPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  assert_stop default-branch-behind
}

@test "registry-path: no member at the app path" {
  printf '[{"name":"tools","path":"tools"}]\n' >"$REPO/.gaia/packages.json"
  commit_all "$REPO"
  assert_stop registry-path
}

@test "both-trees-present: the old and the new app directory both exist" {
  mkdir -p "$REPO/apps/web"
  printf '{}\n' >"$REPO/apps/web/package.json"
  commit_all "$REPO"
  assert_stop both-trees-present
}

@test "member-named-web: another member already holds the name the app is renamed to" {
  printf '[{"name":"frontend","path":"%s"},{"name":"web","path":"tools/web"}]\n' "$LEGACY" \
    >"$REPO/.gaia/packages.json"
  commit_all "$REPO"
  assert_stop member-named-web
}

# ========== passes ==========

@test "a clean default branch passes as fresh" {
  crossing "$REPO" preflight
  [ "$status" -eq 0 ]
  [ "$output" = "CROSSING_PASS fresh" ]
}

@test "an absent registry passes as the app at the old path" {
  git -C "$REPO" rm -q .gaia/packages.json
  commit_all "$REPO"
  crossing "$REPO" preflight
  [ "$status" -eq 0 ]
  [ "$output" = "CROSSING_PASS fresh" ]
}

@test "a kept member name passes with no question and stays through the move" {
  printf '[{"name":"storefront","path":"%s"}]\n' "$LEGACY" >"$REPO/.gaia/packages.json"
  commit_all "$REPO"
  crossing "$REPO" preflight
  [ "$status" -eq 0 ]
  [ "$output" = "CROSSING_PASS fresh" ]
  crossing "$REPO" move
  [ "$status" -eq 0 ]
  [ "$(jq -r '.[0].name' "$REPO/.gaia/packages.json")" = "storefront" ]
}

# ========== resume ==========

@test "resume: the three verbs from a half-crossed tree end equal to an uninterrupted run" {
  local other="$BATS_TEST_TMPDIR/other"
  make_repo "$other"

  crossing "$other" move
  [ "$status" -eq 0 ]
  crossing "$other" rekey --baseline-tag v2.3.0
  [ "$status" -eq 0 ]
  crossing "$other" roster
  [ "$status" -eq 0 ]

  # Half crossed: the app moved, then the interrupted run left the other edits
  # undone, on the update branch with uncommitted work.
  git -C "$REPO" checkout -q -b update/x
  crossing "$REPO" move
  [ "$status" -eq 0 ]
  printf '[{"name":"frontend","path":"%s"}]\n' "$LEGACY" >"$REPO/.gaia/packages.json"
  printf 'packages:\n  - %s\n  - .gaia/cli\n\nminimumReleaseAge: 4320\n' "$LEGACY" >"$REPO/pnpm-workspace.yaml"
  printf 'work in progress\n' >"$REPO/wip.txt"

  crossing "$REPO" preflight
  [ "$status" -eq 0 ]
  [ "$output" = "CROSSING_PASS resume" ]

  crossing "$REPO" move
  [ "$status" -eq 0 ]
  crossing "$REPO" rekey --baseline-tag v2.3.0
  [ "$status" -eq 0 ]
  crossing "$REPO" roster
  [ "$status" -eq 0 ]

  rm "$REPO/wip.txt"
  diff <(tree_digest "$REPO") <(tree_digest "$other")
}

@test "resume: a stray registry entry at the new path also passes" {
  crossing "$REPO" move
  [ "$status" -eq 0 ]
  git -C "$REPO" checkout -q -b update/x
  printf '[{"name":"web","path":"apps/web"}]\n' >"$REPO/.gaia/packages.json"
  crossing "$REPO" preflight
  [ "$status" -eq 0 ]
  [ "$output" = "CROSSING_PASS resume" ]
}
