#!/usr/bin/env bats
# Tests for `.gaia/scripts/resolve-audit-members.sh` (the Code Audit Team
# dispatch resolver: diff → dispatched member set).
#
# Each test runs the script in an isolated `git init`'d temp dir whose HEAD
# sits on a FEATURE branch off `main`, so the merge-base diff carries the
# branch's own committed files (mirrors resolve-audit-base.bats and
# pr-merge-audit-check.bats). The resolver reads the roster from the working
# tree's `.gaia/audit-ci.yml`, so a test's config need not be committed; only
# the CHANGED files it asserts on are committed.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  . "$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)/.gaia/tests/helpers/audit-roster.sh"
  THIS_DIRECTORY="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  SCRIPT="$THIS_DIRECTORY/../resolve-audit-members.sh"
  [ -x "$SCRIPT" ]

  SANDBOX="$BATS_TEST_TMPDIR/sandbox"
  mkdir -p "$SANDBOX/.gaia"

  git -C "$SANDBOX" init --quiet --initial-branch=main
  git -C "$SANDBOX" config user.email "test@example.com"
  git -C "$SANDBOX" config user.name "Test"
  git -C "$SANDBOX" config commit.gpgsign false

  # Base commit on main; the feature branch diverges from here so the
  # merge-base diff is non-empty.
  echo "# readme" > "$SANDBOX/README.md"
  git -C "$SANDBOX" add README.md
  git -C "$SANDBOX" commit --quiet -m "init"
  git -C "$SANDBOX" checkout --quiet -b feature
  BASE_COMMIT="$(git -C "$SANDBOX" rev-parse HEAD)"
}

# Run the resolver with cwd inside the sandbox so its
# `git rev-parse --show-toplevel` lookup hits the fixture. Args pass through.
run_resolver() {
  ( cd "$SANDBOX" && "$SCRIPT" "$@" )
}

# Stage one or more changed files (created with placeholder content).
stage() {
  local staged_path
  for staged_path in "$@"; do
    mkdir -p "$SANDBOX/$(dirname "$staged_path")"
    printf 'x\n' > "$SANDBOX/$staged_path"
    git -C "$SANDBOX" add "$staged_path"
  done
}

commit() {
  git -C "$SANDBOX" commit --quiet -m "$1"
}

# The full shipped roster (frontend default + the two maintainer-only members
# inside the release markers).
write_full_roster() {
  cat > "$SANDBOX/.gaia/audit-ci.yml" <<'YAML'
auditors:
  - name: code-audit-frontend
    globs:
      - "app/**"
      - "test/**"
      - ".storybook/**"
      - ".github/workflows/**"
      - "package.json"
      - "pnpm-lock.yaml"
      - "pnpm-workspace.yaml"
      - "tsconfig*.json"
      - "*.config.ts"
      - "*.config.mts"
      - "*.config.mjs"
      - "*.config.cjs"
      - "*.config.js"
    audience: adopter
    default: true
  # gaia:maintainer-only:start
  - name: code-audit-maintainer-shell
    globs:
      - ".gaia/**/*.sh"
      - ".gaia/**/*.bats"
      - ".claude/hooks/**/*.sh"
      - "tools/lib/*.sh"
      - ".github/**/*.sh"
      - ".github/**/*.bats"
    audience: maintainer
  - name: code-audit-maintainer-node
    globs:
      - ".gaia/cli/src/**"
    audience: maintainer
  # gaia:maintainer-only:end
YAML
}

# The adopter roster: the maintainer-only members stripped, frontend only.
# Mirrors what an adopter clone carries after the release scrub.
write_adopter_roster() {
  cat > "$SANDBOX/.gaia/audit-ci.yml" <<'YAML'
auditors:
  - name: code-audit-frontend
    globs:
      - "app/**"
      - "test/**"
      - ".storybook/**"
    audience: adopter
    default: true
YAML
}

# The pre-move roster: only root-form frontend globs, which leaves an apps/web/
# diff unowned.
write_premove_roster() {
  cat > "$SANDBOX/.gaia/audit-ci.yml" <<'YAML'
auditors:
  - name: code-audit-frontend
    globs:
      - "app/**"
      - "test/**"
    audience: adopter
    default: true
YAML
}

