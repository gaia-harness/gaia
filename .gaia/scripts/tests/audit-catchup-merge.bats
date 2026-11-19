#!/usr/bin/env bats
#
# The whole audit loop across a catch-up merge, end to end. A light sandbox
# (a scratch repository carrying copies of this checkout's gate machinery on
# the base, a bare origin standing in for GitHub, the shipped roster) holds
# markers written by the real clearance writer after a real scope-helper
# capture; the base then moves, the branch merges it, and the real merge gate
# and status poster decide. Assertions are on the gate's JSON decision, the gh
# stub's call log and the files the writer and resolver key.
#
# The roster is the shipped one. Paths below are owned by exactly one member:
#   apps/web/app/**   code-audit-frontend (the default member)
#   .githooks/**      code-audit-maintainer-shell
# and `.claude/rules/**` is gate machinery every member's digest selects. The
# remaining roster members cover none of these and are the non-covering
# specialists.
#
# Run under bash 5: `bash .gaia/scripts/bats5.sh
# .gaia/scripts/tests/audit-catchup-merge.bats < /dev/null`.
# Assertion style: .claude/rules/bats-assertions.md.

# bats-selector fixture-only: CHANGELOG.md

bats_require_minimum_version 1.5.0

# One plain sandbox is built for the file; every test's lsb_init copies it.
setup_file() {
  command -v jq >/dev/null 2>&1 || skip "jq not available"
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  # shellcheck source=.gaia/scripts/tests/helpers/light-sandbox.sh
  . "$REPO_ROOT/.gaia/scripts/tests/helpers/light-sandbox.sh"
  lsb_build_templates plain
}

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  if ! command -v jq >/dev/null 2>&1; then
    if [ -n "${GITHUB_ACTIONS:-}" ]; then
      echo "jq not present on a CI runner; the gate probes here would report green" >&2
      return 1
    fi
    skip "jq required"
  fi
  # shellcheck source=.gaia/scripts/tests/helpers/light-sandbox.sh
  . "$REPO_ROOT/.gaia/scripts/tests/helpers/light-sandbox.sh"
  # shellcheck source=.gaia/tests/helpers/gh-base-stub.sh
  . "$REPO_ROOT/.gaia/tests/helpers/gh-base-stub.sh"
  unset GH_TOKEN GITHUB_REPOSITORY GH_STUB_FAIL GH_STUB_HANG GH_STUB_FAIL_BRANCHES GH_STUB_HANG_BRANCHES GH_STUB_AUTH_FAIL
  FRONTEND=code-audit-frontend
  SHELL_MEMBER=code-audit-maintainer-shell
  GH_BIN="$BATS_TEST_TMPDIR/gh-bin"
  GH_LOG="$BATS_TEST_TMPDIR/gh.log"
  : >"$GH_LOG"
  gh_base_stub_install "$GH_BIN"
  lsb_init
  lsb_catchup_init
}

# --- fixtures -----------------------------------------------------------------

# roster_members: every roster member name, one per line.
roster_members() {
  sed -n 's/^  - name: //p' "$LSB_ROOT/.gaia/audit-ci.yml"
}

# digests: every member's branch-own digest at HEAD against the local base
# reference, one `<member>\t<digest>` line each.
digests() {
  bash -c '. "$1/.claude/hooks/lib/audit-digest.sh"; audit_branch_digests_local "$2"' _ "$LSB_ROOT" "$LSB_ROOT"
}

# digest_of <member>: one member's digest at HEAD.
digest_of() {
  digests | awk -F '\t' -v member="$1" '$1 == member { print $2 }'
}

# dispatched_members: the members the sandbox's resolver dispatches for HEAD.
dispatched_members() {
  bash -c 'cd "$1" && bash .gaia/scripts/resolve-audit-members.sh' _ "$LSB_ROOT"
}

