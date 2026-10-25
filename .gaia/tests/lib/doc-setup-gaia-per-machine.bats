#!/usr/bin/env bats
# Phase 2 per-machine setup, driven by the per-machine reference under
# `.claude/skills/gaia/references/setup/`:
#
#   - The React Doctor probe names the `frontend/` skill location, and neither
#     the setup surface nor `.claude/commands/gaia-init.md` carries the
#     root-level probe.
#   - install-tools runs a tool's install only when its own probe fails, and a
#     resumed run skips a step already recorded.
#   - No setup reference and no command except the init command and the release
#     command (another change owns the release command) pairs `/gaia-init`
#     with per-machine work, and per-machine.md names no automatic caller.
#   - Argument parse says an inline read from init leaves `RECONFIGURE` false.
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

# mutate_file <source> <name> <old> <new>: copy <source> into the test's temp
# dir with every literal <old> replaced by <new>, and print the copy's path.
# Fails when the replacement changed nothing, so a control can never run on an
# unmutated copy.
mutate_file() {
  local copy="${BATS_TEST_TMPDIR}/$2" content
  content="$(cat "$1")"
  content="${content//"$3"/$4}"
  printf '%s\n' "$content" >"$copy"
  cmp -s "$1" "$copy" && {
    echo "the mutation changed nothing in $2" >&2
    return 1
  }
  printf '%s\n' "$copy"
}

# ---------------------------------------------------------------------------
# install-tools runs a tool's install only when its own probe fails
# ---------------------------------------------------------------------------

PER_TOOL_SENTENCE="Run each tool's install only when its own probe fails, so a React Doctor skill already on disk is recorded without being installed again."
STANDALONE_GAP_SENTENCE='A session that read a file under `frontend/` before this install lists the skill only from its next session; the closing message adds no restart line for it.'

# check_install_tools_per_tool <per-machine>: the install-tools step carries
# the per-tool install sentence and the standalone-gap sentence.
check_install_tools_per_tool() {
  local step
  step="$(awk '$0 == "## Step 1: install-tools" { inside = 1; next } inside && /^## / { exit } inside' "$1")"
  [ -n "$step" ] || {
    echo "## Step 1: install-tools is empty or missing" >&2
    return 1
  }
  grep -qF -- "$PER_TOOL_SENTENCE" <<<"$step" || {
    echo "install-tools lacks the per-tool install sentence" >&2
    return 1
  }
  grep -qF -- "$STANDALONE_GAP_SENTENCE" <<<"$step" || {
    echo "install-tools lacks the standalone-gap sentence" >&2
    return 1
  }
  return 0
}

@test "install-tools runs each tool's install only when its own probe fails" {
  check_install_tools_per_tool "$PER_MACHINE_REFERENCE"
}

@test "the per-tool check fails without the per-tool install sentence" {
  local copy
  copy="$(mutate_file "$PER_MACHINE_REFERENCE" per-tool-no-install.md "$PER_TOOL_SENTENCE " '')"
  run check_install_tools_per_tool "$copy"
  [ "$status" -ne 0 ]
  grep -qF 'per-tool install sentence' <<<"$output"
}

@test "the per-tool check fails without the standalone-gap sentence" {
  local copy
  copy="$(mutate_file "$PER_MACHINE_REFERENCE" per-tool-no-gap.md " $STANDALONE_GAP_SENTENCE" '')"
  run check_install_tools_per_tool "$copy"
  [ "$status" -ne 0 ]
  grep -qF 'standalone-gap sentence' <<<"$output"
}

# ---------------------------------------------------------------------------
# No setup or command file says /gaia-init runs the per-machine work
# ---------------------------------------------------------------------------

# check_no_init_per_machine_claim <file>: no line names /gaia-init together
# with a per-machine word.
check_no_init_per_machine_claim() {
  local file="$1" hits
  [ -f "$file" ] || {
    echo "unreadable file: ${file}" >&2
    return 1
  }
  hits="$(grep -F -- '/gaia-init' "$file" | grep -E 'per-machine|mark-step|setup finalize|install|plugin|React Doctor|typescript-lsp' || true)"
  [ -z "$hits" ] || {
    echo "${file} pairs /gaia-init with per-machine work: ${hits}" >&2
    return 1
  }
  return 0
}

