#!/usr/bin/env bats

# Tests for .claude/hooks/worthiness-presence-check.sh, the merge-time half of
# the worthiness audit.
#
# The hook denies `gh pr merge` when an emergent test the PR changed has no
# worthiness-ledger line (.gaia/local/worthiness-ledger/<tree-key>/worthiness.jsonl)
# matching its current content. It scopes to the emergent test files this PR changed (the diff
# against the merge base with the default branch), decides emergent membership via
# the determinism classifier, recomputes each test's signal via the shared test-signals
# helper, and checks PRESENCE + signal match only, never the verdict. Stale-signal
# lines are rejected on recompute. It fails open on missing git/jq/node/lib/
# classifier and skips unparseable files. When zero emergent tests changed, it is
# a no-op.
#
# Setup models a PR: a base commit on `main`, then a `feature` branch carrying the
# change under test. merge-base(HEAD, main) resolves to the base commit, so the
# gate diffs only the feature's files. No remote is needed; the hook falls back
# from origin/main to main.
#
# The hook runs with pwd = the tmp repo so bare `git` resolves the staged change.
# In production pwd = the project root, where .claude/hooks/lib and .gaia/scripts
# live. To reproduce that invariant the setup symlinks those trees from the home
# repo into the tmp repo at their repo-relative paths; the symlinked helpers
# resolve `typescript` from the home repo's node_modules via createRequire.
#
# The hook always exits 0; allow vs deny is carried in stdout: a deny emits
# `"permissionDecision": "deny"`, an allow emits nothing.

# bats file_tags=installed-dependencies

# Mirror the repo-relative layout the hook resolves from a tree's own root, in
# whatever tree a case aims a merge at. Every such tree needs its own copy: the
# signal helper is invoked by the repo-relative path test_signals_signal_script
# returns, run from the tree the gate decides the merge acts on, so a linked
# worktree lacking it emits no signals and drops out of the offender scan.
install_tree_links() {
  local directory="$1"
  mkdir -p "$directory/.claude/hooks/lib" "$directory/.gaia/scripts"
  ln -sfn "$HOME_ROOT/.claude/hooks/lib/test-signals.sh" "$directory/.claude/hooks/lib/test-signals.sh"
  for repo_scope_file in repo-scope.sh repo-scope-segment.sh repo-scope-scan.sh repo-scope-home.sh; do
    ln -sfn "$HOME_ROOT/.claude/hooks/lib/$repo_scope_file" "$directory/.claude/hooks/lib/$repo_scope_file"
  done
  ln -sfn "$HOME_ROOT/.claude/hooks/lib/worthiness-ledger.sh" "$directory/.claude/hooks/lib/worthiness-ledger.sh"
  ln -sfn "$HOME_ROOT/.gaia/scripts/test-signals" "$directory/.gaia/scripts/test-signals"
  ln -sfn "$HOME_ROOT/.gaia/scripts/classifier" "$directory/.gaia/scripts/classifier"
  # worthiness_ledger_path (inside the symlinked libs
  # above) each source this relative to THEIR OWN location to reach
  # gaia_tree_key, so it needs to resolve inside the tree too, not just from
  # the hook's own BASH_SOURCE.
  ln -sfn "$HOME_ROOT/.gaia/scripts/main-root-lib.sh" "$directory/.gaia/scripts/main-root-lib.sh"
}

setup() {
  . "$BATS_TEST_DIRNAME/helpers/run-hook.sh"
  . "$BATS_TEST_DIRNAME/helpers/package-fixture.sh"
  HOME_ROOT=$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)
  # The Node helpers this suite drives resolve `typescript` from node_modules.
  # The gate fails rather than skips on a CI runner, where the dependency is a
  # precondition the job installs; see the helper for why.
  . "$BATS_TEST_DIRNAME/helpers/require-node-typescript.sh"
  require_node_typescript "$HOME_ROOT"
  HOOK_ABSOLUTE_PATH="$HOME_ROOT/.claude/hooks/worthiness-presence-check.sh"
  HELPER="$HOME_ROOT/.gaia/scripts/test-signals/extract-test-signals.mjs"

  REPO=$(mktemp -d -t worthiness-presence-test-XXXXXX)
  git -C "$REPO" init --quiet --initial-branch=main
  git -C "$REPO" config user.email "test@example.com"
  git -C "$REPO" config user.name "Test"
  git -C "$REPO" config commit.gpgsign false
  write_builtin_descriptor "$REPO"

  install_tree_links "$REPO"

  # Base commit on main with a non-test file so HEAD/merge-base exist. The
  # symlinks are untracked; they never enter the diff.
  echo "# readme" > "$REPO/README.md"
  git -C "$REPO" add README.md
  git -C "$REPO" commit --quiet -m "init"
  INITIAL_BASE=$(git -C "$REPO" rev-parse HEAD)

  git -C "$REPO" checkout --quiet -b feature
}

teardown() {
  [ -n "${REPO:-}" ] && rm -rf "$REPO" || true
  return 0
}

# Commit a file on the feature branch (so it appears in the merge-base diff).
# The optional third argument names the tree to commit in, defaulting to the
# tmp repo; a case that aims a merge at a linked worktree commits there.
commit_file() {
  local path="$1" content="$2" root="${3:-$REPO}"
  mkdir -p "$root/$(dirname "$path")"
  printf '%s' "$content" > "$root/$path"
  git -C "$root" add "$path"
  git -C "$root" commit --quiet -m "change $path"
}

# Compute the (fullName,signal) NDJSON for a repo-relative path's CURRENT on-disk
# content, using the same helper the hook uses, run from the tmp repo.
signals_for() {
  local relative_path="$1" root="${2:-$REPO}"
  ( cd "$root" && node "$HELPER" "$relative_path" )
}

# Append a worthiness-ledger line. Args: file fullName signal verdict [artifact].
# Writes to the path the shipped worthiness_ledger_path resolves for REPO, so
# the seed lands exactly where the hook itself will look, rather than a
# second hardcoded copy of the keyed literal.
seed_ledger() {
  local file="$1" full="$2" signal="$3" verdict="${4:-keep}" artifact="${5:-}" root="${6:-$REPO}"
  local ledger
  ledger="$( . "$root/.claude/hooks/lib/worthiness-ledger.sh" && worthiness_ledger_path "$root" )"
  mkdir -p "$(dirname "$ledger")"
  if [ -n "$artifact" ]; then
    jq -nc --arg f "$file" --arg n "$full" --arg s "$signal" --arg v "$verdict" --arg a "$artifact" \
      '{schema:1, file:$f, fullName:$n, signal:$s, verdict:$v, auditedAt:"2026-06-23T00:00:00Z", artifact:$a}' \
      >> "$ledger"
  else
    jq -nc --arg f "$file" --arg n "$full" --arg s "$signal" --arg v "$verdict" \
      '{schema:1, file:$f, fullName:$n, signal:$s, verdict:$v, auditedAt:"2026-06-23T00:00:00Z"}' \
      >> "$ledger"
  fi
}

