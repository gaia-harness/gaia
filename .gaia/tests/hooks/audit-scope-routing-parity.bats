#!/usr/bin/env bats
# audit-scope-routing-parity.bats: the before/after routing-parity proof
# (UAT-017) for the Code Audit Team ownership classifier.
#
# fixtures/audit-routing-before.tsv is `<path><TAB><owner|->`, one row per
# tracked file, generated ONCE against the classifier and roster as they
# existed before this change (reconstructed from git history) and committed.
# It is never regenerated: the whole point is that it records the prior
# state. This suite classifies every fixture path with the CURRENT
# classifier and asserts each row resolves to the same owner as before,
# except the named sets below, which deliberate roster changes move. The
# arms are the authority on how many; deliberately no count in this sentence
# or in the test name, because a count rots the next time a set is added, and
# the rotted number reads as an assertion nobody has checked:
#
#   .github/workflows/<single-segment>.yml|.yaml -> code-audit-github-workflows
#   .github/actions/**/*.yml|*.yaml               -> code-audit-github-workflows
#   .gaia/cli/templates/workflows/code-review-audit.yml.tmpl -> code-audit-maintainer-node
#   .gaia/cli/{package.json,tsconfig*.json,*.config.ts,*.config.mjs}          -> code-audit-maintainer-node
#
# The scaffold templates are one tree now: `.gaia/cli/templates/**` is the
# source and moves from ownerless to the node member (its `before = -` rows),
# and the retired template copies under `.gaia/cli/src/` (the scaffold copy and
# the removed automation templates) read ownerless (their rows were the node
# member's).
#
# The frontend/ move (SPEC-092) then retires the root frontend class: `app/**`,
# `test/**`, `.storybook/**`, `.playwright/**`, root `tsconfig*.json`, and the
# root `Dockerfile`, `.dockerignore`, `.lintstagedrc.json` and `.env.example` resolve
# to no member, because the roster declares them under `frontend/` now. Their
# arm precedes the triage arms below.
#
# The remaining sets are the ownerless-path triage, and their direction is the
# whole content of that change: every row they move goes from `-` to a member,
# and no row moves between members. Those arms assert that direction rather than
# describing it, by matching only when the `before` column reads `-`. One row
# inside them does not move at all: `.gaia/audit-ci.yml` was already granted to
# the shell member explicitly, and `.gaia/*.yml` generalizes that grant rather
# than adding one, so it reads `code-audit-maintainer-shell` on both sides and
# carries its own arm.
#
#   .playwright/**                                -> code-audit-frontend
#   the root tooling that decides what runs        -> code-audit-frontend
#     (.npmrc, .nvmrc, .node-version, .prettierignore)
#   .gaia/scripts/**/*.mjs                         -> code-audit-maintainer-node
#   the distribution and governance surface        -> code-audit-maintainer-shell
#     (.gaia/*.yml, .gaia/*.json, .gaia/scripts/token-rates.json,
#      .gaia/release-exclude, .claude/settings.json, .github/CODEOWNERS)
#
# The prose-legibility member's own reassignment (`.claude/skills/**/*.md`,
# `.claude/agents/*/**`, `.claude/commands/**`, `.claude/instructions/**`,
# `.claude/agents/worthiness-evaluator.md`, `.gaia/cli/health/**/*.md`, and the
# two `.github/forensics/` prompts) is gone with the member (harness triage
# P3-09): it carries no arm above because `before` was already `-` for all
# of it, and deleting the member returns `after` to `-` too, so the trailing
# `else` covers it without a special case.
#
# This is stable and does not rot: the test iterates FIXTURE ROWS, so a file
# added to the repo later neither breaks it nor silently escapes it. It is a
# genuine regression pin on the routing change, not a snapshot that needs
# feeding.
#
# Assertion style: .claude/rules/bats-assertions.md. The `[[ =~ ]]` uses
# below are branch conditionals that pick an `expected` value, never the
# pass/fail signal itself; the actual assertion is the final
# `[ "$fail" -eq 0 ]`.

setup() {
  THIS_DIRECTORY="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIRECTORY/../../.." && pwd )"
  SCOPE_LIBRARY="$REPO_ROOT/.claude/hooks/lib/audit-scope.sh"
  FIXTURE="$THIS_DIRECTORY/fixtures/audit-routing-before.tsv"
}

