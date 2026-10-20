#!/usr/bin/env bats
#
# The retention reaper's library: row validation, forward matching of branch
# keys, entry age, classification, per-class reaping and safe removal.
#
# Every case builds its own main checkout under $BATS_TEST_TMPDIR with a
# fixture registry, so nothing here reads the committed registry or reaches
# the real .gaia/local. Every removal case pairs a survivor with a reaped
# entry in the same run, so a survivor proves the rule rather than a reaper
# that deletes nothing.
#
# Run under bash 5: `.gaia/scripts/bats5.sh .gaia/scripts/tests/state-reaper-lib.bats`.
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

bats_require_minimum_version 1.5.0

FIXTURE_REGISTRY='{
  "entries": [
    {"id": "context", "path": "cache/shared/context/", "match": "prefix", "kind": "dir",
     "retention": {"class": "age", "days": 7, "types": ["file"], "names": ["*.json", "*.json.tmp.*"]}},
    {"id": "shared", "path": "cache/shared/", "match": "prefix", "kind": "dir", "retention": {"class": "age", "days": 7}},
    {"id": "settings", "path": "settings.json", "match": "exact", "kind": "file", "retention": {"class": "keep"}},
    {"id": "ports", "path": "ports/", "match": "prefix", "kind": "dir", "retention": {"class": "owned", "owner": "the ports reaper"}},
    {"id": "renders", "path": "cache/*/renders.json", "match": "glob", "kind": "file", "retention": {"class": "age", "days": 7}},
    {"id": "findings", "path": "audit/*.findings.json", "match": "glob", "kind": "file",
     "retention": {"class": "branch-spent", "key": "slug-dot-field", "days": 7}},
    {"id": "pr-cache", "path": "cache/gh-artifact-pr.*.json", "match": "glob", "kind": "file",
     "retention": {"class": "branch-spent", "key": "slug-glob", "days": 7}},
    {"id": "red", "path": "red-ledger/", "match": "prefix", "kind": "dir", "retention": {"class": "tree-gone"}},
    {"id": "spec-scratch", "path": "cache/draft-*.md|cache/draft.md", "match": "glob", "kind": "file",
     "retention": {"class": "spec-finalized", "days": 30}},
    {"id": "audit-loop", "path": "protected/audit-loop/", "match": "prefix", "kind": "dir",
     "retention": {"class": "branch-spent", "key": "audit-loop", "days": 7}},
    {"id": "verify-pass", "path": "protected/verify-pass/", "match": "prefix", "kind": "dir",
     "retention": {"class": "branch-spent", "key": "normalized-file", "days": 7}},
    {"id": "runs", "path": "runs/", "match": "prefix", "kind": "dir",
     "retention": {"class": "branch-spent", "key": "normalized-path", "days": 7, "session_days": 30}},
    {"id": "scratch", "path": "scratch/", "match": "prefix", "kind": "dir", "retention": {"class": "age", "days": 7}}
  ],
  "residue": [
    {"id": "dead-flag", "path": "cache/shared/dead.txt", "match": "exact", "why": "retired flag"}
  ],
  "report_only": [
    {"match": "prefix", "path": "scratch/old-root/"}
  ]
}'

setup() {
  SCRIPT_DIRECTORY="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
  # shellcheck source=/dev/null
  . "$SCRIPT_DIRECTORY/state-reaper-classes.sh"
  REAL_GIT="$(command -v git)"
  REAL_RM="$(command -v rm)"
  WRAPPER_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$WRAPPER_BIN"
}

teardown() {
  [ -n "${GHOST_DIRECTORY:-}" ] && chmod -R u+w "$GHOST_DIRECTORY" 2>/dev/null
  true
}

