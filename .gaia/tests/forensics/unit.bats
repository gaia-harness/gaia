#!/usr/bin/env bats
# .gaia/tests/forensics/unit.bats; SPEC-002 layer B regression suite.
#
# This file delegates to the bats suites under `.github/forensics/tests/`
# (parser, scope-checker, verdict-parser, handlers, quality-gate runner)
# AND adds layer-A fixture invariants:
#
#   - the six `valid-*` / `non-issue-*` / `redaction-*` / `denylist-*` /
#     `unenumerated-*` fixtures parse cleanly (`.valid == true`);
#   - the two `malformed-*` fixtures parse to the documented error code;
#   - the `redaction-passthrough` fixture's two redaction tokens survive
#     the parser byte-for-byte (UAT-015);
#   - `denylist-attempt` (UAT-007) and `unenumerated-attempt` (UAT-014)
#     resolve to `ok:false` via `check-scope.sh`.
#
# UATs covered automatically by layer A+B (no GitHub round-trip):
#   UAT-003 (handlers.bats / parse-verdict.bats), UAT-007, UAT-009,
#   UAT-013, UAT-014, UAT-015.
#
# Layer C (manual checklist) covers UAT-001 / UAT-002 / UAT-004 /
# UAT-005 / UAT-006 / UAT-008 / UAT-010 / UAT-011 / UAT-012; see
# `.gaia/tests/forensics/integration.md`.

setup() {
  # Resolve repo root from the test file location: this file lives at
  # `.gaia/tests/forensics/unit.bats`, so the repo root is three levels up.
  REPO_ROOT="$( cd "$( dirname "$BATS_TEST_FILENAME" )/../../.." && pwd )"
  FORENSICS_DIR="$REPO_ROOT/.github/forensics"
  FIXTURES_DIRECTORY="$REPO_ROOT/.gaia/tests/forensics/fixtures"
  PARSER="$FORENSICS_DIR/parse-issue-body.sh"
  SCOPE="$FORENSICS_DIR/check-scope.sh"
}

# ---------------------------------------------------------------------------
# Delegation: run every bats suite under `.github/forensics/tests/` so a
# single `pnpm test:forensics` invocation runs the entire forensics
# regression surface. Each suite emits its own ok/not ok lines; this file
# adds a single bats test that wraps the run and checks the exit code.
# ---------------------------------------------------------------------------

@test "delegate: .github/forensics/tests/*.bats all green" {
  run bats "$FORENSICS_DIR/tests/"
  if [ "$status" -ne 0 ]; then
    echo "$output"
  fi
  [ "$status" -eq 0 ]
}

# parse_case <fixture> <needle>...: the parser exits 0 and its output holds
# every needle.
parse_case() {
  local fixture="$1" needle
  shift
  echo "case: fixture $fixture"
  run "$PARSER" "$FIXTURES_DIRECTORY/$fixture.md"
  [ "$status" -eq 0 ] || return 1
  for needle in "$@"; do
    [[ "$output" == *"$needle"* ]] || return 1
  done
  return 0
}

# ---------------------------------------------------------------------------
# Layer-A fixture invariants: valid fixtures parse cleanly, malformed ones
# return the documented error code (UAT-013). The denylist-attempt (UAT-007)
# and unenumerated-attempt (UAT-014) fixtures parse as VALID bodies; the
# boundary they exercise is the scope checker, tested below.
# ---------------------------------------------------------------------------

@test "parse-issue-body.sh returns the documented result for each fixture" {
  parse_case valid-init-failure '"valid":true' '"class":"init"' || return 1
  parse_case valid-update-conflict '"valid":true' '"class":"update"' || return 1
  parse_case non-issue-config '"valid":true' '"class":"dev-server"' || return 1
  parse_case malformed-missing-symptom \
    '"valid":false' '"error":"missing-section"' '"symptom"' || return 1
  parse_case malformed-frontmatter \
    '"valid":false' '"error":"malformed-frontmatter"' || return 1
  parse_case denylist-attempt '"valid":true' || return 1
  parse_case unenumerated-attempt '"valid":true'
}

# ---------------------------------------------------------------------------
# UAT-015 redaction passthrough.
#
# The fixture deliberately carries TWO tokens: a `<redacted>` literal AND
# a repo-relative path (`.gaia/cli/src/config/load.ts`) derived from an
# absolute path. Both must survive the parser byte-for-byte.
# ---------------------------------------------------------------------------

@test "parse-issue-body.sh passes redaction tokens through byte-for-byte" {
  # The second token sits at two sites: capture (`config_path: ...`) and
  # reproduction context.
  parse_case redaction-passthrough \
    '<redacted>' 'api_key: <redacted>' \
    'config_path: .gaia/cli/src/config/load.ts' '.gaia/cli/src/config/load.ts'
}

# ---------------------------------------------------------------------------
# UAT-007 (denylist) and UAT-014 (unenumerated): the proposed paths go through
# `check-scope.sh` directly, as the workflow does after the classifier runs.
# ---------------------------------------------------------------------------

# bats test_tags=protected
@test "check-scope.sh denies a denylisted or unenumerated path" {
  echo "case: UAT-007 mixed allow + deny path proposal denies the whole attempt"
  # Two paths: one in the allowlist (`.claude/skills/`), one on the canonical
  # denylist (`apps/web/app/`). Per UAT-007 the WHOLE attempt is denied;
  # `ok:false`; not just the denylisted path.
  run "$SCOPE" .claude/skills/gaia/SKILL.md apps/web/app/routes/_index.tsx
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *'"ok":false'* ]] || return 1
  [[ "$output" == *'apps/web/app/routes/_index.tsx'* ]] || return 1
  [[ "$output" == *'"reason":"denylist"'* ]] || return 1
  # The allowed leg still appears in `allowed[]`; the partition is informational
  # but `ok` is false, which is what the workflow gates on.
  [[ "$output" == *'"allowed":[".claude/skills/gaia/SKILL.md"]'* ]] || return 1

  echo "case: UAT-014 unenumerated path (tsconfig.json) denied as default-deny-unenumerated"
  run "$SCOPE" tsconfig.json
  [ "$status" -eq 0 ] || return 1
  [[ "$output" == *'"ok":false'* ]] || return 1
  [[ "$output" == *'"reason":"default-deny-unenumerated"'* ]]
}