# claim_command_files: every command except the init command (it has its own
# checks) and the release command (another change owns it and no edit here may
# touch it), derived from the directory.
claim_command_files() {
  local command_file
  for command_file in "${REPO_ROOT}"/.claude/commands/*.md; do
    case "$(basename "$command_file")" in
      gaia-init.md | gaia-release.md) continue ;;
    esac
    printf '%s\n' "$command_file"
  done
}

@test "no setup reference or command says /gaia-init runs the per-machine work" {
  local files file count=0
  files="$(surface_files "$PAGE" "$REFERENCES_DIRECTORY")"
  files="${files}"$'\n'"$(claim_command_files)"
  while IFS= read -r file; do
    check_no_init_per_machine_claim "$file"
    count=$((count + 1))
  done <<<"$files"
  # the surface alone is the entry plus every expected reference
  [ "$count" -gt "$(wc -w <<<"$EXPECTED_SETUP_REFERENCES")" ]
}

@test "the init-claim check fails with the old per-machine header put back" {
  local copy
  copy="$(mutate_file "$PER_MACHINE_REFERENCE" init-claim-header.md 'The four per-machine steps `/setup-gaia` runs in Phase 2:' 'The four per-machine steps `/gaia-init` (Step 8) and `/setup-gaia` (Phase 2) share:')"
  run check_no_init_per_machine_claim "$copy"
  [ "$status" -ne 0 ]
  grep -qF 'The four per-machine steps `/gaia-init` (Step 8)' <<<"$output"
}

# ---------------------------------------------------------------------------
# Entry by inline read, no automatic caller, resume skips recorded steps
# ---------------------------------------------------------------------------

READ_ENTRY_SENTENCE='When `/gaia-init` reads this file inline at its last step, `$ARGUMENTS` is not substituted: `RECONFIGURE` is false.'
SKIP_COMPLETED_SENTENCE='A step already in `completed_steps` is not re-run.'

# check_read_entry_sentence <page>: Argument parse says an inline read carries
# no flag.
check_read_entry_sentence() {
  local section
  section="$(awk '$0 == "## Argument parse" { inside = 1; next } inside && /^## / { exit } inside' "$1")"
  grep -qF -- "$READ_ENTRY_SENTENCE" <<<"$section" || {
    echo "Argument parse lacks the inline-read sentence" >&2
    return 1
  }
  return 0
}

@test "Argument parse says an inline read from init leaves RECONFIGURE false" {
  check_read_entry_sentence "$PAGE"
}

@test "the inline-read check fails on a copy without the sentence" {
  local copy
  copy="$(mutate_file "$PAGE" read-entry-absent.md " $READ_ENTRY_SENTENCE" '')"
  run check_read_entry_sentence "$copy"
  [ "$status" -ne 0 ]
  grep -qF 'inline-read sentence' <<<"$output"
}

# check_no_automatic_caller <per-machine>: no sentence lets an automatic mode
# answer a setup gate.
check_no_automatic_caller() {
  grep -qF -- 'automatic mode' "$1" && {
    echo "per-machine.md names an automatic mode" >&2
    return 1
  }
  return 0
}

@test "per-machine setup names no automatic caller" {
  check_no_automatic_caller "$PER_MACHINE_REFERENCE"
}

@test "the automatic-caller check fails with the old sentence put back" {
  local copy
  copy="$(scratch_copy "$PER_MACHINE_REFERENCE" automatic-caller.md)"
  printf '%s\n' 'A caller running in an automatic mode turns them on without asking.' >>"$copy"
  run check_no_automatic_caller "$copy"
  [ "$status" -ne 0 ]
  grep -qF 'automatic mode' <<<"$output"
}

# check_resume_skips_completed <per-machine>: the skip-completed rule and the
# per-tool install rule are both present, so a resumed run neither repeats a
# recorded step nor reinstalls a tool whose probe passes.
check_resume_skips_completed() {
  grep -qF -- "$SKIP_COMPLETED_SENTENCE" "$1" || {
    echo "per-machine.md lacks the skip-completed rule: ${SKIP_COMPLETED_SENTENCE}" >&2
    return 1
  }
  check_install_tools_per_tool "$1"
}

@test "a resumed setup skips recorded steps and reinstalls no tool whose probe passes" {
  check_resume_skips_completed "$PER_MACHINE_REFERENCE"
}

@test "the resume check fails without the skip-completed rule" {
  local copy
  copy="$(mutate_file "$PER_MACHINE_REFERENCE" skip-completed-absent.md "$SKIP_COMPLETED_SENTENCE" '')"
  run check_resume_skips_completed "$copy"
  [ "$status" -ne 0 ]
  grep -qF 'skip-completed rule' <<<"$output"
}
