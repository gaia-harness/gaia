#!/usr/bin/env bats
# Tests for .gaia/scripts/audit-light-mark.sh, the only writer of a light
# clearance. Every case runs in a light sandbox (a scratch repository carrying
# copies of this checkout's audit machinery). Each refusal is driven from a
# well-formed twin that clears, so a script that printed a constant would fail
# one side of every pair.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

bats_require_minimum_version 1.5.0

# The malformed-reply refusals share one sandbox per route kind (see
# setup_file). Under bats --jobs the cases of a file run in parallel, so they
# would mark against each other's reply mid-test. Keep this file's cases
# serial; other files still run in parallel.
# shellcheck disable=SC2034 # read by bats itself
BATS_NO_PARALLELIZE_WITHIN_FILE=true

setup_file() {
  command -v jq >/dev/null 2>&1 || skip "jq not available"
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  # shellcheck source=.gaia/scripts/tests/helpers/light-sandbox.sh
  . "$REPO_ROOT/.gaia/scripts/tests/helpers/light-sandbox.sh"
  lsb_build_templates plain maintainer
  local flavor
  for flavor in plain maintainer; do
    (
      BATS_TEST_TMPDIR="$LSB_TEMPLATE_ROOT/prepared-$flavor"
      mkdir -p "$BATS_TEST_TMPDIR"
      if [ "$flavor" = maintainer ]; then lsb_init --maintainer; else lsb_init; fi
      lsb_full_clearance code-audit-frontend
      lsb_commit apps/web/app/notes.md "$(printf 'one\ntwo\nthree')"
      routed="$(bash "$LSB_ROOT/.gaia/scripts/audit-light-route.sh" --root "$LSB_ROOT" --member code-audit-frontend)"
      [ "$routed" = "$(printf 'light\tlight-eligible')" ] || { printf 'template router: %s\n' "$routed" >&2; exit 1; }
      cp "$LSB_TEMPLATE_ROOT/$flavor/slug" "$BATS_TEST_TMPDIR/slug"
    ) || return 1
  done
  for flavor in plain maintainer; do
    (
      BATS_TEST_TMPDIR="$LSB_TEMPLATE_ROOT/prepared-quick-$flavor"
      mkdir -p "$BATS_TEST_TMPDIR"
      if [ "$flavor" = maintainer ]; then lsb_init --maintainer; else lsb_init; fi
      lsb_main_base_begin
      lsb_commit "$QUICK_ENGLISH" "$(quick_locale_text Hello)"
      lsb_commit "$QUICK_JAPANESE" "$(quick_locale_text こんにちは)"
      lsb_main_base_end
      lsb_commit "$QUICK_ENGLISH" "$(quick_locale_text Welcome)"
      lsb_commit "$QUICK_JAPANESE" "$(quick_locale_text ようこそ)"
      routed="$(bash "$LSB_ROOT/.gaia/scripts/audit-light-route.sh" --root "$LSB_ROOT" --member code-audit-frontend)"
      [ "$routed" = "$(printf 'light\tquick-eligible')" ] || { printf 'quick template router: %s\n' "$routed" >&2; exit 1; }
      cp "$LSB_TEMPLATE_ROOT/$flavor/slug" "$BATS_TEST_TMPDIR/slug"
    ) || return 1
  done
  # Two owned files routed light, for the replies that must name both.
  (
    BATS_TEST_TMPDIR="$LSB_TEMPLATE_ROOT/prepared-two-files"
    mkdir -p "$BATS_TEST_TMPDIR"
    lsb_init
    lsb_full_clearance code-audit-frontend
    lsb_commit apps/web/app/one.md "one"
    lsb_commit apps/web/app/two.md "two"
    routed="$(bash "$LSB_ROOT/.gaia/scripts/audit-light-route.sh" --root "$LSB_ROOT" --member code-audit-frontend)"
    [ "$routed" = "$(printf 'light\tlight-eligible')" ] || { printf 'two-file router: %s\n' "$routed" >&2; exit 1; }
    cp "$LSB_TEMPLATE_ROOT/plain/slug" "$BATS_TEST_TMPDIR/slug"
  ) || return 1
  # Owned lines refused with a major on line 2 and a minor on line 4; each
  # case then commits its own repair and routes it.
  (
    BATS_TEST_TMPDIR="$LSB_TEMPLATE_ROOT/prepared-refused"
    mkdir -p "$BATS_TEST_TMPDIR"
    lsb_init
    lsb_commit_lines apps/web/app/notes.md 5 line
    lsb_refuse_with_findings code-audit-frontend "[$(lsb_finding apps/web/app/notes.md 2 major false),$(lsb_finding apps/web/app/notes.md 4 minor false)]"
    cp "$LSB_TEMPLATE_ROOT/plain/slug" "$BATS_TEST_TMPDIR/slug"
  ) || return 1
  # The refusal cases persist the reply but never a marker, so they share one
  # prepared sandbox per route kind instead of copying one per case. Each case
  # asserts that no marker exists, so a marker left by an earlier case fails
  # every later one.
  local shared
  for shared in light quick two-files; do
    (
      BATS_TEST_TMPDIR="$BATS_FILE_TMPDIR/shared-$shared"
      mkdir -p "$BATS_TEST_TMPDIR"
      if [ "$shared" = quick ]; then lsb_from_template prepared-quick-plain; else lsb_from_template "prepared-${shared/light/plain}"; fi
    ) || return 1
  done
}

