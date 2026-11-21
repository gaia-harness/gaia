#!/usr/bin/env bats
#
# Doc-conformance suite for the post-merge cleanup, owned by the shared
# work-lifecycle reference: it pulls the default branch into the main checkout
# only when that checkout is on it.
#
# Assertion style: .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  REFERENCES='.claude/skills/gaia/references'
  PULL_PATTERN='pull --ff-only origin "\$default_branch"'
}

# section <file> <heading prefix>: prints the section whose heading line starts
# with the prefix, up to the next heading of the same or a higher level. Lines
# inside a fence are never read as headings, since a `# comment` in a bash
# fence would otherwise end the section early.
section() {
  awk -v want="$2" '
    /^[[:space:]]*```/ { fenced = !fenced }
    !found && !fenced && index($0, want) == 1 {
      found = 1; match($0, /^#+/); level = RLENGTH; print; next
    }
    found && !fenced && /^#+ / { match($0, /^#+/); if (RLENGTH <= level) exit }
    found { print }
  ' "$1"
}

# fence_bodies <info string>: reads text on stdin and prints the lines inside
# every fence opened with exactly that info string, at any indentation.
fence_bodies() {
  awk -v info="$1" '
    !open && $0 ~ ("^[[:space:]]*```" info "$") { open = 1; next }
    open && /^[[:space:]]*```[[:space:]]*$/ { open = 0; next }
    open { print }
  '
}

# --- b. the pull after a merge -------------------------------------------------

worktree_arm_pulls() {
  local path_arm prose
  path_arm="$(section "$1/$REFERENCES/work-lifecycle.md" '### Worktree entered by path or in an earlier session')"
  fence_bodies bash <<<"$path_arm" | grep -qE -- "git( -C ([^ <][^ ]*|<[^>]*>))? $PULL_PATTERN" || return 1
  fence_bodies bash <<<"$path_arm" | grep -qF -- '= "$default_branch" ]' || return 1
  prose="$(section "$1/$REFERENCES/work-lifecycle.md" '## 8. Cleanup')"
  grep -qF -- 'skip the checkout and the pull' <<<"$prose" || return 1
  grep -qF -- 'Never force a pull, and never stash' <<<"$prose"
}

# bats test_tags=whole-tree
@test "the worktree arm pulls the default branch only when the main checkout holds it, and never forces" {
  worktree_arm_pulls "$REPO_ROOT"
}

