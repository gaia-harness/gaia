#!/usr/bin/env bash
# run-recall.sh: run every recall corpus entry once against one bundle.
#
#   run-recall.sh --bundle before|after --run <k> --clone <dir> --scaffold <throwaway>
#                 --out <dir> --max-usd <n> [--dry-run]
#                 [--repo <maintainer checkout>] [--bundle-sha <sha>] [--corpus <corpus.json>]
#
# --clone is the directory the real entries' replay trees are built under, one
# per entry at <clone>/<entry id> (build-tree.sh). --repo is the maintainer
# checkout they are cloned from (default: the checkout holding this script);
# --bundle-sha the bundle commit (default: the corpus's selection bundle for
# --bundle). --scaffold is a throwaway adopter checkout scaffolded from the
# bundle under test, for the planted entries; it must carry the
# .gaia/local/measurement-scratch sentinel.
#
# Each real entry: build its tree (a build failure here is an input error:
# exit 2 naming the entry, never a recorded miss and never a pass), then run
# one headless `claude -p` session in the tree whose main thread dispatches
# only the entry's member, directly, with the member brief the audit loop
# uses. The audit router is never involved, so the router's quick or light
# route for a first frontend dispatch does not apply: every member runs its
# full review. Each planted patch: a fresh branch on the scaffold, the patch
# committed, the frontend member dispatched the same way, the result copied
# to every entry of that patch. Per entry, <out>/<entry id>/ receives the
# member's findings sidecar (findings.json, absent when the member wrote
# none), the session transcripts (session.jsonl and session/), measure.json
# and, last, result.json; score.mjs treats an entry directory without
# result.json as an input error. <out>/summary.json records the run's cost and
# the specialist no-op count (specialist children found with classifyChild
# whose reply audit-noop-detect.sh --shape cra-specialist classifies no-op).
# After every entry the measured cost is added up; at --max-usd the run stops
# with summary.json marked partial.
#
# --dry-run calls no model: it builds every real entry's tree and pipes a
# synthetic PreToolUse payload for an Agent dispatch of that entry's member
# into the tree's own .claude/hooks/audit-loop-bound.sh, with the tree as cwd
# and TMPDIR inside it, and fails when the hook answers with a BLOCKED deny
# (the maintainer-repo verify gate is the one a marker left in place trips).
# Each planted patch is checked with git apply --check on the scaffold. It
# writes nothing outside the clone directory.
#
# The hook's fork check asks gh about the replay branch. GH_REPO, when unset,
# is derived from the source checkout's origin (following a local clone's
# origin to the GitHub one), so gh answers "no pull request" for the branch.
#
# Exit 0 done, 1 a dry-run BLOCKED deny, 2 usage or input error (no sentinel,
# a build failure), 3 stopped at --max-usd or a session that ended or timed
# out before the member returned.
set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
BUILD_TREE="${AUDIT_RECALL_BUILD_TREE:-$SCRIPT_DIRECTORY/build-tree.sh}"
RUNS_HELPER="$SCRIPT_DIRECTORY/lib/runs.mjs"
MEASURE_DISPATCH="$SCRIPT_DIRECTORY/../audit-cost/measure-dispatch.mjs"
RATES_FILE="$SCRIPT_DIRECTORY/../../scripts/token-rates.json"
SENTINEL_RELATIVE_PATH=".gaia/local/measurement-scratch"
POLL_SECONDS="${AUDIT_RECALL_POLL_SECONDS:-15}"
SESSION_TIMEOUT_SECONDS="${AUDIT_RECALL_SESSION_TIMEOUT_SECONDS:-2700}"

usage() {
  echo "usage: run-recall.sh --bundle before|after --run <k> --clone <dir> --scaffold <throwaway> --out <dir> --max-usd <n> [--dry-run] [--repo <checkout>] [--bundle-sha <sha>] [--corpus <corpus.json>]" >&2
}

refuse() {
  echo "ERROR: $*" >&2
  exit 2
}

