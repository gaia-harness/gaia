#!/usr/bin/env bats

# Tests for .githooks/pre-commit.
#
# The hook decides whether a staged change is lint-worthy and runs the Quality
# Gate floor (pnpm typecheck / lint-staged / test:lint-staged) only when it is.
# The decision is descriptor-driven: .gaia/scripts/precommit-packages.sh reads
# the package registry and each descriptor's `preCommitSource` globs and tells
# the POSIX hook which package directories have a counted staged path. A
# directory that .lintstagedrc.json covers but the descriptor never names is the
# live failure mode: a commit scoped to that directory alone matches nothing,
# the skip branch fires, and the change lands unlinted and untypechecked.
#
# Git runs the hook directly through core.hooksPath, so these tests run it
# directly too.
#
# `pnpm` is stubbed onto PATH as a recorder, so the tests assert on which gate
# steps the hook invoked, and in which package directory, rather than on their
# real output. The suite needs no node_modules and stays fast.
#
# The "path ." fixtures write a literal registry and descriptor into the sandbox
# (the transitional layout) and never copy the live files, so the suite states
# what it asserts and stays green whatever path the live registry names.
# The one test that reads the live descriptor says so.

setup() {
  REPO_ROOT=$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)
  HOOK_ABSOLUTE_PATH="$REPO_ROOT/.githooks/pre-commit"

  # Physical path: the hook takes its root from `git rev-parse --show-toplevel`,
  # which resolves symlinks (macOS /var is a link to /private/var).
  REPO=$(cd "$(mktemp -d -t githooks-pre-commit-XXXXXX)" && pwd -P)
  git -C "$REPO" init --quiet --initial-branch=main
  git -C "$REPO" config user.email "test@example.com"
  git -C "$REPO" config user.name "Test"
  git -C "$REPO" config commit.gpgsign false
  echo "# readme" > "$REPO/README.md"
  git -C "$REPO" add README.md
  git -C "$REPO" commit --quiet -m "init"

  # The hook finds its helper and the registry reader under the repo root it
  # runs in, so the sandbox carries copies of both (the code under test).
  mkdir -p "$REPO/.gaia/scripts" "$REPO/.claude/hooks/lib"
  cp "$REPO_ROOT/.gaia/scripts/precommit-packages.sh" "$REPO/.gaia/scripts/"
  cp "$REPO_ROOT/.claude/hooks/lib/gaia-packages.sh" "$REPO/.claude/hooks/lib/"

  # Every stub invocation appends its argv and succeeds, so the hook runs to
  # completion under errexit and each test reads back which steps fired.
  PNPM_LOG="$REPO/pnpm.log"
  STUB_BIN="$REPO/stub-bin"
  mkdir -p "$STUB_BIN"
  cat > "$STUB_BIN/pnpm" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$PNPM_LOG"
exit 0
STUB
  chmod +x "$STUB_BIN/pnpm"
  : > "$PNPM_LOG"
}

# A manifest defining all three gate steps, which the hook runs only where defined.
write_member_manifest() {
  mkdir -p "$1"
  printf '%s\n' '{"scripts":{"typecheck":"tsc","test:lint-staged":"vitest"},"lint-staged":{"*.ts":"eslint"}}' > "$1/package.json"
}

# A descriptor with every required key; $1 is the destination directory, $2 the
# `preCommitSource` array as JSON.
write_descriptor() {
  local directory="$1" pre_commit_source="$2"
  mkdir -p "$directory"
  write_member_manifest "$directory"
  cat > "$directory/gaia.package.json" <<JSON
{
  "schemaVersion": 1,
  "name": "web",
  "globs": {
    "tddUnitTests": ["app/**/*.test.ts"],
    "tddStrictCandidates": ["app/utils/**"],
    "emergentTests": ["app/components/**/*.test.ts"],
    "preCommitSource": $pre_commit_source,
    "doctorConfigs": ["doctor.config.*", "react-doctor.config.*"],
    "dependencyManifests": ["package.json"]
  },
  "wiki": { "sourcePaths": ["app/"], "inventoryPaths": ["app/"], "flowPaths": ["app/"] }
}
JSON
}

# The transitional layout: the frontend package lives at the repo root.
use_root_package() {
  mkdir -p "$REPO/.gaia"
  printf '[{"name":"web","path":"."}]\n' > "$REPO/.gaia/packages.json"
  write_descriptor "$REPO" '["app/**", "test/**", ".storybook/**", ".playwright/**"]'
}

# The workspace layout: the web package lives at apps/web/.
use_frontend_package() {
  mkdir -p "$REPO/.gaia"
  printf '[{"name":"web","path":"apps/web"}]\n' > "$REPO/.gaia/packages.json"
  write_descriptor "$REPO/apps/web" '["app/**", "test/**", ".storybook/**", ".playwright/**"]'
}

teardown() {
  [ -n "${REPO:-}" ] && rm -rf "$REPO"
  return 0
}

run_hook() {
  run env PATH="$STUB_BIN:$PATH" PNPM_LOG="$PNPM_LOG" \
    sh -c 'cd "$1" && "$2"' _ "$REPO" "$HOOK_ABSOLUTE_PATH"
}