# Replace the sandbox roster with the committed one.
seed_committed_roster() {
  rm -f "$SANDBOX/.gaia/audit-ci.yml"
  seed_audit_roster "$SANDBOX"
}

# begin_case <roster function>: a case starts from the base commit with no
# leftovers from the previous case, and the roster it names.
begin_case() {
  git -C "$SANDBOX" reset -q --hard "$BASE_COMMIT"
  git -C "$SANDBOX" clean -qfd
  mkdir -p "$SANDBOX/.gaia"
  "$1"
}

# expect_members <label> <expected member set>: the resolver answers with
# exactly that set (empty for nothing owed).
expect_members() {
  run run_resolver
  [ "$status" -eq 0 ] || { echo "$1: status $status"; return 1; }
  [ "$output" = "$2" ] || { echo "$1: got '$output', expected '$2'"; return 1; }
}

# dispatch_case <label> <roster function> <expected> [<changed path>...]
dispatch_case() {
  local label="$1" roster="$2" expected="$3"
  shift 3
  begin_case "$roster"
  if [ "$#" -gt 0 ]; then
    stage "$@"
    commit "case"
  fi
  expect_members "$label" "$expected"
}

# bats test_tags=protected
@test "the dispatch set follows the changed paths on a fixture roster" {
  local both=$'code-audit-frontend\ncode-audit-maintainer-shell'
  dispatch_case "app-only diff" write_full_roster code-audit-frontend app/x.tsx || return 1
  dispatch_case "app plus .gaia shell, sorted" write_full_roster "$both" app/x.tsx .gaia/scripts/y.sh || return 1
  dispatch_case ".gaia shell only" write_full_roster code-audit-maintainer-shell .gaia/scripts/y.sh || return 1
  dispatch_case "nested .claude/hooks/lib shell" write_full_roster code-audit-maintainer-shell .claude/hooks/lib/z.sh || return 1
  dispatch_case ".gaia/cli/src TypeScript" write_full_roster code-audit-maintainer-node .gaia/cli/src/foo.ts || return 1

  # Config and data the roster does not claim are out of scope.
  begin_case write_full_roster
  stage .gaia/VERSION .gaia/manifest.json
  git -C "$SANDBOX" add .gaia/audit-ci.yml
  commit "config"
  expect_members "framework config and data only" "" || return 1

  dispatch_case "workflow yaml via the default catch-all" write_full_roster code-audit-frontend .github/workflows/release.yml || return 1
  dispatch_case "root tsconfig and *.config.ts" write_full_roster code-audit-frontend tsconfig.json vite.config.ts || return 1
  dispatch_case "wiki and docs only" write_full_roster "" wiki/concepts/Foo.md docs/guide.md || return 1
  # The **/ of .github/**/*.sh collapses to zero segments.
  dispatch_case "top-level .github shell script" write_full_roster code-audit-maintainer-shell .github/x.sh || return 1
  dispatch_case "single-star glob, direct child" write_full_roster code-audit-maintainer-shell tools/lib/foo.sh || return 1
  # Staged alone: beside a direct child, a nested file wrongly matched by the
  # single-* glob would route to the same member and dedupe out of sight.
  dispatch_case "single-star glob, nested file" write_full_roster "" tools/lib/sub/bar.sh || return 1
  dispatch_case "adopter roster, framework source" write_adopter_roster "" .gaia/cli/src/foo.ts || return 1
  dispatch_case "empty diff" write_full_roster "" || return 1
  dispatch_case "bats-only diff under .gaia" write_full_roster code-audit-maintainer-shell \
    .gaia/scripts/tests/resolve-audit-members.bats .gaia/tests/hooks/session-stop.bats || return 1
  dispatch_case "bats-only diff under .github" write_full_roster code-audit-maintainer-shell .github/audit/tests/post-audit-status.bats || return 1
  # The suites are not in the default member's auditable-base set, so an
  # adopter clone has nobody to dispatch for a bats file.
  dispatch_case "adopter roster, bats-only diff" write_adopter_roster "" .gaia/scripts/tests/usage-flush.bats || return 1
  # A roster still carrying only root-form frontend globs leaves an apps/web/
  # diff unowned, the red state the committed roster repairs.
  dispatch_case "pre-move roster, apps/web/app" write_premove_roster "" apps/web/app/routes/x.tsx
}

