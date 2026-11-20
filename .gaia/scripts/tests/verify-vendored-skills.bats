#!/usr/bin/env bats
#
# verify-vendored-skills.sh over scratch fixture trees. Every drift case builds
# its own tree under $BATS_TEST_TMPDIR and points the script at it with --root,
# so the real vendored folder is never mutated.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SCRIPT="$REPO_ROOT/.gaia/scripts/verify-vendored-skills.sh"
  WORKFLOW="$REPO_ROOT/.github/workflows/cli-tests.yml"
  FIXTURE="$BATS_TEST_TMPDIR/fixture"
  TARGET_RELATIVE="apps/web/.claude/skills/demo"
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

# Build a two-file vendored folder and a marker recording both hashes.
make_fixture() {
  mkdir -p "$FIXTURE/$TARGET_RELATIVE/references" "$FIXTURE/.gaia/vendor"
  printf 'top level\n' >"$FIXTURE/$TARGET_RELATIVE/SKILL.md"
  printf 'reference body\n' >"$FIXTURE/$TARGET_RELATIVE/references/one.md"
  jq -n \
    --arg target "$TARGET_RELATIVE" \
    --arg top "$(sha256_of "$FIXTURE/$TARGET_RELATIVE/SKILL.md")" \
    --arg one "$(sha256_of "$FIXTURE/$TARGET_RELATIVE/references/one.md")" \
    '{package: "demo", version: "1.0.0", integrity: "x", source: "skills/demo", target: $target, files: {"SKILL.md": $top, "references/one.md": $one}}' \
    >"$FIXTURE/.gaia/vendor/demo.json"
}

@test "passes on an untouched fixture" {
  make_fixture
  run "$SCRIPT" --root "$FIXTURE"
  [ "$status" -eq 0 ]
}

# bats test_tags=protected
@test "drift of a vendored file is named by kind: MODIFIED, UNEXPECTED, MISSING" {
  local kind
  for kind in MODIFIED UNEXPECTED MISSING; do
    rm -rf "$FIXTURE"
    make_fixture
    case "$kind" in
      MODIFIED) printf 'top levem\n' >"$FIXTURE/$TARGET_RELATIVE/SKILL.md"; named="SKILL.md" ;;
      UNEXPECTED) printf 'stray\n' >"$FIXTURE/$TARGET_RELATIVE/references/extra.md"; named="references/extra.md" ;;
      MISSING) rm "$FIXTURE/$TARGET_RELATIVE/references/one.md"; named="references/one.md" ;;
    esac
    run "$SCRIPT" --root "$FIXTURE"
    [ "$status" -eq 1 ] || { echo "case $kind: expected exit 1, got $status"; return 1; }
    [[ "$output" == *"$kind $TARGET_RELATIVE/$named"* ]] || { echo "case $kind: not named: $output"; return 1; }
  done
}

@test "usage errors exit 2 rather than reporting clean: empty marker set, missing jq, unknown argument" {
  mkdir -p "$FIXTURE/.gaia/vendor"
  run "$SCRIPT" --root "$FIXTURE"
  [ "$status" -eq 2 ] || { echo "case empty marker set: got $status"; return 1; }

  rm -rf "$FIXTURE"
  make_fixture
  mkdir -p "$BATS_TEST_TMPDIR/empty-path"
  PATH="$BATS_TEST_TMPDIR/empty-path" run "$BASH" "$SCRIPT" --root "$FIXTURE"
  [ "$status" -eq 2 ] || { echo "case missing jq: got $status"; return 1; }
  [[ "$output" == *"jq"* ]] || { echo "case missing jq: jq not named"; return 1; }

  run "$SCRIPT" --bogus
  [ "$status" -eq 2 ] || { echo "case unknown argument: got $status"; return 1; }
}

# bats test_tags=whole-tree
@test "the real repository passes" {
  run "$SCRIPT" --root "$REPO_ROOT"
  [ "$status" -eq 0 ]
}

# bats test_tags=whole-tree
@test "the real repository passes with the network unreachable" {
  npm_config_offline=true HTTP_PROXY=http://127.0.0.1:9 HTTPS_PROXY=http://127.0.0.1:9 \
    run "$SCRIPT" --root "$REPO_ROOT"
  [ "$status" -eq 0 ]
}

@test "the script never invokes npm, curl, or wget" {
  # Comment lines are dropped so the header may say what the script avoids.
  grep -vE '^[[:space:]]*#' "$SCRIPT" | grep -qE '(^|[^[:alnum:]_-])(npm|curl|wget)([[:space:]]|$)' && return 1
  true
}

# The cli-tests job body, from its key to the next job key.
cli_tests_job() {
  awk '/^  cli-tests:$/ {inside=1; next} inside && /^  [a-zA-Z0-9_-]+:$/ {exit} inside {print}' "$WORKFLOW"
}

@test "cli-tests.yml runs the check in the cli-tests job" {
  local job
  job="$(cli_tests_job)"
  [ -n "$job" ]
  grep -qxF -- '        run: bash .gaia/scripts/verify-vendored-skills.sh' <<<"$job"
}

@test "cli-tests.yml filters on every path the check reads" {
  local job path
  job="$(cli_tests_job)"
  [ -n "$job" ]
  for path in 'apps/web/.claude/skills/playwright-cli/**' '.gaia/vendor/**' '.gaia/scripts/verify-vendored-skills.sh'; do
    grep -qxF -- "              - '$path'" <<<"$job" || { echo "missing filter entry: $path" >&2; return 1; }
  done
}