# Stage one file at a repo-relative path, then run the hook from the repo root
# the way git does.
stage_and_run() {
  local path="$1"
  mkdir -p "$REPO/$(dirname "$path")"
  echo "// content" > "$REPO/$path"
  git -C "$REPO" add "$path"
  run env PATH="$STUB_BIN:$PATH" PNPM_LOG="$PNPM_LOG" \
    sh -c 'cd "$1" && "$2"' _ "$REPO" "$HOOK_ABSOLUTE_PATH"
}

# Commit one file, then stage its deletion and run the hook. A deletion-only
# commit is the arm-agnostic case: it matches an arm only when that arm's
# --diff-filter carries `D`.
stage_deletion_and_run() {
  local path="$1"
  mkdir -p "$REPO/$(dirname "$path")"
  echo "// content" > "$REPO/$path"
  git -C "$REPO" add "$path"
  git -C "$REPO" commit --quiet -m "add $path"
  git -C "$REPO" rm --quiet "$path"
  run env PATH="$STUB_BIN:$PATH" PNPM_LOG="$PNPM_LOG" \
    sh -c 'cd "$1" && "$2"' _ "$REPO" "$HOOK_ABSOLUTE_PATH"
}

# Assertion style: .claude/rules/bats-assertions.md.
# $1 is the package directory the gate must run in (default: the repo root).
assert_gate_ran() {
  local package_path="${1:-$REPO}"
  [ "$status" -eq 0 ]
  grep -qF -- "running lint-staged" <<<"$output"
  grep -qxF -- "-C $package_path typecheck" "$PNPM_LOG"
  grep -qxF -- "-C $package_path exec lint-staged" "$PNPM_LOG"
  grep -qxF -- "-C $package_path test:lint-staged" "$PNPM_LOG"
}

assert_gate_skipped() {
  [ "$status" -eq 0 ]
  grep -qF -- "skipping lint-staged" <<<"$output"
  [ ! -s "$PNPM_LOG" ]
}

# Row checks for the case tables. Every line returns on its own because a
# function called on the left of `||` runs with errexit off, so the bare greps
# of assert_gate_ran would not stop it there.
check_gate_ran() {
  local label="$1" package_path="${2:-$REPO}" step
  [ "$status" -eq 0 ] || { echo "case $label: status=$status output=$output"; return 1; }
  grep -qF -- "running lint-staged" <<<"$output" || { echo "case $label: no 'running lint-staged' in output=$output"; return 1; }
  for step in typecheck "exec lint-staged" test:lint-staged; do
    grep -qxF -- "-C $package_path $step" "$PNPM_LOG" || { echo "case $label: pnpm log lacks '-C $package_path $step'"; return 1; }
  done
}

check_gate_skipped() {
  local label="$1"
  [ "$status" -eq 0 ] || { echo "case $label: status=$status output=$output"; return 1; }
  grep -qF -- "skipping lint-staged" <<<"$output" || { echo "case $label: no 'skipping lint-staged' in output=$output"; return 1; }
  [ ! -s "$PNPM_LOG" ] || { echo "case $label: a gate step ran: $(cat "$PNPM_LOG")"; return 1; }
}

# Case-table rows share one setup(): snapshot the fresh sandbox once, then give
# each row its own copy at the same path, so no row sees another's commits,
# staged entries or config.
snapshot_sandbox() {
  SANDBOX_SNAPSHOT="$BATS_TEST_TMPDIR/sandbox-snapshot"
  rm -rf "$SANDBOX_SNAPSHOT"
  cp -Rp "$REPO" "$SANDBOX_SNAPSHOT"
}

restore_sandbox() {
  rm -rf "$REPO"
  cp -Rp "$SANDBOX_SNAPSHOT" "$REPO"
}

# --- a change or deletion in a lintable directory runs the gate ---
#
# .lintstagedrc.json lints {.storybook,.playwright}/**/*.{ts,tsx}, so the
# .playwright half needs an arm of its own; without one that entry is
# unreachable for an e2e-spec-only commit, the most common .playwright shape.
#
# Deleting a shared helper, fixture, or spec breaks the types of every file that
# imported it, which is exactly what the skipped `pnpm typecheck` would catch.
# All four arms therefore carry `D`; the deletion rows pin that agreement so a
# future edit cannot narrow one arm back without a failure.
@test "a staged change or deletion under a lintable directory runs the gate, one outside skips it" {
  local row label kind path
  snapshot_sandbox
  for row in \
    "change|app/routes/home.tsx" \
    "change|test/setup.ts" \
    "change|.storybook/preview.ts" \
    "change|.playwright/e2e/home.spec.ts" \
    "deletion|app/routes/home.tsx" \
    "deletion|test/setup.ts" \
    "deletion|.storybook/preview.ts" \
    "deletion|.playwright/e2e/home.spec.ts" \
    "outside|docs/notes.md"; do
    kind=${row%%|*}; path=${row#*|}; label="$kind $path"
    restore_sandbox
    use_root_package
    case "$kind" in
      change)
        stage_and_run "$path"
        check_gate_ran "$label" || return 1
        ;;
      deletion)
        stage_deletion_and_run "$path"
        check_gate_ran "$label" || return 1
        ;;
      outside)
        stage_and_run "$path"
        check_gate_skipped "$label" || return 1
        ;;
    esac
  done
}