@test "the dispatch set follows the changed paths on the committed roster" {
  dispatch_case "cli source" seed_committed_roster code-audit-maintainer-node .gaia/cli/src/foo.ts || return 1
  dispatch_case "cli package.json" seed_committed_roster code-audit-maintainer-node .gaia/cli/package.json || return 1
  dispatch_case "cli tsconfig.json" seed_committed_roster code-audit-maintainer-node .gaia/cli/tsconfig.json || return 1
  # The sharpest of the CLI's tool configs: `setupFiles` executes arbitrary
  # code in every CLI test run, so a config-only diff is a code diff.
  dispatch_case "cli vitest.config.ts" seed_committed_roster code-audit-maintainer-node .gaia/cli/vitest.config.ts || return 1
  dispatch_case "cli eslint.config.mjs" seed_committed_roster code-audit-maintainer-node .gaia/cli/eslint.config.mjs || return 1
  dispatch_case "bats-only diff" seed_committed_roster code-audit-maintainer-shell .gaia/scripts/tests/usage-flush.bats || return 1
  dispatch_case "apps/web/.claude and gaia.package.json" seed_committed_roster code-audit-frontend \
    apps/web/.claude/rules/x.md apps/web/gaia.package.json apps/web/CLAUDE.md || return 1
  dispatch_case "retired root app path" seed_committed_roster "" app/routes/x.tsx || return 1
  # apps/web/public carries a service worker.
  dispatch_case "apps/web/public" seed_committed_roster code-audit-frontend apps/web/public/sw.js || return 1

  begin_case seed_committed_roster
  stage .github/workflows/a.yml .gaia/scripts/a.sh
  commit "mixed"
  run run_resolver
  [ "$status" -eq 0 ] || { echo "workflow and shell: status $status"; return 1; }
  [[ "$output" == *"code-audit-github-workflows"* ]] || { echo "workflow and shell: got '$output'"; return 1; }
  [[ "$output" == *"code-audit-maintainer-shell"* ]] || { echo "workflow and shell: got '$output'"; return 1; }

  dispatch_case "apps/web/app" seed_committed_roster code-audit-frontend apps/web/app/routes/x.tsx || return 1
  # Attribution: drop the member's own `apps/web/app/**` glob and the broader
  # `apps/**` one, and the same diff resolves to nobody, so the match came from
  # those globs and nothing else.
  grep -vF -e '"apps/web/app/**"' -e '"apps/**"' "$SANDBOX/.gaia/audit-ci.yml" > "$SANDBOX/.gaia/audit-ci.yml.tmp"
  mv "$SANDBOX/.gaia/audit-ci.yml.tmp" "$SANDBOX/.gaia/audit-ci.yml"
  expect_members "apps/web/app without its globs" ""
}

