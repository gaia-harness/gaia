#!/usr/bin/env bats
# Team settings written by `.claude/commands/setup-gaia.md`. Every
# team-setting jq read and every commit on the setup surface (the command
# followed by every reference under `.claude/skills/gaia/references/setup/`)
# targets `.gaia/project.json`, and so does the isolation policy read in the
# shared isolation reference. The isolation question leads with always using
# worktrees, and the team questions are asked in the user's language with
# answers keyed on option position.
#
# Assertion style: .claude/rules/bats-assertions.md.

# Each reference basename is named literally in this list: the change selector
# picks a suite only when it contains a changed file's basename, and this suite
# reads every reference through surface_files.
EXPECTED_SETUP_REFERENCES="per-machine.md sandbox.md github-repo.md isolation-question.md squash-only.md statusline-left.md setup-decisions.md standalone-features.md land-decisions.md sandbox-recommendation.md"

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  PAGE="${REPO_ROOT}/.claude/commands/setup-gaia.md"
  ISOLATION_REFERENCE="${REPO_ROOT}/.claude/skills/gaia/references/isolation.md"
  REFERENCES_DIRECTORY="${REPO_ROOT}/.claude/skills/gaia/references/setup"
  [ -f "$PAGE" ] || {
    echo "the audited page is absent: ${PAGE}" >&2
    return 1
  }
  [ -f "$ISOLATION_REFERENCE" ] || {
    echo "the isolation reference is absent: ${ISOLATION_REFERENCE}" >&2
    return 1
  }
  [ -d "$REFERENCES_DIRECTORY" ] || {
    echo "the setup references directory is absent: ${REFERENCES_DIRECTORY}" >&2
    return 1
  }
}

# surface_files <entry> <directory>: the setup surface, one path per line: the
# entry command, then each expected reference from <directory> in list order.
# Fails loudly on an absent file so the surface can never be a short read.
surface_files() {
  local entry="$1" directory="$2" name
  [ -f "$entry" ] || {
    echo "surface entry is absent: ${entry}" >&2
    return 1
  }
  printf '%s\n' "$entry"
  for name in $EXPECTED_SETUP_REFERENCES; do
    [ -f "${directory}/${name}" ] || {
      echo "surface reference is absent: ${directory}/${name}" >&2
      return 1
    }
    printf '%s\n' "${directory}/${name}"
  done
}

# build_surface <entry> <directory> <name>: concatenate the setup surface into
# one file and print its path.
build_surface() {
  local output="${BATS_TEST_TMPDIR}/$3" file files
  files="$(surface_files "$1" "$2")" || return 1
  : >"$output"
  while IFS= read -r file; do
    cat "$file" >>"$output"
  done <<<"$files"
  printf '%s\n' "$output"
}

# real_surface: the surface of the real command and references.
real_surface() {
  build_surface "$PAGE" "$REFERENCES_DIRECTORY" surface-real.md
}

# ---------------------------------------------------------------------------
# Team settings live in .gaia/project.json
# ---------------------------------------------------------------------------

# check_project_json <file>: every jq read of a .gaia/*.json file targets
# .gaia/project.json, the sandbox recommendation is read from it (the
# isolation policy is read only by the isolation reference, checked below),
# and exactly two
# commits stage it: the isolation-policy commit and the land step that commits
# recorded setup decisions. A read of .gaia/local/settings.json is not a
# team setting: it is the per-machine opt-ins file (the statusline left-side
# choice), so it is left out of the read set.
check_project_json() {
  local file="$1" reads stray staged
  reads="$(grep -E "jq -r '[^']*' \.gaia/[^ ]*\.json" "$file" | grep -vF "' .gaia/local/settings.json" || true)"
  [ -n "$reads" ] || {
    echo "no jq read of a .gaia/*.json file found" >&2
    return 1
  }
  stray="$(grep -vF '.gaia/project.json' <<<"$reads" || true)"
  [ -z "$stray" ] || {
    echo "a key read targets another file: ${stray}" >&2
    return 1
  }
  grep -qF -- sandbox_recommended <<<"$reads" || {
    echo "no .gaia/project.json read for sandbox_recommended" >&2
    return 1
  }
  staged="$(grep -cE '^git add \.gaia/project\.json' "$file" || true)"
  [ "$staged" -eq 2 ] || {
    echo "expected 2 commits staging .gaia/project.json (the isolation policy and the land step), found ${staged}" >&2
    return 1
  }
}

