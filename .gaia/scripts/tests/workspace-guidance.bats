#!/usr/bin/env bats
#
# The workspace layout guidance: the coding-guidelines rule, one procedure on the
# Package Descriptor page, and pointers from the pages that used to carry their
# own copy. Every path and script named in them must resolve on the branch.

setup() {
  THIS_DIRECTORY="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  REPO_ROOT="$(git -C "$THIS_DIRECTORY" rev-parse --show-toplevel)"
  RULE="$REPO_ROOT/.claude/rules/coding-guidelines.md"
  DESCRIPTOR_PAGE="$REPO_ROOT/wiki/concepts/Package Descriptor.md"
  CONVENTIONS_PAGE="$REPO_ROOT/wiki/concepts/Claude Integration Conventions.md"
  CUSTOMIZING_PAGE="$REPO_ROOT/wiki/concepts/Customizing GAIA.md"
}

# section_of <file> <heading line>
#
# Prints the body of a section: from its heading to the next heading of the same
# or a shallower level.
section_of() {
  awk -v want="$2" '
    function level(line) { match(line, /^#+/); return RLENGTH }
    $0 == want { inside = 1; depth = level($0); print; next }
    inside && /^#+ / && level($0) <= depth { exit }
    inside { print }
  ' "$1"
}

# dead_paths <file>
#
# Prints every backticked repo path in the file that does not exist. A token
# counts when it starts with `.claude/`, `.gaia/`, `wiki/` or `apps/web/`, or is
# `pnpm-workspace.yaml`; placeholders (<, {, *, $), the example members the page invents, and the built
# CLI bundle are skipped.
dead_paths() {
  local token path
  grep -o '`[^`]*`' "$1" | tr -d '`' | sort -u | while IFS= read -r token; do
    path="$token"
    case "$token" in
      'bash '* | ./*) path="${token#bash }"; path="${path#./}"; path="${path%% *}" ;;
    esac
    case "$path" in
      *'<'* | *'{'* | *'*'* | *'$'*) continue ;;
      packages/i18n* | packages/design-tokens* | apps/admin*) continue ;;
      .gaia/cli/gaia*) continue ;;
      .claude/* | .gaia/* | wiki/* | apps/web/* | pnpm-workspace.yaml) ;;
      *) continue ;;
    esac
    [ -e "$REPO_ROOT/$path" ] || printf '%s\n' "$path"
  done
}

@test "every path in the guidance resolves on the branch" {
  section_of "$DESCRIPTOR_PAGE" '## Adding an app or package' > "$BATS_TEST_TMPDIR/adding.md"
  section_of "$CONVENTIONS_PAGE" '## 6. Monorepo retrofit playbook' > "$BATS_TEST_TMPDIR/section-six.md"
  section_of "$CUSTOMIZING_PAGE" '## Structure tolerance' > "$BATS_TEST_TMPDIR/tolerance.md"
  for file in "$RULE" "$DESCRIPTOR_PAGE" "$BATS_TEST_TMPDIR/section-six.md" "$BATS_TEST_TMPDIR/tolerance.md"; do
    [ -s "$file" ]
    run dead_paths "$file"
    [ "$status" -eq 0 ]
    [ -z "$output" ] || { printf 'dead path in %s: %s\n' "$file" "$output" >&2; return 1; }
  done
}
