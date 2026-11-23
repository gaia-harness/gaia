#!/usr/bin/env bats
#
# A marked sanctioned copy or subset passes `gaia value-sets` while it matches
# its source and fails once it drifts. The work tree is built at run time inside
# $BATS_TEST_TMPDIR, so no literal value set lives in this file.

# bats file_tags=installed-dependencies

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  . "$BATS_TEST_DIRNAME/../hooks/helpers/require-node-typescript.sh"
  require_node_typescript "$REPO_ROOT"
  TREE="$BATS_TEST_TMPDIR/tree"
  mkdir -p "$TREE/.gaia/cli" "$TREE/src"
  cp "$REPO_ROOT/.gaia/cli/gaia" "$TREE/.gaia/cli/gaia"
  chmod +x "$TREE/.gaia/cli/gaia"
  # The check parses TypeScript with the project's own compiler, so the tree
  # carries a copy of just the two files that module loads.
  mkdir -p "$TREE/node_modules/typescript/lib"
  cp "$REPO_ROOT/node_modules/typescript/package.json" "$TREE/node_modules/typescript/package.json"
  cp "$REPO_ROOT/node_modules/typescript/lib/typescript.js" "$TREE/node_modules/typescript/lib/typescript.js"
  git -C "$TREE" init -q
}

write_source() {
  cat > "$TREE/src/keys.ts" <<'SRC'
export const KEYS = ['alpha', 'bravo', 'charlie'] as const;

export const WIDE = ['north', 'south', 'east', 'west'] as const;
SRC
}

write_copy() {
  cat > "$TREE/src/copy.sh" <<'SRC'
#!/usr/bin/env bash
# sanctioned copy of src/keys.ts#KEYS
KEYS_COPY=(alpha bravo charlie)
SRC
}

write_subset() {
  cat > "$TREE/src/narrow.ts" <<'SRC'
// subset of src/keys.ts#WIDE
export const NARROW = ['north', 'south', 'east'] as const;
SRC
}

# Stages the tree and runs the committed CLI bundle inside it.
run_check() {
  git -C "$TREE" add -A
  cd "$TREE" || return 1
  run ./.gaia/cli/gaia value-sets
}

@test "a marked copy and a marked subset pass while they match their sources and the copy fails once its source gains a value" {
  write_source
  write_copy
  write_subset

  run_check
  [ "$status" -eq 0 ] || { echo "matching marked sets: status $status: $output"; return 1; }

  printf '%s\n' "export const KEYS = ['alpha', 'bravo', 'charlie', 'delta'] as const;" > "$TREE/src/keys.ts"
  printf '%s\n' "export const WIDE = ['north', 'south', 'east', 'west'] as const;" >> "$TREE/src/keys.ts"
  run_check
  [ "$status" -eq 1 ] || { echo "drifted copy: status $status: $output"; return 1; }
  grep -qF "src/copy.sh" <<<"$output" || { echo "drifted copy: path not named: $output"; return 1; }
}
