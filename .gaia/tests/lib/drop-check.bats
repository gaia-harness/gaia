#!/usr/bin/env bats
#
# The drop-destination check (drop-check.mjs): a review fixer's output is
# refused unless every finding is accounted for, every changed behavior line is
# quoted by a fix, and every dropped case names a destination holding it. Each
# refusal case has an accepting twin that differs only in the refused property.
# Fixtures live under $BATS_TEST_TMPDIR.
#
# Assertion style follows .claude/rules/bats-assertions.md.


setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  CLI="$REPO_ROOT/.gaia/scripts/spec/drop-check.mjs"
  WORK="$BATS_TEST_TMPDIR/work"
  FINDINGS="$WORK/findings"
  PRE="$WORK/pre/SPEC.md"
  POST="$WORK/post/SPEC.md"
  FIXES="$FINDINGS/fixes.json"
  REQUIREMENTS="$WORK/REQUIREMENTS.md"
  mkdir -p "$FINDINGS" "$WORK/pre" "$WORK/post"
}

# Write the findings file: one id per argument.
write_findings() {
  local ids="" id
  for id in "$@"; do
    ids="$ids{\"id\":\"$id\"},"
  done
  printf '{"findings":[%s]}\n' "${ids%,}" >"$FINDINGS/lens.json"
}

# Write the fixes file. $1 is the edits array and $2 the drops array of TST-001;
# SEC-001 is listed as rejected.
write_fixes() {
  printf '{"fixes":[{"finding":"TST-001","route":"spec","edits":%s,"drops":%s},{"finding":"SEC-001","route":"rejected"}]}\n' \
    "$1" "$2" >"$FIXES"
}

drop_json() { # behavior destination file fragment
  printf '[{"behavior":"%s","case":"old case","destination":"%s","file":"%s","fragment":"%s"}]' \
    "$1" "$2" "$3" "$4"
}

quote_json() { # quote
  printf '[{"change":"dropped","quote":"%s"}]' "$1"
}

check_spec() {
  run node "$CLI" --fixes "$FIXES" --findings "$FINDINGS" --pre "$PRE" --post "$POST" "$@"
}

has_output() { grep -qF -- "$1" <<<"$output"; }

# A SPEC whose other-kind behavior carries a case the tests remove.
write_pre() {
  cat >"$PRE" <<'SPEC'
---
spec_id: X
clarifications:
  deferred:
    - "Deferred: the export limit stays undecided until review"
---
# X

## Behaviors

- **B1** (access): Only the owner may open the account settings page.
  - Case: a member opens another member's settings page -> the server answers 403 with the text Forbidden.
  - Case: the owner opens their own settings page -> the page shows Settings.
- **B3** (other): The list page greets a guest.
  - Case: a guest opens the list with no items -> the page shows the text Nothing here yet.
  - Case: a guest opens a list with items -> the page shows each item title.

## Notes

The empty list always shows the text Nothing here yet to guests.
SPEC
}

# The post-fix SPEC: the pre-fix SPEC with the lines holding $1 removed.
write_post_without() {
  grep -vF -- "$1" "$PRE" >"$POST"
}

REMOVED_OTHER_CASE="a guest opens the list with no items"
OTHER_FRAGMENT="shows the text Nothing here yet to guests"
OTHER_QUOTE="a guest opens the list with no items"

setup_removed_other_case() {
  write_pre
  write_post_without "$REMOVED_OTHER_CASE"
  write_findings TST-001 SEC-001
}

