#!/usr/bin/env bats
#
# Doc-conformance suite for /gaia-init (.claude/commands/gaia-init.md): its
# resume step list names the same steps, in the same order, as the CLI's
# STEP_ORDER. It also pins the single-session shape: the command seeds
# apps/web/.env in Step 9 before finalize (never with cp); Step 9 runs the
# Quality Gate after the seed and before finalize, and the gate page lets that
# commit skip the Commit/Hold stop; Step 9 finalizes and Step 10 ends on the
# read of the setup command; the resume section names no install; and it
# updates no dependencies, installing Chromium once.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  INIT_MD="$REPO_ROOT/.claude/commands/gaia-init.md"
  STATE_TS="$REPO_ROOT/.gaia/cli/src/init/util/state.ts"
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

# ---------------------------------------------------------------------------
# Section helper
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

# ---------------------------------------------------------------------------
# Init seeds apps/web/.env before finalize and its commit
# ---------------------------------------------------------------------------

SEED_ENV_CALL='.gaia/cli/gaia setup bootstrap-env'

# check_env_seeded <init>: the seed call is the only line naming it, sits in
# Step 9 before the finalize call (so a failed seed stops while the resume
# cursor still exists, and before the commit's Quality Gate needs the file),
# and no line copies onto the .env with `cp`, which the Edit deny refuses.
check_env_seeded() {
  local file="$1" step seed_line finalize_line
  [ "$(grep -cF -- "$SEED_ENV_CALL" "$file" || true)" = 1 ] || {
    echo "the init command does not name the seed call exactly once" >&2
    return 1
  }
  step="$(section_of "$file" '## Step 9: Finalize')"
  seed_line="$(grep -nxF -- "$SEED_ENV_CALL" <<<"$step" | head -n 1 | cut -d: -f1)"
  finalize_line="$(grep -nxF -- '.gaia/cli/gaia init finalize' <<<"$step" | head -n 1 | cut -d: -f1)"
  { [ -n "$seed_line" ] && [ -n "$finalize_line" ] && [ "$seed_line" -lt "$finalize_line" ]; } || {
    echo "Step 9 does not seed .env before init finalize" >&2
    return 1
  }
  if grep -qE '(^|[^[:alnum:]_])cp [^`]*\.env' "$file"; then
    echo "the init command copies onto .env with cp" >&2
    return 1
  fi
}

@test "gaia-init.md seeds apps/web/.env in Step 9 before finalize, never with cp" {
  check_env_seeded "$INIT_MD"
}

# ---------------------------------------------------------------------------
# Init's commit goes through the Quality Gate
# ---------------------------------------------------------------------------

GATE_PAGE_PATH='wiki/decisions/Quality Gate.md'
RUNNING_MARKER_CALL='mkdir -p .gaia/local && touch .gaia/local/setup-running'

