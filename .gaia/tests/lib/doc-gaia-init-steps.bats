#!/usr/bin/env bats
#
# Doc-conformance suite for /gaia-init (.claude/commands/gaia-init.md): the
# command asks no CI-intent or wiki-mode question, writes the project settings
# through `gaia init write-project-config`, and its resume step list names the
# same steps, in the same order, as the CLI's STEP_ORDER. It also pins the
# shared-reference shape: the command reads exactly the per-machine,
# isolation-question and sandbox-recommendation references, lists them in its
# references block, and the setup command reads each too (finalize deletes only this command); it has no
# lettered sub-steps; and it finalizes with the plain setup finalize call.
#
# Forbidden tokens that the repo-wide absence guard also forbids are built at
# runtime, so this file never carries the literal. Each absence check is proven
# able to fail: a scratch copy of the command gets the forbidden content
# re-inserted and the check must flag it.

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

# Fixed-string forbidden tokens, one per line. The runtime-built ones are the
# tokens the repo-wide absence guard forbids as literals.
forbidden_tokens() {
  printf '%s\n' \
    "$(printf 'configure%sautomation' -)" \
    "$(printf 'automation%sjson' .)" \
    "$(printf 'docs.gaiareact.com/maintenance/gaia%sci' -)" \
    'Configure CI integrations' \
    'GAIA CI' \
    'default_mode' \
    '--wiki' \
    'CI_CATEGORY' \
    '--ci' \
    'Sets `wiki`' \
    '`ci` / `local` / `off`'
}

