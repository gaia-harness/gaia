#!/usr/bin/env bats
# doc-grep coverage for how a Code Audit Team member hands its findings array
# to the shared sidecar writer (`.gaia/scripts/audit-write-findings.sh`).
#
# The defect this pins: every member spec prescribed the call with a bare
# `--findings /path/to/findings.json` placeholder. `wiki/concepts/PR Merge
# Workflow.md` dispatches every member in parallel from one message, and
# members dispatched from one session share a scratchpad, so each converges on
# the same `findings.json`. The published path is per-member and per-audit-key
# and therefore looks right; the staging file is what the writer READS, so
# member A can publish member B's array under A's name, and a file left by an
# earlier round republishes as a fresh report. Both are silent: the sidecar is
# the report of record, and `audit-noop-detect.sh --findings` reads it to tell
# a real pass from a member whose report was lost, so the gate still greens.
# Observed live during a round on PR #1186, where the prose member found a
# stale staging file holding another member's findings.
#
# The fix is a staging directory no sibling can share, written fresh in the
# call before the writer. Each member stages into the scratch directory the
# protocol mints per invocation under `.gaia/local/cache/mutation-scratch/`
# (pinned in `doc-audit-mutation-scratch.bats`), so neither a co-dispatched
# member nor the same member in a concurrent audit picks the same file. Writing
# the file fresh with `printf` immediately before the writer is what keeps an
# earlier round's file from republishing.
#
# The stage is a `printf` redirect, and the writer a separate command, rather
# than a pipe, a heredoc, or the `Write` tool, because worktree isolation
# refuses each of those: a pipe feeding a program text that carries the token
# `git` (any finding path under `.github/` does), a heredoc outright (`this
# command is too complex to verify that it stays inside the worktree`), and
# `Write` into the scratch directory, which resolves into the main checkout
# through the `.gaia/local` symlink. On a pull request audited from a linked
# worktree each of those is unrunnable, and each member improvises a spelling of
# its own -- the drift the single-writer design exists to prevent.
#
# The single quotes around the payload are load-bearing rather than stylistic:
# finding text carries `$` tokens and backticks routinely (this suite's own
# subject matter is shell prose), and a double-quoted payload expands them
# before the writer ever validates the array.
#
# Nothing type-checks an agent spec and no runtime assertion fires when a
# prescribed command drifts, so this suite is the mechanism, following
# `doc-debt-query.bats` in this directory: grep for frozen literals,
# ground-truthed against the source text.
#
# No member carries a handshake of its own: each definition points at the
# shared protocol file `.claude/hooks/lib/audit-member-protocol.md`, which
# holds the one writer call. So the positive checks below walk SPECS, the
# files that prescribe the call (the protocol file, plus any definition that
# lost its pointer and so fails them), and every absence check walks ALL,
# SPECS plus the pointing definitions, so prose drifting back into a member is
# still caught.
#
# The roster comes from the `code-audit-*.md` glob rather than a hardcoded
# list, so a sixth member joins the guard by existing. The **first `@test`**
# pins the five known specs as a floor, and it is what keeps the rest of the
# suite honest: `setup()` asserts nothing, it builds the list and skips what it
# cannot read, so on an empty glob every per-spec loop below iterates zero
# times and reports `ok`. Do not delete or weaken that test to quiet a roster
# change; add the new member to it.
#
# Assertion style: .claude/rules/bats-assertions.md.

# bats file_tags=whole-tree

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  PROTOCOL_RELATIVE_PATH=".claude/hooks/lib/audit-member-protocol.md"

  SPECS=()
  DELEGATES=()
  for audited_file in "$ROOT"/.claude/agents/code-audit-*.md; do
    # `-s`, not `-f`: an empty file satisfies `-f` and then greens every
    # absence check below on nothing.
    [ -s "$audited_file" ] || continue
    if grep -qF -- "$PROTOCOL_RELATIVE_PATH" "$audited_file"; then
      DELEGATES+=("$audited_file")
    else
      SPECS+=("$audited_file")
    fi
  done
  [ -s "$ROOT/$PROTOCOL_RELATIVE_PATH" ] && SPECS+=("$ROOT/$PROTOCOL_RELATIVE_PATH")
  ALL=("${SPECS[@]}" "${DELEGATES[@]}")
}

# --- Group 1: the roster the rest of the suite walks -----------------------

@test "the glob resolves to at least the known Code Audit Team specs" {
  [ "${#ALL[@]}" -ge 5 ]
  for member in \
    code-audit-frontend \
    code-audit-github-workflows \
    code-audit-maintainer-node \
    code-audit-maintainer-shell \
    code-audit-shell; do
    [ -s "$ROOT/.claude/agents/${member}.md" ] || {
      echo "roster member ${member}.md is missing or empty; every per-spec loop here would skip it silently" >&2
      return 1
    }
  done
}

# --- Group 2: the prescribed call reads a member-private staged file ----------

