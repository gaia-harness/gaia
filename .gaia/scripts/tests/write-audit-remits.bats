#!/usr/bin/env bats
# Tests for .gaia/scripts/write-audit-remits.sh, the roster-derived remit
# region generator.
#
# Every case runs against fixtures scaffolded into $BATS_TEST_TMPDIR. No test
# mutates the repo's real roster or its real agent definitions.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  THIS_DIRECTORY="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIRECTORY/../../.." && pwd )"
  # snapshot_file + assert_files_identical: byte identity without `$(cat …)`.
  . "$REPO_ROOT/.gaia/tests/helpers/files.sh"
  WRITER="$REPO_ROOT/.gaia/scripts/write-audit-remits.sh"
  CHECK="$REPO_ROOT/.gaia/scripts/verify-audit-roster.sh"
  # A hard failure, not a skip: a `skip` here would silently retire every
  # test in this suite to skipped-and-green if the committed writer ever
  # went missing, which is the opposite of what a missing file should do.
  if [ ! -f "$WRITER" ]; then
    printf 'write-audit-remits.sh missing: %s\n' "$WRITER" >&2
    return 1
  fi
}

assert_contains() {
  grep -qF -- "$1" <<<"$output"
}

# Scaffolds a fixture root: the roster arrives on stdin, the machinery lists
# are derived from the member names it declares (so the check's unrelated
# invariants stay clean), and one stub agent file per member is written in the
# shape `shape` selects: "heading" (default, the primary C6 anchor),
# "frontmatter" (no heading, the fallback C6 anchor), or "noanchor" (neither).
fixture_root() {
  local fixture_directory="$1" shape="${2:-heading}" names member_name
  rm -rf "$fixture_directory"
  mkdir -p "$fixture_directory/.gaia/scripts" "$fixture_directory/.claude/agents" "$fixture_directory/.claude/hooks/lib"
  cat > "$fixture_directory/.gaia/audit-ci.yml"
  names="$(awk '/^[[:space:]]*-[[:space:]]+name[[:space:]]*:/ {
    sub(/^[[:space:]]*-[[:space:]]+name[[:space:]]*:[[:space:]]*/, ""); print }' "$fixture_directory/.gaia/audit-ci.yml")"
  {
    printf 'AUDIT_MACHINERY_PATHS="$(cat <<%s\n' "'EOF'"
    for member_name in $names; do printf '.claude/agents/%s.md\n' "$member_name"; done
    printf 'EOF\n)"\n'
  } > "$fixture_directory/.claude/hooks/lib/audit-machinery.sh"
  for member_name in $names; do
    case "$shape" in
      frontmatter)
        cat > "$fixture_directory/.claude/agents/$member_name.md" <<MD
---
name: $member_name
---

# $member_name
MD
        ;;
      noanchor)
        cat > "$fixture_directory/.claude/agents/$member_name.md" <<MD
just some text
no frontmatter no heading
MD
        ;;
      *)
        cat > "$fixture_directory/.claude/agents/$member_name.md" <<MD
---
name: $member_name
---

# $member_name

## Remit and self-skip

You own things.
MD
        ;;
    esac
  done
}

run_writer() {
  run bash "$WRITER" --root "$1" --config "$1/.gaia/audit-ci.yml"
}

# <root> <member> -- that member's roster globs, in roster order, read back
# through the check's own --emit-roster mode. Never a hard-coded list.
member_globs() {
  bash "$CHECK" --emit-roster --root "$1" --config "$1/.gaia/audit-ci.yml" |
    awk -F'\t' -v member="$2" '$1 == "RAW" && $2 == member { print $3 }'
}

# <file> -- the glob bullets inside that file's remit region, in file order.
region_globs() {
  awk '
    /^<!-- gaia:audit-remit:start -->$/ { in_region = 1; next }
    /^<!-- gaia:audit-remit:end -->$/ { in_region = 0; next }
    in_region && /^- `.*`$/ { line = $0; sub(/^- `/, "", line); sub(/`$/, "", line); print line }
  ' "$1"
}

