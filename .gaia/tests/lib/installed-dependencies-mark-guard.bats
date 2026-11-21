#!/usr/bin/env bats

# Suite for .gaia/tests/installed-dependencies-mark-guard.sh, the guard that
# derives which bats suites read installed dependencies and fails when the
# installed-dependencies marks disagree with that set or when a marked suite
# would skip, rather than fail, on a runner that lacks its dependency.
#
# Only the test that runs the guard over the real repository carries the
# whole-tree mark; every other test drives the guard over a fixture repository
# under $BATS_TEST_TMPDIR with `--root`. The mark line a fixture suite carries
# is assembled at run time (mark_line), so it never sits at column 0 in this
# file and bats never tags the fixtures' text.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  GUARD="$REPO_ROOT/.gaia/tests/installed-dependencies-mark-guard.sh"
  FIXTURE="$BATS_TEST_TMPDIR/repo"
  SUITE_DIRECTORY="$FIXTURE/.gaia/tests/lib"
  mkdir -p "$SUITE_DIRECTORY"
}

mark_line() {
  printf '# bats %s\n' 'file_tags=installed-dependencies'
}

backstop_line() {
  printf '# installed-dependencies backstop: %s\n' "$1"
}

# write_suite <name> [marked]: the suite body on stdin, written under the
# fixture's lib directory, with the mark first when asked. A body spells its
# tests `TEST "name" {`, because bats rewrites a literal test line even inside
# a heredoc.
write_suite() {
  local target="$SUITE_DIRECTORY/$1.bats"
  {
    printf '#!/usr/bin/env bats\n'
    if [ "${2:-}" = marked ]; then mark_line; fi
    sed 's/^TEST /@test /'
  } >"$target"
}

# write_helper <relative path under the fixture>: the helper body on stdin.
write_helper() {
  mkdir -p "$(dirname "$FIXTURE/$1")"
  cat >"$FIXTURE/$1"
}

run_guard() {
  run bash "$GUARD" --root "$FIXTURE" "$@"
}

# begin_case <label>: an empty fixture repository, and the label the next
# expect_guard failure names.
begin_case() {
  CASE_LABEL="$1"
  rm -rf "$FIXTURE"
  mkdir -p "$SUITE_DIRECTORY"
}

# expect_guard <status> [needle]: run the guard and require the exit status
# and, when given, that the output names the needle.
expect_guard() {
  run_guard
  [ "$status" -eq "$1" ] || {
    printf 'case %s: expected exit %s, got %s\n%s\n' "$CASE_LABEL" "$1" "$status" "$output" >&2
    return 1
  }
  if [ -n "${2:-}" ]; then
    case "$output" in
      *"$2"*) ;;
      *) printf 'case %s: the output does not name %s:\n%s\n' "$CASE_LABEL" "$2" "$output" >&2; return 1 ;;
    esac
  fi
}

# bats test_tags=protected
@test "the guard fails an unmarked user, a stale mark, a mark on a suite no bats leg runs, a late mark and a root with no suite, and passes a marked user and an unmarked suite no leg runs" {
  begin_case "unmarked user"
  write_suite uses-vitest <<'SUITE'
TEST "runs the unit tests" {
  run pnpm exec vitest run
  [ "$status" -eq 0 ]
}
SUITE
  expect_guard 1 uses-vitest.bats

  begin_case "marked user"
  write_suite uses-vitest marked <<'SUITE'
TEST "runs the unit tests" {
  run pnpm exec vitest run
  [ "$status" -eq 0 ]
}
SUITE
  expect_guard 0

  begin_case "stale mark"
  write_suite plain marked <<'SUITE'
TEST "prints" {
  run echo hello
  [ "$status" -eq 0 ]
}
SUITE
  run_guard
  [ "$status" -eq 1 ]
  case "$output" in
    *plain.bats*stale*) ;;
    *) printf 'the finding does not name the stale mark:\n%s\n' "$output" >&2; return 1 ;;
  esac

  begin_case "unmarked user outside every leg"
  write_helper .gaia/tests/bats-shards.sh <<'SHARDER'
#!/usr/bin/env bash
case "$1" in
  shards) echo only ;;
  files) echo .gaia/tests/lib/in-leg.bats ;;
esac
SHARDER
  write_suite in-leg <<'SUITE'
TEST "plain" {
  true
}
SUITE
  write_suite out-of-leg <<'SUITE'
TEST "uses pnpm" {
  run pnpm install
}
SUITE
  expect_guard 0
  run_guard --list-derived
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  begin_case "mark outside every leg"
  write_helper .gaia/tests/bats-shards.sh <<'SHARDER'