# Seed a matching ledger line for one test of a changed file (computes the real
# current signal so the match is exact).
seed_matching() {
  local relative_path="$1" want_full="$2" verdict="${3:-keep}" root="${4:-$REPO}"
  local ndjson signal
  ndjson=$(signals_for "$relative_path" "$root")
  signal=$(printf '%s\n' "$ndjson" \
    | jq -r --arg n "$want_full" 'select(.fullName == $n) | .signal' | head -1)
  [ -n "$signal" ] || { echo "no signal for '$want_full' in $relative_path" >&2; return 1; }
  seed_ledger "$relative_path" "$want_full" "$signal" "$verdict" "" "$root"
}

# Run the hook with a `gh pr merge` command, from inside the tmp repo.
run_merge_hook() {
  local command="${1:-gh pr merge 30 --squash --delete-branch}"
  local json
  json=$(jq -nc --arg c "$command" '{tool_name:"Bash", tool_input:{command:$c}}')
  invoke_hook_in "$REPO" "$json" "$HOOK_ABSOLUTE_PATH"
}

# The same, from a subdirectory of the tmp repo. The agent's working directory
# is whatever the session last set, not the repository root, so every arm this
# gate depends on has to resolve from a depth nobody chose.
run_merge_hook_from() {
  local sub="$1"
  local command="${2:-gh pr merge 30 --squash --delete-branch}"
  local json
  mkdir -p "$REPO/$sub"
  json=$(jq -nc --arg c "$command" '{tool_name:"Bash", tool_input:{command:$c}}')
  invoke_hook_in "$REPO/$sub" "$json" "$HOOK_ABSOLUTE_PATH"
}

denied() { [[ "$output" == *'"permissionDecision": "deny"'* ]]; }

# Absence assertion: fail the test when the hook denied. A bare `! denied` only
# works as a test's final line -- `set -e` exempts a `!`-negated command from
# aborting, so the moment a later line is appended it silently goes inert. This
# form fails in any position (returns 1 when denied) and stays green as a final
# line when allowed (the completed `if` exits 0). See .claude/rules/bats-assertions.md.
refute_denied() { if denied; then return 1; fi; }

# An emergent component test (.tsx under apps/web/app/components/** classifies emergent).
EMERGENT_TEST='import {expect, test} from "vitest";
test("renders a label", () => {
  expect(true).toBe(true);
});
'

# An emergent component test carrying an in-test `//` comment, used for the
# comment-only-edit and absorbed-assertion cases below. PRE/POST differ only
# in the comment's wording (a reword, not a deletion).
COMMENT_EMERGENT_PRE='import {expect, test} from "vitest";
test("renders a widget", () => {
  // check the label
  expect(true).toBe(true);
});
'
COMMENT_EMERGENT_POST='import {expect, test} from "vitest";
test("renders a widget", () => {
  // verify the label text
  expect(true).toBe(true);
});
'

# Same test, but the trailing assertion is pulled onto the comment line: the
# live `expect(...)` call is gone from executed code, so the signal changes.
ABSORB_EMERGENT_PRE="$COMMENT_EMERGENT_PRE"
ABSORB_EMERGENT_POST='import {expect, test} from "vitest";
test("renders a widget", () => {
  // check the label expect(true).toBe(true);
});
'

# A deterministic util test (.ts under apps/web/app/utils/** classifies strict).
# It is judged on honesty and worth like any other, so the presence
# gate demands a verdict for it like any other test in scope.
STRICT_TEST='import {expect, test} from "vitest";
test("adds two numbers", () => {
  expect(1 + 1).toBe(2);
});
'

# --- case-table plumbing ---

# clear_ledger: drop every worthiness-ledger line REPO's gate reads.
clear_ledger() {
  rm -f "$( . "$REPO/.claude/hooks/lib/worthiness-ledger.sh" && worthiness_ledger_path "$REPO" )"
}

# reset_row: return the fixture to setup()'s state between the rows of a case
# table: main and the feature branch back at the initial commit, no ledger line,
# no registry, root descriptor or run folder, the default descriptor, and the
# real hook. Untracked fixture files a row wrote are removed by name here, since
# a hard reset keeps them.
reset_row() {
  git -C "$REPO" branch --quiet -f main "$INITIAL_BASE"
  git -C "$REPO" reset --quiet --hard "$INITIAL_BASE"
  clear_ledger
  rm -rf "$REPO/.gaia/local" "$REPO/.gaia/packages.json" "$REPO/gaia.package.json"
  write_builtin_descriptor "$REPO"
  HOOK_ABSOLUTE_PATH="$HOME_ROOT/.claude/hooks/worthiness-presence-check.sh"
}

# expect_deny <row> [needle...]: the last hook run exited 0 with a deny whose
# output carries every needle. Names the row on failure.
expect_deny() {
  local row="$1" needle
  shift
  [ "$status" -eq 0 ] || { echo "row $row: status $status: $output" >&2; return 1; }
  denied || { echo "row $row: expected a deny, got: $output" >&2; return 1; }
  for needle in "$@"; do
    grep -qF -- "$needle" <<<"$output" || { echo "row $row: the deny lacks \"$needle\": $output" >&2; return 1; }
  done
  return 0
}

# expect_allow <row>: the last hook run exited 0 without a deny.
expect_allow() {
  [ "$status" -eq 0 ] || { echo "row $1: status $status: $output" >&2; return 1; }
  denied && { echo "row $1: expected an allow, got: $output" >&2; return 1; }
  return 0
}

@test "no gated test changed: the merge is allowed for a non-test file and for non-test source under apps/web/app/components" {
  commit_file "README.md" "# changed"
  run_merge_hook
  expect_allow readme-only

  reset_row
  commit_file "apps/web/app/components/Foo/index.tsx" "export const Foo = () => null;"
  run_merge_hook
  expect_allow component-source-only
}

