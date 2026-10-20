#!/usr/bin/env bats
#
# The backstop reaper driver, end to end. Every case builds a fixture main
# checkout under $BATS_TEST_TMPDIR, copies the driver, its libraries and the
# committed state registry into it, plants .gaia/local entries at the
# registry's real row paths with aged mtimes, runs the fixture's copy and
# asserts on disk. Windows are read from the committed registry, never typed.
# Every removal case pairs a survivor with a reaped entry in one run, so a
# survivor proves the rule rather than a reaper that deletes nothing.
#
# STATE_REAPER_SCRIPTS_UNDER_TEST points the copied scripts at a scratch
# directory, so a guard can be proven able to fail by running a case against
# a deliberately broken copy; the reaper itself reads no such variable.
#
# Run via: bash .gaia/scripts/bats5.sh .gaia/scripts/tests/state-reaper.bats < /dev/null
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

SCRIPT_FILES="state-reaper.sh state-reaper-lib.sh state-reaper-classes.sh main-root-lib.sh state-registry-lib.sh branch-name-lib.sh audit-key-lib.sh audit-loop-state-lib.sh"
SHA="0123456789abcdef0123456789abcdef01234567"

setup() {
  SCRIPTS_DIRECTORY="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SCRIPTS_UNDER_TEST="${STATE_REAPER_SCRIPTS_UNDER_TEST:-$SCRIPTS_DIRECTORY}"
  REAL_REGISTRY="$(cd "$SCRIPTS_DIRECTORY/.." && pwd)/state-registry.json"
  command -v jq >/dev/null 2>&1 || skip "jq required"
  command -v git >/dev/null 2>&1 || skip "git required"
  REAL_GIT="$(command -v git)"
  # shellcheck source=/dev/null
  . "$SCRIPTS_DIRECTORY/main-root-lib.sh"
  # shellcheck source=/dev/null
  . "$SCRIPTS_DIRECTORY/branch-name-lib.sh"
  # shellcheck source=/dev/null
  . "$SCRIPTS_DIRECTORY/audit-key-lib.sh"
}

