#!/usr/bin/env bats
#
# Doc-pin: /update-deps runs a default-branch, interactive run in its own
# worktree.
#
# Static checks over `.claude/skills/update-deps/SKILL.md` and its references
# `worktree.md` (the one worktree-creation instruction) and `publish.md`:
# the run modes and their order, the single creation subsection, the points
# that route to it and how its adopter copy names them, the worktree notice and the provisioning wait, the
# cache bust call, the publish arms, and that no orchestrator block holds a
# command substitution a worktree session refuses.
#
# Each check is a function over a file path, so every test that proves the real
# page passes has a twin that runs the same function over a scratch copy with
# the guarded content removed or altered and asserts it fails.
#
# Assertion style: .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  SKILL_DIR="${REPO_ROOT}/.claude/skills/update-deps"
  SKILL="${SKILL_DIR}/SKILL.md"
  WORKTREE="${SKILL_DIR}/references/worktree.md"
  PUBLISH="${SKILL_DIR}/references/publish.md"
  SECURITY="${SKILL_DIR}/references/security.md"
  FINAL_REPORT="${SKILL_DIR}/references/final-report.md"
  local file
  for file in "$SKILL" "$WORKTREE" "$PUBLISH" "$SECURITY" "$FINAL_REPORT"; do
    [ -f "$file" ] || {
      echo "an audited page is absent: ${file}" >&2
      return 1
    }
  done
}

# scratch_copy <source> <name>: copy a file into the test's temp dir and print
# the copy's path, so a mutation never touches the shared tree.
scratch_copy() {
  local copy="${BATS_TEST_TMPDIR}/$2"
  cp "$1" "$copy"
  printf '%s\n' "$copy"
}

# replace_fixed <file> <fixed-string> <replacement>: replace every occurrence
# of a fixed string in place (no regex), and fail when the string was not
# there, so a twin can never pass because its mutation silently missed.
replace_fixed() {
  local file="$1" needle="$2" replacement="$3" mutated="${1}.mutated"
  grep -qF -- "$needle" "$file" || {
    echo "mutation target not found: ${needle}" >&2
    return 1
  }
  NEEDLE="$needle" REPLACEMENT="$replacement" awk '
    BEGIN { needle = ENVIRON["NEEDLE"]; replacement = ENVIRON["REPLACEMENT"] }
    {
      line = $0
      out = ""
      while ((position = index(line, needle)) > 0) {
        out = out substr(line, 1, position - 1) replacement
        line = substr(line, position + length(needle))
      }
      print out line
    }
  ' "$file" >"$mutated"
  mv "$mutated" "$file"
}

remove_fixed() {
  replace_fixed "$1" "$2" ""
}

# line_of <file> <fixed-string>: the first line number holding the string, or
# nothing when it is absent.
line_of() {
  NEEDLE="$2" awk 'index($0, ENVIRON["NEEDLE"]) { print NR; exit }' "$1"
}

# must_contain <file> <fixed-string> <message>: fail with the message when the
# string is absent.
must_contain() {
  grep -qF -- "$2" "$1" || {
    echo "$3" >&2
    return 1
  }
}

# must_precede <file> <earlier> <later> <message>: both strings are present and
# the first one's first line comes before the second one's.
must_precede() {
  local earlier later
  earlier="$(line_of "$1" "$2")"
  later="$(line_of "$1" "$3")"
  { [ -n "$earlier" ] && [ -n "$later" ] && [ "$earlier" -lt "$later" ]; } || {
    echo "$4" >&2
    return 1
  }
}

# ---------------------------------------------------------------------------
# 1. Creation is conditioned on the flag
# ---------------------------------------------------------------------------

CREATION_CONDITION='Run it only when `SHOULD_CREATE_WORKTREE=true`'

check_creation_condition() {
  must_contain "$WORKTREE" "$CREATION_CONDITION" "the creation subsection is not conditioned on SHOULD_CREATE_WORKTREE=true"
}

# bats test_tags=whole-tree
@test "worktree creation is conditioned on the flag" {
  check_creation_condition
}

