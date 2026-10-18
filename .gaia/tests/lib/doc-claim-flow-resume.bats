#!/usr/bin/env bats
#
# Doc-conformance suite for the Step 11 section of the update claim flow
# (.claude/skills/update-gaia/references/claim-flow.md).
#
# What it guards. A run whose update commit already exists on the branch goes
# straight to Step 11 and never sets CLAIM_PR. Without an adoption step the
# open claim PR keeps its placeholder body and the statusline cache keeps the
# claim. Invariants over the Step 11 section only:
#   1. an adoption step exists, keyed on CLAIM_PR being unset;
#   2. it matches the claim by headRefName against the branch and by the
#      current login, and sets CLAIM_PR from the match;
#   3. it falls through unclaimed on exit 3 or no match and never closes,
#      creates or forces anything;
#   4. it appears before the body rewrite and the drop-claim call.
#
# Section-scoped: every assertion runs over the Step 11 body, so a phrase
# surviving in the claim check cannot green a Step 11 that dropped it. Each
# pin has a red twin that mutates a scratch copy and expects the pin to fail.
#
# Assertion style: .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  CLAIM_FLOW="$REPO_ROOT/.claude/skills/update-gaia/references/claim-flow.md"
}

# step11_body <file>: the Step 11 section, heading to the next H2 or EOF.
step11_body() {
  awk '
    /^## Step 11/ { on = 1; print; next }
    on && /^## / { exit }
    on { print }
  ' "$1"
}

pin_adoption_present() {
  local body
  body="$(step11_body "$1")"
  grep -qF -- 'Adopt an own open claim when `CLAIM_PR` is unset' <<<"$body" || return 1
  grep -qF -- 'set `CLAIM_PR` to its number' <<<"$body" || return 1
}

pin_match_keys() {
  local body
  body="$(step11_body "$1")"
  grep -qF -- '`headRefName` equals `<branch>`' <<<"$body" || return 1
  grep -qF -- 'login equals the current login' <<<"$body" || return 1
  grep -qF -- 'login --tree <main checkout path>' <<<"$body" || return 1
}

pin_falls_through() {
  local body
  body="$(step11_body "$1")"
  grep -qF -- 'exits 3, or no line matches, `CLAIM_PR` stays unset and the run continues unclaimed' <<<"$body" || return 1
  grep -qF -- 'Nothing here closes, creates or forces anything' <<<"$body" || return 1
}

# pin_order <file>: adoption precedes the body rewrite and the drop-claim call.
pin_order() {
  local body adopt rewrite drop
  body="$(step11_body "$1")"
  adopt="$(grep -nF -- 'Adopt an own open claim' <<<"$body" | head -n 1 | cut -d: -f1)"
  rewrite="$(grep -nF -- 'gh pr edit <CLAIM_PR>' <<<"$body" | head -n 1 | cut -d: -f1)"
  drop="$(grep -nF -- '--drop-claim <CLAIM_PR>' <<<"$body" | head -n 1 | cut -d: -f1)"
  [ -n "$adopt" ] && [ -n "$rewrite" ] && [ -n "$drop" ] || return 1
  [ "$adopt" -lt "$rewrite" ] && [ "$adopt" -lt "$drop" ]
}

# mutate <needle> <out>: copy the doc without the lines containing needle.
mutate() {
  grep -vF -- "$1" "$CLAIM_FLOW" >"$2"
}

@test "Step 11 section exists and is non-empty" {
  [ -n "$(step11_body "$CLAIM_FLOW")" ]
}

@test "Step 11 adopts an own open claim when CLAIM_PR is unset" {
  pin_adoption_present "$CLAIM_FLOW"
}

@test "red twin: adoption removed turns the presence pin red" {
  mutate 'Adopt an own open claim' "$BATS_TEST_TMPDIR/m.md"
  run pin_adoption_present "$BATS_TEST_TMPDIR/m.md"
  [ "$status" -ne 0 ]
}

@test "adoption matches on headRefName against the branch and on the current login" {
  pin_match_keys "$CLAIM_FLOW"
}

@test "red twin: dropping the match keys turns the match pin red" {
  mutate 'Adopt an own open claim' "$BATS_TEST_TMPDIR/m.md"
  run pin_match_keys "$BATS_TEST_TMPDIR/m.md"
  [ "$status" -ne 0 ]
}

@test "adoption falls through unclaimed on exit 3 or no match and never closes or creates" {
  pin_falls_through "$CLAIM_FLOW"
}

@test "red twin: dropping the fall-through turns the fall-through pin red" {
  mutate 'Adopt an own open claim' "$BATS_TEST_TMPDIR/m.md"
  run pin_falls_through "$BATS_TEST_TMPDIR/m.md"
  [ "$status" -ne 0 ]
}

@test "adoption precedes the body rewrite and the drop-claim call" {
  pin_order "$CLAIM_FLOW"
}

@test "red twin: adoption moved after the drop-claim call turns the order pin red" {
  local scratch="$BATS_TEST_TMPDIR/m.md" line
  line="$(grep -F -- 'Adopt an own open claim' "$CLAIM_FLOW")"
  mutate 'Adopt an own open claim' "$scratch"
  printf '%s\n' "$line" >>"$scratch"
  run pin_order "$scratch"
  [ "$status" -ne 0 ]
}
