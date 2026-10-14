#!/usr/bin/env bats
# install-react-doctor.sh: installs the react-doctor skill into frontend/ and strips the extras
# its installer adds. Every case builds a scratch git repo under BATS_TEST_TMPDIR with stub
# `npx` and `pnpm` first on PATH, so no real package manager ever runs. INSTALL_REACT_DOCTOR_SCRIPT
# points the suite at a mutant copy for the mutation proofs.

SCRIPT="${INSTALL_REACT_DOCTOR_SCRIPT:-$BATS_TEST_DIRNAME/../install-react-doctor.sh}"

# The stub installer mimics the verified `react-doctor install --yes --cwd frontend` layout.
# STUB_NPX_MODE picks the outcome:
#   ok            every artifact, exit 0
#   fail_noskill  touches the lockfile, writes no skill, exit 3
#   partial       every artifact including the skill, exit 3
#   no_skill_ok   every artifact except the skill, exit 0
#   bad_hook      every artifact, hook start marker carries a trailing space the strip cannot match
write_stub_npx() {
  cat >"$STUB_BIN/npx" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$NPX_LOG"
mode="${STUB_NPX_MODE:-ok}"
printf 'optional peer churn\n' >>pnpm-lock.yaml
if [ "$mode" = fail_noskill ]; then
  exit 3
fi
if [ "$mode" != no_skill_ok ]; then
  mkdir -p frontend/.claude/skills/react-doctor
  printf 'skill\n' >frontend/.claude/skills/react-doctor/SKILL.md
fi
mkdir -p frontend/.agents/skills/react-doctor .github/workflows
printf 'copy\n' >frontend/.agents/skills/react-doctor/SKILL.md
printf 'name: react-doctor\n' >.github/workflows/react-doctor.yml
start_marker='# react-doctor hook start'
if [ "$mode" = bad_hook ]; then
  start_marker='# react-doctor hook start '
fi
{
  printf '\n%s\n' "$start_marker"
  printf 'npx react-doctor --staged\n'
  printf '# react-doctor hook end\n'
} >>"$(git rev-parse --git-path hooks/pre-commit)"
if [ "$mode" = partial ]; then
  exit 3
fi
STUB
  chmod +x "$STUB_BIN/npx"
}

# STUB_PNPM_MODE: ok, fail_install (install --frozen-lockfile fails), fail_remove (remove fails).
write_stub_pnpm() {
  cat >"$STUB_BIN/pnpm" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$PNPM_LOG"
mode="${STUB_PNPM_MODE:-ok}"
if [ "$mode" = fail_remove ] && [ "$1" = remove ]; then
  printf 'ERR_PNPM_CANNOT_REMOVE_MISSING_DEPS\n' >&2
  exit 1
fi
if [ "$mode" = fail_install ] && [ "$1" = install ]; then
  printf 'ERR_PNPM_OUTDATED_LOCKFILE\n' >&2
  exit 1
fi
exit 0
STUB
  chmod +x "$STUB_BIN/pnpm"
}

setup() {
  REPO="$BATS_TEST_TMPDIR/repo"
  STUB_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$REPO/frontend" "$REPO/.githooks" "$STUB_BIN"
  git -C "$REPO" init -q -b main
  git -C "$REPO" config user.email t@example.com
  git -C "$REPO" config user.name t
  git -C "$REPO" config commit.gpgsign false
  git -C "$REPO" config core.hooksPath .githooks
  printf '{"name":"root"}\n' >"$REPO/package.json"
  printf 'packages:\n  - frontend\n' >"$REPO/pnpm-workspace.yaml"
  printf '{"name":"frontend"}\n' >"$REPO/frontend/package.json"
  printf 'lockfileVersion: 9\n' >"$REPO/pnpm-lock.yaml"
  printf '#!/bin/sh\necho existing hook\n' >"$REPO/.githooks/pre-commit"
  chmod +x "$REPO/.githooks/pre-commit"
  NPX_LOG="$BATS_TEST_TMPDIR/npx.log"
  PNPM_LOG="$BATS_TEST_TMPDIR/pnpm.log"
  : >"$NPX_LOG"
  : >"$PNPM_LOG"
  export NPX_LOG PNPM_LOG
  write_stub_npx
  write_stub_pnpm
  export PATH="$STUB_BIN:$PATH"
  cd "$REPO" || return 1
  cp pnpm-lock.yaml "$BATS_TEST_TMPDIR/lock.before"
  cp .githooks/pre-commit "$BATS_TEST_TMPDIR/hook.before"
}

