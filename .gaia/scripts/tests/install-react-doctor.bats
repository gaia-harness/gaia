#!/usr/bin/env bats
# install-react-doctor.sh: copies GAIA's react-doctor skill template into the web member's
# .claude/skills/, with the pinned version substituted. Every case builds a scratch git repo under
# BATS_TEST_TMPDIR holding copies of the real template and pin file, with logging `npx` and `pnpm`
# stubs first on PATH to prove neither runs. INSTALL_REACT_DOCTOR_SCRIPT points the suite at a
# mutant copy for the mutation proofs.

SCRIPT="${INSTALL_REACT_DOCTOR_SCRIPT:-$BATS_TEST_DIRNAME/../install-react-doctor.sh}"
REAL_ROOT="$BATS_TEST_DIRNAME/../../.."

write_logging_stub() {
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"%s"\n' "$TOOL_LOG" >"$STUB_BIN/$1"
  chmod +x "$STUB_BIN/$1"
}

# write_web_descriptor <name> <path>: registers one web-stack member in the scratch repo.
write_web_descriptor() {
  mkdir -p "$REPO/.gaia" "$REPO/$2"
  printf '[{"name":"%s","path":"%s"}]\n' "$1" "$2" >"$REPO/.gaia/packages.json"
  printf '{"schemaVersion":1,"name":"%s","stack":"web","globs":{"tddUnitTests":[],"tddStrictCandidates":[],"emergentTests":[],"preCommitSource":[],"doctorConfigs":[],"dependencyManifests":[]},"wiki":{"flowPaths":[],"inventoryPaths":[],"sourcePaths":[]}}\n' "$1" >"$REPO/$2/gaia.package.json"
}

# expected_skill <dir>: every real template file with the pin substituted, the way the script must
# render it.
expected_skill() {
  local version template_root template_file
  version="$(cat "$REAL_ROOT/.gaia/react-doctor-version")"
  template_root="$REAL_ROOT/.gaia/templates/react-doctor"
  while IFS= read -r template_file; do
    mkdir -p "$1/$(dirname "${template_file#"$template_root"/}")"
    sed "s/{{REACT_DOCTOR_VERSION}}/$version/g" "$template_file" >"$1/${template_file#"$template_root"/}"
  # gaia-lint-ignore whole-tree-mark-guard: the operand is the react-doctor template folder this suite names, not the tracked tree, so a template change selects this suite
  done < <(find "$template_root" -type f)
}

setup() {
  REPO="$BATS_TEST_TMPDIR/repo"
  STUB_BIN="$BATS_TEST_TMPDIR/bin"
  TOOL_LOG="$BATS_TEST_TMPDIR/tools.log"
  mkdir -p "$REPO/apps/web" "$REPO/.githooks" "$REPO/.claude/hooks/lib" "$REPO/.gaia/scripts" "$REPO/.gaia/templates" "$STUB_BIN"
  git -C "$REPO" init -q -b main
  git -C "$REPO" config core.hooksPath .githooks
  cp "$REAL_ROOT/.claude/hooks/lib/gaia-packages.sh" "$REPO/.claude/hooks/lib/"
  cp "$REAL_ROOT/.gaia/react-doctor-version" "$REPO/.gaia/"
  cp "$REAL_ROOT/.gaia/scripts/react-doctor-version-lib.sh" "$REPO/.gaia/scripts/"
  cp -R "$REAL_ROOT/.gaia/templates/react-doctor" "$REPO/.gaia/templates/"
  write_web_descriptor web apps/web
  : >"$TOOL_LOG"
  write_logging_stub npx
  write_logging_stub pnpm
  export PATH="$STUB_BIN:$PATH"
  expected_skill "$BATS_TEST_TMPDIR/expected"
  cd "$REPO" || return 1
}

@test "the pin file holds one semantic version" {
  grep -Eqx '[0-9]+\.[0-9]+\.[0-9]+' "$REAL_ROOT/.gaia/react-doctor-version"
}

@test "the template carries no /doctor trigger, remote fetch or unpinned version" {
  template="$REAL_ROOT/.gaia/templates/react-doctor"
  [ -f "$template/SKILL.md" ]
  [ -f "$template/references/explain.md" ]
  grep -rqE -e '/doctor([^.a-z-]|$)' -e 'https?://' -e 'curl' -e '@latest' "$template" && return 1
  grep -rqF 'react-doctor@{{REACT_DOCTOR_VERSION}}' "$template/SKILL.md"
}

@test "install copies the template with the pinned version and runs no package manager" {
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  diff -r "$BATS_TEST_TMPDIR/expected" apps/web/.claude/skills/react-doctor
  grep -rqF '{{' apps/web/.claude/skills/react-doctor && return 1
  [ ! -s "$TOOL_LOG" ]
}

@test "a second run exits 0 and leaves the same skill" {
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  diff -r "$BATS_TEST_TMPDIR/expected" apps/web/.claude/skills/react-doctor
}

@test "--refresh replaces an upstream-installed skill, extra files included" {
  mkdir -p apps/web/.claude/skills/react-doctor/references
  printf -- '---\nname: react-doctor\ndescription: when the user types `/doctor`\n---\ncurl https://www.react.doctor/prompts/react-doctor-agent.md\n' \
    >apps/web/.claude/skills/react-doctor/SKILL.md
  printf 'npx react-doctor@latest rules list\n' >apps/web/.claude/skills/react-doctor/references/explain.md
  printf 'stale\n' >apps/web/.claude/skills/react-doctor/references/stale.md
  run bash "$SCRIPT" --refresh
  [ "$status" -eq 0 ]
  diff -r "$BATS_TEST_TMPDIR/expected" apps/web/.claude/skills/react-doctor
  [ ! -s "$TOOL_LOG" ]
}

@test "--refresh with no member holding the skill exits 0 and installs nothing" {
  run bash "$SCRIPT" --refresh
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to refresh"* ]]
  [ ! -e apps/web/.claude ]
}

@test "a missing pin file exits 1 and writes no skill" {
  rm .gaia/react-doctor-version
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"react-doctor-version"* ]]
  [ ! -e apps/web/.claude/skills/react-doctor ]
}