# Print each forbidden token found in the file given as $1.
violations() {
  local file="$1" token
  while IFS= read -r token; do
    if grep -qF -- "$token" "$file"; then
      printf '%s\n' "$token"
    fi
  done < <(forbidden_tokens)
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

@test "gaia-init.md carries none of the CI-question tokens" {
  run violations "$INIT_MD"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "the absence check flags every forbidden token re-inserted into a scratch copy" {
  local token scratch
  while IFS= read -r token; do
    scratch="$BATS_TEST_TMPDIR/gaia-init.scratch.md"
    cp "$INIT_MD" "$scratch"
    printf '\n%s\n' "$token" >>"$scratch"
    run violations "$scratch"
    [ "$output" = "$token" ] || {
      printf 'token not flagged: %s (got: %s)\n' "$token" "$output" >&2
      return 1
    }
  done < <(forbidden_tokens)
}

@test "gaia-init.md calls write-project-config with --sandbox-recommended" {
  grep -qF 'gaia init write-project-config' "$INIT_MD"
  grep -qF -- '--sandbox-recommended <true|false>' "$INIT_MD"
}

@test "gaia-init.md keeps the isolation-policy omission rule" {
  grep -qF -- '[--isolation-policy <always-worktree|prefer-worktree|prefer-branch>]' "$INIT_MD"
  grep -qF -- 'omit the flag entirely' "$INIT_MD"
}

@test "the writer check fails when the writer call is removed from a scratch copy" {
  local scratch="$BATS_TEST_TMPDIR/gaia-init.scratch.md"
  grep -vF 'gaia init write-project-config' "$INIT_MD" >"$scratch"
  run grep -qF 'gaia init write-project-config' "$scratch"
  [ "$status" -ne 0 ]
}

@test "the resume list names exactly the frozen steps, 1-indexed, in order" {
  [ "$(resume_steps "$INIT_MD")" = "$FROZEN_STEPS" ]
  [ "$(resume_indices "$INIT_MD")" = "1 2 3 4 5 6 7 8" ]
}

@test "the resume list agrees with STEP_ORDER in state.ts" {
  [ "$(state_steps)" = "$(resume_steps "$INIT_MD")" ]
}

@test "the resume check fails on a reordered scratch copy" {
  local scratch="$BATS_TEST_TMPDIR/gaia-init.scratch.md"
  sed -E 's/6=bootstrap-env, 7=write-project-config/6=write-project-config, 7=bootstrap-env/' "$INIT_MD" >"$scratch"
  [ "$(resume_steps "$scratch")" != "$FROZEN_STEPS" ]
}

@test "the adoption ping passes no --ci field" {
  grep -qF '.gaia/cli/gaia ping --event init --mode "$MODE" --i18n "$I18N_COUNT" || true' "$INIT_MD"
}

# Print Step 2 (from its heading to the Step 3 heading) of the file given as $1.
step_two() {
  awk '/^## Step 2:/{on=1} /^## Step 3:/{on=0} on' "$1"
}

# Print each data-layer anchor missing from the file given as $1, one per line.
data_layer_gaps() {
  local file="$1" label
  for label in 'camelCase (Recommended)' 'snake_case' 'Not sure' \
    'Add TanStack Query for client-owned data?' 'No (Recommended)'; do
    step_two "$file" | grep -qF -- "$label" || printf 'option: %s\n' "$label"
  done
  grep -qF '| Backend casing            | `camelCase`' "$file" || echo 'safe-default row: casing'
  grep -qF '| TanStack Query            | `No`' "$file" || echo 'safe-default row: query'
  grep -qF '> | Backend casing ' "$file" || echo 'automatic row: casing'
  grep -qF '> | TanStack Query ' "$file" || echo 'automatic row: query'
  grep -qF -- '- Backend casing (Step 2)' "$file" || echo 'automatic bullet: casing'
  grep -qF -- '- TanStack Query (Step 2)' "$file" || echo 'automatic bullet: query'
  grep -qE 'gaia init configure-data-layer --casing <CASING> --query <QUERY>' "$file" ||
    echo 'step 3 line'
  return 0
}

@test "gaia-init.md carries the data-layer questions, tier rows, defaults, and Step 3 call" {
  run data_layer_gaps "$INIT_MD"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "the data-layer check flags each anchor deleted from a scratch copy" {
  local pattern scratch
  for pattern in 'camelCase (Recommended)' 'Not sure' 'No (Recommended)' \
    '| Backend casing            | `camelCase`' '| TanStack Query            | `No`' \
    '> | Backend casing ' '> | TanStack Query ' '- Backend casing (Step 2)' \
    '- TanStack Query (Step 2)' 'configure-data-layer --casing'; do
    scratch="$BATS_TEST_TMPDIR/gaia-init.scratch.md"
    grep -vF -- "$pattern" "$INIT_MD" >"$scratch"
    run data_layer_gaps "$scratch"
    [ -n "$output" ] || {
      printf 'deleting %s was not flagged\n' "$pattern" >&2
      return 1
    }
  done
}

@test "Step 2 asks no rendering-mode question" {
  run bash -c "awk '/^## Step 2:/{on=1} /^## Step 3:/{on=0} on' '$INIT_MD' | grep -E 'SSR|SPA|prerender'"
  [ "$status" -ne 0 ]
}

@test "the rendering-mode check fails when a rendering question is added to a scratch Step 2" {
  local scratch="$BATS_TEST_TMPDIR/gaia-init.scratch.md"
  sed 's/^### Q7, TanStack Query (asked alone)/Pick SSR or SPA.\n&/' "$INIT_MD" >"$scratch"
  run bash -c "awk '/^## Step 2:/{on=1} /^## Step 3:/{on=0} on' '$scratch' | grep -E 'SSR|SPA|prerender'"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Shared references only
# ---------------------------------------------------------------------------

SHARED_REFERENCES="isolation-question.md per-machine.md sandbox-recommendation.md"

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

@test "the shared-reference check fails when the setup command stops naming isolation-question.md" {
  local scratch="$BATS_TEST_TMPDIR/setup-gaia.scratch.md"
  sed 's#references/setup/isolation-question\.md#references/setup/gone.md#g' "$SETUP_MD" >"$scratch"
  cmp -s "$SETUP_MD" "$scratch" && return 1
  run check_shared_references_only "$INIT_MD" "$scratch" "$REFERENCES_DIRECTORY"
  [ "$status" -ne 0 ]
  grep -qF 'no longer names isolation-question.md' <<<"$output"
}

@test "the shared-reference check fails when the references block drops a bullet" {
  local scratch="$BATS_TEST_TMPDIR/gaia-init.scratch.md"
  grep -v -- '^- `isolation-question.md`: ' "$INIT_MD" >"$scratch" || true
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
  cp "$REFERENCES_DIRECTORY/per-machine.md" "$directory/"
  run check_shared_references_only "$INIT_MD" "$SETUP_MD" "$directory"
  [ "$status" -ne 0 ]
  grep -qF 'a shared reference is absent' <<<"$output"
}

# ---------------------------------------------------------------------------
# No lettered sub-steps
# ---------------------------------------------------------------------------

# lettered_substeps <file>: print every step heading numbered with a letter
# suffix (for example a "10b." sub-step).
lettered_substeps() {
  grep -nE '^#{2,4} [0-9]+[a-z]\.' "$1" || true
}

@test "gaia-init.md has no lettered sub-step headings" {
  run lettered_substeps "$INIT_MD"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "the lettered sub-step check flags a re-inserted sub-step heading" {
  local scratch="$BATS_TEST_TMPDIR/gaia-init.scratch.md"
  cp "$INIT_MD" "$scratch"
  printf '\n### 10b. Overwrite\n' >>"$scratch"
  run lettered_substeps "$scratch"
  [ "$status" -eq 0 ]
  [ -n "$output" ]
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
