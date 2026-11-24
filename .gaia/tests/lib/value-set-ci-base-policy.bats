#!/usr/bin/env bats
#
# Flow test: the shipped CI job runs the value-set check on a pull request that
# touches only a shell file, taking the exclusion config, the manifest and the
# maintainer marker from the base commit through the contents API. The check
# step is extracted from the workflow and run in a temporary git work tree
# holding the committed CLI bundle, with a stub `gh` standing in for the API.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  WORKFLOW="$REPO_ROOT/.github/workflows/tests.yml"
  TREE="$BATS_TEST_TMPDIR/tree"
  BASE_FILES="$BATS_TEST_TMPDIR/base-files"
  STUB_BIN="$BATS_TEST_TMPDIR/bin"
  STEP_SCRIPT="$BATS_TEST_TMPDIR/step.sh"
  GH_LOG="$BATS_TEST_TMPDIR/gh.log"
  mkdir -p "$BASE_FILES/.gaia" "$STUB_BIN" "$BATS_TEST_TMPDIR/runner-temp" \
    "$TREE/.gaia/cli" "$TREE/apps/web/generated" "$TREE/scripts" "$TREE/node_modules"
  : >"$GH_LOG"
}

@test "the shipped job checks a shell-only pull request against the base commit's exclusion config, manifest and marker" {
  if ! { command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; }; then
    [ -z "${GITHUB_ACTIONS:-}" ] || { echo "no python3 + PyYAML on a CI runner" >&2; return 1; }
    skip "no YAML parser available (python3 + PyYAML)"
  fi

  python3 - "$WORKFLOW" "$STEP_SCRIPT" <<'PY'
import sys, yaml
with open(sys.argv[1]) as handle:
    document = yaml.safe_load(handle)
bodies = [step["run"] for step in document["jobs"]["value-sets"]["steps"] if "run" in step]
if len(bodies) != 1:
    sys.exit("expected exactly one run step, found %d" % len(bodies))
with open(sys.argv[2], "w") as out:
    out.write(bodies[0])
PY

  cat >"$STUB_BIN/gh" <<'STUB'
#!/usr/bin/env bash
endpoint=""
for argument in "$@"; do
  case "$argument" in repos/*) endpoint="$argument" ;; esac
done
printf '%s\n' "$endpoint" >>"$STUB_GH_LOG"
requested="${endpoint#*/contents/}"
requested="${requested%%\?ref=*}"
if [ -f "$STUB_BASE_FILES/$requested" ]; then
  cat "$STUB_BASE_FILES/$requested"
  exit 0
fi
echo "gh: Not Found (HTTP 404)" >&2
exit 1
STUB
  chmod +x "$STUB_BIN/gh"
  cat >"$BASE_FILES/.gaia/value-sets.json" <<'JSON'
{"version":1,"exclude":[{"path":"apps/web/generated/**","reason":"generated output repeats the source on purpose"}]}
JSON

  cp "$REPO_ROOT/.gaia/cli/gaia" "$TREE/.gaia/cli/gaia"
  chmod +x "$TREE/.gaia/cli/gaia"
  ln -s "$REPO_ROOT/.gaia/cli/node_modules/typescript" "$TREE/node_modules/typescript"
  cat >"$TREE/apps/web/generated/modes.ts" <<'TS'
export const MODES = ['light', 'dark', 'system'];
TS
  printf '%s\n' '#!/usr/bin/env bash' 'echo gen' >"$TREE/scripts/gen.sh"
  git -C "$TREE" init -q
  git -C "$TREE" add -A
  git -C "$TREE" -c user.name=test -c user.email=test@example.com commit -q -m base
  base_sha="$(git -C "$TREE" rev-parse HEAD)"

  cat >>"$TREE/scripts/gen.sh" <<'SH'
MODES=(light dark system)
SH
  git -C "$TREE" add -A
  git -C "$TREE" -c user.name=test -c user.email=test@example.com commit -q -m head
  changed="$(git -C "$TREE" diff --name-only -z "$base_sha" HEAD | tr '\0' '\n')"
  [ "$changed" = "scripts/gen.sh" ] || { echo "changed files: $changed"; return 1; }

  run bash -c 'cd "$1" && PATH="$2:$PATH" REPOSITORY=owner/repository EVENT_NAME=pull_request \
    BASE_SHA="$3" RUNNER_TEMP="$4" STUB_BASE_FILES="$5" STUB_GH_LOG="$6" bash "$7" 2>&1' \
    _ "$TREE" "$STUB_BIN" "$base_sha" "$BATS_TEST_TMPDIR/runner-temp" "$BASE_FILES" "$GH_LOG" "$STEP_SCRIPT"
  [ "$status" -eq 0 ] || { echo "expected 0, got $status: $output"; return 1; }

  for policy_file in .gaia/value-sets.json .gaia/manifest.json .claude/rules/maintainers/harness-triage-threshold.md; do
    grep -qF -- "/contents/$policy_file?ref=$base_sha" "$GH_LOG" || { echo "no read of $policy_file at the base sha"; cat "$GH_LOG"; return 1; }
  done
}