bundle=""
run_number=""
clone_directory=""
scaffold=""
output_directory=""
maximum_usd=""
dry_run=0
repo=""
bundle_sha=""
corpus="$SCRIPT_DIRECTORY/corpus.json"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run)
      dry_run=1
      shift
      ;;
    --bundle | --run | --clone | --scaffold | --out | --max-usd | --repo | --bundle-sha | --corpus)
      [ "$#" -ge 2 ] && [ -n "$2" ] || { usage; exit 2; }
      case "$1" in
        --bundle) bundle="$2" ;;
        --run) run_number="$2" ;;
        --clone) clone_directory="$2" ;;
        --scaffold) scaffold="$2" ;;
        --out) output_directory="$2" ;;
        --max-usd) maximum_usd="$2" ;;
        --repo) repo="$2" ;;
        --bundle-sha) bundle_sha="$2" ;;
        --corpus) corpus="$2" ;;
      esac
      shift 2
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done
{ [ -n "$bundle" ] && [ -n "$run_number" ] && [ -n "$clone_directory" ] && [ -n "$scaffold" ] && [ -n "$output_directory" ] && [ -n "$maximum_usd" ]; } || { usage; exit 2; }
case "$bundle" in
  before | after) ;;
  *) refuse "--bundle must be before or after: $bundle" ;;
esac
grep -Eq '^[0-9]+$' <<<"$run_number" || refuse "--run must be a number: $run_number"
grep -Eq '^[0-9]+([.][0-9]+)?$' <<<"$maximum_usd" || refuse "--max-usd must be a number: $maximum_usd"
[ -f "$scaffold/$SENTINEL_RELATIVE_PATH" ] || refuse "--scaffold has no $SENTINEL_RELATIVE_PATH sentinel; a recall run uses only a throwaway: $scaffold"
[ -f "$corpus" ] || refuse "no corpus at $corpus"
jq -e '.schema == 1 and (.entries | type) == "array"' "$corpus" >/dev/null 2>&1 || refuse "$corpus is not a schema-1 corpus"
[ -n "$repo" ] || repo="$(git -C "$SCRIPT_DIRECTORY" rev-parse --show-toplevel)"
[ -n "$bundle_sha" ] || bundle_sha="$(jq -r --arg bundle "$bundle" '.selection_bundles[$bundle] // empty' "$corpus")"
[ -n "$bundle_sha" ] || refuse "no --bundle-sha and no $bundle selection bundle in $corpus"
mkdir -p "$clone_directory"
clone_directory="$(cd "$clone_directory" && pwd -P)"
scaffold="$(cd "$scaffold" && pwd -P)"
if [ "$dry_run" -eq 0 ]; then
  if [ -e "$output_directory" ] && [ -n "$(ls -A "$output_directory" 2>/dev/null)" ]; then
    refuse "--out exists and is not empty: $output_directory"
  fi
  mkdir -p "$output_directory"
  output_directory="$(cd "$output_directory" && pwd -P)"
fi

