#!/usr/bin/env bash
# Installs the react-doctor Claude Code skill into frontend/.claude/skills/ and strips the extras
# its installer adds, so GAIA stays the sole controller of when react-doctor runs (the skill's
# auto-run after edits and the code-audit-frontend agent).
#
# Usage: bash .gaia/scripts/install-react-doctor.sh   (from the repository root, no arguments)
#
# Exit codes:
#   0  done, including two tolerated failures that each print one warning line: `pnpm remove`
#      failing (the dependency can be absent when a trust policy or pnpm's release-age hold
#      skipped its install), and a non-zero installer that still left the skill (a partial
#      install; the strip and the verification still run and decide the exit code)
#   1  the installer failed without leaving the skill, another step failed, or verification failed
#   2  usage error
#
# The package directory is the constant `frontend`: it is GAIA's React package, and `--cwd` there
# makes the skill land where its "before committing React code" trigger only lists for React work.
# The installer has no skill-only flag, so everything else it writes is removed below.

set -euo pipefail

package_directory="frontend"
skill_directory="$package_directory/.claude/skills/react-doctor"
usage="Usage: bash .gaia/scripts/install-react-doctor.sh (run from the repository root, no arguments)"

lockfile_snapshot=""

fail() {
  printf 'install-react-doctor: %s\n' "$1" >&2
  exit 1
}

warn() {
  printf 'install-react-doctor: warning: %s\n' "$1" >&2
}

restore_lockfile() {
  if [ -n "$lockfile_snapshot" ] && [ -f "$lockfile_snapshot" ]; then
    cat "$lockfile_snapshot" >pnpm-lock.yaml
    rm -f "$lockfile_snapshot"
    lockfile_snapshot=""
  fi
}

if [ "$#" -gt 0 ]; then
  if [ "$1" = "--help" ] && [ "$#" -eq 1 ]; then
    printf '%s\n' "$usage"
    exit 0
  fi
  printf '%s\n' "$usage" >&2
  exit 2
fi

# The installer's dependency resolution fills optional peer slots of other packages in
# pnpm-lock.yaml, which `pnpm remove` leaves behind. The snapshot is restored byte for byte on
# every exit path, so lockfile edits made before the install survive it.
[ -f pnpm-lock.yaml ] || fail "pnpm-lock.yaml not found; run from the repository root"
lockfile_snapshot="$(mktemp)"
trap restore_lockfile EXIT
cat pnpm-lock.yaml >"$lockfile_snapshot"

installer_status=0
npx -y react-doctor@latest install --yes --cwd "$package_directory" || installer_status=$?
if [ "$installer_status" -ne 0 ]; then
  if [ -d "$skill_directory" ]; then
    warn "react-doctor installer exited with status $installer_status but left the skill; continuing"
  else
    fail "react-doctor install step failed with status $installer_status and left no skill"
  fi
fi

rm -f .github/workflows/react-doctor.yml

# The non-Claude skill copy (Codex, Cursor, Copilot, Warp, and others). The now-empty parents go
# too, but unrelated .agents/ content stays untouched because rmdir refuses a non-empty directory.
rm -rf "$package_directory/.agents/skills/react-doctor"
rmdir "$package_directory/.agents/skills" "$package_directory/.agents" 2>/dev/null || true

if ! pnpm remove react-doctor --config.ignore-scripts=true 2>/dev/null; then
  warn "pnpm remove react-doctor failed; the dependency may already be absent, continuing"
fi

# The hyphenated key is written in bracket-and-quote form to be safe across pnpm
# versions.
pnpm --dir "$package_directory" pkg delete scripts.doctor 'scripts["react-doctor"]' \
  || fail "pnpm pkg delete step failed removing the react-doctor package scripts"

# Remove the installer's block (and the blank line it adds before it) from the pre-commit hook it
# wrote into. The file is rewritten in place with `cat >` rather than `mv` to keep its executable bit.
hook_file="$(git rev-parse --git-path hooks/pre-commit)"
if [ -f "$hook_file" ] && grep -q '^# react-doctor hook start$' "$hook_file"; then
  hook_stripped="$(mktemp)"
  awk '
    /^# react-doctor hook start$/ { in_block = 1; if (have_prev && prev == "") have_prev = 0; next }
    in_block { if ($0 == "# react-doctor hook end") in_block = 0; next }
    { if (have_prev) print prev; prev = $0; have_prev = 1 }
    END { if (have_prev) print prev }
  ' "$hook_file" >"$hook_stripped" || fail "hook strip step failed reading $hook_file"
  cat "$hook_stripped" >"$hook_file"
  rm -f "$hook_stripped"
fi

# Re-arm the hook path: a clone whose dependencies were installed before `git init` skipped `prepare`.
if [ "$(git config --local --get core.hooksPath || true)" != ".githooks" ]; then
  git config core.hooksPath .githooks || fail "git config step failed setting core.hooksPath"
fi

restore_lockfile
pnpm install --frozen-lockfile --config.ignore-scripts=true \
  || fail "pnpm install step failed resyncing node_modules to the restored lockfile"

[ -d "$skill_directory" ] || fail "verification failed: $skill_directory is missing"
if [ -f "$hook_file" ] && grep -q 'react-doctor hook' "$hook_file"; then
  fail "verification failed: $hook_file still carries a react-doctor hook line"
fi
[ "$(git config --local --get core.hooksPath || true)" = ".githooks" ] \
  || fail "verification failed: core.hooksPath is not .githooks"
