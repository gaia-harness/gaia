#!/usr/bin/env bats
# Executable and prose checks over /setup-gaia's decision routing: the owed
# check, who may record project decisions, each reference block that records
# a feature's settled state without a question, the land step, the setup
# ping, the label-sync degraded marker, the squash-only gate, and Phase 5's
# standalone handoff.
#
# Each block is extracted from the shipped file by its heading and run inside
# a fixture repository under $BATS_TEST_TMPDIR, whose `.gaia/cli/gaia` is a
# wrapper around the real CLI bundle: it answers `labels sync`, `sandbox
# status` (when a test sets a stub answer) and `ping` itself, and passes every
# other call, `setup record` and `setup drift` included, to the real bundle.
# `gh` is a stub on PATH answering the API paths the blocks read.
#
# The interactive questions themselves (the isolation policy, the sandbox
# recommendation, the squash-only offer) are covered by a manual /setup-gaia
# run; here their answers are driven through the literal write and record
# lines the files carry.
#
# Assertion style: .claude/rules/bats-assertions.md.

SETUP_COMMAND_PATH='.claude/commands/setup-gaia.md'
REFERENCES_PATH='.claude/skills/gaia/references/setup'

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  SETUP_COMMAND="${REPO_ROOT}/${SETUP_COMMAND_PATH}"
  REFERENCES="${REPO_ROOT}/${REFERENCES_PATH}"
  REAL_CLI="${REPO_ROOT}/.gaia/cli/gaia"
  FEATURE_LIST="${REPO_ROOT}/.gaia/setup-features.json"
  [ -x "$REAL_CLI" ] || {
    echo "the CLI bundle is absent: ${REAL_CLI}" >&2
    return 1
  }
  export REAL_CLI
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  export GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.com
  export GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.com
  STUB_BIN="${BATS_TEST_TMPDIR}/stub-bin"
  mkdir -p "$STUB_BIN"
  write_gh_stub
  export PATH="${STUB_BIN}:${PATH}"
  export GH_LOG="${BATS_TEST_TMPDIR}/gh.log" CLI_LOG="${BATS_TEST_TMPDIR}/cli.log"
  : >"$GH_LOG"
  : >"$CLI_LOG"
  export HOME="${BATS_TEST_TMPDIR}/home"
  mkdir -p "${HOME}/.claude"
}

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

# write_gh_stub: a gh that logs every call and answers the reads the blocks
# make for owner `o`, repo `r`, default branch `main`. Every mutating call is
# logged as MUTATION and succeeds.
write_gh_stub() {
  cat >"${STUB_BIN}/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_LOG"
case "$*" in
  *"-X "*) printf 'MUTATION %s\n' "$*" >>"$GH_LOG"; cat >/dev/null; exit 0 ;;
  "api repos/o/r/branches/main --jq .name") echo main ;;
  "api repos/o/r/branches/main/protection") echo '{}' ;;
  "api repos/o/r/branches/main/protection/required_status_checks --jq .contexts") echo '["GAIA-Audit", "Vitest"]' ;;
  "api repos/o/r --jq .security_and_analysis"*) echo "${GH_PUSH_STATUS:-enabled}" ;;
  "api repos/o/r --jq .delete_branch_on_merge") echo "${GH_DELETE_BRANCH:-true}" ;;
  "api repos/o/r --jq {allow_merge_commit"*)
    echo '{"allow_merge_commit": false, "allow_rebase_merge": false, "allow_squash_merge": true, "squash_merge_commit_title": "PR_TITLE", "squash_merge_commit_message": "COMMIT_MESSAGES"}' ;;
  *) exit 1 ;;
esac
STUB
  chmod +x "${STUB_BIN}/gh"
}

# make_repo <name> [list]: a git repository on `main` with one commit, the
# feature list (the real one unless a path is given), and the CLI wrapper.
# Prints its path.
make_repo() {
  local repo="${BATS_TEST_TMPDIR}/$1" list="${2:-$FEATURE_LIST}"
  mkdir -p "${repo}/.gaia/cli"
  git init -q -b main "$repo"
  printf '.gaia/local/\n.gaia/cli/\n' >"${repo}/.gitignore"
  cp "$list" "${repo}/.gaia/setup-features.json"
  cat >"${repo}/.gaia/cli/gaia" <<'WRAPPER'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  "labels sync")
    printf '%s\n' "${STUB_SYNC_STDOUT-labels-sync: 0 created, 0 renamed}"
    exit "${STUB_SYNC_STATUS:-0}"
    ;;
  "sandbox status")
    if [ -n "${STUB_SANDBOX_STATUS:-}" ]; then
      printf '%s\n' "$STUB_SANDBOX_STATUS"
      exit 0
    fi
    ;;
