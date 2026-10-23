#!/usr/bin/env bats
#
# Doc-conformance suite for the two locale runbooks under
# frontend/.claude/instructions/ and the /gaia-init step that drives them.
# add-locale's Step 2 is the only writer that registers a locale in
# frontend/app/languages/index.ts; `gaia init configure-i18n` only drops the
# locales the user did not pick. /gaia-init runs add-locale's Steps 1 to 7 for
# every locale, re-runs configure-i18n so the template locale is dropped once a
# picked one is registered, and verifies once after that, so the verify sees
# the final index. add-locale.md stays in place after a run so a language can
# be added after init, and remove-i18n.md deletes both runbooks once i18n is
# gone.

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
# to 7 per locale, re-runs configure-i18n after the last, then Step 8 once, and
# never executes the whole runbook per locale.
verifies_once_after_last() {
  local body rerun_line verify_line
  body="$(init_step_four "$1")"
  [ -n "$body" ] || return 1
  grep -qF -- 'execute Steps 1 to 7' <<<"$body" || return 1
  rerun_line="$(grep -nF -- 'After the last locale, re-run Step 3'"'"'s `configure-i18n` line' <<<"$body" | head -n 1 | cut -d: -f1)"
  verify_line="$(grep -nF -- 'Run Step 8 (verify) once' <<<"$body" | head -n 1 | cut -d: -f1)"
  [ -n "$rerun_line" ] && [ -n "$verify_line" ] || return 1
  [ "$rerun_line" -lt "$verify_line" ] || return 1
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
  sed 's/Run Step 8 (verify) once/Execute every step in the substituted instruction/' "$INIT_MD" >"$scratch"
  cmp -s "$INIT_MD" "$scratch" && return 1
  run verifies_once_after_last "$scratch"
  [ "$status" -ne 0 ]
}

@test "the verify-once check fails on a scratch copy that skips the configure-i18n re-run" {
  local scratch="$BATS_TEST_TMPDIR/gaia-init.no-rerun.md"
  grep -vF -- 'After the last locale, re-run Step 3' "$INIT_MD" >"$scratch"
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