QUICK_ENGLISH="apps/web/app/languages/en/common.ts"
QUICK_JAPANESE="apps/web/app/languages/ja/common.ts"

# quick_locale_text <title>: a one-key language file.
quick_locale_text() {
  printf 'export default {\n  title: '"'"'%s'"'"',\n};' "$1"
}

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  # shellcheck source=.gaia/scripts/tests/helpers/light-sandbox.sh
  . "$REPO_ROOT/.gaia/scripts/tests/helpers/light-sandbox.sh"
  command -v jq >/dev/null 2>&1 || skip "jq not available"
  FRONTEND="code-audit-frontend"
  REPLY_FILE="$BATS_TEST_TMPDIR/reply.json"
}

teardown() {
  chmod -R u+rwx "$BATS_TEST_TMPDIR" 2>/dev/null || true
}

# expect_line <text>: the last `run` exited 0 and printed exactly <text>.
expect_line() {
  [ "$status" -eq 0 ] || { printf 'status %s, output: %s\n' "$status" "$output" >&2; return 1; }
  [ "$output" = "$1" ] || { printf 'want %s, got: %s\n' "$1" "$output" >&2; return 1; }
}

expect_full() {
  expect_line "$(printf 'full\t%s' "$1")"
}

audit_directory() {
  printf '%s/.gaia/local/audit' "$LSB_ROOT"
}

light_directory() {
  printf '%s/.gaia/local/audit/light' "$LSB_ROOT"
}

# marker_path: the earned marker the sandbox's frontend member would have for
# the current digest.
marker_path() {
  printf '%s/%s.ok' "$(audit_directory)" "$(lsb_member_digest "$FRONTEND")"
}

verdict_path() {
  printf '%s/%s.%s.verdict.json' "$(light_directory)" "$(lsb_member_digest "$FRONTEND")" "$FRONTEND"
}

record_path() {
  printf '%s/%s.%s.route.json' "$(light_directory)" "$(lsb_member_digest "$FRONTEND")" "$FRONTEND"
}

ledger_path() {
  printf '%s/%s.reviews.jsonl' "$(light_directory)" "$LSB_SLUG"
}

telemetry_log() {
  printf '%s/.gaia/local/telemetry/audit-light-routing.jsonl' "$LSB_ROOT"
}

# assert_no_marker: no earned marker for the current digest.
assert_no_marker() {
  [ ! -e "$(marker_path)" ] || { printf 'unexpected marker %s\n' "$(marker_path)" >&2; return 1; }
}

# prepare_light [--maintainer]: a full clearance, a small owned Markdown delta,
# and a router run that routed it light.
prepare_light() {
  local flavor=plain
  [ "${1:-}" = "--maintainer" ] && flavor=maintainer
  lsb_from_template "prepared-$flavor"
}

# prepare_quick [--maintainer]: a first-dispatch merge-base sandbox whose
# two-locale string change routed light quick-eligible, with no full clearance.
prepare_quick() {
  local flavor=plain
  [ "${1:-}" = "--maintainer" ] && flavor=maintainer
  lsb_from_template "prepared-quick-$flavor"
}

# use_shared_light / use_shared_quick: point the helpers at the one prepared
# sandbox the malformed-reply cases share (see setup_file) instead of copying a
# template. Only cases whose every outcome is a refusal use these.
# shellcheck disable=SC2034 # LSB_ORIGIN and LSB_BRANCH are read by the sourced sandbox helpers
use_shared_sandbox() {
  local directory="$BATS_FILE_TMPDIR/shared-$1"
  LSB_ORIGIN="$directory/lsb-origin.git"
  LSB_ROOT="$(cd "$directory/lsb-repo" && pwd -P)" || return 1
  LSB_BRANCH="feat/light-sandbox"
  LSB_SLUG="$(cat "$LSB_TEMPLATE_ROOT/prepared-plain/slug")" || return 1
  _lsb_set_head
}

use_shared_light() {
  use_shared_sandbox light
}

use_shared_quick() {
  use_shared_sandbox quick
}

use_shared_two_files() {
  use_shared_sandbox two-files
}

# prepare_refusal_anchored [file-body]: the refused template, then the repair
# (every line rewritten, or the given file body), routed light.
prepare_refusal_anchored() {
  lsb_from_template prepared-refused || return 1
  if [ -n "${1:-}" ]; then
    lsb_commit apps/web/app/notes.md "$1"
  else
    lsb_commit_lines apps/web/app/notes.md 5 fixed
  fi
  lsb_route "$FRONTEND"
  [ "$output" = "$(printf 'light\trefusal-anchored')" ] || { printf 'router: %s\n' "$output" >&2; return 1; }
}

# refuse_reply <case> <reason>: mark the reply now in the reply file; it must
# print full <reason> and write no marker. <case> names the row on failure.
refuse_reply() {
  lsb_mark "$FRONTEND" "$REPLY_FILE"
  { expect_full "$2" && assert_no_marker; } || { printf 'case: %s\n' "$1" >&2; return 1; }
}