@test "drop-check refuses a dropped case whose destination is missing, elsewhere, short, absent, or a requirements fragment without a SPEC pointer, and resolves SPEC.md to the post-fix draft" {
  setup_removed_other_case

  write_fixes "$(quote_json "$OTHER_QUOTE")" "$(drop_json B3 still-stated SPEC.md "$OTHER_FRAGMENT")"
  check_spec
  [ "$status" -eq 0 ]

  write_fixes "$(quote_json "$OTHER_QUOTE")" '[{"behavior":"B3","case":"old case"}]'
  check_spec
  [ "$status" -eq 1 ]
  has_output "drop-check: TST-001" || return 1
  has_output "no destination" || return 1

  write_fixes "$(quote_json "$OTHER_QUOTE")" "$(drop_json B3 still-stated OTHER.md "$OTHER_FRAGMENT")"
  check_spec
  [ "$status" -eq 1 ]
  has_output "drop-check: TST-001" || return 1
  has_output "not a valid destination file" || return 1

  write_fixes "$(quote_json "$OTHER_QUOTE")" "$(drop_json B3 still-stated SPEC.md "the text Nothing here yet")"
  check_spec
  [ "$status" -eq 1 ]
  has_output "drop-check: TST-001" || return 1
  has_output "under 6 words" || return 1

  write_fixes "$(quote_json "$OTHER_QUOTE")" "$(drop_json B3 still-stated SPEC.md "shows the text Missing here yet to guests")"
  check_spec
  [ "$status" -eq 1 ]
  has_output "drop-check: TST-001" || return 1
  has_output "not in SPEC.md" || return 1

  # A fragment wrapped across lines in the file still counts.
  printf '\nThe empty list always shows the\ntext  Nothing   here yet to guests.\n' >>"$POST"
  write_fixes "$(quote_json "$OTHER_QUOTE")" "$(drop_json B3 still-stated SPEC.md "always shows the text Nothing here yet")"
  check_spec
  [ "$status" -eq 0 ]

  setup_removed_other_case
  # The fragment sits in no SPEC text, only in the requirements file.
  printf '# Requirements: X\n\n## Brief\n\nThe empty list must always say Nothing here yet to guests.\n\n## Clarify\n\n### Q1. What does a guest see?\n\nAnswered by: the user\n\nA guest sees the greeting.\n' >"$REQUIREMENTS"
  local fragment="The empty list must always say Nothing here yet"
  write_fixes "$(quote_json "$OTHER_QUOTE")" "$(drop_json B3 still-stated SPEC.md "$fragment")"

  check_spec --requirements "$REQUIREMENTS"
  [ "$status" -eq 1 ]
  has_output "drop-check: TST-001" || return 1

  printf '\nSee REQUIREMENTS.md § Clarify for the questions.\n' >>"$POST"
  check_spec --requirements "$REQUIREMENTS"
  [ "$status" -eq 1 ]

  printf '\nThe greeting is stated in REQUIREMENTS.md § Brief.\n' >>"$POST"
  check_spec --requirements "$REQUIREMENTS"
  [ "$status" -eq 0 ]

  # The requirements file itself is never a destination.
  write_fixes "$(quote_json "$OTHER_QUOTE")" "$(drop_json B3 still-stated REQUIREMENTS.md "$fragment")"
  check_spec --requirements "$REQUIREMENTS" --dest "$POST" --dest "$REQUIREMENTS"
  [ "$status" -eq 1 ]
  has_output "not a valid destination file" || return 1

  # A question pointer matches by its number, not a longer number.
  printf '# R\n\n### Q1. A question\n\nThe guest greeting must stay exactly as stated here.\n' >"$REQUIREMENTS"
  write_fixes "$(quote_json "$OTHER_QUOTE")" "$(drop_json B3 still-stated SPEC.md "The guest greeting must stay exactly as stated")"
  printf '\nSee REQUIREMENTS.md § Q10 only.\n' >>"$POST"
  check_spec --requirements "$REQUIREMENTS"
  [ "$status" -eq 1 ]
  printf '\nSee REQUIREMENTS.md § Q1 for the greeting.\n' >>"$POST"
  check_spec --requirements "$REQUIREMENTS"
  [ "$status" -eq 0 ]

  setup_removed_other_case
  mv "$POST" "$WORK/post/draft-SPEC-001.md"
  write_fixes "$(quote_json "$OTHER_QUOTE")" "$(drop_json B3 still-stated SPEC.md "$OTHER_FRAGMENT")"
  run node "$CLI" --fixes "$FIXES" --findings "$FINDINGS" --pre "$PRE" --post "$WORK/post/draft-SPEC-001.md"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }

  write_fixes "$(quote_json "$OTHER_QUOTE")" "$(drop_json B3 still-stated OTHER.md "$OTHER_FRAGMENT")"
  run node "$CLI" --fixes "$FIXES" --findings "$FINDINGS" --pre "$PRE" --post "$WORK/post/draft-SPEC-001.md"
  [ "$status" -eq 1 ]
  has_output "not a valid destination file" || return 1
}

