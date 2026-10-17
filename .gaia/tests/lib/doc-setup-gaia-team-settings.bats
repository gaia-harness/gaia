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
# .gaia/project.json, the expected keys are read from it, and exactly two
# commits stage it: the isolation-policy commit and the land step that commits
# recorded setup decisions. A read of .gaia/local/settings.json is not a
# team setting: it is the per-machine opt-ins file (the statusline left-side
# choice), so it is left out of the read set.
check_project_json() {
  local file="$1" reads stray key staged
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
  for key in sandbox_recommended isolation_policy; do
    grep -qF -- "$key" <<<"$reads" || {
      echo "no .gaia/project.json read for ${key}" >&2
      return 1
    }
  done
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
  sed "s#has(\"isolation_policy\")' \.gaia/project\.json#has(\"isolation_policy\")' .gaia/other.json#" \
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
# .gaia/project.json with its load-bearing fallback tail, and the file names
# no automation config anywhere.
check_isolation_reference() {
  local file="$1"
  grep -qF -- "jq -r '.isolation_policy // \"prefer-worktree\"' .gaia/project.json 2>/dev/null || echo prefer-worktree" "$file" || {
    echo "the policy read does not target .gaia/project.json with its fallback tail" >&2
    return 1
  }
  if grep -n 'automation' "$file"; then
    echo "the isolation reference still mentions automation" >&2
    return 1
  fi
}

@test "the isolation reference reads its policy from .gaia/project.json" {
  check_isolation_reference "$ISOLATION_REFERENCE"
}

@test "the isolation check fails on the old config path put back" {
  local copy
  copy="$(scratch_copy "$ISOLATION_REFERENCE" "isolation-old.md")"
  sed "s#\.gaia/project\.json#.gaia/$(printf 'automation%sjson' .)#" "$ISOLATION_REFERENCE" >"$copy"
  run check_isolation_reference "$copy"
  [ "$status" -ne 0 ]
}