# refuse_edited <case> <reason> <jq-filter>: refuse_reply over a clear reply
# rewritten through the filter.
refuse_edited() {
  clear_reply_to_file
  reply_edit "$3"
  refuse_reply "$1" "$2"
}

# assert_quick_refused <reason>: the last mark printed full <reason>, left no
# marker, and the router would still send the same delta to the reviewer, so
# the refusal came from the reply and not from a changed route.
assert_quick_refused() {
  expect_full "$1" || return 1
  assert_no_marker || return 1
  lsb_route "$FRONTEND" --check
  expect_line "$(printf 'light\tquick-eligible')"
}

# assert_ledger_timing <duration-or-null> [dispatched-at]: the last ledger line
# carries the merge-base anchor, a UTC marked_at no earlier than the record's
# routed_at, the reviewer duration, and the reviewer dispatch time (null when
# none is named).
assert_ledger_timing() {
  local line routed_at dispatched_at="${2:-null}"
  [ "$dispatched_at" = null ] || dispatched_at="\"$dispatched_at\""
  line="$(tail -n 1 "$(ledger_path)")"
  routed_at="$(jq -r .routed_at "$(record_path)")"
  jq -e --arg routed_at "$routed_at" --argjson duration "$1" --argjson dispatched_at "$dispatched_at" '
    .anchor_kind == "merge-base"
    and (.marked_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$"))
    and .marked_at >= $routed_at
    and .reviewer_duration_ms == $duration
    and .reviewer_dispatched_at == $dispatched_at' <<<"$line" >/dev/null || { printf 'ledger line: %s\n' "$line" >&2; return 1; }
}

clear_reply_to_file() {
  lsb_clear_reply "$FRONTEND" >"$REPLY_FILE"
}

# reply_edit <jq-filter>: rewrite the reply file through a jq filter.
reply_edit() {
  jq -c "$1" "$REPLY_FILE" >"$REPLY_FILE.new" && mv "$REPLY_FILE.new" "$REPLY_FILE"
}

# full_sidecar_base: the shared key base members use, resolved the way members
# resolve it (the resolver reads its repository from the working directory).
full_sidecar_base() {
  local reference
  reference="$(cd "$LSB_ROOT" && bash .github/audit/resolve-audit-base.sh --member "$FRONTEND" 2>/dev/null | sed -n '3p')"
  lsb_git merge-base "$reference" HEAD
}

# preseed_full_sidecar: a full round's findings sidecar under the key a light
# write would also use, so a clobber would be visible.
preseed_full_sidecar() {
  printf '[]' | bash "$LSB_ROOT/.gaia/scripts/audit-write-findings.sh" --root "$LSB_ROOT" --member "$FRONTEND" \
    --base "$(full_sidecar_base)" --findings - >/dev/null
}

full_sidecar_files() {
  find "$(audit_directory)" -maxdepth 1 -name "*.$FRONTEND.findings.json" ! -name '*.light.findings.json'
}

light_sidecar_files() {
  find "$(audit_directory)" -maxdepth 1 -name "*.$FRONTEND.light.findings.json"
}

# --- happy path -------------------------------------------------------------

# bats test_tags=whole-tree
@test "a clear verdict on the routed delta clears light with a marker, a light sidecar and a merge the gate allows" {
  prepare_light
  preseed_full_sidecar
  local full_sidecar before
  full_sidecar="$(full_sidecar_files)"
  [ -n "$full_sidecar" ]
  before="$(cksum <"$full_sidecar")"
  clear_reply_to_file
  lsb_mark "$FRONTEND" "$REPLY_FILE"
  expect_line "light-cleared"
  [ "$(jq -r '[.provenance, .review, .digest, .tree] | join(" ")' "$(marker_path)")" = "earned light $(lsb_member_digest "$FRONTEND") $LSB_TREE" ]
  [ "$(light_sidecar_files | wc -l | tr -d ' ')" = "1" ]
  [ "$(jq -c '[.review, .member, (.findings | length)]' "$(light_sidecar_files)")" = "[\"light\",\"$FRONTEND\",0]" ]
  [ "$(cksum <"$full_sidecar")" = "$before" ]
  [ "$(jq -r .review "$full_sidecar")" = "null" ]
  lsb_run_merge_hook 41
  [ "$status" -eq 0 ]
  grep -qF '"permissionDecision": "deny"' <<<"$output" && return 1
  true
}

# bats test_tags=whole-tree
@test "reply input: a missing, unreadable, empty or non-clear reply is refused with no stdin fallback, then the reply named by file clears and persists byte for byte" {
  prepare_light
  clear_reply_to_file
  lsb_mark "$FRONTEND" ""
  expect_full verdict-noop
  assert_no_marker
  lsb_mark_file "$FRONTEND" "$BATS_TEST_TMPDIR/no-such-reply.json"
  expect_full verdict-noop
  assert_no_marker
  [ -z "$(find "$(light_directory)" -name '.verdict.*')" ]
  # A clear reply on stdin does not rescue a missing named file.
  run bash -c 'bash "$1" --root "$2" --member "$3" --verdict "$4" <"$5"' _ \
    "$LSB_ROOT/.gaia/scripts/audit-light-mark.sh" "$LSB_ROOT" "$FRONTEND" "$BATS_TEST_TMPDIR/no-such-reply.json" "$REPLY_FILE"
  expect_full verdict-noop
  assert_no_marker
  # A directory cannot be read as a reply on any platform or user, root included.
  mkdir "$BATS_TEST_TMPDIR/reply-directory"
  lsb_mark_file "$FRONTEND" "$BATS_TEST_TMPDIR/reply-directory"
  expect_full verdict-noop
  assert_no_marker
  # A mode-000 file, where the user is not root and the mode is enforced.
  cp "$REPLY_FILE" "$BATS_TEST_TMPDIR/locked-reply.json"
  chmod 000 "$BATS_TEST_TMPDIR/locked-reply.json"
  if [ ! -r "$BATS_TEST_TMPDIR/locked-reply.json" ]; then
    lsb_mark_file "$FRONTEND" "$BATS_TEST_TMPDIR/locked-reply.json"
    expect_full verdict-noop
    assert_no_marker
  fi
  lsb_escalate_reply "$FRONTEND" >"$BATS_TEST_TMPDIR/escalate-reply.json"
  lsb_mark_file "$FRONTEND" "$BATS_TEST_TMPDIR/escalate-reply.json"
  expect_full escalate
  assert_no_marker
  # The clear reply by file path, with the stricter merge-base keys that a
  # post-clearance record ignores, and a trailing newline kept as written.
  reply_edit '. + {extra: 1} | .reason = "one minor nit" | .files[0].extra = 1'
  printf '\n' >>"$REPLY_FILE"
  [ "$(jq -r .anchor_kind "$(record_path)")" = "full" ]
  lsb_mark_file "$FRONTEND" "$REPLY_FILE"
  expect_line "light-cleared"
  [ "$(jq -r '[.provenance, .review, .digest, .tree] | join(" ")' "$(marker_path)")" = "earned light $(lsb_member_digest "$FRONTEND") $LSB_TREE" ]
  [ "$(light_sidecar_files | wc -l | tr -d ' ')" = "1" ]
  cmp -s "$REPLY_FILE" "$(verdict_path)"
}

# bats test_tags=whole-tree
@test "post-clearance reply validation: each malformed or mismatched reply prints full with its reason and writes no marker, and the clear twin clears" {
  use_shared_light
  clear_reply_to_file
  : >"$REPLY_FILE"
  refuse_reply "empty reply" verdict-noop
  printf 'looks fine to me\n' >"$REPLY_FILE"
  refuse_reply "non-JSON reply" verdict-noop
  cmp -s "$REPLY_FILE" "$(verdict_path)"
  printf '[{"path":"apps/web/app/notes.md","verdict":"clear"}]' >"$REPLY_FILE"
  refuse_reply "JSON array reply" verdict-noop
  refuse_edited "no files" verdict-noop 'del(.files)'
  refuse_edited "unknown verdict" verdict-malformed '.verdict = "approve"'
  refuse_edited "unknown per-file verdict" verdict-malformed '.files[0].verdict = "approve"'
  refuse_edited "wrong schema number" verdict-malformed '.schema = 2'
  refuse_edited "path the route record does not list" verdict-mismatch '.files[0].path = "apps/web/app/other.md"'
  refuse_edited "wrong tree" verdict-mismatch '.tree = "0000000000000000000000000000000000000001"'
  refuse_edited "wrong member" verdict-mismatch '.member = "code-audit-maintainer-shell"'
  use_shared_two_files
  clear_reply_to_file
  [ "$(jq '.files | length' "$REPLY_FILE")" = "2" ]
  refuse_edited "one escalated file among clear files" escalate '.files[0].verdict = "escalate"'
  refuse_edited "files array one short" verdict-noop '.files |= .[0:1]'
  refuse_edited "duplicated path in place of a routed one" verdict-mismatch '.files[1].path = .files[0].path'
  clear_reply_to_file
  lsb_mark "$FRONTEND" "$REPLY_FILE"
  expect_line "light-cleared"
}

# bats test_tags=whole-tree
@test "ledger: each outcome after the reply appends one line in the documented shape (failed, clear, escalate)" {
  prepare_light
  clear_reply_to_file
  reply_edit '.verdict = "approve"'
  lsb_mark "$FRONTEND" "$REPLY_FILE"
  expect_full verdict-malformed
  [ "$(wc -l <"$(ledger_path)" | tr -d ' ')" = "1" ]
  [ "$(jq -r '[.member, .verdict, .digest, .tree] | join(" ")' "$(ledger_path)")" = "$FRONTEND failed $(lsb_member_digest "$FRONTEND") $LSB_TREE" ]
  clear_reply_to_file
  lsb_mark "$FRONTEND" "$REPLY_FILE"
  expect_line "light-cleared"
  lsb_commit apps/web/app/more.md "more"
  lsb_route "$FRONTEND"
  expect_line "$(printf 'light\tlight-eligible')"
  lsb_escalate_reply "$FRONTEND" >"$REPLY_FILE"
  lsb_mark "$FRONTEND" "$REPLY_FILE"
  expect_full escalate
  [ "$(wc -l <"$(ledger_path)" | tr -d ' ')" = "3" ]
  [ "$(jq -c '[keys[]]' "$(ledger_path)" | sort -u)" = '["anchor_kind","at","digest","marked_at","member","reviewer_dispatched_at","reviewer_duration_ms","tree","verdict"]' ]
  [ "$(jq -r .verdict "$(ledger_path)" | paste -sd, -)" = "failed,clear,escalate" ]
  [ "$(jq -c '[.anchor_kind, .reviewer_duration_ms]' "$(ledger_path)" | sort -u)" = '["full",null]' ]
  jq -e '.at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")' "$(ledger_path)" >/dev/null
}

# bats test_tags=whole-tree
@test "route record, fresh route and refusal checks: each prints full with its reason and writes no marker" {
  prepare_light
  clear_reply_to_file
  local record original="$BATS_TEST_TMPDIR/record.original"
  record="$(record_path)"
  cp "$record" "$original"
  rm "$record"
  refuse_reply "absent route record" no-route-record
  printf 'not json' >"$record"
  refuse_reply "unparseable route record" no-route-record
  jq -c '.digest = "1111111111111111111111111111111111111111111111111111111111111111"' "$original" >"$record"
  refuse_reply "route record naming another digest" route-stale
  jq -c '.tree = "0000000000000000000000000000000000000001"' "$original" >"$record"
  refuse_reply "route record naming another tree" route-stale
  jq -c '.route = "full"' "$original" >"$record"
  refuse_reply "route record whose route is full" route-not-light
  cp "$original" "$record"
  printf 'dirty\n' >>"$LSB_ROOT/apps/web/app/notes.md"
  lsb_route "$FRONTEND" --check
  expect_line "$(printf 'full\tdirty-tree')"
  refuse_reply "record stored light that the fresh router calls full" recheck-full
  lsb_git checkout -q -- apps/web/app/notes.md
  # HEAD moving during the review by an owned change.
  lsb_commit apps/web/app/later.md "committed while the reviewer ran"
  lsb_mark "$FRONTEND" "$REPLY_FILE"
  [ "$status" -eq 0 ]
  case "$output" in
    "$(printf 'full\tno-route-record')" | "$(printf 'full\troute-stale')") ;;
    *) printf 'unexpected: %s\n' "$output" >&2; return 1 ;;
  esac
  assert_no_marker
  lsb_git reset -q --hard HEAD~1
  _lsb_set_head
  local refusal before
  # A refusal whose tree is no commit in the walk range is invisible to the
  # router, so only this script's own check can see it.
  refusal="$(lsb_marker_json "$FRONTEND" refused "" "0000000000000000000000000000000000000001" "$(awk 'NF { print; exit }' "$LSB_ROOT/.gaia/VERSION" | tr -d '[:space:]')" "$(lsb_member_digest "$FRONTEND")")"
  [ -f "$refusal" ]
  before="$(cksum <"$refusal")"
  refuse_reply "same-digest refusal" refusal-present
  [ -f "$refusal" ]
  [ "$(cksum <"$refusal")" = "$before" ]
}