# scope_value <member> <KEY>: run the real scope helper as <member> would and
# print one value of its output.
scope_value() {
  bash "$LSB_ROOT/.gaia/scripts/audit-resolve-scope.sh" --member "$1" --root "$LSB_ROOT" --skip-full-base | sed -n "s/^$2=//p" | head -1
}

# clear_member <member>: an earned clearance from the real writer, after a real
# scope capture.
clear_member() {
  local captured
  captured="$(scope_value "$1" D_SCOPE)"
  [ -n "$captured" ] || { printf 'no scope capture for %s\n' "$1" >&2; return 1; }
  bash "$LSB_ROOT/.gaia/scripts/audit-write-clearance.sh" --root "$LSB_ROOT" --member "$1" \
    --provenance earned --scope-digest "$captured" >/dev/null
}

# clear_dispatched: a clearance for every member the resolver dispatches, and a
# non-empty dispatch set.
clear_dispatched() {
  local member count=0
  while IFS= read -r member; do
    [ -n "$member" ] || continue
    clear_member "$member" || return 1
    count=$((count + 1))
  done < <(dispatched_members)
  [ "$count" -ge 2 ] || { printf 'only %s members dispatched\n' "$count" >&2; return 1; }
}

# marker_path <member> <digest>: where the writer puts an earned marker.
marker_path() {
  if [ "$1" = "$FRONTEND" ]; then
    printf '%s/.gaia/local/audit/%s.ok' "$LSB_ROOT" "$2"
  else
    printf '%s/.gaia/local/audit/%s.%s.ok' "$LSB_ROOT" "$2" "$1"
  fi
}

# gh_environment_arguments [<base tip>]: the env assignments that make the gh
# stub answer for a pull request at the sandbox HEAD whose base tip is the
# origin's current one (or the given commit).
gh_environment_arguments() {
  local tip="${1:-$(git -C "$CATCHUP_ORIGIN" rev-parse refs/heads/main)}" head files
  head="$(lsb_git rev-parse HEAD)"
  files="$(lsb_git diff --name-only "$(lsb_git merge-base HEAD "$tip" 2>/dev/null || printf HEAD)" HEAD | jq -R -s -c 'split("\n") | map(select(length > 0)) | map({path: .})')"
  printf '%s\n' \
    "PATH=$GH_BIN:$PATH" \
    "GH_STUB_LOG=$GH_LOG" \
    "GH_STUB_BASE_BRANCH=main" \
    "GH_STUB_BASE_TIP=$tip" \
    "GH_STUB_REPOSITORY=gaia-react/gaia" \
    "GH_STUB_STATUSES_JSON=${STATUSES_JSON:-[]}" \
    "GH_STUB_PR_JSON=$(jq -n -c --arg head "$head" --argjson files "${files:-[]}" '{title: "feat: catch-up", number: 12, headRefOid: $head, files: $files, body: ("<!-- gaia-pr-body-head: " + $head + " -->")}')"
}

# run_gate [<hook path>] [<base tip>]: the merge gate on a `gh pr merge`
# payload, from the sandbox root.
run_gate() {
  local hook="${1:-$LSB_ROOT/.claude/hooks/pr-merge-audit-check.sh}" environment
  environment=()
  while IFS= read -r line; do environment+=("$line"); done < <(gh_environment_arguments "${2:-}")
  # shellcheck disable=SC2016 # the inner bash expands its own positionals
  run --separate-stderr env "${environment[@]}" bash -c 'cd "$1" && printf %s "$2" | bash "$3"' _ \
    "$LSB_ROOT" "$(lsb_merge_payload 12)" "$hook"
}

# run_poster <marker path> [<poster path>] [<base tip>]: the status poster on an
# existing marker, from the sandbox root.
run_poster() {
  local poster="${2:-$LSB_ROOT/.claude/hooks/post-audit-status.sh}" environment
  environment=()
  while IFS= read -r line; do environment+=("$line"); done < <(gh_environment_arguments "${3:-}")
  # shellcheck disable=SC2016 # the inner bash expands its own positionals
  run --separate-stderr env "${environment[@]}" bash -c 'cd "$1" && bash "$2" "$3"' _ \
    "$LSB_ROOT" "$poster" "$1"
}