@test "drop-check refuses a changed behavior line no fix quotes and a removed case with no drops entry for its behavior, and accepts the traced twin" {
  setup_removed_other_case
  write_fixes '[]' '[]'
  check_spec
  [ "$status" -eq 1 ]
  has_output "a guest opens the list with no items" || return 1

  write_fixes "$(quote_json "$OTHER_QUOTE")" "$(drop_json B3 still-stated SPEC.md "$OTHER_FRAGMENT")"
  check_spec
  [ "$status" -eq 0 ]

  # A quote under six words does not count.
  write_fixes "$(quote_json "a guest opens the list")" '[]'
  check_spec
  [ "$status" -eq 1 ]

  # A reworded line is a change too.
  sed 's/the page shows each item title/the page shows every item name/' "$PRE" >"$POST"
  write_fixes '[]' '[]'
  check_spec
  [ "$status" -eq 1 ]
  has_output "the page shows each item title" || return 1

  write_fixes "$(quote_json "a guest opens a list with items")" '[]'
  check_spec
  [ "$status" -eq 0 ]

  # An unchanged SPEC with no edits.
  cp "$PRE" "$POST"
  write_fixes '[]' '[]'
  check_spec
  [ "$status" -eq 0 ]

  setup_removed_other_case
  write_fixes "$(quote_json "$OTHER_QUOTE")" '[]'
  check_spec
  [ "$status" -eq 1 ]
  has_output "untraced drop: B3 lost 1 case(s)" || return 1

  # A drop labeled with another behavior does not account for B3.
  write_fixes "$(quote_json "$OTHER_QUOTE")" "$(drop_json B1 still-stated SPEC.md "$OTHER_FRAGMENT")"
  check_spec
  [ "$status" -eq 1 ]
  has_output "untraced drop: B3" || return 1

  write_fixes "$(quote_json "$OTHER_QUOTE")" "$(drop_json B3 still-stated SPEC.md "$OTHER_FRAGMENT")"
  check_spec
  [ "$status" -eq 0 ]
}

@test "refuses a missing, duplicated or extra finding id" {
  write_pre
  cp "$PRE" "$POST"
  write_findings TST-001 SEC-001

  write_fixes '[]' '[]'
  check_spec
  [ "$status" -eq 0 ]

  printf '{"fixes":[{"finding":"TST-001","route":"rejected"}]}\n' >"$FIXES"
  check_spec
  [ "$status" -eq 1 ]
  has_output "drop-check: SEC-001" || return 1

  printf '{"fixes":[{"finding":"TST-001","route":"rejected"},{"finding":"TST-001","route":"rejected"},{"finding":"SEC-001","route":"rejected"}]}\n' >"$FIXES"
  check_spec
  [ "$status" -eq 1 ]
  has_output "drop-check: TST-001: finding listed 2 times" || return 1

  printf '{"fixes":[{"finding":"TST-001","route":"rejected"},{"finding":"SEC-001","route":"rejected"},{"finding":"COV-009","route":"rejected"}]}\n' >"$FIXES"
  check_spec
  [ "$status" -eq 1 ]
  has_output "drop-check: COV-009" || return 1
}