assert_happy_outcomes() {
  [ -f frontend/.claude/skills/react-doctor/SKILL.md ]
  [ ! -e .github/workflows/react-doctor.yml ]
  [ ! -e frontend/.agents ]
  cmp -s .githooks/pre-commit "$BATS_TEST_TMPDIR/hook.before"
  [ -x .githooks/pre-commit ]
  cmp -s pnpm-lock.yaml "$BATS_TEST_TMPDIR/lock.before"
  [ "$(git config --local --get core.hooksPath)" = ".githooks" ]
}

@test "happy path installs the skill under frontend and strips every extra" {
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  assert_happy_outcomes
  [ "$(cat "$NPX_LOG")" = "-y react-doctor@latest install --yes --cwd frontend" ]
  expected_log='remove react-doctor --config.ignore-scripts=true
--dir frontend pkg delete scripts.doctor scripts["react-doctor"]
install --frozen-lockfile --config.ignore-scripts=true'
  [ "$(cat "$PNPM_LOG")" = "$expected_log" ]
}

@test "unrelated frontend/.agents content survives" {
  mkdir -p frontend/.agents/skills/other
  printf 'keep\n' >frontend/.agents/skills/other/SKILL.md
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -f frontend/.agents/skills/other/SKILL.md ]
  [ ! -e frontend/.agents/skills/react-doctor ]
}

@test "unrelated frontend/.agents sibling file keeps frontend/.agents in place" {
  mkdir -p frontend/.agents
  printf 'keep\n' >frontend/.agents/notes.txt
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -f frontend/.agents/notes.txt ]
}

@test "a second run exits 0 and changes nothing" {
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  assert_happy_outcomes
}

@test "an installer failure that leaves no skill exits 1 naming the install step and restores the lockfile" {
  STUB_NPX_MODE=fail_noskill run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"install step"* ]]
  cmp -s pnpm-lock.yaml "$BATS_TEST_TMPDIR/lock.before"
  [ ! -s "$PNPM_LOG" ]
}

@test "a failing pnpm remove is tolerated with one warning line" {
  STUB_PNPM_MODE=fail_remove run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  assert_happy_outcomes
  [ "$(printf '%s\n' "$output" | grep -c 'pnpm remove')" -eq 1 ]
  grep -qF -- '--dir frontend pkg delete' "$PNPM_LOG"
  grep -qF 'install --frozen-lockfile --config.ignore-scripts=true' "$PNPM_LOG"
}

@test "a non-zero installer that left the skill is a tolerated partial install" {
  STUB_NPX_MODE=partial run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  assert_happy_outcomes
  [ "$(printf '%s\n' "$output" | grep -c 'status 3')" -eq 1 ]
}

@test "a failing frozen install exits 1 naming the pnpm install step" {
  STUB_PNPM_MODE=fail_install run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"pnpm install"* ]]
}

@test "a hook block the strip cannot remove fails the hook verification" {
  STUB_NPX_MODE=bad_hook run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"hook"* ]]
  cmp -s pnpm-lock.yaml "$BATS_TEST_TMPDIR/lock.before"
}

@test "an installer that writes no skill fails the skill verification" {
  STUB_NPX_MODE=no_skill_ok run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"skill"* ]]
}

@test "a repointed hooksPath is re-armed" {
  git config core.hooksPath .git/hooks
  mkdir -p .git/hooks
  cp .githooks/pre-commit .git/hooks/pre-commit
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(git config --local --get core.hooksPath)" = ".githooks" ]
  grep -q 'react-doctor hook' .githooks/pre-commit .git/hooks/pre-commit && return 1
  true
}

@test "--help exits 0 and prints usage" {
  run bash "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage"* ]]
  [ ! -s "$NPX_LOG" ]
}

@test "an unknown argument exits 2 without running the installer" {
  run bash "$SCRIPT" --bogus
  [ "$status" -eq 2 ]
  [[ "$output" == *"Usage"* ]]
  [ ! -s "$NPX_LOG" ]
}