# make_main [<parent>]: a main checkout with one commit and the fixture
# registry, loaded. Sets MAIN, LOCAL and REGISTRY.
make_main() {
  local parent="${1:-$BATS_TEST_TMPDIR}"
  MAIN="$parent/main"
  "$REAL_GIT" init -q -b trunk "$MAIN"
  "$REAL_GIT" -C "$MAIN" -c user.name=fixture -c user.email=fixture@example.com commit -q --allow-empty -m init
  LOCAL="$MAIN/.gaia/local"
  mkdir -p "$LOCAL"
  REGISTRY="$MAIN/.gaia/state-registry.json"
  printf '%s\n' "$FIXTURE_REGISTRY" >"$REGISTRY"
  gaia_reaper_load_registry "$REGISTRY"
}

branch() { "$REAL_GIT" -C "$MAIN" branch "$1"; }

# stamp <days> [<minutes>]: a `touch -t` stamp that many days (plus an hour,
# so whole-day comparisons are not on the boundary) or minutes ago.
stamp() {
  local epoch
  if [ -n "${2:-}" ]; then epoch=$(($(date +%s) - $2 * 60)); else epoch=$(($(date +%s) - $1 * 86400 - 3600)); fi
  date -r "$epoch" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$epoch" +%Y%m%d%H%M.%S
}

# put <relative> [<days>]: a file under .gaia/local, aged.
put() {
  mkdir -p "$(dirname "$LOCAL/$1")"
  printf 'content of %s\n' "$1" >"$LOCAL/$1"
  [ -z "${2:-}" ] || touch -t "$(stamp "$2")" "$LOCAL/$1"
}

# age <relative> <days>: the path and everything under it, links included.
age() {
  local value
  value="$(stamp "$2")"
  find -P "$LOCAL/$1" -exec touch -h -t "$value" {} +
}

row() { jq -c --arg id "$1" '.entries[] | select(.id == $id)' "$REGISTRY"; }

snap() { gaia_reaper_snapshot "$MAIN"; }

reap() { REAP_OUTPUT="$(gaia_reaper_reap_row "$MAIN" "$(row "$1")")"; }

present() {
  [ -e "$LOCAL/$1" ] || [ -L "$LOCAL/$1" ] || {
    printf 'expected present: %s\n' "$1"
    return 1
  }
}

absent() {
  if [ -e "$LOCAL/$1" ] || [ -L "$LOCAL/$1" ]; then
    printf 'expected removed: %s\n' "$1"
    return 1
  fi
}

# fail_git <subcommand words>: put a git on PATH that fails that read.
fail_git() {
  cat >"$WRAPPER_BIN/git" <<EOF
#!/usr/bin/env bash
case " \$* " in *" $1 "*) exit 1 ;; esac
exec "$REAL_GIT" "\$@"
EOF
  chmod +x "$WRAPPER_BIN/git"
  PATH="$WRAPPER_BIN:$PATH"
}

@test "row check accepts one valid row per class and names each problem" {
  local valid
  for valid in \
    '{"path":"runs/","retention":{"class":"branch-spent","key":"normalized-path","days":7,"session_days":30}}' \
    '{"path":"red-ledger/","retention":{"class":"tree-gone"}}' \
    '{"path":"cache/draft-*.md","retention":{"class":"spec-finalized","days":30}}' \
    '{"path":"cache/x/","retention":{"class":"age","days":7,"types":["file"],"names":["*.json"]}}' \
    '{"path":"ports/","retention":{"class":"owned","owner":"the ports reaper"}}' \
    '{"path":"settings.json","retention":{"class":"keep"}}' \
    '{"path":"protected/audit-loop/","retention":{"class":"branch-spent","key":"audit-loop","days":7}}' \
    '{"path":"protected/x","retention":{"class":"keep"}}'; do
    run gaia_reaper_row_check "$valid"
    [ "$status" -eq 0 ] || { printf 'rejected: %s\n%s\n' "$valid" "$output"; return 1; }
  done

  check_rejects() {
    run gaia_reaper_row_check "$1"
    [ "$status" -eq 1 ] || { printf 'accepted: %s\n' "$1"; return 1; }
    case "$output" in *"$2"*) ;; *) printf 'reason for %s was: %s\n' "$1" "$output"; return 1 ;; esac
  }
  check_rejects '{"path":"a/"}' 'missing retention'
  check_rejects '{"path":"a/","retention":{"class":"forever"}}' 'unknown class'
  check_rejects '{"path":"a/","retention":{"class":"keep","window":3}}' 'unknown retention field window'
  check_rejects '{"path":"a/","retention":{"class":"branch-spent","key":"by-guess","days":7}}' 'unknown key'
  check_rejects '{"path":"a/","retention":{"class":"branch-spent","key":"slug-glob"}}' 'needs days'
  check_rejects '{"path":"a/","retention":{"class":"age","days":0}}' 'positive integer'
  check_rejects '{"path":"a/","retention":{"class":"age","days":1.5}}' 'positive integer'
  check_rejects '{"path":"a/","retention":{"class":"owned"}}' 'owner'
  check_rejects '{"path":"a/","retention":{"class":"age","days":7,"key":"slug-glob"}}' 'key is only allowed'
  check_rejects '{"path":"a/","retention":{"class":"branch-spent","key":"slug-glob","days":7,"session_days":30}}' 'session_days'
  check_rejects '{"path":"a/","retention":{"class":"age","days":7,"types":["file","link"]}}' 'types'
  check_rejects '{"path":"a/","reaped_by":"some prose"}' 'legacy reaped_by'
  check_rejects '{"path":"protected/x/","retention":{"class":"age","days":7}}' 'protected/'
  check_rejects '{"path":"protected/x/","retention":{"class":"branch-spent","key":"normalized-path","days":8}}' 'protected/'
}