# assert_allowed: the gate printed no decision and exited 0.
assert_allowed() {
  [ "$status" -eq 0 ] || { printf 'status %s, stderr: %s\n' "$status" "$stderr" >&2; return 1; }
  [ -z "$output" ] || { printf 'expected an allow (empty stdout), got: %s\n' "$output" >&2; return 1; }
}

# assert_denied_naming <fragment>: a deny decision whose reason names it.
assert_denied_naming() {
  local reason
  [ "$status" -eq 0 ] || { printf 'status %s, stderr: %s\n' "$status" "$stderr" >&2; return 1; }
  [ "$(jq -r '.hookSpecificOutput.permissionDecision // ""' <<<"$output")" = "deny" ] || { printf 'not a deny: %s\n' "$output" >&2; return 1; }
  reason="$(jq -r '.hookSpecificOutput.permissionDecisionReason // ""' <<<"$output")"
  grep -qF -- "$1" <<<"$reason" || { printf 'the deny reason does not name %s:\n%s\n' "$1" "$reason" >&2; return 1; }
}

# status_posts: the status POSTs the stub logged, one per line.
status_posts() {
  grep -E -- 'repos/[^ ]+/statuses/[0-9a-f]{40}' "$GH_LOG" || true
}

# assert_success_posted_on <sha>: the stub logged a GAIA-Audit success POST on
# <sha>.
assert_success_posted_on() {
  status_posts | grep -F -- "statuses/$1" | grep -qF -- 'state=success'
}

# seed_shared_file: a numbered file the base carries before the branch edits it
# far from where the base later does.
seed_shared_file() {
  lsb_catchup_base_commit apps/web/app/shared.md "$(catchup_lines 40 line)"
  lsb_catch_up
}

# branch_work: the branch's own change, spanning two members: line 30 of the
# shared frontend file and a git hook.
branch_work() {
  lsb_catchup_branch_commit apps/web/app/shared.md "$(catchup_lines 40 line 30=branch-edit)"
  lsb_catchup_branch_commit .githooks/pre-commit "branch hook"
}

# base_moves: the base edits line 2 of the shared file (more than three lines
# from the branch's hunk), adds a file under each member's owned set that the
# branch did not touch, and adds a gate-machinery file that is neither the
# roster, the classifier nor the digest engine.
base_moves() {
  lsb_catchup_base_commit apps/web/app/shared.md "$(catchup_lines 40 line 2=base-edit)"
  lsb_catchup_base_commit apps/web/app/base-only.md "from the base"
  lsb_catchup_base_commit .githooks/base-only "from the base"
  lsb_catchup_base_commit .claude/rules/base-only.md "from the base"
}

# loop_state_file: where the sandbox records audit-loop rounds.
loop_state_file() {
  printf '%s/.gaia/local/protected/audit-loop/%s.json' "$LSB_ROOT" "$LSB_BRANCH"
}

# --- a clean catch-up merge ---------------------------------------------------

@test "a clean catch-up leaves every digest, every marker and the loop state alone, and the gate and poster pass" {
  seed_shared_file
  branch_work
  clear_dispatched
  lsb_seed_loop_state "$FRONTEND"
  local before before_state frontend_digest
  before="$(digests)"
  before_state="$(cat "$(loop_state_file)")"
  frontend_digest="$(digest_of "$FRONTEND")"
  [ "$(printf '%s\n' "$before" | grep -c .)" -ge 3 ]
  [ -f "$(marker_path "$FRONTEND" "$frontend_digest")" ]

  base_moves
  lsb_catch_up
  [ "$(lsb_git rev-list --parents -n 1 HEAD | wc -w | tr -d ' ')" -eq 3 ]

  [ "$(digests)" = "$before" ]
  [ "$(cat "$(loop_state_file)")" = "$before_state" ]
  run_gate
  assert_allowed
  run_poster "$(marker_path "$FRONTEND" "$frontend_digest")"
  [ "$status" -eq 0 ]
  grep -qF 'status: posted GAIA-Audit success' <<<"$output"
  assert_success_posted_on "$(lsb_git rev-parse HEAD)"
}

