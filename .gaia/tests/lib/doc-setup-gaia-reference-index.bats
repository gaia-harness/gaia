#!/usr/bin/env bats
# The setup reference index: the `*.md` files under
# `.claude/skills/gaia/references/setup/`, the bullets of the references block
# in `.claude/commands/setup-gaia.md`, and the expected list below name the
# same files, the directory has no subdirectory, the command carries a
# "Read ... now" line for each, and every references/setup path it names
# exists.
#
# Assertion style: .claude/rules/bats-assertions.md.

# Each reference basename is named literally in this list: the change selector
# picks a suite only when it contains a changed file's basename. The
# reference-index check keeps the list and the directory in step.
EXPECTED_SETUP_REFERENCES="auto-merge.md per-machine.md sandbox.md github-repo.md isolation-question.md squash-only.md statusline-left.md setup-decisions.md standalone-features.md migrate-2-machine.md required-ci-checks.md land-decisions.md sandbox-recommendation.md"

# The exact opening sentence of a command's references block.
REFERENCES_OPENING='This command reads these references, all under `.claude/skills/gaia/references/setup/`. Read one only when a "Read ... now" line sends you there, and then read the whole file:'

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  PAGE="${REPO_ROOT}/.claude/commands/setup-gaia.md"
  REFERENCES_DIRECTORY="${REPO_ROOT}/.claude/skills/gaia/references/setup"
  [ -f "$PAGE" ] || {
    echo "the audited page is absent: ${PAGE}" >&2
    return 1
  }
  [ -d "$REFERENCES_DIRECTORY" ] || {
    echo "the setup references directory is absent: ${REFERENCES_DIRECTORY}" >&2
    return 1
  }
}

# ---------------------------------------------------------------------------
# The reference index: directory, references block and Read lines agree
# ---------------------------------------------------------------------------

SETUP_REFERENCES_PATH='.claude/skills/gaia/references/setup/'

# references_block_names <entry>: print the basenames of the bullets directly
# below the references block's exact opening sentence, one per line. Fails
# loudly when the opening sentence is absent, because the block cannot then be
# located.
references_block_names() {
  local entry="$1" names
  names="$(OPENING="$REFERENCES_OPENING" awk '
    $0 == ENVIRON["OPENING"] { found = 1; next }
    found && /^- `[^`]+\.md`: / {
      name = $0
      sub(/^- `/, "", name)
      sub(/`:.*$/, "", name)
      print name
      next
    }
    found { exit }
    END { if (!found) exit 2 }
  ' "$entry")" || {
    echo "the references block opening sentence is absent from ${entry}" >&2
    return 1
  }
  printf '%s\n' "$names"
}

# check_reference_index <entry> <directory>: the *.md files of the directory,
# the bullets of the entry's references block, and the expected list name the
# same files; the entry carries a "Read ... now" line for each, and every
# references/setup path it names exists.
check_reference_index() {
  local entry="$1" directory="$2" expected listed block name named file nested
  expected="$(tr ' ' '\n' <<<"$EXPECTED_SETUP_REFERENCES" | sort)"
  [ -n "$expected" ] || {
    echo "the expected reference list is empty" >&2
    return 1
  }
  listed="$(find "$directory" -maxdepth 1 -type f -name '*.md' -exec basename {} \; | sort)"
  [ "$listed" = "$expected" ] || {
    echo "the references directory differs from the expected list:" >&2
    diff <(printf '%s\n' "$expected") <(printf '%s\n' "$listed") >&2 || true
    return 1
  }
  nested="$(find "$directory" -mindepth 1 -type d)"
  [ -z "$nested" ] || {
    echo "the references directory has a subdirectory: ${nested}" >&2
    return 1
  }
  block="$(references_block_names "$entry")" || return 1
  block="$(sort <<<"$block")"
  [ "$block" = "$expected" ] || {
    echo "the references block differs from the expected list:" >&2
    diff <(printf '%s\n' "$expected") <(printf '%s\n' "$block") >&2 || true
    return 1
  }
  for name in $EXPECTED_SETUP_REFERENCES; do
    grep -qF -- "Read \`${SETUP_REFERENCES_PATH}${name}\` now" "$entry" || {
      echo "the entry has no Read line for ${name}" >&2
      return 1
    }
  done
  named="$(grep -oE 'references/setup/[A-Za-z0-9._-]+\.md' "$entry" | sort -u)"
  [ -n "$named" ] || {
    echo "the entry names no references/setup path" >&2
    return 1
  }
  while IFS= read -r file; do
    [ -f "${directory}/${file#references/setup/}" ] || {
      echo "the entry names a missing reference: ${file}" >&2
      return 1
    }
  done <<<"$named"
}

@test "the setup reference directory, references block, and Read lines name the same files" {
  check_reference_index "$PAGE" "$REFERENCES_DIRECTORY"
}
