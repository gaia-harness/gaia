#!/usr/bin/env bats
#
# Doc-conformance suite for /gaia-init (.claude/commands/gaia-init.md): the
# command writes the project settings through `gaia init write-project-config`,
# and its resume step list names the same steps, in the same order, as the CLI's
# STEP_ORDER. It also pins the single-session shape: the React Doctor install
# sits once in Step 1, before any line names a `frontend/` path; the command
# reads no setup reference and runs or records no per-machine step; it asks for
# no exit, restart or reload; Step 10 finalizes and Step 11 hands off to
# /setup-gaia, ending on the read of the setup command with RECONFIGURE false
# and the halt rule; the wiki log claims no install; the resume section names no
# install. It also pins that it updates no dependencies: no /update-deps run or
# cache bust before Step 11, Chromium installed in Step 1 and not again in
# Step 7, and a handoff pointer to /update-deps.

# The exact opening sentence a command's references block carries.
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
# Section and scratch-copy helpers
# ---------------------------------------------------------------------------

# section_of <file> <heading prefix>: the lines of the section whose heading
# starts with the prefix, up to the next heading of the same or a shallower
# level. Fence-aware: a `## ` line inside a code fence (the wiki log block holds
# one) is content, never a boundary.
section_of() {
  HEADING="$2" awk '
    BEGIN { heading = ENVIRON["HEADING"]; match(heading, /^#+/); level = RLENGTH }
    /^```/ { fence = !fence }
    !fence && /^#+ / {
      match($0, /^#+/)
      if (index($0, heading) == 1) inside = 1
      else if (RLENGTH <= level) inside = 0
    }
    inside { print }
  ' "$1"
}

# drop_line <in> <out> <line>: <in> without the lines equal to <line>.
drop_line() {
  grep -vxF -- "$3" "$1" >"$2" || true
}

# insert_before <in> <out> <line> <anchor>: <line> and a blank line go right
# before the first line that starts with <anchor>.
insert_before() {
  LINE="$3" ANCHOR="$4" awk '
    BEGIN { line = ENVIRON["LINE"]; anchor = ENVIRON["ANCHOR"] }
    !done && index($0, anchor) == 1 { print line; print ""; done = 1 }
    { print }
  ' "$1" >"$2"
}

# insert_after <in> <out> <line> <anchor>: a blank line and <line> go right
# after the first line containing <anchor>.
insert_after() {
  LINE="$3" ANCHOR="$4" awk '
    BEGIN { line = ENVIRON["LINE"]; anchor = ENVIRON["ANCHOR"] }
    { print }
    !done && index($0, anchor) > 0 { print ""; print line; done = 1 }
  ' "$1" >"$2"
}

# remove_text <in> <out> <text>: <in> with every occurrence of <text> deleted.
remove_text() {
  local content
  content="$(<"$1")"
  printf '%s\n' "${content//"$3"/}" >"$2"
}

# ---------------------------------------------------------------------------
# The React Doctor install is early, once, and in Step 1
# ---------------------------------------------------------------------------

# check_react_doctor_early_install <init>: the installer is named on exactly one
# line, inside Step 1, after the dependency install and the Chromium install,
# and no earlier line names a `frontend/` path. Claude Code lists a folder's
# skills the first time the session reads a file in it, so the install must
# precede every step that reads under `frontend/`. The check pins any
# `frontend/` path rather than a file-tool verb near one: a path in the text is
# the only text-level proxy for an instruction that reads, edits or writes
# there, and Step 1's Bash lines name the package as `pnpm -C frontend`, with no
# slash.
check_react_doctor_early_install() {
  local file="$1" count install_line pnpm_line chromium_line frontend_line
  count="$(grep -cF -- 'install-react-doctor.sh' "$file" || true)"
  [ "$count" = 1 ] || {
    echo "gaia-init.md names the React Doctor installer ${count} times" >&2
    return 1
  }
  install_line="$(grep -nF -- 'install-react-doctor.sh' "$file" | head -n 1 | cut -d: -f1)"
  section_of "$file" '## Step 1:' | grep -qF -- 'install-react-doctor.sh' || {
    echo "the React Doctor install is not in Step 1" >&2
    return 1
  }
  pnpm_line="$(grep -nF -- 'pnpm install --config.confirm-modules-purge=false' "$file" | head -n 1 | cut -d: -f1)"
  { [ -n "$pnpm_line" ] && [ "$install_line" -gt "$pnpm_line" ]; } || {
    echo "the React Doctor install precedes the dependency install" >&2
    return 1
  }
  chromium_line="$(grep -nF -- 'playwright install chromium' "$file" | head -n 1 | cut -d: -f1)"
  { [ -n "$chromium_line" ] && [ "$install_line" -gt "$chromium_line" ]; } || {
    echo "the React Doctor install precedes the Chromium install" >&2
    return 1
  }
  frontend_line="$(head -n $((install_line - 1)) "$file" | grep -nF -- 'frontend/' | head -n 1 | cut -d: -f1)"
  [ -z "$frontend_line" ] || {
    echo "a frontend/ path is named before the React Doctor install: line ${frontend_line}" >&2
    return 1
  }
}

# install_line_text: the line of the real file that names the installer.
install_line_text() {
  grep -F -- 'install-react-doctor.sh' "$INIT_MD"
}

@test "gaia-init.md installs React Doctor once, in Step 1, before any frontend/ path" {
  check_react_doctor_early_install "$INIT_MD"
}

@test "the early-install check fails when the installer line is deleted" {
  local scratch="$BATS_TEST_TMPDIR/gaia-init.scratch.md"
  grep -vF -- 'install-react-doctor.sh' "$INIT_MD" >"$scratch" || true
  cmp -s "$INIT_MD" "$scratch" && return 1
  run check_react_doctor_early_install "$scratch"
  [ "$status" -ne 0 ]
  grep -qF 'names the React Doctor installer 0 times' <<<"$output"
}

@test "the early-install check fails when the installer line is duplicated into Step 8" {
  local scratch="$BATS_TEST_TMPDIR/gaia-init.scratch.md" line
  line="$(install_line_text)"
  [ -n "$line" ]
  insert_after "$INIT_MD" "$scratch" "$line" '## Step 8:'
  cmp -s "$INIT_MD" "$scratch" && return 1
  run check_react_doctor_early_install "$scratch"
  [ "$status" -ne 0 ]
  grep -qF 'names the React Doctor installer 2 times' <<<"$output"
}

@test "the early-install check fails when the installer line moves to the end of Step 2" {
  local scratch="$BATS_TEST_TMPDIR/gaia-init.scratch.md" dropped="$BATS_TEST_TMPDIR/dropped.md" line
  line="$(install_line_text)"
  [ -n "$line" ]
  drop_line "$INIT_MD" "$dropped" "$line"
  insert_before "$dropped" "$scratch" "$line" '## Step 3:'
  cmp -s "$INIT_MD" "$scratch" && return 1
  run check_react_doctor_early_install "$scratch"
  [ "$status" -ne 0 ]
  grep -qF 'the React Doctor install is not in Step 1' <<<"$output"
}

@test "the early-install check fails when the installer line moves into Step 4 after the add-locale read" {
  local scratch="$BATS_TEST_TMPDIR/gaia-init.scratch.md" dropped="$BATS_TEST_TMPDIR/dropped.md" line
  line="$(install_line_text)"
  [ -n "$line" ]
  drop_line "$INIT_MD" "$dropped" "$line"
  insert_after "$dropped" "$scratch" "$line" 'add-locale.md'
  cmp -s "$INIT_MD" "$scratch" && return 1
  run check_react_doctor_early_install "$scratch"
  [ "$status" -ne 0 ]
  grep -qF 'the React Doctor install is not in Step 1' <<<"$output"
}

@test "the early-install check fails when the installer line moves above the dependency install" {
  local scratch="$BATS_TEST_TMPDIR/gaia-init.scratch.md" dropped="$BATS_TEST_TMPDIR/dropped.md" line
  line="$(install_line_text)"
  [ -n "$line" ]
  drop_line "$INIT_MD" "$dropped" "$line"
  insert_before "$dropped" "$scratch" "$line" 'pnpm install --config.confirm-modules-purge=false'
  cmp -s "$INIT_MD" "$scratch" && return 1
  run check_react_doctor_early_install "$scratch"
  [ "$status" -ne 0 ]
  grep -qF 'precedes the dependency install' <<<"$output"
}

@test "the early-install check fails when the installer line moves above the Chromium paragraph" {
  local scratch="$BATS_TEST_TMPDIR/gaia-init.scratch.md" dropped="$BATS_TEST_TMPDIR/dropped.md" line
  line="$(install_line_text)"
  [ -n "$line" ]
  drop_line "$INIT_MD" "$dropped" "$line"
  insert_before "$dropped" "$scratch" "$line" 'Then tell the user "Installing Chromium'
  cmp -s "$INIT_MD" "$scratch" && return 1
  run check_react_doctor_early_install "$scratch"
  [ "$status" -ne 0 ]
  grep -qF 'precedes the Chromium install' <<<"$output"
}

@test "the early-install check fails when a frontend/ path is named above the installer line" {
  local scratch="$BATS_TEST_TMPDIR/gaia-init.scratch.md" line
  line="$(install_line_text)"
  [ -n "$line" ]
  insert_before "$INIT_MD" "$scratch" 'Read `frontend/CLAUDE.md` now.' "$line"
  cmp -s "$INIT_MD" "$scratch" && return 1
  run check_react_doctor_early_install "$scratch"
  [ "$status" -ne 0 ]
  grep -qF 'a frontend/ path is named before the React Doctor install' <<<"$output"
}

# ---------------------------------------------------------------------------
# Init reads no setup reference
# ---------------------------------------------------------------------------

SETUP_REFERENCE_NAMES="per-machine.md sandbox.md isolation-question.md"

# check_no_setup_references <init>: the init command carries no references
# block and names no path under the setup references folder, since it hands the
# whole machine setup to /setup-gaia.
check_no_setup_references() {
  local named
  if grep -qF -- 'This command reads these references' "$1"; then
    echo "the init command carries a references block" >&2
    return 1
  fi
  named="$(grep -oE '\.claude/skills/gaia/references/setup/[A-Za-z0-9._-]*' "$1" | sort -u || true)"
  [ -z "$named" ] || {
    echo "the init command names a setup reference:" >&2
    printf '%s\n' "$named" >&2
    return 1
  }
}

# check_setup_names_per_machine <setup-command> <directory>: the setup command
# still names the per-machine reference and the file exists.
check_setup_names_per_machine() {
  [ -f "${2}/per-machine.md" ] || {
    echo "a shared reference is absent: per-machine.md" >&2
    return 1
  }
  grep -qF -- '.claude/skills/gaia/references/setup/per-machine.md' "$1" || {
    echo "the setup command no longer names per-machine.md" >&2
    return 1
  }
}

@test "gaia-init.md names no setup reference and carries no references block" {
  check_no_setup_references "$INIT_MD"
}

@test "the no-reference check fails when the init command reads any setup reference again" {
  local scratch="$BATS_TEST_TMPDIR/gaia-init.scratch.md" name ran=0 expected
  expected="$(wc -w <<<"$SETUP_REFERENCE_NAMES" | tr -d ' ')"
  [ "$expected" -gt 0 ]
  for name in $SETUP_REFERENCE_NAMES; do
    cp "$INIT_MD" "$scratch"
    printf '\nRead `.claude/skills/gaia/references/setup/%s` now, the whole file.\n' "$name" >>"$scratch"
    cmp -s "$INIT_MD" "$scratch" && return 1
    run check_no_setup_references "$scratch"
    [ "$status" -ne 0 ]
    grep -qF 'names a setup reference' <<<"$output" || return 1
    grep -qF "references/setup/${name}" <<<"$output" || return 1
    ran=$((ran + 1))
  done
  [ "$ran" -eq "$expected" ]
}

@test "the no-reference check fails when the references block and its bullet come back" {
  local scratch="$BATS_TEST_TMPDIR/gaia-init.scratch.md"
  cp "$INIT_MD" "$scratch"
  printf '\n%s\n- `per-machine.md`: Step 8.\n' "$REFERENCES_OPENING" >>"$scratch"
  run check_no_setup_references "$scratch"
  [ "$status" -ne 0 ]
  grep -qF 'carries a references block' <<<"$output"
}

@test "the no-reference check fails on a reworded references opening with no path" {
  local scratch="$BATS_TEST_TMPDIR/gaia-init.scratch.md"
  cp "$INIT_MD" "$scratch"
  printf '\nThis command reads these references. Read one only when a "Read ... now" line sends you there:\n' >>"$scratch"
  cmp -s "$INIT_MD" "$scratch" && return 1
  run check_no_setup_references "$scratch"
  [ "$status" -ne 0 ]
  grep -qF 'carries a references block' <<<"$output"
}

@test "the setup command still names per-machine.md and the file exists" {
  check_setup_names_per_machine "$SETUP_MD" "$REFERENCES_DIRECTORY"
}

@test "the setup-side check fails when the setup command stops naming per-machine.md" {
  local scratch="$BATS_TEST_TMPDIR/setup-gaia.scratch.md"
  sed 's#references/setup/per-machine\.md#references/setup/gone.md#g' "$SETUP_MD" >"$scratch"
  cmp -s "$SETUP_MD" "$scratch" && return 1
  run check_setup_names_per_machine "$scratch" "$REFERENCES_DIRECTORY"
  [ "$status" -ne 0 ]
  grep -qF 'no longer names per-machine.md' <<<"$output"
}

@test "the setup-side check fails when the per-machine file is absent" {
  local directory="$BATS_TEST_TMPDIR/references"
  mkdir -p "$directory"
  run check_setup_names_per_machine "$SETUP_MD" "$directory"
  [ "$status" -ne 0 ]
  grep -qF 'a shared reference is absent' <<<"$output"
}

# ---------------------------------------------------------------------------
# Init runs and records no per-machine step
# ---------------------------------------------------------------------------

SETUP_STEP_NEEDLES=(
  'gaia setup finalize'
  'gaia setup mark-step'
  'gaia setup bootstrap-env'
  'gaia setup record install-tools'
  'gaia setup record install-plugins'
  'gaia setup record chmod-statusline'
  'gaia setup record bootstrap-env'
  'claude plugin install'
  '@playwright/cli'
  'chmod +x .gaia/statusline'
  'references/setup/per-machine.md'
)

# check_no_setup_step <init>: none of the per-machine commands appear, while
# the project decisions init does record (the .env bootstrap in Step 6, the
# sandbox recommendation in Step 8) stay.
check_no_setup_step() {
  local needle
  for needle in "${SETUP_STEP_NEEDLES[@]}"; do
    if grep -qF -- "$needle" "$1"; then
      echo "the init command names a per-machine step: ${needle}" >&2
      return 1
    fi
  done
  section_of "$1" '## Step 6:' | grep -qF -- '.gaia/cli/gaia init bootstrap-env' || {
    echo "Step 6 no longer bootstraps .env" >&2
    return 1
  }
  section_of "$1" '## Step 8: Project settings' | grep -qF -- 'gaia setup record sandbox-recommendation declined' || {
    echo "Step 8 no longer records the sandbox recommendation" >&2
    return 1
  }
}

@test "gaia-init.md runs no per-machine step and keeps its project decisions" {
  check_no_setup_step "$INIT_MD"
}

@test "the no-per-machine-step check fails for each needle appended to a scratch copy" {
  local scratch="$BATS_TEST_TMPDIR/gaia-init.scratch.md" needle ran=0
  [ "${#SETUP_STEP_NEEDLES[@]}" -gt 0 ]
  for needle in "${SETUP_STEP_NEEDLES[@]}"; do
    cp "$INIT_MD" "$scratch"
    printf '\n%s\n' "$needle" >>"$scratch"
    run check_no_setup_step "$scratch"
    [ "$status" -ne 0 ]
    grep -qF "names a per-machine step: ${needle}" <<<"$output" || return 1
    ran=$((ran + 1))
  done
  [ "$ran" -eq "${#SETUP_STEP_NEEDLES[@]}" ]
}

@test "the no-per-machine-step check fails when Step 6 stops bootstrapping .env" {
  local scratch="$BATS_TEST_TMPDIR/gaia-init.scratch.md"
  grep -vF -- '.gaia/cli/gaia init bootstrap-env' "$INIT_MD" >"$scratch" || true
  cmp -s "$INIT_MD" "$scratch" && return 1
  run check_no_setup_step "$scratch"
  [ "$status" -ne 0 ]
  grep -qF 'Step 6 no longer bootstraps .env' <<<"$output"
}

@test "the no-per-machine-step check fails when Step 8 stops recording the sandbox recommendation" {
  local scratch="$BATS_TEST_TMPDIR/gaia-init.scratch.md"
  grep -vF -- 'gaia setup record sandbox-recommendation declined' "$INIT_MD" >"$scratch" || true
  cmp -s "$INIT_MD" "$scratch" && return 1
  run check_no_setup_step "$scratch"
  [ "$status" -ne 0 ]
  grep -qF 'Step 8 no longer records the sandbox recommendation' <<<"$output"
}

# ---------------------------------------------------------------------------
# No exit, restart or reload wording
# ---------------------------------------------------------------------------

# check_no_restart <init>: init never tells the user to leave Claude, start it
# again or reload plugins; the whole onboarding is one session.
check_no_restart() {
  if grep -qiE 'exit claude|start claude again|restart claude|reload-plugins' "$1"; then
    echo "the init command tells the user to exit, restart or reload Claude" >&2
    return 1
  fi
  if grep -qF -- 'cd <project-folder-name>' "$1"; then
    echo "the init command prints a cd line for the user" >&2
    return 1
  fi
}

@test "gaia-init.md asks for no exit, restart or reload" {
  check_no_restart "$INIT_MD"
}

@test "the no-restart check fails when the old closing message comes back" {
  local scratch="$BATS_TEST_TMPDIR/gaia-init.scratch.md"
  cp "$INIT_MD" "$scratch"
  printf '\n> <Project Title> is ready for development. Exit Claude, then from your terminal:\n>\n> cd <project-folder-name>\n' >>"$scratch"
  run check_no_restart "$scratch"
  [ "$status" -ne 0 ]
  grep -qF 'exit, restart or reload Claude' <<<"$output"
}

@test "the no-restart check fails on a bare cd line" {
  local scratch="$BATS_TEST_TMPDIR/gaia-init.scratch.md"
  cp "$INIT_MD" "$scratch"
  printf '\ncd <project-folder-name>\n' >>"$scratch"
  run check_no_restart "$scratch"
  [ "$status" -ne 0 ]
  grep -qF 'prints a cd line' <<<"$output"
}

@test "the no-restart check fails when a reload instruction comes back" {
  local scratch="$BATS_TEST_TMPDIR/gaia-init.scratch.md"
  cp "$INIT_MD" "$scratch"
  printf '\nType /reload-plugins --force\n' >>"$scratch"
  run check_no_restart "$scratch"
  [ "$status" -ne 0 ]
  grep -qF 'exit, restart or reload Claude' <<<"$output"
}

# ---------------------------------------------------------------------------
# Step 10 finalizes, Step 11 hands off and its read of setup comes last
# ---------------------------------------------------------------------------

SETUP_READ='Read `.claude/commands/setup-gaia.md` now'

# check_handoff_order <init>: Step 10 runs init finalize before its commit,
# Step 11 follows it with its four subsections in order, and the read of the
# setup command is the last non-blank line of Step 11 and appears nowhere else.
check_handoff_order() {
  local file="$1" step10 step11 finalize_call commit_heading ten_line eleven_line
  local previous=0 heading position total inside last
  step10="$(section_of "$file" '## Step 10: Finalize')"
  [ -n "$step10" ] || {
    echo "the Step 10 section is absent" >&2
    return 1
  }
  finalize_call="$(grep -nF -- '.gaia/cli/gaia init finalize' <<<"$step10" | head -n 1 | cut -d: -f1)"
  commit_heading="$(grep -nF -- '### Commit the init output' <<<"$step10" | head -n 1 | cut -d: -f1)"
  { [ -n "$finalize_call" ] && [ -n "$commit_heading" ] && [ "$finalize_call" -lt "$commit_heading" ]; } || {
    echo "Step 10 does not run init finalize before the commit" >&2
    return 1
  }
  step11="$(section_of "$file" '## Step 11: Continue into /setup-gaia')"
  [ -n "$step11" ] || {
    echo "the Step 11 section is absent" >&2
    return 1
  }
  ten_line="$(grep -nF -- '## Step 10: Finalize' "$file" | head -n 1 | cut -d: -f1)"
  eleven_line="$(grep -nF -- '## Step 11: Continue into /setup-gaia' "$file" | head -n 1 | cut -d: -f1)"
  [ "$eleven_line" -gt "$ten_line" ] || {
    echo "Step 11 does not come after Step 10" >&2
    return 1
  }
  for heading in '### Send the adoption ping' '### Stop on an uncommitted init' '### CODEOWNERS follow-up' '### Hand off to /setup-gaia'; do
    position="$(grep -nF -- "$heading" <<<"$step11" | head -n 1 | cut -d: -f1)"
    { [ -n "$position" ] && [ "$position" -gt "$previous" ]; } || {
      echo "the Step 11 subsections are out of order at: ${heading}" >&2
      return 1
    }
    previous="$position"
  done
  total="$(grep -cF -- "$SETUP_READ" "$file" || true)"
  inside="$(grep -cF -- "$SETUP_READ" <<<"$step11" || true)"
  [ "$total" = "$inside" ] || {
    echo "the setup-gaia read appears outside Step 11" >&2
    return 1
  }
  [ "$inside" = 1 ] || {
    echo "Step 11 reads the setup command ${inside} times" >&2
    return 1
  }
  last="$(grep -v '^[[:space:]]*$' <<<"$step11" | tail -n 1)"
  case "$last" in
    *"$SETUP_READ"*) ;;
    *)
      echo "the setup-gaia read is not the last line of Step 11" >&2
      return 1
      ;;
  esac
}

@test "gaia-init.md finalizes in Step 10 and ends Step 11 on the read of the setup command" {
  check_handoff_order "$INIT_MD"
}

@test "the handoff-order check fails when the read moves above the ping" {
  local scratch="$BATS_TEST_TMPDIR/gaia-init.scratch.md" dropped="$BATS_TEST_TMPDIR/dropped.md" line
  line="$(grep -F -- "$SETUP_READ" "$INIT_MD")"
  [ -n "$line" ]
  drop_line "$INIT_MD" "$dropped" "$line"
  insert_before "$dropped" "$scratch" "$line" '### Send the adoption ping'
  cmp -s "$INIT_MD" "$scratch" && return 1
  run check_handoff_order "$scratch"
  [ "$status" -ne 0 ]
  grep -qF 'not the last line of Step 11' <<<"$output"
}

@test "the handoff-order check fails when the read is duplicated into Step 9" {
  local scratch="$BATS_TEST_TMPDIR/gaia-init.scratch.md" line
  line="$(grep -F -- "$SETUP_READ" "$INIT_MD")"
  [ -n "$line" ]
  insert_after "$INIT_MD" "$scratch" "$line" '## Step 9:'
  cmp -s "$INIT_MD" "$scratch" && return 1
  run check_handoff_order "$scratch"
  [ "$status" -ne 0 ]
  grep -qF 'appears outside Step 11' <<<"$output"
}

@test "the handoff-order check fails when the ping and the uncommitted stop swap places" {
  local scratch="$BATS_TEST_TMPDIR/gaia-init.scratch.md"
  sed -e 's/^### Send the adoption ping$/### SWAP-MARKER/' \
    -e 's/^### Stop on an uncommitted init$/### Send the adoption ping/' \
    -e 's/^### SWAP-MARKER$/### Stop on an uncommitted init/' "$INIT_MD" >"$scratch"
  cmp -s "$INIT_MD" "$scratch" && return 1
  run check_handoff_order "$scratch"
  [ "$status" -ne 0 ]
  grep -qF 'subsections are out of order' <<<"$output"
}

@test "the handoff-order check fails when Step 10 loses its init finalize call" {
  local scratch="$BATS_TEST_TMPDIR/gaia-init.scratch.md"
  grep -vF -- '.gaia/cli/gaia init finalize' "$INIT_MD" >"$scratch" || true
  cmp -s "$INIT_MD" "$scratch" && return 1
  run check_handoff_order "$scratch"
  [ "$status" -ne 0 ]
  grep -qF 'does not run init finalize before the commit' <<<"$output"
}

# ---------------------------------------------------------------------------
# RECONFIGURE false and the halt rule
# ---------------------------------------------------------------------------

HANDOFF_PHRASES=(
  'Setup is now running: GAIA continues with /setup-gaia in this session. After your first push'
  'with `RECONFIGURE` false'
  'no `$ARGUMENTS` substitution'
  "Automatic included, covered init's questions only"
  'repo connect question is always asked'
  're-run `/setup-gaia`, never `gaia init resume`'
)

GATE_PHRASES=(
  'every one of its own setup questions'
  'The GitHub connect question that follows is still asked.'
)

# check_handoff_contract <init>: the hand-off section carries the handoff line,
# the RECONFIGURE note and the halt rule, and the run-mode gate's Automatic
# option says the repo connect question is still asked.
check_handoff_contract() {
  local file="$1" handoff gate phrase
  handoff="$(section_of "$file" '### Hand off to /setup-gaia')"
  gate="$(section_of "$file" '### Run mode, the first gate')"
  [ -n "$handoff" ] || {
    echo "the hand-off section is absent" >&2
    return 1
  }
  [ -n "$gate" ] || {
    echo "the run-mode gate section is absent" >&2
    return 1
  }
  for phrase in "${HANDOFF_PHRASES[@]}"; do
    grep -qF -- "$phrase" <<<"$handoff" || {
      echo "the hand-off section lacks: ${phrase}" >&2
      return 1
    }
  done
  for phrase in "${GATE_PHRASES[@]}"; do
    grep -qF -- "$phrase" <<<"$gate" || {
      echo "the run-mode gate lacks: ${phrase}" >&2
      return 1
    }
  done
}

@test "gaia-init.md hands off with RECONFIGURE false and the halt rule" {
  check_handoff_contract "$INIT_MD"
}

@test "the handoff-contract check fails for each phrase removed from a scratch copy" {
  local scratch="$BATS_TEST_TMPDIR/gaia-init.scratch.md" phrase ran=0 expected
  expected=$((${#HANDOFF_PHRASES[@]} + ${#GATE_PHRASES[@]}))
  [ "$expected" -gt 0 ]
  for phrase in "${HANDOFF_PHRASES[@]}" "${GATE_PHRASES[@]}"; do
    remove_text "$INIT_MD" "$scratch" "$phrase"
    cmp -s "$INIT_MD" "$scratch" && return 1
    run check_handoff_contract "$scratch"
    [ "$status" -ne 0 ]
    grep -qF "lacks: ${phrase}" <<<"$output" || return 1
    ran=$((ran + 1))
  done
  [ "$ran" -eq "$expected" ]
}

# ---------------------------------------------------------------------------
# The setup-running marker
# ---------------------------------------------------------------------------

RUNNING_MARKER_TOUCH='mkdir -p .gaia/local && touch .gaia/local/setup-running'
RUNNING_MARKER_REMOVE='rm -f .gaia/local/setup-running'

# check_running_marker <init>: Step 10 touches the marker on a line before the
# finalize call, and the uncommitted-init stop removes it.
check_running_marker() {
  local file="$1" step stop touch_line finalize_line
  step="$(section_of "$file" '## Step 10: Finalize')"
  stop="$(section_of "$file" '### Stop on an uncommitted init')"
  touch_line="$(grep -nxF -- "$RUNNING_MARKER_TOUCH" <<<"$step" | head -n 1 | cut -d: -f1)"
  finalize_line="$(grep -nxF -- '.gaia/cli/gaia init finalize' <<<"$step" | head -n 1 | cut -d: -f1)"
  [ -n "$touch_line" ] || {
    echo "Step 10 does not touch the setup-running marker" >&2
    return 1
  }
  [ -n "$finalize_line" ] || {
    echo "Step 10 has no finalize call" >&2
    return 1
  }
  [ "$touch_line" -lt "$finalize_line" ] || {
    echo "Step 10 touches the marker after finalize" >&2
    return 1
  }
  grep -qxF -- "$RUNNING_MARKER_REMOVE" <<<"$stop" || {
    echo "the uncommitted-init stop does not remove the marker" >&2
    return 1
  }
}

@test "gaia-init.md marks setup running before finalize and clears it on the uncommitted stop" {
  check_running_marker "$INIT_MD"
}

@test "the running-marker check fails when the touch, its order, or the removal is broken" {
  local scratch="$BATS_TEST_TMPDIR/gaia-init.scratch.md"
  drop_line "$INIT_MD" "$scratch" "$RUNNING_MARKER_TOUCH"
  cmp -s "$INIT_MD" "$scratch" && return 1
  run check_running_marker "$scratch"
  [ "$status" -ne 0 ]
  grep -qF 'does not touch the setup-running marker' <<<"$output"

  drop_line "$INIT_MD" "$scratch" "$RUNNING_MARKER_REMOVE"
  cmp -s "$INIT_MD" "$scratch" && return 1
  run check_running_marker "$scratch"
  [ "$status" -ne 0 ]
  grep -qF 'does not remove the marker' <<<"$output"

  # Order: the touch moved to just after the finalize call.
  awk -v touch="$RUNNING_MARKER_TOUCH" '
    $0 == touch { next }
    { print }
    $0 == ".gaia/cli/gaia init finalize" { print touch }
  ' "$INIT_MD" > "$scratch"
  cmp -s "$INIT_MD" "$scratch" && return 1
  run check_running_marker "$scratch"
  [ "$status" -ne 0 ]
  grep -qF 'touches the marker after finalize' <<<"$output"
}

# ---------------------------------------------------------------------------
# The wiki log claims no install
# ---------------------------------------------------------------------------

LOG_TOOLS=('React Doctor' 'Playwright CLI' 'typescript-lsp')

# wiki_log_block <init>: the lines of the fenced log block under Step 9,
# between its opening and closing fence.
wiki_log_block() {
  section_of "$1" '## Step 9: Refresh the wiki' | awk '
    /^```/ { fences++; if (fences == 1) { on = 1; next } exit }
    on { print }
  '
}

# check_no_install_claim <init>: init's log entry names no tool: the install
# belongs to the setup command now.
check_no_install_claim() {
  local block tool
  block="$(wiki_log_block "$1")"
  grep -qF -- '## [<TODAY>] /gaia-init | project initialized' <<<"$block" || {
    echo "the wiki log block is absent" >&2
    return 1
  }
  for tool in "${LOG_TOOLS[@]}"; do
    if grep -qF -- "$tool" <<<"$block"; then
      echo "the wiki log block names ${tool}" >&2
      return 1
    fi
  done
}

@test "gaia-init.md's wiki log block claims no installed tool" {
  check_no_install_claim "$INIT_MD"
}

@test "the no-install-claim check fails for each tool put back into the log block" {
  local scratch="$BATS_TEST_TMPDIR/gaia-init.scratch.md" tool ran=0
  [ "${#LOG_TOOLS[@]}" -gt 0 ]
  for tool in "${LOG_TOOLS[@]}"; do
    insert_after "$INIT_MD" "$scratch" "- Installed: ${tool}" '- Removed: GAIA branding'
    cmp -s "$INIT_MD" "$scratch" && return 1
    run check_no_install_claim "$scratch"
    [ "$status" -ne 0 ]
    grep -qF "the wiki log block names ${tool}" <<<"$output" || return 1
    ran=$((ran + 1))
  done
  [ "$ran" -eq "${#LOG_TOOLS[@]}" ]
}

# ---------------------------------------------------------------------------
# The resume section
# ---------------------------------------------------------------------------

# check_resume_section <init>: the resume section names no Step 8 install and
# says the run continues through Step 11.
check_resume_section() {
  local section
  section="$(section_of "$1" '## On failure: resume')"
  [ -n "$section" ] || {
    echo "the resume section is absent" >&2
    return 1
  }
  if grep -qF -- 'Step 8' <<<"$section"; then
    echo "the resume section names Step 8" >&2
    return 1
  fi
  if grep -qi -- 'install' <<<"$section"; then
    echo "the resume section mentions an install" >&2
    return 1
  fi
  grep -qF -- 'continues with the remaining steps through Step 11' <<<"$section" || {
    echo "the resume section lacks the continue sentence" >&2
    return 1
  }
}

@test "gaia-init.md's resume section has no install and continues through Step 11" {
  check_resume_section "$INIT_MD"
}

@test "the resume check fails when the Step 8 install sentence comes back" {
  local scratch="$BATS_TEST_TMPDIR/gaia-init.scratch.md"
  insert_after "$INIT_MD" "$scratch" 'A failed Step 8 install is re-run first.' 'If any `gaia init <step>` invocation'
  cmp -s "$INIT_MD" "$scratch" && return 1
  run check_resume_section "$scratch"
  [ "$status" -ne 0 ]
  grep -qF 'the resume section names Step 8' <<<"$output"
}

@test "the resume check fails when the continue sentence is removed" {
  local scratch="$BATS_TEST_TMPDIR/gaia-init.scratch.md"
  remove_text "$INIT_MD" "$scratch" 'continues with the remaining steps through Step 11'
  cmp -s "$INIT_MD" "$scratch" && return 1
  run check_resume_section "$scratch"
  [ "$status" -ne 0 ]
  grep -qF 'lacks the continue sentence' <<<"$output"
}

# check_no_dependency_update <file>: init leaves the bundle's lockfile as
# shipped. No step before Step 11 names /update-deps (Step 11's handoff points
# at it, so it must), nothing busts the update-check cache, and Chromium is
# installed in Step 1 and not again in Step 7, since with no update Playwright
# cannot change between the two.
check_no_dependency_update() {
  awk '
    /^## / { section = $0 }
    /update-check-bust\.sh/ { print "gaia-init.md busts the update-check cache"; failed = 1 }
    section ~ /^## Step (0|1|2|3|4|5|6|7|8|9|10):/ && /\/update-deps/ {
      print "a step before Step 11 names /update-deps"; failed = 1
    }
    section ~ /^## Step 11:/ && /\/update-deps/ { closing = 1 }
    /playwright install chromium/ {
      if (section ~ /^## Step 1:/) step1 = 1
      if (section ~ /^## Step 7:/) { print "Step 7 installs Chromium again"; failed = 1 }
    }
    END {
      if (!step1) { print "Step 1 installs no Chromium"; failed = 1 }
      if (!closing) { print "Step 11 does not point at /update-deps"; failed = 1 }
      exit failed
    }
  ' "$1"
}

@test "gaia-init.md updates no dependencies and installs Chromium once" {
  check_no_dependency_update "$INIT_MD"
}

@test "the no-update check fails when Step 1 runs /update-deps again" {
  local scratch="$BATS_TEST_TMPDIR/gaia-init.scratch.md"
  awk '{ print } /^## Step 1:/ { print "Then run `/update-deps` to bring all packages to their latest compatible versions." }' "$INIT_MD" >"$scratch"
  cmp -s "$INIT_MD" "$scratch" && return 1
  run check_no_dependency_update "$scratch"
  [ "$status" -ne 0 ]
  grep -qF 'a step before Step 11 names /update-deps' <<<"$output"
}

@test "the no-update check fails when the update-check cache bust returns" {
  local scratch="$BATS_TEST_TMPDIR/gaia-init.scratch.md"
  awk '/^## Step 2:/ { print "bash .gaia/scripts/update-check-bust.sh --mode deps" } { print }' "$INIT_MD" >"$scratch"
  cmp -s "$INIT_MD" "$scratch" && return 1
  run check_no_dependency_update "$scratch"
  [ "$status" -ne 0 ]
  grep -qF 'busts the update-check cache' <<<"$output"
}

@test "the no-update check fails when Step 7 installs Chromium again" {
  local scratch="$BATS_TEST_TMPDIR/gaia-init.scratch.md"
  sed 's/^pnpm typecheck && /pnpm -C frontend exec playwright install chromium \&\& pnpm typecheck \&\& /' "$INIT_MD" >"$scratch"
  cmp -s "$INIT_MD" "$scratch" && return 1
  run check_no_dependency_update "$scratch"
  [ "$status" -ne 0 ]
  grep -qF 'Step 7 installs Chromium again' <<<"$output"
}

@test "the no-update check fails when Step 1 drops its Chromium install" {
  local scratch="$BATS_TEST_TMPDIR/gaia-init.scratch.md"
  grep -vF -- 'playwright install chromium' "$INIT_MD" >"$scratch" || true
  cmp -s "$INIT_MD" "$scratch" && return 1
  run check_no_dependency_update "$scratch"
  [ "$status" -ne 0 ]
  grep -qF 'Step 1 installs no Chromium' <<<"$output"
}

@test "the no-update check fails when the handoff drops its /update-deps pointer" {
  local scratch="$BATS_TEST_TMPDIR/gaia-init.scratch.md"
  awk '/^## / { inside = ($0 ~ /^## Step 11:/) } inside && /\/update-deps/ { next } { print }' "$INIT_MD" >"$scratch"
  cmp -s "$INIT_MD" "$scratch" && return 1
  run check_no_dependency_update "$scratch"
  [ "$status" -ne 0 ]
  grep -qF 'Step 11 does not point at /update-deps' <<<"$output"
}