# Each surface's pair shares one commit: the deny without a verdict, then the
# allow once the verdict is recorded. A bats file is outside every scope glob,
# so until a flow-tests file lists it nothing is demanded.
@test "each gated surface denies without a verdict and allows with one: a strict util test, a test helper folder test, a .playwright spec, a route test, a listed bats flow test (not demanded unlisted) and a listed CLI flow test" {
  commit_file "apps/web/app/utils/x/index.test.ts" "$STRICT_TEST"
  run_merge_hook
  expect_deny strict-util "adds two numbers"
  seed_matching "apps/web/app/utils/x/index.test.ts" "adds two numbers" "keep"
  run_merge_hook
  expect_allow strict-util-with-verdict

  reset_row
  write_helper_folder_descriptor
  commit_file "apps/web/test/helper.test.ts" "$STRICT_TEST"
  run_merge_hook
  expect_deny helper-folder "adds two numbers"
  seed_matching "apps/web/test/helper.test.ts" "adds two numbers" "keep"
  run_merge_hook
  expect_allow helper-folder-with-verdict

  reset_row
  commit_file "apps/web/.playwright/e2e/home.spec.ts" "$EMERGENT_TEST"
  run_merge_hook
  expect_deny playwright-spec
  seed_matching "apps/web/.playwright/e2e/home.spec.ts" "renders a label" "keep"
  run_merge_hook
  expect_allow playwright-spec-with-verdict

  reset_row
  commit_file "$ROUTE_TEST_PATH" "$ROUTE_TEST_SOURCE"
  run_merge_hook
  expect_deny route-test "refuses an anonymous visitor"
  seed_matching "$ROUTE_TEST_PATH" "refuses an anonymous visitor"
  run_merge_hook
  expect_allow route-test-with-verdict

  reset_row
  build_flow_bats_source
  commit_file "$FLOW_BATS_PATH" "$FLOW_BATS_SOURCE"
  run_merge_hook
  expect_allow unlisted-bats-flow-test
  write_flow_tests_file "$FLOW_BATS_PATH"
  run_merge_hook
  expect_deny listed-bats-flow-test "refuses a spec that still carries uats"
  ( cd "$REPO" && node "$HOME_ROOT/.gaia/scripts/audit-ledger/append-worthiness.mjs" \
      "$FLOW_BATS_PATH" "refuses a spec that still carries uats" keep )
  run_merge_hook
  expect_allow listed-bats-flow-test-with-verdict

  reset_row
  commit_file "$FLOW_CLI_PATH" 'import {expect, test} from "vitest";
test("refuses a spec that still carries uats", () => {
  expect(1 + 1).toBe(2);
});
'
  write_flow_tests_file "$FLOW_CLI_PATH"
  run_merge_hook
  expect_deny listed-cli-flow-test "refuses a spec that still carries uats"
}

# The app's test helper folder joins the emergent list as one glob.
write_helper_folder_descriptor() {
  write_builtin_descriptor "$REPO" '' '' '["app/components/**/*.test.ts","app/components/**/*.test.tsx",".playwright/**/*.spec.ts",".playwright/**/*.spec.tsx",".playwright/**/*.test.ts",".playwright/**/*.test.tsx","app/route-tests/**/*.test.ts","test/**/*.test.ts"]'
}

@test "the descriptor's scope globs decide what is gated: the helper folder glob, an apps/web component test but not a root app/ one, an apps/web .playwright spec but not a root one, globs that match nothing, a page glob, and a literal path-dot registry" {
  write_helper_folder_descriptor
  commit_file "apps/web/test/helper.test.ts" "$STRICT_TEST"
  run_merge_hook
  expect_deny helper-folder-glob
  write_builtin_descriptor "$REPO"
  run_merge_hook
  expect_allow default-list-without-helper-folder-glob

  reset_row
  commit_file "apps/web/app/components/X/tests/X.test.tsx" "$EMERGENT_TEST"
  run_merge_hook
  expect_deny apps-web-component-test "apps/web/app/components/X/tests/X.test.tsx"
  reset_row
  commit_file "app/components/X/tests/X.test.tsx" "$EMERGENT_TEST"
  run_merge_hook
  expect_allow root-app-component-test

  reset_row
  commit_file "apps/web/.playwright/e2e/home.spec.ts" "$EMERGENT_TEST"
  run_merge_hook
  expect_deny apps-web-playwright-spec
  reset_row
  commit_file ".playwright/e2e/home.spec.ts" "$EMERGENT_TEST"
  run_merge_hook
  expect_allow root-playwright-spec

  reset_row
  write_packages_moved "$REPO"
  commit_file "apps/web/app/components/X/tests/X.test.tsx" "$EMERGENT_TEST"
  run_merge_hook
  expect_deny moved-layout-default-globs
  write_packages_moved "$REPO" '["app/**/*.test.ts"]' '["app/utils/**"]' '["nomatch/**"]'
  run_merge_hook
  expect_allow globs-matching-nothing

  reset_row
  write_packages_moved "$REPO" '["app/**/*.test.ts"]' '["app/utils/**"]' '["app/pages/**/*.test.tsx"]'
  commit_file "apps/web/app/pages/x/tests/page.test.tsx" "$EMERGENT_TEST"
  run_merge_hook
  expect_deny page-glob "renders a label"

  # The path-dot registry is untracked, so the plain reset between its two
  # halves keeps it.
  reset_row
  write_packages_today "$REPO"
  commit_file "app/components/X/tests/X.test.tsx" "$EMERGENT_TEST"
  run_merge_hook
  expect_deny path-dot-root-app-test "app/components/X/tests/X.test.tsx"
  git -C "$REPO" reset --quiet --hard "$INITIAL_BASE"
  commit_file "apps/web/app/components/X/tests/X.test.tsx" "$EMERGENT_TEST"
  run_merge_hook
  expect_allow path-dot-apps-web-test
}

# --- clean-case deny: emergent test changed, no matching ledger line ---

# bats test_tags=protected
@test "denies an emergent component test with no ledger entry" {
  commit_file "apps/web/app/components/Foo/tests/index.test.tsx" "$EMERGENT_TEST"
  run_merge_hook
  [ "$status" -eq 0 ]
  denied
  [[ "$output" == *"renders a label"* ]]
}

# The regression this pins: the gate located its shared libraries, and read
# the changed test files, by bare repository-root-relative paths, so from any
# subdirectory the loads and the reads all failed and every path out of them
# was a fail-open. One `cd` cleared the merge with no verdict demanded, and
# nothing said so. The allow row is the other half: the rooting must not make
# the gate deny everything from a subdirectory either, which would be a
# different silent break.
@test "from a subdirectory working directory the gate still denies a missing verdict and still allows a matching one" {
  commit_file "apps/web/app/components/Foo/tests/index.test.tsx" "$EMERGENT_TEST"
  run_merge_hook_from "apps/web/app/components"
  expect_deny subdirectory-without-verdict "renders a label"
  seed_matching "apps/web/app/components/Foo/tests/index.test.tsx" "renders a label" "keep"
  run_merge_hook_from "apps/web/app/components"
  expect_allow subdirectory-with-verdict
}

@test "a local branch named origin/main does not shadow the remote-tracking base" {
  # The short revspec `origin/main` resolves refs/heads/origin/main ahead of
  # refs/remotes/origin/main. A shadowing branch sitting at the feature head
  # collapses the merge base onto HEAD, empties the changed set, and clears a
  # merge whose emergent test has no verdict.
  commit_file "apps/web/app/components/Foo/tests/index.test.tsx" "$EMERGENT_TEST"
  git -C "$REPO" update-ref refs/remotes/origin/main main
  git -C "$REPO" branch origin/main HEAD
  run_merge_hook
  [ "$status" -eq 0 ]
  denied
  grep -qF -- "renders a label" <<<"$output"
}

