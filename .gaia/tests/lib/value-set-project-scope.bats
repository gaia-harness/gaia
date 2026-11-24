#!/usr/bin/env bats
#
# Flow test: on an adopter the value-set check reads the whole project and
# reports nothing whose every site is a GAIA harness file, while a set
# repeated across the project's own app files is reported.
# It drives the committed CLI bundle from inside a temporary git work tree.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

# bats file_tags=installed-dependencies

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  . "$BATS_TEST_DIRNAME/../hooks/helpers/require-node-typescript.sh"
  require_node_typescript "$REPO_ROOT/.gaia/cli"
  GAIA_CLI="$REPO_ROOT/.gaia/cli/gaia"
  TREE="$BATS_TEST_TMPDIR/tree"
  mkdir -p "$TREE/.gaia" "$TREE/.claude/hooks" "$TREE/apps/web/app" "$TREE/node_modules"
  ln -s "$REPO_ROOT/.gaia/cli/node_modules/typescript" "$TREE/node_modules/typescript"
  cat >"$TREE/.gaia/manifest.json" <<'JSON'
{"files": {
  ".claude/hooks/first.sh": {},
  ".claude/hooks/second.sh": {},
  "apps/web/app/first.ts": {},
  "apps/web/app/second.ts": {}
}}
JSON
  cat >"$TREE/.claude/hooks/first.sh" <<'SH'
#!/usr/bin/env bash
case "$1" in
  red|green|blue) echo colour ;;
esac
SH
  cat >"$TREE/.claude/hooks/second.sh" <<'SH'
#!/usr/bin/env bash
case "$2" in
  red|green|blue) echo shade ;;
esac
SH
  printf '%s\n' 'export const first = 1;' >"$TREE/apps/web/app/first.ts"
  printf '%s\n' 'export const second = 2;' >"$TREE/apps/web/app/second.ts"
  git -C "$TREE" init -q
  git -C "$TREE" add -A
}

@test "the check reports a set repeated across the project's app files and never a set only harness files share" {
  run bash -c 'cd "$1" && "$2" value-sets' _ "$TREE" "$GAIA_CLI"
  [ "$status" -eq 0 ]

  cat >>"$TREE/apps/web/app/first.ts" <<'TS'
export const firstTones = ['low', 'mid', 'high'];
TS
  cat >>"$TREE/apps/web/app/second.ts" <<'TS'
export const secondTones = ['low', 'mid', 'high'];
TS
  git -C "$TREE" add -A

  run bash -c 'cd "$1" && "$2" value-sets' _ "$TREE" "$GAIA_CLI"
  [ "$status" -eq 1 ]
  grep -qF -- "apps/web/app/first.ts" <<<"$output"
  grep -qF -- "apps/web/app/second.ts" <<<"$output"
  grep -qF -- ".claude/hooks/first.sh" <<<"$output" && return 1
  grep -qF -- ".claude/hooks/second.sh" <<<"$output" && return 1
  true
}