# <file> -- the region's non-bullet, non-empty, non-marker lines (the
# sentence).
region_sentence_lines() {
  awk '
    /^<!-- gaia:audit-remit:start -->$/ { in_region = 1; next }
    /^<!-- gaia:audit-remit:end -->$/ { in_region = 0; next }
    in_region && $0 != "" && $0 !~ /^- `.*`$/ { print }
  ' "$1"
}

# Usage surface

@test "usage: --help exits 0 and prints the usage" {
  run bash "$WRITER" --help
  [ "$status" -eq 0 ]
  assert_contains "Usage: write-audit-remits.sh"
}


# UAT-006: the writer repairs a drifted region.

@test "repair: a drifted region is rewritten to the roster globs in order, announces + and - deltas, and touches nothing outside the markers" {
  local fixture_directory="$BATS_TEST_TMPDIR/repair"
  fixture_root "$fixture_directory" <<'YAML'
auditors:
  - name: code-audit-default
    globs:
      - "zzz-default-only/**"
    default: true
  - name: code-audit-a
    globs:
      - "a/**"
      - "a/b/*.ts"
      - "a/b/c.ts"
YAML
  run_writer "$fixture_directory"
  [ "$status" -eq 0 ]

  local agent_file="$fixture_directory/.claude/agents/code-audit-a.md"
  local before
  before="$(snapshot_file "$agent_file")"

  # Delete a granted bullet AND insert one the roster does not grant, so both
  # halves of the delta appear in the same repair run.
  sed '/^- `a\/b\/\*\.ts`$/d' "$agent_file" > "$fixture_directory/tmp1"
  sed '/^- `a\/\*\*`$/a\
- `docs/**`
' "$fixture_directory/tmp1" > "$fixture_directory/tmp-corrupt"
  mv "$fixture_directory/tmp-corrupt" "$agent_file"
  rm -f "$fixture_directory/tmp1"

  run_writer "$fixture_directory"
  [ "$status" -eq 0 ]
  assert_contains "code-audit-a: +a/b/*.ts" || { echo "case + prefix: $output"; return 1; }
  assert_contains "-docs/**" || { echo "case - prefix: $output"; return 1; }

  local line
  line="$(grep -F 'code-audit-a:' <<<"$output")"
  case "$line" in
    *"+a/b/*.ts"*"-docs/**") : ;;
    *) echo "case order: expected the + list before the - list: $line" >&2; return 1 ;;
  esac

  local expected actual after
  expected="$(member_globs "$fixture_directory" "code-audit-a")"
  actual="$(region_globs "$agent_file")"
  [ "$actual" = "$expected" ] || { echo "case roster order: $actual"; return 1; }

  # The repaired file is byte-identical to the file the first run generated.
  after="$(snapshot_file "$agent_file")"
  assert_files_identical "$before" "$after"
}

# UAT-007: insertion into a definition with no markers.

@test "insertion: a definition with no region gets one after the heading, else after the frontmatter" {
  local shape fixture_directory agent_file
  local heading_line region_start_line prose_line frontmatter_end_line
  for shape in heading frontmatter; do
    fixture_directory="$BATS_TEST_TMPDIR/insertion-$shape"
    fixture_root "$fixture_directory" "$shape" <<'YAML'
auditors:
  - name: code-audit-default
    globs:
      - "app/**"
    default: true
  - name: code-audit-a
    globs:
      - "a/**"
YAML
    run_writer "$fixture_directory"
    [ "$status" -eq 0 ] || { echo "case $shape: $output"; return 1; }

    agent_file="$fixture_directory/.claude/agents/code-audit-a.md"
    [ "$(grep -cxF -- '<!-- gaia:audit-remit:start -->' "$agent_file")" -eq 1 ] || { echo "case $shape: start marker count"; return 1; }
    [ "$(grep -cxF -- '<!-- gaia:audit-remit:end -->' "$agent_file")" -eq 1 ] || { echo "case $shape: end marker count"; return 1; }

    region_start_line="$(grep -n -- '^<!-- gaia:audit-remit:start -->$' "$agent_file" | head -1 | cut -d: -f1)"
    if [ "$shape" = heading ]; then
      # The pre-existing content is present verbatim and in order: the heading,
      # then the region, then the stub's own trailing prose.
      heading_line="$(grep -n -- '^## Remit and self-skip$' "$agent_file" | head -1 | cut -d: -f1)"
      prose_line="$(grep -n -- '^You own things\.$' "$agent_file" | head -1 | cut -d: -f1)"
      [ "$heading_line" -lt "$region_start_line" ] || { echo "case $shape: region not after the heading"; return 1; }
    else
      frontmatter_end_line="$(grep -n -- '^---$' "$agent_file" | sed -n '2p' | cut -d: -f1)"
      prose_line="$(grep -n -- '^# code-audit-a$' "$agent_file" | head -1 | cut -d: -f1)"
      [ "$frontmatter_end_line" -lt "$region_start_line" ] || { echo "case $shape: region not after the frontmatter"; return 1; }
    fi
    [ "$region_start_line" -lt "$prose_line" ] || { echo "case $shape: region not before the trailing prose"; return 1; }

    run bash "$CHECK" --root "$fixture_directory" --config "$fixture_directory/.gaia/audit-ci.yml"
    [ "$status" -eq 0 ] || { echo "case $shape: check: $output"; return 1; }
  done
}