# --- every gated directory is reachable by lint-staged ---
#
# The descriptor's `preCommitSource` globs and the package's .lintstagedrc.json
# are the two halves of one contract: a descriptor glob decides the gate runs, a
# lint-staged glob decides lint-staged has anything to hand ESLint. A glob no
# lint-staged key covers is the silent half of the failure mode the header
# describes: the hook prints "running lint-staged", lint-staged matches zero
# files and exits 0, and the commit lands with ESLint skipped for that whole
# directory while typecheck and Vitest still report.
#
# Both directions are derived and checked, one guard each: this one asks whether
# every gated directory reaches a glob, the one below it whether every glob
# reaches a gated directory. These two read the LIVE registry, descriptor, and
# lint-staged config; everything else in this file reads a sandbox.

# The live frontend package directory, from the committed registry. When the
# move has landed the config sits under it; between the rename-only commit and
# the registry flip the registry still says `.`, so fall back to apps/web/.
live_package_directory() {
  local registered
  registered=$(jq -r '.[] | select(.name == "web") | .path' "$REPO_ROOT/.gaia/packages.json") || return 1
  [ -n "$registered" ] || return 1
  printf '%s\n' "$registered"
}

live_lintstaged_file() {
  local directory candidate
  directory=$(live_package_directory) || return 1
  for candidate in "$REPO_ROOT/$directory/.lintstagedrc.json" "$REPO_ROOT/apps/web/.lintstagedrc.json"; do
    if [ -f "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

live_descriptor_file() {
  local directory
  directory=$(live_package_directory) || return 1
  printf '%s\n' "$REPO_ROOT/$directory/gaia.package.json"
}

# Every directory the descriptor's `preCommitSource` globs gate, one per line.
arm_directories() {
  jq -r '.globs.preCommitSource[]' "$(live_descriptor_file)" | sed -n 's#^\(.*/\)\*\*$#\1#p'
}

# Every `preCommitSource` entry, counted by a pattern deliberately wider than
# the derivation above reads. A count taken with the same pattern as the
# extraction agrees with it on every spelling the pattern cannot read, so the
# two readings would confirm each other's blind spot; this one over-counts, so
# a glob the derivation cannot read reds the guard.
arm_assignment_count() {
  jq -r '.globs.preCommitSource | length' "$(live_descriptor_file)"
}

# The lint-staged glob keys whose task chain actually invokes ESLint. Reading
# the keys alone would accept a chain that runs only prettier or stylelint,
# which is the very outcome the arm is supposed to prevent, and chains of that
# shape already live in this config.
eslint_globs() {
  jq -r 'to_entries[]
         | select(any(.value[]?; type == "string" and startswith("eslint")))
         | .key' "$(live_lintstaged_file)"
}

# The glob keys whose chain mentions ESLint anywhere, counted by a pattern
# deliberately wider than the derivation above reads, for the same reason
# arm_assignment_count is wider than arm_directories. A count taken with the same
# `startswith` test would agree with the derivation on every chain that spelling
# cannot reach (`pnpm exec eslint`, a path-qualified binary), confirming its
# blind spot instead of exposing it. This one over-counts, so a key the
# derivation silently drops reds the guard rather than leaving its directory
# unchecked.
#
# `tostring` rather than `.value[]?` is what keeps it wider on both axes.
# lint-staged accepts a bare string chain as well as an array, and `.value[]?`
# yields nothing for a string, so the derivation's own iteration silently drops
# `"scripts/**/*.ts": "eslint --fix"`. A count that iterated the same way would
# drop it too and agree, which is this control's failure mode rather than its
# job. `tostring` reads a string value, an array value, and any nesting.
eslint_glob_mentions() {
  jq -r '[to_entries[] | select(.value | tostring | test("eslint"))]
         | length' "$(live_lintstaged_file)"
}

# Every directory one glob key hands ESLint files under, one per line, and
# nothing at all for a key of any other shape.
#
# This reads the literal shape `<dir>/**/<rest>`, in the key itself or in each
# alternative of its leading brace group, rather than matching a probe path
# against the key. Matching would need lint-staged's own matcher: bash's [[ ]]
# lets `*` cross a `/` where picomatch does not, so `app/*.{ts,tsx}` would
# satisfy a probe while leaving app/routes/home.tsx unlinted, which is exactly
# the miss these guards exist to catch. Demanding the recursive shape is the
# narrower question, and it fails closed in both directions: a key written some
# other way yields no directory, which reds the arm-to-glob guard on the arm it
# should have covered and reds the glob-to-arm guard on the key itself.
glob_head_directories() {
  local glob="$1" head alt
  # A second recursive segment yields nothing, because the cut below takes the
  # head at the FIRST `/**/`: `app/**/routes/**/*.ts` would reduce to a bare
  # `app/` and green the `app/` arm while the key hands ESLint only
  # app/<any>/routes/<any>/*.ts, leaving app/other.ts unlinted. That reduction
  # carries no glob metacharacter, so the alternative validation below cannot
  # reach it; the shape has to be refused before the cut.
  #
  # Refusing the shape rather than cutting at the LAST `/**/` instead: a lazy
  # `${glob%/\*\*/*}` cut looks equivalent and reds `app/**/**/*.ts`, whose
  # doubled globstar is the same directory as one and is legitimately `app/`.
  case "$glob" in
    *"/**/"*"/**/"*) return 0 ;;
    *"/**/"*) head="${glob%%/\*\*/*}" ;;
    *) return 0 ;;
  esac
  case "$head" in
    "{"*"}")
      head="${head#\{}"; head="${head%\}}"
      head=$(printf '%s' "$head" | tr ',' '\n')
      ;;
  esac
  # Validate every alternative before emitting any, so a head this reader cannot
  # expand yields nothing rather than something. A brace group that is not the
  # whole head (`app/{routes,components}`) is the case that makes the difference:
  # emitting it literally would leave the shape check satisfied and send the
  # guard's operator to add a hook arm named after an unexpanded glob, when the
  # repair is to rewrite the key.
  #
  # A slash is not that case and must not join it. A plain nested head
  # (`app/routes`, from `app/routes/**/*.ts`) is fully readable, and rejecting it
  # yielded no directory, which reds the glob-to-arm guard on a legitimate key
  # while telling its operator the key had no recursive head to rewrite toward.
  while IFS= read -r alt; do
    case "$alt" in
      "" | *[{}]*) return 0 ;;
    esac
  done <<<"$head"
  while IFS= read -r alt; do
    printf '%s/\n' "$alt"
  done <<<"$head"
}