# --- a conflict in the changelog resolved by keeping both entries -----------------

@test "a changelog conflict resolved keeping both entries leaves every digest alone, with member-owned and machinery paths arriving beside it" {
  local before
  lsb_catchup_base_commit CHANGELOG.md "$(printf '## [Unreleased]\n\n- seed\n')"
  seed_shared_file
  branch_work
  lsb_catchup_branch_commit CHANGELOG.md "$(printf '## [Unreleased]\n\n- seed\n- branch entry\n')"
  clear_dispatched
  before="$(digests)"

  lsb_catchup_base_commit CHANGELOG.md "$(printf '## [Unreleased]\n\n- seed\n- base entry\n')"
  base_moves
  lsb_catch_up --no-commit
  [ -n "$(lsb_git ls-files --unmerged -- CHANGELOG.md)" ]
  printf '## [Unreleased]\n\n- seed\n- base entry\n- branch entry\n' >"$LSB_ROOT/CHANGELOG.md"
  lsb_commit_merge

  [ "$(digests)" = "$before" ]
  run_gate
  assert_allowed
}

# --- markers written under the previous recipe --------------------------------------

# old_recipe_digest: a digest of HEAD's whole content, the shape the marker key
# had before it was bound to the branch's own patch.
old_recipe_digest() {
  { printf 'old-recipe\0'; lsb_git ls-tree -z -r HEAD; } | { shasum -a 256 2>/dev/null || sha256sum; } | awk '{ print $1 }'
}

# --- an open finding survives a catch-up on every resolver arm ---------------------

# resolver_lines [<member>]: the resolver's stdout, from the sandbox root.
resolver_lines() {
  if [ -n "${1:-}" ]; then
    bash -c 'cd "$1" && bash .github/audit/resolve-audit-base.sh --member "$2" 2>/dev/null' _ "$LSB_ROOT" "$1"
  else
    bash -c 'cd "$1" && bash .github/audit/resolve-audit-base.sh 2>/dev/null' _ "$LSB_ROOT"
  fi
}

# resolver_reason: the reason token the member form reports for the member.
resolver_reason() {
  bash -c 'cd "$1" && bash .github/audit/resolve-audit-base.sh --member "$2" 2>&1 >/dev/null' _ "$LSB_ROOT" "$1" |
    sed -n 's/.*reason=\([a-z-]*\).*/\1/p' | head -1
}

# audit_files: the names in the audit store that are not digest-named
# markers: the ledger, the findings sidecars and the scope captures.
audit_files() {
  find "$LSB_ROOT/.gaia/local/audit" -maxdepth 1 -type f -exec basename {} \; | grep -v -E '^[0-9a-f]{64}(\.|$)' | LC_ALL=C sort
}

# writer_attempt: an earned write for the frontend member with the finding left
# unaccounted: prints the writer's exit status and the entry it names.
writer_attempt() {
  local captured
  captured="$(scope_value "$FRONTEND" D_SCOPE)"
  [ -n "$captured" ] || { printf 'no capture\n'; return 0; }
  bash "$LSB_ROOT/.gaia/scripts/audit-write-clearance.sh" --root "$LSB_ROOT" --member "$FRONTEND" \
    --provenance earned --scope-digest "$captured" 2>&1 >/dev/null | sed -n '1p;/entry_id/p' | head -3
  printf 'exit=%s\n' "${PIPESTATUS[0]}"
}