@test "forward matching keeps a live worktree branch's nested key and reaps keys no live branch maps to" {
  make_main
  branch 'worktree-a+b'
  snap
  run gaia_reaper_live_keys normalize
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qx 'a/b'
  put runs/a/b/STATE.md
  put runs/c/STATE.md
  age runs/a 8
  age runs/c 8
  reap runs
  present runs/a/b/STATE.md
  absent runs/c
}

@test "a spent key is reaped beside live siblings that share its prefix, under nesting and slug keys" {
  make_main
  branch fix/a-b
  branch fix/b
  snap
  put runs/fix/a/STATE.md
  put runs/fix/a-b/STATE.md
  put runs/fix/b/STATE.md
  age runs 8
  put audit/0123abcd.fix%2Fa.m.findings.json 8
  put audit/0123abcd.fix%2Fa-b.m.findings.json 8
  reap runs
  absent runs/fix/a
  present runs/fix/a-b/STATE.md
  present runs/fix/b/STATE.md
  reap findings
  absent audit/0123abcd.fix%2Fa.m.findings.json
  present audit/0123abcd.fix%2Fa-b.m.findings.json
}

@test "path liveness is segment-aware: ancestor, inside and equal are live, a dash sibling is not" {
  gaia_reaper_path_live fix 'fix/a'
  gaia_reaper_path_live fix/a/x 'fix/a'
  gaia_reaper_path_live fix/a 'fix/a'
  gaia_reaper_path_live fix-a 'fix/a' && return 1
  gaia_reaper_path_live fix/ab 'fix/a' && return 1
  true
}

@test "a candidate's age is its newest descendant's mtime" {
  make_main
  snap
  put runs/fresh/sub/deeper/file.txt
  put runs/stale/sub/deeper/file.txt
  age runs 8
  touch -t "$(stamp 1)" "$LOCAL/runs/fresh/sub/deeper/file.txt"
  run gaia_reaper_entry_older_than "$LOCAL/runs/fresh" 7
  [ "$status" -eq 1 ]
  run gaia_reaper_entry_older_than "$LOCAL/runs/stale" 7
  [ "$status" -eq 0 ]
  reap runs
  present runs/fresh/sub/deeper/file.txt
  absent runs/stale
}

@test "a top-level session folder uses the row's session window" {
  make_main
  snap
  put runs/session-young/resume.md
  put runs/session-old/resume.md
  put runs/plain/STATE.md
  age runs/session-young 29
  age runs/session-old 31
  age runs/plain 8
  reap runs
  present runs/session-young/resume.md
  absent runs/session-old
  absent runs/plain
}

