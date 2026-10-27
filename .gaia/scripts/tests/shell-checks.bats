#!/usr/bin/env bats
# Tests for the tests workflow's `Shellcheck and bats` job: the selector
# (.gaia/scripts/shell-checks-select.sh), the lint runner
# (.gaia/scripts/shell-checks-lint.sh) and the job's shape in tests.yml.
#
# The selector reads everything through `gh api`. Here `gh` is a stub on PATH
# that answers from a real git fixture (.gaia/tests/helpers/release-skip-fixture.sh),
# so a pull request is a branch, the merge base is git's, and the same
# repository drives the parity case against the audit's own release rule.
#
# Every fixture shell file is written at test time and never committed: the
# maintainer shell lint runs shellcheck over every tracked `.sh`, so a
# committed fixture with a deliberate warning would fail it. The deliberate
# warning is SC2034 (unused variable), which `-S warning` reports.
#
# Run under bash 5 (.claude/rules/bats-assertions.md):
#   bash .gaia/scripts/bats5.sh .gaia/scripts/tests/shell-checks.bats
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SELECTOR="$REPO_ROOT/.gaia/scripts/shell-checks-select.sh"
  LINTER="$REPO_ROOT/.gaia/scripts/shell-checks-lint.sh"
  WORKFLOW="$REPO_ROOT/.github/workflows/tests.yml"
  command -v jq >/dev/null 2>&1 || skip "jq required"
  . "$REPO_ROOT/.gaia/tests/helpers/release-skip-fixture.sh"
  export FIXTURE="$BATS_TEST_TMPDIR/fixture"
  release_skip_init "$FIXTURE"
  OUT="$BATS_TEST_TMPDIR/out"
  export GH_LOG="$BATS_TEST_TMPDIR/gh.log"
  : > "$GH_LOG"
  install_gh_stub
}

# install_gh_stub: a `gh` that answers the endpoints the selector calls from
# $FIXTURE, logs each endpoint to $GH_LOG, and fails any endpoint matching
# $GH_STUB_FAIL with an HTTP 500. A contents read must ask for the plain raw
# media type: under `raw+json` the real gh treats the body as JSON and rewrites
# it (a `\u0000` escape in a fetched script comes back as a NUL byte), so the
# stub refuses any other Accept header.
install_gh_stub() {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[ "$1" = api ] || { echo "stub: unexpected gh $*" >&2; exit 64; }
shift
endpoint="" accept=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -H) accept="$2"; shift 2 ;;
    --paginate) shift ;;
    *) endpoint="$1"; shift ;;
  esac
done
printf '%s\n' "$endpoint" >> "$GH_LOG"
if [ -n "${GH_STUB_FAIL:-}" ] && [[ "$endpoint" == *"$GH_STUB_FAIL"* ]]; then
  echo "gh: Server Error (HTTP 500)" >&2
  exit 1
fi
not_found() { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
case "$endpoint" in
  repos/*/pulls/*/files*)
    if [ -n "${GH_STUB_FILES_JSON:-}" ]; then cat "$GH_STUB_FILES_JSON"; exit 0; fi
    base="$(git -C "$FIXTURE" merge-base "$STUB_BASE" "$STUB_HEAD")"
    git -C "$FIXTURE" diff --name-status --no-renames "$base" "$STUB_HEAD" \
      | jq -R -s 'split("\n") | map(select(length > 0) | split("\t")
          | {status: (if .[0] == "D" then "removed" elif .[0] == "A" then "added" else "modified" end), filename: .[1]})'
    ;;
  repos/*/compare/*)
    range="${endpoint#repos/*/compare/}"; range="${range%%\?*}"
    printf '{"merge_base_commit":{"sha":"%s"}}\n' "$(git -C "$FIXTURE" merge-base "${range%%...*}" "${range#*...}")"
    ;;
  repos/*/contents/*)
    path="${endpoint#repos/*/contents/}"; reference="${path#*\?ref=}"; path="${path%%\?*}"
    case "$(git -C "$FIXTURE" cat-file -t "$reference:$path" 2>/dev/null || true)" in
      blob)
        [ "$accept" = "Accept: application/vnd.github.raw" ] || { echo "stub: file read with header [$accept]" >&2; exit 65; }
        git -C "$FIXTURE" show "$reference:$path"
        ;;
      tree)
        [ -z "$accept" ] || { echo "stub: directory listing with header [$accept]" >&2; exit 65; }
        git -C "$FIXTURE" ls-tree "$reference:$path" \
          | awk -F'\t' '{ split($1, f, " "); printf "%s\t%s\n", (f[2] == "blob" ? "file" : "dir"), $2 }' \
          | jq -R -s 'split("\n") | map(select(length > 0) | split("\t") | {type: .[0], name: .[1]})'
        ;;
      *) not_found ;;
    esac
    ;;
  *) echo "stub: unexpected endpoint $endpoint" >&2; exit 64 ;;