# One committed test serves the ledger rows, each from an empty ledger. A `fix`
# verdict still satisfies presence and signal match: the verdict is advisory and
# never read for the presence decision.
@test "a gated test needs a ledger line at its current signal, whatever its verdict: an unrelated line denies, a matching keep or fix line allows, a stale signal denies, and appending a matching line turns a deny into an allow" {
  local test_path="apps/web/app/components/Foo/tests/index.test.tsx"
  local widget_path="apps/web/app/components/Widget/tests/index.test.tsx"
  local zero_signal="sha256:0000000000000000000000000000000000000000000000000000000000000000"
  commit_file "$test_path" "$EMERGENT_TEST"

  seed_ledger "apps/web/app/components/Other/tests/index.test.tsx" "something else" "sha256:deadbeef" "keep"
  run_merge_hook
  expect_deny unrelated-line-only

  clear_ledger
  seed_matching "$test_path" "renders a label" "keep"
  run_merge_hook
  expect_allow matching-keep-line

  clear_ledger
  seed_ledger "$test_path" "renders a label" \
    "$(signals_for "$test_path" | jq -r 'select(.fullName=="renders a label") | .signal')" \
    "fix" "no-interaction-assertions"
  run_merge_hook
  expect_allow matching-fix-line

  clear_ledger
  # A line written before a later edit: real file, real fullName, wrong signal.
  seed_ledger "$test_path" "renders a label" "$zero_signal" "keep"
  run_merge_hook
  expect_deny stale-signal

  reset_row
  commit_file "$widget_path" "$COMMENT_EMERGENT_PRE"
  seed_ledger "$widget_path" "renders a widget" "$zero_signal" "keep"
  run_merge_hook
  expect_deny transition-before-append
  seed_matching "$widget_path" "renders a widget"
  run_merge_hook
  expect_allow transition-after-append
}

# --- path encoding: a non-ASCII path is still scoped in ---

# Under git's default core.quotePath, `git diff --name-only` C-quotes a path
# carrying non-ASCII bytes, emitting the surrounding double quotes as literal
# characters. A quoted token starts with `"`, so it matches none of the
# emergent-surface case patterns above, drops out of the loop, and the gate
# passes on exactly the input it exists to hold -- indistinguishable, by then,
# from having nothing to flag.
@test "denies an emergent component test whose path carries non-ASCII bytes" {
  commit_file "apps/web/app/components/Café/tests/index.test.tsx" "$EMERGENT_TEST"
  run_merge_hook
  [ "$status" -eq 0 ]
  denied
}

# --- fail-open: unparseable file is skipped, not denied ---

