#!/usr/bin/env bats
#
# Doc-conformance suite for /gaia-init (.claude/commands/gaia-init.md): the
# command writes the project settings through `gaia init write-project-config`,
# and its resume step list names the same steps, in the same order, as the CLI's
# STEP_ORDER. It also pins the shared-reference shape: the command reads exactly
# the per-machine reference (it asks no team-setting question), lists it in its
# references block, and the setup command reads it too (finalize deletes only
# this command); it finalizes with the plain setup finalize call; and Step 1
# refreshes the statusline's update-check cache after its /update-deps call.

# The exact opening sentence of a command's references block.
REFERENCES_OPENING='This command reads these references, all under `.claude/skills/gaia/references/setup/`. Read one only when a "Read ... now" line sends you there, and then read the whole file:'

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  INIT_MD="$REPO_ROOT/.claude/commands/gaia-init.md"
  SETUP_MD="$REPO_ROOT/.claude/commands/setup-gaia.md"
  REFERENCES_DIRECTORY="$REPO_ROOT/.claude/skills/gaia/references/setup"
  STATE_TS="$REPO_ROOT/.gaia/cli/src/init/util/state.ts"
  FROZEN_STEPS="strip-branding configure-i18n configure-data-layer rename wire-statusline bootstrap-env write-project-config finalize"
}

# Print the resume list names in order, from the `--from-step` sentence.
resume_steps() {
  grep -F -- '--from-step <N>' "$1" |
    grep -oE '[0-9]+=[a-z0-9-]+' |
    sed -E 's/^[0-9]+=//' |
    tr '\n' ' ' | sed 's/ $//'
}

resume_indices() {
  grep -F -- '--from-step <N>' "$1" |
    grep -oE '[0-9]+=[a-z0-9-]+' |
    sed -E 's/=.*$//' |
    tr '\n' ' ' | sed 's/ $//'
}

state_steps() {
  awk '/export const STEP_ORDER = \[/{on=1; next} on && /\] as const/{exit} on{gsub(/[ ,\047]/,""); if ($0 != "") print}' "$STATE_TS" |
    tr '\n' ' ' | sed 's/ $//'
}

# writer_call_present <file>: rc 0 when the file calls write-project-config
# with the shipped not-recommended default.
writer_call_present() {
  grep -qF -- 'gaia init write-project-config --sandbox-recommended false' "$1"
}

@test "gaia-init.md calls write-project-config with the not-recommended default" {
  writer_call_present "$INIT_MD"
}

@test "the writer check fails when the writer subcommand is renamed in a scratch copy" {
  local scratch="$BATS_TEST_TMPDIR/gaia-init.scratch.md"
  sed 's/gaia init write-project-config/gaia init write-renamed-config/g' "$INIT_MD" >"$scratch"
  cmp -s "$INIT_MD" "$scratch" && return 1
  run writer_call_present "$scratch"
  [ "$status" -ne 0 ]
}

@test "the resume list indexes its steps 1..N in order, N derived from STEP_ORDER" {
  local expected_indices="" index step_count
  step_count="$(wc -w <<<"$(state_steps)" | tr -d ' ')"
  [ "$step_count" -gt 0 ]
  for ((index = 1; index <= step_count; index++)); do
    expected_indices="${expected_indices:+$expected_indices }$index"
  done
  [ "$(resume_indices "$INIT_MD")" = "$expected_indices" ]
}

@test "the resume list agrees with STEP_ORDER in state.ts" {
  [ "$(state_steps)" = "$(resume_steps "$INIT_MD")" ]
}

@test "the resume check fails on a reordered scratch copy" {
  local scratch="$BATS_TEST_TMPDIR/gaia-init.scratch.md"
  sed -E 's/6=bootstrap-env, 7=write-project-config/6=write-project-config, 7=bootstrap-env/' "$INIT_MD" >"$scratch"
  [ "$(resume_steps "$scratch")" != "$FROZEN_STEPS" ]
}

# ---------------------------------------------------------------------------
# Shared references only
# ---------------------------------------------------------------------------

SHARED_REFERENCES="per-machine.md"

# references_block_names <file>: the basenames of the bullets directly below
# the references block's exact opening sentence, sorted, one per line. Fails
# loudly when the opening sentence is absent.
references_block_names() {
  local names
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
  ' "$1")" || {
    echo "the references block opening sentence is absent from $1" >&2
    return 1
  }
  sort <<<"$names"
}

