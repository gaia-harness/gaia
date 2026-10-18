#!/usr/bin/env bats
# Team settings written by `.claude/commands/setup-gaia.md`. Every
# team-setting jq read and every commit on the setup surface (the command
# followed by every reference under `.claude/skills/gaia/references/setup/`)
# targets `.gaia/project.json`, and so does the isolation policy read in the
# shared isolation reference.
#
# Each check is a function over a file path, so every test that proves the real
# page passes has a twin that runs the same function over a scratch copy with
# the forbidden content put back and asserts it fails.
#
# Tokens the removed-automation guard forbids anywhere in the tree are built
# at runtime (printf or concatenation) so this file never carries one.
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

# scratch_copy <source> <name>: copy a file into the test's temp dir and print
# the copy's path, so a mutation never touches the shared tree.
scratch_copy() {
  local copy="${BATS_TEST_TMPDIR}/$2"
  cp "$1" "$copy"
  printf '%s\n' "$copy"
}

# scratch_references <name>: copy the setup references directory into the
# test's temp dir and print the copy's path.
scratch_references() {
  local copy="${BATS_TEST_TMPDIR}/$1"
  mkdir -p "$copy"
  cp "${REFERENCES_DIRECTORY}"/*.md "$copy"/
  printf '%s\n' "$copy"
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

@test "the project.json check fails on a read of another config file" {
  local copy surface
  copy="$(scratch_copy "$PAGE" "project-json-read.md")"
  sed "s#sandbox_recommended // false' \.gaia/project\.json#sandbox_recommended // false' .gaia/other.json#" \
    "$PAGE" >"$copy"
  grep -qF '.gaia/other.json' "$copy"
  surface="$(build_surface "$copy" "$REFERENCES_DIRECTORY" surface-project-json-read.md)"
  run check_project_json "$surface"
  [ "$status" -ne 0 ]
}

@test "the project.json check fails when a commit stages another file" {
  local copy surface
  copy="$(scratch_copy "$PAGE" "project-json-commit.md")"
  awk '/^git add \.gaia\/project\.json/ && !done { sub(/project\.json/, "other.json"); done = 1 } { print }' \
    "$PAGE" >"$copy"
  cmp -s "$PAGE" "$copy" && return 1
  surface="$(build_surface "$copy" "$REFERENCES_DIRECTORY" surface-project-json-commit.md)"
  run check_project_json "$surface"
  [ "$status" -ne 0 ]
}

@test "the project.json check fails when the sandbox reference reads another file" {
  local directory surface
  directory="$(scratch_references project-json-sandbox)"
  sed "s#sandbox_recommended // false' \.gaia/project\.json#sandbox_recommended // false' .gaia/other.json#" \
    "${REFERENCES_DIRECTORY}/sandbox.md" >"${directory}/sandbox.md"
  cmp -s "${REFERENCES_DIRECTORY}/sandbox.md" "${directory}/sandbox.md" && return 1
  surface="$(build_surface "$PAGE" "$directory" surface-project-json-sandbox.md)"
  run check_project_json "$surface"
  [ "$status" -ne 0 ]
}

@test "the project.json check fails when an extra team-setting commit is added" {
  local copy surface
  copy="$(scratch_copy "$PAGE" "second-commit.md")"
  printf '\n```bash\ngit add .gaia/project.json\n```\n' >>"$copy"
  surface="$(build_surface "$copy" "$REFERENCES_DIRECTORY" surface-second-commit.md)"
  run check_project_json "$surface"
  [ "$status" -ne 0 ]
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

@test "the isolation check fails with the fallback back on prefer-worktree" {
  local copy
  copy="$(scratch_copy "$ISOLATION_REFERENCE" "isolation-prefer.md")"
  sed -e 's/"always-worktree"'"'"' \.gaia/"prefer-worktree"'"'"' .gaia/' \
    -e 's/|| echo always-worktree)/|| echo prefer-worktree)/' \
    "$ISOLATION_REFERENCE" >"$copy"
  cmp -s "$ISOLATION_REFERENCE" "$copy" && return 1
  run check_isolation_reference "$copy"
  [ "$status" -ne 0 ]
}

@test "the isolation check fails when the unrecognized-value arm falls back to prefer-worktree" {
  local copy
  copy="$(scratch_copy "$ISOLATION_REFERENCE" "isolation-arm.md")"
  sed 's/^    POLICY=always-worktree$/    POLICY=prefer-worktree/' "$ISOLATION_REFERENCE" >"$copy"
  cmp -s "$ISOLATION_REFERENCE" "$copy" && return 1
  run check_isolation_reference "$copy"
  [ "$status" -ne 0 ]
}

@test "the isolation check fails on the old config path put back" {
  local copy
  copy="$(scratch_copy "$ISOLATION_REFERENCE" "isolation-old.md")"
  sed "s#\.gaia/project\.json#.gaia/$(printf 'automation%sjson' .)#" "$ISOLATION_REFERENCE" >"$copy"
  run check_isolation_reference "$copy"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# The isolation question recommends always using worktrees
# ---------------------------------------------------------------------------

# check_isolation_question <file>: the question's options, in order, lead with
# always-worktree as the one recommended option, and each answer-mapping label
# matches its option's label.
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
  answers="$(grep -E '^- `[^`]+` is `[a-z-]+`\.$' "$file")"
  [ "$answers" = "$(printf '%s\n' \
    '- `Always use worktrees (Recommended)` is `always-worktree`.' \
    '- `Prefer worktrees` is `prefer-worktree`.' \
    '- `Prefer branches` is `prefer-branch`.')" ] || {
    printf 'the isolation answer mapping does not match the options:\n%s\n' "$answers" >&2
    return 1
  }
}

@test "the isolation question leads with always using worktrees, recommended" {
  check_isolation_question "${REFERENCES_DIRECTORY}/isolation-question.md"
}

@test "the isolation question check fails with the recommendation back on prefer-worktree" {
  local copy
  copy="$(scratch_copy "${REFERENCES_DIRECTORY}/isolation-question.md" "isolation-question-old.md")"
  sed -e 's/^- \*\*Always use worktrees (Recommended)\*\*:/- **Always use worktrees**:/' \
    -e 's/^- \*\*Prefer worktrees\*\*:/- **Prefer worktrees (Recommended)**:/' \
    "${REFERENCES_DIRECTORY}/isolation-question.md" >"$copy"
  cmp -s "${REFERENCES_DIRECTORY}/isolation-question.md" "$copy" && return 1
  run check_isolation_question "$copy"
  [ "$status" -ne 0 ]
}

@test "the isolation question check fails when an answer label drifts from its option" {
  local copy
  copy="$(scratch_copy "${REFERENCES_DIRECTORY}/isolation-question.md" "isolation-question-drift.md")"
  sed 's/^- `Always use worktrees (Recommended)` is/- `Always use worktrees` is/' \
    "${REFERENCES_DIRECTORY}/isolation-question.md" >"$copy"
  cmp -s "${REFERENCES_DIRECTORY}/isolation-question.md" "$copy" && return 1
  run check_isolation_question "$copy"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# --reconfigure re-opens the sandbox recommendation
# ---------------------------------------------------------------------------

# check_reconfigure_lists <file>: the frontmatter description and the
# argument-parse list of what --reconfigure re-opens both name the sandbox
# recommendation, and no line says --reconfigure leaves it closed.
check_reconfigure_lists() {
  local file="$1" line
  for line in "$(grep -E '^description: ' "$file")" "$(grep -E '^Parse `\$ARGUMENTS` for the `--reconfigure` flag' "$file")"; do
    [ -n "$line" ] || {
      echo "a --reconfigure list is absent" >&2
      return 1
    }
    grep -qE 'sandbox[- ]recommendation' <<<"$line" || {
      printf 'a --reconfigure list omits the sandbox recommendation: %s\n' "$line" >&2
      return 1
    }
  done
  if grep -n 'does not re-open' "$file"; then
    echo "the page still says --reconfigure does not re-open a decision" >&2
    return 1
  fi
}

@test "every --reconfigure list on the setup page names the sandbox recommendation" {
  check_reconfigure_lists "$PAGE"
}

@test "the reconfigure check fails with the does-not-re-open sentence put back" {
  local copy
  copy="$(scratch_copy "$PAGE" "reconfigure-closed.md")"
  printf '\nRun only when `MAY_RECORD_PROJECT` is `admin`. `--reconfigure` does not re-open it.\n' >>"$copy"
  run check_reconfigure_lists "$copy"
  [ "$status" -ne 0 ]
}

@test "the reconfigure check fails when the description drops the sandbox recommendation" {
  local copy
  copy="$(scratch_copy "$PAGE" "reconfigure-description.md")"
  sed -E '/^description: /s/ sandbox-recommendation,//' "$PAGE" >"$copy"
  cmp -s "$PAGE" "$copy" && return 1
  run check_reconfigure_lists "$copy"
  [ "$status" -ne 0 ]
}