# One drop per behavior of the six-behavior SPEC: $1 takes destination $2,
# file $3 and fragment $4; every other behavior is still-stated.
drops_for_all() {
  local entries="" id
  for id in B1 B2 B3 B4 B5 B6; do
    if [ "$id" = "$1" ]; then
      entries="$entries{\"behavior\":\"$id\",\"case\":\"old case\",\"destination\":\"$2\",\"file\":\"$3\",\"fragment\":\"$4\"},"
    else
      entries="$entries{\"behavior\":\"$id\",\"case\":\"old case\",\"destination\":\"still-stated\",\"file\":\"SPEC.md\",\"fragment\":\"still refused with 403 Forbidden by the server\"},"
    fi
  done
  printf '[%s]' "${entries%,}"
}

@test "a security or refusal case resolves only to still stated, restored, a narrower refusal or deferred" {
  cat >"$PRE" <<'SPEC'
---
spec_id: X
clarifications:
  deferred:
    - "Deferred: the export limit stays undecided until review"
---
## Behaviors

- **B1** (access): Only the owner opens settings.
  - Case: B1 first case: the owner opens settings -> the page shows Settings.
  - Case: B1 second case: a visitor repeats the request -> the answer is 403 Forbidden.
- **B2** (data-loss): Deleting needs a confirmation.
  - Case: B2 first case: the owner confirms -> the record is gone.
  - Case: B2 second case: the owner cancels twice -> the record stays.
- **B3** (other): The list greets a guest.
  - Case: B3 first case: a guest opens the list -> the page shows the greeting.
  - Case: B3 second case: a guest opens the list twice -> the page shows the greeting again.
- **B4** (forgery): The server takes the target from the URL.
  - Case: B4 first case: a post names the URL id -> that record changes.
  - Case: B4 second case: a post names another id in the body -> the body id is ignored.
- **B5** (secret): The token never reaches the page.
  - Case: B5 first case: the page renders -> no token appears.
  - Case: B5 second case: the page errors -> no token appears.
- **B6** (refusal): A closed account cannot sign in.
  - Case: B6 first case: a closed account signs in -> the answer is 403.
  - Case: B6 second case: a closed account retries -> the answer is 403.

## Notes

Every repeated request is still refused with 403 Forbidden by the server.
SPEC
  grep -v 'second case' "$PRE" >"$POST"
  write_findings TST-001 SEC-001
  local edits="["
  edits="$edits{\"change\":\"dropped\",\"quote\":\"B1 second case: a visitor repeats the\"},"
  edits="$edits{\"change\":\"dropped\",\"quote\":\"B2 second case: the owner cancels twice\"},"
  edits="$edits{\"change\":\"dropped\",\"quote\":\"B3 second case: a guest opens the\"},"
  edits="$edits{\"change\":\"dropped\",\"quote\":\"B4 second case: a post names another\"},"
  edits="$edits{\"change\":\"dropped\",\"quote\":\"B5 second case: the page errors ->\"},"
  edits="$edits{\"change\":\"dropped\",\"quote\":\"B6 second case: a closed account retries\"}]"
  local fragment="still refused with 403 Forbidden by the server"
  local deferred="the export limit stays undecided until review"
  local behavior destination

  for behavior in B1 B4 B5 B6; do
    for destination in out-of-scope corrected-value; do
      write_fixes "$edits" "$(drops_for_all "$behavior" "$destination" SPEC.md "$fragment")"
      check_spec
      [ "$status" -eq 1 ]
      has_output "drop-check: TST-001: $behavior" || return 1
    done
    for destination in still-stated restored refusal; do
      write_fixes "$edits" "$(drops_for_all "$behavior" "$destination" SPEC.md "$fragment")"
      check_spec
      [ "$status" -eq 0 ] || { echo "$behavior $destination: $output"; return 1; }
    done
    write_fixes "$edits" "$(drops_for_all "$behavior" deferred SPEC.md "$deferred")"
    check_spec
    [ "$status" -eq 0 ] || { echo "$behavior deferred: $output"; return 1; }
    # A deferred fragment that sits outside clarifications.deferred is refused.
    write_fixes "$edits" "$(drops_for_all "$behavior" deferred SPEC.md "$fragment")"
    check_spec
    [ "$status" -eq 1 ]
    has_output "clarifications.deferred" || return 1
  done

  for behavior in B2 B3; do
    write_fixes "$edits" "$(drops_for_all "$behavior" out-of-scope SPEC.md "$fragment")"
    check_spec
    [ "$status" -eq 0 ] || { echo "$behavior out-of-scope: $output"; return 1; }
  done
}

