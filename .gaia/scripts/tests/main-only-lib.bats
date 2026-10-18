#!/usr/bin/env bats
#
# Conformance suite for .gaia/scripts/main-only-lib.sh (task 5.3): the shared
# main-only-flow refusal helper the classified flows source instead of each
# carrying its own copy-pasted detection. CALL_SITE_FILES below is the roster.
#
# Run under bash 5 (bash 3.2's `[[ ]]` skip-under-set-e gap is real; see
# .claude/rules/bats-assertions.md): `source .gaia/scripts/bats5.sh && bats5
# .gaia/scripts/tests/main-only-lib.bats`.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.
#
# Fixture idiom matched from main-root-lib.bats (make_repo / make_worktree,
# canonicalized via `pwd -P` since macOS resolves /tmp -> /private/tmp inside
# `git rev-parse` and outputs are compared byte-for-byte) and link-worktree.bats
# (a run_in helper that cds into a tree and runs a script).

setup() {
  LIBRARY_SCRIPT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/main-only-lib.sh"
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  CLEANUP_DIRECTORIES=()
}

teardown() {
  local cleanup_directory
  for cleanup_directory in "${CLEANUP_DIRECTORIES[@]:-}"; do
    [ -n "$cleanup_directory" ] && rm -rf "$cleanup_directory"
  done
  return 0
}

git_identity() {
  git -C "$1" config user.email gaia-test@example.com
  git -C "$1" config user.name "GAIA Test"
  git -C "$1" config commit.gpgsign false
}

# make_repo: an ordinary clone. Sets REPO.
make_repo() {
  local raw
  raw=$(mktemp -d -t gaia-mol-repo-XXXXXX)
  REPO="$(cd "$raw" && pwd -P)"
  CLEANUP_DIRECTORIES+=("$REPO")
  git -C "$REPO" init -q --initial-branch=main
  git_identity "$REPO"
  echo init >"$REPO/f"
  git -C "$REPO" add f
  git -C "$REPO" commit -q -m init
}

# make_worktree <repo> <relative_path> <branch>: a real linked worktree under
# <repo>/.claude/worktrees/<relative_path>, mirroring how GAIA creates plan/debt
# worktrees. Sets WORKTREE to the worktree's absolute path.
make_worktree() {
  local repo="$1" relative_path="$2" branch="$3"
  git -C "$repo" branch "$branch"
  mkdir -p "$repo/.claude/worktrees"
  git -C "$repo" worktree add -q "$repo/.claude/worktrees/$relative_path" "$branch"
  WORKTREE="$repo/.claude/worktrees/$relative_path"
}

# run_in <directory> -- <bash args...>: runs a command with cwd=<directory>.
run_in() {
  local directory="$1"
  shift
  [ "$1" = "--" ] && shift
  ( cd "$directory" && "$@" )
}

# ---------- not a linked worktree ----------