@test "an answerable query with nothing owed exits 0 with empty stdout" {
  local not_repository_root

  begin_case true
  run bash -c '( cd "$1" && "$2" --bogus 2>/dev/null )' _ "$SANDBOX" "$SCRIPT"
  [ "$status" -eq 0 ] || { echo "unknown flag: status $status"; return 1; }
  [ -z "$output" ] || { echo "unknown flag: got '$output'"; return 1; }

  begin_case write_full_roster
  stage app/a.tsx
  commit "feat"
  run run_resolver --base deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
  [ "$status" -eq 0 ] || { echo "unresolvable --base: status $status"; return 1; }
  [ -z "$output" ] || { echo "unresolvable --base: got '$output'"; return 1; }

  run bash -c '( cd "$1" && "$2" --base 2>/dev/null )' _ "$SANDBOX" "$SCRIPT"
  [ "$status" -eq 0 ] || { echo "--base without an argument: status $status"; return 1; }
  [ -z "$output" ] || { echo "--base without an argument: got '$output'"; return 1; }

  # Neither a remote-tracking ref nor a local branch of the default name exists.
  not_repository_root="$BATS_TEST_TMPDIR/unresolvable"
  mkdir -p "$not_repository_root/.gaia" "$not_repository_root/app"
  git -C "$not_repository_root" init -q --initial-branch=master
  git -C "$not_repository_root" config user.email t@example.com
  git -C "$not_repository_root" config user.name T
  git -C "$not_repository_root" config commit.gpgsign false
  cat > "$not_repository_root/.gaia/audit-ci.yml" <<'YAML'
auditors:
  - name: code-audit-frontend
    globs:
      - "app/**"
    audience: adopter
    default: true
YAML
  printf 'x\n' > "$not_repository_root/app/a.ts"
  git -C "$not_repository_root" add -A
  git -C "$not_repository_root" commit -q -m init
  run bash -c '( cd "$1" && GIT_CEILING_DIRECTORIES="$1" "$2" 2>/dev/null )' _ "$not_repository_root" "$SCRIPT"
  [ "$status" -eq 0 ] || { echo "no resolvable base: status $status"; return 1; }
  [ -z "$output" ] || { echo "no resolvable base: got '$output'"; return 1; }

  # A remote-verified base with no commits ahead is an empty, decisive answer.
  begin_case write_full_roster
  git -C "$SANDBOX" checkout -q main
  git -C "$SANDBOX" update-ref refs/remotes/origin/main refs/heads/main
  git -C "$SANDBOX" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  run run_resolver
  [ "$status" -eq 0 ] || { echo "remote-verified base: status $status"; return 1; }
  [ -z "$output" ] || { echo "remote-verified base: got '$output'"; return 1; }
}

# An unanswerable query exits 2 with empty stdout: empty stdout is reserved for
# a real answer ("nothing in this diff is in audit scope"), and a caller that
# read an unanswerable query as an empty member set would clear a diff no
# dispatched member read.
# bats test_tags=protected
@test "an unanswerable query exits 2 with empty stdout" {
  local not_repository_root error_output
  write_full_roster
  stage app/x.tsx
  commit "feat"

  not_repository_root="$BATS_TEST_TMPDIR/notrepo"
  mkdir -p "$not_repository_root"
  run bash -c 'cd "$1" && GIT_CEILING_DIRECTORIES="$1" "$2" 2>/dev/null' _ "$not_repository_root" "$SCRIPT"
  [ "$status" -eq 2 ] || { echo "not in a git repo: status $status"; return 1; }
  [ -z "$output" ] || { echo "not in a git repo: got '$output'"; return 1; }
  # bats `run` merges stderr into `$output`, so prove the diagnostic goes to
  # stderr specifically by discarding stdout.
  # shellcheck disable=SC2069
  error_output="$( ( cd "$not_repository_root" && GIT_CEILING_DIRECTORIES="$not_repository_root" "$SCRIPT" ) 2>&1 1>/dev/null || true )"
  grep -qF -- "resolve-audit-members" <<<"$error_output" || { echo "not in a git repo: stderr '$error_output'"; return 1; }

  # cwd is a real repo, so only --root can produce the failure: this pins that
  # the flag is authoritative and that its failure is not masked by a usable
  # ambient cwd.
  not_repository_root="$BATS_TEST_TMPDIR/notrepo-root"
  mkdir -p "$not_repository_root"
  run bash -c '( cd "$1" && GIT_CEILING_DIRECTORIES="$3" "$2" --root "$3" 2>/dev/null )' \
    _ "$SANDBOX" "$SCRIPT" "$not_repository_root"
  [ "$status" -eq 2 ] || { echo "--root at a non-repository: status $status"; return 1; }
  [ -z "$output" ] || { echo "--root at a non-repository: got '$output'"; return 1; }

  # Reachable as `--root "$R"` with R unset: the quoted word survives, so the
  # script sees $#=2 with an empty $2. Read as "no override" that would answer
  # from a root the caller never named.
  run bash -c '( cd "$1" && "$2" --root "" 2>/dev/null )' _ "$SANDBOX" "$SCRIPT"
  [ "$status" -eq 2 ] || { echo "--root with an empty value: status $status"; return 1; }
  [ -z "$output" ] || { echo "--root with an empty value: got '$output'"; return 1; }

  # There is no fallback roster, so a config without an auditors: block cannot
  # be answered.
  printf 'gate_label: null\nunrelated_knob: true\n' > "$SANDBOX/.gaia/audit-ci.yml"
  ( cd "$SANDBOX" && "$SCRIPT" ) >"$BATS_TEST_TMPDIR/out" 2>"$BATS_TEST_TMPDIR/err" && exit_status=0 || exit_status=$?
  [ "$exit_status" -eq 2 ] || { echo "missing auditors key: status $exit_status"; return 1; }
  [ ! -s "$BATS_TEST_TMPDIR/out" ] || { echo "missing auditors key: stdout not empty"; return 1; }
  [ "$(wc -l <"$BATS_TEST_TMPDIR/err" | tr -d ' ')" -eq 1 ] || { echo "missing auditors key: stderr is not one line"; return 1; }
  grep -qF 'has no auditors: roster' "$BATS_TEST_TMPDIR/err" || { echo "missing auditors key: stderr names no reason"; return 1; }
}