esac
if [ "$1" = ping ]; then
  printf '%s\n' "$*" >>"$CLI_LOG"
  exit 0
fi
exec "$REAL_CLI" "$@"
WRAPPER
  chmod +x "${repo}/.gaia/cli/gaia"
  git -C "$repo" add .gitignore .gaia/setup-features.json
  git -C "$repo" commit -q -m initial
  printf '%s\n' "$repo"
}

# make_provisioned <name>: a completed machine with all four per-machine steps
# and no decision record, a declined sandbox marker, a `gaia` statusline
# choice, a global statusline, and no .gaia/project.json.
make_provisioned() {
  local repo step
  repo="$(make_repo "$1")"
  for step in install-tools install-plugins chmod-statusline bootstrap-env; do
    in_repo "$repo" .gaia/cli/gaia setup mark-step "$step" >/dev/null || return 1
  done
  in_repo "$repo" .gaia/cli/gaia setup finalize >/dev/null || return 1
  in_repo "$repo" .gaia/cli/gaia sandbox record --outcome declined --capability ready >/dev/null || return 1
  printf '%s\n' '{"version": 1, "statusline": {"left": "gaia"}}' >"${repo}/.gaia/local/settings.json"
  printf '%s\n' '{"statusLine": {"command": "my-statusline"}}' >"${HOME}/.claude/settings.json"
  printf '%s\n' "$repo"
}

# in_repo <repo> <command...>: run a command from the repository root.
in_repo() {
  local repo="$1"
  shift
  (cd "$repo" && "$@")
}

# run_block <repo> <block> [NAME=value...]: run a block's text with bash from
# the repository root, with the given variables in its environment.
run_block() {
  local repo="$1" block="$2"
  shift 2
  [ -n "$block" ] || {
    echo "the block to run is empty" >&2
    return 1
  }
  (cd "$repo" && env "$@" bash -c "$block")
}

# block_under <file> <heading> [n]: the body of the n-th (default first)
# column-0 bash fence after the exact heading line, before the next level-two
# heading.
block_under() {
  awk -v heading="$2" -v want="${3:-1}" '
    $0 == heading { seen = 1; next }
    seen && /^## / { exit }
    seen && /^```bash[[:space:]]*$/ { inside = 1; n++; next }
    seen && inside && /^```[[:space:]]*$/ { inside = 0; if (n == want) exit; next }
    seen && inside && n == want { print }
  ' "$1"
}

# check_line <name> <id>: the owed or declined check line from
# setup-decisions.md with the id substituted.
check_line() {
  local anchor line
  case "$1" in
    owed) anchor="'any(.undecided[]?; .id == \$id)'" ;;
    declined) anchor="'.decided[\$id] == \"declined\"'" ;;
  esac
  line="$(grep -F -- "$anchor" "${REFERENCES}/setup-decisions.md" | grep -F -- '--arg id <id>' | sed 's/^ *//')"
  [ "$(grep -c . <<<"$line")" -eq 1 ] || {
    echo "expected one ${1} check line, found: ${line}" >&2
    return 1
  }
  printf '%s\n' "${line/<id>/$2}"
}

# decision <repo> <id>: the recorded value for an id, from whichever record
# file holds it, or empty.
decision() {
  in_repo "$1" .gaia/cli/gaia setup drift --json | jq -r --arg id "$2" '.decided[$id] // empty'
}

# undecided_ids <repo>: drift's undecided ids, space-separated.
undecided_ids() {
  in_repo "$1" .gaia/cli/gaia setup drift --json | jq -r '[.undecided[].id] | join(" ")'
}

# record_all_but <repo> <id>: record every listed id except one as applied.
record_all_but() {
  local repo="$1" skip="$2" id
  for id in $(jq -r '.features[].id' "$FEATURE_LIST"); do
    [ "$id" = "$skip" ] && continue
    in_repo "$repo" .gaia/cli/gaia setup record "$id" applied >/dev/null || return 1
  done
}