# UAT-008: idempotence.

@test "idempotence: a second run changes nothing, including with a release-skip key, and the check passes remit parity" {
  local fixture_directory="$BATS_TEST_TMPDIR/uat008"
  fixture_root "$fixture_directory" <<'YAML'
auditors:
  - name: code-audit-default
    globs:
      - "zzz-default-only/**"
    default: true
  - name: code-audit-a
    globs:
      - "a/**"
      - "a/b/*.ts"
YAML
  run_writer "$fixture_directory"
  [ "$status" -eq 0 ]

  sed '/^- `a\/b\/\*\.ts`$/d' "$fixture_directory/.claude/agents/code-audit-a.md" > "$fixture_directory/tmp-corrupt"
  mv "$fixture_directory/tmp-corrupt" "$fixture_directory/.claude/agents/code-audit-a.md"

  run_writer "$fixture_directory"
  [ "$status" -eq 0 ]
  local after_first
  after_first="$(find "$fixture_directory" -type f -exec shasum {} + | sort)"

  run_writer "$fixture_directory"
  [ "$status" -eq 0 ]
  local after_second
  after_second="$(find "$fixture_directory" -type f -exec shasum {} + | sort)"

  [ "$after_first" = "$after_second" ] || { echo "case repair: two runs diverged"; return 1; }

  local skip_directory="$BATS_TEST_TMPDIR/skip-idempotent"
  skip_roster_fixture "$skip_directory"
  run_writer "$skip_directory"
  [ "$status" -eq 0 ]
  local before="$BATS_TEST_TMPDIR/skip-before"
  rm -rf "$before"
  cp -R "$skip_directory/.claude/agents" "$before"
  run_writer "$skip_directory"
  [ "$status" -eq 0 ]
  diff -r "$before" "$skip_directory/.claude/agents" || { echo "case release-skip: second run changed the agents"; return 1; }
  run bash "$CHECK" --root "$skip_directory" --config "$skip_directory/.gaia/audit-ci.yml"
  [ "$status" -eq 0 ] || { printf 'case release-skip: %s\n' "$output" >&2; return 1; }
}

# UAT-016: the generated sentences.

