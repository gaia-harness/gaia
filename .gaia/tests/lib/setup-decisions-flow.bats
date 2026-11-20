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
# status` and `sandbox detect` (when a test sets a stub answer) and `ping`
# itself, and passes every
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
  mkdir -p "${repo}/.gaia/cli" "${repo}/.gaia/scripts"
  cp "${REPO_ROOT}/.gaia/scripts/setup-ping.sh" "${repo}/.gaia/scripts/"
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
  "sandbox detect")
    if [ -n "${STUB_SANDBOX_CAPABILITY:-}" ]; then
      printf '{"capability": "%s", "reason": "stub"}\n' "$STUB_SANDBOX_CAPABILITY"
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

# drift_state <repo>: the name and content of every file a record or a block
# writes, the key drift_json caches on.
drift_state() {
  local repo="$1"
  # gaia-lint-ignore whole-tree-mark-guard: the operand is a make_repo sandbox under BATS_TEST_TMPDIR, not the tracked tree
  find "${repo}/.gaia/local" -type f 2>/dev/null | sort | while IFS= read -r file; do
    printf '%s\n' "$file"
    cat "$file"
  done
  cat "${repo}/.gaia/project.json" "${HOME}/.claude/settings.json" 2>/dev/null
}

# drift_json <repo>: drift's JSON, read once per state of the repository. The
# cache is keyed on the content of every file a record or a block writes, so a
# record between two reads is seen by the second.
drift_json() {
  local repo="$1" name key cache
  name="$(basename "$repo")"
  cache="${BATS_TEST_TMPDIR}/drift-cache-${name}"
  key="$(drift_state "$repo" | cksum)"
  if [ ! -f "${cache}.json" ] || [ "$(cat "${cache}.key" 2>/dev/null)" != "$key" ]; then
    in_repo "$repo" .gaia/cli/gaia setup drift --json >"${cache}.json" || return 1
    printf '%s\n' "$key" >"${cache}.key"
  fi
  cat "${cache}.json"
}

# decision_cached <repo> <id>: decision, from the once-per-state drift read.
decision_cached() {
  drift_json "$1" | jq -r --arg id "$2" '.decided[$id] // empty'
}