@test "audit-loop state: the merge guard, the plain spent rule, closed entries and emptied parents" {
  make_main
  branch fix/x
  mkdir -p "$LOCAL/telemetry"
  printf '%s\n' '{"kind":"merge","pr":12}' 'not json' '{"kind":"edge","pr":13}' >"$LOCAL/telemetry/links.jsonl"
  snap
  local directory=protected/audit-loop
  printf '{"pr":12}\n' >"$BATS_TEST_TMPDIR/merged.json"
  put "$directory/fix/y.json"
  cp "$BATS_TEST_TMPDIR/merged.json" "$LOCAL/$directory/fix/y.json"
  put "$directory/fix/y.d/round-1.stamp"
  put "$directory/fix/open.json"
  printf '{"pr":13}\n' >"$LOCAL/$directory/fix/open.json"
  put "$directory/fix/open.d/round-1.stamp"
  put "$directory/fix/null.json"
  printf '{"pr":null}\n' >"$LOCAL/$directory/fix/null.json"
  put "$directory/fix/null.d/round-1.stamp"
  put "$directory/fix/absent.json"
  printf '{"schema":1}\n' >"$LOCAL/$directory/fix/absent.json"
  put "$directory/fix/x.json"
  printf '{"pr":null}\n' >"$LOCAL/$directory/fix/x.json"
  put "$directory/gone/only.json"
  printf '{"pr":null}\n' >"$LOCAL/$directory/gone/only.json"
  put "$directory/.closed/fix+y.12.20260101T000000Z.json"
  put "$directory/.closed/fix+y.12.20260101T000000Z.d/round-1.stamp"
  put "$directory/.closed/fix+x.12.20260101T000000Z.json"
  put "$directory/.closed/not-a-closed-name.json"
  age "$directory" 8
  reap audit-loop
  absent "$directory/fix/y.json"
  absent "$directory/fix/y.d"
  present "$directory/fix/open.json"
  present "$directory/fix/open.d/round-1.stamp"
  absent "$directory/fix/null.json"
  absent "$directory/fix/null.d"
  absent "$directory/fix/absent.json"
  present "$directory/fix/x.json"
  absent "$directory/gone"
  present "$directory/fix"
  absent "$directory/.closed/fix+y.12.20260101T000000Z.json"
  absent "$directory/.closed/fix+y.12.20260101T000000Z.d"
  present "$directory/.closed/fix+x.12.20260101T000000Z.json"
  present "$directory/.closed/not-a-closed-name.json"
}

@test "an audit-loop state file whose lock another writer holds is never deleted" {
  make_main
  snap
  local directory=protected/audit-loop
  put "$directory/fix/y.json"
  printf '{"pr":null}\n' >"$LOCAL/$directory/fix/y.json"
  put "$directory/fix/y.d/round-1.stamp"
  put "$directory/fix/z.json"
  printf '{"pr":null}\n' >"$LOCAL/$directory/fix/z.json"
  age "$directory" 8
  mkdir "$LOCAL/$directory/fix/y.json.lock"
  reap audit-loop
  present "$directory/fix/y.json"
  present "$directory/fix/y.d/round-1.stamp"
  present "$directory/fix/y.json.lock"
  absent "$directory/fix/z.json"
  printf '%s\n' "$REAP_OUTPUT" | grep -q "refused $directory/fix/y.json: its audit-loop lock is held"
}

