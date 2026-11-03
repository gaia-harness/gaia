#!/usr/bin/env bats
# The `## First CI run` fences of `.claude/skills/gaia/references/setup/github-repo.md`,
# extracted and run against stubbed `gh` and `sleep`. A new repository can
# start no workflow run while its Actions settings read enabled, so the probe
# waits a bounded time for a run on the pushed commit, and the recovery
# dispatches `tests.yml` once and checks once. Every outcome that is not a run
# reports itself (`no-run`, `dispatch-failed`); none loops past its bound.
#
# Mutation tests prove the bound and the skip guard can fail.
#
# Assertion style: .claude/rules/bats-assertions.md.

POLL_LIMIT=9

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  PAGE="${REPO_ROOT}/.claude/skills/gaia/references/setup/github-repo.md"
  [ -f "$PAGE" ] || {
    echo "the audited page is absent: ${PAGE}" >&2
    return 1
  }
  PROJECT="${BATS_TEST_TMPDIR}/project"
  mkdir -p "${PROJECT}/.github/workflows"
  : >"${PROJECT}/.github/workflows/tests.yml"
  git -C "$PROJECT" init -q
  git -C "$PROJECT" -c user.email=t@example.com -c user.name=t -c commit.gpgsign=false \
    commit -q --allow-empty --no-verify -m init
  STUB_BIN="${BATS_TEST_TMPDIR}/stub-bin"
  mkdir -p "$STUB_BIN"
  cat >"${STUB_BIN}/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_LOG"
case "$1" in
  workflow) exit "${GH_DISPATCH_EXIT:-0}" ;;
  api)
    [ -n "${GH_API_FAIL:-}" ] && exit 1
    polls="$(grep -c '^api ' "$GH_LOG")"
    if [ "$polls" -ge "${GH_RUN_FROM_POLL:-999}" ]; then echo 1; else echo 0; fi
    ;;
esac
STUB
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"$SLEEP_LOG"\n' >"${STUB_BIN}/sleep"
  chmod +x "${STUB_BIN}/gh" "${STUB_BIN}/sleep"
  GH_LOG="${BATS_TEST_TMPDIR}/gh.log"
  SLEEP_LOG="${BATS_TEST_TMPDIR}/sleep.log"
  : >"$GH_LOG"
  : >"$SLEEP_LOG"
  export GH_LOG SLEEP_LOG
}

# fence_with <anchor> <file>: print the body of the one bash fence in <file>
# containing <anchor>; fail unless exactly one fence matches.
fence_with() {
  awk -v anchor="$1" '
    /^```bash[[:space:]]*$/ { inside = 1; body = ""; next }
    /^```[[:space:]]*$/ && inside {
      inside = 0
      if (index(body, anchor)) { printf "%s", body; found++ }
      next
    }
    inside { body = body $0 "\n" }
    END { if (found != 1) exit 1 }
  ' "$2"
}

# extract <anchor> [<page>]: write the fence to fence.sh.
extract() {
  fence_with "$1" "${2:-$PAGE}" >"${BATS_TEST_TMPDIR}/fence.sh"
  [ -s "${BATS_TEST_TMPDIR}/fence.sh" ]
}

# run_fence [<default branch>]: run fence.sh from the project with the stubs.
run_fence() {
  run env OWNER=acme REPO=app DEFAULT_BRANCH="${1:-main}" PATH="${STUB_BIN}:${PATH}" \
    bash -c 'cd "$1" && bash "$2"' _ "$PROJECT" "${BATS_TEST_TMPDIR}/fence.sh"
}

api_calls() { grep -c '^api ' "$GH_LOG" || true; }

@test "probe: a run on the first poll reports run-seen with no wait" {
  extract 'first_run_probe()'
  GH_RUN_FROM_POLL=1 run_fence
  [ "$status" -eq 0 ]
  [ "$output" = "actions-probe: run-seen" ]
  [ "$(api_calls)" -eq 1 ]
  [ ! -s "$SLEEP_LOG" ]
}

