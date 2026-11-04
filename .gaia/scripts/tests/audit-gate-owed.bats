#!/usr/bin/env bats

# Tests for .gaia/scripts/audit-gate-owed.sh. The script runs from a scratch
# copy beside a stub evaluator, so the real evaluator is never run; pnpm and
# the dev smoke test are stubs that log their arguments.

setup() {
  REAL_SCRIPT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/audit-gate-owed.sh"
  T="$BATS_TEST_TMPDIR"
  R="$T/repo"
  D="$T/run"
  mkdir -p "$T/scripts" "$T/bin" "$R/.gaia/scripts" "$R/apps/web/app" "$D"
  cp "$REAL_SCRIPT" "$T/scripts/audit-gate-owed.sh"
  G="$T/scripts/audit-gate-owed.sh"
  CALLS="$T/calls.log"
  : >"$CALLS"

  cat >"$T/scripts/audit-loop-eval.sh" <<EOF
#!/usr/bin/env bash
case "\$1" in
  findings) cat "$T/findings.json" ;;
  current-round) cat "$T/current-round" ;;
esac
EOF
  printf '3\n' >"$T/current-round"

  cat >"$T/bin/pnpm" <<EOF
#!/usr/bin/env bash
printf 'pnpm %s\n' "\$*" >>"$CALLS"
[ ! -f "$T/fail-\$3" ] || exit 1
[ ! -f "$T/edit-\$3" ] || printf 'x\n' >>"$R/apps/web/app/a.ts"
exit 0
EOF
  cat >"$R/.gaia/scripts/dev-smoke.sh" <<EOF
#!/usr/bin/env bash
printf 'smoke %s\n' "\$*" >>"$CALLS"
[ ! -f "$T/smoke-rc" ] || exit "\$(cat "$T/smoke-rc")"
exit 0
EOF
  chmod +x "$T/bin/pnpm" "$R/.gaia/scripts/dev-smoke.sh" "$T/scripts/audit-loop-eval.sh"
  export PATH="$T/bin:$PATH"

  git -C "$R" init --quiet --initial-branch=main
  git -C "$R" config user.email t@example.com
  git -C "$R" config user.name T
  git -C "$R" config commit.gpgsign false
  printf 'readme\n' >"$R/README.md"
  printf 'export const a = 1;\n' >"$R/apps/web/app/a.ts"
  git -C "$R" add -A
  git -C "$R" commit --quiet -m init
}

gate() { bash "$G" "$@" --root "$R" --run-folder "$D"; }

commit_path() {
  mkdir -p "$(dirname "$R/$1")"
  printf '%s\n' "$RANDOM" >>"$R/$1"
  git -C "$R" add -A
  git -C "$R" commit --quiet -m "change $1"
}

finding_row() {
  printf '{"member":"m","finding_class":"c","path":"%s","line":1,"severity":"%s","security":%s}' "$1" "$2" "$3"
}

write_findings() {
  printf '{"round":1,"entries":[%s],"missing_members":[]}\n' "$1" >"$T/findings.json"
}

write_fixes() {
  printf '{"version":1,"entries":[%s]}\n' "$1" >"$D/dispositions-1.json"
}

fix_entry() {
  printf '{"member":"m","finding_class":"c","path":"%s","line":1,"disposition":"fix"}' "$1"
}

# --- choose ------------------------------------------------------------------

@test "choose: all-Minor fixes pick the smaller gate" {
  write_findings "$(finding_row a.ts minor false),$(finding_row b.ts minor false)"
  write_fixes "$(fix_entry a.ts),$(fix_entry b.ts)"
  run gate choose --round 1
  [ "$status" -eq 0 ]
  [ "$output" = smaller ]
}

@test "choose: a Major, a Critical, security true or absent, a missing row, or zero fixes pick full" {
  local severity
  for severity in major critical; do
    write_findings "$(finding_row a.ts minor false),$(finding_row b.ts "$severity" false)"
    write_fixes "$(fix_entry a.ts),$(fix_entry b.ts)"
    run gate choose --round 1
    [ "$output" = full ]
  done
  write_findings "$(finding_row a.ts minor true)"
  write_fixes "$(fix_entry a.ts)"
  run gate choose --round 1
  [ "$output" = full ]
  write_findings '{"member":"m","finding_class":"c","path":"a.ts","line":1,"severity":"minor"}'
  run gate choose --round 1
  [ "$output" = full ]
  write_findings "$(finding_row a.ts minor false)"
  write_fixes "$(fix_entry a.ts),$(fix_entry missing.ts)"
  run gate choose --round 1
  [ "$output" = full ]
  write_fixes ""
  run gate choose --round 1
  [ "$status" -eq 0 ]
  [ "$output" = full ]
}

# --- mark, status, selection -------------------------------------------------