# Whether one glob key hands ESLint the files under directory $1.
#
# Exact, where arm_names_directory below is a substring relation, and the asymmetry is
# the contract rather than an oversight. This direction asks whether an arm's
# whole directory reaches ESLint, and a nested head covers only part of it:
# `app/routes/**/*.ts` leaves app/other.ts unlinted while the `app/` arm still
# fires, which is the miss this direction exists to catch. Loosening it to a
# substring would green exactly that case.
#
# The other spelling of that miss, a key carrying a second recursive segment,
# never reaches this check at all: glob_head_directories refuses the shape and yields
# nothing, so the key reds both directions instead of satisfying either.
glob_covers_directory() {
  local directory="$1" glob="$2"
  glob_head_directories "$glob" | grep -qxF -- "$directory"
}

# Whether some hook arm's grep reaches every file under directory $1, given the
# newline-separated arm directories in $2.
#
# Substring, because the arms are unanchored greps (.githooks/pre-commit documents
# the lack of anchoring as deliberate). Every path under a directory carries that
# directory as a prefix, so an arm whose pattern is a substring of the directory
# is a substring of every path beneath it: the `app/` arm reaches all of
# `app/routes/`. Demanding an exact name here would red a nested glob key the
# hook already covers.
arm_names_directory() {
  local directory="$1" arm
  while IFS= read -r arm; do
    [ -n "$arm" ] || continue
    case "$directory" in
      *"$arm"*) return 0 ;;
    esac
  done <<<"$2"
  return 1
}

@test "every pre-commit arm directory is covered by an ESLint lint-staged glob" {
  local directories globs derived assignments directory glob covered
  directories=$(arm_directories)
  derived=$(printf '%s\n' "$directories" | grep -c . || true)
  assignments=$(arm_assignment_count)
  [ "$derived" -gt 0 ]
  [ "$derived" -eq "$assignments" ]

  # Captured rather than piped, so a jq that is absent or cannot parse the
  # config reports itself instead of emptying the loop below and blaming the
  # first arm for an uncovered directory.
  globs=$(eslint_globs) || {
    printf 'could not read .lintstagedrc.json (is jq installed?)\n' >&2
    return 1
  }
  [ -n "$globs" ] || {
    printf '.lintstagedrc.json declares no glob whose chain invokes eslint\n' >&2
    return 1
  }

  while IFS= read -r directory; do
    covered=0
    while IFS= read -r glob; do
      if glob_covers_directory "$directory" "$glob"; then covered=1; fi
    done <<<"$globs"
    if [ "$covered" -ne 1 ]; then
      printf 'hook arm %s has no ESLint .lintstagedrc.json glob\n' "$directory" >&2
      return 1
    fi
  done <<<"$directories"
}