@test "region sentences: claimant, default and release-skip claimant regions carry their sentence and no path" {
  local fixture_directory="$BATS_TEST_TMPDIR/uat016"
  fixture_root "$fixture_directory" <<'YAML'
auditors:
  - name: code-audit-default
    globs:
      - "app/**"
    default: true
  - name: code-audit-a
    globs:
      - "a/**"
YAML
  run_writer "$fixture_directory"
  [ "$status" -eq 0 ]
  grep -qF 'Filter the changed-file list against the globs above' "$fixture_directory/.claude/agents/code-audit-a.md" || { echo "case claimant sentence"; return 1; }
  grep -qF 'second precedence tier' "$fixture_directory/.claude/agents/code-audit-default.md" || { echo "case default sentence"; return 1; }

  local sentence_lines
  sentence_lines="$(region_sentence_lines "$fixture_directory/.claude/agents/code-audit-a.md")"
  grep -qE '`|/' <<<"$sentence_lines" && { echo "case no path: claimant"; return 1; }
  sentence_lines="$(region_sentence_lines "$fixture_directory/.claude/agents/code-audit-default.md")"
  grep -qE '`|/' <<<"$sentence_lines" && { echo "case no path: default"; return 1; }

  local skip_directory="$BATS_TEST_TMPDIR/skip-writer"
  skip_roster_fixture "$skip_directory"
  run_writer "$skip_directory"
  [ "$status" -eq 0 ]
  local keyed unkeyed default_agent
  keyed="$skip_directory/.claude/agents/code-audit-a.md"
  unkeyed="$skip_directory/.claude/agents/code-audit-b.md"
  default_agent="$skip_directory/.claude/agents/code-audit-default.md"

  [ "$(region_sentence_lines "$keyed" | wc -l | tr -d ' ')" -eq 1 ] || { echo "case release-skip: keyed sentence line count"; return 1; }
  region_sentence_lines "$keyed" | grep -qF 'Filter the changed-file list against the globs above.' || { echo "case release-skip: keyed filter sentence"; return 1; }
  region_sentence_lines "$keyed" | grep -qF 'removes a GAIA-owned file this branch changes by applying a GAIA release' || { echo "case release-skip: keyed removal sentence"; return 1; }
  region_sentence_lines "$keyed" | grep -qF 'manifest class' || { echo "case release-skip: keyed manifest class"; return 1; }
  region_sentence_lines "$keyed" | grep -qF 'is never removed this way' || { echo "case release-skip: keyed never removed"; return 1; }
  region_sentence_lines "$unkeyed" | grep -qF 'manifest class' && { echo "case release-skip: unkeyed manifest class"; return 1; }
  region_sentence_lines "$unkeyed" | grep -qF 'is never removed this way' && { echo "case release-skip: unkeyed never removed"; return 1; }
  region_sentence_lines "$default_agent" | grep -qF 'manifest class' && { echo "case release-skip: default manifest class"; return 1; }
  region_sentence_lines "$default_agent" | grep -qF 'is never removed this way' && { echo "case release-skip: default never removed"; return 1; }
  region_sentence_lines "$unkeyed" | grep -qF 'removes a GAIA-owned file' && { echo "case release-skip: unkeyed removal sentence"; return 1; }
  region_sentence_lines "$default_agent" | grep -qF 'removes a GAIA-owned file' && { echo "case release-skip: default removal sentence"; return 1; }
  region_sentence_lines "$unkeyed" | grep -qF 'Filter the changed-file list against the globs above.' || { echo "case release-skip: unkeyed filter sentence"; return 1; }
  region_sentence_lines "$default_agent" | grep -qF 'second precedence tier' || { echo "case release-skip: default sentence"; return 1; }
}

# Refusals: malformed markers are refused, not repaired, and a definition with
# neither anchor is refused.

@test "refusals leave the file byte-identical: duplicate start, missing end, reversed pair, neither anchor" {
  local base="$BATS_TEST_TMPDIR/refusal-base"
  fixture_root "$base" <<'YAML'
auditors:
  - name: code-audit-default
    globs:
      - "app/**"
    default: true
  - name: code-audit-a
    globs:
      - "a/**"
YAML
  run_writer "$base"
  [ "$status" -eq 0 ]

  local case_name fixture_directory agent_file before after
  for case_name in duplicate-start missing-end reversed; do
    fixture_directory="$BATS_TEST_TMPDIR/refusal-$case_name"
    rm -rf "$fixture_directory"
    cp -R "$base" "$fixture_directory"
    agent_file="$fixture_directory/.claude/agents/code-audit-a.md"
    case "$case_name" in
      duplicate-start)
        sed '/^<!-- gaia:audit-remit:start -->$/i\
<!-- gaia:audit-remit:start -->
' "$agent_file" > "$fixture_directory/tmp-corrupt"
        mv "$fixture_directory/tmp-corrupt" "$agent_file"
        ;;
      missing-end)
        sed '/^<!-- gaia:audit-remit:end -->$/d' "$agent_file" > "$fixture_directory/tmp-corrupt"
        mv "$fixture_directory/tmp-corrupt" "$agent_file"
        ;;
      reversed)
        # A single balanced pair (start=1, end=1) whose end marker sits ABOVE
        # its start marker. Counting alone reads this as "replace"; only the
        # line-order check catches it. A writer that missed this would print
        # through the start marker, emit the new body, and then drop every
        # remaining line to EOF, including this fixture's distinctive tail line.
        cat > "$agent_file" <<'MD'