@test "status after mark on a frontend path is owed, and a harness-only commit keeps it owed" {
  commit_path apps/web/app/a.ts
  gate mark --round 1
  run gate status
  [ "$status" -eq 1 ]
  commit_path .claude/rules/x.md
  run gate status
  [ "$status" -eq 1 ]
  run gate selection
  [ "$output" = apps/web/app/a.ts ]
}

@test "status is clear with no record" {
  run gate status
  [ "$status" -eq 0 ]
}

@test "a corrupt record exits 3 on status" {
  printf 'not json\n' >"$D/gate-owed.json"
  run gate status
  [ "$status" -eq 3 ]
}

# --- run ---------------------------------------------------------------------

@test "run executes only the three rooted steps in order and a pass clears" {
  commit_path apps/web/app/a.ts
  gate mark --round 1
  run gate run
  [ "$status" -eq 0 ]
  [ "${lines[${#lines[@]}-1]}" = "gate-owed exit 0" ]
  [ "$(cat "$CALLS")" = "pnpm -C $R pw
smoke --tree $R
pnpm -C $R build" ]
  run gate status
  [ "$status" -eq 0 ]
  [ ! -e "$D/gate-failure.json" ]
}

@test "a failing step leaves the gate owed and writes the failure record" {
  commit_path apps/web/app/a.ts
  gate mark --round 2
  touch "$T/fail-build"
  run gate run
  [ "$status" -eq 1 ]
  [ "$(jq -r .step "$D/gate-failure.json")" = build ]
  [ "$(jq -r .after_round "$D/gate-failure.json")" = 3 ]
  [ "$(jq -r .tree "$D/gate-failure.json")" = "$(git -C "$R" rev-parse 'HEAD^{tree}')" ]
  run gate status
  [ "$status" -eq 1 ]
}

@test "a step that edits a tracked file fails the run though it exited 0" {
  commit_path apps/web/app/a.ts
  gate mark --round 1
  touch "$T/edit-pw"
  run gate run
  [ "$status" -eq 1 ]
  [ "$(jq -r .step "$D/gate-failure.json")" = pw ]
}

@test "an unreadable current round exits 3 and writes no failure record" {
  commit_path apps/web/app/a.ts
  gate mark --round 1
  touch "$T/fail-pw"
  rm "$T/current-round"
  run gate run
  [ "$status" -eq 3 ]
  [ ! -e "$D/gate-failure.json" ]
}

@test "a smoke refusal of 2 or 3 stays owed, writes no failure record and exits 3" {
  local code
  commit_path apps/web/app/a.ts
  gate mark --round 1
  for code in 3 2; do
    printf '%s' "$code" >"$T/smoke-rc"
    run gate run
    [ "$status" -eq 3 ]
    [ "${lines[${#lines[@]}-1]}" = "gate-owed exit 3" ]
    [ ! -e "$D/gate-failure.json" ]
    run gate status
    [ "$status" -eq 1 ]
  done
}

# --- pass evidence -----------------------------------------------------------

@test "steps-passed with no pass evidence refuses with exit 4 and the gate stays owed" {
  commit_path apps/web/app/a.ts
  gate mark --round 1
  touch "$T/fail-build"
  run gate run
  [ "$status" -eq 1 ]
  run gate steps-passed
  [ "$status" -eq 4 ]
  [[ "$output" == *"steps-passed refused: no pass evidence for HEAD tree"* ]]
  [ "$(jq -r .owed "$D/gate-owed.json")" = true ]
  [ "$(jq -r .last_failure.step "$D/gate-owed.json")" = build ]
  run gate status
  [ "$status" -eq 1 ]
}

@test "steps-passed refuses evidence recorded for another tree" {
  commit_path apps/web/app/a.ts
  gate mark --round 1
  run gate gate-steps
  [ "$status" -eq 0 ]
  commit_path apps/web/app/a.ts
  run gate steps-passed
  [ "$status" -eq 4 ]
  run gate status
  [ "$status" -eq 1 ]
}

@test "steps-passed refuses a malformed evidence file or one missing a step" {
  local tree
  commit_path apps/web/app/a.ts
  gate mark --round 1
  tree="$(git -C "$R" rev-parse 'HEAD^{tree}')"
  printf 'not json\n' >"$D/gate-pass.json"
  run gate steps-passed
  [ "$status" -eq 4 ]
  jq -n -c --arg tree "$tree" '{version: 1, tree: $tree, commit: "x", steps: ["pw", "build"], exit: 0}' >"$D/gate-pass.json"
  run gate steps-passed
  [ "$status" -eq 4 ]
  jq -n -c --arg tree "$tree" '{version: 1, tree: $tree, commit: "x", steps: ["pw", "smoke", "build"], exit: 1}' >"$D/gate-pass.json"
  run gate steps-passed
  [ "$status" -eq 4 ]
  run gate status
  [ "$status" -eq 1 ]
}

@test "a run failure discards earlier evidence for the same tree" {
  commit_path apps/web/app/a.ts
  gate mark --round 1
  gate gate-steps >/dev/null
  touch "$T/fail-build"
  run gate run
  [ "$status" -eq 1 ]
  [ ! -e "$D/gate-pass.json" ]
  run gate steps-passed
  [ "$status" -eq 4 ]
}

@test "gate-steps passing before a commit lets steps-passed clear the committed tree" {
  commit_path apps/web/app/a.ts
  gate mark --round 1
  printf 'export const b = 2;\n' >"$R/apps/web/app/b.ts"
  run gate gate-steps
  [ "$status" -eq 0 ]
  [ "${lines[${#lines[@]}-1]}" = "gate-owed exit 0" ]
  [ "$(cat "$CALLS")" = "pnpm -C $R pw
smoke --tree $R
pnpm -C $R build" ]
  [ "$(jq -r .owed "$D/gate-owed.json")" = true ]
  git -C "$R" add -A
  git -C "$R" commit --quiet -m "fix round"
  run gate steps-passed
  [ "$status" -eq 0 ]
  [ "$(jq -r .owed "$D/gate-owed.json")" = false ]
  run gate status
  [ "$status" -eq 0 ]
}

@test "a commit that leaves out a gated change gives steps-passed nothing to clear" {
  commit_path apps/web/app/a.ts
  gate mark --round 1
  printf 'export const b = 2;\n' >"$R/apps/web/app/b.ts"
  printf 'export const c = 3;\n' >"$R/apps/web/app/c.ts"
  gate gate-steps >/dev/null
  git -C "$R" add apps/web/app/b.ts
  git -C "$R" commit --quiet -m "partial"
  run gate steps-passed
  [ "$status" -eq 4 ]
}

@test "a failing gate-steps writes no evidence and leaves the owed record alone" {
  commit_path apps/web/app/a.ts
  gate mark --round 1
  touch "$T/fail-pw"
  run gate gate-steps
  [ "$status" -eq 1 ]
  [ ! -e "$D/gate-pass.json" ]
  [ ! -e "$D/gate-failure.json" ]
  [ "$(jq -r .last_failure "$D/gate-owed.json")" = null ]
  run gate steps-passed
  [ "$status" -eq 4 ]
}

# --- pass-tree rule and since ------------------------------------------------

@test "after a pass a harness-only commit is clear, a later frontend commit is owed" {
  commit_path apps/web/app/a.ts
  gate mark --round 1
  gate run >/dev/null
  commit_path .claude/rules/x.md
  run gate status
  [ "$status" -eq 0 ]
  commit_path apps/web/app/a.ts
  run gate status
  [ "$status" -eq 1 ]
  [ "$(jq -r .owed "$D/gate-owed.json")" = false ]
}

@test "a catch-up merge carrying frontend paths after a pass is clear" {
  commit_path apps/web/app/a.ts
  gate mark --round 1
  gate run >/dev/null
  git -C "$R" checkout --quiet -b side HEAD~1
  commit_path apps/web/app/side.ts
  git -C "$R" checkout --quiet main
  git -C "$R" merge --quiet --no-ff --no-edit side
  run gate status
  [ "$status" -eq 0 ]
}

@test "since advances: a harness-only mark after a pass selects nothing" {
  commit_path apps/web/app/a.ts
  gate mark --round 1
  gate run >/dev/null
  commit_path .claude/rules/x.md
  gate mark --round 2
  run gate selection
  [ -z "$output" ]
  [ "$(jq -r .owed "$D/gate-owed.json")" = true ]
}

# --- status without a run folder ---------------------------------------------

@test "status with no run folder reads the main checkout's record from a worktree" {
  local main="$T/main" worktree="$T/main-wt" key folder
  git init --quiet --initial-branch=main "$main"
  git -C "$main" config user.email t@example.com
  git -C "$main" config user.name T
  git -C "$main" config commit.gpgsign false
  mkdir -p "$main/apps/web/app"
  printf 'x\n' >"$main/apps/web/app/a.ts"
  git -C "$main" add -A
  git -C "$main" commit --quiet -m init
  git -C "$main" worktree add --quiet -b feat/gate-fixture "$worktree"
  printf 'y\n' >>"$worktree/apps/web/app/a.ts"
  git -C "$worktree" commit --quiet -am change
  key="$(. "$(dirname "$REAL_SCRIPT")/audit-loop-state-lib.sh"; gaia_loop_key "$worktree")"
  folder="$(cd "$main" && pwd -P)/.gaia/local/runs/$key"
  bash "$REAL_SCRIPT" mark --round 1 --root "$worktree" --run-folder "$folder"
  run bash "$REAL_SCRIPT" status --root "$worktree"
  [ "$status" -eq 1 ]
  run bash "$REAL_SCRIPT" status --root "$T/not-a-repo"
  [ "$status" -eq 3 ]
}

@test "the script carries no working-document id" {
  grep -qE '(SPEC|UAT)-[0-9]' "$REAL_SCRIPT" && return 1
  true
}
