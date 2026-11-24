#!/usr/bin/env bats
#
# The `Value sets` job of the shipped tests.yml: its check step is extracted and
# run in a throwaway git work tree holding the committed CLI bundle, with a stub
# `gh` serving the base commit's policy files. Test inputs holding a literal
# value set are written at run time inside $BATS_TEST_TMPDIR.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  WORKFLOW="$REPO_ROOT/.github/workflows/tests.yml"
  REQUIRED_CHECKS_PAGE="$REPO_ROOT/.claude/skills/gaia/references/setup/required-ci-checks.md"
  TREE="$BATS_TEST_TMPDIR/tree"
  BASE_FILES="$BATS_TEST_TMPDIR/base-files"
  STUB_BIN="$BATS_TEST_TMPDIR/bin"
  STEP_SCRIPT="$BATS_TEST_TMPDIR/step.sh"
  mkdir -p "$BASE_FILES" "$STUB_BIN" "$BATS_TEST_TMPDIR/runner-temp"
}

require_yaml_parser() {
  if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
    return 0
  fi
  [ -z "${GITHUB_ACTIONS:-}" ] || { echo "no python3 + PyYAML on a CI runner" >&2; return 1; }
  skip "no YAML parser available (python3 + PyYAML)"
}

# Writes the check step's shell body from the workflow to $STEP_SCRIPT.
extract_check_step() {
  python3 - "$WORKFLOW" "$STEP_SCRIPT" <<'PY'
import sys, yaml
with open(sys.argv[1]) as handle:
    document = yaml.safe_load(handle)
steps = document["jobs"]["value-sets"]["steps"]
bodies = [step["run"] for step in steps if "run" in step]
if len(bodies) != 1:
    sys.exit("expected exactly one run step, found %d" % len(bodies))
with open(sys.argv[2], "w") as out:
    out.write(bodies[0])
PY
}

# A `gh` that answers the contents API from $STUB_BASE_FILES: the file when
# present, a 404 when absent, a server error for the path in $STUB_FAIL_PATH.
install_gh_stub() {
  cat > "$STUB_BIN/gh" <<'EOF'
#!/usr/bin/env bash
endpoint=""
for argument in "$@"; do
  case "$argument" in repos/*) endpoint="$argument" ;; esac
done
printf '%s\n' "$endpoint" >> "$STUB_GH_LOG"
requested="${endpoint#*/contents/}"
requested="${requested%%\?ref=*}"
if [ -n "${STUB_FAIL_PATH:-}" ] && [ "$requested" = "$STUB_FAIL_PATH" ]; then
  echo "gh: Server Error (HTTP 500)" >&2
  exit 1
fi
if [ -f "$STUB_BASE_FILES/$requested" ]; then
  cat "$STUB_BASE_FILES/$requested"
  exit 0
fi
echo "gh: Not Found (HTTP 404)" >&2
exit 1
EOF
  chmod +x "$STUB_BIN/gh"
}

write_duplicate_shell() {
  cat > "$TREE/$1" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  -v|--verbose|verbose) echo on ;;
esac
EOF
}

# Two shell files that define the same value set, in a git work tree that
# carries the committed CLI bundle.
build_tree() {
  mkdir -p "$TREE/.gaia/cli"
  cp "$REPO_ROOT/.gaia/cli/gaia" "$TREE/.gaia/cli/gaia"
  chmod +x "$TREE/.gaia/cli/gaia"
  write_duplicate_shell first.sh
  write_duplicate_shell second.sh
  git -C "$TREE" init -q
}

stage_tree() {
  git -C "$TREE" add -A
}

# run_step <event>: runs the extracted step inside $TREE.
run_step() {
  cd "$TREE" || return 1
  PATH="$STUB_BIN:$PATH" \
    REPOSITORY=owner/repository \
    EVENT_NAME="$1" \
    BASE_SHA="${BASE_SHA:-0000000000000000000000000000000000000000}" \
    RUNNER_TEMP="$BATS_TEST_TMPDIR/runner-temp" \
    STUB_BASE_FILES="$BASE_FILES" \
    STUB_GH_LOG="$BATS_TEST_TMPDIR/gh.log" \
    STUB_FAIL_PATH="${STUB_FAIL_PATH:-}" \
    bash "$STEP_SCRIPT" 2>&1
}

write_base_file() {
  mkdir -p "$(dirname "$BASE_FILES/$1")"
  cat > "$BASE_FILES/$1"
}