---
name: code-audit-a
---

# code-audit-a

## Remit and self-skip

You own things.

<!-- gaia:audit-remit:end -->
- `a/**`

Filter the changed-file list against the globs above.
<!-- gaia:audit-remit:start -->

## Some other important section

THIS TAIL MUST SURVIVE
MD
        ;;
    esac
    before="$(snapshot_file "$agent_file")"

    run_writer "$fixture_directory"
    [ "$status" -eq 1 ] || { echo "case $case_name: status $status: $output"; return 1; }
    assert_contains "code-audit-a" || { echo "case $case_name: member not named: $output"; return 1; }
    after="$(snapshot_file "$agent_file")"
    assert_files_identical "$before" "$after" || { echo "case $case_name: file changed"; return 1; }
    if [ "$case_name" = reversed ]; then
      grep -qxF -- "THIS TAIL MUST SURVIVE" "$agent_file" || { echo "case $case_name: tail lost"; return 1; }
    fi
  done

  # Neither anchor present: refused, naming the member and the file.
  fixture_directory="$BATS_TEST_TMPDIR/refusal-no-anchor"
  fixture_root "$fixture_directory" noanchor <<'YAML'
auditors:
  - name: code-audit-default
    globs:
      - "app/**"
    default: true
  - name: code-audit-a
    globs:
      - "a/**"
YAML
  agent_file="$fixture_directory/.claude/agents/code-audit-a.md"
  before="$(snapshot_file "$agent_file")"
  run_writer "$fixture_directory"
  [ "$status" -eq 1 ] || { echo "case no-anchor: status $status: $output"; return 1; }
  assert_contains "code-audit-a" || { echo "case no-anchor: member not named: $output"; return 1; }
  after="$(snapshot_file "$agent_file")"
  assert_files_identical "$before" "$after" || { echo "case no-anchor: file changed"; return 1; }
}

# Robustness.