# check_shared_references_only <init> <setup-command> <directory>: the setup
# reference paths <init> names are exactly the shared ones, they exist, its
# references block lists exactly those, and the setup command names each too.
check_shared_references_only() {
  local init="$1" setup_command="$2" directory="$3" expected named block name
  expected="$(tr ' ' '\n' <<<"$SHARED_REFERENCES" | sort)"
  named="$(grep -oE '\.claude/skills/gaia/references/setup/[A-Za-z0-9._-]+\.md' "$init" | sed 's#.*/##' | sort -u)"
  [ "$named" = "$expected" ] || {
    echo "the init command names setup references other than the shared ones:" >&2
    diff <(printf '%s\n' "$expected") <(printf '%s\n' "$named") >&2 || true
    return 1
  }
  for name in $SHARED_REFERENCES; do
    [ -f "${directory}/${name}" ] || {
      echo "a shared reference is absent: ${name}" >&2
      return 1
    }
    grep -qF -- ".claude/skills/gaia/references/setup/${name}" "$setup_command" || {
      echo "the setup command no longer names ${name}" >&2
      return 1
    }
  done
  block="$(references_block_names "$init")" || return 1
  [ "$block" = "$expected" ] || {
    echo "the init references block differs from the shared references:" >&2
    diff <(printf '%s\n' "$expected") <(printf '%s\n' "$block") >&2 || true
    return 1
  }
}

@test "gaia-init.md reads only the references setup-gaia.md also reads" {
  check_shared_references_only "$INIT_MD" "$SETUP_MD" "$REFERENCES_DIRECTORY"
}

@test "the shared-reference check fails when the init command names a reference outside the shared set" {
  local scratch="$BATS_TEST_TMPDIR/gaia-init.scratch.md"
  cp "$INIT_MD" "$scratch"
  printf '\nRead `.claude/skills/gaia/references/setup/sandbox.md` now, the whole file.\n' >>"$scratch"
  run check_shared_references_only "$scratch" "$SETUP_MD" "$REFERENCES_DIRECTORY"
  [ "$status" -ne 0 ]
  grep -qF 'other than the shared ones' <<<"$output"
}

@test "the shared-reference check fails when the init command reads the isolation question again" {
  local scratch="$BATS_TEST_TMPDIR/gaia-init.scratch.md"
  cp "$INIT_MD" "$scratch"
  printf '\nRead `.claude/skills/gaia/references/setup/isolation-question.md` now, the whole file.\n' >>"$scratch"
  run check_shared_references_only "$scratch" "$SETUP_MD" "$REFERENCES_DIRECTORY"
  [ "$status" -ne 0 ]
  grep -qF 'other than the shared ones' <<<"$output"
}

@test "the shared-reference check fails when the setup command stops naming per-machine.md" {
  local scratch="$BATS_TEST_TMPDIR/setup-gaia.scratch.md"
  sed 's#references/setup/per-machine\.md#references/setup/gone.md#g' "$SETUP_MD" >"$scratch"
  cmp -s "$SETUP_MD" "$scratch" && return 1
  run check_shared_references_only "$INIT_MD" "$scratch" "$REFERENCES_DIRECTORY"
  [ "$status" -ne 0 ]
  grep -qF 'no longer names per-machine.md' <<<"$output"
}

@test "the shared-reference check fails when the references block drops a bullet" {
  local scratch="$BATS_TEST_TMPDIR/gaia-init.scratch.md"
  grep -v -- '^- `per-machine.md`: ' "$INIT_MD" >"$scratch" || true
  cmp -s "$INIT_MD" "$scratch" && return 1
  run check_shared_references_only "$scratch" "$SETUP_MD" "$REFERENCES_DIRECTORY"
  [ "$status" -ne 0 ]
  grep -qF 'references block differs' <<<"$output"
}

@test "the shared-reference check fails loudly when the opening sentence is reworded" {
  local scratch="$BATS_TEST_TMPDIR/gaia-init.scratch.md"
  sed 's/^This command reads these references/This command loads these references/' "$INIT_MD" >"$scratch"
  cmp -s "$INIT_MD" "$scratch" && return 1
  run check_shared_references_only "$scratch" "$SETUP_MD" "$REFERENCES_DIRECTORY"
  [ "$status" -ne 0 ]
  grep -qF 'opening sentence is absent' <<<"$output"
}

@test "the shared-reference check fails when a shared reference file is absent" {
  local directory="$BATS_TEST_TMPDIR/references"
  mkdir -p "$directory"
  run check_shared_references_only "$INIT_MD" "$SETUP_MD" "$directory"
  [ "$status" -ne 0 ]
  grep -qF 'a shared reference is absent' <<<"$output"
}

# ---------------------------------------------------------------------------
# Plain finalize
# ---------------------------------------------------------------------------

# check_plain_finalize <file>: the file carries the plain setup finalize call
# and never the forced form.
check_plain_finalize() {
  grep -qF -- '.gaia/cli/gaia setup finalize' "$1" || {
    echo "the plain setup finalize call is absent" >&2
    return 1
  }
  if grep -qF -- 'setup finalize --force' "$1"; then
    echo "the forced setup finalize call is present" >&2
    return 1
  fi
}