# --- every ESLint lint-staged glob's directory is named by a hook arm ---
#
# The other half of the same contract, and the direction the header calls the
# live failure mode: a glob whose directory no arm greps for means a commit
# scoped to that directory alone matches nothing, the else branch fires, and the
# change lands unlinted *and* untypechecked. That is strictly worse than the
# uncovered-arm case the guard above catches, which still runs typecheck and
# Vitest.
#
# The glob set is derived from .lintstagedrc.json rather than restated here, and
# a key whose chain mentions ESLint in a spelling the derivation cannot read is
# counted separately, so a config entry added with no arm reds here instead of
# shipping behind a guard that never saw it.
@test "every ESLint lint-staged glob directory is named by a pre-commit arm" {
  local directories globs derived mentions glob glob_directories directory
  directories=$(arm_directories)
  [ -n "$directories" ]

  # Captured rather than piped, for the reason the guard above gives: a jq that
  # is absent or cannot parse the config must report itself rather than empty
  # the loop below into a vacuous pass.
  globs=$(eslint_globs) || {
    printf 'could not read .lintstagedrc.json (is jq installed?)\n' >&2
    return 1
  }
  [ -n "$globs" ] || {
    printf '.lintstagedrc.json declares no glob whose chain invokes eslint\n' >&2
    return 1
  }
  derived=$(printf '%s\n' "$globs" | grep -c .)
  mentions=$(eslint_glob_mentions)
  [ "$derived" -eq "$mentions" ]

  while IFS= read -r glob; do
    glob_directories=$(glob_head_directories "$glob")
    [ -n "$glob_directories" ] || {
      printf 'eslint glob %s does not reduce to a plain recursive <dir>/**/ head, so no directory can be checked against the arms\n' "$glob" >&2
      return 1
    }
    while IFS= read -r directory; do
      if ! arm_names_directory "$directory" "$directories"; then
        printf 'ESLint .lintstagedrc.json glob %s covers %s, which no pre-commit arm reaches\n' "$glob" "$directory" >&2
        return 1
      fi
    done <<<"$glob_directories"
  done <<<"$globs"
}

# A descriptor glob the hook never acts on is dead: the directory looks gated in
# the descriptor and decides nothing. For each directory the LIVE descriptor
# gates, the real hook, given a sandbox carrying the live registry and
# descriptor, runs the gate in the package directory for a file staged there.
@test "every live preCommitSource directory runs the gate through the hook" {
  local directories directory package_directory prefix package_path
  directories=$(arm_directories)
  [ -n "$directories" ]
  package_directory=$(live_package_directory)
  mkdir -p "$REPO/.gaia"
  cp "$REPO_ROOT/.gaia/packages.json" "$REPO/.gaia/packages.json"
  mkdir -p "$REPO/$package_directory"
  cp "$(live_descriptor_file)" "$REPO/$package_directory/gaia.package.json"
  write_member_manifest "$REPO/$package_directory"
  if [ "$package_directory" = . ]; then
    prefix=''
    package_path="$REPO"
  else
    prefix="$package_directory/"
    package_path="$REPO/$package_directory"
  fi
  while IFS= read -r directory; do
    : > "$PNPM_LOG"
    git -C "$REPO" reset --quiet
    mkdir -p "$REPO/$prefix$directory"
    echo "// content" > "$REPO/${prefix}${directory}probe.ts"
    git -C "$REPO" add "${prefix}${directory}probe.ts"
    run_hook
    if ! { [ "$status" -eq 0 ] && grep -qxF -- "-C $package_path exec lint-staged" "$PNPM_LOG"; }; then
      printf 'staging %s%sprobe.ts did not run the gate in %s\n' "$prefix" "$directory" "$package_path" >&2
      return 1
    fi
  done <<<"$directories"
}

# --- package-aware behavior (SPEC-092 couplings, C5 and C13) ---

assert_gate_not_invoked() {
  [ "$status" -eq 0 ]
  [ ! -s "$PNPM_LOG" ]
}

# The descriptor-names-nothing row is the guard's failing state: with a
# descriptor that gates nothing the staged file matches, a frontend commit
# skips, which proves the descriptor decides rather than an unanchored
# substring of the path.
@test "apps/web/ package: a change runs the gate in apps/web/ with a registry or the built-in default, a descriptor naming nothing skips, a root app/x.tsx is refused" {
  local label
  snapshot_sandbox
  for label in "registry" "descriptor names nothing" "root app/x.tsx" "built-in default"; do
    restore_sandbox
    case "$label" in
      "registry")
        use_frontend_package
        stage_and_run "apps/web/app/x.tsx"
        check_gate_ran "$label" "$REPO/apps/web" || return 1
        ;;
      "descriptor names nothing")
        use_frontend_package
        write_descriptor "$REPO/apps/web" '["nomatch/**"]'
        stage_and_run "apps/web/app/x.tsx"
        check_gate_skipped "$label" || return 1
        ;;
      "root app/x.tsx")
        use_frontend_package
        stage_and_run "app/x.tsx"
        [ "$status" -ne 0 ] || { echo "case $label: status=$status"; return 1; }
        grep -qF -- "app/x.tsx -> apps/web/app/x.tsx" <<<"$output" || { echo "case $label: refusal does not name the move: $output"; return 1; }
        [ ! -s "$PNPM_LOG" ] || { echo "case $label: a gate step ran: $(cat "$PNPM_LOG")"; return 1; }
        ;;
      "built-in default")
        rm -f "$REPO/.gaia/packages.json"
        . "$BATS_TEST_DIRNAME/helpers/package-fixture.sh"
        write_builtin_descriptor "$REPO"
        write_member_manifest "$REPO/apps/web"
        stage_and_run "apps/web/app/x.tsx"
        check_gate_ran "$label" "$REPO/apps/web" || return 1
        ;;
    esac
  done
}