# 3b. a non-ASCII path is classified, not C-quoted into ownerlessness
#
# Under git's default `core.quotePath`, `diff --name-only` wraps any path
# carrying non-ASCII or control bytes in double quotes and backslash-escapes
# the bytes, so the path arrives as a token that matches no remit glob. This
# resolver's answer is then an EMPTY member set, which the fail-closed
# convention around it reads as "nobody owns anything here" and answers with
# the default member. The specialist that owns the file is never named and
# the merge completes looking audited, which is why the derivation reads
# `--name-only -z`.

@test "a non-ASCII path is classified rather than C-quoted into no member" {
  write_full_roster
  stage .gaia/scripts/règle.sh
  commit "chore"
  run run_resolver
  [ "$status" -eq 0 ]
  [ "$output" = "code-audit-maintainer-shell" ]

  # Non-vacuity: git really does quote THIS path under the pre-fix spelling. A
  # fixture whose name turned out to be plain ASCII would pass the assertion
  # above while proving nothing about quoting. `core.quotePath` is pinned rather
  # than inherited: it is the DEFAULT this probe asserts about, and a maintainer
  # who turns it off in ~/.gitconfig would otherwise get a red here against a
  # tree with nothing wrong with it.
  local base quoted
  base="$(git -C "$SANDBOX" merge-base HEAD main)"
  # gaia-lint-ignore lint-git-path-quoting: the unquoted call IS the experiment
  # this test runs; repairing it would delete the proof, below, that the
  # pre-fix spelling really does C-quote a non-ASCII path
  quoted="$(git -C "$SANDBOX" -c core.quotePath=true diff --name-only "${base}...HEAD")"
  grep -qF '"' <<<"$quoted" || {
    printf 'the pre-fix spelling did not quote %s, so this fixture proves nothing\n' "$quoted"
    return 1
  }
}

@test "a rename out of app/ still dispatches the app/ owner" {
  # Rename detection would list only the new out-of-scope path and dispatch
  # nobody for the app/ source the branch removed.
  write_full_roster
  mkdir -p "$SANDBOX/app"
  printf 'export const moved = "a line long enough to be detected as a rename";\n' > "$SANDBOX/app/moved.tsx"
  git -C "$SANDBOX" add app/moved.tsx
  commit "app source"
  git -C "$SANDBOX" branch -f main HEAD
  git -C "$SANDBOX" mv app/moved.tsx wiki-moved.md
  commit "move"
  run run_resolver
  [ "$status" -eq 0 ]
  [ "$output" = "code-audit-frontend" ]
}

# 15. Novel member (extensibility): a fabricated roster member is dispatched
#     purely from its config entry, proving generic roster iteration.

@test "a novel roster member is dispatched for its own glob (generic iteration)" {
  cat > "$SANDBOX/.gaia/audit-ci.yml" <<'YAML'
auditors:
  - name: code-audit-frontend
    globs:
      - "app/**"
    audience: adopter
    default: true
  - name: code-audit-example
    globs:
      - "examples/**"
    audience: adopter
YAML
  stage examples/widget.ts
  commit "feat"
  run run_resolver
  [ "$status" -eq 0 ]
  [ "$output" = "code-audit-example" ]
}