esac
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

# branch <name>: checks out a new branch from main in the fixture.
branch() {
  git -C "$FIXTURE" checkout -q -b "$1" main
}

# put <path> [content]: writes a file in the fixture (default: a clean script).
put() {
  mkdir -p "$(dirname "$FIXTURE/$1")"
  printf '%s\n' "${2:-#!/usr/bin/env bash
echo ok}" > "$FIXTURE/$1"
}

# put_warning <path>: a script carrying SC2034.
put_warning() {
  put "$1" '#!/usr/bin/env bash
unused_variable=1'
}

commit() {
  git -C "$FIXTURE" add -A
  git -C "$FIXTURE" commit -q -m "${1:-change}"
}

bump_version() {
  put .gaia/VERSION 1.1.0
}

suite() {
  put tests/shell/smoke.bats '#!/usr/bin/env bats
@test "smoke" {
  true
}'
}

# plan_pr [extra args]: the selector's plan for branch HEAD against main.
plan_pr() {
  export STUB_BASE STUB_HEAD
  STUB_BASE="$(git -C "$FIXTURE" rev-parse main)"
  STUB_HEAD="$(git -C "$FIXTURE" rev-parse HEAD)"
  run bash "$SELECTOR" plan --repository owner/name --head-sha "$STUB_HEAD" \
    --output-directory "$OUT" --pull-request 7 --base-sha "$STUB_BASE" "$@"
}

value_of() {
  printf '%s\n' "$output" | sed -n "s/^$1=//p"
}

lint_paths() {
  tr '\0' '\n' < "$OUT/lint-paths"
}

expect_plan() {
  [ "$status" -eq 0 ]
  [ "$(value_of lint)" = "$1" ]
  [ "$(value_of bats)" = "$2" ]
  [ "$(value_of checkout)" = "$3" ]
}

need_shellcheck() {
  if command -v shellcheck >/dev/null 2>&1; then return 0; fi
  [ -z "${GITHUB_ACTIONS:-}" ] || { echo "shellcheck missing on a CI runner" >&2; return 1; }
  skip "shellcheck is not installed"
}

# ---------- selection ------------------------------------------------------

@test "no shell change: nothing to do, decided from the files list alone" {
  branch docs
  put README.md '# readme'
  commit
  plan_pr
  expect_plan none false none
  [ "$(wc -l < "$GH_LOG" | tr -d ' ')" -eq 1 ]
  grep -q '/pulls/7/files' "$GH_LOG"
}

@test "an adopter script change is linted through a sparse checkout" {
  branch adopter
  put scripts/deploy.sh
  commit
  plan_pr
  expect_plan changed false sparse
  [ "$(lint_paths)" = "scripts/deploy.sh" ]
  grep -qx '/scripts/deploy.sh' "$OUT/sparse-patterns"
  grep -qx '.shellcheckrc' "$OUT/sparse-patterns"
}

@test "a GAIA update skips owned shell (base only, head only, both) and keeps adopter shell" {
  branch release
  release_skip_apply "$FIXTURE" release
  put scripts/deploy.sh
  commit
  plan_pr
  expect_plan changed false sparse
  [ "$(lint_paths)" = "scripts/deploy.sh" ]
  grep -qx '.gaia/scripts/gaia-retired.sh' "$OUT/owned"
  grep -qx '.gaia/scripts/gaia-new.sh' "$OUT/owned"
  grep -qx '.gaia/scripts/gaia-tool.sh' "$OUT/owned"
}

@test "a GAIA update that changes only owned shell selects nothing" {
  branch release
  release_skip_apply "$FIXTURE" release
  plan_pr
  expect_plan none false none
}

@test "an ordinary pull request lints an owned file it edits" {
  branch hand-edit
  release_skip_apply "$FIXTURE" hand-edit
  plan_pr
  expect_plan changed false sparse
  [ "$(lint_paths)" = ".claude/hooks/gaia-guard.sh" ]
  [ ! -s "$OUT/owned" ]
}