@test "gaia-init.md finalizes with the plain setup finalize call" {
  check_plain_finalize "$INIT_MD"
}

@test "the plain finalize check fails on the forced form put back" {
  local scratch="$BATS_TEST_TMPDIR/gaia-init.scratch.md"
  cp "$INIT_MD" "$scratch"
  printf '\n.gaia/cli/gaia setup finalize --force\n' >>"$scratch"
  run check_plain_finalize "$scratch"
  [ "$status" -ne 0 ]
  grep -qF 'forced setup finalize' <<<"$output"
}

@test "the plain finalize check fails when the plain call is removed" {
  local scratch="$BATS_TEST_TMPDIR/gaia-init.scratch.md"
  grep -vF -- '.gaia/cli/gaia setup finalize' "$INIT_MD" >"$scratch" || true
  cmp -s "$INIT_MD" "$scratch" && return 1
  run check_plain_finalize "$scratch"
  [ "$status" -ne 0 ]
  grep -qF 'plain setup finalize call is absent' <<<"$output"
}

# check_step1_bust <file>: Step 1 runs the deps-mode update-check bust after
# its /update-deps call and before Step 2. An init-invoked /update-deps cuts no
# branch, so it never reaches the bust /update-deps runs at branch creation.
check_step1_bust() {
  awk '
    /^## Step 1:/ { inside = 1; next }
    inside && /^## Step 2:/ { exit }
    inside && /run `\/update-deps`/ { saw_update_deps = 1 }
    inside && saw_update_deps && /update-check-bust\.sh .*--mode deps/ { busted = 1 }
    END {
      if (!saw_update_deps) { print "Step 1 has no /update-deps call"; exit 1 }
      if (!busted) { print "Step 1 runs no deps-mode bust after /update-deps"; exit 1 }
    }
  ' "$1"
}

# move_bust_line <file> <anchor ERE> <before|after>: prints the file with the
# bust command line moved next to the first line matching the anchor.
move_bust_line() {
  ANCHOR="$2" PLACEMENT="$3" awk '
    NR == FNR { if (/update-check-bust\.sh/) bust = $0; next }
    /update-check-bust\.sh/ { next }
    !moved && $0 ~ ENVIRON["ANCHOR"] {
      moved = 1
      if (ENVIRON["PLACEMENT"] == "before") { print bust; print; next }
      print; print bust; next
    }
    { print }
  ' "$1" "$1"
}

@test "gaia-init.md Step 1 busts the update-check cache after /update-deps" {
  check_step1_bust "$INIT_MD"
}

@test "the Step 1 bust check fails when the bust is removed" {
  local scratch="$BATS_TEST_TMPDIR/gaia-init.scratch.md"
  grep -vF -- 'update-check-bust.sh' "$INIT_MD" >"$scratch" || true
  cmp -s "$INIT_MD" "$scratch" && return 1
  run check_step1_bust "$scratch"
  [ "$status" -ne 0 ]
  grep -qF 'no deps-mode bust after /update-deps' <<<"$output"
}

@test "the Step 1 bust check fails when the bust moves before /update-deps" {
  local scratch="$BATS_TEST_TMPDIR/gaia-init.scratch.md"
  move_bust_line "$INIT_MD" 'run `/update-deps`' before >"$scratch"
  cmp -s "$INIT_MD" "$scratch" && return 1
  run check_step1_bust "$scratch"
  [ "$status" -ne 0 ]
  grep -qF 'no deps-mode bust after /update-deps' <<<"$output"
}

@test "the Step 1 bust check fails when the bust leaves Step 1" {
  local scratch="$BATS_TEST_TMPDIR/gaia-init.scratch.md"
  move_bust_line "$INIT_MD" '^## Step 2:' after >"$scratch"
  cmp -s "$INIT_MD" "$scratch" && return 1
  run check_step1_bust "$scratch"
  [ "$status" -ne 0 ]
  grep -qF 'no deps-mode bust after /update-deps' <<<"$output"
}

@test "the Step 1 bust check fails on a deps bust in the wrong mode" {
  local scratch="$BATS_TEST_TMPDIR/gaia-init.scratch.md"
  sed 's/update-check-bust\.sh \(.*\)--mode deps/update-check-bust.sh \1--mode gaia/' "$INIT_MD" >"$scratch"
  cmp -s "$INIT_MD" "$scratch" && return 1
  run check_step1_bust "$scratch"
  [ "$status" -ne 0 ]
  grep -qF 'no deps-mode bust after /update-deps' <<<"$output"
}