# bats test_tags=whole-tree
@test "fails open on what it cannot read: a test file with a syntax error, a story file with a syntax error, and audit-base-provenance.sh missing on a merge the intact stage denies" {
  commit_file "apps/web/app/components/Foo/tests/index.test.tsx" 'import {test} from "vitest";
test("oops" => { syntax(((;'
  run_merge_hook
  expect_allow test-file-syntax-error

  reset_row
  write_story_descriptor
  commit_file "apps/web/app/utils/tests/broken.stories.tsx" "export const Broken = {play: async ((( => {"
  run_merge_hook
  expect_allow story-file-syntax-error

  reset_row
  commit_file "apps/web/app/components/Foo/tests/index.test.tsx" "$EMERGENT_TEST"
  run_merge_hook_staged_root ""
  expect_deny intact-staged-root
  run_merge_hook_staged_root "audit-base-provenance.sh"
  expect_allow audit-base-provenance-absent
}

# --- command-position match ---

@test "arming: a command that is not a merge is ignored; a merge after a separator, a quoted verb, a heredoc body without its opener and a heredoc piped into bash reach the gate; a cat-to-file heredoc body does not" {
  commit_file "apps/web/app/components/Foo/tests/index.test.tsx" "$EMERGENT_TEST"

  run_merge_hook "git status"
  expect_allow not-a-merge

  run_merge_hook "git fetch origin && gh pr merge 30 --squash"
  expect_deny after-a-separator

  run_merge_hook 'gh pr "merge" 30 --squash'
  expect_deny quoted-verb "Worthiness presence gate"

  run_merge_hook $'cat > f.txt <<EOF\ngh pr merge 30 --squash\nEOF\n'
  expect_allow cat-to-file-heredoc-body

  run_merge_hook $'gh pr merge 30 --squash\nEOF\n'
  expect_deny heredoc-opener-removed

  run_merge_hook $'cat <<EOF | bash\ngh pr merge 30 --squash\nEOF\n'
  expect_deny heredoc-piped-into-bash
}

# --- coexistence: deny names this gate, distinct from the audit gate ---

# The refusal reaches Claude, so naming the ledger writer in it would offer a
# way to record a verdict without the review the gate exists to require.
@test "the refusal names the gate and the evaluator as the one unblock path, offers no direct ledger write, and tells the agent to fix on the branch or ask with the rotation and CI cost, without debt wording" {
  local refusal needle
  commit_file "apps/web/app/components/Foo/tests/index.test.tsx" "$EMERGENT_TEST"
  run_merge_hook
  expect_deny names-the-gate "Worthiness presence gate"
  expect_deny names-the-evaluator "To unblock:" "worthiness evaluator"
  grep -qF -- "append-worthiness" <<<"$output" && { echo "row no-direct-ledger-write: $output" >&2; return 1; }
  refusal=$(reason_of_output)
  for needle in \
    'To unblock:' \
    'worthiness evaluator' \
    '.claude/skills/gaia/references/worthiness-step.md' \
    'only keep verdicts needs no commit' \
    'Fix a fix verdict on the branch: this is the recommendation' \
    'ask the human' \
    'clearances the fix rotates and the CI cycle it costs' \
    'Accepted residual is the alternative' \
    'Retry gh pr merge'; do
    grep -qF -- "$needle" <<<"$refusal" || { echo "row next-steps: the refusal lacks \"$needle\": $refusal" >&2; return 1; }
  done
  refusal_free_of_debt_wording "$refusal" || { echo "row no-debt-wording: $refusal" >&2; return 1; }
}

# --- comment-only edit vs. an assertion absorbed into a comment ---

@test "the signal ignores comments: a reworded comment keeps a matching verdict, the same reword with a mismatched signal denies, and an assertion absorbed into a comment denies" {
  local widget_path="apps/web/app/components/Widget/tests/index.test.tsx"
  commit_file "$widget_path" "$COMMENT_EMERGENT_PRE"
  # Seed BEFORE the edit, against the pre-edit revision's real signal.
  seed_matching "$widget_path" "renders a widget"
  commit_file "$widget_path" "$COMMENT_EMERGENT_POST"
  run_merge_hook
  expect_allow comment-reword-after-verdict
  grep -qF -- "renders a widget" <<<"$output" && { echo "row comment-reword-after-verdict: the test is named: $output" >&2; return 1; }

  reset_row
  commit_file "$widget_path" "$COMMENT_EMERGENT_PRE"
  seed_ledger "$widget_path" "renders a widget" \
    "sha256:0000000000000000000000000000000000000000000000000000000000000000" "keep"
  commit_file "$widget_path" "$COMMENT_EMERGENT_POST"
  run_merge_hook
  expect_deny comment-reword-mismatched-signal

  reset_row
  commit_file "$widget_path" "$ABSORB_EMERGENT_PRE"
  seed_matching "$widget_path" "renders a widget"
  commit_file "$widget_path" "$ABSORB_EMERGENT_POST"
  run_merge_hook
  expect_deny absorbed-assertion "renders a widget"
}

# ---------------------------------------------------------------------------
# Shared verb-arming adoption: the tokenizer arm this hook gained, and the
# data-proof that keeps a heredoc-body merge from arming it. Every case seeds
# an emergent test with NO ledger entry, so the hook has a real reason to
# deny once armed; the assertion is on the DENY TEXT, never the exit status,
# per README.md's "trap directive TST-008" for this suite.
# ---------------------------------------------------------------------------

# Stage the whole of .claude/hooks, lib/ included, into a fresh tree and
# delete LIBNAME from the staged copy, then run the STAGED hook with cwd =
# $REPO (whose OTHER libs stay the setup()-installed symlinks; this hook
# sources those cwd-relatively, so only the BASH_SOURCE-anchored verb-arming
# load is affected by which copy of the hook file runs).
run_merge_hook_library_absent() {
  local libname="$1" command="$2" json stage
  stage="$BATS_TEST_TMPDIR/staged-hooks-${libname}"
  if [ ! -d "$stage" ]; then
    cp -r "$(dirname "$HOOK_ABSOLUTE_PATH")" "$stage"
    rm -f "$stage/lib/$libname"
  fi
  json=$(jq -nc --arg c "$command" '{tool_name:"Bash", tool_input:{command:$c}}')
  invoke_hook_in "$REPO" "$json" "$stage/worthiness-presence-check.sh"
}

# bats test_tags=whole-tree
@test "a required library absent fails closed: verb-arming.sh missing denies every Bash tool call naming the file, lib/hook-payload.sh absent exits 2 naming the library" {
  local hooks_directory scratch_hooks payload
  run_merge_hook_library_absent "verb-arming.sh" "echo hi"
  expect_deny verb-arming-absent "verb-arming.sh"

  hooks_directory=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)
  scratch_hooks="$BATS_TEST_TMPDIR/scratch-hooks"
  mkdir -p "$scratch_hooks"
  cp -R "$hooks_directory/." "$scratch_hooks/"
  rm -f "$scratch_hooks/lib/hook-payload.sh"
  payload=$(jq -nc --arg command 'gh pr merge 1' '{tool_name: "Bash", tool_input: {command: $command}}')
  run bash -c 'cd "$1" && printf %s "$2" | bash "$3"' _ "$BATS_TEST_TMPDIR" "$payload" "$scratch_hooks/worthiness-presence-check.sh"
  [ "$status" -eq 2 ] || { echo "row hook-payload-absent: status $status: $output" >&2; return 1; }
  grep -qF 'BLOCKED: worthiness-presence-check.sh cannot load lib/hook-payload.sh' <<<"$output" || { echo "row hook-payload-absent: $output" >&2; return 1; }
}

# Stage a whole checkout-shaped root, not just .claude/hooks: past arming the
# hook resolves .gaia/scripts from its own location and exits 0 without it, so
# a hooks-only stage fails open on every merge and proves nothing about a lib
# the hook reaches later. An empty LIBNAME stages the intact set, the control.
run_merge_hook_staged_root() {
  local libname="$1" json stage
  stage="$BATS_TEST_TMPDIR/staged-root-${libname:-intact}"
  if [ ! -d "$stage" ]; then
    mkdir -p "$stage/.claude" "$stage/.gaia"
    cp -r "$(dirname "$HOOK_ABSOLUTE_PATH")" "$stage/.claude/hooks"
    ln -sfn "$HOME_ROOT/.gaia/scripts" "$stage/.gaia/scripts"
    [ -z "$libname" ] || rm -f "$stage/.claude/hooks/lib/$libname"
  fi
  json=$(jq -nc --arg c "gh pr merge 30 --squash" '{tool_name:"Bash", tool_input:{command:$c}}')
  invoke_hook_in "$REPO" "$json" "$stage/.claude/hooks/worthiness-presence-check.sh"
}

# ---------------------------------------------------------------------------
# The tree the merge acts on, not the tree the session sits in.
#
# A linked worktree is the same repository, so the repo-scope guard reads a
# leading `cd <worktree> &&` as home and this gate keeps enforcing. What it
# must not keep reading is its own checkout: the merge-base diff and the
# per-tree ledger both belong to the checkout the merge acts on
# (gaia-react/gaia#2013).
# ---------------------------------------------------------------------------

# A linked worktree of REPO, cut from main so its own merge-base diff holds
# only what a case commits there, and provisioned the way REPO itself is.
# Sets WORKTREE.
make_worktree() {
  WORKTREE="$BATS_TEST_TMPDIR/wt"
  git -C "$REPO" worktree add --quiet -b wt-branch "$WORKTREE" main
  install_tree_links "$WORKTREE"
  write_builtin_descriptor "$WORKTREE"
}

# Run the hook with an explicit payload cwd. run_merge_hook leaves that field
# unset, which is the shape the cases above want; these cases set it because
# the tree the command targets and the tree the session stands in differ here,
# and the field is how the gate learns the latter.
run_merge_hook_in() {
  local cwd="$1" command="$2" json
  json=$(jq -nc --arg c "$command" --arg d "$cwd" \
    '{tool_name:"Bash", cwd:$d, tool_input:{command:$c}}')
  invoke_hook_in "$cwd" "$json" "$HOOK_ABSOLUTE_PATH"
}

# The rows run the false-deny half first: the session's own un-ledgered
# emergent test belongs to a tree this merge never lands on. The session
# checkout is then reset clean, so the next deny can only come from the
# worktree. The ledger is per-tree state, so following the command's target has
# to reach the ledger lookup as well as the diff.
@test "a leading cd into a linked worktree gates that worktree: the session checkout's changed tests are not read, the worktree's are, and the worktree's own ledger allows the merge" {
  local test_path="apps/web/app/components/Foo/tests/index.test.tsx"
  make_worktree
  commit_file "$test_path" "$EMERGENT_TEST"
  run_merge_hook_in "$REPO" "cd $WORKTREE && gh pr merge 30 --squash"
  expect_allow session-checkout-test-not-read

  git -C "$REPO" reset --quiet --hard "$INITIAL_BASE"
  commit_file "$test_path" "$EMERGENT_TEST" "$WORKTREE"
  run_merge_hook_in "$REPO" "cd $WORKTREE && gh pr merge 30 --squash"
  expect_deny worktree-test-read "renders a label"

  seed_matching "$test_path" "renders a label" "keep" "$WORKTREE"
  run_merge_hook_in "$REPO" "cd $WORKTREE && gh pr merge 30 --squash"
  expect_allow worktree-ledger-read
}

# --- package scope: the emergent-test globs come from the descriptor ---

reason_of_output() {
  jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$output"
}

# Move `main` to the feature branch's tip, so what is already committed counts
# as base and only later commits are the PR's change.
advance_base_to_head() {
  git -C "$REPO" branch --quiet -f main HEAD
}

# A copy of the hook whose determinism classifier is a stub, so the hook's
# mapping of a classifier exit code is driven directly. Every other library and
# script is the real one, linked in. Args: <exit-code> <stdout>.
install_stub_classifier_home() {
  local exit_code="$1" stdout="$2" entry
  FAKE_HOME="$BATS_TEST_TMPDIR/fake-home"
  mkdir -p "$FAKE_HOME/.claude/hooks/lib" "$FAKE_HOME/.gaia/scripts/classifier"
  cp "$HOME_ROOT/.claude/hooks/worthiness-presence-check.sh" "$FAKE_HOME/.claude/hooks/"
  # gaia-lint-ignore whole-tree-mark-guard: every test that reaches this link farm carries the per-test mark
  for entry in "$HOME_ROOT"/.claude/hooks/lib/*; do
    ln -sfn "$entry" "$FAKE_HOME/.claude/hooks/lib/$(basename "$entry")"
  done
  # gaia-lint-ignore whole-tree-mark-guard: every test that reaches this link farm carries the per-test mark
  for entry in "$HOME_ROOT"/.gaia/scripts/*; do
    [ "$(basename "$entry")" = classifier ] && continue
    ln -sfn "$entry" "$FAKE_HOME/.gaia/scripts/$(basename "$entry")"
  done
  printf 'process.stdout.write(%s);\nprocess.exitCode = %s;\n' "$(jq -Rn --arg s "$stdout" '$s')" "$exit_code" \
    >"$FAKE_HOME/.gaia/scripts/classifier/classify-determinism.mjs"
  HOOK_ABSOLUTE_PATH="$FAKE_HOME/.claude/hooks/worthiness-presence-check.sh"
}

# move_root_x_test_into_apps_web: commit an emergent test under the root app/,
# make that the base, then move it into apps/web/ on the branch, staged but not
# committed.
move_root_x_test_into_apps_web() {
  commit_file "app/components/X/tests/X.test.tsx" "$EMERGENT_TEST"
  advance_base_to_head
  mkdir -p "$REPO/apps/web/app/components/X/tests"
  git -C "$REPO" mv app/components/X/tests/X.test.tsx apps/web/app/components/X/tests/X.test.tsx
}

@test "a rename is gated by its content: an exact rename into apps/web/ needs no ledger line, a new test beside it still denies naming only the new one, and a rename that changes a line denies at its new path" {
  move_root_x_test_into_apps_web
  git -C "$REPO" commit --quiet -m "move X test"
  git -C "$REPO" diff --name-status -M100% main...HEAD | grep -q '^R100' || { echo "row exact-rename: the move is not an exact rename" >&2; return 1; }
  run_merge_hook
  expect_allow exact-rename

  commit_file "apps/web/app/components/Y/tests/Y.test.tsx" "$EMERGENT_TEST"
  run_merge_hook
  expect_deny rename-plus-new-test "Y.test.tsx"
  grep -qF -- "X.test.tsx" <<<"$output" && { echo "row rename-plus-new-test: the renamed test is named: $output" >&2; return 1; }

  reset_row
  move_root_x_test_into_apps_web
  printf '%s' 'import {expect, test} from "vitest";
test("renders a label", () => {
  expect(false).toBe(false);
});
' >"$REPO/apps/web/app/components/X/tests/X.test.tsx"
  git -C "$REPO" add apps/web/app/components/X/tests/X.test.tsx
  git -C "$REPO" commit --quiet -m "move and edit X test"
  git -C "$REPO" diff --name-status -M100% main...HEAD | grep -q '^R' && { echo "row rename-with-edit: the move still reads as an exact rename" >&2; return 1; }
  run_merge_hook
  expect_deny rename-with-edit "apps/web/app/components/X/tests/X.test.tsx"
}

# bats test_tags=whole-tree
@test "a package or classifier failure denies, never allows: an unparseable registry, a registered package with no descriptor, a classifier exiting 7; a classifier exiting 3 fails open; an emergent classifier verdict demands the line" {
  local test_path="apps/web/app/components/X/tests/X.test.tsx"
  write_package_registry "$REPO" '{'
  commit_file "$test_path" "$EMERGENT_TEST"
  run_merge_hook
  expect_deny unparseable-registry
  reason_of_output | grep -qF -- 'gaia-packages: .gaia/packages.json is malformed' || { echo "row unparseable-registry: $output" >&2; return 1; }

  reset_row
  rm "$REPO/apps/web/gaia.package.json"
  write_package_registry "$REPO" '[{"name":"web","path":"apps/web"}]'
  commit_file "$test_path" "$EMERGENT_TEST"
  run_merge_hook
  expect_deny package-without-descriptor
  reason_of_output | grep -qF -- 'gaia-packages: apps/web/gaia.package.json is missing' || { echo "row package-without-descriptor: $output" >&2; return 1; }

  reset_row
  commit_file "$test_path" "$EMERGENT_TEST"
  install_stub_classifier_home 7 '{"error":"gaia-packages: stub descriptor failure. Next step: fix it."}'
  run_merge_hook
  expect_deny classifier-exit-7
  [ "$(reason_of_output)" = "gaia-packages: stub descriptor failure. Next step: fix it." ] || { echo "row classifier-exit-7: $output" >&2; return 1; }

  install_stub_classifier_home 3 ''
  run_merge_hook
  expect_allow classifier-exit-3

  install_stub_classifier_home 0 '{"file":"x","classification":"emergent","reasons":[]}'
  run_merge_hook
  expect_deny classifier-emergent
  reason_of_output | grep -qF -- 'Worthiness presence gate' || { echo "row classifier-emergent: $output" >&2; return 1; }
}

# --- story files: play stories are emergent and gated like component tests ---

# A CSF4 story file with one story carrying one test, parameterized by the
# export name and the text the test looks for. The extractor emits the story's
# base story plus its test.
story_source() {
  local export_name="$1" marker="$2"
  printf '%s\n' \
    "import preview from '#.storybook/preview';" \
    "import {expect} from 'storybook/test';" \
    "" \
    "const Marker = () => <p>${marker}</p>;" \
    "" \
    "const meta = preview.meta({component: Marker, title: 'Internal/${marker}'});" \
    "" \
    "export const ${export_name} = meta.story({});" \
    "" \
    "${export_name}.test('shows the marker', async ({canvas}) => {" \
    "  await expect(canvas.getByText('${marker}')).toBeTruthy();" \
    "});"
}

# Verdicts for both units a story_source file emits.
record_story_verdicts() {
  record_verdict "$1" "$2   base story"
  record_verdict "$1" "$2   shows the marker"
}

# Record a verdict through the real ledger writer, aimed at REPO's ledger.
record_verdict() {
  local relative_path="$1" full_name="$2" ledger
  ledger="$( . "$REPO/.claude/hooks/lib/worthiness-ledger.sh" && worthiness_ledger_path "$REPO" )"
  ( cd "$REPO" && WORTHINESS_LEDGER_PATH="$ledger" \
      node "$HOME_ROOT/.gaia/scripts/audit-ledger/append-worthiness.mjs" "$relative_path" "$full_name" keep )
}

# The fixture descriptor's default emergent globs plus the story-file glob the
# committed frontend descriptor carries.
write_story_descriptor() {
  write_builtin_descriptor "$REPO" '' '' '["app/components/**/*.test.ts","app/components/**/*.test.tsx",".playwright/**/*.spec.ts",".playwright/**/*.spec.tsx",".playwright/**/*.test.ts",".playwright/**/*.test.tsx","app/**/*.stories.tsx"]'
}

@test "story files are gated per unit: component and utility stories deny then allow once verdicts are recorded, a test without a verdict denies beside a recorded base story, a test changed after its verdict denies, a render-only file demands nothing, an old-format file and an imported play are refused" {
  local component_story="apps/web/app/components/Marker/tests/marker.stories.tsx"
  local utility_story="apps/web/app/utils/tests/utility-marker.stories.tsx"
  local story

  write_story_descriptor
  commit_file "$component_story" "$(story_source ShowsComponentMarker 'component marker')"
  commit_file "$utility_story" "$(story_source ShowsUtilityMarker 'utility marker')"
  run_merge_hook
  expect_deny component-and-utility-stories "$component_story" \
    "Shows Component Marker   base story" "Shows Component Marker   shows the marker" \
    "$utility_story" "Shows Utility Marker   shows the marker"
  record_story_verdicts "$component_story" "Shows Component Marker"
  record_story_verdicts "$utility_story" "Shows Utility Marker"
  run_merge_hook
  expect_allow component-and-utility-stories-with-verdicts

  reset_row
  write_story_descriptor
  commit_file "$utility_story" "$(story_source ShowsUtilityMarker 'utility marker')"
  record_verdict "$utility_story" "Shows Utility Marker   base story"
  run_merge_hook
  expect_deny test-without-verdict "Shows Utility Marker   shows the marker"
  grep -qF -- "Shows Utility Marker   base story" <<<"$output" && { echo "row test-without-verdict: the recorded base story is named: $output" >&2; return 1; }

  reset_row
  write_story_descriptor
  commit_file "$utility_story" "$(story_source ShowsUtilityMarker 'utility marker')"
  record_story_verdicts "$utility_story" "Shows Utility Marker"
  commit_file "$utility_story" "$(story_source ShowsUtilityMarker 'utility marker edited')"
  run_merge_hook
  expect_deny test-changed-after-verdict "Shows Utility Marker   shows the marker"

  reset_row
  write_story_descriptor
  commit_file "apps/web/app/components/Marker/tests/marker.stories.tsx" "import preview from '#.storybook/preview';

const Marker = () => <p>marker</p>;

const meta = preview.meta({component: Marker, title: 'Internal/Marker'});

export const Plain = meta.story({});
"
  run_merge_hook
  expect_allow render-only

  reset_row
  write_story_descriptor
  story="apps/web/app/utils/tests/old-format.stories.tsx"
  commit_file "$story" "$(cat "$BATS_TEST_DIRNAME/fixtures/test-signals/csf3-old-format.stories.tsx")"
  run_merge_hook
  expect_deny old-format \
    "extract-test-signals: $story is an old-format story file; migrate it with: .gaia/cli/gaia migrate-csf4" \
    "Next step:"

  reset_row
  write_story_descriptor
  story="apps/web/app/utils/tests/imported-play.stories.tsx"
  commit_file "$story" "$IMPORTED_PLAY_STORY"
  run_merge_hook
  expect_deny imported-play "$story" "unsupported story shape" "Next step:"
}

# --- the one-jq payload reader ---

# bats test_tags=whole-tree
@test "a non-arming Bash payload spawns exactly one jq process" {
  local hooks_directory shim_directory spawn_log real_jq payload spawn_count
  hooks_directory=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)
  shim_directory="$BATS_TEST_TMPDIR/jq-shim"
  spawn_log="$BATS_TEST_TMPDIR/jq-spawns"
  real_jq=$(command -v jq)
  mkdir -p "$shim_directory"
  printf '#!/bin/sh\nprintf x >>"%s"\nexec "%s" "$@"\n' "$spawn_log" "$real_jq" >"$shim_directory/jq"
  chmod +x "$shim_directory/jq"
  : >"$spawn_log"
  payload=$(jq -nc '{tool_name: "Bash", tool_input: {command: "ls -la"}}')
  run env PATH="$shim_directory:$PATH" bash -c 'cd "$1" && printf %s "$2" | bash "$3"' _ "$BATS_TEST_TMPDIR" "$payload" "$hooks_directory/worthiness-presence-check.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  spawn_count=$(wc -c <"$spawn_log" | tr -d ' ')
  [ "$spawn_count" -eq 1 ]
}

# --- the shared selection library ---

# Run the library's walk directly, the way a caller outside the hook does: its
# inputs set in the caller's own shell, the walk written to a file. Prints the
# records, then `status=<n>` and `error=<reason>` lines. Args: <tree> then an
# optional mode: `unset-ere`, `unset-classifier` or `empty-ere`.
run_selection_walk() {
  local tree="$1" mode="${2:-normal}"
  cat >"$BATS_TEST_TMPDIR/walk-driver.sh" <<'DRIVER'
tree="$1"; mode="$2"; home_root="$3"
. "$home_root/.claude/hooks/lib/gaia-packages.sh"
. "$home_root/.claude/hooks/lib/test-signals.sh"
. "$home_root/.claude/hooks/lib/worthiness-selection.sh"
gaia_packages_load "$tree" || exit 5
case "$mode" in
  empty-ere) WORTHINESS_SELECTION_ERE='' ;;
  unset-ere) ;;
  *) WORTHINESS_SELECTION_ERE=$(worthiness_selection_scope_ere) ;;
esac
if [ "$mode" != unset-classifier ]; then
  WORTHINESS_SELECTION_CLASSIFIER="$home_root/.gaia/scripts/classifier/classify-determinism.mjs"
fi
base=$(git -C "$tree" merge-base main HEAD)
records_file=$(mktemp)
walk_status=0
worthiness_selection_walk "$tree" "$base" >"$records_file" || walk_status=$?
cat "$records_file"
rm -f "$records_file"
printf 'status=%s\n' "$walk_status"
printf 'error=%s\n' "$WORTHINESS_SELECTION_ERROR"
DRIVER
  # gaia-lint-ignore whole-tree-mark-guard: operand is not the tracked tree
  run bash "$BATS_TEST_TMPDIR/walk-driver.sh" "$tree" "$mode" "$HOME_ROOT"
}

