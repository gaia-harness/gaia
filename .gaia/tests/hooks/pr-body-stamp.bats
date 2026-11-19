#!/usr/bin/env bats
#
# The PR body's head stamp: the library (.claude/hooks/lib/pr-body-stamp.sh),
# the script that writes and checks it (.gaia/scripts/pr-body-stamp.sh), and
# the merge gate's refusal of a stale one on an audited allow. The poster's
# refusal lives with its other cases in post-audit-status.bats.
#
# Run: .gaia/scripts/bats5.sh .gaia/tests/hooks/pr-body-stamp.bats < /dev/null
# Assertion style: .claude/rules/bats-assertions.md.

bats_require_minimum_version 1.5.0

HEAD_SHA=1111111111111111111111111111111111111111
OLD_SHA=2222222222222222222222222222222222222222

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  STAMP_LIBRARY="$REPO_ROOT/.claude/hooks/lib/pr-body-stamp.sh"
  STAMP_SCRIPT="$REPO_ROOT/.gaia/scripts/pr-body-stamp.sh"
}

stamp_of() {
  printf '<!-- gaia-pr-body-head: %s -->' "$1"
}

verdict() {
  bash -c '. "$1"; pr_body_stamp_verdict "$2" "$3"' _ "$STAMP_LIBRARY" "$1" "$2"
}

restamp() {
  bash -c '. "$1"; pr_body_restamp "$2" "$3"' _ "$STAMP_LIBRARY" "$1" "$2"
}

# --- library -----------------------------------------------------------------

@test "a body carrying one stamp for the head is current" {
  run verdict "Summary.

Closes #<N>

$(stamp_of "$HEAD_SHA")" "$HEAD_SHA"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a body with no stamp is stale" {
  run verdict "Summary.

Closes #<N>" "$HEAD_SHA"
  [ "$status" -eq 1 ]
  [ "$output" = "the PR body carries no head stamp" ]
}

@test "a stamp for another head is stale and the reason names the head" {
  run verdict "Summary.
$(stamp_of "$OLD_SHA")" "$HEAD_SHA"
  [ "$status" -eq 1 ]
  grep -qF -- "not for head ${HEAD_SHA:0:12}" <<<"$output"
}

@test "a second stamp beside a current one is stale" {
  run verdict "$(stamp_of "$OLD_SHA")
Summary.
$(stamp_of "$HEAD_SHA")" "$HEAD_SHA"
  [ "$status" -eq 1 ]
  [ "$output" = "the PR body carries 2 head stamps, not one" ]
}

@test "prose that mentions the stamp mid-line is not a stamp" {
  run verdict "The gate reads the \`$(stamp_of "$OLD_SHA")\` line.
$(stamp_of "$HEAD_SHA")" "$HEAD_SHA"
  [ "$status" -eq 0 ]
}

@test "a body stored with CRLF endings still reads its stamp" {
  run verdict "$(printf 'Summary.\r\n\r\n%s\r\n' "$(stamp_of "$HEAD_SHA")")" "$HEAD_SHA"
  [ "$status" -eq 0 ]
}

@test "a restamp replaces the stamp, keeps every other line, and is idempotent" {
  local body once twice
  body="Summary.

Closes #<N>

## Audit rounds
- round 1: clean
$(stamp_of "$OLD_SHA")"
  once="$(restamp "$body" "$HEAD_SHA")"
  twice="$(restamp "$once" "$HEAD_SHA")"
  [ "$once" = "$twice" ]
  run verdict "$once" "$HEAD_SHA"
  [ "$status" -eq 0 ]
  # Every non-stamp line survives in order.
  [ "$(grep -v 'gaia-pr-body-head' <<<"$once" | grep -v '^$')" = "$(grep -v 'gaia-pr-body-head' <<<"$body" | grep -v '^$')" ]
}

@test "a stamp moved with no body change passes: the re-read found nothing false" {
  local body moved
  body="Summary.
$(stamp_of "$OLD_SHA")"
  moved="$(restamp "$body" "$HEAD_SHA")"
  [ "$(diff <(printf '%s\n' "$body") <(printf '%s\n' "$moved") | grep -c '^[<>] .*gaia-pr-body-head')" -eq 2 ]
  run verdict "$moved" "$HEAD_SHA"
  [ "$status" -eq 0 ]
}

# --- the script --------------------------------------------------------------

# install_script_gh_stub <body>: a gh whose `pr view` answers a record for PR 7
# at HEAD_SHA carrying <body>, and whose `pr edit` copies the --body-file it is
# handed to edited-body. Every call is logged.
install_script_gh_stub() {
  local stub_directory="$BATS_TEST_TMPDIR/stub"
  mkdir -p "$stub_directory/bin"
  jq -n --arg body "$1" --arg head "$HEAD_SHA" '{number: 7, headRefOid: $head, body: $body}' > "$stub_directory/record.json"
  cat > "$stub_directory/bin/gh" <<EOF
#!/usr/bin/env bash
stub_directory="$stub_directory"
EOF
  cat >> "$stub_directory/bin/gh" <<'EOF'
printf '%s\n' "$*" >> "$stub_directory/gh.log"
case "$1 ${2-}" in
  "pr view") cat "$stub_directory/record.json"; exit 0 ;;
  "pr edit")
    previous=''
    for argument in "$@"; do
      [ "$previous" != --body-file ] || cp "$argument" "$stub_directory/edited-body"
      previous="$argument"
    done
    exit 0
    ;;
esac
exit 1
EOF
  chmod +x "$stub_directory/bin/gh"
  STUB_DIRECTORY="$stub_directory"
  export PATH="$stub_directory/bin:$PATH"
}