# bats test_tags=protected
@test "feature-dropped resolves a security case only when its behavior is gone and a decision record that predates the fix holds the fragment" {
  cat >"$PRE" <<'SPEC'
---
spec_id: X
---
## Behaviors

- **B1** (access): Only the owner opens settings.
  - Case: B1 first case: the owner opens settings -> the page shows Settings.
  - Case: B1 second case: a visitor repeats the request -> the answer is 403 Forbidden.
- **B2** (other): The list greets a guest.
  - Case: B2 first case: a guest opens the list -> the page shows the greeting.

## Notes

The settings page was removed from the product entirely.

## Amendments to an order

The maintainer decided the export page and its owner check are dropped from this build.

## Build amendment

### Settings page

The maintainer decided the settings page and its owner check are dropped from this build.

## Open questions

Nothing is open about the export format.
SPEC
  # The whole feature goes: B1 and both of its cases.
  grep -v 'B1' "$PRE" >"$POST"
  write_findings TST-001 SEC-001
  local edits='[{"change":"dropped","quote":"B1 first case: the owner opens settings"},{"change":"dropped","quote":"B1 second case: a visitor repeats the"},{"change":"dropped","quote":"(access): Only the owner opens settings."}]'
  local record="the settings page and its owner check are dropped from this build"

  write_fixes "$edits" "$(two_drops "$record")"
  check_spec
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }

  local fragment
  for fragment in \
    "The settings page was removed from the product entirely" \
    "the export page and its owner check are dropped from this build" \
    "Nothing is open about the export format"; do
    write_fixes "$edits" "$(two_drops "$fragment")"
    check_spec
    [ "$status" -eq 1 ]
    has_output "not in a decision record that predates" || return 1
  done

  write_fixes "$edits" "$(two_drops "owner check are dropped")"
  check_spec
  [ "$status" -eq 1 ]
  has_output "fragment is under 6 words" || return 1

  # The other destinations stay closed to a security case.
  write_fixes "$edits" "$(drop_json B1 out-of-scope SPEC.md "$record")"
  check_spec
  [ "$status" -eq 1 ]
  has_output "cannot resolve to out-of-scope" || return 1
}

two_drops() { # fragment
  printf '[{"behavior":"B1","case":"first","destination":"feature-dropped","file":"SPEC.md","fragment":"%s"},{"behavior":"B1","case":"second","destination":"feature-dropped","file":"SPEC.md","fragment":"%s"}]' "$1" "$1"
}

# bats test_tags=protected
@test "feature-dropped refuses a security case whose behavior is still in the post-fix SPEC" {
  cat >"$PRE" <<'SPEC'
---
spec_id: X
---
## Behaviors

- **B1** (access): Only the owner opens settings.
  - Case: B1 first case: the owner opens settings -> the page shows Settings.
  - Case: B1 second case: a visitor repeats the request -> the answer is 403 Forbidden.

## Build amendment

The maintainer decided the settings page and its owner check are dropped from this build.
SPEC
  grep -v 'B1 second case' "$PRE" >"$POST"
  write_findings TST-001 SEC-001
  write_fixes "$(quote_json "B1 second case: a visitor repeats the")" \
    "$(drop_json B1 feature-dropped SPEC.md "the settings page and its owner check are dropped from this build")"
  check_spec
  [ "$status" -eq 1 ]
  has_output "still a behavior of the post-fix SPEC" || return 1
}

