#!/usr/bin/env bats
# The closing message of /setup-gaia: Phase 6 of `.claude/commands/setup-gaia.md`
# routes to `## The closing message` in
# `.claude/skills/gaia/references/setup/land-decisions.md`, which prints the
# "You're all set" line only when no project setting this machine can act on
# is still owed, and a setup-not-finished line naming the re-run otherwise. A
# run whose GitHub setup was refused or skipped must not end on a line that
# reads as done, and the message reads the same predicate the statusline's
# setup nudge counts, so the two never disagree.
#
# The closing is a sequence of separate lines in a fixed order: the status
# line, the sandbox line (printed only under its condition), the auto-mode
# line, the fresh-context line and the docs line. The auto-mode line prints
# unconditionally, with wording true in any permission mode, because Claude's
# judgment of its own mode does not hold run to run. The sandbox line reads
# only this run's sandbox answer, never the sandbox marker, so a machine an
# earlier run enabled gets no sentence. No setup surface file tells the user
# to restart Claude Code or to reload plugins. Every changed check has a
# scratch-copy twin that puts the old content back or removes the new and
# asserts the named failure.
#
# Assertion style: .claude/rules/bats-assertions.md.

DONE_LINE="You're all set: your GAIA project is ready."
NOT_DONE_LINE="Setup isn't finished: these project settings are still owed: <the OWED_AT_END ids>. Fix what stopped them above, then re-run /setup-gaia; it resumes from the first owed step."
UNCHECKED_LINE="Your part of setup is done, but these project settings are still undecided: <the ADMIN_UNCHECKED_AT_END ids>. GAIA couldn't check whether you're a repository admin, because gh isn't signed in, GitHub didn't answer, or the repository didn't exist yet when setup checked. Re-run /setup-gaia (after gh auth login if gh isn't signed in), or ask a repository admin to run it on the default branch."
ADMIN_OWED_LINE="Your part of setup is done, but these project settings still need a repository admin: <the ADMIN_OWED_AT_END ids>. They stay unapplied until a repo admin runs /setup-gaia on the default branch, so ask one to."
DOCS_LINE='New to GAIA? The docs walk you through your first feature: https://docs.gaiaharness.com/getting-started/onboarding/'
FRESH_CONTEXT_LINE='Type /clear to start your first feature with a fresh context.'
SANDBOX_LINE='The sandbox you enabled takes effect from your next Claude Code session.'
SANDBOX_CONDITION="When \`SANDBOX_ANSWER\` is \`enable\`"
SANDBOX_BULLET="- ${SANDBOX_CONDITION} (this run's Phase 2 enabled the sandbox; a sandbox an earlier run enabled does not count): \`${SANDBOX_LINE}\`"
AUTO_MODE_LINE='If this session is in auto mode, press Shift+Tab to leave it, or start Claude with plain claude next time.'

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  PAGE="${REPO_ROOT}/.claude/commands/setup-gaia.md"
  REFERENCE="${REPO_ROOT}/.claude/skills/gaia/references/setup/land-decisions.md"
  local file
  for file in "$PAGE" "$REFERENCE"; do
    [ -f "$file" ] || {
      echo "the audited page is absent: ${file}" >&2
      return 1
    }
  done
  PHASE_SIX="$(section_of "$PAGE" '## Phase 6: Finalize')"
  CLOSING="$(section_of "$REFERENCE" '## The closing message')"
  [ -n "$PHASE_SIX" ] || {
    echo "Phase 6 of ${PAGE} is empty or missing" >&2
    return 1
  }
  [ -n "$CLOSING" ] || {
    echo "## The closing message of ${REFERENCE} is empty or missing" >&2
    return 1
  }
}