@test "robustness: a failed temp directory or region body write is refused with definitions byte-identical" {
  local base="$BATS_TEST_TMPDIR/robustness-base"
  fixture_root "$base" <<'YAML'
auditors:
  - name: code-audit-default
    globs:
      - "app/**"
    default: true
  - name: code-audit-a
    globs:
      - "a/**"
YAML

  # Case unusable TMPDIR. Without the guard this is destructive and silent: an
  # empty temporary directory makes the region body file unwritable, awk's
  # getline cannot tell unreadable from empty, and every definition is
  # rewritten to a region holding the two markers and nothing between them,
  # with exit 0. The writer must refuse instead.
  local fixture_directory="$BATS_TEST_TMPDIR/bad-tmpdir"
  rm -rf "$fixture_directory"
  cp -R "$base" "$fixture_directory"
  local before_default before_a after_default after_a
  before_default="$(snapshot_file "$fixture_directory/.claude/agents/code-audit-default.md")"
  before_a="$(snapshot_file "$fixture_directory/.claude/agents/code-audit-a.md")"

  run env TMPDIR="$fixture_directory/no-such-tmpdir" bash "$WRITER" --root "$fixture_directory" --config "$fixture_directory/.gaia/audit-ci.yml"
  [ "$status" -eq 1 ] || { echo "case TMPDIR: status $status: $output"; return 1; }

  after_default="$(snapshot_file "$fixture_directory/.claude/agents/code-audit-default.md")"
  after_a="$(snapshot_file "$fixture_directory/.claude/agents/code-audit-a.md")"
  assert_files_identical "$before_default" "$after_default" || { echo "case TMPDIR: default changed"; return 1; }
  assert_files_identical "$before_a" "$after_a" || { echo "case TMPDIR: a changed"; return 1; }

  # Case body write failing after mktemp succeeds, the ENOSPC/EIO class the
  # region-body emptiness guard exists for. The TMPDIR case above trips the
  # mktemp guard and returns before the member loop runs; this one covers the
  # state that guard cannot reach. Root ignores mode 500, so the case is
  # skipped there.
  if [ "$(id -u)" -ne 0 ]; then
    fixture_directory="$BATS_TEST_TMPDIR/unwritable-body-dir"
    rm -rf "$fixture_directory"
    cp -R "$base" "$fixture_directory"

    # A PATH shim is the only handle on that directory: the writer names it
    # with a random mktemp suffix, so no fixture can chmod it by name
    # beforehand. The shim delegates to the real mktemp, then strips write
    # permission from what it just created, leaving it readable and traversable
    # so the body write is the only thing that fails. It chmods every mktemp in
    # the writer's process tree, so it assumes exactly one call site there; a
    # second one, such as in the verify-audit-roster.sh child, breaks that call
    # first and surfaces as `--emit-roster failed` rather than as an obvious
    # shim problem.
    local shim real_mktemp
    shim="$BATS_TEST_TMPDIR/mktemp-shim"
    mkdir -p "$shim"
    real_mktemp="$(command -v mktemp)"
    cat > "$shim/mktemp" <<SH
#!/usr/bin/env bash
created_directory="\$("$real_mktemp" "\$@")" || exit 1
chmod 500 "\$created_directory" || exit 1
printf '%s\n' "\$created_directory"
SH
    chmod +x "$shim/mktemp"

    before_default="$(snapshot_file "$fixture_directory/.claude/agents/code-audit-default.md")"
    before_a="$(snapshot_file "$fixture_directory/.claude/agents/code-audit-a.md")"

    run env PATH="$shim:$PATH" bash "$WRITER" --root "$fixture_directory" --config "$fixture_directory/.gaia/audit-ci.yml"
    [ "$status" -eq 1 ] || { echo "case body write: status $status: $output"; return 1; }

    # The emptiness guard is what refused, for every member, and the earlier
    # mktemp guard is not what fired.
    assert_contains "code-audit-default: region body generation failed" || { echo "case body write: default not refused: $output"; return 1; }
    assert_contains "code-audit-a: region body generation failed" || { echo "case body write: a not refused: $output"; return 1; }
    assert_contains "could not create a temporary directory" && { echo "case body write: the mktemp guard fired"; return 1; }

    after_default="$(snapshot_file "$fixture_directory/.claude/agents/code-audit-default.md")"
    after_a="$(snapshot_file "$fixture_directory/.claude/agents/code-audit-a.md")"
    assert_files_identical "$before_default" "$after_default" || { echo "case body write: default changed"; return 1; }
    assert_files_identical "$before_a" "$after_a" || { echo "case body write: a changed"; return 1; }
  fi
  true
}

@test "robustness: an agent file deleted after scaffolding is skipped, others still processed" {
  local fixture_directory="$BATS_TEST_TMPDIR/deleted-agent"
  fixture_root "$fixture_directory" <<'YAML'
auditors:
  - name: code-audit-default
    globs:
      - "app/**"
    default: true
  - name: code-audit-a
    globs:
      - "a/**"
YAML
  rm "$fixture_directory/.claude/agents/code-audit-a.md"

  run_writer "$fixture_directory"
  [ "$status" -eq 0 ]
  assert_contains "code-audit-default: region inserted"
  grep -qxF -- '<!-- gaia:audit-remit:start -->' "$fixture_directory/.claude/agents/code-audit-default.md"
}


# --- The release-skip key ------------------------------------------------------

skip_roster_fixture() {
  fixture_root "$1" <<'YAML'
auditors:
  - name: code-audit-default
    globs:
      - "zzz-default-only/**"
    default: true
  - name: code-audit-a
    globs:
      - "a/**"
    skip_gaia_release_changes: true
  - name: code-audit-b
    globs:
      - "b/**"
YAML
}