# Lines of a driver run that are walk records, not the trailing status lines.
walk_records() {
  grep -v '^status=\|^error=' <<<"$output" || true
}

TWO_TEST_FILE='import {expect, test} from "vitest";
test("first label", () => {
  expect(1).toBe(1);
});
test("second label", () => {
  expect(2).toBe(2);
});
'

# A story whose play is an imported identifier: the extractor refuses it (exit 7).
IMPORTED_PLAY_STORY="import preview from '#.storybook/preview';
import {sharedPlay} from './shared-play';

const Marker = () => <p>marker</p>;

const meta = preview.meta({component: Marker, title: 'Internal/Imported'});

export const UsesImportedPlay = meta.story({play: sharedPlay});
"

@test "the library's walk and the hook agree on a changed file, an exact rename, a deletion, a strict util test and a test outside the scope globs" {
  commit_file "apps/web/app/components/Foo/tests/index.test.tsx" "$TWO_TEST_FILE"
  commit_file "apps/web/app/components/Moved/tests/index.test.tsx" "$EMERGENT_TEST"
  commit_file "apps/web/app/components/Gone/tests/index.test.tsx" "$EMERGENT_TEST"
  advance_base_to_head
  commit_file "apps/web/app/components/Foo/tests/index.test.tsx" "${TWO_TEST_FILE/expect(1)/expect(3)}"
  mkdir -p "$REPO/apps/web/app/components/Renamed/tests"
  git -C "$REPO" mv apps/web/app/components/Moved/tests/index.test.tsx apps/web/app/components/Renamed/tests/index.test.tsx
  git -C "$REPO" rm --quiet apps/web/app/components/Gone/tests/index.test.tsx
  git -C "$REPO" commit --quiet -m "rename and delete"
  commit_file "apps/web/app/utils/x/index.test.ts" "$STRICT_TEST"
  commit_file "apps/web/tools/x/index.test.ts" "$STRICT_TEST"

  run_selection_walk "$REPO"
  grep -qx 'status=0' <<<"$output"
  local walk_pairs hook_pairs walk_path walk_line
  walk_pairs=$(walk_records | while IFS=$'\t' read -r walk_path walk_line; do
    printf '%s %s\n' "$walk_path" "$(jq -r '.fullName' <<<"$walk_line")"
  done | sort)
  [ "$walk_pairs" = "$(printf '%s\n%s\n%s' \
    'apps/web/app/components/Foo/tests/index.test.tsx first label' \
    'apps/web/app/components/Foo/tests/index.test.tsx second label' \
    'apps/web/app/utils/x/index.test.ts adds two numbers')" ]

  run_merge_hook
  denied
  hook_pairs=$(reason_of_output | grep '^  • ' | sed 's/^  • //; s/ › / /' | sort)
  [ "$hook_pairs" = "$walk_pairs" ]
}