# Fail closed on a registry or descriptor failure (UAT-018). On an unreadable
# registry the reader prints its own reason and next step; the hook's closing
# line points at them and names the file, so the refusal is not a dead end.
@test "a registry that is unreadable or unparseable, or a missing descriptor, fails the commit with a pointer" {
  local label
  snapshot_sandbox
  for label in "unreadable registry" "unparseable registry" "missing descriptor"; do
    restore_sandbox
    case "$label" in
      "unreadable registry")
        mkdir -p "$REPO/.gaia"
        printf 'not json\n' > "$REPO/.gaia/packages.json"
        stage_and_run "app/x.tsx"
        [ "$status" -ne 0 ] || { echo "case $label: status=$status"; return 1; }
        grep -qF -- ".gaia/packages.json is malformed" <<<"$output" || { echo "case $label: no malformed line: $output"; return 1; }
        grep -qF -- "The reason and its next step are printed above" <<<"$output" || { echo "case $label: no pointer to the reason: $output"; return 1; }
        grep -qF -- "bash .gaia/scripts/precommit-packages.sh" <<<"$output" || { echo "case $label: file not named: $output"; return 1; }
        ;;
      "unparseable registry")
        use_frontend_package
        printf 'not json {\n' > "$REPO/.gaia/packages.json"
        stage_and_run "apps/web/app/x.tsx"
        [ "$status" -eq 1 ] || { echo "case $label: status=$status"; return 1; }
        grep -qF -- "gaia-packages: " <<<"$output" || { echo "case $label: no gaia-packages message: $output"; return 1; }
        ;;
      "missing descriptor")
        use_frontend_package
        rm "$REPO/apps/web/gaia.package.json"
        stage_and_run "apps/web/app/x.tsx"
        [ "$status" -eq 1 ] || { echo "case $label: status=$status"; return 1; }
        grep -qF -- "gaia-packages: " <<<"$output" || { echo "case $label: no gaia-packages message: $output"; return 1; }
        ;;
    esac
    [ ! -s "$PNPM_LOG" ] || { echo "case $label: a gate step ran: $(cat "$PNPM_LOG")"; return 1; }
  done
}

@test "a harness-only staged set skips the gate" {
  use_frontend_package
  mkdir -p "$REPO/wiki" "$REPO/.claude/rules"
  echo a > "$REPO/wiki/a.md"
  echo a > "$REPO/.claude/rules/a.md"
  git -C "$REPO" add wiki/a.md .claude/rules/a.md
  run_hook
  assert_gate_skipped
}

# --- machine-local references: the staged scan runs before any gate step ---

# bats test_tags=protected
@test "machine-local refs: a staged prose line naming a plan number is refused and runs no gate step" {
  use_frontend_package
  mkdir -p "$REPO/wiki"
  printf '# Page\n\nShipped by PLAN-007.\n' > "$REPO/wiki/page.md"
  git -C "$REPO" add wiki/page.md
  run_hook
  [ "$status" -ne 0 ]
  grep -qF -- "wiki/page.md:3: PLAN-007" <<<"$output"
  grep -qF -- ".claude/rules/working-doc-ids.md" <<<"$output"
  [ ! -s "$PNPM_LOG" ]
}

@test "machine-local refs: a staged placeholder passes the scan" {
  use_frontend_package
  mkdir -p "$REPO/wiki"
  printf '# Page\n\nA SPEC folder is .notebook/specs/SPEC-NNN/.\n' > "$REPO/wiki/page.md"
  git -C "$REPO" add wiki/page.md
  run_hook
  assert_gate_skipped
}

# The hook reads the detector beside its own tree. A copy with no detector
# there must refuse rather than commit unscanned.
@test "machine-local refs: the hook refuses when the detector cannot run" {
  use_frontend_package
  mkdir -p "$REPO/.githooks" "$REPO/wiki"
  cp "$HOOK_ABSOLUTE_PATH" "$REPO/.githooks/pre-commit"
  chmod +x "$REPO/.githooks/pre-commit"
  echo a > "$REPO/wiki/a.md"
  git -C "$REPO" add wiki/a.md
  run env PATH="$STUB_BIN:$PATH" PNPM_LOG="$PNPM_LOG" \
    sh -c 'cd "$1" && "$2"' _ "$REPO" "$REPO/.githooks/pre-commit"
  [ "$status" -ne 0 ]
  grep -qF -- "machine-local-ref-lib.sh" <<<"$output"
  [ ! -s "$PNPM_LOG" ]
}

# --- C13: the migration-rename exemption ---

# Commit the retired root paths, then stage their renames the way the Phase 4
# move does, so the staged set carries real R100 entries.
commit_root_frontend_files() {
  local path
  for path in "$@"; do
    mkdir -p "$REPO/$(dirname "$path")"
    echo "// $path" > "$REPO/$path"
    # Long enough that one appended line stays a rename above git's similarity
    # threshold, so the content-change refusal drives a real Rnn entry.
    seq 1 40 >> "$REPO/$path"
    git -C "$REPO" add "$path"
  done
  git -C "$REPO" commit --quiet -m "seed root frontend files"
}

stage_rename() {
  mkdir -p "$REPO/$(dirname "$2")"
  git -C "$REPO" mv "$1" "$2"
}