@test "every team-setting read and commit on the setup surface targets .gaia/project.json" {
  check_project_json "$(real_surface)"
}

# check_isolation_reference <file>: the policy read targets
# .gaia/project.json with its load-bearing fallback tail, an unset or
# unrecognized policy falls back to always-worktree, and the file names no
# automation config anywhere.
check_isolation_reference() {
  local file="$1"
  grep -qF -- "jq -r '.isolation_policy // \"always-worktree\"' .gaia/project.json 2>/dev/null || echo always-worktree" "$file" || {
    echo "the policy read does not target .gaia/project.json with its always-worktree fallback tail" >&2
    return 1
  }
  grep -qxF -- '    POLICY=always-worktree' "$file" || {
    echo "the unrecognized-value arm does not fall back to always-worktree" >&2
    return 1
  }
  if grep -n 'POLICY=prefer-worktree' "$file"; then
    echo "a fallback still resolves to prefer-worktree" >&2
    return 1
  fi
  if grep -n 'automation' "$file"; then
    echo "the isolation reference still mentions automation" >&2
    return 1
  fi
}

@test "the isolation reference reads its policy from .gaia/project.json" {
  check_isolation_reference "$ISOLATION_REFERENCE"
}

# ---------------------------------------------------------------------------
# The isolation question recommends always using worktrees
# ---------------------------------------------------------------------------

# check_isolation_question <file>: the question's options, in order, lead with
# always-worktree as the one recommended option, and each answer maps by the
# option's position, naming its option's label. The user sees the labels in
# their own language, so a mapping keyed on the label text alone fails.
check_isolation_question() {
  local file="$1" options answers
  options="$(grep -oE '^- \*\*[^*]+\*\*:' "$file")"
  [ "$options" = "$(printf '%s\n' \
    '- **Always use worktrees (Recommended)**:' \
    '- **Prefer worktrees**:' \
    '- **Prefer branches**:')" ] || {
    printf 'the isolation question options are out of order or mislabelled:\n%s\n' "$options" >&2
    return 1
  }
  answers="$(grep -E '^- (The [a-z]+ option, )?`[^`]+`,? is `[a-z-]+`\.$' "$file")"
  [ "$answers" = "$(printf '%s\n' \
    '- The first option, `Always use worktrees (Recommended)`, is `always-worktree`.' \
    '- The second option, `Prefer worktrees`, is `prefer-worktree`.' \
    '- The third option, `Prefer branches`, is `prefer-branch`.')" ] || {
    printf 'the isolation answer mapping does not match the options:\n%s\n' "$answers" >&2
    return 1
  }
}

@test "the isolation question leads with always using worktrees, recommended" {
  check_isolation_question "${REFERENCES_DIRECTORY}/isolation-question.md"
}

# ---------------------------------------------------------------------------
# The --reconfigure team questions speak the user's language
# ---------------------------------------------------------------------------

# check_question_language <file>: the question is shown in the user's language
# and nothing in the file holds part of it back in English.
check_question_language() {
  local file="$1" pinned
  pinned="$(grep -n -i -E 'stays (in )?english' "$file" || true)"
  [ -z "$pinned" ] || {
    printf '%s keeps part of its question in English:\n%s\n' "$file" "$pinned" >&2
    return 1
  }
  grep -q "in the user's language" "$file" || {
    printf '%s does not say to ask in the user'"'"'s language\n' "$file" >&2
    return 1
  }
}

@test "the isolation and sandbox-recommendation questions are asked in the user's language" {
  check_question_language "${REFERENCES_DIRECTORY}/isolation-question.md"
  check_question_language "${REFERENCES_DIRECTORY}/sandbox-recommendation.md"
}

# check_sandbox_recommendation_answer <file>: each answer maps by the option's
# position, naming its option's label.
check_sandbox_recommendation_answer() {
  local file="$1" answers
  answers="$(grep -E '^- (The [a-z]+ option, )?`[^`]+`,? is `(true|false)`\.$' "$file")"
  [ "$answers" = "$(printf '%s\n' \
    '- The first option, `No, don'"'"'t recommend (Recommended)`, is `false`.' \
    '- The second option, `Yes, recommend the sandbox`, is `true`.')" ] || {
    printf 'the sandbox-recommendation answer is not keyed on option position:\n%s\n' "$answers" >&2
    return 1
  }
}

@test "the sandbox-recommendation answer maps by option position" {
  check_sandbox_recommendation_answer "${REFERENCES_DIRECTORY}/sandbox-recommendation.md"
}