@test "not a linked worktree: returns 0 and prints nothing" {
  make_repo
  run run_in "$REPO" -- bash -c '. "$1"; gaia_refuse_if_worktree "/x"' _ "$LIBRARY_SCRIPT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------- linked worktree, resolvable main ----------

@test "linked worktree with resolvable main: returns 1, message names both roots, no state_line_function given" {
  make_repo
  make_worktree "$REPO" w wtbranch1
  run run_in "$WORKTREE" -- bash -c '. "$1"; gaia_refuse_if_worktree "/gaia-release"' _ "$LIBRARY_SCRIPT"
  [ "$status" -eq 1 ]
  grep -qF -- "/gaia-release must run from the main checkout, not a worktree." <<<"$output" || return 1
  grep -qF -- "Worktree:       $WORKTREE" <<<"$output" || return 1
  grep -qF -- "Main checkout:  $REPO" <<<"$output" || return 1
  grep -qF -- "Run \`cd $REPO\` then re-invoke /gaia-release." <<<"$output" || return 1
}

@test "linked worktree, no state_line_function supplied: no state paragraph at all" {
  make_repo
  make_worktree "$REPO" w wtbranch2
  run run_in "$WORKTREE" -- bash -c '. "$1"; gaia_refuse_if_worktree "/gaia-release" 2>/dev/null' _ "$LIBRARY_SCRIPT"
  [ "$status" -eq 1 ]
  # Byte-exact: no state paragraph, and exactly one blank line separates the
  # roots block from the "Run \`cd\`" line -- not $lines-based, bats' $lines
  # splitting silently drops blank-line entries so it can't prove this.
  local expected
  expected="/gaia-release must run from the main checkout, not a worktree.

Worktree:       $WORKTREE
Main checkout:  $REPO

Run \`cd $REPO\` then re-invoke /gaia-release."
  [ "$output" = "$expected" ]
}

@test "linked worktree, state_line_function prints a line: that line is in the message" {
  make_repo
  make_worktree "$REPO" w wtbranch3
  run run_in "$WORKTREE" -- bash -c '
. "$1"
my_state() { printf "Cached on main: GAIA 1.2.3 installed; latest 1.2.3 (update not-available).\n"; }
gaia_refuse_if_worktree "/update-gaia" my_state
' _ "$LIBRARY_SCRIPT"
  [ "$status" -eq 1 ]
  grep -qF -- "Cached on main: GAIA 1.2.3 installed; latest 1.2.3 (update not-available)." <<<"$output" || return 1
  # Per .claude/rules/bats-assertions.md: a `<positive> && return 1` absence
  # check is only safe on a non-final line -- as the test's LAST line its own
  # (good-case) exit status of 1 would fail the test. The explicit `return 0`
  # makes the success path's exit status deterministic.
  grep -qF -- "Cached state unavailable" <<<"$output" && return 1
  return 0
}

@test "linked worktree, state_line_function supplied but prints nothing: shared fallback line is used" {
  make_repo
  make_worktree "$REPO" w wtbranch4
  run run_in "$WORKTREE" -- bash -c '
. "$1"
my_state() { :; }
gaia_refuse_if_worktree "/update-deps" my_state
' _ "$LIBRARY_SCRIPT"
  [ "$status" -eq 1 ]
  grep -qF -- 'Cached state unavailable on main; symlinks may be broken, run `bash .gaia/scripts/link-worktree.sh` to repair.' <<<"$output" || return 1
}

@test "linked worktree, state_line_function's own cache_file argument is main's cache path, not the worktree's" {
  make_repo
  make_worktree "$REPO" w wtbranch5
  local captured="$BATS_TEST_TMPDIR/cache_file_arg"
  run run_in "$WORKTREE" -- bash -c '
. "$1"
captured_path="$2"
my_state() { printf "%s" "$1" > "$captured_path"; }
gaia_refuse_if_worktree "/update-gaia" my_state
' _ "$LIBRARY_SCRIPT" "$captured"
  [ "$status" -eq 1 ]
  [ "$(cat "$captured")" = "$REPO/.gaia/local/cache/shared/update-check.json" ]
}

# ---------- own-branch-prefix exemption ----------
#
# The third argument lets an update command continue inside the worktree it
# created. Every refusal below is compared byte for byte against the same call
# with no third argument, so a prefix can only ever remove the refusal, never
# reword it.

# call_refuse <directory> <prefix>: calls
# gaia_refuse_if_worktree "/flow" with an empty state function and the prefix
# ("" means no third argument at all), under bash.
call_refuse() {
  local directory="$1" prefix="$2"
  if [ -n "$prefix" ]; then
    run run_in "$directory" -- bash -c '. "$1"; gaia_refuse_if_worktree "/flow" "" "$2"' _ "$LIBRARY_SCRIPT" "$prefix"
  else
    run run_in "$directory" -- bash -c '. "$1"; gaia_refuse_if_worktree "/flow"' _ "$LIBRARY_SCRIPT"
  fi
}

@test "own prefix: deps/ from a deps/x worktree returns 0 and prints nothing" {
  make_repo
  make_worktree "$REPO" w-deps deps/x
  call_refuse "$WORKTREE" "deps/"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "own prefix: update/ from a deps/x worktree refuses, byte-identical to the no-prefix refusal" {
  make_repo
  make_worktree "$REPO" w-deps deps/x
  call_refuse "$WORKTREE" ""
  [ "$status" -eq 1 ]
  local baseline="$output"
  [ -n "$baseline" ]
  call_refuse "$WORKTREE" "update/"
  [ "$status" -eq 1 ]
  [ "$output" = "$baseline" ]
}

@test "own prefix: update/ from an update/x worktree returns 0; deps/ from it refuses identically to no prefix" {
  make_repo
  make_worktree "$REPO" w-update update/x
  call_refuse "$WORKTREE" "update/"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  call_refuse "$WORKTREE" ""
  [ "$status" -eq 1 ]
  local baseline="$output"
  call_refuse "$WORKTREE" "deps/"
  [ "$status" -eq 1 ]
  [ "$output" = "$baseline" ]
}

@test "own prefix: spec/x and debt/x worktrees refuse for both prefixes, byte-identical to no prefix" {
  make_repo
  local kind prefix baseline
  for kind in spec debt; do
    make_worktree "$REPO" "w-$kind" "$kind/x"
    call_refuse "$WORKTREE" ""
    [ "$status" -eq 1 ] || return 1
    baseline="$output"
    for prefix in "deps/" "update/"; do
      call_refuse "$WORKTREE" "$prefix"
      [ "$status" -eq 1 ] || { echo "$kind/x with $prefix: expected exit 1, got $status" >&2; return 1; }
      [ "$output" = "$baseline" ] || { echo "$kind/x with $prefix: output differs from the no-prefix refusal" >&2; return 1; }
    done
  done
  return 0
}

@test "own prefix: a detached HEAD worktree refuses with either prefix" {
  make_repo
  git -C "$REPO" worktree add -q --detach "$REPO/.claude/worktrees/w-detached"
  local detached="$REPO/.claude/worktrees/w-detached" prefix baseline
  call_refuse "$detached" ""
  [ "$status" -eq 1 ]
  baseline="$output"
  for prefix in "deps/" "update/"; do
    call_refuse "$detached" "$prefix"
    [ "$status" -eq 1 ] || { echo "detached with $prefix: expected exit 1, got $status" >&2; return 1; }
    [ "$output" = "$baseline" ] || { echo "detached with $prefix: output differs from the no-prefix refusal" >&2; return 1; }
  done
  return 0
}

@test "own prefix: the legacy harness branch spelling is not matched" {
  make_repo
  make_worktree "$REPO" w-legacy worktree-deps+x
  call_refuse "$WORKTREE" "deps/"
  [ "$status" -eq 1 ]
}

@test "own prefix: a matching prefix does not call the state function" {
  make_repo
  make_worktree "$REPO" w-deps deps/x
  local marker="$BATS_TEST_TMPDIR/state-called"
  run run_in "$WORKTREE" -- bash -c '
. "$1"
my_state() { : > "$2"; printf "state\n"; }
gaia_refuse_if_worktree "/flow" my_state "deps/"
' _ "$LIBRARY_SCRIPT" "$marker"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$marker" ]
}

@test "own prefix: an empty state function with a non-matching prefix refuses with no state paragraph" {
  make_repo
  make_worktree "$REPO" w-spec spec/x
  call_refuse "$WORKTREE" ""
  local baseline="$output"
  call_refuse "$WORKTREE" "deps/"
  [ "$status" -eq 1 ]
  [ "$output" = "$baseline" ]
  grep -qF -- "Cached state unavailable" <<<"$output" && return 1
  return 0
}

@test "own prefix: from the main checkout any prefix returns 0 and prints nothing" {
  make_repo
  local prefix
  for prefix in "deps/" "update/" "nonsense/"; do
    call_refuse "$REPO" "$prefix"
    [ "$status" -eq 0 ] || return 1
    [ -z "$output" ] || return 1
  done
  return 0
}

@test "own prefix: a main-only flow without a prefix still passes from main while a deps worktree is live" {
  make_repo
  make_worktree "$REPO" w-deps deps/x
  call_refuse "$REPO" ""
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "own prefix: deps/ from a deps/x worktree returns 0 and prints nothing, under zsh" {
  command -v zsh >/dev/null 2>&1 || skip "zsh not installed"
  make_repo
  install_libraries "$REPO"
  make_worktree "$REPO" w-deps deps/x
  run run_in "$WORKTREE" -- zsh -c '. .gaia/scripts/main-only-lib.sh; gaia_refuse_if_worktree "/flow" "" "deps/"'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "own prefix: update/ from a deps/x worktree refuses, byte-identical to no prefix, under zsh" {
  command -v zsh >/dev/null 2>&1 || skip "zsh not installed"
  make_repo
  install_libraries "$REPO"
  make_worktree "$REPO" w-deps deps/x
  run run_in "$WORKTREE" -- zsh -c '. .gaia/scripts/main-only-lib.sh; gaia_refuse_if_worktree "/flow"'
  [ "$status" -eq 1 ]
  local baseline="$output"
  grep -qF -- "/flow must run from the main checkout, not a worktree." <<<"$baseline" || return 1
  run run_in "$WORKTREE" -- zsh -c '. .gaia/scripts/main-only-lib.sh; gaia_refuse_if_worktree "/flow" "" "update/"'
  [ "$status" -eq 1 ]
  [ "$output" = "$baseline" ]
}

# ---------- unresolvable main (fail-open) ----------

@test "linked worktree, unresolvable main: fails open, returns 0, prints nothing" {
  make_repo
  make_worktree "$REPO" w wtbranch6
  local common_config
  common_config="$(cd "$REPO/.git" && pwd -P)/config"
  git config --file "$common_config" core.worktree "/nonexistent/evil/path"
  # bats' `run` merges stdout+stderr by default, and the resolver's own
  # contract (main-root-lib.sh) writes one diagnostic line to STDERR on this
  # exact failure -- expected, and not this helper's stdout contract. Discard
  # it here (matching main-root-lib.bats' `resolve()` helper) so $output
  # reflects gaia_refuse_if_worktree's own stdout only.
  run run_in "$WORKTREE" -- bash -c '. "$1"; gaia_refuse_if_worktree "/gaia-release" 2>/dev/null' _ "$LIBRARY_SCRIPT"
  git config --file "$common_config" --unset core.worktree || true
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------- structural ----------

@test "structural: main-only-lib.sh is executable" {
  [ -x "$LIBRARY_SCRIPT" ]
}

@test "structural: sourcing the library defines gaia_refuse_if_worktree and the resolver functions, with no side effects" {
  run bash -c '
    # shellcheck disable=SC1090
    source "$1"
    type gaia_refuse_if_worktree >/dev/null
    type gaia_resolve_main_root >/dev/null
    type gaia_is_linked_worktree >/dev/null
    type gaia_resolve_tree_root >/dev/null
    echo OK
  ' _ "$LIBRARY_SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

# ---------- as the call sites actually invoke it ----------
#
# Every test above sources $LIBRARY_SCRIPT by ABSOLUTE path under bash. The call sites
# do neither: they are markdown blocks an agent runs through its shell
# tool, so the sourcing shell is that machine's login shell (zsh on a stock
# Mac, not bash as a settings.json-registered hook gets), and the line they run
# is the repo-relative `. .gaia/scripts/main-only-lib.sh` from a checkout root.
#
# Both halves of that matter, and each hid the other. Under zsh BASH_SOURCE is
# unset and `declare -F` declares a float and succeeds, so the sibling resolver
# was never sourced and every refusal returned 0 -- the flow continuing, from a
# worktree, with no refusal printed. And under `zsh -c` a relative `.` drops
# the directory from $0, so a test that sources by absolute path greens while
# the real relative-path call stays dead.
#
# install_libraries copies both libraries into the fixture at the same repo-relative
# path a real checkout has them, and commits them before the worktree is cut so
# both trees carry them.
install_libraries() {
  local repo="$1" scripts_directory
  scripts_directory="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  mkdir -p "$repo/.gaia/scripts"
  cp "$scripts_directory/main-only-lib.sh" "$scripts_directory/main-root-lib.sh" "$scripts_directory/update-state-line-lib.sh" "$repo/.gaia/scripts/"
  git -C "$repo" add .gaia/scripts
  git -C "$repo" commit -q -m "libs"
}

@test "as invoked: relative source from a worktree root refuses out loud, under zsh" {
  command -v zsh >/dev/null 2>&1 || skip "zsh not installed"
  make_repo
  install_libraries "$REPO"
  make_worktree "$REPO" w wtbranchzsh1
  run run_in "$WORKTREE" -- zsh -c '. .gaia/scripts/main-only-lib.sh; gaia_refuse_if_worktree "/gaia-release"'
  [ "$status" -eq 1 ]
  grep -qF -- "/gaia-release must run from the main checkout, not a worktree." <<<"$output" || return 1
  grep -qF -- "Main checkout:  $REPO" <<<"$output" || return 1
  # The failure this test exists for was near-silent: no refusal, and a stray
  # shell error in its place.
  grep -qF -- "command not found" <<<"$output" && return 1
  return 0
}

@test "as invoked: relative source from a worktree root refuses out loud, under bash" {
  make_repo
  install_libraries "$REPO"
  make_worktree "$REPO" w wtbranchrel1
  run run_in "$WORKTREE" -- bash -c '. .gaia/scripts/main-only-lib.sh; gaia_refuse_if_worktree "/gaia-release"'
  [ "$status" -eq 1 ]
  grep -qF -- "/gaia-release must run from the main checkout, not a worktree." <<<"$output" || return 1
}

@test "as invoked: relative source from the main checkout returns 0 and prints nothing, under zsh" {
  command -v zsh >/dev/null 2>&1 || skip "zsh not installed"
  make_repo
  install_libraries "$REPO"
  run run_in "$REPO" -- zsh -c '. .gaia/scripts/main-only-lib.sh; gaia_refuse_if_worktree "/gaia-release"'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "structural: sourcing main-root-lib.sh first, then this file, does not error (guarded re-source)" {
  local main_root_library
  main_root_library="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/main-root-lib.sh"
  run bash -c '
    # shellcheck disable=SC1090
    source "$1"
    # shellcheck disable=SC1090
    source "$2"
    type gaia_refuse_if_worktree >/dev/null
    echo OK
  ' _ "$main_root_library" "$LIBRARY_SCRIPT"
  [ "$status" -eq 0 ]
  [ "$output" = "OK" ]
}

# ---------- the call-site meter ----------
#
# main-only-lib.sh's own header, in the sibling-location idiom note above its
# location-candidate loop, records the Milestone 5 false green: the refusal is
# shell an agent runs through its shell tool, zsh on a stock Mac, not the bash
# a settings-registered hook gets, and for most of that milestone the refusal
# was dead under zsh while a bash-only meter read green. This section is what
# keeps the hardening honest as the call-site count grows. It tests the block
# AS WRITTEN in each file, under the shell the call site really uses, from a
# REAL linked worktree, not a copy hand-transcribed into this suite.
#
# Classification of which flows carry the refusal and which do not lives in
# .gaia/local/plans/worktree-program-next/RUNBOOK.md, which is machine-local
# and gitignored; this test cannot read it, so the two lists below are
# hardcoded here instead, with this comment naming where the classification
# itself lives.

# The classified flows that carry the refusal, and each one's flow-name
# literal at the same array index. Order matches the RUNBOOK.md
# classification's own ordering, not alphabetical.
CALL_SITE_FILES=(
  ".claude/commands/gaia-cleanse.md"
  ".claude/commands/gaia-debt.md"
  ".claude/commands/gaia-fitness.md"
  ".claude/commands/gaia-codify.md"
  ".claude/commands/gaia-release.md"
  ".claude/commands/gaia-serena-sync.md"
  ".claude/commands/setup-gaia.md"
  ".claude/skills/gaia-wiki/SKILL.md"
  "frontend/.claude/skills/gaia-react-perf/SKILL.md"
  ".claude/skills/release-notes/SKILL.md"
  ".claude/skills/update-deps/SKILL.md"
  ".claude/skills/update-gaia/SKILL.md"
  ".claude/commands/gaia-residue.md"
)
CALL_SITE_FLOW_NAMES=(
  "/gaia-cleanse"
  "/gaia-debt"
  "/gaia-fitness"
  "/gaia-codify"
  "/gaia-release"
  "/gaia-serena-sync"
  "/setup-gaia"
  "/gaia-wiki"
  "/gaia-react-perf"
  "/release-notes"
  "/update-deps"
  "/update-gaia"
  "/gaia-residue"
)

# The flows that must never carry the refusal: each provisions or drives
# its own worktree mid-flow (gaia-plan, gaia-debt's fix path) or must stay
# reachable from inside one (gaia-spec, gaia-forensics, file-tech-debt).
# This half is what catches a future drive-by adding the refusal to one of these, e.g. onto /gaia-plan, which would break
# plan execution the moment the flow enters the worktree it just created.
#
# distribution-vet joins them on a different warrant, and one worth stating
# because the refusal did sit on it. What decides it is what the flow writes:
# /distribution-vet writes `.gaia/manifest.json` and `.gaia/release-exclude`,
# git-tracked branch-scoped files a linked worktree isolates correctly, and it
# writes nothing under `.gaia/local`, so a worktree run collides with no shared
# state. The release path's main-only property is enforced at /gaia-release's
# own call site above, not here.
#
# That warrant stands on its own and deliberately does not rest on
# main-only-lib.sh's docblock, which disclaims deciding membership and points
# here instead. Reading the motivating case the docblock does record reaches
# the same verdict anyway: that sentence is a conjunction, a
# VERSION/lockfile/cache-state write AND opening or driving a PR, and
# /distribution-vet satisfies neither half. CALL_SITE_FILES is the roster,
# and the `call-site roster:` census tests are what enforce it.
NO_CALL_SITE_FILES=(
  ".claude/commands/distribution-vet.md"
  ".claude/commands/gaia-plan.md"
  ".claude/commands/gaia-spec.md"
  ".claude/commands/gaia-forensics.md"
  ".claude/skills/file-tech-debt/SKILL.md"
)

# Part of the call-site roster are thin dispatchers: a "Read `.claude/..." (or "Read `frontend/.claude/...") line
# sends the agent to a reference file, and a refusal call placed BELOW that
# line greps as present but never runs, because the agent follows the
# reference instead of reading the rest of the file. This is the frozen
# set; the placement test below derives its own split at runtime
# rather than trusting this list, and fails when the two disagree.
EXPECTED_DISPATCHER_FILES=(
  ".claude/commands/gaia-cleanse.md"
  ".claude/commands/gaia-debt.md"
  ".claude/commands/gaia-fitness.md"
  ".claude/commands/gaia-codify.md"
  ".claude/commands/gaia-serena-sync.md"
  ".claude/commands/setup-gaia.md"
  ".claude/skills/gaia-wiki/SKILL.md"
  "frontend/.claude/skills/gaia-react-perf/SKILL.md"
  ".claude/commands/gaia-residue.md"
)

# extract_block <file>: pulls the fenced code block (```...```) that
# contains the gaia_refuse_if_worktree invocation, verbatim, exclusive of
# the fences. An awk state machine over the file rather than a
# hand-maintained copy of each block, because a hand-maintained copy is
# exactly the thing that drifts from the file it claims to test.
extract_block() {
  awk '
    /^```/ {
      if (in_block) {
        if (found) { printf "%s", block_text; exit }
        in_block = 0; block_text = ""; found = 0
      } else {
        in_block = 1; block_text = ""
      }
      next
    }
    in_block {
      block_text = block_text $0 "\n"
      if ($0 ~ /gaia_refuse_if_worktree "/) found = 1
    }
  ' "$1"
}

# ---------- roster census ----------

@test "call-site roster: every classified flow carries exactly one line-anchored invocation" {
  local call_site_file count
  for call_site_file in "${CALL_SITE_FILES[@]}"; do
    count=$(grep -c '^[[:space:]]*gaia_refuse_if_worktree "' "$REPO_ROOT/$call_site_file" || true)
    [ "$count" -eq 1 ] || { echo "expected exactly one gaia_refuse_if_worktree invocation in $call_site_file, found $count" >&2; return 1; }
  done
}

@test "call-site roster: the worktree-callable flows carry none" {
  local call_site_file count
  for call_site_file in "${NO_CALL_SITE_FILES[@]}"; do
    count=$(grep -c '^[[:space:]]*gaia_refuse_if_worktree "' "$REPO_ROOT/$call_site_file" || true)
    [ "$count" -eq 0 ] || { echo "expected no gaia_refuse_if_worktree invocation in $call_site_file, found $count" >&2; return 1; }
  done
}

# ---------- placement ----------

@test "call-site placement: the invocation precedes the file's own dispatch line, in every thin dispatcher" {
  local call_site_file dispatch_line invoke_line measured=() sorted_measured sorted_expected
  for call_site_file in "${CALL_SITE_FILES[@]}"; do
    dispatch_line=$(grep -nE 'Read `(frontend/)?\.claude/' "$REPO_ROOT/$call_site_file" | head -1 | cut -d: -f1)
    [ -n "$dispatch_line" ] || continue # exempt: no dispatch line to sit ahead of
    measured+=("$call_site_file")
    invoke_line=$(grep -n '^[[:space:]]*gaia_refuse_if_worktree "' "$REPO_ROOT/$call_site_file" | head -1 | cut -d: -f1)
    [ "$invoke_line" -lt "$dispatch_line" ] || { echo "$call_site_file: invocation at line $invoke_line does not precede dispatch line $dispatch_line" >&2; return 1; }
  done
  # Report and enforce the measured split against the frozen set: a
  # difference is a finding, not something to accommodate.
  sorted_measured="$(printf '%s\n' "${measured[@]}" | sort)"
  sorted_expected="$(printf '%s\n' "${EXPECTED_DISPATCHER_FILES[@]}" | sort)"
  echo "measured dispatchers (${#measured[@]}): $sorted_measured" >&2
  [ "$sorted_measured" = "$sorted_expected" ] || { echo "dispatcher split drifted from the frozen set; measured vs expected above" >&2; return 1; }
}

# ---------- per-call-site execution, under the shell the call site really uses ----------

@test "call-site execution: every extracted block refuses correctly under bash, from a real linked worktree" {
  make_repo
  install_libraries "$REPO"
  make_worktree "$REPO" mol-bash mol-bash-branch
  local i=0 call_site_file flow block
  for call_site_file in "${CALL_SITE_FILES[@]}"; do
    flow="${CALL_SITE_FLOW_NAMES[$i]}"
    i=$((i + 1))
    block="$(extract_block "$REPO_ROOT/$call_site_file")"
    [ -n "$block" ] || { echo "$call_site_file: extractor found no fenced block containing the invocation" >&2; return 1; }
    run run_in "$WORKTREE" -- bash -c "$block"
    [ "$status" -eq 1 ] || { echo "$call_site_file (bash): expected exit 1, got $status; output: $output" >&2; return 1; }
    grep -qF -- "$flow must run from the main checkout, not a worktree." <<<"$output" || { echo "$call_site_file (bash): missing refusal line" >&2; return 1; }
    grep -qF -- "Main checkout:  $REPO" <<<"$output" || { echo "$call_site_file (bash): missing main checkout line" >&2; return 1; }
    grep -qF -- "Run \`cd $REPO\` then re-invoke $flow." <<<"$output" || { echo "$call_site_file (bash): missing re-invoke line" >&2; return 1; }
    # The Milestone 5 failure was near-silent: no refusal, and a stray shell
    # error in its place.
    grep -qF -- "command not found" <<<"$output" && { echo "$call_site_file (bash): stray shell error in output" >&2; return 1; }
  done
  # Explicit and deterministic: without this, the loop's own exit status is
  # the LAST command's, and the good case of the final `&&`-guarded absence
  # check above exits 1 (grep found no match), which would otherwise leak
  # through as this function's own return status.
  return 0
}

@test "call-site execution: every extracted block refuses correctly under zsh, from a real linked worktree" {
  command -v zsh >/dev/null 2>&1 || skip "zsh not installed"
  make_repo
  install_libraries "$REPO"
  make_worktree "$REPO" mol-zsh mol-zsh-branch
  local i=0 call_site_file flow block
  for call_site_file in "${CALL_SITE_FILES[@]}"; do
    flow="${CALL_SITE_FLOW_NAMES[$i]}"
    i=$((i + 1))
    block="$(extract_block "$REPO_ROOT/$call_site_file")"
    [ -n "$block" ] || { echo "$call_site_file: extractor found no fenced block containing the invocation" >&2; return 1; }
    run run_in "$WORKTREE" -- zsh -c "$block"
    [ "$status" -eq 1 ] || { echo "$call_site_file (zsh): expected exit 1, got $status; output: $output" >&2; return 1; }
    grep -qF -- "$flow must run from the main checkout, not a worktree." <<<"$output" || { echo "$call_site_file (zsh): missing refusal line" >&2; return 1; }
    grep -qF -- "Main checkout:  $REPO" <<<"$output" || { echo "$call_site_file (zsh): missing main checkout line" >&2; return 1; }
    grep -qF -- "Run \`cd $REPO\` then re-invoke $flow." <<<"$output" || { echo "$call_site_file (zsh): missing re-invoke line" >&2; return 1; }
    # Under zsh, BASH_SOURCE is unset and `declare -F` declares a float and
    # succeeds instead of answering whether a function exists; that hazard
    # is exactly what a "command not found" in the output would reveal.
    grep -qF -- "command not found" <<<"$output" && { echo "$call_site_file (zsh): stray shell error in output" >&2; return 1; }
  done
  # See the bash test above: without this, the loop's own exit status is the
  # last iteration's last command, whose good case exits 1.
  return 0
}

@test "call-site execution: extracted blocks are silent no-ops from the main checkout" {
  make_repo
  install_libraries "$REPO"
  local call_site_file block
  # One file with no state_line_function, one with: both idiom shapes get the
  # mirror-case proof, not just the no-arg one.
  for call_site_file in ".claude/commands/gaia-release.md" ".claude/skills/update-deps/SKILL.md"; do
    block="$(extract_block "$REPO_ROOT/$call_site_file")"
    run run_in "$REPO" -- bash -c "$block"
    [ "$status" -eq 0 ] || { echo "$call_site_file: expected exit 0 from the main checkout, got $status; output: $output" >&2; return 1; }
    [ -z "$output" ] || { echo "$call_site_file: expected empty output from the main checkout, got: $output" >&2; return 1; }
  done
}

# ---------- the /setup-gaia composition ----------

@test "setup-gaia composition: the refusal half names cd back to main" {
  # /setup-gaia is main-only AND the one statusline nudge that still renders
  # outside main: the nudge tells a worktree session setup is owed, the
  # refusal tells it where to go. The rendering half is asserted in
  # .gaia/tests/statusline/statusline-worktree.bats, in the test named
  # "an incomplete setup is reported from a worktree too". This suite has no
  # statusline fixture, so only the refusal half's composing sentence is
  # asserted here; duplicating the render assertion would be a second copy
  # of a suite that already exists.
  make_repo
  install_libraries "$REPO"
  make_worktree "$REPO" mol-setup mol-setup-branch
  local block
  block="$(extract_block "$REPO_ROOT/.claude/commands/setup-gaia.md")"
  run run_in "$WORKTREE" -- bash -c "$block"
  [ "$status" -eq 1 ]
  grep -qF -- "Run \`cd $REPO\` then re-invoke /setup-gaia." <<<"$output"
}

# ---------- the update skills' own-branch-prefix call sites ----------
#
# The execution tests above run every block from a worktree whose branch
# matches neither update prefix, so a dropped, typo'd or swapped prefix
# argument leaves them green. These pins run the two update skills' real blocks
# from worktrees on each kind of branch.

PREFIX_PIN_SKILL_FILES=(
  ".claude/skills/update-deps/SKILL.md"
  ".claude/skills/update-gaia/SKILL.md"
)
PREFIX_PIN_OWN_KINDS=("deps" "update")
PREFIX_PIN_OTHER_KINDS=("update" "deps")

# strip_prefix_argument <block>: the block with the trailing quoted prefix
# argument removed from the guard call.
strip_prefix_argument() {
  sed -E 's/ "[a-z]+\/"( \|\| exit 1)/\1/' <<<"$1"
}

# run_pin_block <shell> <directory> <block>: runs the block under the shell.
run_pin_block() {
  run run_in "$2" -- "$1" -c "$3"
}

# assert_prefix_pins <shell>: the own-branch pass-through, the refusals and the
# red twin for both update skills, under one shell.
assert_prefix_pins() {
  local shell_name="$1" index block stripped baseline skill_file label kind refused_kind
  make_repo
  install_libraries "$REPO"
  for kind in deps update spec debt; do
    make_worktree "$REPO" "pin-$kind" "$kind/x"
  done
  for index in 0 1; do
    skill_file="${PREFIX_PIN_SKILL_FILES[$index]}"
    label="$skill_file ($shell_name)"
    block="$(extract_block "$REPO_ROOT/$skill_file")"
    [ -n "$block" ] || { echo "$label: extractor found no block" >&2; return 1; }
    stripped="$(strip_prefix_argument "$block")"
    [ "$stripped" != "$block" ] || { echo "$label: removing the prefix argument changed nothing" >&2; return 1; }

    kind="${PREFIX_PIN_OWN_KINDS[$index]}"
    run_pin_block "$shell_name" "$REPO/.claude/worktrees/pin-$kind" "$block"
    [ "$status" -eq 0 ] || { echo "$label: own kind $kind expected exit 0, got $status; output: $output" >&2; return 1; }
    [ -z "$output" ] || { echo "$label: own kind $kind expected empty output, got: $output" >&2; return 1; }

    run_pin_block "$shell_name" "$REPO/.claude/worktrees/pin-$kind" "$stripped"
    [ "$status" -eq 1 ] || { echo "$label: red twin from $kind expected exit 1, got $status" >&2; return 1; }

    for refused_kind in "${PREFIX_PIN_OTHER_KINDS[$index]}" spec debt; do
      run_pin_block "$shell_name" "$REPO/.claude/worktrees/pin-$refused_kind" "$stripped"
      [ "$status" -eq 1 ] || { echo "$label: no-prefix variant from $refused_kind expected exit 1, got $status" >&2; return 1; }
      baseline="$output"
      [ -n "$baseline" ] || { echo "$label: no-prefix refusal from $refused_kind was empty" >&2; return 1; }
      run_pin_block "$shell_name" "$REPO/.claude/worktrees/pin-$refused_kind" "$block"
      [ "$status" -eq 1 ] || { echo "$label: from $refused_kind expected exit 1, got $status; output: $output" >&2; return 1; }
      [ "$output" = "$baseline" ] || { echo "$label: from $refused_kind the refusal differs from the no-prefix variant's" >&2; return 1; }
    done
  done
  return 0
}

@test "update skills' call sites: own branch passes, every other worktree refuses like no prefix, under bash" {
  assert_prefix_pins bash
}

@test "update skills' call sites: own branch passes, every other worktree refuses like no prefix, under zsh" {
  command -v zsh >/dev/null 2>&1 || skip "zsh not installed"
  assert_prefix_pins zsh
}

# ---------- gaia_pull_gate ----------

# make_gate_repo <local_version> <cache_json>: a repo carrying the libraries, a
# live `.gaia/VERSION` (omitted when <local_version> is "-") and an
# update-check cache (omitted when <cache_json> is "-"). Sets REPO and GH_LOG,
# and puts a logging `gh` stub first on PATH through GATE_PATH.
make_gate_repo() {
  local local_version="$1" cache_json="$2" stub_directory
  make_repo
  install_libraries "$REPO"
  [ "$local_version" = "-" ] || printf '%s\n' "$local_version" >"$REPO/.gaia/VERSION"
  if [ "$cache_json" != "-" ]; then
    mkdir -p "$REPO/.gaia/local/cache/shared"
    printf '%s' "$cache_json" >"$REPO/.gaia/local/cache/shared/update-check.json"
  fi
  stub_directory="$REPO/.gate-stub-bin"
  GH_LOG="$REPO/.gate-gh.log"
  mkdir -p "$stub_directory"
  : >"$GH_LOG"
  printf '#!/bin/sh\necho "gh $*" >>"%s"\nexit 0\n' "$GH_LOG" >"$stub_directory/gh"
  chmod +x "$stub_directory/gh"
  GATE_PATH="$stub_directory:$PATH"
}

# run_gate <directory> <shell> <command_name> [library]: sources the library
# (the repo's own copy unless <library> is given) and calls the gate.
run_gate() {
  local directory="$1" shell_name="$2" command_name="$3" library="${4:-}"
  [ -n "$library" ] || library="$REPO/.gaia/scripts/main-only-lib.sh"
  run run_in "$directory" -- env PATH="$GATE_PATH" "$shell_name" -c '. "$1"; gaia_pull_gate "$2"' _ "$library" "$command_name"
}

GATE_BEHIND_CACHE='{"gaiaOriginVersion":"2.0.4","gaiaHasUpdate":false,"gaiaUpdateClaims":[]}'
GATE_BEHIND_LINE="GAIA 2.0.4 is on origin/main and this checkout has 2.0.3. New work needs it first."

assert_gate_silent_pass() {
  [ "$status" -eq 0 ] || { echo "expected exit 0, got $status; output: $output" >&2; return 1; }
  [ -z "$output" ] || { echo "expected no output, got: $output" >&2; return 1; }
  [ ! -s "$GH_LOG" ] || { echo "gate called gh: $(cat "$GH_LOG")" >&2; return 1; }
}

@test "pull gate: behind from the main checkout returns 1 with the exact line" {
  make_gate_repo 2.0.3 "$GATE_BEHIND_CACHE"
  run_gate "$REPO" bash /gaia-plan
  [ "$status" -eq 1 ]
  [ "$output" = "$GATE_BEHIND_LINE" ]
  [ ! -s "$GH_LOG" ]
}

@test "pull gate: behind from a linked worktree returns 2 with the next step naming the main root and command" {
  make_gate_repo 2.0.3 "$GATE_BEHIND_CACHE"
  make_worktree "$REPO" gate-w gate-branch
  run_gate "$WORKTREE" bash /gaia-plan
  [ "$status" -eq 2 ]
  local expected="$GATE_BEHIND_LINE
Next step: run /update-gaia in the main checkout at $REPO to pull, then start /gaia-plan again."
  [ "$output" = "$expected" ]
  [ ! -s "$GH_LOG" ]
}

@test "pull gate: a worktree session reads the main checkout's live version, not its own copy" {
  make_gate_repo 2.0.3 "$GATE_BEHIND_CACHE"
  make_worktree "$REPO" gate-live gate-live-branch
  printf '2.0.4\n' >"$WORKTREE/.gaia/VERSION"
  run_gate "$WORKTREE" bash /gaia-plan
  [ "$status" -eq 2 ]
}

@test "pull gate: a repo whose origin has only master names origin/master" {
  make_gate_repo 2.0.3 "$GATE_BEHIND_CACHE"
  git -C "$REPO" update-ref refs/remotes/origin/master HEAD
  run_gate "$REPO" bash /gaia-plan
  [ "$status" -eq 1 ]
  [ "$output" = "GAIA 2.0.4 is on origin/master and this checkout has 2.0.3. New work needs it first." ]
}

@test "pull gate: origin/HEAD names the default branch when set" {
  make_gate_repo 2.0.3 "$GATE_BEHIND_CACHE"
  git -C "$REPO" update-ref refs/remotes/origin/trunk HEAD
  git -C "$REPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/trunk
  run_gate "$REPO" bash /gaia-plan
  [ "$status" -eq 1 ]
  [ "$output" = "GAIA 2.0.4 is on origin/trunk and this checkout has 2.0.3. New work needs it first." ]
}

@test "pull gate: equal versions pass silently" {
  make_gate_repo 2.0.4 "$GATE_BEHIND_CACHE"
  run_gate "$REPO" bash /gaia-plan
  assert_gate_silent_pass
}

@test "pull gate: a local version ahead of origin passes silently" {
  make_gate_repo 2.0.5 "$GATE_BEHIND_CACHE"
  run_gate "$REPO" bash /gaia-plan
  assert_gate_silent_pass
}

@test "pull gate: versions compare numerically, not as strings" {
  make_gate_repo 2.0.9 '{"gaiaOriginVersion":"2.0.10"}'
  run_gate "$REPO" bash /gaia-plan
  [ "$status" -eq 1 ]
  make_gate_repo 2.0.10 '{"gaiaOriginVersion":"2.0.9"}'
  run_gate "$REPO" bash /gaia-plan
  assert_gate_silent_pass
}

@test "pull gate: a prerelease is below its release" {
  make_gate_repo 2.0.4-rc.1 "$GATE_BEHIND_CACHE"
  run_gate "$REPO" bash /gaia-plan
  [ "$status" -eq 1 ]
  [ "$output" = "GAIA 2.0.4 is on origin/main and this checkout has 2.0.4-rc.1. New work needs it first." ]
  make_gate_repo 2.0.4 '{"gaiaOriginVersion":"2.0.4-rc.1"}'
  run_gate "$REPO" bash /gaia-plan
  assert_gate_silent_pass
}

@test "pull gate: missing cache passes silently" {
  make_gate_repo 2.0.3 -
  run_gate "$REPO" bash /gaia-plan
  assert_gate_silent_pass
}

@test "pull gate: unreadable cache passes silently" {
  make_gate_repo 2.0.3 "not json {"
  run_gate "$REPO" bash /gaia-plan
  assert_gate_silent_pass
}

@test "pull gate: cache without gaiaOriginVersion passes silently" {
  make_gate_repo 2.0.3 '{"gaiaHasUpdate":true}'
  run_gate "$REPO" bash /gaia-plan
  assert_gate_silent_pass
}

@test "pull gate: null gaiaOriginVersion passes silently" {
  make_gate_repo 2.0.3 '{"gaiaOriginVersion":null}'
  run_gate "$REPO" bash /gaia-plan
  assert_gate_silent_pass
}

@test "pull gate: non-version gaiaOriginVersion passes silently" {
  local bad
  for bad in '"latest"' '"2.0"' '"2.0.x"' '"v2.0.4"' '7'; do
    make_gate_repo 2.0.3 "{\"gaiaOriginVersion\":$bad}"
    run_gate "$REPO" bash /gaia-plan
    assert_gate_silent_pass || { echo "origin value $bad did not pass" >&2; return 1; }
  done
}

@test "pull gate: missing local VERSION passes silently" {
  make_gate_repo - "$GATE_BEHIND_CACHE"
  run_gate "$REPO" bash /gaia-plan
  assert_gate_silent_pass
}

@test "pull gate: non-version local VERSION passes silently" {
  make_gate_repo "not-a-version" "$GATE_BEHIND_CACHE"
  run_gate "$REPO" bash /gaia-plan
  assert_gate_silent_pass
}

@test "pull gate: a teammate's claim with origin equal to local passes" {
  make_gate_repo 2.0.4 '{"gaiaOriginVersion":"2.0.4","gaiaHasUpdate":false,"gaiaUpdateClaims":[{"login":"teammate","branch":"update/2.0.5","pr":1}]}'
  run_gate "$REPO" bash /gaia-plan
  assert_gate_silent_pass
}

@test "pull gate: update available with origin equal to local passes" {
  make_gate_repo 2.0.4 '{"gaiaOriginVersion":"2.0.4","gaiaHasUpdate":true,"gaiaLatest":"2.0.9"}'
  run_gate "$REPO" bash /gaia-plan
  assert_gate_silent_pass
}

@test "pull gate: sourced under zsh it still returns 1 when behind, and 2 from a worktree" {
  command -v zsh >/dev/null 2>&1 || skip "zsh not installed"
  make_gate_repo 2.0.3 "$GATE_BEHIND_CACHE"
  make_worktree "$REPO" gate-zsh gate-zsh-branch
  run_gate "$REPO" zsh /gaia-plan
  [ "$status" -eq 1 ]
  [ "$output" = "$GATE_BEHIND_LINE" ]
  run_gate "$WORKTREE" zsh /gaia-plan
  [ "$status" -eq 2 ]
  grep -qF -- "Next step: run /update-gaia in the main checkout at $REPO to pull, then start /gaia-plan again." <<<"$output" || return 1
}

@test "pull gate: relative source from a checkout root works as the call sites run it" {
  make_gate_repo 2.0.3 "$GATE_BEHIND_CACHE"
  run run_in "$REPO" -- env PATH="$GATE_PATH" bash -c '. .gaia/scripts/main-only-lib.sh; gaia_pull_gate "/gaia-plan"'
  [ "$status" -eq 1 ]
  [ "$output" = "$GATE_BEHIND_LINE" ]
}

@test "pull gate mutation: an inverted comparison fails the behind case" {
  make_gate_repo 2.0.3 "$GATE_BEHIND_CACHE"
  local mutant="$BATS_TEST_TMPDIR/mutant-lib"
  mkdir -p "$mutant"
  cp "$REPO/.gaia/scripts/main-root-lib.sh" "$mutant/"
  sed 's/^  _gaia_pull_gate_is_behind "\$local_version" "\$origin_version" || return 0$/  _gaia_pull_gate_is_behind "$local_version" "$origin_version" \&\& return 0/' \
    "$REPO/.gaia/scripts/main-only-lib.sh" >"$mutant/main-only-lib.sh"
  ! cmp -s "$mutant/main-only-lib.sh" "$REPO/.gaia/scripts/main-only-lib.sh" || { echo "mutation did not apply" >&2; return 1; }
  run_gate "$REPO" bash /gaia-plan "$mutant/main-only-lib.sh"
  [ "$status" -ne 1 ]
}

@test "pull gate mutation: without the linked-worktree branch a worktree returns 1, not 2" {
  make_gate_repo 2.0.3 "$GATE_BEHIND_CACHE"
  make_worktree "$REPO" gate-mut gate-mut-branch
  local mutant="$BATS_TEST_TMPDIR/mutant-lib"
  mkdir -p "$mutant"
  cp "$REPO/.gaia/scripts/main-root-lib.sh" "$mutant/"
  sed 's/^  if gaia_is_linked_worktree; then$/  if false; then/' \
    "$REPO/.gaia/scripts/main-only-lib.sh" >"$mutant/main-only-lib.sh"
  ! cmp -s "$mutant/main-only-lib.sh" "$REPO/.gaia/scripts/main-only-lib.sh" || { echo "mutation did not apply" >&2; return 1; }
  run_gate "$WORKTREE" bash /gaia-plan "$mutant/main-only-lib.sh"
  [ "$status" -eq 1 ]
}
