#!/usr/bin/env bats
# Every `pnpm install` a workflow, composite action or CI script under .github/
# runs goes through .github/actions/gaia-setup-node/bounded-install.sh, so a
# stalled registry response costs one bounded attempt and a retry instead of
# the job's whole timeout. A new bare install fails here before it reaches CI.
#
# Comment lines are skipped, and so are bats suites under a tests/ directory,
# which run pnpm through stubs. The scan reads .yml, .yaml and .sh files; an
# install spelled in any other file type is not seen.
#
# Assertion style per .claude/rules/bats-assertions.md.
#
# Maintainer-only. `.gaia/tests` is wholesale release-excluded via
# `.gaia/release-exclude`, so this never reaches an adopter.

# pnpm, any options with their values, then the install subcommand.
pnpm_install_pattern='pnpm( +-[^ ]+( +[^ -][^ ]*)?)* +(install|i)( |$)'

# install_lines <root>: one `bounded <file>:<line>` or `bare <file>:<line>` per
# uncommented pnpm install under <root>/.github.
install_lines() {
  local root="$1" match location text
  grep -rnE --include='*.yml' --include='*.yaml' --include='*.sh' "$pnpm_install_pattern" "$root/.github" |
    while IFS= read -r match; do
      location="${match%%:*}:$(cut -d: -f2 <<<"$match")"
      location="${location#"$root/"}"
      text="$(cut -d: -f3- <<<"$match")"
      case "$location" in */tests/*) continue ;; esac
      case "${text#"${text%%[![:space:]]*}"}" in '#'*) continue ;; esac
      case "$text" in
        *bounded-install.sh*) echo "bounded $location" ;;
        *) echo "bare $location" ;;
      esac
    done
}

# bats test_tags=whole-tree
@test "every pnpm install under .github runs through bounded-install.sh" {
  local lines
  lines="$(install_lines "$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)")"
  grep -q '^bounded ' <<<"$lines" || return 1
  grep '^bare ' <<<"$lines" && return 1
  true
}

@test "a bare pnpm install in a workflow fails the scan (the guard can fail)" {
  local root="$BATS_TEST_TMPDIR/tree"
  mkdir -p "$root/.github/workflows" "$root/.github/forensics/tests"
  printf '%s\n' 'jobs:' '  build:' '    steps:' \
    '      # pnpm install --frozen-lockfile in a comment is not a step' \
    '      - run: bash .github/actions/gaia-setup-node/bounded-install.sh --attempt-seconds 180 -- pnpm install --frozen-lockfile' \
    '      - run: pnpm -C frontend exec playwright install chromium' \
    >"$root/.github/workflows/clean.yml"
  printf '%s\n' 'pnpm install --frozen-lockfile' >"$root/.github/forensics/tests/stubbed.sh"
  run install_lines "$root"
  [ "$status" -eq 0 ] || return 1
  [ "$output" = "bounded .github/workflows/clean.yml:5" ] || return 1

  printf '%s\n' '      - run: pnpm --filter . install' >>"$root/.github/workflows/clean.yml"
  printf '%s\n' 'pnpm i --frozen-lockfile' >"$root/.github/run.sh"
  run install_lines "$root"
  grep -qxF "bare .github/workflows/clean.yml:7" <<<"$output" || return 1
  grep -qxF "bare .github/run.sh:1" <<<"$output"
}