# bats test_tags=whole-tree,protected
@test "a wrong digest in the verdict prints full verdict-mismatch" {
  use_shared_light
  clear_reply_to_file
  reply_edit '.digest = "0000000000000000000000000000000000000000000000000000000000000000"'
  lsb_mark "$FRONTEND" "$REPLY_FILE"
  expect_full verdict-mismatch
  assert_no_marker
}

# bats test_tags=whole-tree,protected
@test "a hard-full edit committed after routing never clears light" {
  prepare_light
  clear_reply_to_file
  lsb_commit .claude/hooks/lib/zz-added-after-routing.txt "touched after routing"
  lsb_mark "$FRONTEND" "$REPLY_FILE"
  [ "$status" -eq 0 ]
  case "$output" in
    "$(printf 'full\tno-route-record')" | "$(printf 'full\troute-stale')" | "$(printf 'full\trecheck-full')") ;;
    *) printf 'unexpected: %s\n' "$output" >&2; return 1 ;;
  esac
  assert_no_marker
}

# --- refusal-anchored checklist ---------------------------------------------

# bats test_tags=whole-tree
@test "refusal-anchored checklist: resolved must name every open finding as strings and nothing else; a complete reply clears and accounts for the findings" {
  prepare_refusal_anchored
  clear_reply_to_file
  [ "$(jq -c .resolved "$REPLY_FILE")" = '["r1-1","r1-2"]' ]
  refuse_edited "resolved omits an open finding" verdict-incomplete '.resolved = ["r1-1"]'
  refuse_edited "no resolved list" verdict-incomplete 'del(.resolved)'
  refuse_edited "resolved names a key the checklist does not hold" verdict-mismatch '.resolved = ["r1-1","r1-2","r9-9"]'
  refuse_edited "resolved is a string" verdict-malformed '.resolved = "r1-1"'
  refuse_edited "resolved holds a non-string" verdict-malformed '.resolved = ["r1-1", 2]'
  lsb_escalate_reply "$FRONTEND" >"$REPLY_FILE"
  refuse_reply "escalating reply" escalate
  clear_reply_to_file
  lsb_mark "$FRONTEND" "$REPLY_FILE"
  expect_line "light-cleared"
  [ "$(jq -r '[.provenance, .review, .tree] | join(" ")' "$(marker_path)")" = "earned light $LSB_TREE" ]
  local sidecar ledger
  sidecar="$(full_sidecar_files)"
  [ -f "$sidecar" ]
  [ "$(jq -c '[(.findings | length), [.resolutions[].entry_id]]' "$sidecar")" = '[0,["r1-1","r1-2"]]' ]
  ledger="$(find "$(audit_directory)" -maxdepth 1 -name '*.rerun.json')"
  [ -z "$ledger" ] || { printf 'ledger left behind: %s\n' "$ledger" >&2; return 1; }
}