@test "routing parity: every fixture row resolves to the same owner, except the named sets" {
  [ -f "$FIXTURE" ]

  # shellcheck source=/dev/null
  . "$SCOPE_LIBRARY"
  audit_scope_init "$REPO_ROOT"

  # Classify every fixture path with the CURRENT classifier in one batch pass
  # (the batch predicate forks zero processes per path), then join the
  # before/after columns by line position: both sides iterate the fixture's
  # paths in the same order, so a plain `paste` aligns them correctly.
  after_owners="$(cut -f1 "$FIXTURE" | audit_owners_for_paths | cut -f2)"

  fail=0
  rows=0
  while IFS=$'\t' read -r path before after; do
    [ -n "$path" ] || continue
    rows=$((rows + 1))

    if [[ "$path" =~ ^\.github/workflows/[^/]*\.ya?ml$ ]]; then
      expected="code-audit-github-workflows"
    elif [[ "$path" =~ ^\.github/actions/.*\.ya?ml$ ]]; then
      expected="code-audit-github-workflows"
    elif [ "$path" = ".gaia/cli/templates/workflows/code-review-audit.yml.tmpl" ]; then
      expected="code-audit-maintainer-node"
    elif [ "$before" = "-" ] && [[ "$path" =~ ^\.gaia/cli/templates/ ]]; then
      expected="code-audit-maintainer-node"
    elif [ "$before" = "code-audit-maintainer-node" ] && [[ "$path" =~ ^\.gaia/cli/src/(scaffold|automation)/templates/ ]]; then
      expected="-"
    elif [[ "$path" =~ ^\.gaia/cli/(package\.json|tsconfig[^/]*\.json|[^/]*\.config\.ts|[^/]*\.config\.mjs)$ ]]; then
      expected="code-audit-maintainer-node"
    # The four ownerless-triage arms below are guarded on `before = -` rather
    # than on the path alone, so the header's claim about their DIRECTION is
    # asserted instead of narrated. A future change that moved one of these
    # rows from one member to another would no longer match its arm, fall to
    # the `else` below, and be reported as a mismatch. `.gaia/audit-ci.yml` is
    # the one row inside these sets that legitimately does not move, so it gets
    # its own literal arm ahead of them.
    elif [ "$path" = ".gaia/audit-ci.yml" ]; then
      expected="code-audit-maintainer-shell"
    # The frontend/ move retired these root paths: the roster now declares them
    # under frontend/, so a root path of the old frontend class owns nothing.
    elif [[ "$path" =~ ^(app|test|\.storybook|\.playwright)/ ]] || [[ "$path" =~ ^tsconfig[^/]*\.json$ ]] \
      || [[ "$path" =~ ^(Dockerfile|\.dockerignore|\.lintstagedrc\.json|\.env\.example)$ ]]; then
      expected="-"
    elif [ "$before" = "-" ] && [[ "$path" =~ ^\.playwright/ ]]; then
      expected="code-audit-frontend"
    elif [ "$before" = "-" ] && [[ "$path" =~ ^(\.npmrc|\.nvmrc|\.node-version|\.prettierignore)$ ]]; then
      expected="code-audit-frontend"
    elif [ "$before" = "-" ] && [[ "$path" =~ ^\.gaia/scripts/.*\.mjs$ ]]; then
      expected="code-audit-maintainer-node"
    elif [ "$before" = "-" ] && [[ "$path" =~ ^(\.gaia/[^/]*\.(yml|json)|\.gaia/scripts/token-rates\.json|\.gaia/release-exclude|\.claude/settings\.json|\.github/CODEOWNERS)$ ]]; then
      expected="code-audit-maintainer-shell"
    else
      expected="$before"
    fi

    if [ "$after" != "$expected" ]; then
      echo "ROUTING MISMATCH: $path  before=$before  after=$after  expected=$expected" >&2
      fail=$((fail + 1))
    fi
  done < <(paste "$FIXTURE" <(printf '%s\n' "$after_owners"))

  [ "$rows" -gt 0 ]
  [ "$fail" -eq 0 ]
}

# ---------------------------------------------------------------------------
# The release-change skip, over the same fixture paths. The live roster keys no
# member, so these cases key one claimant (the shell member) in a copy of it,
# and arm the context on a scratch repository that carries the live manifest at
# both ends. The fixture's prior-state meaning is untouched: the case above
# still pins the unarmed routing.
# ---------------------------------------------------------------------------

