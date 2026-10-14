#!/usr/bin/env bats
#
# Doc-conformance suite for the prose that describes the audit loop's branch
# checkpoint outside the PR Merge Workflow page: the always-loaded rules, the
# `/gaia-debt` and `/gaia-codify` references, the audit agent text, and the
# hook and script inventories.
#
# What it guards. The checkpoint has two audiences with opposite instructions:
# an interactive run asks the human in-session, an unattended drain asks
# nothing and reports. Prose that drifts back to a continuation prompt, or
# that lets a drain ask, silently reopens the loop's old failure. Each case
# reads one line or one section by its own text, never by line number, and
# every forbidden phrase is checked inside the paragraph that owns the
# instruction so an unrelated mention elsewhere in the file cannot green it.
#
# Each target path reads through an env override that defaults to the real
# file, so a mutant copy proves a case can fail without touching the tree.
# Absence checks are written `positive && return 1` per
# .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  DEBT_MD="${DOC_AUDIT_LOOP_DEBT_MD:-$REPO_ROOT/.claude/skills/gaia/references/debt.md}"
  FRONTEND_AGENT="${DOC_AUDIT_LOOP_FRONTEND_AGENT:-$REPO_ROOT/.claude/agents/code-audit-frontend.md}"
  MEMBER_PROTOCOL="${DOC_AUDIT_LOOP_MEMBER_PROTOCOL:-$REPO_ROOT/.claude/hooks/lib/audit-member-protocol.md}"
}

# line_starting <file> <literal-prefix>
# Prints the first line of the file that starts with the literal prefix. The
# caller asserts it is non-empty, so a missing paragraph fails loudly.
line_starting() {
  awk -v want="$2" 'index($0, want) == 1 { print; exit }' "$1"
}

# --- UAT-011: the unattended checkpoint ending -----------------------------

@test "UAT-011: debt.md's checkpoint ending pushes, keeps the PR and claim, reports, and names the typed line" {
  paragraph="$(line_starting "$DEBT_MD" '- **A stop at the branch checkpoint**')"
  [ -n "$paragraph" ]
  grep -qF -- 'pushed' <<<"$paragraph"
  grep -qF -- 'the PR stays open' <<<"$paragraph"
  grep -qF -- '`in-progress` claim stays' <<<"$paragraph"
  grep -qF -- 'verdict' <<<"$paragraph"
  grep -qF -- 'per-round evidence' <<<"$paragraph"
  grep -qF -- 'recommendation' <<<"$paragraph"
  grep -qF -- 'audit-loop-eval.sh brief' <<<"$paragraph"
  grep -qF -- 'grant or accept line' <<<"$paragraph"
  grep -qF -- 'interactive session on that branch' <<<"$paragraph"
  grep -qF -- 'never grants itself rounds' <<<"$paragraph"
}

@test "UAT-011: debt.md's checkpoint ending neither asks nor emits a continuation prompt" {
  paragraph="$(line_starting "$DEBT_MD" '- **A stop at the branch checkpoint**')"
  [ -n "$paragraph" ]
  grep -qF -- 'AskUserQuestion' <<<"$paragraph" && return 1
  grep -qiF -- 'continuation prompt' <<<"$paragraph" && return 1
  true
}

@test "COV-010: debt.md's fix-round stop pushes nothing, keeps the PR and claim, and reports reason and paths" {
  paragraph="$(line_starting "$DEBT_MD" '- **A stop inside the fix round**')"
  [ -n "$paragraph" ]
  grep -qF -- 'third Quality Gate failure' <<<"$paragraph"
  grep -qF -- 'second verifier failure' <<<"$paragraph"
  grep -qF -- 'second consecutive fixer no-op' <<<"$paragraph"
  grep -qF -- 'Push nothing uncommitted' <<<"$paragraph"
  grep -qF -- 'leave the PR open' <<<"$paragraph"
  grep -qF -- 'keep the `in-progress` claim' <<<"$paragraph"
  grep -qF -- 'stop reason' <<<"$paragraph"
  grep -qF -- 'run-folder paths' <<<"$paragraph"
  grep -qF -- 'AskUserQuestion' <<<"$paragraph" && return 1
  grep -qiF -- 'continuation prompt' <<<"$paragraph" && return 1
  true
}

# --- UAT-029: /gaia-codify asks at the checkpoint --------------------------

# --- the always-loaded rules ------------------------------------------------

# --- wiki inventories -------------------------------------------------------

# --- COV-007: the fixer is not briefed from the ledger ---------------------

# The member-side ledger text lives once, in the shared member protocol's
# "Re-run carry-forward ledger" section, which every member definition points
# at; the frontend definition carries no copy of its own.

# --- the shared ledger is removed by the clearance writer, never a member ---
# One ledger serves every dispatched member, so a member deleting it on its own
# clean pass discards a co-dispatched member's open remaining[] entries
# (gaia-react/gaia#2416).

@test "the member protocol tells a member never to remove the shared re-run ledger itself" {
  grep -qF -- 'Never remove the ledger yourself' "$MEMBER_PROTOCOL"
  local surface
  for surface in "$MEMBER_PROTOCOL" "$FRONTEND_AGENT"; do
    grep -qE -- 'rm[[:space:]].*\.rerun\.json' "$surface" && return 1
    grep -qF -- 'Ledger cleanup' "$surface" && return 1
  done
  true
}