# refusal_anchored_row <row> <file-body> <clear|unchanged>: a repair of the
# given body in a sandbox of its own, marked with the all-resolved reply.
refusal_anchored_row() {
  local base="$BATS_TEST_TMPDIR"
  BATS_TEST_TMPDIR="$base/row-$1"
  mkdir -p "$BATS_TEST_TMPDIR"
  REPLY_FILE="$BATS_TEST_TMPDIR/reply.json"
  prepare_refusal_anchored "$2"
  clear_reply_to_file
  [ "$(jq -c .resolved "$REPLY_FILE")" = '["r1-1","r1-2"]' ]
  lsb_mark "$FRONTEND" "$REPLY_FILE"
  if [ "$3" = clear ]; then
    expect_line "light-cleared" || { printf 'row: %s\n' "$1" >&2; return 1; }
  else
    { expect_full checklist-unchanged && assert_no_marker; } || { printf 'row: %s\n' "$1" >&2; return 1; }
  fi
  BATS_TEST_TMPDIR="$base"
  REPLY_FILE="$base/reply.json"
}

# bats test_tags=whole-tree
@test "refusal-anchored checklist: each cited line must be touched by the delta, and a pure insertion beside it counts as touching it" {
  refusal_anchored_row "cited-line-never-touched" "$(printf 'line 1\nfixed 2\nline 3\nline 4\nline 5')" unchanged
  refusal_anchored_row "insertion-beside-each-cited-line" "$(printf 'line 1\nline 2\ninserted a\nline 3\nline 4\ninserted b\nline 5')" clear
  refusal_anchored_row "insertion-beside-one-cited-line" "$(printf 'line 1\nline 2\ninserted a\nline 3\nline 4\nline 5')" unchanged
}