@test "the library returns the extractor refusal status with the reason set, and the hook denies with that same reason" {
  write_story_descriptor
  commit_file "apps/web/app/utils/tests/imported-play.stories.tsx" "$IMPORTED_PLAY_STORY"
  run_selection_walk "$REPO"
  grep -qx 'status=7' <<<"$output"
  local walk_reason
  walk_reason="${output#*$'\n'error=}"
  [[ "$walk_reason" == *"unsupported story shape"* ]]

  run_merge_hook
  denied
  [ "$(reason_of_output)" = "$walk_reason" ]
}

@test "the library returns 9 and emits nothing when a required input is unset; a set but empty glob returns 0 with no records" {
  commit_file "apps/web/app/components/Foo/tests/index.test.tsx" "$EMERGENT_TEST"

  run_selection_walk "$REPO" unset-classifier
  [ -z "$(walk_records)" ]
  grep -qx 'status=9' <<<"$output"

  run_selection_walk "$REPO" unset-ere
  [ -z "$(walk_records)" ]
  grep -qx 'status=9' <<<"$output"

  run_selection_walk "$REPO" empty-ere
  [ -z "$(walk_records)" ]
  grep -qx 'status=0' <<<"$output"
}

# Failing-state assertion: returns 1 when the refusal text mentions debt.
refusal_free_of_debt_wording() {
  local text="$1"
  grep -qiF 'tech debt' <<<"$text" && return 1
  grep -qiF 'tech-debt' <<<"$text" && return 1
  return 0
}