@test "on a pull request the config, manifest and marker come from the base commit, the head's config is only shape-checked, and a failed base read exits 2" {
  require_yaml_parser
  extract_check_step
  install_gh_stub
  build_tree

  # The pull request's own exclusion is not applied: the base has no config.
  mkdir -p "$TREE/.gaia"
  printf '%s\n' '{"version":1,"exclude":[{"path":"second.sh","reason":"mine"}]}' > "$TREE/.gaia/value-sets.json"
  stage_tree
  run run_step pull_request
  [ "$status" -eq 1 ] || { echo "own exclusion: expected 1, got $status: $output"; return 1; }
  grep -qF "first.sh" <<<"$output" || { echo "own exclusion: no finding naming first.sh: $output"; return 1; }

  # A base with no config and no manifest leaves both absent: the duplicate is reported.
  rm -f "$TREE/.gaia/value-sets.json"
  run run_step pull_request
  [ "$status" -eq 1 ] || { echo "no base config: expected 1, got $status: $output"; return 1; }

  # The base's config is applied: the same duplicate, excluded there, is clean.
  printf '%s\n' '{"version":1,"exclude":[{"path":"second.sh","reason":"kept on purpose"}]}' | write_base_file .gaia/value-sets.json
  run run_step pull_request
  [ "$status" -eq 0 ] || { echo "base exclusion: expected 0, got $status: $output"; return 1; }
  rm -f "$BASE_FILES/.gaia/value-sets.json"

  # A head config entry with no reason fails, naming the head's config.
  printf '%s\n' '{"version":1,"exclude":[{"path":"second.sh"}]}' > "$TREE/.gaia/value-sets.json"
  run run_step pull_request
  [ "$status" -eq 2 ] || { echo "head config: expected 2, got $status: $output"; return 1; }
  grep -qF ".gaia/value-sets.json" <<<"$output" || { echo "head config: not named: $output"; return 1; }
  rm -f "$TREE/.gaia/value-sets.json"

  # A failed base read exits 2 and names the file.
  STUB_FAIL_PATH=.gaia/manifest.json run run_step pull_request
  [ "$status" -eq 2 ] || { echo "failed read: expected 2, got $status: $output"; return 1; }
  grep -qF "value-sets: cannot run: could not read .gaia/manifest.json from the base commit" <<<"$output" \
    || { echo "failed read: message missing: $output"; return 1; }

  # A manifest listing the pull request's files is not applied.
  printf '%s\n' '{"files":{"first.sh":{},"second.sh":{}}}' > "$TREE/.gaia/manifest.json"
  run run_step pull_request
  [ "$status" -eq 1 ] || { echo "head manifest: expected 1, got $status: $output"; return 1; }

  # The same manifest on the base hides the finding on an adopter.
  printf '%s\n' '{"files":{"first.sh":{},"second.sh":{}}}' | write_base_file .gaia/manifest.json
  run run_step pull_request
  [ "$status" -eq 0 ] || { echo "base manifest: expected 0, got $status: $output"; return 1; }

  # A marker on the base keeps the finding reported though the head deleted it.
  printf 'marker\n' | write_base_file .claude/rules/maintainers/harness-triage-threshold.md
  run run_step pull_request
  [ "$status" -eq 1 ] || { echo "deleted marker: expected 1, got $status: $output"; return 1; }

  # Every read named the base sha, and the step never fetches.
  grep -qF "?ref=0000000000000000000000000000000000000000" "$BATS_TEST_TMPDIR/gh.log" \
    || { echo "reads did not name the base sha"; return 1; }
  grep -qF "git fetch" "$STEP_SCRIPT" && return 1
  true
}

@test "a pull request changing only a shell file runs the check and fails on a duplicate" {
  require_yaml_parser
  extract_check_step
  install_gh_stub
  build_tree
  rm "$TREE/second.sh"
  stage_tree
  git -C "$TREE" -c user.name=test -c user.email=test@example.com commit -q -m base
  base_sha="$(git -C "$TREE" rev-parse HEAD)"
  write_duplicate_shell second.sh
  stage_tree
  git -C "$TREE" -c user.name=test -c user.email=test@example.com commit -q -m head

  changed="$(git -C "$TREE" diff --name-only -z "$base_sha" HEAD | tr '\0' '\n')"
  [ "$changed" = "second.sh" ] || { echo "changed files: $changed"; return 1; }

  BASE_SHA="$base_sha" run run_step pull_request
  [ "$status" -eq 1 ] || { echo "expected 1, got $status: $output"; return 1; }
  grep -qF "second.sh" <<<"$output" || { echo "finding does not name second.sh: $output"; return 1; }
}

@test "the Value sets job has no filter or condition, installs at the root and is a required check" {
  require_yaml_parser
  run python3 - "$WORKFLOW" <<'PY'
import sys, yaml
with open(sys.argv[1]) as handle:
    document = yaml.safe_load(handle)
job = (document.get("jobs") or {}).get("value-sets") or {}
problems = []
if job.get("name") != "Value sets":
    problems.append("job name is not 'Value sets'")
if job.get("permissions") != {"contents": "read"}:
    problems.append("permissions are %s" % job.get("permissions"))
steps = job.get("steps") or []
holders = [(job, "job")] + [(step, "step " + str(step.get("name") or step.get("uses"))) for step in steps]
for holder, label in holders:
    for key in ("if", "paths", "paths-ignore", "continue-on-error"):
        if key in holder:
            problems.append("%s carries %s" % (label, key))
checkouts = [step for step in steps if str(step.get("uses", "")).startswith("actions/checkout@")]
if len(checkouts) != 1:
    problems.append("expected one checkout step")
else:
    options = checkouts[0].get("with") or {}
    if options.get("persist-credentials") is not False:
        problems.append("checkout persists credentials")
    for key in ("sparse-checkout", "filter", "fetch-depth", "path"):
        if key in options:
            problems.append("checkout narrows the tree with " + key)
installs = [step for step in steps if step.get("uses") == "./.github/actions/gaia-setup-node"]
if len(installs) != 1:
    problems.append("expected one gaia-setup-node step")
elif (installs[0].get("with") or {}).get("install", "root") != "root":
    problems.append("install is not the root install")
triggers = document.get(True, document.get("on")) or {}
for event, body in triggers.items():
    if isinstance(body, dict) and ("paths" in body or "paths-ignore" in body):
        problems.append(event + " carries a paths filter")
runs = [step["run"] for step in steps if "run" in step]
if len(runs) != 1 or "value-sets --policy-from" not in runs[0]:
    problems.append("no check step runs value-sets --policy-from")
for problem in problems:
    print("PROBLEM " + problem)
PY
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  [ -z "$output" ] || { echo "$output"; return 1; }
  grep -qF "'Value sets'" "$REQUIRED_CHECKS_PAGE" || { echo "required-ci-checks.md detect loop lacks Value sets"; return 1; }
  grep -qF "\`Value sets\`" "$REQUIRED_CHECKS_PAGE" || { echo "required-ci-checks.md job list lacks Value sets"; return 1; }
}