# bats test_tags=protected
@test "feature-dropped refuses a decision record the fixer wrote in the same pass" {
  cat >"$PRE" <<'SPEC'
---
spec_id: X
---
## Behaviors

- **B1** (access): Only the owner opens settings.
  - Case: B1 first case: the owner opens settings -> the page shows Settings.
SPEC
  cat >"$POST" <<'SPEC'
---
spec_id: X
---
## Behaviors

## Build amendment

The maintainer decided the settings page and its owner check are dropped from this build.
SPEC
  write_findings TST-001 SEC-001
  write_fixes "$(quote_json "Only the owner opens settings.")" \
    "$(drop_json B1 feature-dropped SPEC.md "the settings page and its owner check are dropped from this build")"
  check_spec
  [ "$status" -eq 1 ]
  has_output "not in a decision record that predates the fix" || return 1
}

@test "feature-dropped accepts the fragment under each decision-record heading spelling" {
  local heading
  for heading in "Decision" "Decisions" "Decisions taken" "Decisions taken here" \
    "Amendment" "Amendments" "Build amendment" "Spec amendment"; do
    cat >"$PRE" <<SPEC
---
spec_id: X
---
## Behaviors

- **B1** (access): Only the owner opens settings.
  - Case: B1 first case: the owner opens settings -> the page shows Settings.

## $heading

The maintainer decided the settings page and its owner check are dropped from this build.
SPEC
    grep -v 'B1' "$PRE" >"$POST"
    write_findings TST-001 SEC-001
    write_fixes '[{"change":"dropped","quote":"B1 first case: the owner opens settings"},{"change":"dropped","quote":"(access): Only the owner opens settings."}]' \
      "$(drop_json B1 feature-dropped SPEC.md "the settings page and its owner check are dropped from this build")"
    check_spec
    [ "$status" -eq 0 ] || { echo "$heading: $output"; return 1; }
  done
}

make_plan_dirs() {
  PLAN_PRE="$WORK/plan-pre"
  PLAN_POST="$WORK/plan-post"
  mkdir -p "$PLAN_PRE" "$PLAN_POST"
  cat >"$PLAN_PRE/task-a.md" <<'TASK'
# task-a

## Context

- A bullet outside the acceptance section may change freely.

## Acceptance criteria

- The server answers 403 with the text Forbidden for another member's page.
- The page shows Settings to the owner.
TASK
  cp "$PLAN_PRE/task-a.md" "$PLAN_POST/task-a.md"
  printf '# Plan\n\nThe server answers 403 with the text Forbidden everywhere.\n' >"$PLAN_PRE/README.md"
  cp "$PLAN_PRE/README.md" "$PLAN_POST/README.md"
  printf '# Orchestrator\n\nThe server answers 403 with the text Forbidden in every run.\n' >"$PLAN_POST/ORCHESTRATOR.md"
}

check_plan() {
  run node "$CLI" --mode plan --fixes "$FIXES" --findings "$FINDINGS" --pre "$PLAN_PRE" --post "$PLAN_POST"
}

write_plan_spec() { # heading-line the record sits under
  PLAN_SPEC="$WORK/plan-spec/SPEC.md"
  mkdir -p "$WORK/plan-spec"
  cat >"$PLAN_SPEC" <<SPEC
---
spec_id: X
---
## Behaviors

- **B1** (access): Only the owner opens settings.
  - Case: B1 first case: the owner opens settings -> the page shows Settings.

$1

The maintainer decided the settings page and its owner check are dropped from this build.
SPEC
}

plan_drop_fixes() { # fragment
  printf '{"fixes":[{"finding":"DP-001","route":"plan","edits":%s,"drops":%s}]}\n' \
    "$(quote_json "The server answers 403 with the text Forbidden")" \
    "$(drop_json B1 feature-dropped SPEC.md "$1")" >"$FIXES"
}

