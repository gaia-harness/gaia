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

@test "the rule states the standard and the threshold" {
  run grep -F 'apps go in `apps/<name>`, libraries in `packages/<name>` once two consumers share them, never a new top-level folder' "$RULE"
  [ "$status" -eq 0 ]
  run grep -F '`infra`' "$RULE"
  [ "$status" -eq 0 ]
}

@test "the adding section walks both examples and names the three things" {
  section="$(section_of "$DESCRIPTOR_PAGE" '## Adding an app or package')"
  [ -n "$section" ]
  for needle in 'Workspace entry' 'Registry entry' 'Descriptor' 'packages/i18n' 'packages/design-tokens'; do
    printf '%s\n' "$section" | grep -qF "$needle"
  done
  printf '%s\n' "$section" | grep -qF 'cannot reach React Native'
  printf '%s\n' "$section" | grep -qF 'Root `CLAUDE.md`'
  printf '%s\n' "$section" | grep -qF '.gitignore'
}

@test "the page names the layout as GAIA's convention beside both links" {
  run grep -F "GAIA's convention" "$DESCRIPTOR_PAGE"
  [ "$status" -eq 0 ]
  run grep -E '\[[^]]+\]\(https://pnpm\.io/workspaces\)' "$DESCRIPTOR_PAGE"
  [ "$status" -eq 0 ]
  run grep -E '\[[^]]+\]\(https://nx\.dev/docs/kb/pnpm-workspaces\)' "$DESCRIPTOR_PAGE"
  [ "$status" -eq 0 ]
}

@test "section 6 points at the procedure and holds no numbered steps" {
  section="$(section_of "$CONVENTIONS_PAGE" '## 6. Monorepo retrofit playbook')"
  [ -n "$section" ]
  printf '%s\n' "$section" | grep -qF '[[Package Descriptor#Adding an app or package]]'
  ! printf '%s\n' "$section" | grep -qE '^[0-9]+\. '
}

@test "Customizing GAIA names generatedSettings and links the section" {
  run grep -F 'generatedSettings' "$CUSTOMIZING_PAGE"
  [ "$status" -eq 0 ]
  run grep -F '[[Package Descriptor#Adding an app or package]]' "$CUSTOMIZING_PAGE"
  [ "$status" -eq 0 ]
}

@test "the wiki index entry mentions the procedure" {
  run grep -F '[[Package Descriptor]]' "$REPO_ROOT/wiki/index.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"adding an app or package"* ]]
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

@test "the path check fails on a scratch copy holding a dead path" {
  cp "$DESCRIPTOR_PAGE" "$BATS_TEST_TMPDIR/page.md"
  printf '\nSee `.gaia/scripts/no-such-script.sh`.\n' >> "$BATS_TEST_TMPDIR/page.md"
  run dead_paths "$BATS_TEST_TMPDIR/page.md"
  [ "$output" = ".gaia/scripts/no-such-script.sh" ]
}