# --- the merge-base (first-dispatch quick) reply contract ------------------------

# bats test_tags=whole-tree
@test "merge-base reply contract: a malformed, escalating, empty or missing reply prints full with its reason and writes no marker, and the route stays quick-eligible" {
  use_shared_quick
  clear_reply_to_file
  lsb_escalate_reply "$FRONTEND" >"$REPLY_FILE"
  refuse_reply "escalate reply" escalate
  : >"$REPLY_FILE"
  refuse_reply "empty reply" verdict-noop
  lsb_mark_file "$FRONTEND" "$BATS_TEST_TMPDIR/no-such-reply.json"
  { expect_full verdict-noop && assert_no_marker; } || { printf 'case: missing reply file\n' >&2; return 1; }
  refuse_edited "findings array" verdict-malformed '. + {findings: []}'
  # The refused run persists the same timing fields, with a null duration and
  # dispatch time when no flag names them.
  refuse_edited "any extra key" verdict-malformed '. + {extra: 1}'
  assert_ledger_timing null
  [ "$(jq -r .verdict "$(ledger_path)" | tail -n 1)" = "failed" ]
  refuse_edited "missing required key" verdict-malformed 'del(.reason)'
  refuse_edited "file object extra key" verdict-malformed '.files[0].extra = 1'
  refuse_edited "non-empty resolved list" verdict-malformed '.resolved = ["x"]'
  refuse_edited "reason names a minor nit" verdict-malformed '.reason = "one minor nit"'
  refuse_edited "file note says Minor" verdict-malformed '.files[0].note = "Minor: spacing"'
  lsb_route "$FRONTEND" --check
  expect_line "$(printf 'light\tquick-eligible')"
}

# bats test_tags=whole-tree
@test "a clean reply on a merge-base record prints light-cleared with a light marker, the merge-base anchor, an empty light sidecar and the reviewer timing on its ledger line" {
  prepare_quick
  [ "$(jq -r .anchor_kind "$(record_path)")" = "merge-base" ]
  clear_reply_to_file
  [ "$(jq -c .resolved "$REPLY_FILE")" = '[]' ]
  run bash -c 'bash "$1" --root "$2" --member "$3" --verdict - --reviewer-duration-ms 6900 --reviewer-dispatched-at 2020-01-01T00:00:00Z <"$4"' _ \
    "$LSB_ROOT/.gaia/scripts/audit-light-mark.sh" "$LSB_ROOT" "$FRONTEND" "$REPLY_FILE"
  expect_line "light-cleared"
  [ "$(jq -r .review "$(marker_path)")" = "light" ]
  [ "$(jq -r .anchor_kind "$(record_path)")" = "merge-base" ]
  [ "$(light_sidecar_files | wc -l | tr -d ' ')" = "1" ]
  [ "$(jq -c .findings "$(light_sidecar_files)")" = '[]' ]
  [ "$(find "$(audit_directory)" -maxdepth 1 -name '*.findings.json' | wc -l | tr -d ' ')" = "1" ]
  assert_ledger_timing 6900 2020-01-01T00:00:00Z
}