# section_of <file> <heading>: the lines under a "## " heading, up to the next one.
section_of() {
  awk -v heading="$2" '$0 == heading { inside = 1; next } inside && /^## / { exit } inside' "$1"
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

# check_closing_order <closing-text>: each status line is a whole line, the
# first occurrences strictly increase in the printed order, and the
# auto-mode, fresh-context and docs lines occur once.
check_closing_order() {
  local closing="$1" previous=0 position index count text
  local -a modes=(-xF -xF -xF -xF -F -xF -xF -xF)
  local -a texts=("$DONE_LINE" "$NOT_DONE_LINE" "$UNCHECKED_LINE" "$ADMIN_OWED_LINE" "$SANDBOX_LINE" "$AUTO_MODE_LINE" "$FRESH_CONTEXT_LINE" "$DOCS_LINE")
  for index in 0 1 2 3 4 5 6 7; do
    position="$(grep -n "${modes[$index]}" -- "${texts[$index]}" <<<"$closing" | head -n 1 | cut -d: -f1 || true)"
    [ -n "$position" ] || {
      echo "missing whole line: ${texts[$index]}" >&2
      return 1
    }
    [ "$position" -gt "$previous" ] || {
      echo "out of order: ${texts[$index]}" >&2
      return 1
    }
    previous="$position"
  done
  for text in "$AUTO_MODE_LINE" "$FRESH_CONTEXT_LINE" "$DOCS_LINE"; do
    count="$(grep -cxF -- "$text" <<<"$closing" || true)"
    [ "$count" = 1 ] || {
      echo "line occurs ${count} times, not once: ${text}" >&2
      return 1
    }
  done
  return 0
}

# check_conditional_line <closing-text> <sentence> <condition>: exactly one
# line carries the sentence, and that same line carries the condition.
check_conditional_line() {
  local closing="$1" sentence="$2" condition="$3" count line
  count="$(grep -cF -- "$sentence" <<<"$closing" || true)"
  [ "$count" = 1 ] || {
    echo "exactly one line must carry the sentence, found ${count}: ${sentence}" >&2
    return 1
  }
  line="$(grep -F -- "$sentence" <<<"$closing")"
  grep -qF -- "$condition" <<<"$line" || {
    echo "the sentence is not gated by its condition (${condition}): ${sentence}" >&2
    return 1
  }
  return 0
}

# check_unconditional_line <closing-text> <sentence>: the sentence is a whole
# line of its own, once, and no other line carries it (a condition bullet
# would).
check_unconditional_line() {
  local closing="$1" sentence="$2" whole any
  whole="$(grep -cxF -- "$sentence" <<<"$closing" || true)"
  any="$(grep -cF -- "$sentence" <<<"$closing" || true)"
  [ "$whole" = 1 ] || {
    echo "the sentence must be one whole line, found ${whole}: ${sentence}" >&2
    return 1
  }
  [ "$any" = 1 ] || {
    echo "the sentence also sits inside another line, so it is gated: ${sentence}" >&2
    return 1
  }
  return 0
}

# check_sandbox_gate <closing-text>: the sandbox sentence reads only this run's
# answer; the closing never names the sandbox marker or its outcome value.
check_sandbox_gate() {
  local closing="$1"
  grep -qF -- 'sandbox status' <<<"$closing" && {
    echo "the closing names the sandbox marker (sandbox status)" >&2
    return 1
  }
  grep -qF -- '`enabled`' <<<"$closing" && {
    echo "the closing reads the sandbox marker's outcome value" >&2
    return 1
  }
  check_conditional_line "$closing" "$SANDBOX_LINE" "$SANDBOX_CONDITION"
}

# check_no_restart_or_reload <page> <references-directory>: no line of the
# command or of any reference under the directory tells the user to restart
# Claude or reload plugins. The file list is derived from the directory and
# every file is asserted read.
check_no_restart_or_reload() {
  local page="$1" directory="$2" file files count=0
  files="$(find "$directory" -maxdepth 1 -name '*.md' | sort)"
  [ -n "$files" ] || {
    echo "no reference files found under ${directory}" >&2
    return 1
  }
  while IFS= read -r file; do
    [ -f "$file" ] || {
      echo "unreadable file: ${file}" >&2
      return 1
    }
    count=$((count + 1))
    grep -qE 'Restart Claude|restart Claude|reload-plugins' "$file" && {
      echo "restart or reload wording in ${file}" >&2
      return 1
    }
  done <<<"$(printf '%s\n%s\n' "$page" "$files")"
  [ "$count" -gt 1 ] || {
    echo "only ${count} file read" >&2
    return 1
  }
  return 0
}

# check_sandbox_answer_cached <page>: Phase 2 caches the sandbox answer for the
# closing message and says the answer stays unset on the two routes that ask
# nothing.
check_sandbox_answer_cached() {
  local phase_two
  phase_two="$(section_of "$1" '## Phase 2: Per-machine setup (skip if finalized and nothing is owed)')"
  [ -n "$phase_two" ] || {
    echo "Phase 2 is empty or missing" >&2
    return 1
  }
  grep -qF -- 'and `SANDBOX_ANSWER` (`enable`, `decline`, or unset) for Phase 6' <<<"$phase_two" || {
    echo "Phase 2 does not cache SANDBOX_ANSWER for Phase 6" >&2
    return 1
  }
  grep -qF -- 'On `SANDBOX=stands` or `SANDBOX=default-off`, `SANDBOX_ANSWER` stays unset' <<<"$phase_two" || {
    echo "Phase 2 does not say SANDBOX_ANSWER stays unset on the other routes" >&2
    return 1
  }
  return 0
}

HALT_SENTENCE='This covers a run entered from `/gaia-init`'"'"'s last step, and a step Claude Code'"'"'s auto-mode classifier denies: stop, say which step was denied, and tell the user to re-run `/setup-gaia`, approving the action when asked; never point at `gaia init resume`.'

# check_halt_rule <page>: the re-run section tells a halt (including a step the
# auto-mode classifier denies) to re-run setup, never to resume init.
check_halt_rule() {
  local section
  section="$(section_of "$1" '## On failure: re-run')"
  grep -qF -- "$HALT_SENTENCE" <<<"$section" || {
    echo "the re-run section lacks the halt sentence" >&2
    grep -qF -- 'auto-mode classifier denies' <<<"$section" || echo "missing phrase: auto-mode classifier denies" >&2
    grep -qF -- 'never point at `gaia init resume`' <<<"$section" || echo "missing phrase: never point at gaia init resume" >&2
    return 1
  }
  return 0
}

@test "Phase 6 runs the closing message and prints no closing line of its own" {
  grep -qF -- "Then run \`land-decisions.md\`'s \`## The closing message\`." <<<"$PHASE_SIX"
  grep -qF -- "You're all set" <<<"$PHASE_SIX" && return 1
  return 0
}

@test "the closing message reads the shared setup-owed predicate" {
  grep -qF -- '. .gaia/statusline/setup-owed.sh' <<<"$CLOSING"
  grep -qF -- 'OWED_AT_END=%s' <<<"$CLOSING"
  grep -qF -- 'gaia_setup_owed_ids .' <<<"$CLOSING"
}

@test "the closing message reads the admin-owed ids from the same predicate file" {
  grep -qF -- 'ADMIN_OWED_AT_END=%s' <<<"$CLOSING"
  grep -qF -- 'gaia_setup_admin_owed_ids .' <<<"$CLOSING"
}

@test "the closing message prints each status, conditional, fresh-context and docs line as a whole line" {
  grep -qxF -- "$DONE_LINE" <<<"$CLOSING"
  grep -qxF -- "$NOT_DONE_LINE" <<<"$CLOSING"
  grep -qxF -- "$UNCHECKED_LINE" <<<"$CLOSING"
  grep -qxF -- "$ADMIN_OWED_LINE" <<<"$CLOSING"
  grep -qxF -- "$FRESH_CONTEXT_LINE" <<<"$CLOSING"
  grep -qxF -- "$DOCS_LINE" <<<"$CLOSING"
  grep -qxF -- "$SANDBOX_BULLET" <<<"$CLOSING"
  grep -qxF -- "$AUTO_MODE_LINE" <<<"$CLOSING"
}

@test "the closing lines print in order, the fresh-context and docs lines once" {
  check_closing_order "$CLOSING"
}

@test "the closing order check fails with the fresh-context and docs lines swapped" {
  local copy
  copy="$(mutate_file "$REFERENCE" order-one.md "$FRESH_CONTEXT_LINE" '@@FRESH@@')"
  copy="$(mutate_file "$copy" order-two.md "$DOCS_LINE" "$FRESH_CONTEXT_LINE")"
  copy="$(mutate_file "$copy" order-three.md '@@FRESH@@' "$DOCS_LINE")"
  run check_closing_order "$(section_of "$copy" '## The closing message')"
  [ "$status" -ne 0 ]
  grep -qF 'out of order' <<<"$output"
}

@test "the closing order check fails when the fresh-context sentence joins the done line" {
  local copy
  copy="$(mutate_file "$REFERENCE" order-joined.md "$DONE_LINE" "$DONE_LINE $FRESH_CONTEXT_LINE")"
  run check_closing_order "$(section_of "$copy" '## The closing message')"
  [ "$status" -ne 0 ]
  grep -qF 'missing whole line' <<<"$output"
}

@test "the sandbox sentence prints once, gated on this run's answer, and never reads the marker" {
  check_sandbox_gate "$CLOSING"
}

@test "the sandbox gate check fails when the sentence loses its condition" {
  local copy
  copy="$(mutate_file "$REFERENCE" sandbox-ungated.md "$SANDBOX_BULLET" "\`${SANDBOX_LINE}\`")"
  run check_sandbox_gate "$(section_of "$copy" '## The closing message')"
  [ "$status" -ne 0 ]
  grep -qF 'not gated' <<<"$output"
}

@test "the sandbox gate check fails when the condition reads the marker" {
  local copy
  copy="$(mutate_file "$REFERENCE" sandbox-marker.md "$SANDBOX_CONDITION" "When the sandbox marker's outcome is \`enabled\`")"
  run check_sandbox_gate "$(section_of "$copy" '## The closing message')"
  [ "$status" -ne 0 ]
  grep -qF 'marker' <<<"$output"
}

@test "the sandbox gate check fails when the sentence is removed" {
  local copy
  copy="$(mutate_file "$REFERENCE" sandbox-absent.md "$SANDBOX_BULLET" '')"
  run check_sandbox_gate "$(section_of "$copy" '## The closing message')"
  [ "$status" -ne 0 ]
  grep -qF 'exactly one line' <<<"$output"
}

@test "the auto-mode line prints once, unconditionally, as a whole line" {
  check_unconditional_line "$CLOSING" "$AUTO_MODE_LINE"
}

@test "the auto-mode check fails when the line is put back under a mode condition" {
  local copy
  copy="$(mutate_file "$REFERENCE" auto-gated.md "$AUTO_MODE_LINE" "- When this session runs in auto permission mode: \`${AUTO_MODE_LINE}\`")"
  run check_unconditional_line "$(section_of "$copy" '## The closing message')" "$AUTO_MODE_LINE"
  [ "$status" -ne 0 ]
  grep -qF 'one whole line' <<<"$output"
}

@test "the auto-mode check fails when the line also appears inside another line" {
  local copy
  copy="$(mutate_file "$REFERENCE" auto-doubled.md "$DONE_LINE" "$DONE_LINE $AUTO_MODE_LINE")"
  run check_unconditional_line "$(section_of "$copy" '## The closing message')" "$AUTO_MODE_LINE"
  [ "$status" -ne 0 ]
  grep -qF 'inside another line' <<<"$output"
}

@test "the auto-mode check fails when the line is removed" {
  local copy
  copy="$(mutate_file "$REFERENCE" auto-absent.md "$AUTO_MODE_LINE" '')"
  run check_unconditional_line "$(section_of "$copy" '## The closing message')" "$AUTO_MODE_LINE"
  [ "$status" -ne 0 ]
  grep -qF 'one whole line' <<<"$output"
}

@test "no setup surface file tells the user to restart Claude or reload plugins" {
  check_no_restart_or_reload "$PAGE" "$(dirname "$REFERENCE")"
}

@test "the restart check fails with the old restart sentence put back in a reference" {
  local directory
  directory="${BATS_TEST_TMPDIR}/restart-references"
  mkdir -p "$directory"
  cp "$(dirname "$REFERENCE")"/*.md "$directory"/
  mutate_file "$REFERENCE" restart-old.md "$DONE_LINE" "$DONE_LINE Restart Claude Code to load your new plugins and skills." >/dev/null
  cp "${BATS_TEST_TMPDIR}/restart-old.md" "${directory}/land-decisions.md"
  run check_no_restart_or_reload "$PAGE" "$directory"
  [ "$status" -ne 0 ]
  grep -qF 'land-decisions.md' <<<"$output"
}

@test "the restart check fails with a reload command added to a reference" {
  local directory
  directory="${BATS_TEST_TMPDIR}/reload-references"
  mkdir -p "$directory"
  cp "$(dirname "$REFERENCE")"/*.md "$directory"/
  printf '%s\n' 'Type `/reload-plugins --force` to load your new plugins and skills in this session.' >>"${directory}/land-decisions.md"
  run check_no_restart_or_reload "$PAGE" "$directory"
  [ "$status" -ne 0 ]
  grep -qF 'land-decisions.md' <<<"$output"
}

@test "Phase 2 caches the sandbox answer for the closing message" {
  check_sandbox_answer_cached "$PAGE"
}

@test "the sandbox-answer check fails without the caching clause" {
  local copy
  copy="$(mutate_file "$PAGE" cache-clause.md ', and `SANDBOX_ANSWER` (`enable`, `decline`, or unset) for Phase 6'"'"'s closing message' '')"
  run check_sandbox_answer_cached "$copy"
  [ "$status" -ne 0 ]
  grep -qF 'does not cache' <<<"$output"
}

@test "the sandbox-answer check fails without the stays-unset sentence" {
  local copy
  copy="$(mutate_file "$PAGE" stays-unset.md 'On `SANDBOX=stands` or `SANDBOX=default-off`, `SANDBOX_ANSWER` stays unset: only an answer given this run counts.' '')"
  run check_sandbox_answer_cached "$copy"
  [ "$status" -ne 0 ]
  grep -qF 'stays unset' <<<"$output"
}

@test "the re-run section names a classifier-denied step and never points at init resume" {
  check_halt_rule "$PAGE"
}

@test "the halt-rule check fails with the sentence removed" {
  local copy
  copy="$(mutate_file "$PAGE" halt-absent.md " ${HALT_SENTENCE}" '')"
  run check_halt_rule "$copy"
  [ "$status" -ne 0 ]
  grep -qF 'lacks the halt sentence' <<<"$output"
}

@test "the halt-rule check fails with the init-resume prohibition deleted" {
  local copy
  copy="$(mutate_file "$PAGE" halt-no-resume.md '; never point at `gaia init resume`' '')"
  run check_halt_rule "$copy"
  [ "$status" -ne 0 ]
  grep -qF 'missing phrase: never point at gaia init resume' <<<"$output"
}

@test "the summary's Dependabot item is the approved line verbatim, reason included" {
  local approved="Dependabot security alerts are on. GAIA updates vulnerable packages for you and tests the result before anything changes, so Dependabot's own security fix pull requests are turned off."
  local github_repo="${REPO_ROOT}/.claude/skills/gaia/references/setup/github-repo.md"
  grep -qxF -- "$approved" <<<"$CLOSING"
  grep -qF -- 'verbatim, never a shortened form' <<<"$CLOSING"
  # The same line the Dependabot step prints, so the two cannot drift apart.
  grep -qF -- "print \`${approved}\`" "$github_repo"
}

@test "the done line is gated: the closing message names when each line prints" {
  grep -qF -- 'When `OWED_AT_END`, `ADMIN_UNCHECKED_AT_END` and `ADMIN_OWED_AT_END` are all empty:' <<<"$CLOSING"
  grep -qF -- 'When `OWED_AT_END` is not empty' <<<"$CLOSING"
  grep -qF -- 'When `OWED_AT_END` is empty and `ADMIN_UNCHECKED_AT_END` is not' <<<"$CLOSING"
  grep -qF -- 'When `OWED_AT_END` and `ADMIN_UNCHECKED_AT_END` are empty and `ADMIN_OWED_AT_END` is not' <<<"$CLOSING"
}

@test "the closing message never says a non-admin owes nothing" {
  grep -qF -- 'owes nothing on this machine and ends on the done line' <<<"$CLOSING" && return 1
  true
}

# check_running_marker <page>: Pre-flight touches the marker after the worktree
# refusal, Phase 6 removes it before the adoption ping, and the re-run section
# removes it on a halt.
check_running_marker() {
  local preflight phase_six failure touch_line refuse_line remove_line ping_line
  preflight="$(section_of "$1" '## Pre-flight: Worktree check')"
  phase_six="$(section_of "$1" '## Phase 6: Finalize')"
  failure="$(section_of "$1" '## On failure: re-run')"
  touch_line="$(grep -nxF -- 'mkdir -p .gaia/local && touch .gaia/local/setup-running' <<<"$preflight" | head -n 1 | cut -d: -f1)"
  refuse_line="$(grep -nF -- 'gaia_refuse_if_worktree "/setup-gaia" || exit 1' <<<"$preflight" | head -n 1 | cut -d: -f1)"
  [ -n "$touch_line" ] || {
    echo "Pre-flight does not touch the setup-running marker" >&2
    return 1
  }
  { [ -n "$refuse_line" ] && [ "$touch_line" -gt "$refuse_line" ]; } || {
    echo "Pre-flight touches the marker before the worktree refusal" >&2
    return 1
  }
  remove_line="$(grep -nxF -- 'rm -f .gaia/local/setup-running' <<<"$phase_six" | head -n 1 | cut -d: -f1)"
  ping_line="$(grep -nF -- '**Adoption ping.**' <<<"$phase_six" | head -n 1 | cut -d: -f1)"
  { [ -n "$remove_line" ] && [ -n "$ping_line" ] && [ "$remove_line" -lt "$ping_line" ]; } || {
    echo "Phase 6 does not remove the marker before the adoption ping" >&2
    return 1
  }
  grep -qF -- 'rm -f .gaia/local/setup-running' <<<"$failure" || {
    echo "the re-run section does not remove the marker" >&2
    return 1
  }
}

@test "setup-gaia.md marks setup running after the worktree refusal and clears it on finish and on halt" {
  check_running_marker "$PAGE"
}

@test "the running-marker check fails for each broken site" {
  local copy
  copy="$(mutate_file "$PAGE" no-touch.md 'mkdir -p .gaia/local && touch .gaia/local/setup-running' 'true')"
  run check_running_marker "$copy"
  [ "$status" -ne 0 ]
  grep -qF 'does not touch the setup-running marker' <<<"$output"

  copy="$(mutate_file "$PAGE" no-failure-rm.md 'On any halt, first run `rm -f .gaia/local/setup-running`' 'On any halt')"
  run check_running_marker "$copy"
  [ "$status" -ne 0 ]
  grep -qF 'the re-run section does not remove the marker' <<<"$output"

  copy="$(mutate_file "$PAGE" no-phase-six-rm.md 'rm -f .gaia/local/setup-running
```

**Adoption ping.**' '**Adoption ping.**')"
  run check_running_marker "$copy"
  [ "$status" -ne 0 ]
  grep -qF 'Phase 6 does not remove the marker' <<<"$output"
}

# closing_block: the closing message's first bash block, the one that reads the
# owed sets. Fails when the section holds no bash block.
closing_block() {
  local block
  block="$(awk '/^```bash$/ { inside = 1; next } inside && /^```$/ { exit } inside' <<<"$CLOSING")"
  [ -n "$block" ] || {
    echo "the closing message holds no bash block" >&2
    return 1
  }
  printf '%s\n' "$block"
}

# make_closing_fixture: a checkout holding the shipped feature list, the
# shared predicate, and a committed project config that decides every project
# id but required-ci-checks. No admin answer is cached. Prints its path.
make_closing_fixture() {
  local fixture="${BATS_TEST_TMPDIR}/closing-fixture"
  mkdir -p "${fixture}/.gaia/statusline"
  cp "${REPO_ROOT}/.gaia/setup-features.json" "${fixture}/.gaia/setup-features.json"
  cp "${REPO_ROOT}/.gaia/statusline/setup-owed.sh" "${fixture}/.gaia/statusline/setup-owed.sh"
  jq '{setup_decisions: ([.features[] | select(.scope == "project" and .id != "required-ci-checks") | {key: .id, value: "applied"}] | from_entries)}' \
    "${REPO_ROOT}/.gaia/setup-features.json" >"${fixture}/.gaia/project.json"
  jq -e '[.features[] | select(.id == "required-ci-checks" and .scope == "project" and .admin == true)] | length == 1' \
    "${fixture}/.gaia/setup-features.json" >/dev/null || {
    echo "the shipped list no longer holds required-ci-checks as an admin-gated project id" >&2
    return 1
  }
  printf '%s\n' "$fixture"
}

# run_closing_block <fixture> <host> <auth status>: run the closing block from
# the fixture with Phase 1's cached HOST and AUTH_STATUS declared, as the
# closing message runs it.
run_closing_block() {
  local script="${BATS_TEST_TMPDIR}/closing-block.sh"
  closing_block >"$script"
  run bash -c 'cd "$1" && HOST="$2" && AUTH_STATUS="$3" && . "$4"' _ "$1" "$2" "$3" "$script"
}

@test "a github.com origin whose admin probe failed names its undecided admin-gated ids, so the done line cannot print" {
  local fixture auth_status
  fixture="$(make_closing_fixture)"
  for auth_status in unauthenticated api_error ''; do
    run_closing_block "$fixture" github.com "$auth_status"
    [ "$status" -eq 0 ]
    grep -qxF -- 'OWED_AT_END=' <<<"$output"
    grep -qxF -- 'ADMIN_OWED_AT_END=' <<<"$output"
    grep -qxF -- 'ADMIN_UNCHECKED_AT_END=required-ci-checks' <<<"$output" || {
      echo "auth status '${auth_status}' left the admin-gated id unnamed" >&2
      return 1
    }
  done
}

@test "an ok admin probe leaves the unchecked set empty and a cached non-admin keeps the admin line" {
  local fixture
  fixture="$(make_closing_fixture)"
  mkdir -p "${fixture}/.gaia/local"
  printf '{"admin":false}\n' >"${fixture}/.gaia/local/setup-state.json"
  run_closing_block "$fixture" github.com ok
  [ "$status" -eq 0 ]
  grep -qxF -- 'ADMIN_UNCHECKED_AT_END=' <<<"$output"
  grep -qxF -- 'ADMIN_OWED_AT_END=required-ci-checks' <<<"$output"
}

@test "an origin on another host, or no origin, names no GitHub id as admin-owed or unchecked" {
  local fixture host
  fixture="$(make_closing_fixture)"
  for host in gitlab.com ''; do
    run_closing_block "$fixture" "$host" ''
    [ "$status" -eq 0 ]
    grep -qxF -- 'ADMIN_OWED_AT_END=' <<<"$output" || {
      echo "host '${host}' named an admin-owed id" >&2
      return 1
    }
    grep -qxF -- 'ADMIN_UNCHECKED_AT_END=' <<<"$output" || {
      echo "host '${host}' named an unchecked id" >&2
      return 1
    }
  done
}