# A roster an adopter wrote before the key was retired may still carry
# `push_fixes:` on a member. The resolver reads nothing from it: the set it
# returns is the one the same roster without the key returns.
@test "a roster still carrying the retired push_fixes key resolves the same member set" {
  stage app/x.tsx examples/widget.ts
  commit "feat"
  cat > "$SANDBOX/.gaia/audit-ci.yml" <<'YAML'
auditors:
  - name: code-audit-frontend
    globs:
      - "app/**"
    audience: adopter
    default: true
  - name: code-audit-example
    globs:
      - "examples/**"
    audience: adopter
YAML
  run run_resolver
  [ "$status" -eq 0 ]
  local without_key="$output"
  cat > "$SANDBOX/.gaia/audit-ci.yml" <<'YAML'
auditors:
  - name: code-audit-frontend
    globs:
      - "app/**"
    audience: adopter
    push_fixes: true
    default: true
  - name: code-audit-example
    globs:
      - "examples/**"
    audience: adopter
    push_fixes: false
YAML
  grep -qF 'push_fixes: true' "$SANDBOX/.gaia/audit-ci.yml"
  run run_resolver
  [ "$status" -eq 0 ]
  # Both members are dispatched, so equality is not two empty answers.
  grep -qF 'code-audit-example' <<<"$output"
  grep -qF 'code-audit-frontend' <<<"$output"
  [ "$output" = "$without_key" ]
}

# 16. --base <ref> override

@test "--base <ref> overrides the diff base" {
  write_full_roster
  stage app/a.tsx
  commit "feat"
  run run_resolver --base main
  [ "$status" -eq 0 ]
  [ "$output" = "code-audit-frontend" ]
}

# 17. --help exits 0 without crashing

@test "--help exits 0 and prints usage" {
  run run_resolver --help
  [ "$status" -eq 0 ]
  grep -qF "Usage: resolve-audit-members.sh" <<<"$output" || return 1
}

@test "--root answers for that checkout from an unrelated cwd; bare does not" {
  write_full_roster
  stage app/x.tsx
  commit "feat"
  outside="$BATS_TEST_TMPDIR/outside"
  mkdir -p "$outside"
  run bash -c '( cd "$1" && GIT_CEILING_DIRECTORIES="$1" "$2" --root "$3" 2>/dev/null )' \
    _ "$outside" "$SCRIPT" "$SANDBOX"
  [ "$status" -eq 0 ]
  [ "$output" = "code-audit-frontend" ]
  # Same cwd, no --root: the resolver cannot answer at all and says so, rather
  # than reporting the empty set that means "nothing owed".
  run bash -c '( cd "$1" && GIT_CEILING_DIRECTORIES="$1" "$2" 2>/dev/null )' \
    _ "$outside" "$SCRIPT"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
}

# --- shared base-provenance resolver adoption (SPEC-074 Phase 2) ------------
#
# resolve_base() no longer runs its own merge-base chain; it calls the shared
# audit_resolve_base_provenance with `default-branch` as an explicit literal
# argument (AUDIT.md plan-time directive COV-003). The member set's answer
# is unchanged on every arm below except the one SPEC `always` boundary
# (SEC-001): the remote-minting arm now takes the fully-qualified
# refs/remotes/origin/<name> ref rather than the bare origin/<name> revspec.

# 26. Anchor regression: a record-shaped branch is present, even declared as
#     the pull request's base in the environment, but the member resolver has
#     no pr-record arm at all, so the dispatched set stays the one a
#     default-branch-anchored derivation produces.