@test "tree keys: listed trees survive from a symlinked root, removed and prunable trees are reaped" {
  mkdir -p "$BATS_TEST_TMPDIR/real"
  ln -s "$BATS_TEST_TMPDIR/real" "$BATS_TEST_TMPDIR/linked"
  make_main "$BATS_TEST_TMPDIR/linked"
  "$REAL_GIT" -C "$MAIN" worktree add -q "$BATS_TEST_TMPDIR/linked/kept" -b kept
  "$REAL_GIT" -C "$MAIN" worktree add -q "$BATS_TEST_TMPDIR/linked/removed" -b removed
  "$REAL_GIT" -C "$MAIN" worktree add -q "$BATS_TEST_TMPDIR/linked/pruned" -b pruned
  local main_key kept_key removed_key pruned_key
  main_key="$(cd "$MAIN" && gaia_tree_key)"
  kept_key="$(cd "$BATS_TEST_TMPDIR/linked/kept" && gaia_tree_key)"
  removed_key="$(gaia_tree_key "$BATS_TEST_TMPDIR/linked/removed")"
  pruned_key="$(gaia_tree_key "$BATS_TEST_TMPDIR/linked/pruned")"
  "$REAL_GIT" -C "$MAIN" worktree remove "$BATS_TEST_TMPDIR/linked/removed"
  rm -rf "$BATS_TEST_TMPDIR/linked/pruned"
  put "red-ledger/$main_key/observations.jsonl"
  put "red-ledger/$kept_key/observations.jsonl"
  put "red-ledger/$removed_key/observations.jsonl"
  put "red-ledger/$pruned_key/observations.jsonl"
  snap
  reap red
  present "red-ledger/$main_key/observations.jsonl"
  present "red-ledger/$kept_key/observations.jsonl"
  absent "red-ledger/$removed_key"
  absent "red-ledger/$pruned_key"
}

@test "a listed worktree path that cannot be keyed disables the tree-gone pass" {
  make_main
  "$REAL_GIT" -C "$MAIN" worktree add -q "$BATS_TEST_TMPDIR/listed" -b listed
  GHOST_DIRECTORY="$BATS_TEST_TMPDIR/ghost"
  mkdir -p "$GHOST_DIRECTORY"
  printf 'gitdir: %s/nowhere\n' "$BATS_TEST_TMPDIR" >"$GHOST_DIRECTORY/.git"
  printf '%s/.git\n' "$GHOST_DIRECTORY" >"$MAIN/.git/worktrees/listed/gitdir"
  run "$REAL_GIT" -C "$MAIN" worktree list --porcelain
  printf '%s\n' "$output" | grep -q "prunable" && return 1
  put red-ledger/0000000000000000/observations.jsonl
  snap
  [ -z "$GAIA_REAPER_TREES_OK" ]
  printf '%s\n' "$GAIA_REAPER_SKIPPED" | grep -q 'tree-gone: cannot key the listed worktree'
  reap red
  present red-ledger/0000000000000000/observations.jsonl
  printf '%s\n' "$REAP_OUTPUT" | grep -q '^skipped red:'
}

@test "spec scratch follows its catalog row, falls back to age without one, and an unreadable catalog reaps none" {
  make_main
  mkdir -p "$MAIN/.notebook"
  printf '%s\n' '{"version":1,"items":[{"kind":"spec","id":"alpha","status":"draft"},{"kind":"spec","id":"beta","status":"ready"},{"kind":"spec","id":"gamma","status":"merged"},{"kind":"plan","id":"delta","status":"ready"}]}' >"$MAIN/.notebook/catalog.json"
  put cache/draft-alpha.md 30
  put cache/draft-beta.md 30
  put cache/draft-gamma.md 30
  put cache/draft-delta.md 31
  put cache/draft-epsilon.md 29
  put cache/draft.md 31
  snap
  reap spec-scratch
  present cache/draft-alpha.md
  absent cache/draft-beta.md
  absent cache/draft-gamma.md
  absent cache/draft-delta.md
  present cache/draft-epsilon.md
  absent cache/draft.md
}

@test "an unparseable or absent catalog reaps no spec scratch while an age row still reaps" {
  make_main
  mkdir -p "$MAIN/.notebook"
  local catalog_state
  for catalog_state in unparseable absent; do
    if [ "$catalog_state" = unparseable ]; then
      printf '{"version":1,"items": [\n' >"$MAIN/.notebook/catalog.json"
    else
      rm -f "$MAIN/.notebook/catalog.json"
    fi
    put cache/draft.md 40
    put cache/draft-beta.md 40
    put scratch/old.txt 8
    snap
    [ -z "$GAIA_REAPER_CATALOG_OK" ]
    printf '%s\n' "$GAIA_REAPER_SKIPPED" | grep -q '^spec-finalized:'
    reap spec-scratch
    printf '%s\n' "$REAP_OUTPUT" | grep -q '^skipped spec-scratch:'
    reap scratch
    present cache/draft.md
    present cache/draft-beta.md
    absent scratch/old.txt
  done
}

