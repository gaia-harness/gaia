#!/usr/bin/env bash
# 05-clean-env.sh
#
# Layer 1 isolation: validates the create-gaia bootstrapper survives in
# a PATH-stripped environment with no pnpm/uv/claude pre-installed.
#
# What this DOES test:
#   - Tarball extraction works without dev tools.
#   - Corepack-driven pnpm bootstrap (the path adopters hit on first
#     run) succeeds.
#   - `pnpm install --frozen-lockfile` works after corepack provisions
#     pnpm.
#   - bats is absent before install; after it, `pnpm exec bats --version`
#     prints the version the staged package.json pins.
#   - With a bash 4+ first on PATH, `pnpm test:shell` runs a one-test suite
#     (TAP plan 1..1, ok 1); with a bash older than 4 first it exits non-zero
#     with one line naming the shell stack reference and plans no test. The
#     bash 4 run is skipped (a failure under GAIA_DISTRIBUTION_REQUIRE_COREPACK=1)
#     on a host with no bash 4+.
#
# What this does NOT test:
#   - /gaia-init or /setup-gaia execution (would need Claude).
#   - Full filesystem isolation (a true Docker run is the answer; deferred).
#   - Linux-only adopter environments (the host OS is what it is).
#
# Skipped automatically (soft PASS) if `corepack` is not on PATH; the
# bootstrap path is unverifiable without it. Setting
# GAIA_DISTRIBUTION_REQUIRE_COREPACK=1 turns that skip into a failure, so a
# release gate cannot count a run whose frozen install never happened.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib/lib.sh"

require_command jq "jq required to read the pinned bats version from the staged package.json"

if ! command -v corepack >/dev/null 2>&1; then
  if [ "${GAIA_DISTRIBUTION_REQUIRE_COREPACK:-}" = "1" ]; then
    fail "corepack not on PATH and GAIA_DISTRIBUTION_REQUIRE_COREPACK=1 forbids skipping"
    exit 1
  fi
  log "corepack not on PATH; skipping (Node 16.13+ ships corepack)"
  pass "corepack unavailable; scenario skipped (Node ships corepack since v16.13)"
  exit 0
fi

# We need a populated staging tree to extract; reuse the build helper
# in the OUTER environment (PATH-stripping happens for the bootstrap
# step, not the staging step; staging needs git/tar/rsync/jq/the CLI
# binary, all of which Layer 0 maintainers have).
STAGING="$(mktemp -d -t gaia-dist-cleanenv-stage-XXXXXX)"
SCAFFOLD="$(mktemp -d -t gaia-dist-cleanenv-scaffold-XXXXXX)"
FAKE_HOME="$(mktemp -d -t gaia-dist-cleanenv-home-XXXXXX)"
trap 'rm -rf "$STAGING" "$SCAFFOLD" "$FAKE_HOME"' EXIT

"$HERE/lib/build-staging.sh" "$STAGING" \
  || { fail "build-staging failed"; exit 1; }

# Tar the staged tree, then extract into SCAFFOLD; same shape as
# create-gaia's download+extract step. Bypasses the actual GitHub fetch
# (we have the staging dir locally).
TARBALL="$(mktemp -t gaia-dist-cleanenv-tar.XXXXXX).tar.gz"
trap 'rm -rf "$STAGING" "$SCAFFOLD" "$FAKE_HOME" "$TARBALL"' EXIT
tar -czf "$TARBALL" -C "$STAGING" .

# Resolve the corepack and node paths in the OUTER PATH (we'll stash
# them so the inner subshell can still find them; the test isn't about
# hiding Node itself, just dev tools the adopter wouldn't have).
NODE_BIN="$(command -v node)"
COREPACK_BIN="$(command -v corepack)"
TAR_BIN="$(command -v tar)"
GIT_BIN="$(command -v git)"
[ -n "$NODE_BIN" ]     || { fail "node unavailable on outer PATH"; exit 1; }
[ -n "$COREPACK_BIN" ] || { fail "corepack unavailable on outer PATH"; exit 1; }

# Run the bootstrap in a subshell with stripped PATH and isolated HOME.
# PATH includes only system binaries plus the directories holding node /
# corepack / tar / git that we resolved above. Nothing from
# /usr/local/bin or homebrew, so any pnpm/uv/claude on the maintainer's
# machine becomes invisible.
mkdir -p "$FAKE_HOME/bin"
ln -s "$NODE_BIN"     "$FAKE_HOME/bin/node"
ln -s "$COREPACK_BIN" "$FAKE_HOME/bin/corepack"
ln -s "$TAR_BIN"      "$FAKE_HOME/bin/tar"
ln -s "$GIT_BIN"      "$FAKE_HOME/bin/git"

# The shell test stack reads the first bash on PATH, so the scenario decides
# which bash each run sees. A bash 4+ directory comes from the first candidate
# that reports a major of 4 or more; a stock macOS host has none on the default
# PATH, so the Homebrew locations are tried too. Without one the bash-4 run is
# skipped, which GAIA_DISTRIBUTION_REQUIRE_COREPACK=1 turns into a failure so a
# release gate cannot count a run that never exercised it.
expected_bats_version="$(jq -r '.devDependencies.bats // empty' "$STAGING/package.json")"
[ -n "$expected_bats_version" ] || { fail "the staged root package.json pins no bats devDependency"; exit 1; }

