#!/usr/bin/env bats
# Cross-implementation conformance suite for the whole-line marker-pair
# parsers: `.gaia/cli/src/update/region-markers.ts` (TypeScript, the region
# oracle's parser), `.gaia/scripts/write-audit-remits.sh` (the writer), and
# `.gaia/scripts/verify-audit-roster.sh`'s `_verify_roster_read_regions` (the
# check). One fixture set drives all three REAL implementations, never a
# reimplementation of their `grep -cxF` counting: this suite is only a
# conformance test if it executes the scripts it binds against.
#
# Each fixture is a one-member roster (`code-audit-fixture`, default: true,
# globs `fixture/a/**` + `fixture/b/**`) plus that member's agent definition,
# written fresh into `$BATS_TEST_TMPDIR` for every probe so the writer's
# in-place rewrite of one probe's copy never contaminates another's.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

# bats file_tags=installed-dependencies
# installed-dependencies backstop: .github/workflows/cli-tests.yml

setup() {
  THIS_DIRECTORY="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  PROJECT_ROOT="$(git -C "$THIS_DIRECTORY" rev-parse --show-toplevel)"
  CLI_DIRECTORY="$PROJECT_ROOT/.gaia/cli"
  WRITER="$PROJECT_ROOT/.gaia/scripts/write-audit-remits.sh"
  CHECKER="$PROJECT_ROOT/.gaia/scripts/verify-audit-roster.sh"

  # This suite runs the real TypeScript parser through tsx, which needs the
  # CLI member's node_modules. audit-ci-tests.yml runs this file inside
  # whichever scripts-* shard it lands in, and those legs install only `bats`
  # and `python3-yaml`, with no actions/setup-node, no pnpm and no
  # `pnpm install`, so the suite skips cleanly there rather than failing a
  # required PR check for an environment it cannot control. It runs wherever a
  # root install has provisioned the workspace, since that install also
  # provisions the CLI member. The binding is asserted regardless by
  # cli-tests.yml, which installs the CLI's dependencies and runs this file by
  # name, so the skip never hides it.
  [ -d "$CLI_DIRECTORY/node_modules" ] || skip "no node_modules on this runner"

  START_MARKER='<!-- gaia:audit-remit:start -->'
  END_MARKER='<!-- gaia:audit-remit:end -->'
}

teardown() {
  rm -rf "${BATS_TEST_TMPDIR:?}"/sandbox-*
}

# --- Sandbox + fixture helpers ----------------------------------------------

# Writes a fresh one-member roster + agent file under $BATS_TEST_TMPDIR and
# prints its path. $1 = unique suffix, $2 = the agent file's full body.
make_sandbox() {
  local suffix="$1" body="$2" sandbox_directory
  sandbox_directory="$BATS_TEST_TMPDIR/sandbox-$suffix"
  mkdir -p "$sandbox_directory/.gaia" "$sandbox_directory/.claude/agents"
  cat > "$sandbox_directory/.gaia/audit-ci.yml" <<'YAML'
auditors:
  - name: code-audit-fixture
    globs:
      - "fixture/a/**"
      - "fixture/b/**"
    audience: adopter
    default: true
YAML
  printf '%s\n' "$body" > "$sandbox_directory/.claude/agents/code-audit-fixture.md"
  printf '%s' "$sandbox_directory"
}

fixture_ok() {
  printf -- '---\nname: code-audit-fixture\n---\n\n## Remit and self-skip\n\n%s\n- `fixture/a/**`\n- `fixture/b/**`\n\nplaceholder sentence.\n%s\n\nTrailing content.\n' \
    "$START_MARKER" "$END_MARKER"
}

fixture_absent() {
  printf -- '---\nname: code-audit-fixture\n---\n\n## Remit and self-skip\n\nno markers at all here.\n'
}

fixture_duplicate_start() {
  printf -- '---\nname: code-audit-fixture\n---\n\n## Remit and self-skip\n\n%s\n- `fixture/a/**`\n%s\n- `fixture/b/**`\n%s\n' \
    "$START_MARKER" "$START_MARKER" "$END_MARKER"
}

fixture_unbalanced() {
  printf -- '---\nname: code-audit-fixture\n---\n\n## Remit and self-skip\n\n%s\n- `fixture/a/**`\n- `fixture/b/**`\n' \
    "$START_MARKER"
}

fixture_inverted() {
  printf -- '---\nname: code-audit-fixture\n---\n\n## Remit and self-skip\n\n%s\n- `fixture/a/**`\n- `fixture/b/**`\n\nplaceholder sentence.\n%s\n' \
    "$END_MARKER" "$START_MARKER"
}

fixture_substring() {
  printf -- '---\nname: code-audit-fixture\n---\n\n## Remit and self-skip\n\nUse the `%s` marker to delimit it.\n' \
    "$START_MARKER"
}

# --- Probes ------------------------------------------------------------------

# Probe 1 (TypeScript): runs the real region-markers.ts module through tsx,
# never a reimplementation. Prints `kind` (and `/reason` when malformed).
typescript_scan() {
  GAIA_FIXTURE_FILE="$1" GAIA_START_MARKER="$START_MARKER" GAIA_END_MARKER="$END_MARKER" \
    pnpm --silent -C "$CLI_DIRECTORY" exec tsx -e '
      import {scanRegion} from "./src/update/region-markers.js";
      import {readFileSync} from "node:fs";
      const source = readFileSync(process.env.GAIA_FIXTURE_FILE, "utf8");
      const scan = scanRegion(
        source,
        process.env.GAIA_START_MARKER,
        process.env.GAIA_END_MARKER
      );
      process.stdout.write(scan.kind + (scan.reason ? "/" + scan.reason : ""));
    '
}