# undecided_ids_cached <repo>: undecided_ids, from the once-per-state drift read.
undecided_ids_cached() {
  drift_json "$1" | jq -r '[.undecided[].id] | join(" ")'
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

# bats test_tags=protected
@test "who records project decisions by role, auth, host and branch" {
  local repo origin="${BATS_TEST_TMPDIR}/who-origin.git"
  # One repository serves every case: the block reads only the current branch
  # and origin/HEAD, so the cases run in an order that adds that state.
  repo="$(make_repo who-records)"
  run who_records "$repo" FOUND=true HOST=github.com ADMIN=true AUTH_STATUS=ok DEFAULT_BRANCH=main
  grep -qx 'MAY_RECORD_PROJECT=admin' <<<"$output" || { echo "case admin on main: $output"; return 1; }
  grep -qx 'DEFAULT_BRANCH=main' <<<"$output" || { echo "case admin on main: $output"; return 1; }
  run who_records "$repo" FOUND=true HOST=github.com ADMIN=false AUTH_STATUS=ok DEFAULT_BRANCH=main
  grep -qx 'MAY_RECORD_PROJECT=none' <<<"$output" || { echo "case non-admin: $output"; return 1; }
  run who_records "$repo" FOUND=true HOST=github.com ADMIN=true AUTH_STATUS=unauthenticated DEFAULT_BRANCH=main
  grep -qx 'MAY_RECORD_PROJECT=none' <<<"$output" || { echo "case failed auth: $output"; return 1; }
  run who_records "$repo" FOUND=false DEFAULT_BRANCH=main
  grep -qx 'MAY_RECORD_PROJECT=none' <<<"$output" || { echo "case no origin: $output"; return 1; }
  grep -qx 'DEFAULT_BRANCH=' <<<"$output" || { echo "case no origin: $output"; return 1; }
  git init -q --bare "$origin"
  git -C "$repo" remote add origin "$origin"
  run who_records "$repo" FOUND=true HOST=git.example.com
  grep -qx 'MAY_RECORD_PROJECT=none' <<<"$output" || { echo "case other host, no origin/HEAD: $output"; return 1; }
  grep -qx 'DEFAULT_BRANCH=' <<<"$output" || { echo "case other host, no origin/HEAD: $output"; return 1; }
  git -C "$repo" push -q origin main
  git -C "$repo" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  run who_records "$repo" FOUND=true HOST=git.example.com
  grep -qx 'MAY_RECORD_PROJECT=not-applicable-only' <<<"$output" || { echo "case other host on default branch: $output"; return 1; }
  grep -qx 'DEFAULT_BRANCH=main' <<<"$output" || { echo "case other host on default branch: $output"; return 1; }
  git -C "$repo" checkout -q -b feature
  run who_records "$repo" FOUND=true HOST=github.com ADMIN=true AUTH_STATUS=ok DEFAULT_BRANCH=main
  grep -qx 'MAY_RECORD_PROJECT=none' <<<"$output" || { echo "case admin on another branch: $output"; return 1; }
  run who_records "$repo" FOUND=true HOST=git.example.com
  grep -qx 'MAY_RECORD_PROJECT=none' <<<"$output" || { echo "case other host on another branch: $output"; return 1; }
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

# record_standalone_not_applicable <repo>: records every shipped standalone
# feature as not-applicable, the record Phase 5 makes on a project that never
# needed it. Phase 5 has its own cases below; the probe cases only need those
# ids decided.
record_standalone_not_applicable() {
  local id ids
  ids="$(jq -r '.features[] | select(.standalone) | .id' "$FEATURE_LIST")" || return 1
  for id in $ids; do
    in_repo "$1" .gaia/cli/gaia setup record "$id" not-applicable >/dev/null || return 1
  done
}

@test "the probe blocks record every settled feature without a question, and drift then reports nothing" {
  local repo id
  repo="$(make_provisioned probes)"
  [ "$(grep -cE '\.gaia/cli/gaia setup record [a-z-]+ applied' "${REFERENCES}/per-machine.md")" -eq 4 ]
  record_settled_state "$repo" admin >/dev/null
  [ "$(decision_cached "$repo" sandbox)" = declined ]
  [ "$(decision_cached "$repo" statusline-left)" = applied ]
  for id in github-repository branch-protection gaia-audit-check push-protection delete-branch-on-merge \
    dependabot-posture squash-only label-sync install-tools install-plugins chmod-statusline bootstrap-env; do
    [ "$(decision_cached "$repo" "$id")" = applied ] || {
      echo "${id} recorded '$(decision_cached "$repo" "$id")', expected applied" >&2
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
  record_standalone_not_applicable "$repo"
  [ -z "$(undecided_ids_cached "$repo")" ]
  [ "$(jq -c 'keys' "${repo}/.gaia/project.json")" = '["isolation_policy","sandbox_recommended","setup_decisions","version"]' ]
}

# bats test_tags=protected
@test "the probe blocks keep every other key of an existing project.json" {
  local repo before
  repo="$(make_provisioned probes-existing)"
  printf '%s\n' '{"version": 1, "isolation_policy": "prefer-worktree", "sandbox_recommended": true, "x": {"kept": [1, 2]}}' \
    >"${repo}/.gaia/project.json"
  before="$(jq -S -c . "${repo}/.gaia/project.json")"
  record_settled_state "$repo" admin >/dev/null
  in_repo "$repo" .gaia/cli/gaia setup record isolation-policy applied >/dev/null
  in_repo "$repo" .gaia/cli/gaia setup record sandbox-recommendation applied >/dev/null
  record_standalone_not_applicable "$repo"
  [ -z "$(undecided_ids "$repo")" ]
  [ "$(jq -S -c 'del(.setup_decisions)' "${repo}/.gaia/project.json")" = "$before" ]
}

# ---------------------------------------------------------------------------
# A machine id on a completed machine
# ---------------------------------------------------------------------------

@test "statusline choice records not-applicable without a global statusline and declined for a standing user choice" {
  local repo
  # One repository: the no-global case runs first, then the user choice
  # overwrites its record.
  repo="$(make_repo statusline-choice)"
  record_all_but "$repo" statusline-left
  [ "$(undecided_ids "$repo")" = statusline-left ] || { echo "case no global: statusline-left not the only owed id"; return 1; }
  run_block "$repo" "$(block_under "${REFERENCES}/statusline-left.md" '## Record a settled choice')" \
    GLOBAL_STATUSLINE= LEFT_CHOICE= >/dev/null
  [ "$(jq -r '.decisions["statusline-left"]' "${repo}/.gaia/local/setup-state.json")" = not-applicable ] || { echo "case no global: not recorded not-applicable"; return 1; }
  [ -z "$(undecided_ids "$repo")" ] || { echo "case no global: still owed"; return 1; }
  run_block "$repo" "$(block_under "${REFERENCES}/statusline-left.md" '## Record a settled choice')" \
    GLOBAL_STATUSLINE=my-statusline LEFT_CHOICE=user >/dev/null
  [ "$(jq -r '.decisions["statusline-left"]' "${repo}/.gaia/local/setup-state.json")" = declined ] || { echo "case user choice: not recorded declined"; return 1; }
}

# ---------------------------------------------------------------------------
# The declined rule
# ---------------------------------------------------------------------------

@test "owed and declined check lines gate on the recorded decision" {
  local repo line
  # One repository: the two cases check different ids.
  repo="$(make_repo check-lines)"
  line="$(check_line declined sandbox)"
  run in_repo "$repo" bash -c "$line"
  [ "$status" -ne 0 ] || { echo "case declined, undecided: passed"; return 1; }
  in_repo "$repo" .gaia/cli/gaia setup record sandbox applied >/dev/null
  run in_repo "$repo" bash -c "$line"
  [ "$status" -ne 0 ] || { echo "case declined, applied: passed"; return 1; }
  in_repo "$repo" .gaia/cli/gaia setup record sandbox declined >/dev/null
  in_repo "$repo" bash -c "$line" || { echo "case declined, declined: failed"; return 1; }
  line="$(check_line owed squash-only)"
  in_repo "$repo" bash -c "$line" || { echo "case owed, undecided: failed"; return 1; }
  in_repo "$repo" .gaia/cli/gaia setup record squash-only declined >/dev/null
  run in_repo "$repo" bash -c "$line"
  [ "$status" -ne 0 ] || { echo "case owed, declined: passed"; return 1; }
  run in_repo "$repo" .gaia/cli/gaia setup record squash-only applied
  [ "$(jq -r '.previous' <<<"$output")" = declined ] || { echo "case owed, overwrite: previous not declined"; return 1; }
  [ "$(jq -r '.setup_decisions["squash-only"]' "${repo}/.gaia/project.json")" = applied ] || { echo "case owed, overwrite: not applied"; return 1; }
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

# bats test_tags=protected
@test "a failed push reports the decisions committed locally" {
  local repo output_text
  repo="$(make_repo land-no-origin)"
  in_repo "$repo" .gaia/cli/gaia setup record squash-only declined >/dev/null
  output_text="$(run_block "$repo" "$(land_block 3)" DEFAULT_BRANCH=main 2>&1)"
  grep -qF 'committed locally and need a push or a pull request' <<<"$output_text"
  grep -q '^LANDED' <<<"$output_text" && return 1
  true
}

# ---------------------------------------------------------------------------
# The setup ping
# ---------------------------------------------------------------------------

ping_block() {
  block_under "${REFERENCES}/land-decisions.md" '## The setup ping'
}

@test "the ping block pings per owed, type and repo inputs and skips when nothing was decided" {
  local repo output_text
  # One repository: the two cases that need nothing decided run before the
  # record the other two need.
  repo="$(make_repo ping-wiring)"
  printf '%s\n' '{"version": 1, "x": true}' >"${repo}/.gaia/project.json"
  cp "${repo}/.gaia/project.json" "${BATS_TEST_TMPDIR}/project-before.json"
  output_text="$(run_block "$repo" "$(ping_block)" SETUP_TYPE= REPO_CHOICE= OWED_AT_START='squash-only sandbox' \
    STUB_SANDBOX_STATUS='{"resolved": true, "outcome": "enabled"}')"
  [ "$output_text" = PING_SKIPPED ] || { echo "case nothing decided: $output_text"; return 1; }
  [ ! -s "$CLI_LOG" ] || { echo "case nothing decided: pinged"; return 1; }
  cmp "${BATS_TEST_TMPDIR}/project-before.json" "${repo}/.gaia/project.json" || { echo "case nothing decided: project.json changed"; return 1; }
  run_block "$repo" "$(ping_block)" SETUP_TYPE=reconfigure REPO_CHOICE= OWED_AT_START= \
    STUB_SANDBOX_STATUS='{"resolved": false}' >/dev/null
  [ "$(cat "$CLI_LOG")" = 'ping --event setup --sandbox off --type reconfigure' ] || { echo "case reconfigure: $(cat "$CLI_LOG")"; return 1; }
  in_repo "$repo" .gaia/cli/gaia setup record squash-only declined >/dev/null
  : >"$CLI_LOG"
  run_block "$repo" "$(ping_block)" SETUP_TYPE= REPO_CHOICE= OWED_AT_START='squash-only label-sync' \
    STUB_SANDBOX_STATUS='{"resolved": true, "outcome": "enabled"}' >/dev/null
  [ "$(cat "$CLI_LOG")" = 'ping --event setup --sandbox on' ] || { echo "case plain decided: $(cat "$CLI_LOG")"; return 1; }
  : >"$CLI_LOG"
  run_block "$repo" "$(ping_block)" SETUP_TYPE= REPO_CHOICE=create OWED_AT_START=squash-only \
    STUB_SANDBOX_STATUS='{"resolved": true, "outcome": "declined"}' >/dev/null
  [ "$(cat "$CLI_LOG")" = 'ping --event setup --sandbox off --repo create' ] || { echo "case repo answered: $(cat "$CLI_LOG")"; return 1; }
}

# ---------------------------------------------------------------------------
# Label sync
# ---------------------------------------------------------------------------

label_sync_block() {
  block_under "$SETUP_COMMAND" '## Phase 4.5: Label sync (always evaluated)'
}

@test "label sync records only a clean sync owed to an admin" {
  local repo output_text
  # One repository: the cases that record nothing run before the one that records.
  repo="$(make_repo labels-sync)"
  output_text="$(run_block "$repo" "$(label_sync_block)" LABEL_SYNC_OWED=true MAY_RECORD_PROJECT=admin \
    STUB_SYNC_STDOUT='labels-sync: degraded, manual commands follow' STUB_SYNC_STATUS=0)"
  grep -qxF 'labels-sync: degraded, manual commands follow' <<<"$output_text" || { echo "case degraded: marker not printed"; return 1; }
  grep -qx LABELS_APPLIED <<<"$output_text" && { echo "case degraded: LABELS_APPLIED printed"; return 1; }
  [ -z "$(decision "$repo" label-sync)" ] || { echo "case degraded: recorded"; return 1; }
  output_text="$(run_block "$repo" "$(label_sync_block)" LABEL_SYNC_OWED=true MAY_RECORD_PROJECT=admin STUB_SYNC_STATUS=1)"
  grep -qx LABELS_APPLIED <<<"$output_text" && { echo "case failed: LABELS_APPLIED printed"; return 1; }
  [ -z "$(decision "$repo" label-sync)" ] || { echo "case failed: recorded"; return 1; }
  output_text="$(run_block "$repo" "$(label_sync_block)" LABEL_SYNC_OWED=false MAY_RECORD_PROJECT=admin)"
  grep -qx LABELS_APPLIED <<<"$output_text" || { echo "case not owed: no LABELS_APPLIED"; return 1; }
  [ -z "$(decision "$repo" label-sync)" ] || { echo "case not owed: recorded"; return 1; }
  run_block "$repo" "$(label_sync_block)" LABEL_SYNC_OWED=true MAY_RECORD_PROJECT=none >/dev/null
  [ -z "$(decision "$repo" label-sync)" ] || { echo "case non-admin: recorded"; return 1; }
  run_block "$repo" "$(label_sync_block)" LABEL_SYNC_OWED=true MAY_RECORD_PROJECT=admin >/dev/null
  [ "$(decision "$repo" label-sync)" = applied ] || { echo "case owed admin: not applied"; return 1; }
}

# ---------------------------------------------------------------------------
# The squash-only gate
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Who may record: the admin rule
# ---------------------------------------------------------------------------

# bats test_tags=protected
@test "project blocks record by MAY_RECORD_PROJECT value" {
  local repo id undecided expected_count=0
  local -a owed_ids=(github-repository push-protection branch-protection gaia-audit-check delete-branch-on-merge dependabot-posture label-sync)
  # Two repositories: the none case needs a provisioned machine, and the
  # not-applicable-only case counts the machine ids as still undecided.
  repo="$(make_provisioned admin-none)"
  record_settled_state "$repo" none >/dev/null
  run_block "$repo" "$(block_under "${REFERENCES}/github-repo.md" '## Owed and recorded settings' 1)" \
    MAY_RECORD_PROJECT=none >/dev/null
  [ ! -e "${repo}/.gaia/project.json" ] || { echo "case none: project.json written"; return 1; }
  [ "$(decision "$repo" statusline-left)" = applied ] || { echo "case none: statusline-left not applied"; return 1; }
  [ "$(decision "$repo" sandbox)" = declined ] || { echo "case none: sandbox not declined"; return 1; }
  : >"$GH_LOG"
  repo="$(make_repo admin-other-host)"
  in_repo "$repo" .gaia/cli/gaia setup record squash-only declined >/dev/null
  run_block "$repo" "$(block_under "${REFERENCES}/github-repo.md" '## Owed and recorded settings' 1)" \
    MAY_RECORD_PROJECT=not-applicable-only >/dev/null
  run_block "$repo" "$(block_under "${REFERENCES}/github-repo.md" '## Owed and recorded settings' 2)" \
    OWNER=o REPO=r HOST=git.example.com DEFAULT_BRANCH=main MAY_RECORD_PROJECT=not-applicable-only >/dev/null
  for id in "${owed_ids[@]}"; do
    [ "$(decision_cached "$repo" "$id")" = not-applicable ] || {
      echo "case not-applicable-only: ${id} recorded '$(decision_cached "$repo" "$id")', expected not-applicable" >&2
      return 1
    }
  done
  [ "$(decision_cached "$repo" squash-only)" = declined ] || { echo "case not-applicable-only: squash-only not declined"; return 1; }
  # The recorded set is the owed GitHub ids plus the one declined id; every
  # other registry id is still undecided, in the registry's own order.
  [ "$(jq -r '.setup_decisions | keys | length' "${repo}/.gaia/project.json")" -eq $((${#owed_ids[@]} + 1)) ] || { echo "case not-applicable-only: recorded count"; return 1; }
  undecided="$(undecided_ids_cached "$repo")"
  for id in $(jq -r '.features[].id' "$FEATURE_LIST"); do
    [ "$id" = squash-only ] && continue
    case " ${owed_ids[*]} " in *" $id "*) continue ;; esac
    expected_count=$((expected_count + 1))
    tr ' ' '\n' <<<"$undecided" | grep -qxF -- "$id" || {
      echo "case not-applicable-only: ${id} should still be undecided: ${undecided}" >&2
      return 1
    }
  done
  [ "$expected_count" -gt 0 ] || { echo "case not-applicable-only: no other id"; return 1; }
  [ "$(wc -w <<<"$undecided" | tr -d ' ')" -eq "$expected_count" ] || { echo "case not-applicable-only: undecided count"; return 1; }
  [ ! -s "$GH_LOG" ] || { echo "case not-applicable-only: gh called"; return 1; }
}

# ---------------------------------------------------------------------------
# Phase 5: standalone features
# ---------------------------------------------------------------------------

standalone_block() {
  block_under "${REFERENCES}/standalone-features.md" '# Owed standalone setup features'
}

# standalone_not_applicable_block <id>: the gated not-applicable record line
# for a `detect` handoff, with the id substituted.
standalone_not_applicable_block() {
  local block
  block="$(block_under "${REFERENCES}/standalone-features.md" '# Owed standalone setup features' 2)"
  grep -qF -- '<id>' <<<"$block" || {
    echo "the not-applicable record block names no <id>: ${block}" >&2
    return 1
  }
  printf '%s\n' "${block//<id>/$1}"
}

@test "Phase 5 standalone handoff by role and host" {
  local list="${BATS_TEST_TMPDIR}/standalone-list.json" repo output_text reference
  # Two repositories: the role cases need a fixture list, and the host case
  # the real one.
  jq '.features |= map(select(.standalone | not)) | .features += [
    {"id": "later-machine", "scope": "machine", "required": true, "admin": false, "standalone": true, "reference": "docs/later-machine.md"},
    {"id": "later-project", "scope": "project", "required": false, "admin": true, "standalone": true, "reference": "docs/later-project.md"}
  ]' "$FEATURE_LIST" >"$list"
  repo="$(make_repo standalone "$list")"
  output_text="$(run_block "$repo" "$(standalone_block)" MAY_RECORD_PROJECT=admin)"
  [ "$output_text" = "$(printf '%s\n' 'OWED_FEATURE later-machine apply docs/later-machine.md' 'OWED_FEATURE later-project ask docs/later-project.md')" ] || { echo "case admin: $output_text"; return 1; }
  output_text="$(run_block "$repo" "$(standalone_block)" MAY_RECORD_PROJECT=none)"
  [ "$output_text" = "$(printf '%s\n' 'OWED_FEATURE later-machine apply docs/later-machine.md' 'SKIP_PROJECT later-project')" ] || { echo "case non-admin: $output_text"; return 1; }
  output_text="$(run_block "$repo" "$(standalone_block)" MAY_RECORD_PROJECT=not-applicable-only)"
  [ "$output_text" = "$(printf '%s\n' 'OWED_FEATURE later-machine apply docs/later-machine.md' 'OWED_FEATURE later-project detect docs/later-project.md')" ] || { echo "case not-applicable-only: $output_text"; return 1; }
  reference="$(jq -r '.features[] | select(.id == "required-ci-checks") | .reference' "$FEATURE_LIST")"
  [ -n "$reference" ] || { echo "case other host: required-ci-checks has no reference"; return 1; }
  repo="$(make_repo standalone-other-host)"
  output_text="$(run_block "$repo" "$(standalone_block)" MAY_RECORD_PROJECT=not-applicable-only)"
  grep -qxF -- 'SKIP_PROJECT required-ci-checks' <<<"$output_text" && { echo "case other host: skipped"; return 1; }
  grep -qxF -- "OWED_FEATURE required-ci-checks detect ${reference}" <<<"$output_text" || { echo "case other host: not handed as detect"; return 1; }
  # Off the default branch the gate records nothing.
  run_block "$repo" "$(standalone_not_applicable_block required-ci-checks)" MAY_RECORD_PROJECT=none >/dev/null
  [ -z "$(decision "$repo" required-ci-checks)" ] || { echo "case other host, none: recorded"; return 1; }
  run_block "$repo" "$(standalone_not_applicable_block required-ci-checks)" MAY_RECORD_PROJECT=not-applicable-only >/dev/null
  [ "$(decision "$repo" required-ci-checks)" = not-applicable ] || { echo "case other host: not recorded not-applicable"; return 1; }
  output_text="$(run_block "$repo" "$(standalone_block)" MAY_RECORD_PROJECT=not-applicable-only)"
  grep -qF -- 'required-ci-checks' <<<"$output_text" && { echo "case other host, next run: still owed"; return 1; }
  [ ! -s "$GH_LOG" ] || { echo "case other host: gh called"; return 1; }
}

@test "Phase 5 hands over exactly the shipped standalone features" {
  local repo output_text expected
  repo="$(make_repo standalone-real)"
  expected="$(jq -r '.features[] | select(.standalone)
    | "OWED_FEATURE \(.id) \(if .required then "apply" else "ask" end) \(.reference)"' "$FEATURE_LIST")"
  [ -n "$expected" ]
  output_text="$(run_block "$repo" "$(standalone_block)" MAY_RECORD_PROJECT=admin)"
  [ "$output_text" = "$expected" ]
}

# ---------------------------------------------------------------------------
# Shipped defaults: worktrees, sandbox off, no recommendation
# ---------------------------------------------------------------------------

INIT_COMMAND_PATH='.claude/commands/gaia-init.md'

sandbox_route_block() {
  block_under "$SETUP_COMMAND" '## Phase 2: Per-machine setup (skip if finalized and nothing is owed)'
}

default_off_block() {
  block_under "${REFERENCES}/sandbox.md" '## Default off'
}

isolation_block() {
  block_under "$SETUP_COMMAND" '### The isolation policy'
}

recommendation_block() {
  block_under "$SETUP_COMMAND" '### The sandbox recommendation'
}

team_from_sandbox_block() {
  block_under "${REFERENCES}/sandbox.md" "## The admin's answer sets the team recommendation"
}

init_settings_block() {
  block_under "${REPO_ROOT}/${INIT_COMMAND_PATH}" '## Step 7: Project settings'
}

@test "the sandbox route per marker, recommendation and reconfigure" {
  local repo
  # One repository: each case adds the record or marker the next one needs.
  repo="$(make_repo sandbox-route)"
  [ "$(run_block "$repo" "$(sandbox_route_block)")" = SANDBOX=default-off ] || { echo "case no marker, no project.json"; return 1; }
  printf '%s\n' '{"version": 1, "sandbox_recommended": false}' >"${repo}/.gaia/project.json"
  [ "$(run_block "$repo" "$(sandbox_route_block)")" = SANDBOX=default-off ] || { echo "case no marker, not recommended"; return 1; }
  in_repo "$repo" .gaia/cli/gaia setup record sandbox declined >/dev/null
  printf '%s\n' '{"version": 1, "sandbox_recommended": true}' >"${repo}/.gaia/project.json"
  [ "$(run_block "$repo" "$(sandbox_route_block)")" = SANDBOX=ask ] || { echo "case recommended, declined record without marker"; return 1; }
  in_repo "$repo" .gaia/cli/gaia sandbox record --outcome declined --capability ready >/dev/null
  [ "$(run_block "$repo" "$(sandbox_route_block)")" = SANDBOX=stands ] || { echo "case answered, plain run"; return 1; }
  [ "$(run_block "$repo" "$(sandbox_route_block)" RECONFIGURE=true)" = SANDBOX=ask ] || { echo "case answered, reconfigure"; return 1; }
  rm -f "${repo}/.gaia/local/sandbox.json"
  [ "$(run_block "$repo" "$(sandbox_route_block)" RECONFIGURE=true)" = SANDBOX=ask ] || { echo "case marker removed, reconfigure"; return 1; }
}

@test "the default-off block records by capability and prior decision" {
  local repo capability output_text before
  for capability in needs-deps unsupported; do
    repo="$(make_repo "default-off-${capability}")"
    output_text="$(run_block "$repo" "$(default_off_block)" STUB_SANDBOX_CAPABILITY="$capability")"
    [ -z "$output_text" ] || {
      echo "case ${capability}: the default-off block printed: ${output_text}" >&2
      return 1
    }
    [ "$(decision "$repo" sandbox)" = not-applicable ] || { echo "case ${capability}: not recorded not-applicable"; return 1; }
    [ ! -e "${repo}/.gaia/local/sandbox.json" ] || { echo "case ${capability}: marker written"; return 1; }
  done
  # The ready case's repository then serves the already-decided case.
  repo="$(make_repo default-off-ready)"
  run_block "$repo" "$(default_off_block)" STUB_SANDBOX_CAPABILITY=ready >/dev/null
  [ "$(decision "$repo" sandbox)" = declined ] || { echo "case ready: not recorded declined"; return 1; }
  [ ! -e "${repo}/.gaia/local/sandbox.json" ] || { echo "case ready: marker written"; return 1; }
  in_repo "$repo" .gaia/cli/gaia setup record sandbox not-applicable >/dev/null
  before="$(cat "${repo}/.gaia/local/setup-state.json")"
  run_block "$repo" "$(default_off_block)" STUB_SANDBOX_CAPABILITY=ready >/dev/null
  [ "$(cat "${repo}/.gaia/local/setup-state.json")" = "$before" ] || { echo "case decided: record changed"; return 1; }
}

@test "the isolation block records or asks by role and reconfigure" {
  local repo output_text
  # One repository: the cases that record nothing run before the one that records.
  repo="$(make_repo isolation)"
  run_block "$repo" "$(isolation_block)" MAY_RECORD_PROJECT=none >/dev/null
  [ -z "$(decision "$repo" isolation-policy)" ] || { echo "case non-admin: recorded"; return 1; }
  [ "$(run_block "$repo" "$(isolation_block)" MAY_RECORD_PROJECT=admin RECONFIGURE=true)" = ISOLATION=ask ] || { echo "case reconfigure: did not ask"; return 1; }
  [ -z "$(decision "$repo" isolation-policy)" ] || { echo "case reconfigure: recorded"; return 1; }
  output_text="$(run_block "$repo" "$(isolation_block)" MAY_RECORD_PROJECT=admin)"
  grep -qF 'ISOLATION=ask' <<<"$output_text" && { echo "case plain admin: asked"; return 1; }
  [ "$(decision "$repo" isolation-policy)" = applied ] || { echo "case plain admin: not applied"; return 1; }
  [ "$(jq -r 'has("isolation_policy")' "${repo}/.gaia/project.json")" = false ] || { echo "case plain admin: key written"; return 1; }
}

@test "the recommendation block records or asks by key, reconfigure and sandbox answer" {
  local repo output_text
  # One repository: the cases that record nothing run first, and the set-key
  # case rewrites project.json whole, which clears the earlier record.
  repo="$(make_repo recommendation)"
  [ "$(run_block "$repo" "$(recommendation_block)" MAY_RECORD_PROJECT=admin RECONFIGURE=true)" = RECOMMENDATION=ask ] || { echo "case reconfigure, sandbox set nothing: did not ask"; return 1; }
  [ -z "$(decision "$repo" sandbox-recommendation)" ] || { echo "case reconfigure, sandbox set nothing: recorded"; return 1; }
  output_text="$(run_block "$repo" "$(recommendation_block)" MAY_RECORD_PROJECT=admin RECONFIGURE=true SANDBOX_TEAM_SET=true)"
  grep -qF 'RECOMMENDATION=ask' <<<"$output_text" && { echo "case reconfigure, sandbox set it: asked"; return 1; }
  output_text="$(run_block "$repo" "$(recommendation_block)" MAY_RECORD_PROJECT=admin)"
  grep -qF 'RECOMMENDATION=ask' <<<"$output_text" && { echo "case absent key: asked"; return 1; }
  [ "$(decision "$repo" sandbox-recommendation)" = declined ] || { echo "case absent key: not declined"; return 1; }
  [ "$(jq -r 'has("sandbox_recommended")' "${repo}/.gaia/project.json")" = false ] || { echo "case absent key: key written"; return 1; }
  printf '%s\n' '{"version": 1, "sandbox_recommended": true}' >"${repo}/.gaia/project.json"
  run_block "$repo" "$(recommendation_block)" MAY_RECORD_PROJECT=admin >/dev/null
  [ "$(decision "$repo" sandbox-recommendation)" = applied ] || { echo "case set key: not applied"; return 1; }
}

@test "the sandbox answer sets the team recommendation by arm" {
  local repo answer value record
  [ -n "$(team_from_sandbox_block)" ] || { echo "the team recommendation block is empty"; return 1; }
  # One repository: the arms that write nothing run before the admin-ready arm.
  repo="$(make_repo team-from-sandbox)"
  [ -z "$(run_block "$repo" "$(team_from_sandbox_block)" RECONFIGURE=true MAY_RECORD_PROJECT=none SANDBOX_ANSWER=enable)" ] || { echo "case non-admin reconfigure: printed"; return 1; }
  [ -z "$(run_block "$repo" "$(team_from_sandbox_block)" MAY_RECORD_PROJECT=admin SANDBOX_ANSWER=enable)" ] || { echo "case plain run: printed"; return 1; }
  [ ! -e "${repo}/.gaia/project.json" ] || { echo "case non-admin: project.json written"; return 1; }
  [ -z "$(decision "$repo" sandbox-recommendation)" ] || { echo "case non-admin: recorded"; return 1; }
  [ -z "$(run_block "$repo" "$(team_from_sandbox_block)" RECONFIGURE=true MAY_RECORD_PROJECT=admin)" ] || { echo "case admin-incapable: printed"; return 1; }
  [ ! -e "${repo}/.gaia/project.json" ] || { echo "case admin-incapable: project.json written"; return 1; }
  [ -z "$(decision "$repo" sandbox-recommendation)" ] || { echo "case admin-incapable: recorded"; return 1; }
  [ "$(run_block "$repo" "$(recommendation_block)" MAY_RECORD_PROJECT=admin RECONFIGURE=true)" = RECOMMENDATION=ask ] || { echo "case admin-incapable: own question not asked"; return 1; }
  for answer in enable decline; do
    case "$answer" in
      enable) value=true record=applied ;;
      decline) value=false record=declined ;;
    esac
    [ "$(run_block "$repo" "$(team_from_sandbox_block)" RECONFIGURE=true MAY_RECORD_PROJECT=admin SANDBOX_ANSWER="$answer")" = SANDBOX_TEAM_SET=true ] || { echo "case admin-ready ${answer}: not set"; return 1; }
    [ "$(jq -r '.sandbox_recommended' "${repo}/.gaia/project.json")" = "$value" ] || { echo "case admin-ready ${answer}: value"; return 1; }
    [ "$(decision "$repo" sandbox-recommendation)" = "$record" ] || { echo "case admin-ready ${answer}: record"; return 1; }
  done
}

@test "a fresh init then a plain setup owe none of the isolation, sandbox and recommendation ids" {
  local repo id route
  repo="$(make_repo fresh-defaults)"
  # The init CLI refuses a tree with no manifest, the mark of a GAIA scaffold.
  cp "${REPO_ROOT}/.gaia/manifest.json" "${repo}/.gaia/manifest.json"
  run_block "$repo" "$(init_settings_block)" >/dev/null
  route="$(run_block "$repo" "$(sandbox_route_block)")"
  [ "$route" = SANDBOX=default-off ]
  run_block "$repo" "$(default_off_block)" STUB_SANDBOX_CAPABILITY=ready >/dev/null
  run_block "$repo" "$(isolation_block)" MAY_RECORD_PROJECT=admin >/dev/null
  run_block "$repo" "$(recommendation_block)" MAY_RECORD_PROJECT=admin >/dev/null
  for id in isolation-policy sandbox sandbox-recommendation; do
    grep -qxF -- "$id" <<<"$(undecided_ids "$repo" | tr ' ' '\n')" && {
      echo "${id} is still owed after the defaults" >&2
      return 1
    }
  done
  [ "$(jq -r 'has("isolation_policy")' "${repo}/.gaia/project.json")" = false ]
  [ ! -e "${repo}/.gaia/local/sandbox.json" ]
}