# owner/name of the GitHub repository behind a checkout, following a local
# clone's origin (a scratch clone's origin is the checkout it was cloned from).
github_repository_of() {
  local checkout="$1" url depth=0
  while [ "$depth" -lt 4 ]; do
    url="$(git -C "$checkout" remote get-url origin 2>/dev/null)" || return 1
    case "$url" in
      *github.com[:/]*)
        url="${url#*github.com[:/]}"
        printf '%s\n' "${url%.git}"
        return 0
        ;;
      /* | file://*)
        checkout="${url#file://}"
        depth=$((depth + 1))
        ;;
      *) return 1 ;;
    esac
  done
  return 1
}
if [ -z "${GH_REPO:-}" ] && GH_REPO="$(github_repository_of "$repo")"; then
  export GH_REPO
fi

real_ids=()
while IFS= read -r entry_id; do real_ids+=("$entry_id"); done < <(jq -r '.entries[] | select(.source == "real") | .id' "$corpus")
planted_patches=()
while IFS= read -r patch; do planted_patches+=("$patch"); done < <(jq -r '[.entries[] | select(.source == "planted") | .planted_patch] | unique[]' "$corpus")

entry_field() {
  jq -r --arg id "$1" --arg field "$2" '.entries[] | select(.id == $id) | .[$field] // empty' "$corpus"
}

build_entry() {
  local entry_id="$1" tree="$clone_directory/$1" build_status=0 build_log
  build_log="$(bash "$BUILD_TREE" --repo "$repo" --bundle "$bundle_sha" --base "$(entry_field "$entry_id" base_sha)" --head "$(entry_field "$entry_id" head_sha)" --clone "$tree" 2>&1 >/dev/null)" || build_status=$?
  if [ "$build_status" -ne 0 ]; then
    echo "ERROR: $entry_id: the replay tree did not build (exit $build_status): $(printf '%s\n' "$build_log" | tail -n 1)" >&2
    echo "A build failure at run time is an input error, never a miss: re-check the corpus (select.mjs --check) against this bundle." >&2
    exit 2
  fi
}

# The backticks are literal: the brief shows the member a command to run.
# shellcheck disable=SC2016
member_brief() {
  local root="$1" member="$2" tree
  tree="$(git -C "$root" rev-parse 'HEAD^{tree}')"
  printf 'Working root: %s\n' "$root"
  printf 'Run your definition'"'"'s root fence with AUDIT_ROOT=%s ahead of it, then type %s wherever a command in your definition writes <root>, never carrying it in a shell variable. Expected HEAD tree: %s, the tree captured immediately before this dispatch.\n' "$root" "$root" "$tree"
  printf 'MANDATORY FIRST ACTION, before any review: run `git -C %s rev-parse HEAD^{tree}` and compare it to %s. If that command errors OR the value does not match exactly, STOP, do not review, do not write a marker, and return only the mismatch or error as your entire output.\n' "$root" "$tree"
  printf 'SECOND ACTION, still before any review: run your definition'"'"'s scope resolver, after the protocol Read your definition names. Read your own agent definition at %s/.claude/agents/%s.md only when the resolver prints DEFINITION=reread.\n' "$root" "$member"
  printf 'Only on an exact match, review all changes in %s'"'"'s current branch compared to main, scoping every git command to `git -C %s`, and write your findings sidecar as your definition says.\n' "$root" "$root"
}

dry_run_hook() {
  local entry_id="$1" member="$2" tree="$3" payload hook_output hook_status=0
  payload="$(jq -n --arg member "$member" --arg root "$tree" --arg session "recall-dry-run-$entry_id" --arg prompt "$(member_brief "$tree" "$member")" \
    '{session_id: $session, cwd: $root, hook_event_name: "PreToolUse", tool_name: "Agent",
      tool_input: {subagent_type: $member, description: "Recall replay review", prompt: $prompt}}')"
  mkdir -p "$tree/.gaia/local/tmp"
  hook_output="$(cd "$tree" && TMPDIR="$tree/.gaia/local/tmp" bash .claude/hooks/audit-loop-bound.sh <<<"$payload" 2>&1)" || hook_status=$?
  if [ "$hook_status" -ne 0 ] || grep -q 'BLOCKED' <<<"$hook_output"; then
    echo "dry-run: $entry_id: $member dispatch denied (hook exit $hook_status):" >&2
    { jq -r '.hookSpecificOutput.permissionDecisionReason // empty' <<<"$hook_output" 2>/dev/null || printf '%s\n' "$hook_output"; } | head -n 3 >&2
    return 1
  fi
  echo "dry-run: $entry_id: $member dispatch allowed"
}

if [ "$dry_run" -eq 1 ]; then
  denied=0
  for entry_id in "${real_ids[@]+"${real_ids[@]}"}"; do
    build_entry "$entry_id"
    dry_run_hook "$entry_id" "$(entry_field "$entry_id" member)" "$clone_directory/$entry_id" || denied=1
  done
  for patch in "${planted_patches[@]+"${planted_patches[@]}"}"; do
    git -C "$scaffold" apply --check "$SCRIPT_DIRECTORY/$patch" || refuse "the planted patch $patch does not apply to the scaffold"
    echo "dry-run: $patch applies to the scaffold"
  done
  exit "$denied"
fi

total_usd=0
specialist_count=0
specialist_noops=0
claude_pid=""
scaffold_branch=""

cleanup() {
  local status=$?
  trap - EXIT
  if [ -n "$claude_pid" ] && kill -0 "$claude_pid" 2>/dev/null; then
    kill "$claude_pid" 2>/dev/null || true
    wait "$claude_pid" 2>/dev/null || true
  fi
  if [ -n "$scaffold_branch" ]; then
    git -C "$scaffold" checkout --quiet main >/dev/null 2>&1 || true
    git -C "$scaffold" branch -D "$scaffold_branch" >/dev/null 2>&1 || true
  fi
  exit "$status"
}
trap cleanup EXIT

write_summary() {
  jq -n --arg bundle "$bundle" --arg sha "$bundle_sha" --argjson run "$run_number" --argjson total "$total_usd" \
    --argjson specialists "$specialist_count" --argjson noops "$specialist_noops" --argjson partial "$1" --arg stopped "${2:-}" \
    '{schema: 1, bundle: $bundle, bundle_sha: $sha, run: $run, total_cost_usd: $total, partial: $partial,
      stopped_at: (if $stopped == "" then null else $stopped end),
      noop: {specialists: $specialists, noops: $noops}}' >"$output_directory/summary.json"
}

live_transcript() {
  local stream="$1" session_id candidate
  session_id="$(jq -rs '[.[] | select(.type == "system" and .subtype == "init") | .session_id][0] // empty' "$stream" 2>/dev/null || true)"
  [ -n "$session_id" ] || return 1
  for candidate in "${CLAUDE_CONFIG_DIR:-$HOME/.claude}"/projects/*/"$session_id".jsonl; do
    [ -f "$candidate" ] || continue
    printf '%s\n' "$candidate"
    return 0
  done
  return 1
}

