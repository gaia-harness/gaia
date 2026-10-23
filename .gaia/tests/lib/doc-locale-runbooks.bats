#!/usr/bin/env bats
#
# Doc-conformance suite for the two locale runbooks under
# frontend/.claude/instructions/ and the /gaia-init step that drives them.
# `gaia init configure-i18n` registers every picked locale in
# frontend/app/languages/index.ts before any locale's language tree exists, so
# a verify run per locale fails typecheck on the next locale's missing import:
# /gaia-init must run add-locale's Steps 1 to 7 for every locale and verify once
# after the last. add-locale.md stays in place after a run so a language can be
# added after init, and remove-i18n.md deletes both runbooks once i18n is gone.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  INIT_MD="$REPO_ROOT/.claude/commands/gaia-init.md"
  ADD_LOCALE_MD="$REPO_ROOT/frontend/.claude/instructions/add-locale.md"
  REMOVE_I18N_MD="$REPO_ROOT/frontend/.claude/instructions/remove-i18n.md"
}

# init_step_four <file>: the body of the "## Step 4" section.
init_step_four() {
  awk '/^## Step 4:/{on=1; next} on && /^## /{exit} on' "$1"
}

# verifies_once_after_last <file>: rc 0 when Step 4 runs add-locale's Steps 1
# to 7 per locale and Step 8 once after the last, and never executes the whole
# runbook per locale.
verifies_once_after_last() {
  local body
  body="$(init_step_four "$1")"
  [ -n "$body" ] || return 1
  grep -qF -- 'execute Steps 1 to 7' <<<"$body" || return 1
  grep -qF -- 'After the last locale, run Step 8 (verify) once' <<<"$body" || return 1
  grep -qiF -- 'Execute every step in the substituted instruction' <<<"$body" && return 1
  true
}

# deletes_add_locale <file>: rc 0 when the file runs an rm naming add-locale.md.
deletes_add_locale() {
  grep -qE '^rm .*frontend/\.claude/instructions/add-locale\.md' "$1"
}

@test "gaia-init Step 4 verifies once after the last locale" {
  verifies_once_after_last "$INIT_MD"
}

@test "the verify-once check fails on a scratch copy that executes the whole runbook per locale" {
  local scratch="$BATS_TEST_TMPDIR/gaia-init.scratch.md"
  sed 's/After the last locale, run Step 8 (verify) once/Execute every step in the substituted instruction/' "$INIT_MD" >"$scratch"
  cmp -s "$INIT_MD" "$scratch" && return 1
  run verifies_once_after_last "$scratch"
  [ "$status" -ne 0 ]
}

@test "add-locale.md does not delete itself" {
  run deletes_add_locale "$ADD_LOCALE_MD"
  [ "$status" -ne 0 ]
}

@test "the self-delete check fires on a scratch copy that removes add-locale.md" {
  local scratch="$BATS_TEST_TMPDIR/add-locale.scratch.md"
  { cat "$ADD_LOCALE_MD"; printf '%s\n' 'rm frontend/.claude/instructions/add-locale.md'; } >"$scratch"
  deletes_add_locale "$scratch"
}

@test "remove-i18n.md deletes add-locale.md along with itself" {
  deletes_add_locale "$REMOVE_I18N_MD"
  grep -qE '^rm .*frontend/\.claude/instructions/remove-i18n\.md' "$REMOVE_I18N_MD"
}