# make_fixture [<parent>]: a committed main checkout holding copies of the
# driver, its libraries and the committed registry. Sets MAIN, LOCAL and
# PARENT.
make_fixture() {
  local script_file
  PARENT="${1:-$BATS_TEST_TMPDIR}"
  MAIN="$PARENT/main"
  mkdir -p "$MAIN/.gaia/scripts" "$MAIN/.gaia/local"
  for script_file in $SCRIPT_FILES; do
    cp "$SCRIPTS_UNDER_TEST/$script_file" "$MAIN/.gaia/scripts/$script_file"
  done
  mkdir -p "$MAIN/.gaia/scripts/notebook" "$MAIN/.gaia/scripts/spec"
  cp "$SCRIPTS_DIRECTORY"/notebook/*.sh "$MAIN/.gaia/scripts/notebook/"
  cp "$SCRIPTS_DIRECTORY/spec/with-ledger-lock.sh" "$MAIN/.gaia/scripts/spec/"
  cp "$REAL_REGISTRY" "$MAIN/.gaia/state-registry.json"
  "$REAL_GIT" -C "$MAIN" init -q
  "$REAL_GIT" -C "$MAIN" symbolic-ref HEAD refs/heads/main
  "$REAL_GIT" -C "$MAIN" config user.email fixture@example.com
  "$REAL_GIT" -C "$MAIN" config user.name fixture
  "$REAL_GIT" -C "$MAIN" add -A
  "$REAL_GIT" -C "$MAIN" commit -q -m fixture
  LOCAL="$MAIN/.gaia/local"
}

make_branch() { "$REAL_GIT" -C "$MAIN" branch "$1"; }

# make_worktree <directory-name> <new-branch>: a linked worktree beside MAIN.
make_worktree() { "$REAL_GIT" -C "$MAIN" worktree add -q "$PARENT/$1" -b "$2"; }

# stamp <days>: a `touch -t` stamp that many days and an hour ago, so a whole
# day comparison is never on the boundary. BSD and GNU safe.
stamp() {
  local epoch=$(($(date +%s) - $1 * 86400 - 3600))
  date -r "$epoch" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$epoch" +%Y%m%d%H%M.%S
}

# plant_file <relative> <days>
plant_file() {
  mkdir -p "$(dirname "$LOCAL/$1")"
  printf 'content of %s\n' "$1" >"$LOCAL/$1"
  touch -t "$(stamp "$2")" "$LOCAL/$1"
}

# plant_dir <relative> <days>: a directory holding one file, both aged.
plant_dir() {
  mkdir -p "$LOCAL/$1"
  printf 'content of %s\n' "$1" >"$LOCAL/$1/inner"
  touch -t "$(stamp "$2")" "$LOCAL/$1/inner" "$LOCAL/$1"
}

# plant_link <relative> <target> <days>
plant_link() {
  mkdir -p "$(dirname "$LOCAL/$1")"
  ln -s "$2" "$LOCAL/$1"
  touch -h -t "$(stamp "$3")" "$LOCAL/$1"
}

present() {
  [ -e "$LOCAL/$1" ] || [ -L "$LOCAL/$1" ] || {
    printf 'expected present: %s\n' "$1" >&2
    return 1
  }
}

absent() {
  if [ -e "$LOCAL/$1" ] || [ -L "$LOCAL/$1" ]; then
    printf 'expected removed: %s\n' "$1" >&2
    return 1
  fi
}

# row_field <row-id> <jq-path>: a field of one committed registry row.
row_field() { jq -r --arg id "$1" ".entries[] | select(.id == \$id) | $2" "$REAL_REGISTRY"; }

# window <row-id> [<field>]: a positive integer window of a committed row.
window() {
  local value
  value="$(row_field "$1" ".retention.${2:-days}")"
  case "$value" in
    '' | *[!0-9]*)
      printf 'row %s has no integer %s\n' "$1" "${2:-days}" >&2
      return 1
      ;;
  esac
  [ "$value" -ge 2 ] || return 1
  printf '%s\n' "$value"
}

run_reaper() {
  run bash "$MAIN/.gaia/scripts/state-reaper.sh" </dev/null
}

# plant_branch_entries <branch> <runs-key> <days>: every entry kind the
# branch-spent rows key on a branch, and the paths it planted.
plant_branch_entries() {
  local slug
  slug="$(gaia_key_slug "$1")"
  plant_file "audit/$SHA.$slug.code-audit.findings.json" "$3"
  plant_file "audit/$SHA.$slug.code-audit.scope.json" "$3"
  plant_file "audit/$SHA.$slug.code-audit.review.diff" "$3"
  plant_file "audit/$SHA.$slug.rerun.json" "$3"
  plant_file "audit/light/$slug.reviews.jsonl" "$3"
  plant_file "cache/gh-artifact-pr.$slug.json" "$3"
  plant_dir "runs/$2" "$3"
  BRANCH_ENTRIES="audit/$SHA.$slug.code-audit.findings.json
audit/$SHA.$slug.code-audit.scope.json
audit/$SHA.$slug.code-audit.review.diff
audit/$SHA.$slug.rerun.json
audit/light/$slug.reviews.jsonl
cache/gh-artifact-pr.$slug.json
runs/$2"
}

# assert_each <present|absent> <newline-list>
assert_each() {
  local entry count=0
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    "$1" "$entry"
    count=$((count + 1))
  done <<<"$2"
  [ "$count" -gt 0 ]
}

# make_catalog <json>: the notebook catalog the spec rows read.
make_catalog() {
  mkdir -p "$MAIN/.notebook"
  printf '%s\n' "$1" >"$MAIN/.notebook/catalog.json"
}

# install_failing_git <subcommand words>: a git on a fixture bin directory
# that fails that read and passes everything else through.
install_failing_git() {
  mkdir -p "$MAIN/bin"
  cat >"$MAIN/bin/git" <<EOF
#!/bin/sh
case " \$* " in *" $1 "*) exit 1 ;; esac
exec "$REAL_GIT" "\$@"
EOF
  chmod +x "$MAIN/bin/git"
}

run_reaper_with_failing_git() {
  PATH="$MAIN/bin:$PATH" run bash "$MAIN/.gaia/scripts/state-reaper.sh" </dev/null
}

# plant_git_failure_fixture: keyed and age-classed entries that are all over
# their windows, for the cases where a git read fails.
plant_git_failure_fixture() {
  local branch_window
  branch_window="$(window audit-review-diffs)"
  plant_branch_entries "fix/gone" "fix/gone" $((branch_window + 1))
  plant_dir "red-ledger/aaaaaaaaaaaaaaaa" 1
  GONE_TREE_ENTRY="red-ledger/aaaaaaaaaaaaaaaa"
  AGED_ENTRY="cache/doctrine-injected.sess"
  plant_file "$AGED_ENTRY" $(($(window doctrine-injected-marker) + 1))
}

# bats test_tags=whole-tree
@test "the fixture copies every library the reaper sources" {
  local script_file referenced name
  for script_file in state-reaper.sh state-reaper-lib.sh state-reaper-classes.sh audit-loop-state-lib.sh state-registry-lib.sh; do
    referenced="$(grep -Eho '(source|\.) "\$[A-Za-z_]+/[a-z-]+\.sh"' "$SCRIPTS_DIRECTORY/$script_file" | grep -Eo '[a-z-]+\.sh')"
    [ -n "$referenced" ] || continue
    for name in $referenced; do
      case " $SCRIPT_FILES " in *" $name "*) ;; *)
        printf '%s sources %s, which the fixture does not copy\n' "$script_file" "$name" >&2
        return 1
        ;;
      esac
    done
  done
}

# bats test_tags=whole-tree
@test "a gone branch's entries are removed past the window; live and worktree branches keep theirs" {
  make_fixture
  make_branch fix/x
  make_worktree wt-foo worktree-foo
  local age_days=$(($(window audit-review-diffs) + 1))
  plant_branch_entries fix/y fix/y "$age_days"
  GONE="$BRANCH_ENTRIES"
  plant_branch_entries fix/x fix/x "$age_days"
  LIVE="$BRANCH_ENTRIES"
  plant_branch_entries worktree-foo foo "$age_days"
  WORKTREE="$BRANCH_ENTRIES"
  run_reaper
  [ "$status" -eq 0 ]
  assert_each absent "$GONE"
  assert_each present "$LIVE"
  assert_each present "$WORKTREE"
  present runs/fix
}

# bats test_tags=whole-tree
@test "a gone branch's entries inside the window survive, and a folder holding a fresh file keeps its old directory" {
  make_fixture
  local old_days=$(($(window runs) + 1)) recent_days=2
  [ "$(window runs)" -gt "$recent_days" ]
  [ "$(window audit-review-diffs)" -gt "$recent_days" ]
  plant_branch_entries recent-branch recent-branch "$recent_days"
  RECENT="$BRANCH_ENTRIES"
  plant_branch_entries spent-branch spent-branch "$old_days"
  SPENT="$BRANCH_ENTRIES"
  plant_dir runs/mixed "$old_days"
  plant_file runs/mixed/fresh 1
  touch -t "$(stamp "$old_days")" "$LOCAL/runs/mixed"
  run_reaper
  [ "$status" -eq 0 ]
  assert_each absent "$SPENT"
  assert_each present "$RECENT"
  present runs/mixed/fresh
}

# bats test_tags=whole-tree
@test "tree-keyed ledgers of an unlisted worktree go; the main checkout's and a listed worktree's stay, from a symlinked fixture root" {
  mkdir -p "$BATS_TEST_TMPDIR/real-parent"
  ln -s real-parent "$BATS_TEST_TMPDIR/link-parent"
  make_fixture "$BATS_TEST_TMPDIR/link-parent"
  make_worktree wt-live live-branch
  make_worktree wt-gone gone-branch
  local main_key live_key gone_key ledger
  main_key="$(cd "$MAIN" && gaia_tree_key)"
  live_key="$(cd "$PARENT/wt-live" && gaia_tree_key)"
  gone_key="$(cd "$PARENT/wt-gone" && gaia_tree_key)"
  "$REAL_GIT" -C "$MAIN" worktree remove --force "$PARENT/wt-gone"
  [ "$main_key" != "$live_key" ]
  [ "$live_key" != "$gone_key" ]
  [ "$main_key" != "$gone_key" ]
  for ledger in red-ledger worthiness-ledger; do
    plant_dir "$ledger/$main_key" 1
    plant_dir "$ledger/$live_key" 1
    plant_dir "$ledger/$gone_key" 1
  done
  run_reaper
  [ "$status" -eq 0 ]
  for ledger in red-ledger worthiness-ledger; do
    absent "$ledger/$gone_key"
    present "$ledger/$main_key"
    present "$ledger/$live_key"
  done
}

# bats test_tags=whole-tree
@test "age-classed entries are removed one day past their committed window and kept one day inside it" {
  make_fixture
  local pair row_id kind young old days
  local -a pairs=(
    "doctrine-injected-marker|file|cache/doctrine-injected.young|cache/doctrine-injected.old"
    "audit-mutation-scratch|dir|cache/mutation-scratch/young|cache/mutation-scratch/old"
    "context-readings|file|cache/shared/context/young.json|cache/shared/context/old.json"
    "context-checkpoint-markers|file|cache/context-checkpoint/young|cache/context-checkpoint/old"
    "context-checkpoint-agent-markers|file|cache/context-checkpoint-agents/young.agent|cache/context-checkpoint-agents/old.agent"
    "cache-shared-orphan-temps|file|cache/shared/.updates.young1|cache/shared/.updates.old001"
    "telemetry-usage-tmp|file|telemetry/.usage-young.tmp.1|telemetry/.usage-old.tmp.1"
    "audit-clearance-markers|file|audit/young-digest.member.ok|audit/old-digest.member.ok"
    "audit-light-review-state|file|audit/light/young-digest.member.route.json|audit/light/old-digest.member.route.json"
  )
  [ "${#pairs[@]}" -eq 9 ]
  for pair in "${pairs[@]}"; do
    IFS='|' read -r row_id kind young old <<<"$pair"
    days="$(window "$row_id")"
    "plant_$kind" "$young" $((days - 1))
    "plant_$kind" "$old" $((days + 1))
  done
  local session_window
  session_window="$(window runs session_days)"
  plant_dir runs/session-young $((session_window - 1))
  plant_dir runs/session-old $((session_window + 1))
  run_reaper
  [ "$status" -eq 0 ]
  for pair in "${pairs[@]}"; do
    IFS='|' read -r row_id kind young old <<<"$pair"
    present "$young"
    absent "$old"
  done
  present runs/session-young
  absent runs/session-old
}

# bats test_tags=whole-tree
@test "an aged refusal beside a younger same-digest earned marker is kept, an aged lone refusal and aged pair go" {
  make_fixture
  local days
  days="$(window audit-clearance-markers)"
  plant_file audit/shadowed-digest.member.refused $((days + 1))
  plant_file audit/shadowed-digest.member.ok $((days - 1))
  plant_file audit/lone-digest.member.refused $((days + 1))
  plant_file audit/pair-digest.member.refused $((days + 2))
  plant_file audit/pair-digest.member.ok $((days + 1))
  run_reaper
  [ "$status" -eq 0 ]
  present audit/shadowed-digest.member.refused
  present audit/shadowed-digest.member.ok
  absent audit/lone-digest.member.refused
  absent audit/pair-digest.member.ok
  absent audit/pair-digest.member.refused
}

# bats test_tags=whole-tree
@test "spec scratch of a ready or merged SPEC goes, a draft SPEC's stays" {
  make_fixture
  make_catalog '{"version":1,"items":[{"id":"draftone","kind":"spec","status":"draft"},{"id":"readyone","kind":"spec","status":"ready"},{"id":"mergedone","kind":"spec","status":"merged"}]}'
  local spec_id age_days
  age_days="$(window spec-draft-and-gate1-scratch)"
  for spec_id in draftone readyone mergedone; do
    plant_file "cache/draft-$spec_id.md" "$age_days"
    plant_file "cache/gate1-$spec_id.json" "$age_days"
    plant_file "cache/spec-session-$spec_id.json" "$age_days"
    plant_file "cache/spec-session-$spec_id.lock" "$age_days"
  done
  run_reaper
  [ "$status" -eq 0 ]
  for spec_id in readyone mergedone; do
    absent "cache/draft-$spec_id.md"
    absent "cache/gate1-$spec_id.json"
    absent "cache/spec-session-$spec_id.json"
    absent "cache/spec-session-$spec_id.lock"
  done
  present cache/draft-draftone.md
  present cache/gate1-draftone.json
  present cache/spec-session-draftone.json
  present cache/spec-session-draftone.lock
}

# bats test_tags=whole-tree
@test "spec scratch with no catalog row ages out by the row window, and so does the id-less draft" {
  make_fixture
  make_catalog '{"version":1,"items":[{"id":"other","kind":"spec","status":"draft"}]}'
  local age_days
  age_days="$(window spec-draft-and-gate1-scratch)"
  plant_file cache/gate1-stale.json $((age_days + 1))
  plant_file cache/draft-stale.md $((age_days + 1))
  plant_file cache/spec-session-stale.json $((age_days + 1))
  plant_file cache/gate1-fresh.json $((age_days - 1))
  plant_file cache/draft-fresh.md $((age_days - 1))
  plant_file cache/spec-session-fresh.json $((age_days - 1))
  plant_file cache/draft.md $((age_days + 1))
  run_reaper
  [ "$status" -eq 0 ]
  absent cache/gate1-stale.json
  absent cache/draft-stale.md
  absent cache/spec-session-stale.json
  absent cache/draft.md
  present cache/gate1-fresh.json
  present cache/draft-fresh.md
  present cache/spec-session-fresh.json
}

# bats test_tags=whole-tree
@test "a spec audit scratch directory follows its SPEC's catalog status and otherwise its age" {
  make_fixture
  make_catalog '{"version":1,"items":[{"id":"draftone","kind":"spec","status":"draft"},{"id":"readyone","kind":"spec","status":"ready"}]}'
  local age_days
  age_days="$(window spec-audit-scratch)"
  plant_dir cache/audit-draftone "$age_days"
  plant_dir cache/audit-readyone "$age_days"
  plant_dir cache/audit-stale $((age_days + 1))
  plant_dir cache/audit-fresh $((age_days - 1))
  run_reaper
  [ "$status" -eq 0 ]
  absent cache/audit-readyone
  absent cache/audit-stale
  present cache/audit-draftone
  present cache/audit-fresh
}

# bats test_tags=whole-tree
@test "an unparseable catalog keeps every spec scratch while age-classed markers still go" {
  make_fixture
  make_catalog 'this is { not json'
  local age_days marker_days
  age_days="$(window spec-draft-and-gate1-scratch)"
  marker_days="$(window doctrine-injected-marker)"
  plant_file cache/gate1-stale.json $((age_days + 1))
  plant_file cache/draft.md $((age_days + 1))
  plant_dir cache/audit-stale $((age_days + 1))
  plant_file cache/doctrine-injected.sess $((marker_days + 1))
  run_reaper
  [ "$status" -eq 0 ]
  present cache/gate1-stale.json
  present cache/draft.md
  present cache/audit-stale
  absent cache/doctrine-injected.sess
}

# bats test_tags=whole-tree
@test "audit-loop state recording a PR with no merge row survives, and spent state with none or a merged PR goes" {
  make_fixture
  local age_days
  age_days="$(window audit-loop-state)"
  age_days=$((age_days + 1))
  mkdir -p "$LOCAL/protected/audit-loop/fix" "$LOCAL/telemetry"
  printf '{"pr":77}\n' >"$LOCAL/protected/audit-loop/fix/held.json"
  printf '{"pr":null}\n' >"$LOCAL/protected/audit-loop/fix/free.json"
  printf '{"pr":78}\n' >"$LOCAL/protected/audit-loop/fix/merged.json"
  printf '{"kind":"merge","pr":78}\n' >"$LOCAL/telemetry/links.jsonl"
  plant_dir protected/audit-loop/fix/held.d "$age_days"
  plant_dir protected/audit-loop/fix/free.d "$age_days"
  plant_dir protected/audit-loop/fix/merged.d "$age_days"
  touch -t "$(stamp "$age_days")" "$LOCAL/protected/audit-loop/fix/held.json" "$LOCAL/protected/audit-loop/fix/free.json" "$LOCAL/protected/audit-loop/fix/merged.json"
  run_reaper
  [ "$status" -eq 0 ]
  present protected/audit-loop/fix/held.json
  present protected/audit-loop/fix/held.d
  absent protected/audit-loop/fix/free.json
  absent protected/audit-loop/fix/free.d
  absent protected/audit-loop/fix/merged.json
  absent protected/audit-loop/fix/merged.d
}

# bats test_tags=whole-tree
@test "a failed worktree list removes no keyed entry but still removes an over-window age-classed one" {
  make_fixture
  plant_git_failure_fixture
  install_failing_git "worktree list"
  run_reaper_with_failing_git
  [ "$status" -eq 0 ]
  assert_each present "$BRANCH_ENTRIES"
  present "$GONE_TREE_ENTRY"
  absent "$AGED_ENTRY"
}

# bats test_tags=whole-tree
@test "a failed branch ref read removes no keyed entry but still removes an over-window age-classed one" {
  make_fixture
  plant_git_failure_fixture
  install_failing_git "for-each-ref"
  run_reaper_with_failing_git
  [ "$status" -eq 0 ]
  assert_each present "$BRANCH_ENTRIES"
  present "$GONE_TREE_ENTRY"
  absent "$AGED_ENTRY"
}

# bats test_tags=whole-tree
@test "a malformed registry removes nothing and still exits 0" {
  make_fixture
  plant_git_failure_fixture
  printf 'this is { not json' >"$MAIN/.gaia/state-registry.json"
  run_reaper
  [ "$status" -eq 0 ]
  assert_each present "$BRANCH_ENTRIES"
  present "$GONE_TREE_ENTRY"
  present "$AGED_ENTRY"
  jq -e '(.skipped | length) > 0' "$LOCAL/cache/state-reaper/last-run.json" >/dev/null
}

# bats test_tags=whole-tree
@test "durable and owned state and unregistered entries stay byte-identical at any age" {
  make_fixture
  make_catalog '{"version":1,"items":[]}'
  local entry before after
  local -a untouched=(
    settings.json
    telemetry/usage.jsonl
    telemetry/links.jsonl
    kept-worktrees.tsv
    ports/sessions/session-one
    cache/research/x
    archive/x
  )
  for entry in "${untouched[@]}"; do plant_file "$entry" 400; done
  touch -t "$(stamp 400)" "$MAIN/.notebook/catalog.json"
  plant_file cache/doctrine-injected.sess 400
  before="$(cd "$LOCAL" && cksum "${untouched[@]}" ../../.notebook/catalog.json)"
  run_reaper
  [ "$status" -eq 0 ]
  after="$(cd "$LOCAL" && cksum "${untouched[@]}" ../../.notebook/catalog.json)"
  [ "$before" = "$after" ]
  absent cache/doctrine-injected.sess
}

# bats test_tags=whole-tree
@test "a registry whose rows carry the old reaped_by field and no retention removes nothing" {
  make_fixture
  jq '.entries |= map(del(.retention) | .reaped_by = "legacy prose")' "$REAL_REGISTRY" >"$MAIN/.gaia/state-registry.json"
  [ "$(jq '[.entries[] | select(has("retention"))] | length' "$MAIN/.gaia/state-registry.json")" -eq 0 ]
  plant_git_failure_fixture
  run_reaper
  [ "$status" -eq 0 ]
  assert_each present "$BRANCH_ENTRIES"
  present "$GONE_TREE_ENTRY"
  present "$AGED_ENTRY"
}

# bats test_tags=whole-tree
@test "sweeps remove old marker files and their temp files and leave directories and symlinks" {
  make_fixture
  local context_days checkpoint_days
  context_days=$(($(window context-readings) + 1))
  checkpoint_days=$(($(window context-checkpoint-markers) + 1))
  printf 'sentinel\n' >"$BATS_TEST_TMPDIR/elsewhere"
  plant_file cache/shared/context/x.json "$context_days"
  plant_file cache/shared/context/x.json.tmp.123 "$context_days"
  plant_file cache/shared/context/notes.txt "$context_days"
  plant_dir cache/shared/context/subdirectory "$context_days"
  plant_link cache/shared/context/link.json "$BATS_TEST_TMPDIR/elsewhere" "$context_days"
  plant_file cache/context-checkpoint/session-id "$checkpoint_days"
  plant_file cache/context-checkpoint/.session-id.4242 "$checkpoint_days"
  plant_dir cache/context-checkpoint/subdirectory "$checkpoint_days"
  plant_link cache/context-checkpoint/link "$BATS_TEST_TMPDIR/elsewhere" "$checkpoint_days"
  plant_file cache/context-checkpoint-agents/session-id.agent "$checkpoint_days"
  plant_file cache/context-checkpoint-agents/.session-id.agent.4242 "$checkpoint_days"
  plant_dir cache/context-checkpoint-agents/subdirectory "$checkpoint_days"
  plant_link cache/context-checkpoint-agents/link "$BATS_TEST_TMPDIR/elsewhere" "$checkpoint_days"
  run_reaper
  [ "$status" -eq 0 ]
  absent cache/shared/context/x.json
  absent cache/shared/context/x.json.tmp.123
  absent cache/context-checkpoint/session-id
  absent cache/context-checkpoint/.session-id.4242
  absent cache/context-checkpoint-agents/session-id.agent
  absent cache/context-checkpoint-agents/.session-id.agent.4242
  present cache/shared/context/notes.txt
  present cache/shared/context/subdirectory
  present cache/shared/context/link.json
  present cache/context-checkpoint/subdirectory
  present cache/context-checkpoint/link
  present cache/context-checkpoint-agents/subdirectory
  present cache/context-checkpoint-agents/link
  [ "$(cat "$BATS_TEST_TMPDIR/elsewhere")" = sentinel ]
}

# bats test_tags=whole-tree
@test "a symlink under an age-classed directory is unlinked at most and its target survives" {
  make_fixture
  local age_days
  age_days=$(($(window audit-mutation-scratch) + 1))
  printf 'sentinel\n' >"$BATS_TEST_TMPDIR/outside-file"
  mkdir -p "$LOCAL/protected/audit-loop"
  printf '{"pr":null}\n' >"$LOCAL/protected/audit-loop/target-state.json"
  before="$(cksum "$LOCAL/protected/audit-loop/target-state.json" "$BATS_TEST_TMPDIR/outside-file")"
  plant_link cache/mutation-scratch/into-protected "$LOCAL/protected/audit-loop" "$age_days"
  plant_link cache/mutation-scratch/outside "$BATS_TEST_TMPDIR/outside-file" "$age_days"
  plant_dir cache/mutation-scratch/real-old "$age_days"
  run_reaper
  [ "$status" -eq 0 ]
  absent cache/mutation-scratch/real-old
  after="$(cksum "$LOCAL/protected/audit-loop/target-state.json" "$BATS_TEST_TMPDIR/outside-file")"
  [ "$before" = "$after" ]
  [ -d "$LOCAL/protected/audit-loop" ]
}

# bats test_tags=whole-tree
@test "a held fresh run lock stops a second run, and the run log counts what a run removed" {
  make_fixture
  local marker_days context_days
  marker_days=$(($(window doctrine-injected-marker) + 1))
  context_days=$(($(window context-readings) + 1))
  plant_file cache/doctrine-injected.one "$marker_days"
  mkdir -p "$LOCAL/cache/state-reaper/run.lock.d"
  run_reaper
  [ "$status" -eq 0 ]
  present cache/doctrine-injected.one
  absent cache/state-reaper/last-run.json
  rmdir "$LOCAL/cache/state-reaper/run.lock.d"
  plant_file cache/doctrine-injected.two "$marker_days"
  plant_file cache/shared/context/old.json "$context_days"
  plant_file cache/shared/context/new.json 1
  run_reaper
  [ "$status" -eq 0 ]
  absent cache/doctrine-injected.one
  absent cache/doctrine-injected.two
  absent cache/shared/context/old.json
  present cache/shared/context/new.json
  [ ! -e "$LOCAL/cache/state-reaper/run.lock.d" ]
  jq -e '.schema == 1 and (.started_at | type) == "string" and (.finished_at | type) == "string" and (.skipped | type) == "array"
    and .removed["doctrine-injected-marker"] == 2 and .removed["context-readings"] == 1 and ([.removed[]] | add) == 3' \
    "$LOCAL/cache/state-reaper/last-run.json" >/dev/null
}

# bats test_tags=whole-tree
@test "a run lock older than the stale window is reclaimed" {
  make_fixture
  local marker_days
  marker_days=$(($(window doctrine-injected-marker) + 1))
  plant_file cache/doctrine-injected.one "$marker_days"
  mkdir -p "$LOCAL/cache/state-reaper/run.lock.d"
  touch -t "$(stamp 1)" "$LOCAL/cache/state-reaper/run.lock.d"
  run_reaper
  [ "$status" -eq 0 ]
  absent cache/doctrine-injected.one
  [ ! -e "$LOCAL/cache/state-reaper/run.lock.d" ]
}

# bats test_tags=whole-tree
@test "an argument ends the run with usage and removes nothing" {
  make_fixture
  plant_file cache/doctrine-injected.one $(($(window doctrine-injected-marker) + 1))
  run bash "$MAIN/.gaia/scripts/state-reaper.sh" --anything </dev/null
  [ "$status" -eq 0 ]
  present cache/doctrine-injected.one
  absent cache/state-reaper
  grep -qi 'usage' <<<"$output"
}