@test "a GAIA update whose head manifest is unreadable skips nothing" {
  branch release
  release_skip_apply "$FIXTURE" release
  git -C "$FIXTURE" rm -q .gaia/manifest.json
  commit
  plan_pr
  expect_plan changed false sparse
  lint_paths | grep -qx '.gaia/scripts/gaia-tool.sh'
}

@test "a deleted file is never linted" {
  put scripts/old.sh
  commit seed
  branch delete
  git -C "$FIXTURE" rm -q scripts/old.sh
  commit
  plan_pr
  expect_plan none false none
}

@test "a rename lints the new path only" {
  branch rename
  put scripts/new.sh
  commit
  export GH_STUB_FILES_JSON="$BATS_TEST_TMPDIR/files.json"
  printf '[{"status":"renamed","filename":"scripts/new.sh","previous_filename":"scripts/old.sh"}]\n' > "$GH_STUB_FILES_JSON"
  plan_pr
  expect_plan changed false sparse
  [ "$(lint_paths)" = "scripts/new.sh" ]
}

@test "project.json shellcheck false turns the lint off; true, absent and malformed lint" {
  branch toggle
  put scripts/deploy.sh
  put .gaia/project.json '{"version": 1, "shellcheck": false}'
  commit
  plan_pr
  expect_plan none false none

  put .gaia/project.json '{"version": 1, "shellcheck": true}'
  commit
  plan_pr
  expect_plan changed false sparse

  put .gaia/project.json '{"version": 1}'
  commit
  plan_pr
  expect_plan changed false sparse

  put .gaia/project.json 'not json'
  commit
  plan_pr
  expect_plan changed false sparse
}

@test "a .shellcheckrc change lints every shell file under the owned rule" {
  branch policy
  bump_version
  put .shellcheckrc 'disable=SC2034'
  commit
  plan_pr
  expect_plan full false full
  [ ! -s "$OUT/lint-paths" ]
  grep -qx '.gaia/scripts/gaia-tool.sh' "$OUT/owned"
}

@test "a shellcheck pin change lints everything; a tests.yml change without one does not" {
  put .github/workflows/tests.yml "    env:
      SHELLCHECK_VERSION: '0.10.0'"
  commit seed
  branch pin
  put .github/workflows/tests.yml "    env:
      SHELLCHECK_VERSION: '0.11.0'"
  commit
  plan_pr
  expect_plan full false full

  git -C "$FIXTURE" checkout -q -b same-pin main
  put .github/workflows/tests.yml "    env:
      # a comment
      SHELLCHECK_VERSION: '0.10.0'"
  commit
  plan_pr
  expect_plan none false none
}

@test "bats is due when a suite exists and selected shell or tests/shell changed" {
  suite
  commit seed
  branch shell
  put scripts/deploy.sh
  commit
  plan_pr
  expect_plan changed true full

  git -C "$FIXTURE" checkout -q -b suite-only main
  put tests/shell/README.md '# suite notes'
  commit
  plan_pr
  expect_plan none true full

  git -C "$FIXTURE" checkout -q -b unrelated main
  put docs/notes.md '# notes'
  commit
  plan_pr
  expect_plan none false none
}

@test "bats is not due without a suite, nor for a GAIA update's owned shell" {
  branch no-suite
  put scripts/deploy.sh
  commit
  plan_pr
  expect_plan changed false sparse

  git -C "$FIXTURE" checkout -q main
  suite
  commit seed
  git -C "$FIXTURE" checkout -q -b release main
  release_skip_apply "$FIXTURE" release
  plan_pr
  expect_plan none false none
}

@test "the shellcheck opt-out leaves bats running" {
  suite
  put .gaia/project.json '{"version": 1, "shellcheck": false}'
  commit seed
  branch shell
  put scripts/deploy.sh
  commit
  plan_pr
  expect_plan none true full
}

@test "a manual run lints everything and runs bats when a suite exists" {
  suite
  commit seed
  run bash "$SELECTOR" plan --repository owner/name --head-sha main --output-directory "$OUT"
  expect_plan full true full
}