# bats test_tags=protected
@test "plan mode feature-dropped passes for a strict-kind behavior the SPEC still states when a decision record holds the fragment, and refuses one that does not" {
  make_plan_dirs
  grep -vF "answers 403" "$PLAN_PRE/task-a.md" >"$PLAN_POST/task-a.md"
  write_findings DP-001
  write_plan_spec "## Build amendment"
  local record="the settings page and its owner check are dropped from this build"

  plan_drop_fixes "$record"
  run node "$CLI" --mode plan --fixes "$FIXES" --findings "$FINDINGS" --pre "$PLAN_PRE" --post "$PLAN_POST" --dest "$PLAN_SPEC"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }

  # A fragment outside every decision record is refused.
  plan_drop_fixes "The server answers 403 with the text Forbidden"
  run node "$CLI" --mode plan --fixes "$FIXES" --findings "$FINDINGS" --pre "$PLAN_PRE" --post "$PLAN_POST" --dest "$PLAN_SPEC"
  [ "$status" -eq 1 ]
  has_output "not in a decision record that predates the fix" || return 1

  # The record under a heading that is no decision heading is refused.
  write_plan_spec "## Notes"
  plan_drop_fixes "$record"
  run node "$CLI" --mode plan --fixes "$FIXES" --findings "$FINDINGS" --pre "$PLAN_PRE" --post "$PLAN_POST" --dest "$PLAN_SPEC"
  [ "$status" -eq 1 ]
  has_output "not in a decision record that predates the fix" || return 1
}

@test "plan mode refuses an untraced change to or removal of a numbered acceptance criterion" {
  make_plan_dirs
  printf '# task-a\n\n## Acceptance criteria\n\n1. The server answers 403 with the text Forbidden for another\n   member'"'"'s page.\n2) The page shows Settings to the owner.\n' >"$PLAN_PRE/task-a.md"
  cp "$PLAN_PRE/task-a.md" "$PLAN_POST/task-a.md"
  write_findings DP-001
  printf '{"fixes":[{"finding":"DP-001","route":"rejected"}]}\n' >"$FIXES"
  check_plan
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }

  sed -i.bak "s/for another/for any other/; s/to the owner/to everyone/" "$PLAN_POST/task-a.md"
  check_plan
  [ "$status" -eq 1 ]
  has_output "member's page" || return 1
  has_output "Settings to the owner" || return 1

  grep -vF "Settings to the owner" "$PLAN_PRE/task-a.md" >"$PLAN_POST/task-a.md"
  check_plan
  [ "$status" -eq 1 ]
  has_output "untraced drop: 1 acceptance criteria were removed" || return 1
}

@test "plan mode refuses only the removal when a numbered list is renumbered by it" {
  make_plan_dirs
  printf '# task-a\n\n## Acceptance criteria\n\n1. The server answers 403 with the text Forbidden for another member.\n2. The page shows Settings to the owner.\n3. The page shows Billing to the owner.\n' >"$PLAN_PRE/task-a.md"
  printf '# task-a\n\n## Acceptance criteria\n\n1. The page shows Settings to the owner.\n2. The page shows Billing to the owner.\n' >"$PLAN_POST/task-a.md"
  write_findings DP-001
  printf '{"fixes":[{"finding":"DP-001","route":"rejected"}]}\n' >"$FIXES"
  check_plan
  [ "$status" -eq 1 ]
  has_output "untraced drop: 1 acceptance criteria were removed" || return 1
  ! has_output "Settings to the owner" || return 1
  ! has_output "Billing to the owner" || return 1
}