# dispatch_member <root> <member> <result directory>: one headless session in
# <root> whose main thread dispatches only <member>; on return the transcripts,
# the sidecar and measure.json land in <result directory>.
dispatch_member() {
  local root="$1" member="$2" result_directory="$3" stream start_marker prompt remaining transcript elapsed=0 member_done=0 sidecar
  mkdir -p "$result_directory"
  stream="$result_directory/stream.jsonl"
  start_marker="$result_directory/.started"
  : >"$start_marker"
  remaining="$(jq -n --argjson maximum "$maximum_usd" --argjson spent "$total_usd" '$maximum - $spent')"
  prompt="$(printf 'This session measures one Code Audit Team member. Make exactly one tool call: an Agent call with subagent_type "%s", description "Recall replay review", and as its prompt exactly the text between the two marker lines below. Run no other tool, review nothing yourself and dispatch nothing else. When the member has returned, reply DONE.\n-----BEGIN MEMBER PROMPT-----\n%s\n-----END MEMBER PROMPT-----\n' "$member" "$(member_brief "$root" "$member")")"
  # bypassPermissions: a replay tree is an untrusted workspace, so headless
  # claude ignores the project's allow list and the member's gh and git calls
  # wait on a prompt nobody can answer. Hooks still run.
  (
    cd "$root"
    exec env -u CLAUDE_PROJECT_DIR -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_SSE_PORT \
      claude -p "$prompt" --output-format stream-json --verbose --permission-mode bypassPermissions --max-budget-usd "$remaining"
  ) >"$stream" 2>"$result_directory/stderr.log" </dev/null &
  claude_pid=$!
  while kill -0 "$claude_pid" 2>/dev/null && [ "$elapsed" -lt "$SESSION_TIMEOUT_SECONDS" ]; do
    sleep "$POLL_SECONDS"
    elapsed=$((elapsed + POLL_SECONDS))
    if transcript="$(live_transcript "$stream")" && node "$RUNS_HELPER" member-done "$transcript" "$member"; then
      member_done=1
      break
    fi
  done
  if kill -0 "$claude_pid" 2>/dev/null; then kill "$claude_pid" 2>/dev/null || true; fi
  wait "$claude_pid" 2>/dev/null || true
  claude_pid=""
  transcript="$(live_transcript "$stream")" || { echo "ERROR: no session transcript for $result_directory" >&2; exit 3; }
  cp "$transcript" "$result_directory/session.jsonl"
  [ ! -d "${transcript%.jsonl}" ] || cp -R "${transcript%.jsonl}" "$result_directory/session"
  if [ "$member_done" -ne 1 ] && ! node "$RUNS_HELPER" member-done "$result_directory/session.jsonl" "$member"; then
    echo "ERROR: the session ended before $member returned ($result_directory)" >&2
    exit 3
  fi
  sidecar="$(find "$root/.gaia/local/audit" -maxdepth 1 -type f -name "*.$member.findings.json" -newer "$start_marker" 2>/dev/null | head -n 1 || true)"
  [ -z "$sidecar" ] || cp "$sidecar" "$result_directory/findings.json"
  node "$MEASURE_DISPATCH" --session "$result_directory/session.jsonl" --rates "$RATES_FILE" --out "$result_directory/measure.json"
}