#!/usr/bin/env bash
case "$1" in
  shards) echo only ;;
  files) echo .gaia/tests/lib/in-leg.bats ;;
esac
SHARDER
  write_suite in-leg <<'SUITE'
TEST "plain" {
  true
}
SUITE
  write_suite out-of-leg marked <<'SUITE'
TEST "uses pnpm" {
  run pnpm install
}
SUITE
  expect_guard 1 out-of-leg.bats

  begin_case "mark after the first test"
  write_suite late-mark <<'SUITE'
TEST "runs" {
  run pnpm install
}
SUITE
  mark_line >>"$SUITE_DIRECTORY/late-mark.bats"
  expect_guard 1 late-mark.bats

  begin_case "root with no bats suite"
  expect_guard 2
}

@test "the guard derives a suite as a user from its command words and not from stubs, comments, quoted text or built-ins only" {
  begin_case "pnpm function stub"
  write_suite stub-function <<'SUITE'
pnpm() { echo "stubbed pnpm $*"; }

TEST "calls the stub" {
  run pnpm exec thing
  [ "$status" -eq 0 ]
}
SUITE
  expect_guard 0

  begin_case "pnpm file stub on PATH"
  write_suite stub-file <<'SUITE'
TEST "calls the stub file" {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\necho stub\n' >"$BATS_TEST_TMPDIR/bin/pnpm"
  chmod +x "$BATS_TEST_TMPDIR/bin/pnpm"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run pnpm install
  [ "$status" -eq 0 ]
}
SUITE
  expect_guard 0

  begin_case "stub of one tool beside a real call to another"
  write_suite stub-and-real <<'SUITE'
pnpm() { echo stub; }

TEST "runs the real npx" {
  run npx tsx script.ts
  [ "$status" -eq 0 ]
}
SUITE
  expect_guard 1

  begin_case "mention in a comment, a quoted string or a heredoc body"
  write_suite mentions <<'SUITE'
# This suite never runs pnpm exec vitest itself.
TEST "greps for the text" {
  run grep -q "pnpm exec vitest" some-file
  printf '%s\n' 'npx tsx x' >"$BATS_TEST_TMPDIR/out"
  cat >"$BATS_TEST_TMPDIR/doc" <<'DOC'
Run pnpm install, then playwright test.
DOC
  command -v pnpm || true
  tools=(pnpm npx vitest)
  true
}
SUITE
  expect_guard 0

  local shape
  for shape in \
    'run --separate-stderr pnpm -C "$BATS_TEST_DIRNAME" test' \
    'FOO=1 BAR=2 npx tsx x.ts' \
    'echo go | vitest run' \
    'value=$(playwright --version)' \
    'timeout 30 pnpm exec tsc' \
    'bash -c "cd /tmp && pnpm exec x"'; do
    begin_case "call shape $shape"
    write_suite shaped <<SUITE
TEST "shape" {
  $shape
}
SUITE
    expect_guard 1
  done

  begin_case "sourced helper that calls require_node_typescript"
  write_helper .gaia/tests/lib/helpers/gate.sh <<'HELPER'
check_gate() {
  require_node_typescript "$1"
}
HELPER
  write_suite via-helper <<'SUITE'
setup() {
  . "$BATS_TEST_DIRNAME/helpers/gate.sh"
  check_gate "$BATS_TEST_DIRNAME"
}

TEST "runs" {
  true
}
SUITE
  # The helper hop is one level: the call to the shared gate is what counts,
  # so the helper file itself calls it by name.
  write_helper .gaia/tests/lib/helpers/gate.sh <<'HELPER'
require_node_typescript "$1"
HELPER
  expect_guard 1 via-helper.bats

  begin_case "sourced helper that runs pnpm"
  write_helper .gaia/tests/lib/helpers/runner.sh <<'HELPER'
run_workspace_tests() {
  pnpm -C apps/web test --run
}
HELPER
  write_suite via-runner <<'SUITE'
load helpers/runner

TEST "runs" {
  run_workspace_tests
}
SUITE
  # bats resolves `load helpers/runner` to helpers/runner.bash.
  mv "$FIXTURE/.gaia/tests/lib/helpers/runner.sh" "$FIXTURE/.gaia/tests/lib/helpers/runner.bash"
  expect_guard 1

  begin_case "helper outside a helpers directory"
  write_helper .gaia/tests/lib/shared.sh <<'HELPER'
pnpm install
HELPER
  write_suite elsewhere <<'SUITE'
. "$BATS_TEST_DIRNAME/shared.sh"

TEST "runs" {
  true
}
SUITE
  expect_guard 0

  begin_case "node on a script that resolves workspace packages"
  write_helper .gaia/scripts/needs/uses-package.mjs <<'SCRIPT'
import {createRequire} from 'node:module';
const require = createRequire(import.meta.url);
require('typescript');
SCRIPT
  write_suite runs-script <<'SUITE'
SCRIPT_UNDER_TEST="$BATS_TEST_DIRNAME/../../scripts/needs/uses-package.mjs"

TEST "runs the script" {
  run node "$SCRIPT_UNDER_TEST" arg
  [ "$status" -eq 0 ]
}
SUITE
  expect_guard 1

  begin_case "node on a script that imports only built-ins"
  write_helper .gaia/scripts/needs/builtin-only.mjs <<'SCRIPT'
import net from 'node:net';
net.createServer();
SCRIPT
  write_suite runs-builtin-script <<'SUITE'
TEST "runs the script" {
  run node "$BATS_TEST_DIRNAME/../../scripts/needs/builtin-only.mjs" 1234
  [ "$status" -eq 0 ]
}
SUITE
  expect_guard 0

  begin_case "node -e text that requires a bare package"
  write_suite eval-bare <<'SUITE'
TEST "resolves a package" {
  run node -e "console.log(require('left-pad')('x', 3))"
  [ "$status" -eq 0 ]
}
SUITE
  expect_guard 1

  begin_case "node -e text that requires only built-ins"
  write_suite eval-builtin <<'SUITE'
TEST "opens a port" {
  run node -e "require('net').createServer(); require('node:fs'); require('./local.js')"
  [ "$status" -eq 0 ]
}
SUITE
  expect_guard 0
}