@test "every spec and plan lens prefix is accepted and an unknown one refused" {
  write_pre
  cp "$PRE" "$POST"
  local prefix
  for prefix in TST COV SEC BRIEF-FIT FG A11Y MIG PERF DOC DP CG; do
    write_findings "$prefix-001"
    printf '{"fixes":[{"finding":"%s-001","route":"rejected"}]}\n' "$prefix" >"$FIXES"
    check_spec
    [ "$status" -eq 0 ] || { echo "$prefix: $output"; return 1; }
  done

  write_findings RT-001
  printf '{"fixes":[{"finding":"RT-001","route":"rejected"}]}\n' >"$FIXES"
  check_spec
  [ "$status" -eq 1 ]
  has_output "drop-check: RT-001: id prefix" || return 1

  # Plan mode takes a destination in the plan README or a task doc.
  make_plan_dirs
  write_findings DP-001
  printf '{"fixes":[{"finding":"DP-001","route":"plan","drops":%s}]}\n' \
    "$(drop_json AC1 still-stated README.md "answers 403 with the text Forbidden everywhere")" >"$FIXES"
  check_plan
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

@test "plan mode refuses an untraced acceptance-criterion change, a drop outside the plan documents and a removed bullet no drops entry accounts for" {
  make_plan_dirs
  write_findings DP-001 CG-001
  local structural='{"finding":"CG-001","route":"plan"}'
  local fragment="answers 403 with the text Forbidden everywhere"

  # An untouched plan with a structural finding and no edits.
  printf '{"fixes":[{"finding":"DP-001","route":"rejected"},%s]}\n' "$structural" >"$FIXES"
  check_plan
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }

  # A reworded acceptance bullet; a change outside the section is free.
  sed -i.bak "s/for another member's page/for any other member/; s/change freely/change quietly/" "$PLAN_POST/task-a.md"
  check_plan
  [ "$status" -eq 1 ]
  has_output "for another member's page" || return 1
  has_output "change freely" && return 1

  printf '{"fixes":[{"finding":"DP-001","route":"plan","edits":%s},%s]}\n' \
    "$(quote_json "The server answers 403 with the text Forbidden")" "$structural" >"$FIXES"
  check_plan
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }

  # A drop to the orchestrator is refused; the same drop to the README is not.
  printf '{"fixes":[{"finding":"DP-001","route":"plan","edits":%s,"drops":%s},%s]}\n' \
    "$(quote_json "The server answers 403 with the text Forbidden")" \
    "$(drop_json AC1 still-stated ORCHESTRATOR.md "answers 403 with the text Forbidden in every run")" \
    "$structural" >"$FIXES"
  check_plan
  [ "$status" -eq 1 ]
  has_output "drop-check: DP-001" || return 1
  has_output "not a valid destination file" || return 1

  printf '{"fixes":[{"finding":"DP-001","route":"plan","edits":%s,"drops":%s},%s]}\n' \
    "$(quote_json "The server answers 403 with the text Forbidden")" \
    "$(drop_json AC1 still-stated README.md "$fragment")" \
    "$structural" >"$FIXES"
  check_plan
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }

  # A removed task doc takes its bullets with it, so each needs a quote.
  rm "$PLAN_POST/task-a.md"
  check_plan
  [ "$status" -eq 1 ]
  has_output "The page shows Settings to the owner" || return 1

  make_plan_dirs
  write_findings DP-001
  grep -vF "The page shows Settings to the owner" "$PLAN_PRE/task-a.md" >"$PLAN_POST/task-a.md"
  printf '{"fixes":[{"finding":"DP-001","route":"plan","edits":%s}]}\n' \
    "$(quote_json "The page shows Settings to the owner")" >"$FIXES"
  check_plan
  [ "$status" -eq 1 ]
  has_output "untraced drop: 1 acceptance criteria were removed" || return 1

  printf '{"fixes":[{"finding":"DP-001","route":"plan","edits":%s,"drops":%s}]}\n' \
    "$(quote_json "The page shows Settings to the owner")" \
    "$(drop_json AC2 still-stated README.md "answers 403 with the text Forbidden everywhere")" >"$FIXES"
  check_plan
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}

