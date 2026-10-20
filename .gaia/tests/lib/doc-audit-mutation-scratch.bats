#!/usr/bin/env bats
# doc-grep coverage for how a Code Audit Team member names, and removes, its
# scratch directory under `.gaia/local/cache/mutation-scratch/`.
#
# The defect this pins: every member was told to name that directory with its
# member name and nothing else. A linked worktree's `.gaia/local` is one
# symlink into the main checkout, so every audit on the machine shares one
# `mutation-scratch/` tree, and two audits running the same member from two
# worktrees at once land in the same directory. Each one's staged
# `findings.json` can then be read by the other's sidecar writer, and either
# one's cleanup removes the other's working copy mid-run. Both are silent: a
# sidecar carrying the wrong array still reads as a real pass, and a mutation
# whose check goes red because its files vanished reads as a guard proven
# non-hollow. Observed live when code-audit-frontend's scratch directory
# disappeared mid-run during a round in which other audits were running.
#
# The fix is a name no other invocation can share: the protocol mints it with
# `mktemp -d` under a member-name prefix, the member carries the printed path
# as `<scratch>`, and removes exactly that path. Nothing type-checks agent
# prose, so this suite is the mechanism: it greps the frozen literals, and its
# last test runs those same literals, which the earlier tests pin as whole
# lines of the protocol, against two mints for one member name.
#
# Assertion style: .claude/rules/bats-assertions.md.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  PROTOCOL="$ROOT/.claude/hooks/lib/audit-member-protocol.md"
  MKDIR_LINE='mkdir -p <root>/.gaia/local/cache/mutation-scratch'
  MINT_LINE='mktemp -d <root>/.gaia/local/cache/mutation-scratch/<member>.XXXXXX'
  REMOVE_LINE='rm -rf <scratch>'

  MEMBERS=()
  # gaia-lint-ignore whole-tree-mark-guard: every test that uses the member roster this collects carries the
  # per-test mark
  for audited_file in "$ROOT"/.claude/agents/code-audit-*.md; do
    [ -s "$audited_file" ] || continue
    grep -qF -- 'mutation-scratch' "$audited_file" && MEMBERS+=("$audited_file")
  done
}

# bats test_tags=whole-tree
@test "the protocol and every member that names mutation-scratch are read" {
  [ -s "$PROTOCOL" ] || { echo "the member protocol is missing or empty" >&2; return 1; }
  for member in \
    code-audit-frontend \
    code-audit-github-workflows \
    code-audit-maintainer-node \
    code-audit-maintainer-shell; do
    grep -qF -- 'mutation-scratch' "$ROOT/.claude/agents/${member}.md" || {
      echo "${member}.md no longer names its scratch directory; every check below would skip it" >&2
      return 1
    }
  done
  [ "${#MEMBERS[@]}" -ge 4 ]
}

@test "the protocol mints the scratch directory with mktemp under a member-name prefix" {
  grep -qxF -- "$MKDIR_LINE" "$PROTOCOL" || { echo "protocol lacks: $MKDIR_LINE" >&2; return 1; }
  grep -qxF -- "$MINT_LINE" "$PROTOCOL" || { echo "protocol lacks: $MINT_LINE" >&2; return 1; }
}

@test "the protocol removes exactly the minted path" {
  grep -qxF -- "$REMOVE_LINE" "$PROTOCOL" || { echo "protocol lacks: $REMOVE_LINE" >&2; return 1; }
}

# bats test_tags=whole-tree
@test "every member points at the protocol's scratch section rather than restating a name" {
  for audited_file in "${MEMBERS[@]}"; do
    grep -qF -- '"Scratch directory"' "$audited_file" || {
      echo "$audited_file names mutation-scratch without pointing at the protocol's \"Scratch directory\" section" >&2
      return 1
    }
  done
}

# bats test_tags=whole-tree
@test "no spec still prescribes a scratch name built from the member name alone" {
  for audited_file in "$PROTOCOL" "${MEMBERS[@]}"; do
    grep -nE -- 'named with (your|its) (own )?member name|with your own member name' "$audited_file" && {
      echo "$audited_file still prescribes the member-name-only scratch directory" >&2
      return 1
    }
  done
  true
}

# bats test_tags=whole-tree
@test "two concurrent mints for one member get separate directories, and one removal spares the other" {
  scratch_root="$BATS_TEST_TMPDIR/root"
  mkdir -p "$scratch_root"
  member="code-audit-maintainer-shell"
  mkdir_command="${MKDIR_LINE//<root>/$scratch_root}"
  mint_command="${MINT_LINE//<root>/$scratch_root}"
  mint_command="${mint_command//<member>/$member}"

  eval "$mkdir_command"
  first_scratch="$(eval "$mint_command")"
  second_scratch="$(eval "$mint_command")"
  [ -d "$first_scratch" ]
  [ -d "$second_scratch" ]
  [ "$first_scratch" != "$second_scratch" ] || { echo "both mints returned $first_scratch" >&2; return 1; }
  case "$first_scratch" in
    "$scratch_root/.gaia/local/cache/mutation-scratch/$member."*) ;;
    *) echo "minted path $first_scratch is not under the member-name prefix" >&2; return 1 ;;
  esac

  printf '%s' '[]' > "$first_scratch/findings.json"
  printf '%s' '[{"from":"second"}]' > "$second_scratch/findings.json"
  remove_command="${REMOVE_LINE//<scratch>/$first_scratch}"
  eval "$remove_command"

  [ ! -e "$first_scratch" ]
  [ -d "$scratch_root/.gaia/local/cache/mutation-scratch" ]
  [ "$(cat "$second_scratch/findings.json")" = '[{"from":"second"}]' ]
}