# assert_no_mutation: the gh stub saw no mutating call.
assert_no_mutation() {
  if grep -q '^MUTATION' "$GH_LOG"; then
    echo "a mutating gh call was made: $(grep '^MUTATION' "$GH_LOG")" >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# The owed set
# ---------------------------------------------------------------------------

@test "the owed check lists every listed id on a provisioned machine with no record and no project.json" {
  local repo output_line owed id count=0
  repo="$(make_provisioned owed-set)"
  [ ! -e "${repo}/.gaia/project.json" ]
  output_line="$(run_block "$repo" "$(block_under "${REFERENCES}/setup-decisions.md" '## The owed check')")"
  owed="$(sed -n 's/^OWED_AT_START=//p' <<<"$output_line")"
  while IFS= read -r id; do
    count=$((count + 1))
    grep -qw -- "$id" <<<"$owed" || {
      echo "${id} is missing from OWED_AT_START: ${owed}" >&2
      return 1
    }
  done < <(jq -r '.features[].id' "$FEATURE_LIST")
  [ "$count" -eq "$(jq '.features | length' "$FEATURE_LIST")" ]
  [ "$(wc -w <<<"$owed" | tr -d ' ')" -eq "$count" ]
}

@test "the owed check prints DRIFT_FAILED when the list cannot be read" {
  local repo
  repo="$(make_repo drift-failed)"
  printf 'not json\n' >"${repo}/.gaia/setup-features.json"
  run run_block "$repo" "$(block_under "${REFERENCES}/setup-decisions.md" '## The owed check')"
  grep -qx 'DRIFT_FAILED' <<<"$output"
  grep -q '^OWED_AT_START=' <<<"$output" && return 1
  true
}

# ---------------------------------------------------------------------------
# Who records project decisions
# ---------------------------------------------------------------------------

# who_records <repo> NAME=value...: run the block and print its two lines.
who_records() {
  local repo="$1"
  shift
  run_block "$repo" "$(block_under "${REFERENCES}/setup-decisions.md" '## Who records project decisions')" \
    FOUND= HOST= ADMIN= AUTH_STATUS= DEFAULT_BRANCH= "$@"
}

@test "who records: an admin on the default branch is admin, and on another branch is none" {
  local repo
  repo="$(make_repo who-admin)"
  run who_records "$repo" FOUND=true HOST=github.com ADMIN=true AUTH_STATUS=ok DEFAULT_BRANCH=main
  grep -qx 'MAY_RECORD_PROJECT=admin' <<<"$output"
  grep -qx 'DEFAULT_BRANCH=main' <<<"$output"
  git -C "$repo" checkout -q -b feature
  run who_records "$repo" FOUND=true HOST=github.com ADMIN=true AUTH_STATUS=ok DEFAULT_BRANCH=main
  grep -qx 'MAY_RECORD_PROJECT=none' <<<"$output"
}

@test "who records: a non-admin, a failed auth, and no origin are none" {
  local repo
  repo="$(make_repo who-none)"
  run who_records "$repo" FOUND=true HOST=github.com ADMIN=false AUTH_STATUS=ok DEFAULT_BRANCH=main
  grep -qx 'MAY_RECORD_PROJECT=none' <<<"$output"
  run who_records "$repo" FOUND=true HOST=github.com ADMIN=true AUTH_STATUS=unauthenticated DEFAULT_BRANCH=main
  grep -qx 'MAY_RECORD_PROJECT=none' <<<"$output"
  run who_records "$repo" FOUND=false DEFAULT_BRANCH=main
  grep -qx 'MAY_RECORD_PROJECT=none' <<<"$output"
  grep -qx 'DEFAULT_BRANCH=' <<<"$output"
}

@test "who records: a non-GitHub origin takes its default branch from origin/HEAD, and without one is none" {
  local repo origin="${BATS_TEST_TMPDIR}/who-origin.git"
  repo="$(make_repo who-other-host)"
  git init -q --bare "$origin"
  git -C "$repo" remote add origin "$origin"
  run who_records "$repo" FOUND=true HOST=git.example.com
  grep -qx 'MAY_RECORD_PROJECT=none' <<<"$output"
  grep -qx 'DEFAULT_BRANCH=' <<<"$output"
  git -C "$repo" push -q origin main
  git -C "$repo" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  run who_records "$repo" FOUND=true HOST=git.example.com
  grep -qx 'MAY_RECORD_PROJECT=not-applicable-only' <<<"$output"
  grep -qx 'DEFAULT_BRANCH=main' <<<"$output"
  git -C "$repo" checkout -q -b feature
  run who_records "$repo" FOUND=true HOST=git.example.com
  grep -qx 'MAY_RECORD_PROJECT=none' <<<"$output"
}

# ---------------------------------------------------------------------------
# Probes record without a question
# ---------------------------------------------------------------------------

# record_settled_state <repo> <may-record-project>: run every block that
# records a settled state with no question.
record_settled_state() {
  local repo="$1" may="$2" github_repo="${REFERENCES}/github-repo.md" line
  run_block "$repo" "$(block_under "${REFERENCES}/sandbox.md" '## Record a settled decision')" || return 1
  run_block "$repo" "$(block_under "${REFERENCES}/statusline-left.md" '## Record a settled choice')" \
    GLOBAL_STATUSLINE=my-statusline LEFT_CHOICE=gaia || return 1
  run_block "$repo" "$(block_under "$github_repo" '## Owed and recorded settings' 2)" \
    OWNER=o REPO=r HOST=github.com DEFAULT_BRANCH=main MAY_RECORD_PROJECT="$may" || return 1
  run_block "$repo" "$(block_under "$github_repo" '## Push protection')" \
    OWNER=o REPO=r MAY_RECORD_PROJECT="$may" || return 1
  run_block "$repo" "$(block_under "$github_repo" '## Remaining defaults')" \
    OWNER=o REPO=r MAY_RECORD_PROJECT="$may" || return 1
  run_block "$repo" "$(block_under "${REFERENCES}/squash-only.md" '# Squash-only merge question')" \
    OWNER=o REPO=r MAY_RECORD_PROJECT="$may" || return 1
  run_block "$repo" "$(block_under "$SETUP_COMMAND" '## Phase 4.5: Label sync (always evaluated)')" \
    LABEL_SYNC_OWED=true MAY_RECORD_PROJECT="$may" || return 1
  while IFS= read -r line; do
    in_repo "$repo" bash -c "$line" >/dev/null || return 1
  done < <(grep -oE '\.gaia/cli/gaia setup record [a-z-]+ applied' "${REFERENCES}/per-machine.md")
  # The Dependabot posture is applied by `gaia setup configure-dependabot-alerts`,
  # whose GitHub calls the CLI's own tests cover; its success records through
  # this gated line.
  line="$(grep -oE '\[ "\$MAY_RECORD_PROJECT" != admin \] \|\| \.gaia/cli/gaia setup record dependabot-posture applied' "$github_repo")"
  [ "$(grep -c . <<<"$line")" -eq 1 ] || return 1
  run_block "$repo" "$line" MAY_RECORD_PROJECT="$may" || return 1
}

@test "the probe blocks record every settled feature without a question, and drift then reports nothing" {
  local repo id
  repo="$(make_provisioned probes)"
  [ "$(grep -cE '\.gaia/cli/gaia setup record [a-z-]+ applied' "${REFERENCES}/per-machine.md")" -eq 4 ]
  record_settled_state "$repo" admin >/dev/null
  [ "$(decision "$repo" sandbox)" = declined ]
  [ "$(decision "$repo" statusline-left)" = applied ]
  for id in github-repository branch-protection gaia-audit-check push-protection delete-branch-on-merge \
    dependabot-posture squash-only label-sync install-tools install-plugins chmod-statusline bootstrap-env; do
    [ "$(decision "$repo" "$id")" = applied ] || {
      echo "${id} recorded '$(decision "$repo" "$id")', expected applied" >&2
      return 1
    }
  done
  assert_no_mutation
  # The two team settings are absent here and need an interactive answer;
  # the manual run covers the question, and these are its write and record lines.
  in_repo "$repo" .gaia/cli/gaia setup write-isolation-policy prefer-branch >/dev/null
  in_repo "$repo" .gaia/cli/gaia setup record isolation-policy applied >/dev/null
  in_repo "$repo" .gaia/cli/gaia setup write-sandbox-recommendation false >/dev/null
  in_repo "$repo" .gaia/cli/gaia setup record sandbox-recommendation declined >/dev/null
  [ -z "$(undecided_ids "$repo")" ]
  [ "$(jq -c 'keys' "${repo}/.gaia/project.json")" = '["isolation_policy","sandbox_recommended","setup_decisions","version"]' ]
}

@test "the probe blocks keep every other key of an existing project.json" {
  local repo before
  repo="$(make_provisioned probes-existing)"
  printf '%s\n' '{"version": 1, "isolation_policy": "prefer-worktree", "sandbox_recommended": true, "x": {"kept": [1, 2]}}' \
    >"${repo}/.gaia/project.json"
  before="$(jq -S -c . "${repo}/.gaia/project.json")"
  record_settled_state "$repo" admin >/dev/null
  in_repo "$repo" .gaia/cli/gaia setup record isolation-policy applied >/dev/null
  in_repo "$repo" .gaia/cli/gaia setup record sandbox-recommendation applied >/dev/null
  [ -z "$(undecided_ids "$repo")" ]
  [ "$(jq -S -c 'del(.setup_decisions)' "${repo}/.gaia/project.json")" = "$before" ]
}

# ---------------------------------------------------------------------------
# A machine id on a completed machine
# ---------------------------------------------------------------------------

@test "an owed statusline choice with no global statusline records not-applicable on this machine" {
  local repo
  repo="$(make_repo statusline-none)"
  record_all_but "$repo" statusline-left
  [ "$(undecided_ids "$repo")" = statusline-left ]
  run_block "$repo" "$(block_under "${REFERENCES}/statusline-left.md" '## Record a settled choice')" \
    GLOBAL_STATUSLINE= LEFT_CHOICE= >/dev/null
  [ "$(jq -r '.decisions["statusline-left"]' "${repo}/.gaia/local/setup-state.json")" = not-applicable ]
  [ -z "$(undecided_ids "$repo")" ]
}

@test "a standing user statusline choice records declined" {
  local repo
  repo="$(make_repo statusline-user)"
  run_block "$repo" "$(block_under "${REFERENCES}/statusline-left.md" '## Record a settled choice')" \
    GLOBAL_STATUSLINE=my-statusline LEFT_CHOICE=user >/dev/null
  [ "$(jq -r '.decisions["statusline-left"]' "${repo}/.gaia/local/setup-state.json")" = declined ]
}

# ---------------------------------------------------------------------------
# The declined rule
# ---------------------------------------------------------------------------

@test "the declined check passes only for an id recorded declined" {
  local repo line
  repo="$(make_repo declined-check)"
  line="$(check_line declined sandbox)"
  run in_repo "$repo" bash -c "$line"
  [ "$status" -ne 0 ]
  in_repo "$repo" .gaia/cli/gaia setup record sandbox applied >/dev/null
  run in_repo "$repo" bash -c "$line"
  [ "$status" -ne 0 ]
  in_repo "$repo" .gaia/cli/gaia setup record sandbox declined >/dev/null
  in_repo "$repo" bash -c "$line"
}

# ---------------------------------------------------------------------------
# Land the decisions
# ---------------------------------------------------------------------------

land_block() {
  block_under "${REFERENCES}/land-decisions.md" '## Land the decisions' "$1"
}

@test "the land decision block: changed or untracked lands, unchanged or absent does not" {
  local repo
  repo="$(make_repo land-decide)"
  [ "$(run_block "$repo" "$(land_block 1)")" = NOTHING_TO_LAND ]
  in_repo "$repo" .gaia/cli/gaia setup record squash-only declined >/dev/null
  [ "$(run_block "$repo" "$(land_block 1)")" = LAND ]
  git -C "$repo" add .gaia/project.json
  git -C "$repo" commit -q -m project
  [ "$(run_block "$repo" "$(land_block 1)")" = NOTHING_TO_LAND ]
  in_repo "$repo" .gaia/cli/gaia setup record squash-only applied >/dev/null
  [ "$(run_block "$repo" "$(land_block 1)")" = LAND ]
}

@test "the land blocks, run in order, push the decision to the origin's default branch and clear the sentinel" {
  local repo origin="${BATS_TEST_TMPDIR}/land-origin.git" output_text
  repo="$(make_repo land-push)"
  git init -q --bare "$origin"
  git -C "$repo" remote add origin "$origin"
  git -C "$repo" push -q origin main
  in_repo "$repo" .gaia/cli/gaia setup record squash-only declined >/dev/null
  [ "$(run_block "$repo" "$(land_block 1)")" = LAND ]
  run_block "$repo" "$(land_block 2)"
  [ -f "${repo}/.gaia/local/setup-in-progress" ]
  output_text="$(run_block "$repo" "$(land_block 3)" DEFAULT_BRANCH=main 2>&1)"
  grep -qE '^LANDED [0-9a-f]+$' <<<"$output_text"
  run_block "$repo" "$(land_block 4)"
  [ ! -e "${repo}/.gaia/local/setup-in-progress" ]
  [ "$(git --git-dir="$origin" show main:.gaia/project.json | jq -r '.setup_decisions["squash-only"]')" = declined ]
  [ "$(run_block "$repo" "$(land_block 1)")" = NOTHING_TO_LAND ]
}

@test "a failed push reports the decisions committed locally" {
  local repo output_text
  repo="$(make_repo land-no-origin)"
  in_repo "$repo" .gaia/cli/gaia setup record squash-only declined >/dev/null
  output_text="$(run_block "$repo" "$(land_block 3)" DEFAULT_BRANCH=main 2>&1)"
  grep -qF 'committed locally and need a push or a pull request' <<<"$output_text"
  grep -q '^LANDED' <<<"$output_text" && return 1
  true
}

# check_land_order <file>: under `## Land the decisions`, the sentinel touch
# sits in a fence of its own with no git command, before the fence staging
# .gaia/project.json, and a fence removing the sentinel follows that one.
check_land_order() {
  awk '
    $0 == "## Land the decisions" { seen = 1; next }
    seen && /^## / { exit }
    seen && /^```bash[[:space:]]*$/ { inside = 1; n++; touch = 0; git = 0; next }
    seen && inside && /^```[[:space:]]*$/ {
      inside = 0
      if (touch && !git && !touch_fence) touch_fence = n
      next
    }
    seen && inside && /^touch \.gaia\/local\/setup-in-progress$/ { touch = 1 }
    seen && inside && /^git / { git = 1 }
    seen && inside && /^git add \.gaia\/project\.json$/ && !commit_fence { commit_fence = n }
    seen && inside && /^rm -f \.gaia\/local\/setup-in-progress$/ { remove_fence = n }
    END {
      if (!touch_fence || !commit_fence || !remove_fence) exit 1
      exit !(touch_fence < commit_fence && commit_fence < remove_fence)
    }
  ' "$1" || {
    echo "the sentinel touch, the commit and the sentinel removal are not three ordered fences" >&2
    return 1
  }
}