@test "probe: the poll targets the pushed commit's runs" {
  extract 'first_run_probe()'
  GH_RUN_FROM_POLL=1 run_fence
  local sha
  sha="$(git -C "$PROJECT" rev-parse HEAD)"
  grep -qF -- "api repos/acme/app/actions/runs?head_sha=${sha} --jq .total_count" "$GH_LOG"
}

@test "probe: no run reports no-run after exactly the bound" {
  extract 'first_run_probe()'
  run_fence
  [ "$status" -eq 0 ]
  [ "$output" = "actions-probe: no-run" ]
  [ "$(api_calls)" -eq "$POLL_LIMIT" ]
  [ "$(wc -l <"$SLEEP_LOG" | tr -d ' ')" -eq $((POLL_LIMIT - 1)) ]
}

@test "probe: a failing gh reads as no run, not as a run" {
  extract 'first_run_probe()'
  GH_API_FAIL=1 run_fence
  [ "$output" = "actions-probe: no-run" ]
}

@test "probe: a default branch other than main skips without calling gh" {
  extract 'first_run_probe()'
  run_fence master
  [ "$output" = "actions-probe: skipped" ]
  [ ! -s "$GH_LOG" ]
}

@test "probe: an absent tests.yml skips without calling gh" {
  extract 'first_run_probe()'
  rm "${PROJECT}/.github/workflows/tests.yml"
  run_fence
  [ "$output" = "actions-probe: skipped" ]
  [ ! -s "$GH_LOG" ]
}

@test "dispatch: a failed gh workflow run reports dispatch-failed and polls nothing" {
  extract 'first_run_dispatch()'
  GH_DISPATCH_EXIT=1 run_fence
  [ "$status" -eq 0 ]
  [ "$output" = "actions-probe: dispatch-failed" ]
  [ "$(api_calls)" -eq 0 ]
}

@test "dispatch: dispatches tests.yml on main, then a run reports run-seen" {
  extract 'first_run_dispatch()'
  GH_RUN_FROM_POLL=2 run_fence
  [ "$output" = "actions-probe: run-seen" ]
  grep -qxF -- "workflow run tests.yml --repo acme/app --ref main" "$GH_LOG"
  [ "$(api_calls)" -eq 2 ]
}

@test "dispatch: no run after the dispatch reports no-run after exactly the bound" {
  extract 'first_run_dispatch()'
  run_fence
  [ "$output" = "actions-probe: no-run" ]
  [ "$(api_calls)" -eq "$POLL_LIMIT" ]
  [ "$(grep -c '^workflow ' "$GH_LOG")" -eq 1 ]
}

@test "page: every non-run outcome routes to the hand-off, and the question offers enable or skip" {
  local section
  section="$(awk '/^## First CI run$/ { on = 1; next } /^## / && on { exit } on' "$PAGE")"
  [ -n "$section" ]
  grep -qF -- 'On `dispatch-failed`, `no-run` or `Skip for now`, print the following' <<<"$section"
  grep -qF -- '! gh workflow run tests.yml --ref main' <<<"$section"
  grep -qF -- '**I enabled it** (Recommended)' <<<"$section"
  grep -qF -- '**Skip for now**' <<<"$section"
  grep -qF -- 'Then run `## First CI run` below' "$PAGE"
}

@test "mutation: a probe with its poll bound removed fails the bound fixture" {
  local mutant="${BATS_TEST_TMPDIR}/mutant.md"
  sed 's/for attempt in 1 2 3 4 5 6 7 8 9; do/for attempt in 1 2 3 4 5 6 7 8 9 10 11; do/' "$PAGE" >"$mutant"
  cmp -s "$PAGE" "$mutant" && return 1
  extract 'first_run_probe()' "$mutant"
  run_fence
  [ "$(api_calls)" -ne "$POLL_LIMIT" ]
}

@test "mutation: a probe without its main guard calls gh on master" {
  local mutant="${BATS_TEST_TMPDIR}/mutant.md"
  sed 's/if \[ "\$DEFAULT_BRANCH" != main \] || /if /' "$PAGE" >"$mutant"
  cmp -s "$PAGE" "$mutant" && return 1
  extract 'first_run_probe()' "$mutant"
  run_fence master
  [ -s "$GH_LOG" ]
}