# arm_record: everything a catch-up must leave alone for the member's open
# finding: the resolver's line 3 and reason, the argument-less line, the
# artifact key, the audit store's keyed file names, and what the writer does
# with the unaccounted finding.
arm_record() {
  printf 'reason=%s\n' "$(resolver_reason "$FRONTEND")"
  printf 'line3=%s\n' "$(resolver_lines "$FRONTEND" | sed -n '3p')"
  printf 'argless=%s\n' "$(resolver_lines)"
  printf 'key=%s\n' "$(scope_value "$FRONTEND" AUDIT_KEY)"
  printf 'files=%s\n' "$(audit_files | tr '\n' ' ')"
  printf 'writer=%s\n' "$(writer_attempt | tr '\n' ' ')"
}

# refuse_with_open_finding: a frontend refusal carrying one open finding,
# written by the real findings and clearance writers after a real scope
# capture, under the key base the resolver's shared base gives (the fork point,
# which this branch's earlier catch-up has already moved off the base tip).
refuse_with_open_finding() {
  local key_base captured
  key_base="$(lsb_git merge-base "$(resolver_lines "$FRONTEND" | sed -n '3p')" HEAD)"
  captured="$(scope_value "$FRONTEND" D_SCOPE)"
  [ -n "$key_base" ] && [ -n "$captured" ] || return 1
  printf '[%s]' "$(lsb_finding apps/web/app/shared.md 30 critical false)" |
    bash "$LSB_ROOT/.gaia/scripts/audit-write-findings.sh" --root "$LSB_ROOT" --member "$FRONTEND" \
      --base "$key_base" --findings - >/dev/null || return 1
  bash "$LSB_ROOT/.gaia/scripts/audit-write-clearance.sh" --root "$LSB_ROOT" --member "$FRONTEND" \
    --provenance refused --scope-digest "$captured" --base "$key_base" >/dev/null 2>&1 || return 1
  [ -n "$(find "$LSB_ROOT/.gaia/local/audit" -name '*.rerun.json' -print -quit)" ]
}

# assert_open_finding_survives <expected reason>: record the arm, catch up
# cleanly, record it again, and require the two records to be equal. The first
# record must name the arm, carry a fork point as line 3, list the ledger, and
# show the writer refusing the unaccounted finding.
assert_open_finding_survives() {
  local before after
  before="$(arm_record)"
  grep -qxF "reason=$1" <<<"$before" || { printf 'wrong arm:\n%s\n' "$before" >&2; return 1; }
  grep -qE '^line3=[0-9a-f]{40}$' <<<"$before" || { printf 'no fork point in line 3:\n%s\n' "$before" >&2; return 1; }
  grep -qF '.rerun.json' <<<"$before" || { printf 'no ledger:\n%s\n' "$before" >&2; return 1; }
  grep -qF 'exit=3' <<<"$before" || { printf 'the writer did not refuse the unaccounted finding:\n%s\n' "$before" >&2; return 1; }

  base_moves
  lsb_catch_up
  after="$(arm_record)"
  [ "$before" = "$after" ] || { printf 'before:\n%s\nafter:\n%s\n' "$before" "$after" >&2; return 1; }
}

@test "an open finding keeps its artifact key, sidecar and scope capture across a clean catch-up on the member-refusal arm" {
  seed_shared_file
  branch_work
  refuse_with_open_finding
  lsb_catchup_branch_commit apps/web/app/after-refusal.md "after the refusal"
  assert_open_finding_survives member-refusal
}

# --- a stale, forged or shadowed local base ref ----------------------------------------

# cleared_and_caught_up: a fully cleared branch whose base then moved and was
# merged cleanly. OLD_BASE_TIP is the base tip the branch was cleared against.
cleared_and_caught_up() {
  seed_shared_file
  branch_work
  clear_dispatched
  OLD_BASE_TIP="$(lsb_git rev-parse refs/remotes/origin/main)"
  base_moves
  lsb_catch_up
}