# bats test_tags=whole-tree
@test "words that only contain minor or nit as a fragment still clear on a merge-base record, and no dispatch flag records a null dispatch time" {
  prepare_quick
  clear_reply_to_file
  reply_edit '.reason = "a minority of tokens, nitrogen free" | .files[0].note = "reviewed unit"'
  lsb_mark "$FRONTEND" "$REPLY_FILE"
  expect_line "light-cleared"
  [ -f "$(marker_path)" ]
  [ "$(jq -c .reviewer_dispatched_at "$(ledger_path)")" = "null" ]
}

# bats test_tags=whole-tree
@test "in a maintainer sandbox a merge-base clear appends one light_outcome with the reviewer tokens, duration and anchor kind" {
  prepare_quick --maintainer
  clear_reply_to_file
  run bash -c 'bash "$1" --root "$2" --member "$3" --verdict - --reviewer-tokens 4321 --reviewer-duration-ms 987 <"$4"' _ \
    "$LSB_ROOT/.gaia/scripts/audit-light-mark.sh" "$LSB_ROOT" "$FRONTEND" "$REPLY_FILE"
  expect_line "light-cleared"
  [ "$(grep -c '"light_outcome"' "$(telemetry_log)")" = "1" ]
  [ "$(grep '"light_outcome"' "$(telemetry_log)" | jq -r '[.verdict, (.tokens | tostring), (.duration_ms | tostring), .anchor_kind] | join(" ")')" = "clear 4321 987 merge-base" ]
}

# expect_usage_error <case> <argument...>: the script exits 2, prints no
# decision line and persists nothing.
expect_usage_error() {
  local label="$1"
  shift
  run bash "$LSB_ROOT/.gaia/scripts/audit-light-mark.sh" "$@" </dev/null
  grep -qE 'light-cleared|^full' <<<"$output" && { printf 'case: %s printed a decision: %s\n' "$label" "$output" >&2; return 1; }
  { [ "$status" -eq 2 ] && [ ! -e "$(ledger_path)" ] && [ -z "$(find "$(light_directory)" -name '*.verdict.json')" ] && assert_no_marker; } || { printf 'case: %s\nstatus %s, output: %s\n' "$label" "$status" "$output" >&2; return 1; }
}

# bats test_tags=whole-tree
@test "usage errors exit 2, print no decision line and persist nothing" {
  prepare_quick
  clear_reply_to_file
  local value
  expect_usage_error "no verdict flag" --root "$LSB_ROOT" --member "$FRONTEND"
  expect_usage_error "bare verdict flag" --root "$LSB_ROOT" --member "$FRONTEND" --verdict
  expect_usage_error "non-integer tokens" --root "$LSB_ROOT" --member "$FRONTEND" --verdict - --reviewer-tokens many
  expect_usage_error "non-integer duration" --root "$LSB_ROOT" --member "$FRONTEND" --verdict - --reviewer-duration-ms 1.5
  expect_usage_error "unknown dispatch flag" --root "$LSB_ROOT" --member "$FRONTEND" --verdict - --dispatched-at 2020-01-01T00:00:00Z
  expect_usage_error "relative root" --root relative/path --member "$FRONTEND" --verdict -
  expect_usage_error "member escaping the directory" --root "$LSB_ROOT" --member ../escape --verdict -
  expect_usage_error "unknown flag" --root "$LSB_ROOT" --member "$FRONTEND" --verdict - --unknown
  for value in "2026-10-21 05:00:00" "2026-10-21T05:00:00.123Z" "2026-10-21T05:00:00+09:00" "now" ""; do
    expect_usage_error "dispatch time '$value'" --root "$LSB_ROOT" --member "$FRONTEND" --verdict "$REPLY_FILE" --reviewer-dispatched-at "$value"
  done
  expect_usage_error "bare dispatch time flag" --root "$LSB_ROOT" --member "$FRONTEND" --verdict "$REPLY_FILE" --reviewer-dispatched-at
}

# bats test_tags=whole-tree
@test "a telemetry directory the script cannot write still prints light-cleared" {
  prepare_light --maintainer
  clear_reply_to_file
  chmod 0555 "$(dirname "$(telemetry_log)")"
  lsb_mark "$FRONTEND" "$REPLY_FILE"
  expect_line "light-cleared"
  [ "$(jq -r .review "$(marker_path)")" = "light" ]
}

# --- cwd independence -------------------------------------------------------

# bats test_tags=whole-tree
@test "run from an unrelated directory the sidecar still lands under the sandbox root" {
  prepare_light
  clear_reply_to_file
  mkdir -p "$BATS_TEST_TMPDIR/elsewhere"
  run bash -c 'cd "$5" && bash "$1" --root "$2" --member "$3" --verdict - <"$4"' _ \
    "$LSB_ROOT/.gaia/scripts/audit-light-mark.sh" "$LSB_ROOT" "$FRONTEND" "$REPLY_FILE" "$BATS_TEST_TMPDIR/elsewhere"
  expect_line "light-cleared"
  [ "$(light_sidecar_files | wc -l | tr -d ' ')" = "1" ]
  [ -z "$(find "$BATS_TEST_TMPDIR/elsewhere" -type f)" ]
}