@test "the land order check fails when the touch folds into the commit fence" {
  local copy="${BATS_TEST_TMPDIR}/land-folded.md"
  awk '
    /^touch \.gaia\/local\/setup-in-progress$/ { next }
    /^git add \.gaia\/project\.json$/ { print "touch .gaia/local/setup-in-progress" }
    { print }
  ' "${REFERENCES}/land-decisions.md" >"$copy"
  cmp -s "${REFERENCES}/land-decisions.md" "$copy" && return 1
  run check_land_order "$copy"
  [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# The setup ping
# ---------------------------------------------------------------------------

ping_block() {
  block_under "${REFERENCES}/land-decisions.md" '## The setup ping'
}

@test "a plain re-run that decided an owed id pings with the real sandbox value, no type and no repo" {
  local repo
  repo="$(make_repo ping-plain)"
  in_repo "$repo" .gaia/cli/gaia setup record squash-only declined >/dev/null
  run_block "$repo" "$(ping_block)" SETUP_TYPE= REPO_CHOICE= OWED_AT_START='squash-only label-sync' \
    STUB_SANDBOX_STATUS='{"resolved": true, "outcome": "enabled"}' >/dev/null
  [ "$(cat "$CLI_LOG")" = 'ping --event setup --sandbox on' ]
}

@test "the ping carries --repo only when the connect question was answered" {
  local repo
  repo="$(make_repo ping-repo)"
  in_repo "$repo" .gaia/cli/gaia setup record squash-only declined >/dev/null
  run_block "$repo" "$(ping_block)" SETUP_TYPE= REPO_CHOICE=create OWED_AT_START=squash-only \
    STUB_SANDBOX_STATUS='{"resolved": true, "outcome": "declined"}' >/dev/null
  [ "$(cat "$CLI_LOG")" = 'ping --event setup --sandbox off --repo create' ]
}

@test "a plain re-run that decided nothing sends no ping and leaves project.json byte-identical" {
  local repo output_text
  repo="$(make_repo ping-skipped)"
  printf '%s\n' '{"version": 1, "x": true}' >"${repo}/.gaia/project.json"
  cp "${repo}/.gaia/project.json" "${BATS_TEST_TMPDIR}/project-before.json"
  output_text="$(run_block "$repo" "$(ping_block)" SETUP_TYPE= REPO_CHOICE= OWED_AT_START='squash-only sandbox' \
    STUB_SANDBOX_STATUS='{"resolved": true, "outcome": "enabled"}')"
  [ "$output_text" = PING_SKIPPED ]
  [ ! -s "$CLI_LOG" ]
  cmp "${BATS_TEST_TMPDIR}/project-before.json" "${repo}/.gaia/project.json"
}

@test "a reconfigure run pings with its type even when nothing was newly decided" {
  local repo
  repo="$(make_repo ping-type)"
  run_block "$repo" "$(ping_block)" SETUP_TYPE=reconfigure REPO_CHOICE= OWED_AT_START= \
    STUB_SANDBOX_STATUS='{"resolved": false}' >/dev/null
  [ "$(cat "$CLI_LOG")" = 'ping --event setup --sandbox off --type reconfigure' ]
}

# ---------------------------------------------------------------------------
# Label sync
# ---------------------------------------------------------------------------

label_sync_block() {
  block_under "$SETUP_COMMAND" '## Phase 4.5: Label sync (always evaluated)'
}

@test "a degraded label sync on stdout prints no LABELS_APPLIED and records nothing" {
  local repo output_text
  repo="$(make_repo labels-degraded)"
  output_text="$(run_block "$repo" "$(label_sync_block)" LABEL_SYNC_OWED=true MAY_RECORD_PROJECT=admin \
    STUB_SYNC_STDOUT='labels-sync: degraded, manual commands follow' STUB_SYNC_STATUS=0)"
  grep -qxF 'labels-sync: degraded, manual commands follow' <<<"$output_text"
  grep -qx LABELS_APPLIED <<<"$output_text" && return 1
  [ -z "$(decision "$repo" label-sync)" ]
}

@test "a block testing stderr for the marker records the degraded sync, so stdout is what catches it" {
  local repo block mutated old new
  repo="$(make_repo labels-stderr)"
  block="$(label_sync_block)"
  old='SYNC_OUTPUT="$(.gaia/cli/gaia labels sync)"'
  new='SYNC_OUTPUT="$(.gaia/cli/gaia labels sync 2>&1 >/dev/null)"'
  mutated="${block/"$old"/"$new"}"
  [ "$mutated" != "$block" ]
  run_block "$repo" "$mutated" LABEL_SYNC_OWED=true MAY_RECORD_PROJECT=admin \
    STUB_SYNC_STDOUT='labels-sync: degraded, manual commands follow' STUB_SYNC_STATUS=0 >/dev/null
  [ "$(decision "$repo" label-sync)" = applied ]
}

@test "a clean label sync records only when label-sync is owed and the run is an admin's" {
  local repo output_text
  repo="$(make_repo labels-gates)"
  output_text="$(run_block "$repo" "$(label_sync_block)" LABEL_SYNC_OWED=false MAY_RECORD_PROJECT=admin)"
  grep -qx LABELS_APPLIED <<<"$output_text"
  [ -z "$(decision "$repo" label-sync)" ]
  run_block "$repo" "$(label_sync_block)" LABEL_SYNC_OWED=true MAY_RECORD_PROJECT=none >/dev/null
  [ -z "$(decision "$repo" label-sync)" ]
  run_block "$repo" "$(label_sync_block)" LABEL_SYNC_OWED=true MAY_RECORD_PROJECT=admin >/dev/null
  [ "$(decision "$repo" label-sync)" = applied ]
}

@test "a failed label sync records nothing" {
  local repo output_text
  repo="$(make_repo labels-failed)"
  output_text="$(run_block "$repo" "$(label_sync_block)" LABEL_SYNC_OWED=true MAY_RECORD_PROJECT=admin STUB_SYNC_STATUS=1)"
  grep -qx LABELS_APPLIED <<<"$output_text" && return 1
  [ -z "$(decision "$repo" label-sync)" ]
}

# ---------------------------------------------------------------------------
# The squash-only gate
# ---------------------------------------------------------------------------

@test "the squash-only owed check passes while undecided, fails once declined, and a new answer overwrites" {
  local repo line
  repo="$(make_repo squash-gate)"
  line="$(check_line owed squash-only)"
  in_repo "$repo" bash -c "$line"
  in_repo "$repo" .gaia/cli/gaia setup record squash-only declined >/dev/null
  run in_repo "$repo" bash -c "$line"
  [ "$status" -ne 0 ]
  run in_repo "$repo" .gaia/cli/gaia setup record squash-only applied
  [ "$(jq -r '.previous' <<<"$output")" = declined ]
  [ "$(jq -r '.setup_decisions["squash-only"]' "${repo}/.gaia/project.json")" = applied ]
}

# ---------------------------------------------------------------------------
# Who may record: the admin rule
# ---------------------------------------------------------------------------

@test "with MAY_RECORD_PROJECT none, no project block records while a machine block still does" {
  local repo
  repo="$(make_provisioned admin-none)"
  record_settled_state "$repo" none >/dev/null
  run_block "$repo" "$(block_under "${REFERENCES}/github-repo.md" '## Owed and recorded settings' 1)" \
    MAY_RECORD_PROJECT=none >/dev/null
  [ ! -e "${repo}/.gaia/project.json" ]
  [ "$(decision "$repo" statusline-left)" = applied ]
  [ "$(decision "$repo" sandbox)" = declined ]
}

@test "with MAY_RECORD_PROJECT not-applicable-only, the non-GitHub arm records only owed GitHub ids" {
  local repo id
  repo="$(make_repo admin-other-host)"
  in_repo "$repo" .gaia/cli/gaia setup record squash-only declined >/dev/null
  run_block "$repo" "$(block_under "${REFERENCES}/github-repo.md" '## Owed and recorded settings' 1)" \
    MAY_RECORD_PROJECT=not-applicable-only >/dev/null
  run_block "$repo" "$(block_under "${REFERENCES}/github-repo.md" '## Owed and recorded settings' 2)" \
    OWNER=o REPO=r HOST=git.example.com DEFAULT_BRANCH=main MAY_RECORD_PROJECT=not-applicable-only >/dev/null
  for id in github-repository push-protection branch-protection gaia-audit-check delete-branch-on-merge \
    dependabot-posture label-sync; do
    [ "$(decision "$repo" "$id")" = not-applicable ] || {
      echo "${id} recorded '$(decision "$repo" "$id")', expected not-applicable" >&2
      return 1
    }
  done
  [ "$(decision "$repo" squash-only)" = declined ]
  [ "$(jq -r '.setup_decisions | keys | length' "${repo}/.gaia/project.json")" -eq 8 ]
  [ "$(undecided_ids "$repo")" = 'install-tools install-plugins chmod-statusline bootstrap-env sandbox statusline-left isolation-policy sandbox-recommendation' ]
  [ ! -s "$GH_LOG" ]
}

# ---------------------------------------------------------------------------
# Phase 5: standalone features
# ---------------------------------------------------------------------------

standalone_block() {
  block_under "${REFERENCES}/standalone-features.md" '# Owed standalone setup features'
}

@test "Phase 5 hands an admin each undecided standalone feature, and a non-admin only the machine one" {
  local list="${BATS_TEST_TMPDIR}/standalone-list.json" repo output_text
  jq '.features += [
    {"id": "later-machine", "scope": "machine", "required": true, "admin": false, "standalone": true, "reference": "docs/later-machine.md"},
    {"id": "later-project", "scope": "project", "required": false, "admin": true, "standalone": true, "reference": "docs/later-project.md"}
  ]' "$FEATURE_LIST" >"$list"
  repo="$(make_repo standalone "$list")"
  output_text="$(run_block "$repo" "$(standalone_block)" MAY_RECORD_PROJECT=admin)"
  [ "$output_text" = "$(printf '%s\n' 'OWED_FEATURE later-machine apply docs/later-machine.md' 'OWED_FEATURE later-project ask docs/later-project.md')" ]
  output_text="$(run_block "$repo" "$(standalone_block)" MAY_RECORD_PROJECT=none)"
  [ "$output_text" = "$(printf '%s\n' 'OWED_FEATURE later-machine apply docs/later-machine.md' 'SKIP_PROJECT later-project')" ]
}

@test "Phase 5 prints nothing for the shipped list" {
  local repo output_text
  repo="$(make_repo standalone-real)"
  [ "$(undecided_ids "$repo" | wc -w | tr -d ' ')" -gt 0 ]
  output_text="$(run_block "$repo" "$(standalone_block)" MAY_RECORD_PROJECT=admin)"
  [ -z "$output_text" ]
}