@test "a pull request at the files cap takes its diff from git, not the API" {
  branch big
  put scripts/deploy.sh
  commit
  plan_pr --changed-file-count 3000 --remote "$FIXTURE"
  expect_plan changed false sparse
  [ "$(lint_paths)" = "scripts/deploy.sh" ]
  grep -q '/pulls/7/files' "$GH_LOG" && return 1
  true
}

@test "an API error fails the plan rather than guessing" {
  branch adopter
  put scripts/deploy.sh
  commit
  GH_STUB_FAIL=/pulls/ plan_pr
  [ "$status" -eq 1 ]
  GH_STUB_FAIL=/contents/.gaia/project.json plan_pr
  [ "$status" -eq 1 ]
}

@test "a path with a space or a pattern character is matched literally by its sparse pattern" {
  branch odd
  put 'scripts/my tool[1].sh'
  commit
  plan_pr
  expect_plan changed false sparse
  grep -qxF '/scripts/my tool\[1\].sh' "$OUT/sparse-patterns"
}

@test "filter keeps shell paths the owned list does not name" {
  printf '%s\n' .gaia/scripts/gaia-tool.sh > "$BATS_TEST_TMPDIR/owned"
  run bash -c 'printf "%s\0" .gaia/scripts/gaia-tool.sh scripts/a.sh tests/a.bats README.md \
    | bash "$1" filter --owned "$2" | tr "\0" "\n"' _ "$SELECTOR" "$BATS_TEST_TMPDIR/owned"
  [ "$status" -eq 0 ]
  [ "$output" = "scripts/a.sh
tests/a.bats" ]
}

# ---------- parity with the audit's release rule ---------------------------

# audit_shell_paths <branch>: changed .sh/.bats paths still present at the head
# that the audit routes to the release-skipping member.
audit_shell_paths() {
  bash -c '
    library="$1" root="$2"
    . "$library/audit-scope.sh" || exit 9
    audit_scope_init "$root" "$root/.gaia/audit-ci.yml" || exit 9
    audit_scope_release_context "$root" main HEAD
    git -C "$root" diff --name-only -z --no-renames --diff-filter=d "$(git -C "$root" merge-base main HEAD)" HEAD \
      | tr "\0" "\n" | grep -E "\.(sh|bats)$" | audit_owners_for_paths
  ' _ "$REPO_ROOT/.claude/hooks/lib" "$FIXTURE" | awk -F'\t' '$2 == "fixture-shell" { print $1 }' | sort
}

@test "the selector and the audit agree on every release-skip branch kind" {
  local kind checked=0
  for kind in release ordinary hand-edit hand-edit-release mixed; do
    git -C "$FIXTURE" checkout -q -b "$kind" main
    release_skip_apply "$FIXTURE" "$kind"
    plan_pr
    [ "$status" -eq 0 ]
    [ "$(lint_paths | sort)" = "$(audit_shell_paths)" ] || {
      echo "disagreement on $kind: selector [$(lint_paths | tr '\n' ' ')] audit [$(audit_shell_paths | tr '\n' ' ')]" >&2
      return 1
    }
    checked=$((checked + 1))
  done
  [ "$checked" -eq 5 ]
}

@test "guard can fail: a selector that ignores the VERSION check disagrees with the audit" {
  sed 's/! cmp -s "\$inputs\/base-VERSION" "\$inputs\/head-VERSION"/true/' "$SELECTOR" > "$BATS_TEST_TMPDIR/broken.sh"
  grep -q 'cmp -s' "$BATS_TEST_TMPDIR/broken.sh" && return 1
  SELECTOR="$BATS_TEST_TMPDIR/broken.sh"
  branch hand-edit
  release_skip_apply "$FIXTURE" hand-edit
  plan_pr
  [ "$status" -eq 0 ]
  [ "$(lint_paths | sort)" != "$(audit_shell_paths)" ]
}

# ---------- lint runner ----------------------------------------------------

lint() {
  run bash -c '{ [ "$#" -lt 2 ] || printf "%s\0" "${@:2}"; } | bash "$1" --root "$FIXTURE"' _ "$LINTER" "$@"
}

@test "lint: a warning fails and names the code; a clean file passes" {
  need_shellcheck
  put_warning scripts/bad.sh
  put scripts/good.sh
  lint scripts/bad.sh scripts/good.sh
  [ "$status" -eq 1 ]
  [[ "$output" == *SC2034* ]]
  lint scripts/good.sh
  [ "$status" -eq 0 ]
}

@test "lint: a bats file is linted as bash" {
  need_shellcheck
  put tests/shell/bad.bats '#!/usr/bin/env bats
unused_variable=1
@test "x" {
  true
}'
  lint tests/shell/bad.bats
  [ "$status" -eq 1 ]
  [[ "$output" == *SC2034* ]]
}

@test "lint: the root .shellcheckrc applies" {
  need_shellcheck
  put_warning scripts/bad.sh
  put .shellcheckrc 'disable=SC2034'
  lint scripts/bad.sh
  [ "$status" -eq 0 ]
}

@test "lint: no paths passes; a missing path is a usage error" {
  lint
  [ "$status" -eq 0 ]
  lint scripts/absent.sh
  [ "$status" -eq 2 ]
}

@test "selection then lint: a warning in an owned file an ordinary pull request edits fails" {
  need_shellcheck
  branch hand-edit
  put_warning .claude/hooks/gaia-guard.sh
  commit
  plan_pr
  expect_plan changed false sparse
  run bash -c 'bash "$1" --root "$2" < "$3"' _ "$LINTER" "$FIXTURE" "$OUT/lint-paths"
  [ "$status" -eq 1 ]
  [[ "$output" == *SC2034* ]]
}

# ---------- the job in tests.yml -------------------------------------------

require_yaml_parser() {
  if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
    return 0
  fi
  [ -z "${GITHUB_ACTIONS:-}" ] || { echo "no python3 + PyYAML on a CI runner" >&2; return 1; }
  skip "no YAML parser available (python3 + PyYAML)"
}

# job_shape <workflow>: prints one PROBLEM line per broken contract, nothing
# when the job holds every one.
job_shape() {
  python3 - "$1" <<'PY'
import sys, yaml
with open(sys.argv[1]) as handle:
    document = yaml.safe_load(handle)
triggers = document.get(True, document.get("on")) or {}
jobs = document.get("jobs") or {}
shell = jobs.get("shell") or {}
problems = []
for event, body in triggers.items():
    if isinstance(body, dict) and ("paths" in body or "paths-ignore" in body):
        problems.append(f"{event} carries a paths filter")
if shell.get("name") != "Shellcheck and bats":
    problems.append("job name is not 'Shellcheck and bats'")
if shell.get("if") != (jobs.get("tests") or {}).get("if"):
    problems.append("job condition differs from the tests job")
permissions = shell.get("permissions") or {}
if permissions != {"contents": "read", "pull-requests": "read"}:
    problems.append(f"permissions are {permissions}")
steps = shell.get("steps") or []
if not steps or steps[0].get("id") != "select" or "uses" in steps[0]:
    problems.append("first step is not the checkout-free select step")
for step in steps[1:]:
    if "steps.select.outputs." not in str(step.get("if", "")):
        problems.append(f"step '{step.get('name')}' is not gated on the select step")
text = open(sys.argv[1]).read()
if "vnd.github.raw+json" in text:
    problems.append("a contents read uses the raw+json media type, which gh rewrites")
if "vars." in text:
    problems.append("the workflow reads a repository variable")
for problem in problems:
    print("PROBLEM " + problem)
PY
}

@test "the shell job runs on every pull request, selects first and gates the rest" {
  require_yaml_parser
  run job_shape "$WORKFLOW"
  [ "$status" -eq 0 ]
  [ -z "$output" ] || { echo "$output" >&2; return 1; }
}

@test "guard can fail: the shape check reds on an ungated checkout and a paths filter" {
  require_yaml_parser
  local broken="$BATS_TEST_TMPDIR/tests.yml"
  python3 - "$WORKFLOW" "$broken" <<'PY'
import sys, yaml
with open(sys.argv[1]) as handle:
    document = yaml.safe_load(handle)
triggers = document.get(True, document.get("on"))
triggers["pull_request"]["paths"] = ["**/*.sh"]
document["jobs"]["shell"]["steps"].insert(1, {"name": "Ungated", "uses": "actions/checkout@x"})
with open(sys.argv[2], "w") as handle:
    yaml.safe_dump(document, handle)
PY
  run job_shape "$broken"
  [[ "$output" == *"paths filter"* ]]
  [[ "$output" == *"'Ungated' is not gated"* ]]
}

@test "actionlint passes on the workflow" {
  command -v actionlint >/dev/null 2>&1 || skip "actionlint is not installed"
  run actionlint "$WORKFLOW"
  [ "$status" -eq 0 ]
}
