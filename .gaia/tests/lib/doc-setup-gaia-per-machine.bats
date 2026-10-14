#!/usr/bin/env bats
# Phase 2 per-machine setup, driven by the per-machine reference under
# `.claude/skills/gaia/references/setup/`:
#
#   - The React Doctor probe names the `frontend/` skill location, and neither
#     the setup surface nor `.claude/commands/gaia-init.md` carries the
#     root-level probe.
#
# Every test that proves the real files pass has a twin that runs the same
# check over a scratch copy with the guarded content removed or the old
# content put back and asserts it fails.
#
# Assertion style: .claude/rules/bats-assertions.md.

# Each reference basename is named literally in this list: the change selector
# picks a suite only when it contains a changed file's basename, and this suite
# reads every reference through surface_files.
EXPECTED_SETUP_REFERENCES="per-machine.md sandbox.md github-repo.md isolation-question.md squash-only.md statusline-left.md setup-decisions.md standalone-features.md land-decisions.md sandbox-recommendation.md"

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  PAGE="${REPO_ROOT}/.claude/commands/setup-gaia.md"
  INIT_PAGE="${REPO_ROOT}/.claude/commands/gaia-init.md"
  REFERENCES_DIRECTORY="${REPO_ROOT}/.claude/skills/gaia/references/setup"
  PER_MACHINE_REFERENCE="${REFERENCES_DIRECTORY}/per-machine.md"
  [ -f "$PAGE" ] || {
    echo "the audited page is absent: ${PAGE}" >&2
    return 1
  }
  [ -f "$INIT_PAGE" ] || {
    echo "the init page is absent: ${INIT_PAGE}" >&2
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
# The React Doctor skill lives under frontend/
# ---------------------------------------------------------------------------

REACT_DOCTOR_PROBE='[ -d frontend/.claude/skills/react-doctor ]'
OLD_REACT_DOCTOR_PROBE='[ -d .claude/skills/react-doctor ]'

# check_react_doctor_location <per-machine> <surface-file> <init>: the probe
# names the frontend location, and no file carries the root-level probe.
check_react_doctor_location() {
  local per_machine="$1" surface="$2" init="$3" file
  grep -qF -- "$REACT_DOCTOR_PROBE" "$per_machine" || {
    echo "the per-machine probe does not name frontend/.claude/skills/react-doctor" >&2
    return 1
  }
  for file in "$surface" "$init"; do
    if grep -qF -- "$OLD_REACT_DOCTOR_PROBE" "$file"; then
      echo "${file} carries the root-level React Doctor probe" >&2
      return 1
    fi
  done
}

@test "the React Doctor probe names the frontend location and the old probe is gone" {
  check_react_doctor_location "$PER_MACHINE_REFERENCE" "$(real_surface)" "$INIT_PAGE"
}

@test "the React Doctor location check fails with the old probe put back in a reference" {
  local directory surface
  directory="$(scratch_references react-doctor-old-reference)"
  printf '\n%s\n' "$OLD_REACT_DOCTOR_PROBE" >>"${directory}/sandbox.md"
  surface="$(build_surface "$PAGE" "$directory" surface-react-doctor-old.md)"
  run check_react_doctor_location "${directory}/per-machine.md" "$surface" "$INIT_PAGE"
  [ "$status" -ne 0 ]
  grep -qF 'root-level React Doctor probe' <<<"$output"
}

@test "the React Doctor location check fails with the old probe put back in the init command" {
  local copy
  copy="$(scratch_copy "$INIT_PAGE" "react-doctor-old-init.md")"
  printf '\n%s\n' "$OLD_REACT_DOCTOR_PROBE" >>"$copy"
  run check_react_doctor_location "$PER_MACHINE_REFERENCE" "$(real_surface)" "$copy"
  [ "$status" -ne 0 ]
  grep -qF 'root-level React Doctor probe' <<<"$output"
}

@test "the React Doctor location check fails when the per-machine probe loses the frontend path" {
  local copy
  copy="$(scratch_copy "$PER_MACHINE_REFERENCE" "react-doctor-no-frontend.md")"
  sed 's#\[ -d frontend/\.claude/skills/react-doctor \]#[ -d .claude/skills/react-doctor ]#' "$PER_MACHINE_REFERENCE" >"$copy"
  cmp -s "$PER_MACHINE_REFERENCE" "$copy" && return 1
  run check_react_doctor_location "$copy" "$(real_surface)" "$INIT_PAGE"
  [ "$status" -ne 0 ]
  grep -qF 'does not name' <<<"$output"
}