@test "a captured command -v path is a call, even beside a stub of the same name" {
  local tool shape
  for shape in \
    'pnpm|printf '"'"'exec "%s" x\n'"'"' "$(command -v pnpm)" >"$BATS_TEST_TMPDIR/wrapper"' \
    'npx|tool_path=$(command -v npx)' \
    'vitest|tool_path=`command -v vitest`'; do
    tool="${shape%%|*}"
    shape="${shape#*|}"
    rm -f "$SUITE_DIRECTORY"/*.bats
    write_suite captured <<SUITE
TEST "shape" {
  $shape
  printf '#!/bin/sh\nexit 0\n' >"\$BATS_TEST_TMPDIR/stub-bin/$tool"
}
SUITE
    run_guard
    if [ "$status" -ne 1 ]; then
      printf 'shape not detected: %s\n%s\n' "$shape" "$output" >&2
      return 1
    fi
  done
  rm -f "$SUITE_DIRECTORY"/*.bats
  write_suite captured marked <<'SUITE'
TEST "shape" {
  path=$(command -v pnpm)
}
SUITE
  run_guard
  [ "$status" -eq 0 ]
}

@test "node on a script that hands a resolving script to a child node makes the suite a user" {
  write_helper .gaia/scripts/needs/uses-package.mjs <<'SCRIPT'
import {createRequire} from 'node:module';
const require = createRequire(import.meta.url);
require('typescript');
SCRIPT
  write_helper .gaia/scripts/needs/calls-child.mjs <<'SCRIPT'
import {execFileSync} from 'node:child_process';
import path from 'node:path';
execFileSync('node', [path.join(import.meta.dirname, 'uses-package.mjs')]);
SCRIPT
  write_suite runs-two-hop <<'SUITE'
TEST "runs the outer script" {
  run node "$BATS_TEST_DIRNAME/../../scripts/needs/calls-child.mjs"
  [ "$status" -eq 0 ]
}
SUITE
  run_guard
  [ "$status" -eq 1 ]
  case "$output" in
    *"lib/runs-two-hop.bats"*) ;;
    *) printf 'the finding does not name the suite:\n%s\n' "$output" >&2; return 1 ;;
  esac
}

@test "a node file stub for one test does not hide the suite's real node call on a resolving script" {
  write_helper .gaia/scripts/needs/uses-package.mjs <<'SCRIPT'
import {createRequire} from 'node:module';
const require = createRequire(import.meta.url);
require('typescript');
SCRIPT
  write_suite stub-file-and-real-node <<'SUITE'
setup() {
  node "$BATS_TEST_DIRNAME/../../scripts/needs/uses-package.mjs"
}

TEST "a failing node on PATH" {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\nexit 1\n' >"$BATS_TEST_TMPDIR/bin/node"
  chmod +x "$BATS_TEST_TMPDIR/bin/node"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run some-hook
  [ "$status" -eq 1 ]
}
SUITE
  run_guard
  [ "$status" -eq 1 ]
  case "$output" in
    *"lib/stub-file-and-real-node.bats"*) ;;
    *) printf 'the finding does not name the suite:\n%s\n' "$output" >&2; return 1 ;;
  esac
}

@test "a node function cancels node on a resolving script" {
  write_helper .gaia/scripts/needs/uses-package.mjs <<'SCRIPT'
import {createRequire} from 'node:module';
const require = createRequire(import.meta.url);
require('typescript');
SCRIPT
  write_suite stub-function-node <<'SUITE'
node() { echo stubbed; }

TEST "calls the stub" {
  run node "$BATS_TEST_DIRNAME/../../scripts/needs/uses-package.mjs"
  [ "$status" -eq 0 ]
}
SUITE
  run_guard
  [ "$status" -eq 0 ]
}

@test "--list-derived prints each user once and nothing else" {
  write_suite alpha marked <<'SUITE'
TEST "runs" {
  run pnpm install
}
SUITE
  write_suite beta <<'SUITE'
TEST "plain" {
  true
}
SUITE
  run_guard --list-derived
  [ "$status" -eq 0 ]
  [ "$output" = ".gaia/tests/lib/alpha.bats" ]
}

# bats test_tags=protected
@test "a marked suite that skips without its dependency fails unless a backstop names a workflow that names the suite, or the skip is gated to fail under GITHUB_ACTIONS or unrelated" {
  begin_case "skip with no backstop"
  write_suite skips-on-ci marked <<'SUITE'
setup() {
  [ -d "$BATS_TEST_DIRNAME/node_modules" ] || skip "no node_modules on this runner"
}

TEST "runs" {
  run pnpm exec tsx x.ts
}
SUITE
  expect_guard 1 skips-on-ci.bats

  begin_case "backstop workflow names the suite"
  mkdir -p "$FIXTURE/.github/workflows"
  printf 'run: bats .gaia/tests/lib/skips-on-ci.bats\n' >"$FIXTURE/.github/workflows/backstop.yml"
  write_suite skips-on-ci marked <<SUITE
$(backstop_line .github/workflows/backstop.yml)
setup() {
  [ -d "\$BATS_TEST_DIRNAME/node_modules" ] || skip "no node_modules on this runner"
}

TEST "runs" {
  run pnpm exec tsx x.ts
}
SUITE
  expect_guard 0
  run_guard --list-backstopped
  [ "$status" -eq 0 ]
  [ "$output" = ".gaia/tests/lib/skips-on-ci.bats" ]

  begin_case "backstop workflow does not name the suite"
  mkdir -p "$FIXTURE/.github/workflows"
  printf 'run: bats some-other-suite.bats\n' >"$FIXTURE/.github/workflows/backstop.yml"
  write_suite skips-on-ci marked <<SUITE
$(backstop_line .github/workflows/backstop.yml)
setup() {
  [ -d "\$BATS_TEST_DIRNAME/node_modules" ] || skip "no node_modules on this runner"
}

TEST "runs" {
  run pnpm exec tsx x.ts
}
SUITE
  expect_guard 1 skips-on-ci.bats
  run_guard --list-backstopped
  [ -z "$output" ]

  begin_case "backstop workflow file is missing"
  write_suite skips-on-ci marked <<SUITE
$(backstop_line .github/workflows/missing.yml)
TEST "runs" {
  run pnpm exec tsx x.ts
}
SUITE
  expect_guard 1

  begin_case "skip gated to fail under GITHUB_ACTIONS"
  write_helper .gaia/tests/lib/helpers/gate.sh <<'HELPER'
require_dependency() {
  [ -d "$1/node_modules" ] && return 0
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    echo "missing on CI" >&2
    return 1
  fi
  skip "node_modules not installed"
}
HELPER
  write_suite gated marked <<'SUITE'
. "$BATS_TEST_DIRNAME/helpers/gate.sh"

setup() {
  require_dependency "$BATS_TEST_DIRNAME"
}

TEST "runs" {
  run pnpm exec tsx x.ts
}
SUITE
  expect_guard 0

  begin_case "skip unrelated to a dependency"
  write_suite port-skip marked <<'SUITE'
TEST "runs" {
  run pnpm exec tsx x.ts
  [ "$status" -eq 0 ] || skip "port 6006 is in use on this host"
}
SUITE
  expect_guard 0
}

# bats test_tags=whole-tree
@test "the real repository is clean, and its derived set holds the known users" {
  run bash "$GUARD" --root "$REPO_ROOT"
  if [ "$status" -ne 0 ]; then
    printf '%s\n' "$output" >&2
    return 1
  fi
}