@test "a pin that is not a version exits 1 and keeps the installed skill" {
  mkdir -p apps/web/.claude/skills/react-doctor
  printf 'kept\n' >apps/web/.claude/skills/react-doctor/SKILL.md
  printf 'latest\n' >.gaia/react-doctor-version
  run bash "$SCRIPT" --refresh
  [ "$status" -eq 1 ]
  [ "$(cat apps/web/.claude/skills/react-doctor/SKILL.md)" = kept ]
}

@test "a missing template exits 1 and writes no skill" {
  rm -rf .gaia/templates/react-doctor
  run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"template"* ]]
  [ ! -e apps/web/.claude/skills/react-doctor ]
}

@test "a repointed hooksPath is re-armed" {
  git config core.hooksPath .git/hooks
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(git config --local --get core.hooksPath)" = ".githooks" ]
}

@test "--help exits 0 and prints usage" {
  run bash "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage"* ]]
}

@test "an unknown argument exits 2 and installs nothing" {
  run bash "$SCRIPT" --bogus
  [ "$status" -eq 2 ]
  [[ "$output" == *"Usage"* ]]
  [ ! -e apps/web/.claude ]
}

@test "a registry with no web-stack member exits 0 and installs nothing" {
  jq 'del(.stack)' apps/web/gaia.package.json >apps/web/gaia.package.json.tmp
  mv apps/web/gaia.package.json.tmp apps/web/gaia.package.json
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"stack"* ]]
  [ ! -e apps/web/.claude ]
}

@test "the skill is installed under a web member named storefront at its own path" {
  rm -rf apps/web
  write_web_descriptor storefront apps/storefront
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  diff -r "$BATS_TEST_TMPDIR/expected" apps/storefront/.claude/skills/react-doctor
}
