#!/usr/bin/env bats
#
# Flow test: the value-set check fails on a tree holding a duplicated value
# set, names every site, and passes again once the duplicate is removed.
# It drives the committed CLI bundle from inside a temporary git work tree.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  GAIA_CLI="$REPO_ROOT/.gaia/cli/gaia"
  TREE="$BATS_TEST_TMPDIR/tree"
  mkdir -p "$TREE/apps/web/app" "$TREE/scripts" "$TREE/node_modules"
  ln -s "$REPO_ROOT/.gaia/cli/node_modules/typescript" "$TREE/node_modules/typescript"
  cat >"$TREE/apps/web/app/status.ts" <<'TS'
export type Status = 'draft' | 'published' | 'archived';
TS
  printf '%s\n' '#!/usr/bin/env bash' 'echo sync' >"$TREE/scripts/sync.sh"
  git -C "$TREE" init -q
  git -C "$TREE" add -A
}

@test "the check fails on a duplicated value set naming both sites, then passes once it is removed" {
  cat >>"$TREE/scripts/sync.sh" <<'SH'
STATUSES=(draft published archived)
SH
  git -C "$TREE" add -A

  run bash -c 'cd "$1" && "$2" value-sets' _ "$TREE" "$GAIA_CLI"
  [ "$status" -eq 1 ]
  grep -qF -- "apps/web/app/status.ts" <<<"$output"
  grep -qF -- "scripts/sync.sh" <<<"$output"

  printf '%s\n' '#!/usr/bin/env bash' 'echo sync' >"$TREE/scripts/sync.sh"
  git -C "$TREE" add -A

  run bash -c 'cd "$1" && "$2" value-sets' _ "$TREE" "$GAIA_CLI"
  [ "$status" -eq 0 ]
}