# --- route tests: worthiness-audited on both axes ---

ROUTE_TEST_PATH="apps/web/app/route-tests/orders/tests/refuses-anonymous.test.ts"
ROUTE_TEST_SOURCE='import {expect, test} from "vitest";
test("refuses an anonymous visitor", () => {
  expect(1 + 1).toBe(2);
});
'

# --- flow files: a listed bats or CLI test is demanded whatever the scope globs say ---

FLOW_BATS_PATH=".gaia/tests/lib/flow-sample.bats"
FLOW_BATS_SOURCE=
build_flow_bats_source() {
  local AT=@
  FLOW_BATS_SOURCE="#!/usr/bin/env bats

${AT}test \"refuses a spec that still carries uats\" {
  run echo refused
  [ \"\$status\" -eq 0 ]
}
"
}
FLOW_CLI_PATH=".gaia/cli/src/flow-sample/flow-sample.test.ts"

# Write the run folder's flow-tests.tsv (flow_id, slug, kind, path) in the
# folder the hook derives from the tree's branch key. The key comes from the
# same library function the hook calls.
write_flow_tests_file() {
  local flow_path="$1" key run_folder
  key="$( . "$HOME_ROOT/.gaia/scripts/audit-loop-state-lib.sh" && gaia_loop_key "$REPO" )"
  run_folder="$( . "$HOME_ROOT/.gaia/scripts/audit-loop-state-lib.sh" && gaia_loop_run_directory "$REPO" "$key" )"
  mkdir -p "$run_folder"
  printf 'FLOW-001\tflow-sample\tcommand\t%s\n' "$flow_path" >"$run_folder/flow-tests.tsv"
}