# bats test_tags=whole-tree
@test "the creation-condition check fails with the condition deleted" {
  local copy
  copy="$(scratch_copy "$WORKTREE" "condition.md")"
  remove_fixed "$copy" "$CREATION_CONDITION"
  WORKTREE="$copy" run check_creation_condition
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# 3. No bare branch cut anywhere in the skill
# ---------------------------------------------------------------------------

# check_no_bare_branch_cut <skill-dir>: the skill page and every reference
# carry no `git checkout -b`, and the scan saw files.
check_no_bare_branch_cut() {
  local scanned=0 file
  for file in "$1/SKILL.md" "$1"/references/*.md; do
    [ -f "$file" ] || continue
    scanned=$((scanned + 1))
    if grep -qF -- 'git checkout -b' "$file"; then
      echo "a bare branch cut remains in ${file}" >&2
      return 1
    fi
  done
  [ "$scanned" -ge 2 ] || {
    echo "the scan found too few files: ${scanned}" >&2
    return 1
  }
}

# bats test_tags=whole-tree
@test "no file of the skill cuts a branch with git checkout -b" {
  check_no_bare_branch_cut "$SKILL_DIR"
}

# bats test_tags=whole-tree
@test "the bare-branch-cut check fails with a checkout -b in the Branch creation section" {
  local copy_dir="${BATS_TEST_TMPDIR}/skill-copy"
  mkdir -p "${copy_dir}/references"
  cp "$SKILL" "${copy_dir}/SKILL.md"
  cp "$SKILL_DIR"/references/*.md "${copy_dir}/references/"
  replace_fixed "${copy_dir}/SKILL.md" '## Branch creation (after discovery)' $'## Branch creation (after discovery)\n\ngit checkout -b x'
  run check_no_bare_branch_cut "$copy_dir"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# 4, 5. One creation subsection, routed from every branch point
# ---------------------------------------------------------------------------

# section_between <file> <start-fixed> <end-fixed>: the lines from the first
# line holding the start string up to, not including, the first later line
# holding the end string.
section_between() {
  START="$2" END="$3" awk '
    !inside && index($0, ENVIRON["START"]) { inside = 1 }
    inside && started && index($0, ENVIRON["END"]) { exit }
    inside { started = 1; print }
  ' "$1"
}

VENDORED_START='### Vendored skill sync'
VENDORED_END='<!-- gaia:maintainer-only:end -->'
REFRESH_START='- **Refresh-only run.**'
REFRESH_END='Do the following in order:'
POST_DECISION_STEP='2. **Worktree.**'
MAINTAINER_START='<!-- gaia:maintainer-only:start -->'
MAINTAINER_END='<!-- gaia:maintainer-only:end -->'

# is_maintainer_copy <file>: the file still carries maintainer-only markers, so
# it is the source repo's copy rather than the scrubbed one an adopter gets.
is_maintainer_copy() {
  grep -qF -- "$MAINTAINER_START" "$1"
}

# stripped_copy <file> <name>: write a copy of the file with every
# maintainer-only block removed and print its path: what an adopter reads. A
# hand-kept model of the shipped parser (`stripMarkerBlocks` in
# `.gaia/cli/src/release/marker-strip.ts`), the same one
# setup-decision-nudge.bats carries for the statusline's shell markers.
stripped_copy() {
  local copy="${BATS_TEST_TMPDIR}/$2"
  awk -v start_marker="$MAINTAINER_START" -v end_marker="$MAINTAINER_END" '
    {
      has_start_marker = index($0, start_marker) > 0
      has_end_marker = index($0, end_marker) > 0
      if (!skip && has_start_marker) { if (!has_end_marker) skip = 1; next }
      if (skip) { if (has_end_marker) skip = 0; next }
      print
    }
  ' "$1" >"$copy"
  printf '%s\n' "$copy"
}

# check_branch_points: every branch point names the creation subsection. The
# vendored-skill sync is maintainer-only, so the check requires it only in the
# source repo's copy; the scrubbed copy an adopter gets has no such section.
check_branch_points() {
  local vendored refresh
  if is_maintainer_copy "$SKILL"; then
    vendored="$(section_between "$SKILL" "$VENDORED_START" "$VENDORED_END")"
    [ -n "$vendored" ] || {
      echo "the vendored-skill sync section is not found" >&2
      return 1
    }
    grep -qF -- 'references/worktree.md' <<<"$vendored" || {
      echo "the vendored-skill sync does not name references/worktree.md" >&2
      return 1
    }
  fi
  grep -F -- "$POST_DECISION_STEP" "$SKILL" | grep -qF -- 'references/worktree.md' || {
    echo "the post-decision step does not name references/worktree.md" >&2
    return 1
  }
  refresh="$(section_between "$SKILL" "$REFRESH_START" "$REFRESH_END")"
  [ -n "$refresh" ] || {
    echo "the refresh-only path is not found" >&2
    return 1
  }
  grep -qF -- 'references/worktree.md' <<<"$refresh" || {
    echo "the refresh-only path names no creation subsection" >&2
    return 1
  }
  # The runtime call lives in the creation subsection and nowhere else.
  grep -qF -- 'EnterWorktree(' "$WORKTREE" || {
    echo "the creation subsection does not call EnterWorktree" >&2
    return 1
  }
  local other
  # gaia-lint-ignore whole-tree-mark-guard: every test that reaches this glob carries the per-test mark
  for other in "$SKILL" "$SKILL_DIR"/references/*.md; do
    [ "$other" = "$WORKTREE" ] && continue
    if grep -qF -- 'EnterWorktree(' "$other"; then
      echo "EnterWorktree( appears outside the creation subsection: ${other}" >&2
      return 1
    fi
  done
}

# bats test_tags=whole-tree
@test "every branch point names the one creation subsection" {
  check_branch_points
}

# bats test_tags=whole-tree
@test "the branch-point check fails when the refresh-only path names no subsection" {
  local copy
  copy="$(scratch_copy "$SKILL" "refresh.md")"
  replace_fixed "$copy" 'Run `references/worktree.md`' 'Run the creation step'
  SKILL="$copy" run check_branch_points
  [ "$status" -ne 0 ]
}

# bats test_tags=whole-tree
@test "the branch-point check fails when the vendored-skill sync names no subsection" {
  is_maintainer_copy "$SKILL" || skip "the scrubbed copy has no vendored-skill sync"
  local copy
  copy="$(scratch_copy "$SKILL" "vendored.md")"
  replace_fixed "$copy" '`references/worktree.md` now. The re-vendor' 'the branch now. The re-vendor'
  SKILL="$copy" run check_branch_points
  [ "$status" -ne 0 ]
}

# check_route_sentence: the creation subsection names the routes an adopter's
# SKILL.md has, and names the maintainer-only vendored-skill sync only inside a
# maintainer-only block, so neither copy names a caller its SKILL.md lacks.
check_route_sentence() {
  local adopter
  adopter="$(stripped_copy "$WORKTREE" "worktree-adopter.md")"
  must_contain "$adopter" '`## Branch creation (after discovery)`' "the adopter copy does not name the post-decision route" || return 1
  must_contain "$adopter" 'the refresh-only path' "the adopter copy does not name the refresh-only route" || return 1
  grep -qiF -- 'vendored-skill sync' "$adopter" && {
    echo "the adopter copy names the maintainer-only vendored-skill sync" >&2
    return 1
  }
  if is_maintainer_copy "$SKILL"; then
    must_contain "$WORKTREE" 'vendored-skill sync' "the maintainer copy does not name the vendored-skill sync route"
  fi
}

@test "the adopter copy of the creation subsection names only the routes its SKILL.md has" {
  check_route_sentence
}

@test "the route-sentence check fails with the vendored-skill sync named outside a maintainer-only block" {
  local copy
  copy="$(scratch_copy "$WORKTREE" "route.md")"
  printf 'The maintainer-only vendored-skill sync routes here too.\n' >>"$copy"
  WORKTREE="$copy" run check_route_sentence
  [ "$status" -ne 0 ]
}

check_refresh_only_before_phase_5b() {
  local refresh_line phase_line
  refresh_line="$(line_of "$SKILL" "$REFRESH_START")"
  phase_line="$(line_of "$SKILL" '## Phase 5b')"
  { [ -n "$refresh_line" ] && [ -n "$phase_line" ] && [ "$refresh_line" -lt "$phase_line" ]; } || {
    echo "the refresh-only creation instruction does not precede the Phase 5b section" >&2
    return 1
  }
  grep -qF -- 'and only when it reports `landed`' "$SKILL" && {
    echo "the rule that creates the branch after Phase 5b lands is still present" >&2
    return 1
  }
  true
}

@test "the refresh-only path creates the worktree before Phase 5b" {
  check_refresh_only_before_phase_5b
}

@test "the refresh-only ordering check fails with the old after-Phase-5b rule reinserted" {
  local copy
  copy="$(scratch_copy "$SKILL" "after-5b.md")"
  printf 'On a refresh-only run, run it after Phase 5b returns, and only when it reports `landed`.\n' >>"$copy"
  SKILL="$copy" run check_refresh_only_before_phase_5b
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# 6. The guard call carries the update worktree's branch prefix
# ---------------------------------------------------------------------------

GUARD_CALL='gaia_refuse_if_worktree "/update-deps" gaia_update_deps_state_line "deps/" || exit 1'

check_guard_call() {
  must_contain "$SKILL" "$GUARD_CALL" "the guard call does not carry deps/ as its third argument"
}

@test "the guard call passes the own-branch prefix" {
  check_guard_call
}

@test "the guard-call check fails with the prefix argument removed" {
  local copy
  copy="$(scratch_copy "$SKILL" "guard.md")"
  replace_fixed "$copy" 'gaia_update_deps_state_line "deps/"' 'gaia_update_deps_state_line'
  SKILL="$copy" run check_guard_call
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# 7. The creation subsection's contents
# ---------------------------------------------------------------------------

NOTICE_WARNING='Warning: --force discards any uncommitted changes in the worktree.'

@test "the creation subsection holds the worktree notice with both removal commands" {
  must_contain "$WORKTREE" 'Update worktree: <worktree path>' "the notice's first line is missing"
  must_contain "$WORKTREE" 'Branch: <branch>' "the notice's branch line is missing"
  must_contain "$WORKTREE" 'To discard it, run from the main checkout (<main checkout path>):' "the notice's discard line is missing"
  must_contain "$WORKTREE" '  git worktree remove --force <worktree path>' "the worktree removal command is missing"
  must_contain "$WORKTREE" '  git branch -D <branch>' "the branch removal command is missing"
}

check_notice_warning() {
  must_contain "$WORKTREE" "$NOTICE_WARNING" "the --force warning is missing from the notice"
}

@test "the creation subsection holds the --force warning" {
  check_notice_warning
}

@test "the warning check fails with the warning line deleted" {
  local copy
  copy="$(scratch_copy "$WORKTREE" "warning.md")"
  remove_fixed "$copy" "$NOTICE_WARNING"
  WORKTREE="$copy" run check_notice_warning
  [ "$status" -ne 0 ]
}

@test "the creation subsection waits for provisioning with the provision-wait call" {
  must_contain "$WORKTREE" 'bash .gaia/scripts/provision-wait.sh --tree <worktree path>' "the provisioning wait call is missing"
}

@test "the creation subsection states the stop rule" {
  must_contain "$WORKTREE" '## The stop rule' "the stop rule heading is missing"
  must_contain "$WORKTREE" 'leaves the worktree in place, changes nothing in the main checkout, and prints the worktree notice' "the stop rule does not keep the worktree and print the notice"
}

@test "the creation subsection hands every dispatched agent the worktree path" {
  must_contain "$WORKTREE" 'receives `<worktree path>` in its prompt as the tree it works in' "the agent-root rule is missing"
}

@test "the creation subsection cites the tool-choice contract by path" {
  must_contain "$WORKTREE" '`.claude/skills/gaia/references/spec.md` (`## Operational primitives`' "the tool-choice contract is not cited by path"
}

@test "the creation subsection re-reads discovery against the worktree" {
  must_contain "$WORKTREE" '**Re-read against the worktree.**' "the re-read rule is missing"
  must_contain "$WORKTREE" 'Re-read each apply-set package' "the reconcile step is missing"
}

# ---------------------------------------------------------------------------
# 8, 15. The publish arms
# ---------------------------------------------------------------------------

check_publish_notice_after_pr_create() {
  must_precede "$PUBLISH" '`gh pr create --draft`' 'Print the worktree notice' "the notice is not printed after gh pr create"
}

check_publish_timeout_arm() {
  local arm
  arm="$(grep -F -- '**`TIMEOUT`**' "$PUBLISH")"
  grep -qF -- '### Worktree entered by path or in an earlier session' <<<"$arm" || {
    echo "the TIMEOUT arm does not name the by-path cleanup" >&2
    return 1
  }
}

check_publish_merged_arm() {
  local arm
  arm="$(grep -F -- '**`MERGED`**' "$PUBLISH")"
  grep -qF -- '### Worktree entered by name in this session' <<<"$arm" || {
    echo "the MERGED arm does not name the by-name cleanup" >&2
    return 1
  }
  grep -qF -- '### Worktree entered by path or in an earlier session' <<<"$arm" || {
    echo "the MERGED arm does not name the by-path cleanup" >&2
    return 1
  }
}

LOCAL_SYNC_SENTENCE='That is the local-sync failure in `wiki/concepts/PR Merge Workflow.md` `## Local-sync failure mode`, not a STOP'

check_publish_local_sync() {
  must_contain "$PUBLISH" "$LOCAL_SYNC_SENTENCE" "the local-sync failure is not exempted from the STOP"
}

@test "publish prints the worktree notice after gh pr create" {
  check_publish_notice_after_pr_create
}

@test "publish's TIMEOUT arm prints the by-path cleanup" {
  check_publish_timeout_arm
}

@test "publish's MERGED arm names both worktree cleanup arms" {
  check_publish_merged_arm
}

@test "publish treats the local-sync failure as not a STOP" {
  check_publish_local_sync
}

@test "the TIMEOUT-arm check fails with the by-path pointer deleted" {
  local copy
  copy="$(scratch_copy "$PUBLISH" "timeout.md")"
  replace_fixed "$copy" 'also print the cleanup to run once the merge lands: a pointer to `.claude/skills/gaia/references/work-lifecycle.md` `### Worktree entered by path or in an earlier session`, with the worktree path and the branch filled in' 'and stop'
  PUBLISH="$copy" run check_publish_timeout_arm
  [ "$status" -ne 0 ]
}

@test "the local-sync check fails with the exemption deleted" {
  local copy
  copy="$(scratch_copy "$PUBLISH" "local-sync.md")"
  remove_fixed "$copy" "$LOCAL_SYNC_SENTENCE"
  PUBLISH="$copy" run check_publish_local_sync
  [ "$status" -ne 0 ]
}

IN_PLACE_PUBLISH='a worktree run in place because the session started inside its own update worktree (mode 1)'

check_mode_one_publish() {
  must_contain "$PUBLISH" "$IN_PLACE_PUBLISH" "publish does not take mode 1 as a worktree run" || return 1
  must_precede "$PUBLISH" 'gh pr list --head <branch-name> --state open' '`gh pr create --draft`' "the open-PR check does not come before gh pr create"
}

# bats test_tags=whole-tree
@test "mode 1 publishes as a worktree run and checks for an open PR before creating one" {
  check_mode_one_publish
}

# bats test_tags=whole-tree
@test "the mode-1 check fails with mode 1 dropped from the worktree run" {
  local copy
  copy="$(scratch_copy "$PUBLISH" "mode1.md")"
  remove_fixed "$copy" "$IN_PLACE_PUBLISH"
  PUBLISH="$copy" run check_mode_one_publish
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# 9. No orchestrator block holds a captured substitution
# ---------------------------------------------------------------------------

# fence_bodies <file>: the lines inside fenced code blocks.
fence_bodies() {
  awk '/^[[:space:]]*```/ { inside = !inside; next } inside { print }' "$1"
}

# check_plain_blocks <file>...: no fenced block holds mktemp or a command
# substitution, and none defines the state-line function inline.
check_plain_blocks() {
  local file
  [ "$#" -ge 1 ] || return 1
  for file in "$@"; do
    if fence_bodies "$file" | grep -qE 'mktemp|\$\('; then
      echo "a block in ${file} holds mktemp or a command substitution" >&2
      return 1
    fi
    if fence_bodies "$file" | grep -qF -- 'gaia_update_deps_state_line() {'; then
      echo "a block in ${file} defines the state-line function inline" >&2
      return 1
    fi
  done
}

@test "no orchestrator block holds mktemp, a command substitution or an inline state-line definition" {
  check_plain_blocks "$SKILL" "$SECURITY" "$FINAL_REPORT" "$PUBLISH"
}

@test "the plain-block check fails with a mktemp capture reinserted" {
  local copy
  copy="$(scratch_copy "$FINAL_REPORT" "mktemp.md")"
  printf '\n```bash\ncapture="$(mktemp .gaia/local/cache/shared/.x.XXXXXX)"\n```\n' >>"$copy"
  run check_plain_blocks "$SKILL" "$SECURITY" "$copy" "$PUBLISH"
  [ "$status" -ne 0 ]
}

@test "the plain-block check fails with the inline state-line definition reinserted" {
  local copy
  copy="$(scratch_copy "$SKILL" "state-line.md")"
  printf '\n```bash\ngaia_update_deps_state_line() {\n  return 0\n}\n```\n' >>"$copy"
  run check_plain_blocks "$copy" "$SECURITY" "$FINAL_REPORT" "$PUBLISH"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# 13. An existing update worktree stops the run before discovery
# ---------------------------------------------------------------------------

EXISTING_CHECK='When any record holds a `refs/heads/deps/` branch, or a `refs/heads/worktree-deps+` branch'
DISCOVERY_CALL='update-deps run --emit-updates'

check_existing_worktree_stop() {
  must_contain "$SKILL" "$EXISTING_CHECK" "the pre-flight does not check for an existing update worktree" || return 1
  must_precede "$SKILL" "$EXISTING_CHECK" "$DISCOVERY_CALL" "the existing-worktree check sits after discovery" || return 1
  must_contain "$SKILL" 're-run `/update-deps` inside it, which continues there; or remove it with the removal commands' "the stop does not name both next steps" || return 1
  must_contain "$SKILL" 'stop before discovery and create nothing' "the stop does not forbid a second worktree"
}

@test "an existing update worktree stops the run before discovery, naming both next steps" {
  check_existing_worktree_stop
}

@test "the existing-worktree check fails with the check moved after discovery" {
  local copy
  copy="$(scratch_copy "$SKILL" "existing.md")"
  remove_fixed "$copy" "$EXISTING_CHECK"
  printf '%s\n' "$EXISTING_CHECK" >>"$copy"
  SKILL="$copy" run check_existing_worktree_stop
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# 14. The cache bust
# ---------------------------------------------------------------------------

BUST_CALL='bash .gaia/scripts/update-check-bust.sh --cache <main checkout path>/.gaia/local/cache/shared/update-check.json --mode deps'
POST_MERGE_BUST_CALL='bash <main checkout path>/.gaia/scripts/update-check-bust.sh --cache <main checkout path>/.gaia/local/cache/shared/update-check.json --mode deps'
READ_BACK='read the file back'

check_cache_bust() {
  must_contain "$SKILL" "$BUST_CALL" "the bust does not call update-check-bust.sh with the main-checkout cache path" || return 1
  must_precede "$SKILL" "$BUST_CALL" "$READ_BACK" "no read-back follows the bust call" || return 1
  grep -qF -- 'Use the Write tool to overwrite' "$SKILL" && {
    echo "the Write-tool bust paragraph is still present" >&2
    return 1
  }
  true
}

@test "the cache bust calls the script at the main-checkout path and reads the file back" {
  check_cache_bust
}

@test "the cache-bust check fails with the read-back sentence deleted" {
  local copy
  copy="$(scratch_copy "$SKILL" "bust.md")"
  remove_fixed "$copy" "$READ_BACK"
  SKILL="$copy" run check_cache_bust
  [ "$status" -ne 0 ]
}

@test "the cache-bust check fails with the Write-tool paragraph reinserted" {
  local copy
  copy="$(scratch_copy "$SKILL" "write-tool.md")"
  printf 'Use the Write tool to overwrite the cache.\n' >>"$copy"
  SKILL="$copy" run check_cache_bust
  [ "$status" -ne 0 ]
}

# The decision-time bust lands before the bump reaches the main checkout, so
# any writer that marks the cache stale before the merge lets a refresh
# recount against the pre-merge tree. Only a bust after MERGED, once cleanup
# has pulled the main checkout, leaves the cache true.
check_post_merge_bust() {
  local arm
  arm="$(grep -F -- '**`MERGED`**' "$PUBLISH")"
  grep -qF -- "$POST_MERGE_BUST_CALL" <<<"$arm" || {
    echo "the MERGED arm does not bust the cache after cleanup" >&2
    return 1
  }
}

@test "publish's MERGED arm busts the cache again after cleanup" {
  check_post_merge_bust
}

@test "the post-merge bust check fails with the MERGED arm's bust deleted" {
  local copy
  copy="$(scratch_copy "$PUBLISH" "post-merge-bust.md")"
  remove_fixed "$copy" "$POST_MERGE_BUST_CALL"
  PUBLISH="$copy" run check_post_merge_bust
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# 16. A non-default branch takes the worktree path
# ---------------------------------------------------------------------------

MAIN_CHECKOUT_MODE='2. **In the main checkout, on `main`, `master` or any other branch.**'
UNDECLARED_RECONCILE='and so does a package neither of the worktree'"'"'s `package.json` files declares'

check_feature_branch_worktree() {
  must_contain "$SKILL" "$MAIN_CHECKOUT_MODE" "the worktree mode does not cover a non-default branch" || return 1
  must_contain "$WORKTREE" "$UNDECLARED_RECONCILE" "the reconcile does not drop a package the default branch does not declare" || return 1
  grep -qF -- 'push only' "$SKILL" && {
    echo "SKILL.md still states a push-only mode" >&2
    return 1
  }
  grep -qx -- '   git push' "$PUBLISH" && {
    echo "publish still has a push-only arm" >&2
    return 1
  }
  true
}

# bats test_tags=whole-tree
@test "a run on a non-default branch takes the worktree path, and no run pushes without a PR" {
  check_feature_branch_worktree
}

@test "the feature-branch check fails with the in-place mode restored" {
  local copy
  copy="$(scratch_copy "$SKILL" "in-place.md")"
  printf '5. **Any other branch.** The run works in place: no worktree, no branch, push only.\n' >>"$copy"
  SKILL="$copy" run check_feature_branch_worktree
  [ "$status" -ne 0 ]
}

@test "the feature-branch check fails with the undeclared-package reconcile deleted" {
  local copy
  copy="$(scratch_copy "$WORKTREE" "reconcile.md")"
  remove_fixed "$copy" "$UNDECLARED_RECONCILE"
  WORKTREE="$copy" run check_feature_branch_worktree
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# 17. Mode 1 waits for provisioning before discovery
# ---------------------------------------------------------------------------

PROVISION_CALL='bash .gaia/scripts/provision-wait.sh --tree <worktree path>'

check_mode_one_wait() {
  must_precede "$SKILL" "$PROVISION_CALL" "$DISCOVERY_CALL" "mode 1 has no provisioning wait before discovery"
}

# bats test_tags=whole-tree
@test "mode 1 waits for provisioning before discovery" {
  check_mode_one_wait
}

# bats test_tags=whole-tree
@test "the mode-1 wait check fails with the wait call deleted" {
  local copy
  copy="$(scratch_copy "$SKILL" "wait.md")"
  remove_fixed "$copy" "$PROVISION_CALL"
  SKILL="$copy" run check_mode_one_wait
  [ "$status" -ne 0 ]
}