# account <result directory> <root>: set entry_cost and add it and the entry's
# specialist no-ops to the run totals, classifying with the tree's own no-op
# detector. Called directly, never in a command substitution, whose subshell
# would drop the totals.
entry_cost=0
account() {
  local result_directory="$1" root="$2" reply
  entry_cost="$(jq '[.dispatches[]?.cost_usd // 0] | add // 0' "$result_directory/measure.json")"
  total_usd="$(jq -n --argjson total "$total_usd" --argjson cost "$entry_cost" '$total + $cost')"
  node "$RUNS_HELPER" specialist-replies "$result_directory/session.jsonl" "$result_directory/specialist-replies" >/dev/null
  for reply in "$result_directory"/specialist-replies/*.txt; do
    [ -f "$reply" ] || continue
    specialist_count=$((specialist_count + 1))
    bash "$root/.gaia/scripts/audit-noop-detect.sh" --shape cra-specialist --path "$reply" >/dev/null 2>&1 || specialist_noops=$((specialist_noops + 1))
  done
}

record_result() {
  local entry_id="$1" result_directory="$2" cost="$3"
  jq -n --arg id "$entry_id" --arg bundle "$bundle" --argjson run "$run_number" --argjson cost "$cost" \
    --argjson findings "$([ -f "$result_directory/findings.json" ] && echo true || echo false)" \
    '{schema: 1, id: $id, bundle: $bundle, run: $run, cost_usd: $cost, findings_sidecar: $findings}' >"$result_directory/result.json"
}

stop_when_spent() {
  if jq -en --argjson total "$total_usd" --argjson maximum "$maximum_usd" '$total >= $maximum' >/dev/null; then
    write_summary true "$1"
    echo "stopped: the accumulated cost $total_usd reached --max-usd $maximum_usd after $1" >&2
    exit 3
  fi
}

for entry_id in "${real_ids[@]+"${real_ids[@]}"}"; do
  build_entry "$entry_id"
  result_directory="$output_directory/$entry_id"
  dispatch_member "$clone_directory/$entry_id" "$(entry_field "$entry_id" member)" "$result_directory"
  account "$result_directory" "$clone_directory/$entry_id"
  record_result "$entry_id" "$result_directory" "$entry_cost"
  stop_when_spent "$entry_id"
done

for patch in "${planted_patches[@]+"${planted_patches[@]}"}"; do
  patch_name="$(basename "$patch" .patch)"
  scaffold_branch="recall-$patch_name-$bundle-$run_number-$(date +%s)"
  git -C "$scaffold" checkout --quiet main
  git -C "$scaffold" checkout --quiet -b "$scaffold_branch"
  git -C "$scaffold" apply "$SCRIPT_DIRECTORY/$patch"
  git -C "$scaffold" add -A -- frontend
  git -C "$scaffold" -c user.name=measurement -c user.email=measurement@example.com -c commit.gpgsign=false \
    commit --quiet --no-verify -m "feat: planted recall change $patch_name"
  patch_directory="$output_directory/.planted-$patch_name"
  dispatch_member "$scaffold" code-audit-frontend "$patch_directory"
  account "$patch_directory" "$scaffold"
  while IFS= read -r entry_id; do
    mkdir -p "$output_directory/$entry_id"
    cp -R "$patch_directory/." "$output_directory/$entry_id/"
    record_result "$entry_id" "$output_directory/$entry_id" "$entry_cost"
  done < <(jq -r --arg patch "$patch" '.entries[] | select(.source == "planted" and .planted_patch == $patch) | .id' "$corpus")
  git -C "$scaffold" checkout --quiet main
  git -C "$scaffold" branch -D "$scaffold_branch" >/dev/null
  scaffold_branch=""
  stop_when_spent "$patch"
done

write_summary false