@test "a failed worktree-list read disables branch-spent and tree-gone; an age row still reaps" {
  make_main
  put runs/gone/STATE.md 8
  age runs 8
  put red-ledger/0000000000000000/observations.jsonl
  put audit/0123abcd.gone.m.findings.json 8
  put scratch/old.txt 8
  fail_git 'worktree list'
  run gaia_reaper_snapshot "$MAIN"
  [ "$status" -eq 0 ]
  snap
  run gaia_reaper_live_keys normalize
  [ "$status" -eq 1 ]
  run gaia_reaper_reap_row "$MAIN" "$(row runs)"
  [ "$status" -eq 0 ]
  reap runs
  reap red
  reap findings
  reap scratch
  present runs/gone/STATE.md
  present red-ledger/0000000000000000/observations.jsonl
  present audit/0123abcd.gone.m.findings.json
  absent scratch/old.txt
}

@test "a failed ref read disables branch-spent; an age row still reaps" {
  make_main
  put runs/gone/STATE.md 8
  age runs 8
  put audit/0123abcd.gone.m.findings.json 8
  put scratch/old.txt 8
  fail_git 'for-each-ref'
  run gaia_reaper_snapshot "$MAIN"
  [ "$status" -eq 0 ]
  snap
  run gaia_reaper_live_keys normalize
  [ "$status" -eq 1 ]
  run gaia_reaper_reap_row "$MAIN" "$(row runs)"
  [ "$status" -eq 0 ]
  reap runs
  reap findings
  reap scratch
  present runs/gone/STATE.md
  present audit/0123abcd.gone.m.findings.json
  absent scratch/old.txt
}

@test "a candidate is reaped only by the row its path classifies to" {
  make_main
  snap
  put cache/shared/context/x.json 8
  put cache/shared/dead.txt 8
  put cache/shared/old.bin 8
  age cache/shared 8
  put scratch/old-root/kept.txt 8
  put scratch/loose.txt 8
  age scratch 8
  mkdir -p "$LOCAL/cache/directory/renders.json"
  put cache/file/renders.json 8
  age cache/directory 8
  reap shared
  present cache/shared/context/x.json
  present cache/shared/dead.txt
  absent cache/shared/old.bin
  reap scratch
  present scratch/old-root/kept.txt
  absent scratch/loose.txt
  reap renders
  present cache/directory/renders.json
  absent cache/file/renders.json
  [ "$(gaia_reaper_classify cache/directory/renders.json dir)" = unknown ]
  [ "$(gaia_reaper_classify cache/shared/dead.txt file)" = residue ]
  [ "$(gaia_reaper_classify scratch/old-root dir)" = report-only ]
  [ "$(gaia_reaper_classify cache/shared/context/x.json file)" = context ]
}

@test "an age row's types and names filters leave other shapes alone" {
  make_main
  snap
  put cache/shared/context/x.json
  put cache/shared/context/x.json.tmp.123
  put cache/shared/context/x.txt
  put cache/shared/context/subdirectory/inner.json
  ln -s x.txt "$LOCAL/cache/shared/context/link.json"
  age cache/shared/context 8
  reap context
  absent cache/shared/context/x.json
  absent cache/shared/context/x.json.tmp.123
  present cache/shared/context/x.txt
  present cache/shared/context/subdirectory/inner.json
  present cache/shared/context/link.json
}