@test "C13: a staged set of only C6 renames skips the gate, even with the descriptor missing" {
  commit_root_frontend_files app/x.tsx .dockerignore test/setup.ts public/favicon.ico .storybook/main.ts .playwright/a.spec.ts vite.config.ts .claude/skills/tailwind/SKILL.md .claude/rules/i18n.md .claude/agents/code-audit-frontend/cn.md
  stage_rename app/x.tsx apps/web/app/x.tsx
  stage_rename .dockerignore apps/web/Dockerfile.dockerignore
  stage_rename test/setup.ts apps/web/test/setup.ts
  stage_rename public/favicon.ico apps/web/public/favicon.ico
  stage_rename .storybook/main.ts apps/web/.storybook/main.ts
  stage_rename .playwright/a.spec.ts apps/web/.playwright/a.spec.ts
  stage_rename vite.config.ts apps/web/vite.config.ts
  stage_rename .claude/skills/tailwind/SKILL.md apps/web/.claude/skills/tailwind/SKILL.md
  stage_rename .claude/rules/i18n.md apps/web/.claude/rules/i18n.md
  stage_rename .claude/agents/code-audit-frontend/cn.md apps/web/.claude/agents/code-audit-frontend/cn.md
  # No registry and no descriptor anywhere: the exemption runs before the load.
  rm -rf "$REPO/.gaia/packages.json" "$REPO/gaia.package.json" "$REPO/apps/web/gaia.package.json"
  git -C "$REPO" diff --cached --name-status -M100% | grep -c '^R100' | grep -qx 10
  run_hook
  assert_gate_skipped
}

@test "C13 refusal: a rename that is not a pure C6 rename runs the full gate: R100 inside apps/web/, a non-counterpart destination, one changed line, a non-exempt entry beside" {
  local label
  snapshot_sandbox
  for label in "R100 inside apps/web/" "non-counterpart destination" "one changed line" "non-exempt entry beside"; do
    restore_sandbox
    case "$label" in
      "R100 inside apps/web/")
        use_frontend_package
        commit_root_frontend_files apps/web/app/utils/a.ts
        stage_rename apps/web/app/utils/a.ts apps/web/app/utils/b.ts
        git -C "$REPO" diff --cached --name-status -M100% | grep -q '^R100' || { echo "case $label: no R100 entry staged"; return 1; }
        run_hook
        check_gate_ran "$label" "$REPO/apps/web" || return 1
        ;;
      "non-counterpart destination")
        use_root_package
        commit_root_frontend_files app/x.tsx
        stage_rename app/x.tsx src/x.tsx
        git -C "$REPO" diff --cached --name-status -M100% | grep -q '^R100' || { echo "case $label: no R100 entry staged"; return 1; }
        run_hook
        check_gate_ran "$label" "$REPO" || return 1
        ;;
      "one changed line")
        use_frontend_package
        commit_root_frontend_files app/x.tsx
        stage_rename app/x.tsx apps/web/app/x.tsx
        printf 'a changed line\n' >> "$REPO/apps/web/app/x.tsx"
        git -C "$REPO" add apps/web/app/x.tsx
        run_hook
        check_gate_ran "$label" "$REPO/apps/web" || return 1
        ;;
      "non-exempt entry beside")
        use_frontend_package
        commit_root_frontend_files app/x.tsx
        stage_rename app/x.tsx apps/web/app/x.tsx
        mkdir -p "$REPO/apps/web/app"
        echo "// new" > "$REPO/apps/web/app/new.tsx"
        git -C "$REPO" add apps/web/app/new.tsx
        run_hook
        check_gate_ran "$label" "$REPO/apps/web" || return 1
        ;;
    esac
  done
}

# --- doctor guard, one config per package directory ---

@test "doctor guard: two configs under apps/web/ fail the commit naming apps/web, one config passes" {
  local label
  snapshot_sandbox
  for label in "two configs" "one config"; do
    restore_sandbox
    use_frontend_package
    : > "$REPO/apps/web/doctor.config.ts"
    case "$label" in
      "two configs")
        : > "$REPO/apps/web/doctor.config.json"
        stage_and_run "docs/notes.md"
        [ "$status" -eq 1 ] || { echo "case $label: status=$status"; return 1; }
        grep -qF -- "Multiple react-doctor configs found in apps/web" <<<"$output" || { echo "case $label: no multiple-configs line: $output"; return 1; }
        grep -qF -- "apps/web/doctor.config.json" <<<"$output" || { echo "case $label: second config not named: $output"; return 1; }
        [ ! -s "$PNPM_LOG" ] || { echo "case $label: a gate step ran: $(cat "$PNPM_LOG")"; return 1; }
        ;;
      "one config")
        stage_and_run "docs/notes.md"
        check_gate_skipped "$label" || return 1
        ;;
    esac
  done
}

# --- the hook runs as a native git hook ---

# A pnpm stub whose `typecheck` step fails and whose every other step logs and
# succeeds, so a failing gate is distinguishable from a hook that never ran.
install_failing_typecheck_stub() {
  cat > "$STUB_BIN/pnpm" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$PNPM_LOG"
case "$*" in
  *typecheck*) exit 1 ;;
esac
exit 0
STUB
  chmod +x "$STUB_BIN/pnpm"
}