@test "write on a stale body edits the pull request once with a current body" {
  install_script_gh_stub "Summary.

Closes #<N>
$(stamp_of "$OLD_SHA")"
  run bash "$STAMP_SCRIPT" write --pr 7
  [ "$status" -eq 0 ]
  [ "$output" = "stamp: written ${HEAD_SHA:0:12}" ]
  [ "$(grep -c '^pr edit 7 --body-file ' "$STUB_DIRECTORY/gh.log")" -eq 1 ]
  run verdict "$(cat "$STUB_DIRECTORY/edited-body")" "$HEAD_SHA"
  [ "$status" -eq 0 ]
  grep -qxF -- 'Closes #<N>' "$STUB_DIRECTORY/edited-body"
}

@test "write on a current body leaves the pull request alone" {
  install_script_gh_stub "Summary.
$(stamp_of "$HEAD_SHA")"
  run bash "$STAMP_SCRIPT" write
  [ "$status" -eq 0 ]
  [ "$output" = "stamp: current ${HEAD_SHA:0:12}" ]
  grep -q '^pr edit' "$STUB_DIRECTORY/gh.log" && return 1
  true
}

# bats test_tags=protected
@test "check exits 1 on a stale body with the reason, and 0 on a current one" {
  install_script_gh_stub "Summary."
  run bash "$STAMP_SCRIPT" check --pr 7
  [ "$status" -eq 1 ]
  [ "$output" = "the PR body carries no head stamp" ]

  install_script_gh_stub "$(stamp_of "$HEAD_SHA")"
  run bash "$STAMP_SCRIPT" check --pr 7
  [ "$status" -eq 0 ]
}

@test "an unreadable pull request exits 3 and a malformed call exits 2" {
  local empty_bin="$BATS_TEST_TMPDIR/empty-bin"
  mkdir -p "$empty_bin"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$empty_bin/gh"
  chmod +x "$empty_bin/gh"
  PATH="$empty_bin:$PATH" run bash "$STAMP_SCRIPT" write --pr 7
  [ "$status" -eq 3 ]
  run bash "$STAMP_SCRIPT" write --pr seven
  [ "$status" -eq 2 ]
  run bash "$STAMP_SCRIPT" stamp
  [ "$status" -eq 2 ]
}

@test "a missing stamp library exits 2 and never edits the pull request" {
  install_script_gh_stub "Summary.
$(stamp_of "$OLD_SHA")"
  local scratch="$BATS_TEST_TMPDIR/scratch-copy"
  mkdir -p "$scratch/.gaia/scripts" "$scratch/.claude/hooks/lib"
  cp "$STAMP_SCRIPT" "$scratch/.gaia/scripts/pr-body-stamp.sh"
  run bash "$scratch/.gaia/scripts/pr-body-stamp.sh" write --pr 7
  [ "$status" -eq 2 ]
  grep -qF -- 'cannot load the stamp library' <<<"$output"
  [ ! -e "$STUB_DIRECTORY/gh.log" ]
}

# --- the merge gate ----------------------------------------------------------

gate_setup() {
  . "$BATS_TEST_DIRNAME/helpers/run-hook.sh"
  . "$REPO_ROOT/.gaia/tests/helpers/audit-roster.sh"
  . "$BATS_TEST_DIRNAME/helpers/merge-gate-fixture.sh"
  . "$BATS_TEST_DIRNAME/helpers/package-fixture.sh"
  mgf_init
  write_builtin_descriptor "$REPO"
}

# set_record_body <body>: replace the recorded pull request's body.
set_record_body() {
  jq -c --arg body "$1" '.body = $body' "$MGF_STUB_DIRECTORY/record.json" > "$MGF_STUB_DIRECTORY/record.next"
  mv "$MGF_STUB_DIRECTORY/record.next" "$MGF_STUB_DIRECTORY/record.json"
}

marker_cleared_app_pr() {
  mgf_commit "apps/web/app/x.ts" "export const x = 1"
  mgf_record 12 false "feat: x" "apps/web/app/x.ts"
  mgf_marker code-audit-frontend >/dev/null
}

@test "gate: a marker-cleared merge with a current stamp is allowed" {
  gate_setup
  marker_cleared_app_pr
  mgf_run_merge "gh pr merge 12 --squash"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# bats test_tags=protected
@test "gate: a stamp for an older head denies the marker-cleared merge, naming the write command" {
  gate_setup
  marker_cleared_app_pr
  set_record_body "Summary.
$(stamp_of "$OLD_SHA")"
  mgf_run_merge "gh pr merge 12 --squash"
  assert_denied_by_json
  grep -qF -- 'not for head' <<<"$output" || return 1
  grep -qF -- '.gaia/scripts/pr-body-stamp.sh write' <<<"$output" || return 1
}

@test "gate: a body with no stamp denies the marker-cleared merge" {
  gate_setup
  marker_cleared_app_pr
  set_record_body "Summary."
  mgf_run_merge "gh pr merge 12 --squash"
  assert_denied_by_json
  grep -qF -- 'carries no head stamp' <<<"$output"
}

@test "gate: a bypass merge is not held to the stamp" {
  gate_setup
  mgf_commit "wiki/page.md" "doc"
  mgf_record 12 false "docs: page" "wiki/page.md"
  set_record_body "Summary."
  mgf_run_merge "gh pr merge 12 --squash"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "gate mutation: without the stamp call the stale-stamp merge is allowed" {
  local mutant
  gate_setup
  # `:` rather than deletion: an emptied else branch would not parse.
  mutant="$(mgf_scratch_hook 's/^([ \t]*)gate_require_body_stamp$/$1:/mg')"
  marker_cleared_app_pr
  set_record_body "Summary."
  mgf_run_merge "gh pr merge 12 --squash" "$mutant"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
