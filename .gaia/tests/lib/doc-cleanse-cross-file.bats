#!/usr/bin/env bats
# Doc-conformance for the cross-file mode of /gaia-cleanse. The arm that lets
# the cleanse edit a GAIA-shipped file exists only in the GAIA source repo:
# every `owner: maintainer` in research.md and apply.md sits inside a
# maintainer-only block, which the release scrub strips, so no adopter bundle
# carries it.
#
# Assertion style: .claude/rules/bats-assertions.md.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  CLEANSE="$ROOT/.claude/skills/gaia/references/cleanse"
  RESEARCH="$CLEANSE/research.md"
  APPLY="$CLEANSE/apply.md"
}

# check_maintainer_owner_inside_blocks <file>...: every line carrying
# `owner: maintainer` sits between a maintainer-only start and end marker, and
# each file carries at least one, so a file that lost the arm cannot pass.
# Prints each offending file:line on stderr.
check_maintainer_owner_inside_blocks() {
  awk '
    FNR == 1 { inside = 0; files[FILENAME] = 0 }
    /gaia:maintainer-only:start/ { inside = 1; next }
    /gaia:maintainer-only:end/ { inside = 0; next }
    index($0, "owner: maintainer") {
      files[FILENAME]++
      if (!inside) { print FILENAME ":" FNR " sits outside a maintainer-only block" > "/dev/stderr"; outside++ }
    }
    END {
      for (file in files) {
        if (files[file] == 0) { print file " carries no owner: maintainer" > "/dev/stderr"; outside++ }
      }
      exit (outside > 0) ? 1 : 0
    }' "$@"
}

@test "the GAIA-shipped edit arm sits only inside maintainer-only blocks" {
  check_maintainer_owner_inside_blocks "$RESEARCH" "$APPLY"
}