# Install the hook under test into the sandbox repository and point
# core.hooksPath at it, as the root `prepare` script does.
install_hook_into_sandbox() {
  mkdir -p "$REPO/.githooks"
  cp -p "$HOOK_ABSOLUTE_PATH" "$REPO/.githooks/pre-commit"
  # The hook reads the machine-local reference detector beside itself.
  cp "$REPO_ROOT/.gaia/scripts/machine-local-ref-lib.sh" "$REPO/.gaia/scripts/"
  git -C "$REPO" config core.hooksPath .githooks
}

@test "the hook is executable in the index" {
  run git -C "$REPO_ROOT" ls-files -s -z .githooks/pre-commit
  [ "$status" -eq 0 ]
  grep -q -- '^100755 ' <<<"$output"
}

@test "the hook arms its own errexit" {
  install_failing_typecheck_stub
  use_frontend_package
  stage_and_run "apps/web/app/x.tsx"
  [ "$status" -ne 0 ]
  grep -qF -- "typecheck" "$PNPM_LOG"
  grep -qF -- "exec lint-staged" "$PNPM_LOG" && return 1
  true
}

# Stage a frontend file and commit it through real git, so git itself decides
# whether to run the hook. Sets head_before to HEAD before the commit attempt.
commit_frontend_file_through_hook() {
  use_frontend_package
  install_hook_into_sandbox
  mkdir -p "$REPO/apps/web/app"
  echo "// content" > "$REPO/apps/web/app/x.tsx"
  git -C "$REPO" add apps/web/app/x.tsx
  head_before=$(git -C "$REPO" rev-parse HEAD)
  run env PATH="$STUB_BIN:$PATH" PNPM_LOG="$PNPM_LOG" \
    git -C "$REPO" commit --quiet -m x
}

@test "git refuses a commit when the hook fails" {
  install_failing_typecheck_stub
  local head_before
  commit_frontend_file_through_hook
  [ "$status" -ne 0 ]
  [ "$(git -C "$REPO" rev-parse HEAD)" = "$head_before" ]
}

@test "git runs the hook through core.hooksPath" {
  local head_before
  commit_frontend_file_through_hook
  [ "$status" -eq 0 ]
  [ "$(git -C "$REPO" rev-parse HEAD)" != "$head_before" ]
  grep -qxF -- "-C $REPO/apps/web typecheck" "$PNPM_LOG"
  grep -qxF -- "-C $REPO/apps/web exec lint-staged" "$PNPM_LOG"
}

# --- the root prepare script ---

# Run the root prepare script from directory $1 with the env words in "${@:2}".
# Absolute interpreters, so a PATH reduced to an empty directory still finds them.
run_prepare() {
  local directory="$1"
  shift
  local prepare_script
  prepare_script=$(jq -r '.scripts.prepare' "$REPO_ROOT/package.json")
  run /usr/bin/env "$@" /bin/sh -c 'cd "$1" && /bin/sh -c "$2"' _ "$directory" "$prepare_script"
}

# The unset checks use `--local` because a machine can carry a global
# core.hooksPath that a plain `--get` would report. Unset means no output and
# exit status 1.
@test "prepare sets or leaves core.hooksPath by environment: outside CI, CI set, outside a repository, no git binary, a nested directory" {
  local label bare_directory="$BATS_TEST_TMPDIR/not-a-repository" empty_bin="$BATS_TEST_TMPDIR/empty-bin"
  mkdir -p "$bare_directory" "$empty_bin"
  snapshot_sandbox
  for label in "outside CI" "CI set" "outside a repository" "no git binary" "nested directory"; do
    restore_sandbox
    case "$label" in
      "outside CI")
        run_prepare "$REPO" -u CI
        [ "$status" -eq 0 ] || { echo "case $label: status=$status output=$output"; return 1; }
        [ "$(git -C "$REPO" config --local --get core.hooksPath)" = ".githooks" ] || { echo "case $label: core.hooksPath not .githooks"; return 1; }
        ;;
      "CI set")
        run_prepare "$REPO" CI=true
        [ "$status" -eq 0 ] || { echo "case $label: status=$status output=$output"; return 1; }
        run git -C "$REPO" config --local --get core.hooksPath
        [ "$status" -eq 1 ] && [ -z "$output" ] || { echo "case $label: core.hooksPath set: status=$status output=$output"; return 1; }
        ;;
      "outside a repository")
        run_prepare "$bare_directory" -u CI
        [ "$status" -eq 0 ] || { echo "case $label: status=$status"; return 1; }
        [ -z "$output" ] || { echo "case $label: printed $output"; return 1; }
        ;;
      "no git binary")
        run_prepare "$bare_directory" -u CI "PATH=$empty_bin"
        [ "$status" -eq 0 ] || { echo "case $label: status=$status"; return 1; }
        [ -z "$output" ] || { echo "case $label: printed $output"; return 1; }
        ;;
      "nested directory")
        mkdir -p "$REPO/nested/package"
        run_prepare "$REPO/nested/package" -u CI
        [ "$status" -eq 0 ] || { echo "case $label: status=$status output=$output"; return 1; }
        run git -C "$REPO" config --local --get core.hooksPath
        [ "$status" -eq 1 ] && [ -z "$output" ] || { echo "case $label: enclosing core.hooksPath set: status=$status output=$output"; return 1; }
        ;;
    esac
  done
}