# release_parity_setup <version-after>: writes the keyed and the
# member-removed roster copies and a repository whose branch moves .gaia/VERSION
# from 1.0.0 to <version-after>.
release_parity_setup() {
  local repository="$BATS_TEST_TMPDIR/release-parity"
  command -v jq >/dev/null 2>&1 || skip "jq required"
  KEYED_ROSTER="$BATS_TEST_TMPDIR/keyed.yml"
  REMOVED_ROSTER="$BATS_TEST_TMPDIR/removed.yml"
  # The live roster already keys the adopter shell member; the fixtures key
  # only the maintainer shell member, so the keys the live roster carries
  # come off first.
  local unkeyed="$BATS_TEST_TMPDIR/unkeyed.yml"
  grep -v '^    skip_gaia_release_changes: true$' "$REPO_ROOT/.gaia/audit-ci.yml" > "$unkeyed"
  awk '
    /^auditors:/ { in_auditors = 1 }
    in_auditors && /^[A-Za-z_]/ && !/^auditors:/ { if (pending) print "    skip_gaia_release_changes: true"; pending = 0; in_auditors = 0 }
    in_auditors && /^  - name:/ { if (pending) print "    skip_gaia_release_changes: true"; pending = ($0 ~ /code-audit-maintainer-shell$/) }
    { print }
  ' "$unkeyed" > "$KEYED_ROSTER"
  awk '
    /^auditors:/ { in_auditors = 1 }
    in_auditors && /^[A-Za-z_]/ && !/^auditors:/ { dropping = 0; in_auditors = 0 }
    in_auditors && /^  - name:/ { dropping = ($0 ~ /code-audit-maintainer-shell$/) }
    !dropping { print }
  ' "$unkeyed" > "$REMOVED_ROSTER"
  [ "$(grep -c '^    skip_gaia_release_changes: true$' "$KEYED_ROSTER")" -eq 1 ]
  grep -q 'name: code-audit-maintainer-shell$' "$REMOVED_ROSTER" && return 1
  mkdir -p "$repository/.gaia"
  git -C "$repository" init -q --initial-branch=main
  git -C "$repository" config user.email test@example.com
  git -C "$repository" config user.name Test
  git -C "$repository" config commit.gpgsign false
  cp "$REPO_ROOT/.gaia/manifest.json" "$repository/.gaia/manifest.json"
  printf '1.0.0\n' > "$repository/.gaia/VERSION"
  git -C "$repository" add -A
  git -C "$repository" commit -qm base
  git -C "$repository" checkout -q -b update
  printf '%s\n' "$1" > "$repository/.gaia/VERSION"
  git -C "$repository" commit -qam update --allow-empty
  RELEASE_PARITY_ROOT="$repository"
}

# release_parity_owners <config> [armed]: fixture paths' owners, one per line.
release_parity_owners() {
  bash -c '
    . "$1" || exit 9
    audit_scope_init "$2" "$3" || exit 9
    [ -z "$5" ] || audit_scope_release_context "$2" main
    [ -z "$5" ] || audit_scope_release_context_state >&2
    cut -f1 "$4" | audit_owners_for_paths | cut -f2
  ' _ "$SCOPE_LIBRARY" "$RELEASE_PARITY_ROOT" "$1" "$FIXTURE" "${2:-}"
}

@test "routing parity, release context armed: only owned rows of the keyed member move, each to its keyed-entry-removed owner" {
  release_parity_setup 1.1.0
  local live keyed removed owned fail=0 moved=0 path live_owner keyed_owner removed_owner expected
  live="$(release_parity_owners "$REPO_ROOT/.gaia/audit-ci.yml")"
  keyed="$(release_parity_owners "$KEYED_ROSTER" armed 2>"$BATS_TEST_TMPDIR/state")"
  removed="$(release_parity_owners "$REMOVED_ROSTER")"
  grep -q '^armed [1-9]' "$BATS_TEST_TMPDIR/state"
  owned=$'\n'"$(jq -r '.files | to_entries[] | select(.value == "owned") | .key' "$REPO_ROOT/.gaia/manifest.json")"$'\n'
  while IFS=$'\t' read -r path live_owner keyed_owner removed_owner; do
    expected="$live_owner"
    if [ "$live_owner" = code-audit-maintainer-shell ]; then
      case "$owned" in *$'\n'"$path"$'\n'*) expected="$removed_owner" ;; esac
    fi
    [ "$expected" = "$live_owner" ] || moved=$((moved + 1))
    if [ "$keyed_owner" != "$expected" ]; then
      echo "RELEASE ROUTING MISMATCH: $path live=$live_owner keyed=$keyed_owner expected=$expected" >&2
      fail=$((fail + 1))
    fi
  done < <(paste <(cut -f1 "$FIXTURE") <(printf '%s\n' "$live") <(printf '%s\n' "$keyed") <(printf '%s\n' "$removed"))
  [ "$moved" -gt 0 ]
  [ "$fail" -eq 0 ]
}

@test "routing parity, release context disarmed: a keyed roster routes every fixture row exactly as the live roster" {
  release_parity_setup 1.0.0
  local live keyed
  live="$(release_parity_owners "$REPO_ROOT/.gaia/audit-ci.yml")"
  keyed="$(release_parity_owners "$KEYED_ROSTER" armed 2>"$BATS_TEST_TMPDIR/state")"
  [ "$(cat "$BATS_TEST_TMPDIR/state")" = "disarmed no-version-change" ]
  [ -n "$live" ]
  [ "$keyed" = "$live" ]
}