# check_gate_before_commit <init>: Step 9 sends Claude to the gate page on a
# line after the .env seed (E2E and the dev smoke need the file) and before
# the setup-running marker and init finalize, so a gate that does not pass
# stops the run while the resume cursor still exists, ahead of the commit.
check_gate_before_commit() {
  local file="$1" step gate_line seed_line marker_line finalize_line
  step="$(section_of "$file" '## Step 9: Finalize')"
  gate_line="$(grep -nF -- "\`$GATE_PAGE_PATH\`" <<<"$step" | head -n 1 | cut -d: -f1)"
  seed_line="$(grep -nxF -- "$SEED_ENV_CALL" <<<"$step" | head -n 1 | cut -d: -f1)"
  marker_line="$(grep -nxF -- "$RUNNING_MARKER_CALL" <<<"$step" | head -n 1 | cut -d: -f1)"
  finalize_line="$(grep -nxF -- '.gaia/cli/gaia init finalize' <<<"$step" | head -n 1 | cut -d: -f1)"
  { [ -n "$seed_line" ] && [ -n "$marker_line" ] && [ -n "$finalize_line" ]; } || {
    echo "Step 9 lacks the seed, marker or finalize call this check orders against" >&2
    return 1
  }
  { [ -n "$gate_line" ] && [ "$seed_line" -lt "$gate_line" ] &&
    [ "$gate_line" -lt "$marker_line" ] && [ "$gate_line" -lt "$finalize_line" ]; } || {
    echo "Step 9 does not run the Quality Gate between the .env seed and the marker" >&2
    return 1
  }
}

@test "gaia-init.md runs the Quality Gate in Step 9 after the .env seed and before finalize" {
  check_gate_before_commit "$INIT_MD"
}

# check_gate_lists_init <gate page>: the gate's stop-and-report step lists
# /gaia-init's commit among the workflows that commit without the Commit/Hold
# stop; without it, the gate would stop init on a Commit/Hold question its own
# commit step never asks.
check_gate_lists_init() {
  grep -E '^10\. \*\*Stop and report\*\*' "$1" | grep -qF -- '`/gaia-init`' || {
    echo "the gate page's step 10 does not list /gaia-init's commit" >&2
    return 1
  }
}

@test "the Quality Gate page's step 10 lists /gaia-init's init commit" {
  check_gate_lists_init "$REPO_ROOT/$GATE_PAGE_PATH"
}

# ---------------------------------------------------------------------------
# Step 9 finalizes, Step 10 hands off and its read of setup comes last
# ---------------------------------------------------------------------------

SETUP_READ='Read `.claude/commands/setup-gaia.md` now'

# check_handoff_order <init>: Step 9 runs init finalize before its commit,
# Step 10 follows it with its four subsections in order, and the read of the
# setup command is the last non-blank line of Step 10 and appears nowhere else.
check_handoff_order() {
  local file="$1" step_finalize step_handoff finalize_call commit_heading ten_line eleven_line
  local previous=0 heading position total inside last
  step_finalize="$(section_of "$file" '## Step 9: Finalize')"
  [ -n "$step_finalize" ] || {
    echo "the Step 9 section is absent" >&2
    return 1
  }
  finalize_call="$(grep -nF -- '.gaia/cli/gaia init finalize' <<<"$step_finalize" | head -n 1 | cut -d: -f1)"
  commit_heading="$(grep -nF -- '### Commit the init output' <<<"$step_finalize" | head -n 1 | cut -d: -f1)"
  { [ -n "$finalize_call" ] && [ -n "$commit_heading" ] && [ "$finalize_call" -lt "$commit_heading" ]; } || {
    echo "Step 9 does not run init finalize before the commit" >&2
    return 1
  }
  step_handoff="$(section_of "$file" '## Step 10: Continue into /setup-gaia')"
  [ -n "$step_handoff" ] || {
    echo "the Step 10 section is absent" >&2
    return 1
  }
  ten_line="$(grep -nF -- '## Step 9: Finalize' "$file" | head -n 1 | cut -d: -f1)"
  eleven_line="$(grep -nF -- '## Step 10: Continue into /setup-gaia' "$file" | head -n 1 | cut -d: -f1)"
  [ "$eleven_line" -gt "$ten_line" ] || {
    echo "Step 10 does not come after Step 9" >&2
    return 1
  }
  for heading in '### Send the adoption ping' '### Stop on an uncommitted init' '### CODEOWNERS follow-up' '### Hand off to /setup-gaia'; do
    position="$(grep -nF -- "$heading" <<<"$step_handoff" | head -n 1 | cut -d: -f1)"
    { [ -n "$position" ] && [ "$position" -gt "$previous" ]; } || {
      echo "the Step 10 subsections are out of order at: ${heading}" >&2
      return 1
    }
    previous="$position"
  done
  total="$(grep -cF -- "$SETUP_READ" "$file" || true)"
  inside="$(grep -cF -- "$SETUP_READ" <<<"$step_handoff" || true)"
  [ "$total" = "$inside" ] || {
    echo "the setup-gaia read appears outside Step 10" >&2
    return 1
  }
  [ "$inside" = 1 ] || {
    echo "Step 10 reads the setup command ${inside} times" >&2
    return 1
  }
  last="$(grep -v '^[[:space:]]*$' <<<"$step_handoff" | tail -n 1)"
  case "$last" in
    *"$SETUP_READ"*) ;;
    *)
      echo "the setup-gaia read is not the last line of Step 10" >&2
      return 1
      ;;
  esac
}

@test "gaia-init.md finalizes in Step 9 and ends Step 10 on the read of the setup command" {
  check_handoff_order "$INIT_MD"
}

# ---------------------------------------------------------------------------
# The resume section
# ---------------------------------------------------------------------------

# check_resume_section <init>: the resume section names no Step 7 install and
# says the run continues through Step 10.
check_resume_section() {
  local section
  section="$(section_of "$1" '## On failure: resume')"
  [ -n "$section" ] || {
    echo "the resume section is absent" >&2
    return 1
  }
  if grep -qF -- 'Step 7' <<<"$section"; then
    echo "the resume section names Step 7" >&2
    return 1
  fi
  if grep -qi -- 'install' <<<"$section"; then
    echo "the resume section mentions an install" >&2
    return 1
  fi
  grep -qF -- 'continues with the remaining steps through Step 10' <<<"$section" || {
    echo "the resume section lacks the continue sentence" >&2
    return 1
  }
}

@test "gaia-init.md's resume section has no install and continues through Step 10" {
  check_resume_section "$INIT_MD"
}

# check_no_dependency_update <file>: init leaves the bundle's lockfile as
# shipped. No step before Step 10 names /update-deps (Step 10's handoff points
# at it, so it must), nothing busts the update-check cache, and Chromium is
# installed in Step 1 and not again in Step 6, since with no update Playwright
# cannot change between the two.
check_no_dependency_update() {
  awk '
    /^## / { section = $0 }
    /update-check-bust\.sh/ { print "gaia-init.md busts the update-check cache"; failed = 1 }
    section ~ /^## Step (0|1|2|3|4|5|6|7|8|9):/ && /\/update-deps/ {
      print "a step before Step 10 names /update-deps"; failed = 1
    }
    section ~ /^## Step 10:/ && /\/update-deps/ { closing = 1 }
    /playwright install chromium/ {
      if (section ~ /^## Step 1:/) step1 = 1
      if (section ~ /^## Step 6:/) { print "Step 6 installs Chromium again"; failed = 1 }
    }
    END {
      if (!step1) { print "Step 1 installs no Chromium"; failed = 1 }
      if (!closing) { print "Step 10 does not point at /update-deps"; failed = 1 }
      exit failed
    }
  ' "$1"
}

@test "gaia-init.md updates no dependencies and installs Chromium once" {
  check_no_dependency_update "$INIT_MD"
}

