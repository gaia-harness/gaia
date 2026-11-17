#!/usr/bin/env bats
# Plan-document replacement applier: the apply-on-one-match rule and the
# fix-up route for items it cannot apply.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  CLI="$REPO_ROOT/.gaia/scripts/test-design/doc-replace.mjs"
  PLAN="$BATS_TEST_TMPDIR/plan"
  ITEMS="$BATS_TEST_TMPDIR/items.json"
  mkdir -p "$PLAN"
  printf 'one foo line\ntwo twin\nthree twin\nfour\n' >"$PLAN/task-alpha.md"
}

@test "a replacement applies only on exactly one match at apply time in the stated order" {
  # Listed out of order on purpose: F-1 runs before F-2, so F-2's old text
  # exists only once F-1 has written it.
  cat >"$ITEMS" <<'JSON'
[
  {"finding": "F-2", "index": 0, "file": "task-alpha.md", "old": "one bar line", "new": "one baz line"},
  {"finding": "F-1", "index": 0, "file": "task-alpha.md", "old": "one foo line", "new": "one bar line"},
  {"finding": "F-3", "index": 0, "file": "task-alpha.md", "old": "twin", "new": "triplet"},
  {"finding": "F-4", "index": 0, "file": "task-alpha.md", "old": "no such text", "new": "x"}
]
JSON
  run node "$CLI" --plan-dir "$PLAN" --items "$ITEMS"
  [ "$status" -eq 0 ] || return 1
  grep -qF '"applied":[{"finding":"F-1","index":0},{"finding":"F-2","index":0}]' <<<"$output" || return 1
  grep -qF '{"finding":"F-3","index":0,"reason":"old text matched 2 times, not exactly once"}' <<<"$output" || return 1
  grep -qF '{"finding":"F-4","index":0,"reason":"old text matched 0 times, not exactly once"}' <<<"$output" || return 1
  grep -qF '"refused":[]' <<<"$output" || return 1
  [ "$(cat "$PLAN/task-alpha.md")" = "$(printf 'one baz line\ntwo twin\nthree twin\nfour')" ] || return 1

  # Dry run reports the same result and writes nothing.
  printf 'one foo line\ntwo twin\nthree twin\nfour\n' >"$PLAN/task-alpha.md"
  cp "$PLAN/task-alpha.md" "$BATS_TEST_TMPDIR/before.md"
  run node "$CLI" --plan-dir "$PLAN" --items "$ITEMS" --dry-run
  [ "$status" -eq 0 ] || return 1
  grep -qF '"applied":[{"finding":"F-1","index":0},{"finding":"F-2","index":0}]' <<<"$output" || return 1
  cmp -s "$PLAN/task-alpha.md" "$BATS_TEST_TMPDIR/before.md" || return 1
  [ "$(ls -A "$PLAN")" = "task-alpha.md" ] || return 1
}

@test "a malformed replacement goes to the fix-up list" {
  cp "$PLAN/task-alpha.md" "$BATS_TEST_TMPDIR/before.md"
  cat >"$ITEMS" <<'JSON'
[
  {"finding": "M-1", "index": 0, "file": "task-alpha.md", "new": "x"},
  {"finding": "M-2", "index": 0, "file": "task-alpha.md", "old": "four"},
  {"finding": "M-3", "index": 0, "old": "four", "new": "x"},
  {"finding": "M-4", "index": 0, "file": "task-gone.md", "old": "four", "new": "x"},
  {"finding": "M-5", "index": 0, "file": "task-alpha.md", "old": "", "new": "x"}
]
JSON
  run node "$CLI" --plan-dir "$PLAN" --items "$ITEMS"
  [ "$status" -eq 0 ] || return 1
  grep -qF '"applied":[]' <<<"$output" || return 1
  grep -qF '"refused":[]' <<<"$output" || return 1
  for finding in M-1 M-2 M-3 M-4 M-5; do
    grep -qF "{\"finding\":\"$finding\",\"index\":0,\"reason\":" <<<"$output" || return 1
  done
  cmp -s "$PLAN/task-alpha.md" "$BATS_TEST_TMPDIR/before.md" || return 1
}

@test "a replacement aimed outside the task docs and phase plan is refused" {
  mkdir -p "$PLAN/audit"
  printf 'secret outside text\n' >"$BATS_TEST_TMPDIR/outside.md"
  printf 'linked target text\n' >"$BATS_TEST_TMPDIR/linked.md"
  ln -s "$BATS_TEST_TMPDIR/linked.md" "$PLAN/task-link.md"
  printf '{"gate": "closed"}\n' >"$PLAN/tests.json"
  printf 'kickoff text\n' >"$PLAN/KICKOFF.md"
  printf '{"td": "audit text"}\n' >"$PLAN/audit/TD.json"
  printf '# Plan\n\n## Phase 1\n\nphase text\n\n## Test design\n\ndesign row text\n- Security writer: sec-writer\n\n## Follow-ups\n\nfollow text\n' >"$PLAN/README.md"

  local snapshot="$BATS_TEST_TMPDIR/snapshot"
  mkdir -p "$snapshot"
  cp -R "$PLAN/." "$snapshot/plan"
  cp "$BATS_TEST_TMPDIR/outside.md" "$snapshot/outside.md"
  cp "$BATS_TEST_TMPDIR/linked.md" "$snapshot/linked.md"

  cat >"$ITEMS" <<'JSON'
[
  {"finding": "R-1", "index": 0, "file": "../outside.md", "old": "secret outside text", "new": "x"},
  {"finding": "R-2", "index": 0, "file": "../nowhere/task-gone.md", "old": "anything", "new": "x"},
  {"finding": "R-3", "index": 0, "file": "task-link.md", "old": "linked target text", "new": "x"},
  {"finding": "R-4", "index": 0, "file": "tests.json", "old": "closed", "new": "open"},
  {"finding": "R-5", "index": 0, "file": "KICKOFF.md", "old": "kickoff text", "new": "x"},
  {"finding": "R-6", "index": 0, "file": "audit/TD.json", "old": "audit text", "new": "x"},
  {"finding": "R-7", "index": 0, "file": "README.md", "old": "design row text", "new": "x"},
  {"finding": "R-8", "index": 0, "file": "README.md", "old": "- Security writer: sec-writer", "new": "- Security writer: none"}
]
JSON
  run node "$CLI" --plan-dir "$PLAN" --items "$ITEMS"
  [ "$status" -eq 1 ] || return 1
  grep -qF '"applied":[]' <<<"$output" || return 1
  grep -qF '"fixup":[]' <<<"$output" || return 1
  for finding in R-1 R-2 R-3 R-4 R-5 R-6 R-7 R-8; do
    grep -qF "{\"finding\":\"$finding\",\"index\":0,\"reason\":" <<<"$output" || return 1
  done

  diff -r "$snapshot/plan" "$PLAN" || return 1
  cmp -s "$snapshot/outside.md" "$BATS_TEST_TMPDIR/outside.md" || return 1
  cmp -s "$snapshot/linked.md" "$BATS_TEST_TMPDIR/linked.md" || return 1
  [ -L "$PLAN/task-link.md" ] || return 1
  [ ! -e "$BATS_TEST_TMPDIR/nowhere" ] || return 1
}