bash_major_of() {
  # shellcheck disable=SC2016 # the probe expands inside the child bash
  "$1" -c 'printf %s "${BASH_VERSINFO[0]}"' 2>/dev/null || true
}
BASH4_DIRECTORY=""
for candidate_bash in "$(command -v bash || true)" /opt/homebrew/bin/bash /usr/local/bin/bash /bin/bash /usr/bin/bash; do
  [ -x "$candidate_bash" ] || continue
  candidate_major="$(bash_major_of "$candidate_bash")"
  case "$candidate_major" in
    '' | *[!0-9]*) continue ;;
  esac
  if [ "$candidate_major" -ge 4 ]; then
    BASH4_DIRECTORY="$FAKE_HOME/bash4"
    mkdir -p "$BASH4_DIRECTORY"
    ln -s "$candidate_bash" "$BASH4_DIRECTORY/bash"
    break
  fi
done
if [ -z "$BASH4_DIRECTORY" ]; then
  if [ "${GAIA_DISTRIBUTION_REQUIRE_COREPACK:-}" = "1" ]; then
    fail "no bash 4+ found for the shell test run and GAIA_DISTRIBUTION_REQUIRE_COREPACK=1 forbids skipping"
    exit 1
  fi
  log "no bash 4+ found; the bats run under bash 4 is skipped"
fi

# A bash older than 4 first on PATH: the real /bin/bash when it reports a
# major below 4 (stock macOS), otherwise a shim that answers the version probe
# with 3.
BASH3_DIRECTORY="$FAKE_HOME/bash3"
mkdir -p "$BASH3_DIRECTORY"
if [ -x /bin/bash ] && [ "$(bash_major_of /bin/bash)" = "3" ]; then
  ln -s /bin/bash "$BASH3_DIRECTORY/bash"
else
  printf '#!/bin/sh\nprintf 3\n' > "$BASH3_DIRECTORY/bash"
  chmod +x "$BASH3_DIRECTORY/bash"
fi

(
  unset PNPM_HOME UV_HOME npm_config_prefix
  export HOME="$FAKE_HOME"
  export PATH="/usr/bin:/bin:$FAKE_HOME/bin"

  # Confirm pnpm is NOT visible; this is the test invariant.
  if command -v pnpm >/dev/null 2>&1; then
    printf 'pnpm IS visible in stripped subshell; PATH-strip failed\n' >&2
    exit 1
  fi
  if command -v bats >/dev/null 2>&1; then
    printf 'bats IS visible before install; the adopter must get it from the pinned devDependency\n' >&2
    exit 1
  fi

  cd "$SCAFFOLD"
  tar -xzf "$TARBALL" --strip-components=0 -C .
  git init --quiet --initial-branch=main
  git config user.email "test@example.com"
  git config user.name "Distribution Test"
  git config commit.gpgsign false
  git add . >/dev/null 2>&1

  # Mirror create-gaia's ensurePnpm(); corepack first, npm install -g
  # fallback. Only test the corepack path here (the npm fallback would
  # mutate the host's global npm, which we don't want in a test).
  corepack enable pnpm

  # Now pnpm should be visible (provisioned by corepack into ~/.local/...).
  command -v pnpm >/dev/null 2>&1 \
    || { printf 'corepack did not provision pnpm into PATH\n' >&2; exit 1; }

  pnpm --version >/dev/null
  install_log="$(mktemp "$FAKE_HOME/pnpm-install-XXXXXX")"
  if ! pnpm install --frozen-lockfile >"$install_log" 2>&1; then
    printf 'FAIL: pnpm install --frozen-lockfile failed; last 40 lines of output:\n' >&2
    tail -n 40 "$install_log" >&2
    exit 1
  fi

  # The pinned bats arrives with the frozen install, at exactly the staged
  # package.json version.
  bats_version_output="$(pnpm exec bats --version 2>&1)" \
    || { printf 'pnpm exec bats --version failed: %s\n' "$bats_version_output" >&2; exit 1; }
  if [ "$bats_version_output" != "Bats $expected_bats_version" ]; then
    printf 'bats reports "%s", expected "Bats %s"\n' "$bats_version_output" "$expected_bats_version" >&2
    exit 1
  fi

  mkdir -p tests/shell
  cat > tests/shell/smoke.bats <<'SMOKE'
#!/usr/bin/env bats

@test "runs under bash 4 or later" {
  [ "${BASH_VERSINFO[0]}" -ge 4 ]
}
SMOKE

  if [ -n "$BASH4_DIRECTORY" ]; then
    suite_output="$(PATH="$BASH4_DIRECTORY:$PATH" pnpm test:shell 2>&1)" \
      || { printf 'pnpm test:shell failed under bash 4:\n%s\n' "$suite_output" >&2; exit 1; }
    printf '%s\n' "$suite_output" | grep -qx '1\.\.1' \
      || { printf 'pnpm test:shell did not plan one test:\n%s\n' "$suite_output" >&2; exit 1; }
    printf '%s\n' "$suite_output" | grep -q '^ok 1 ' \
      || { printf 'pnpm test:shell did not report ok 1:\n%s\n' "$suite_output" >&2; exit 1; }
  fi

  refusal_status=0
  refusal_output="$(PATH="$BASH3_DIRECTORY:$PATH" pnpm test:shell 2>&1)" || refusal_status=$?
  if [ "$refusal_status" -eq 0 ]; then
    printf 'pnpm test:shell ran under a bash older than 4:\n%s\n' "$refusal_output" >&2
    exit 1
  fi
  if [ "$(printf '%s\n' "$refusal_output" | grep -cF '.claude/skills/tdd/references/tests-shell.md')" -ne 1 ]; then
    printf 'expected exactly one line naming the shell stack reference:\n%s\n' "$refusal_output" >&2
    exit 1
  fi
  if printf '%s\n' "$refusal_output" | grep -qx '1\.\.1'; then
    printf 'pnpm test:shell planned a test despite the old bash:\n%s\n' "$refusal_output" >&2
    exit 1
  fi
)

pass "clean-env bootstrap (PATH-strip + corepack pnpm provision) succeeded; frozen install ran"