# The resolver's argument-less line is a commit when it names the branch's fork
# point instead of a ref; the light sidecar must still land under the key the
# members' own sidecars use.
# bats test_tags=whole-tree
@test "the light sidecar shares the member sidecar's key when the resolver prints a commit" {
  local fork_point resolver="$BATS_TEST_TMPDIR/resolver.sh" full_name light_name
  lsb_init
  fork_point="$(lsb_git merge-base refs/remotes/origin/main HEAD)"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'if [ "$#" -eq 0 ]; then printf "%%s\\n" "%s"; else printf "%%s\\n%%s\\n%%s\\n\\n" "%s" no-anchor "%s"; fi\n' \
      "$fork_point" "$fork_point" "$fork_point"
  } >"$resolver"
  cp "$resolver" "$LSB_ROOT/.github/audit/resolve-audit-base.sh"
  lsb_git add -A && lsb_git commit -q -m "pin the resolver answer"
  lsb_full_clearance "$FRONTEND"
  lsb_commit apps/web/app/notes.md "$(printf 'one\ntwo\nthree')"
  lsb_route "$FRONTEND"
  [ "$output" = "$(printf 'light\tlight-eligible')" ]
  preseed_full_sidecar
  clear_reply_to_file
  lsb_mark "$FRONTEND" "$REPLY_FILE"
  expect_line "light-cleared"
  full_name="$(basename "$(full_sidecar_files)")"
  light_name="$(basename "$(light_sidecar_files)")"
  [ "${full_name%".$FRONTEND.findings.json"}" = "${light_name%".$FRONTEND.light.findings.json"}" ]
}

# --- degraded ---------------------------------------------------------------

# bats test_tags=whole-tree
@test "an underivable digest prints full degraded and persists nothing" {
  prepare_light --maintainer
  clear_reply_to_file
  local telemetry_lines_before
  telemetry_lines_before="$(grep -c '"light_outcome"' "$(telemetry_log)" || true)"
  printf '#!/usr/bin/env bash\nexit 1\n' >"$LSB_ROOT/.gaia/scripts/audit-member-digest.sh"
  lsb_mark "$FRONTEND" "$REPLY_FILE"
  expect_full degraded
  [ -z "$(find "$(light_directory)" -name '*.verdict.json')" ]
  [ ! -e "$(ledger_path)" ]
  [ "$(grep -c '"light_outcome"' "$(telemetry_log)" || true)" = "$telemetry_lines_before" ]
  [ -z "$(find "$(audit_directory)" -maxdepth 1 -name '*.ok' -newer "$REPLY_FILE")" ]
}

# --- structural guards ------------------------------------------------------

# review_light_offenders <repo>: tracked *.sh files outside the allowlist that
# spell the literal. The allowlist is the two writers (the clearance writer with
# its phase siblings), the one caller, and any shell file under a tests
# directory.
review_light_offenders() {
  local scanned=0 file
  while IFS= read -r -d '' file; do
    scanned=$((scanned + 1))
    case "$file" in
      .gaia/scripts/audit-write-clearance.sh | .gaia/scripts/audit-write-clearance-*.sh | .gaia/scripts/audit-write-findings.sh | .gaia/scripts/audit-light-mark.sh) continue ;;
      tests/* | */tests/*) continue ;;
    esac
    grep -qF -- '--review light' "$1/$file" 2>/dev/null && printf '%s\n' "$file"
  done < <(git -C "$1" ls-files -z -- '*.sh')
  [ "$scanned" -gt 0 ] || printf 'scanned nothing\n'
  return 0
}

# bats test_tags=whole-tree
@test "the review-light literal appears in no tracked shell file outside the allowlist" {
  local offenders
  offenders="$(review_light_offenders "$REPO_ROOT")"
  [ -z "$offenders" ] || { printf 'offenders: %s\n' "$offenders" >&2; return 1; }
  # Non-vacuity: the scan reads files that do carry the literal.
  grep -qF -- '--review light' "$REPO_ROOT/.gaia/scripts/audit-write-clearance.sh"
  grep -qF -- '--review light' "$REPO_ROOT/.gaia/scripts/audit-write-findings.sh"
  grep -qF -- '--review light' "$REPO_ROOT/.gaia/scripts/audit-light-mark.sh"
  [ "$(git -C "$REPO_ROOT" ls-files -z -- '*.sh' | tr -cd '\0' | wc -c | tr -d ' ')" -gt 50 ]
}

# fenced_telemetry_references <file>: prints `fenced` when every line naming the
# telemetry script sits between the shell maintainer-only markers and at least
# one such line exists.
fenced_telemetry_references() {
  awk -v marker="gaia:""maintainer-only" '
    index($0, "# " marker ":start") { inside = 1; next }
    index($0, "# " marker ":end") { inside = 0; next }
    /audit-light-telemetry\.sh/ { seen++; if (!inside) bad++ }
    END { if (seen > 0 && bad == 0) print "fenced"; else print "unfenced" }
  ' "$1"
}

@test "every line naming the telemetry script sits inside maintainer-only markers" {
  [ "$(fenced_telemetry_references "$REPO_ROOT/.gaia/scripts/audit-light-mark.sh")" = "fenced" ]
}
