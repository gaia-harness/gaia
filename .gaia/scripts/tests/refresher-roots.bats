#!/usr/bin/env bats
#
# Conformance suite for the two background refreshers' root derivation
# (`.gaia/scripts/check-updates.sh` and `.gaia/scripts/debt-count-refresh.sh`).
#
# Both write machine-local state the state registry classifies `shared`:
# cache/shared/update-check.json and debt/count.json are one physical copy per
# clone, and the statusline reads them by resolving the main checkout. Until
# this suite existed each refresher derived every path it writes from its own
# location on disk, so a copy running inside a worktree wrote a per-tree copy
# and the nudge it feeds went quiet.
#
# The fixture deliberately gives the worktree a REAL .gaia/local directory
# rather than the symlink to main that provisioning installs. That is the whole
# point: with the symlink in place a per-tree path resolves to main's copy
# anyway, so a suite built on a provisioned worktree would pass whether or not
# the script asks the resolver. Removing the symlink is what makes these
# assertions measure the derivation instead of the cutover.
#
# Run under bash 5 (see .claude/rules/bats-assertions.md):
#   source .gaia/scripts/bats5.sh && bats5 .gaia/scripts/tests/refresher-roots.bats
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  SCRIPTS_DIRECTORY="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  RESOLVER="$SCRIPTS_DIRECTORY/main-root-lib.sh"
  [ -f "$RESOLVER" ] || skip "main-root-lib.sh missing"
  command -v jq >/dev/null 2>&1 || skip "jq required"
  command -v git >/dev/null 2>&1 || skip "git required"
}

# make_pair <script> [--no-resolver]
#
# Builds a committed main checkout holding the named refresher plus the
# resolver, adds a linked worktree at the real .claude/worktrees/<name> layout,
# and gives that worktree its own REAL .gaia/local (see the header note).
# Sets MAIN and WORKTREE. With --no-resolver the resolver is never copied in, which
# is the degrade-to-local path the shipped idiom must still honour.
make_pair() {
  local script="$1"
  local with_resolver=1
  [ "${2:-}" = "--no-resolver" ] && with_resolver=0

  MAIN="$(mktemp -d "$BATS_TEST_TMPDIR/main.XXXXXX")"
  MAIN="$(cd "$MAIN" && pwd -P)"

  mkdir -p "$MAIN/.gaia/scripts" "$MAIN/.gaia/local" "$MAIN/bin"
  cp "$SCRIPTS_DIRECTORY/$script" "$MAIN/.gaia/scripts/$script"
  chmod +x "$MAIN/.gaia/scripts/$script"
  if [ "$with_resolver" -eq 1 ]; then
    cp "$RESOLVER" "$MAIN/.gaia/scripts/main-root-lib.sh"
  fi
  printf '1.0.0\n' > "$MAIN/.gaia/VERSION"
  cp "$SCRIPTS_DIRECTORY/knowledge-inventory.sh" "$MAIN/.gaia/scripts/knowledge-inventory.sh"
  cp "$SCRIPTS_DIRECTORY/exclusive-lock-lib.sh" "$MAIN/.gaia/scripts/exclusive-lock-lib.sh"

  git -C "$MAIN" init -q
  git -C "$MAIN" config user.email t@t.t
  git -C "$MAIN" config user.name t
  git -C "$MAIN" add -A
  git -C "$MAIN" commit -qm fixture

  git -C "$MAIN" worktree add -q "$MAIN/.claude/worktrees/wt" -b wt
  WORKTREE="$MAIN/.claude/worktrees/wt"

  # The worktree owns a real state directory, not main's symlink.
  mkdir -p "$WORKTREE/.gaia/local"
}

# stub_gh <count>: a `gh` whose `issue list` reports <count> open issues and
# whose every other subcommand is a silent success.
stub_gh() {
  cat > "$MAIN/bin/gh" <<STUB
#!/usr/bin/env bash
if [ "\$1" = "issue" ] && [ "\$2" = "list" ]; then
  printf '%s\n' "$1"
fi
exit 0
STUB
  chmod +x "$MAIN/bin/gh"
}