@test "resolve_base passes an explicit default-branch anchor to the shared resolver (COV-003)" {
  grep -qF 'audit_resolve_base_provenance "$repo_root" default-branch' "$SCRIPT" || {
    echo "resolve-audit-members.sh no longer passes default-branch as an explicit literal" >&2
    return 1
  }

  write_full_roster
  git -C "$SANDBOX" checkout -q main
  git -C "$SANDBOX" checkout -q -b release
  stage .gaia/scripts/tests/release-only.sh
  commit "release-only"
  git -C "$SANDBOX" checkout -q -b feature2
  stage app/feat.tsx
  commit "feat"
  git -C "$SANDBOX" update-ref refs/remotes/origin/main refs/heads/main
  git -C "$SANDBOX" update-ref refs/remotes/origin/release refs/heads/release
  git -C "$SANDBOX" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main

  export GITHUB_ACTIONS=true
  export GITHUB_BASE_REF=release
  run run_resolver
  [ "$status" -eq 0 ]
  [ "$output" = "code-audit-frontend
code-audit-maintainer-shell" ]
}

# 27. Remote-versus-local contrast: the two arms resolve to DIFFERENT commits,
#     and the dispatched set is the one derived from refs/remotes/origin/main,
#     not from a shadowing bare local branch literally named "origin/main"
#     (SEC-001).

@test "the remote arm takes the fully-qualified ref, not a shadowing local branch named origin/main (SEC-001)" {
  write_full_roster
  git -C "$SANDBOX" checkout -q main
  git -C "$SANDBOX" checkout -q -b origin-sim
  stage .gaia/scripts/tests/origin-only.sh
  commit "origin-only"
  git -C "$SANDBOX" checkout -q main
  stage .gaia/scripts/tests/main-advance.sh
  commit "advance"
  git -C "$SANDBOX" checkout -q -b feature-shadow
  stage app/feat.tsx
  commit "feat"
  git -C "$SANDBOX" update-ref refs/remotes/origin/main refs/heads/origin-sim
  git -C "$SANDBOX" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  # A local branch literally named origin/main, shadowing the remote-tracking
  # ref through git's own refs/heads-before-refs/remotes disambiguation order.
  git -C "$SANDBOX" branch origin/main main

  run run_resolver
  [ "$status" -eq 0 ]
  [ "$output" = "code-audit-frontend
code-audit-maintainer-shell" ]
}

@test "committed roster: a apps/web/app change rotates the default member digest" {
  # The digest measures the branch's own patch against the base reference, so
  # the sandbox needs an origin carrying `main`. The fixture removes an existing
  # origin first, and that removal fails under errexit when there is none.
  . "$BATS_TEST_DIRNAME/../../tests/helpers/catchup-fixture.sh"
  git -C "$SANDBOX" remote add origin "$BATS_TEST_TMPDIR/placeholder-origin.git"
  catchup_add_origin "$SANDBOX" main
  seed_committed_roster
  stage apps/web/app/routes/x.tsx
  commit "one"
  local digest_one digest_two
  digest_one="$(bash "$THIS_DIRECTORY/../audit-member-digest.sh" --root "$SANDBOX" --member code-audit-frontend)"
  printf 'y\n' > "$SANDBOX/apps/web/app/routes/x.tsx"
  git -C "$SANDBOX" add apps/web/app/routes/x.tsx
  commit "two"
  digest_two="$(bash "$THIS_DIRECTORY/../audit-member-digest.sh" --root "$SANDBOX" --member code-audit-frontend)"
  [ -n "$digest_one" ]
  [ -n "$digest_two" ]
  [ "$digest_one" != "$digest_two" ]
}

# ---------- the release-change skip ------------------------------------------
#
# The fixture (.gaia/tests/helpers/release-skip-fixture.sh) keys fixture-shell
# with skip_gaia_release_changes: true.

@test "release skip: the member set per branch kind" {
  command -v jq >/dev/null 2>&1 || skip "jq required"
  . "$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)/.gaia/tests/helpers/release-skip-fixture.sh"
  local root="$BATS_TEST_TMPDIR/release-skip" row kind expected
  release_skip_init "$root"
  # A release-applying branch does not dispatch the keyed member; adopter shell
  # does, on an ordinary branch, as an edit to a shipped hook, and beside a
  # release.
  for row in \
    "release|fixture-default"$'\n'"fixture-scripts" \
    "ordinary|fixture-shell" \
    "hand-edit|fixture-shell" \
    "mixed|fixture-default"$'\n'"fixture-scripts"$'\n'"fixture-shell"; do
    kind="${row%%|*}"
    expected="${row#*|}"
    release_skip_branch "$root" "$kind"
    run "$SCRIPT" --root "$root" --base "$(git -C "$root" merge-base main HEAD)"
    [ "$status" -eq 0 ] || { echo "$kind: status $status"; return 1; }
    [ "$output" = "$expected" ] || { echo "$kind: got '$output', expected '$expected'"; return 1; }
    git -C "$root" checkout -q main
  done
}