# outcomes [<gate hook>] [<poster>]: the gate's and the poster's results, as one
# comparable text, with the frontend marker the poster is handed.
outcomes() {
  local marker
  marker="$(marker_path "$FRONTEND" "$FRONTEND_MARKER_DIGEST")"
  run_gate "${1:-}"
  printf 'gate %s %s\n' "$status" "$output"
  run_poster "$marker" "${2:-}"
  printf 'poster %s %s\n' "$status" "$output"
}

# forge <stale|forged|shadowed>: damage the local view of the base while the
# tip GitHub reports stays present locally. Stale is the base's previous tip;
# forged is a commit of the branch's own, so the branch's own change measured
# from it grows; shadowed leaves the remote-tracking ref honest and adds a
# local branch named origin/main at that same commit. None of them empties the
# set of members the changed files dispatch, which would take the gate's
# members-empty bypass and prove nothing about the base.
forge() {
  local branch_start
  branch_start="$(lsb_git log -1 --format=%H --grep='change apps/web/app/branch-start.md')"
  [ -n "$branch_start" ] || return 1
  case "$1" in
    stale) lsb_git update-ref refs/remotes/origin/main "$OLD_BASE_TIP" ;;
    forged) lsb_git update-ref refs/remotes/origin/main "$branch_start" ;;
    shadowed) lsb_git branch origin/main "$branch_start" 2>/dev/null ;;
  esac
}

# assert_forged_base_changes_nothing <fixture>: the gate and the poster reach
# the outcome the honest run does.
assert_forged_base_changes_nothing() {
  local honest forged
  cleared_and_caught_up
  FRONTEND_MARKER_DIGEST="$(digest_of "$FRONTEND")"
  honest="$(outcomes)"
  grep -qF 'gate 0 ' <<<"$honest"
  grep -qF 'poster 0 status: posted GAIA-Audit success' <<<"$honest"

  forge "$1"
  forged="$(outcomes)"
  [ "$forged" = "$honest" ] || { printf 'honest:\n%s\nforged (%s):\n%s\n' "$honest" "$1" "$forged" >&2; return 1; }
}

# bats test_tags=protected
@test "a stale, forged or shadowed local base ref changes neither the gate nor the poster outcome" {
  local honest forged tip fixture
  cleared_and_caught_up
  FRONTEND_MARKER_DIGEST="$(digest_of "$FRONTEND")"
  honest="$(outcomes)"
  grep -qF 'gate 0 ' <<<"$honest"
  grep -qF 'poster 0 status: posted GAIA-Audit success' <<<"$honest"
  tip="$(lsb_git rev-parse refs/remotes/origin/main)"

  for fixture in stale forged shadowed; do
    forge "$fixture"
    forged="$(outcomes)"
    [ "$forged" = "$honest" ] || { printf 'honest:\n%s\nforged (%s):\n%s\n' "$honest" "$fixture" "$forged" >&2; return 1; }
    lsb_git update-ref refs/remotes/origin/main "$tip"
    lsb_git branch -D origin/main >/dev/null 2>&1 || true
  done
}

# bats test_tags=protected
@test "a clearance written against a forged local base ref does not match, and the gate names the member as owing a marker" {
  local member members root_commit
  seed_shared_file
  branch_work
  members="$(dispatched_members)"
  root_commit="$(lsb_git rev-list --max-parents=0 HEAD | head -1)"
  lsb_git update-ref refs/remotes/origin/main "$root_commit"
  while IFS= read -r member; do
    [ -n "$member" ] || continue
    clear_member "$member"
  done <<<"$members"
  [ "$(printf '%s\n' "$members" | grep -c .)" -ge 2 ]

  run_gate
  assert_denied_naming "$FRONTEND"
  assert_denied_naming "$SHELL_MEMBER"
}