@test "a refresher run from a worktree reads and writes the MAIN checkout's state" {
  make_pair debt-count-refresh.sh
  stub_gh 7
  mkdir -p "$WORKTREE/.gaia/local/debt"
  touch "$WORKTREE/.gaia/local/debt/refresh-requested"

  PATH="$MAIN/bin:$PATH" run bash "$WORKTREE/.gaia/scripts/debt-count-refresh.sh"
  [ "$status" -eq 0 ] || { echo "debt refresher: status $status"; return 1; }
  # The one physical copy the statusline reads lives under main.
  [ -f "$MAIN/.gaia/local/debt/count.json" ] || { echo "debt refresher: no count cache under main"; return 1; }
  # And nothing forked a per-tree copy beside it.
  [ -f "$WORKTREE/.gaia/local/debt/count.json" ] && { echo "debt refresher: forked a per-tree count cache"; return 1; }

  make_pair check-updates.sh
  # The memory dir is machine-local state keyed by the tree's own path
  # spelling, so it is NOT covered by the .gaia/local symlink. Main's slug gets
  # three entries; the worktree's gets one, which is the realistic shape (a
  # freshly created worktree path has almost no memory history). A count of 1
  # here means the shared cache is stating a fact about the worktree, and the
  # cleanse nudge silently stops tracking the clone.
  local main_slug worktree_slug
  main_slug="$(printf %s "$MAIN" | sed 's/[^A-Za-z0-9-]/-/g')"
  worktree_slug="$(printf %s "$WORKTREE" | sed 's/[^A-Za-z0-9-]/-/g')"
  mkdir -p "$BATS_TEST_TMPDIR/home/.claude/projects/$main_slug/memory"
  mkdir -p "$BATS_TEST_TMPDIR/home/.claude/projects/$worktree_slug/memory"
  touch "$BATS_TEST_TMPDIR/home/.claude/projects/$main_slug/memory/"{a,b,c}.md
  touch "$BATS_TEST_TMPDIR/home/.claude/projects/$worktree_slug/memory/only.md"

  # The memory count comes from the CLI inventory, so the worktree's `gaia`
  # hands `fitness` to the committed bundle. Wiki drift is a fact about the
  # main checkout's wiki/.state.json, so the stub records where `wiki state`
  # ran: it must be main even though the script lives in the worktree.
  mkdir -p "$WORKTREE/.gaia/cli"
  cat > "$WORKTREE/.gaia/cli/gaia" <<STUB
#!/usr/bin/env bash
if [ "\$1" = "fitness" ]; then
  exec "$SCRIPTS_DIRECTORY/../cli/gaia" "\$@"
fi
if [ "\$1" = "wiki" ] && [ "\$2" = "state" ]; then
  pwd -P > "$BATS_TEST_TMPDIR/wiki-state-cwd"
  printf '{"drift_count":7}'
  exit 0
fi
exit 1
STUB
  chmod +x "$WORKTREE/.gaia/cli/gaia"

  HOME="$BATS_TEST_TMPDIR/home" PATH="$MAIN/bin:$PATH" \
    run bash "$WORKTREE/.gaia/scripts/check-updates.sh"
  [ "$status" -eq 0 ] || { echo "update refresher: status $status"; return 1; }
  [ -f "$MAIN/.gaia/local/cache/shared/update-check.json" ] || { echo "update refresher: no shared cache under main"; return 1; }
  [ -f "$WORKTREE/.gaia/local/cache/shared/update-check.json" ] && { echo "update refresher: forked a per-tree update cache"; return 1; }
  [ "$(jq -r '.cleanseMemoryCount' "$MAIN/.gaia/local/cache/shared/update-check.json")" = "3" ] || { echo "update refresher: memory count is not main's"; return 1; }
  [ "$(cat "$BATS_TEST_TMPDIR/wiki-state-cwd")" = "$MAIN" ] || { echo "update refresher: wiki drift not asked of main"; return 1; }
  [ "$(jq -r '.wikiDriftCount' "$MAIN/.gaia/local/cache/shared/update-check.json")" = "7" ] || { echo "update refresher: wiki drift count"; return 1; }
}

@test "a refresher with no resolver present degrades to its own root" {
  make_pair debt-count-refresh.sh --no-resolver
  stub_gh 3
  mkdir -p "$WORKTREE/.gaia/local/debt"
  touch "$WORKTREE/.gaia/local/debt/refresh-requested"

  PATH="$MAIN/bin:$PATH" run bash "$WORKTREE/.gaia/scripts/debt-count-refresh.sh"
  [ "$status" -eq 0 ] || { echo "debt refresher: status $status"; return 1; }
  # No resolver to ask, so the local root is the honest answer rather than a
  # failure: the refresher still refreshes something.
  [ -f "$WORKTREE/.gaia/local/debt/count.json" ] || { echo "debt refresher: no local count cache"; return 1; }

  make_pair check-updates.sh --no-resolver
  PATH="$MAIN/bin:$PATH" run bash "$WORKTREE/.gaia/scripts/check-updates.sh"
  [ "$status" -eq 0 ] || { echo "update refresher: status $status"; return 1; }
  [ -f "$WORKTREE/.gaia/local/cache/shared/update-check.json" ] || { echo "update refresher: no local update cache"; return 1; }
}