@test "safe removal unlinks symlinks without touching their targets and refuses unsafe paths" {
  make_main
  snap
  put protected/thing.txt
  printf 'sentinel\n' >"$BATS_TEST_TMPDIR/sentinel"
  mkdir -p "$LOCAL/scratch" "$BATS_TEST_TMPDIR/outside-directory"
  ln -s ../protected/thing.txt "$LOCAL/scratch/to-protected"
  ln -s "$BATS_TEST_TMPDIR/sentinel" "$LOCAL/scratch/to-outside"
  touch -h -t "$(stamp 8)" "$LOCAL/scratch/to-protected" "$LOCAL/scratch/to-outside"
  printf 'outside\n' >"$BATS_TEST_TMPDIR/outside-directory/file"
  ln -s "$BATS_TEST_TMPDIR/outside-directory" "$LOCAL/scratch/linked-directory"
  cat >"$WRAPPER_BIN/rm" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >>"$BATS_TEST_TMPDIR/rm-arguments"
exec "$REAL_RM" "\$@"
EOF
  chmod +x "$WRAPPER_BIN/rm"
  PATH="$WRAPPER_BIN:$PATH"
  reap scratch
  absent scratch/to-protected
  absent scratch/to-outside
  [ "$(cat "$LOCAL/protected/thing.txt")" = "content of protected/thing.txt" ]
  [ "$(cat "$BATS_TEST_TMPDIR/sentinel")" = sentinel ]
  run gaia_reaper_safe_remove "$LOCAL" "$(row scratch)" scratch/linked-directory/file 'scratch/../settings.json'
  printf '%s\n' "$output" | grep -q '^refused scratch/linked-directory/file:'
  printf '%s\n' "$output" | grep -q '^refused scratch/../settings.json:'
  [ "$(cat "$BATS_TEST_TMPDIR/outside-directory/file")" = outside ]
  local argument count=0
  while IFS= read -r argument; do
    case "$argument" in -f | -rf | --) continue ;; esac
    count=$((count + 1))
    case "$argument" in "$LOCAL"/?*) ;; *) printf 'rm received %s\n' "$argument"; return 1 ;; esac
  done <"$BATS_TEST_TMPDIR/rm-arguments"
  [ "$count" -ge 2 ]
}

@test "keep and owned rows are never touched" {
  make_main
  snap
  put settings.json 400
  put ports/slots.json 400
  reap settings
  [ -z "$REAP_OUTPUT" ]
  reap ports
  [ -z "$REAP_OUTPUT" ]
  present settings.json
  present ports/slots.json
}

@test "a normalized-file row reaps gone keys by age, ages out orphan temps and takes no lock" {
  make_main
  branch fix/x
  snap
  gaia_loop_lock() {
    printf 'lock taken\n' >>"$BATS_TEST_TMPDIR/lock-calls"
    return 1
  }
  put protected/verify-pass/fix/y.json 8
  put protected/verify-pass/fix/x.json 8
  put protected/verify-pass/fresh/y.json 2
  put protected/verify-pass/orphan/.verify-pass.AbC123 8
  put protected/verify-pass/young/.verify-pass.XyZ789 6
  put protected/verify-pass/gone/only.json 8
  age protected/verify-pass/gone 8
  reap verify-pass
  absent protected/verify-pass/fix/y.json
  present protected/verify-pass/fix/x.json
  present protected/verify-pass/fresh/y.json
  absent protected/verify-pass/orphan
  present protected/verify-pass/young/.verify-pass.XyZ789
  absent protected/verify-pass/gone
  [ ! -e "$BATS_TEST_TMPDIR/lock-calls" ]
}

@test "the entry key parser reads each key shape and rejects keyless names" {
  make_main
  [ "$(gaia_reaper_entry_key "$(row runs)" runs/fix/a)" = fix/a ]
  [ "$(gaia_reaper_entry_key "$(row verify-pass)" protected/verify-pass/fix/y.json)" = fix/y ]
  [ "$(gaia_reaper_entry_key "$(row audit-loop)" protected/audit-loop/fix/y.json)" = fix/y ]
  [ "$(gaia_reaper_entry_key "$(row audit-loop)" protected/audit-loop/fix/y.d)" = fix/y ]
  [ "$(gaia_reaper_entry_key "$(row audit-loop)" protected/audit-loop/.closed/fix+y.12.20260101T000000Z.json)" = fix/y ]
  [ "$(gaia_reaper_entry_key "$(row audit-loop)" protected/audit-loop/.closed/v1.2.none.20260101T000000Z.d)" = v1.2 ]
  [ "$(gaia_reaper_entry_key "$(row findings)" audit/0123abcd.fix%2Fa.m.findings.json)" = fix%2Fa ]
  [ "$(gaia_reaper_entry_key "$(row pr-cache)" cache/gh-artifact-pr.fix%2Fa.json)" = fix%2Fa ]
  run gaia_reaper_entry_key "$(row audit-loop)" protected/audit-loop/.closed/fix+y.json
  [ "$status" -eq 1 ]
  run gaia_reaper_entry_key "$(row audit-loop)" protected/audit-loop/.closed/fix+y.12.yesterday.json
  [ "$status" -eq 1 ]
  run gaia_reaper_entry_key "$(row verify-pass)" protected/verify-pass/fix/.verify-pass.AbC123
  [ "$status" -eq 1 ]
}