@test "every findings invocation in every spec reads the member-private staged file" {
  # One rule, stated once: the flag appears only in the pinned form. Every line
  # mentioning `--findings` must be `--findings <scratch>/findings.json` and
  # nothing else, so stdin (`--findings -`), a fixed session-scratchpad path
  # (`--findings /tmp/x.json`), a revived heredoc, and prose that hands the
  # writer some other path all fail the same way, without a second check
  # enumerating argument shapes. Anchored end to end, so a line carrying the
  # pinned form and then more (a redirect, a heredoc opener) fails too.
  #
  # The offenders check runs FIRST so a drifted spec is reported by its
  # offending line rather than as "prescribes no sidecar write at all".
  for audited_file in "${ALL[@]}"; do
    local offenders
    offenders="$(grep -n -- '--findings' "$audited_file" | grep -vE -- '^[0-9]+:[[:space:]]*--findings <scratch>/findings\.json[[:space:]]*$' || true)"
    [ -z "$offenders" ] || {
      echo "$audited_file: --findings appears outside the pinned staged-file form: $offenders" >&2
      return 1
    }
  done
  for audited_file in "${SPECS[@]}"; do
    grep -qE -- '^[[:space:]]*--findings <scratch>/findings\.json[[:space:]]*$' "$audited_file" || {
      echo "$audited_file carries no --findings line of any shape, so it prescribes no sidecar write at all" >&2
      return 1
    }
  done
}

# --- Group 3: the producer that stages the file, paired with its writer ---------

@test "every staged producer is immediately followed by its writer call" {
  # Group 2 pins the flag. This pins the producer and ties each one to a writer.
  #
  # Counts alone balance cardinalities and associate nothing: a spec could stage
  # the array in one place and call the writer somewhere unrelated, so the
  # member runs the writer against whatever file an earlier call left, which
  # is the stale republish this suite exists to forbid. So each producer must be
  # followed, fence to fence, by the literal-root writer call: its own fence
  # closes, one blank line, the next fence opens on the writer. The writer is
  # anchored at `<root>` for the reason audit-root-resolution.bats stage 8b
  # gives: an unanchored spelling runs the session cwd's copy of the writer.
  #
  # The totals are checked too, so a writer call with no producer ahead of it
  # (reading a file nothing in the spec stages) fails as well.
  for audited_file in "${SPECS[@]}"; do
    local producers writers consumers unpaired
    producers="$(grep -cE -- "^printf '%s' '.*' > <scratch>/findings\\.json$" "$audited_file" || true)"
    writers="$(grep -cE -- '^bash <root>/\.gaia/scripts/audit-write-findings\.sh \\$' "$audited_file" || true)"
    consumers="$(grep -cE -- '^[[:space:]]*--findings <scratch>/findings\.json[[:space:]]*$' "$audited_file" || true)"
    [ "$producers" -gt 0 ] || { echo "$audited_file: no staged printf producer" >&2; return 1; }
    [ "$producers" -eq "$writers" ] || { echo "$audited_file: $producers producers, $writers writer calls" >&2; return 1; }
    [ "$writers" -eq "$consumers" ] || { echo "$audited_file: $writers writer calls, $consumers staged-file consumers" >&2; return 1; }
    unpaired="$(awk '
      { line[NR] = $0 }
      END {
        for (i = 1; i <= NR; i++) {
          if (line[i] ~ /^printf .%s. .*> <scratch>\/findings\.json$/) {
            if (!(line[i+1] == "```" && line[i+2] == "" && line[i+3] == "```bash" && line[i+4] ~ /^bash <root>\/\.gaia\/scripts\/audit-write-findings\.sh \\$/)) print i
          }
        }
      }' "$audited_file")"
    [ -z "$unpaired" ] || {
      echo "$audited_file: producer(s) at line(s) $unpaired are not immediately followed by the writer call" >&2
      return 1
    }
  done
}

# --- Group 4: payload forms the writer or the isolation guard refuses ---------

@test "no spec pipes the payload into the writer, double-quotes it, revives a heredoc or hands a resolver value to a flag unquoted, and every spec carries the quoted anchor-tree form" {
  # Double-quoted payload: expands `$` and backticks in finding text before the
  # writer validates the array. Pipe into the writer: the superseded stdin form,
  # refused by worktree isolation whenever the payload carries the token `git`.
  # Heredoc: unrunnable from a linked worktree. Unquoted resolver value: the
  # resolver prints ANCHOR_TREE empty on every first dispatch, so a bare
  # `--anchor-tree <ANCHOR_TREE>` swallows the next flag and the writer exits 2.
  # The anchor-tree presence check is the floor for that last absence rule.
  local forbidden_case forbidden_pattern forbidden_label
  local -a forbidden_cases=(
    "^printf '%s' \"|double-quoted payload"
    '\|[[:space:]]*bash[[:space:]].*audit-write-findings\.sh|payload piped into the writer'
    "--findings - <<|revived --findings heredoc"
    "^printf '%s'.*<<|revived producer heredoc"
    '--[a-z-]+ <[A-Z_]+>|resolver value handed to a flag unquoted'
  )
  for audited_file in "${ALL[@]}"; do
    for forbidden_case in "${forbidden_cases[@]}"; do
      forbidden_pattern="${forbidden_case%|*}"
      forbidden_label="${forbidden_case##*|}"
      if grep -qE -- "$forbidden_pattern" "$audited_file"; then
        echo "$audited_file: $forbidden_label" >&2
        return 1
      fi
    done
  done
  for audited_file in "${SPECS[@]}"; do
    grep -qF -- "--anchor-tree '<ANCHOR_TREE>'" "$audited_file" || {
      echo "$audited_file carries no quoted --anchor-tree form" >&2
      return 1
    }
  done
}