# Probe 2 (writer): executes the real write-audit-remits.sh against the
# sandbox and classifies its outcome for the one member from what it actually
# did, never from a count computed here. $1 = sandbox directory.
classify_writer() {
  local sandbox_directory="$1" command_output status=0
  command_output="$(bash "$WRITER" --root "$sandbox_directory" --config "$sandbox_directory/.gaia/audit-ci.yml" 2>&1)" || status=$?
  if [ "$status" -ne 0 ]; then
    printf 'fail'
    return 0
  fi
  if grep -qF 'region inserted' <<<"$command_output"; then
    printf 'insert'
    return 0
  fi
  printf 'replace'
}

# Probe 3 (check): executes the real verify-audit-roster.sh against the
# sandbox and reads off the region-shape finding it emitted for the member,
# never a count computed here. $1 = sandbox directory. The `unreadable-
# machinery-list` finding is sandbox noise (no .claude/hooks/lib/
# audit-machinery.sh in a bare fixture root) and is not asserted on; only the
# region-shape label is.
classify_check() {
  local sandbox_directory="$1" command_output
  command_output="$(bash "$CHECKER" --root "$sandbox_directory" --config "$sandbox_directory/.gaia/audit-ci.yml" 2>&1)" || true
  if grep -qF 'FAIL missing-remit-region' <<<"$command_output"; then
    printf 'REGIONMISSING'
    return 0
  fi
  if grep -qF 'FAIL duplicate-remit-region' <<<"$command_output"; then
    printf 'REGIONDUP'
    return 0
  fi
  if grep -qF 'FAIL unbalanced-remit-region' <<<"$command_output"; then
    printf 'REGIONUNBALANCED'
    return 0
  fi
  if grep -qF 'FAIL reversed-remit-region' <<<"$command_output"; then
    printf 'REGIONREVERSED'
    return 0
  fi
  printf 'REGIONOK'
}

# One row per marker-pair shape, driven through all three real implementations:
# <name>|<fixture function>|<TypeScript scan>|<writer outcome>|<check outcome>.
#
# absent is the expected pre-region adopter state: the writer inserts the
# region and the check reports it missing as a routine finding.
#
# substring is one line embedding the marker text inside longer prose, with no
# real marker. All three see no region, the whole-line contract; a
# substring-matching implementation (marker-strip.ts's semantics) fails here.
#
# inverted (end line before start line): all three refuse reversed marker
# order, so none judges by count alone.
@test "marker-pair shapes agree across the TypeScript parser, the writer and the roster check" {
  local row name fixture_function typescript_expected writer_expected check_expected
  local body typescript_directory writer_directory check_directory fixture before
  local rows=(
    "ok|fixture_ok|region|replace|REGIONOK"
    "absent|fixture_absent|absent|insert|REGIONMISSING"
    "duplicate-start|fixture_duplicate_start|malformed/duplicate-start|fail|REGIONDUP"
    "unbalanced|fixture_unbalanced|malformed/unbalanced|fail|REGIONUNBALANCED"
    "substring|fixture_substring|absent|insert|REGIONMISSING"
    "inverted|fixture_inverted|malformed/inverted|fail|REGIONREVERSED"
  )
  for row in "${rows[@]}"; do
    IFS='|' read -r name fixture_function typescript_expected writer_expected check_expected <<<"$row"
    body="$($fixture_function)"
    typescript_directory="$(make_sandbox "$name-ts" "$body")"
    writer_directory="$(make_sandbox "$name-writer" "$body")"
    check_directory="$(make_sandbox "$name-check" "$body")"

    run typescript_scan "$typescript_directory/.claude/agents/code-audit-fixture.md"
    [ "$status" -eq 0 ] || { echo "row $name: TypeScript status $status"; return 1; }
    [ "$output" = "$typescript_expected" ] || { echo "row $name: TypeScript got '$output'"; return 1; }

    fixture="$writer_directory/.claude/agents/code-audit-fixture.md"
    before="$BATS_TEST_TMPDIR/$name-before.md"
    # The pre-run bytes, copied aside rather than captured into a variable:
    # `$(cat ...)` strips all trailing newlines from both sides, so a writer
    # that deleted or added exactly a trailing newline would satisfy a
    # byte-identity claim it had in fact broken.
    cp "$fixture" "$before"

    run classify_writer "$writer_directory"
    [ "$status" -eq 0 ] || { echo "row $name: writer classify status $status"; return 1; }
    [ "$output" = "$writer_expected" ] || { echo "row $name: writer got '$output'"; return 1; }
    # The writer never deletes bytes outside a pair it can identify: a
    # rejected pair leaves the file byte-identical to before the run. `cmp`
    # unsuppressed, so a regression names the differing byte offset.
    if [ "$writer_expected" = "fail" ]; then
      cmp "$before" "$fixture" || { echo "row $name: writer changed a rejected file"; return 1; }
    fi

    # A missing region is a routine invariant finding (exit 1), never a usage
    # error (exit 2) or a crash.
    if [ "$check_expected" = "REGIONMISSING" ]; then
      run bash "$CHECKER" --root "$check_directory" --config "$check_directory/.gaia/audit-ci.yml"
      [ "$status" -eq 1 ] || { echo "row $name: check exit $status, expected 1"; return 1; }
    fi

    run classify_check "$check_directory"
    [ "$status" -eq 0 ] || { echo "row $name: check classify status $status"; return 1; }
    [ "$output" = "$check_expected" ] || { echo "row $name: check got '$output'"; return 1; }
  done
}