@test "reap_key removes a gone key's entries with no age check" {
  make_main
  branch fix/b
  put runs/fix/a/STATE.md
  put runs/fix/b/STATE.md
  put cache/gh-artifact-pr.fix%2Fa.json
  put cache/gh-artifact-pr.fix%2Fb.json
  touch -t "$(stamp 0 1)" "$LOCAL/runs/fix/a/STATE.md" "$LOCAL/cache/gh-artifact-pr.fix%2Fa.json"
  run gaia_reaper_reap_key "$MAIN" "$(row runs)" fix/a
  [ "$status" -eq 0 ]
  absent runs/fix/a
  present runs/fix/b/STATE.md
  run gaia_reaper_reap_key "$MAIN" "$(row pr-cache)" fix%2Fa
  absent cache/gh-artifact-pr.fix%2Fa.json
  present cache/gh-artifact-pr.fix%2Fb.json
}

@test "reap_key refuses a live key, a key holding a live key, and unreadable liveness" {
  make_main
  branch 'worktree-fix+a'
  branch fix/b
  put runs/fix/a/STATE.md
  put runs/fix/b/STATE.md
  put cache/gh-artifact-pr.gone.json
  run gaia_reaper_reap_key "$MAIN" "$(row runs)" fix/a
  printf '%s\n' "$output" | grep -q '^skipped runs: fix/a is live'
  run gaia_reaper_reap_key "$MAIN" "$(row runs)" fix
  printf '%s\n' "$output" | grep -q '^skipped runs: fix is live'
  present runs/fix/a/STATE.md
  present runs/fix/b/STATE.md
  local failing
  for failing in for-each-ref 'worktree list'; do
    fail_git "$failing"
    run gaia_reaper_reap_key "$MAIN" "$(row pr-cache)" gone
    printf '%s\n' "$output" | grep -q '^skipped pr-cache:'
    present cache/gh-artifact-pr.gone.json
  done
}

@test "safe removal checks a glob row's candidate against the row's own directory" {
  make_main
  put cache/file/renders.json
  put elsewhere/renders.json
  ln -s ../elsewhere "$LOCAL/cache/linked"
  run gaia_reaper_safe_remove "$LOCAL" "$(row renders)" cache/file/renders.json cache/linked/renders.json elsewhere/renders.json
  printf '%s\n' "$output" | grep -qx 'removed cache/file/renders.json'
  printf '%s\n' "$output" | grep -q '^refused cache/linked/renders.json:'
  printf '%s\n' "$output" | grep -q '^refused elsewhere/renders.json:'
  absent cache/file/renders.json
  present elsewhere/renders.json
}

@test "both libraries parse under bash 3.2 and the current bash, and shellcheck is clean" {
  local library
  for library in state-reaper-lib.sh state-reaper-classes.sh; do
    bash -n "$SCRIPT_DIRECTORY/$library"
    if [ -x /bin/bash ]; then /bin/bash -n "$SCRIPT_DIRECTORY/$library"; fi
  done
  command -v shellcheck >/dev/null 2>&1 || skip 'shellcheck is not installed'
  shellcheck "$SCRIPT_DIRECTORY/state-reaper-lib.sh" "$SCRIPT_DIRECTORY/state-reaper-classes.sh" "$BATS_TEST_FILENAME"
}
