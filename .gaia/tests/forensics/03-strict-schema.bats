#!/usr/bin/env bats
# UAT-007: report file has four headed sections in correct order
# UAT-010: body sections appear in declared order, no extra top-level headers

HERE="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"
FIXTURES="$HERE/fixtures"

# Validate a report body (no frontmatter) has the four required sections
# in the declared order and no other top-level (##) headers.
assert_strict_body_schema() {
  local body="$1"

  # Extract top-level (##) headers
  local headers
  headers="$(printf '%s' "$body" | grep -E '^## ' || true)"

  # Must contain all four required headers
  printf '%s' "$headers" | grep -q '^## Symptom'          || return 1
  printf '%s' "$headers" | grep -q '^## Classification'   || return 1
  printf '%s' "$headers" | grep -q '^## Capture'          || return 1
  printf '%s' "$headers" | grep -q '^## Reproduction context' || return 1

  # Must appear in declared order
  local symptom_line class_line capture_line reproduction_line
  symptom_line="$(printf '%s' "$body" | grep -n '^## Symptom' | head -1 | cut -d: -f1)"
  class_line="$(printf '%s' "$body" | grep -n '^## Classification' | head -1 | cut -d: -f1)"
  capture_line="$(printf '%s' "$body" | grep -n '^## Capture' | head -1 | cut -d: -f1)"
  reproduction_line="$(printf '%s' "$body" | grep -n '^## Reproduction context' | head -1 | cut -d: -f1)"

  [[ -n "$symptom_line" && -n "$class_line" && -n "$capture_line" && -n "$reproduction_line" ]] || return 1
  [[ "$symptom_line" -lt "$class_line" ]]   || return 1
  [[ "$class_line" -lt "$capture_line" ]]   || return 1
  [[ "$capture_line" -lt "$reproduction_line" ]]   || return 1

  # Must have exactly 4 top-level (##) headers, no more.
  # Use printf '%s\n' to ensure trailing newline so wc -l counts correctly.
  local header_count
  header_count="$(printf '%s\n' "$headers" | wc -l | tr -d ' ')"
  [[ "$header_count" -eq 4 ]] || return 1

  return 0
}

# ---------------------------------------------------------------------------
# Schema validation against golden files
# ---------------------------------------------------------------------------

@test "each golden fixture has four ordered sections; the init golden carries classification and capture keys" {
  local name golden body section
  for name in init update secrets other-class; do
    case "$name" in
      other-class) golden="$FIXTURES/golden-other-class.md" ;;
      *) golden="$FIXTURES/golden-$name-redacted.md" ;;
    esac
    echo "case: $name golden file has four required sections in declared order"
    [[ -f "$golden" ]] || return 1
    body="$(cat "$golden")"
    assert_strict_body_schema "$body" || return 1
  done

  body="$(cat "$FIXTURES/golden-init-redacted.md")"

  echo "case: Classification section contains 'class:' and 'evidence:' lines"
  section="$(printf '%s' "$body" | awk '/^## Classification/{found=1} found && /^## / && !/^## Classification/{exit} found{print}')"
  printf '%s' "$section" | grep -q '^class: ' || return 1
  printf '%s' "$section" | grep -q '^evidence: ' || return 1

  echo "case: Capture section contains version fields"
  section="$(printf '%s' "$body" | awk '/^## Capture/{found=1} found && /^## / && !/^## Capture/{exit} found{print}')"
  printf '%s' "$section" | grep -q '^gaia_version: ' || return 1
  printf '%s' "$section" | grep -q '^node: ' || return 1
  printf '%s' "$section" | grep -q '^pnpm: ' || return 1
  # COV-7: claude_code is part of the canonical envelope and must be asserted.
  printf '%s' "$section" | grep -q '^claude_code: ' || return 1
  printf '%s' "$section" | grep -q '^branch: ' || return 1
  printf '%s' "$section" | grep -q '^dirty: '
}

# ---------------------------------------------------------------------------
# TST-02: canonical Capture rendering is byte-identical everywhere.
#
# Header-presence checks (above) never caught the whitespace/indentation drift
# between the three renderings (forensics.md, capture.md, the goldens). These
# two tests pin the canonical form byte-for-byte: no blank line after a `## `
# header, `class_state_files:` immediately followed by two-space-indented list
# items, and the seven canonical envelope keys in declared order.
# ---------------------------------------------------------------------------

@test "TST-02: golden-init Capture block matches the canonical rendering byte-for-byte" {
  local golden="$FIXTURES/golden-init-redacted.md"
  [[ -f "$golden" ]] || skip "golden-init-redacted.md not found"

  local body capture_section
  body="$(cat "$golden")"
  capture_section="$(printf '%s' "$body" | awk '/^## Capture/{found=1} found && /^## / && !/^## Capture/{exit} found{print}')"

  local expected
  expected="$(cat <<'EOF'
## Capture
gaia_version: 1.2.0
node: v20.11.0
pnpm: 8.15.4
claude_code: 1.0.0
branch: main
dirty: false
class_state_files:
  - .gaia/manifest.json: present, version 1.2.0
  - .gaia/local/setup-state.json: present, lastStep "rename"
  - package.json: present, name "gaia" (rename incomplete)
EOF
)"
  [[ "$capture_section" == "$expected" ]]
}

@test "TST-02: golden-other-class is byte-identical to the canonical empty-list rendering" {
  local golden="$FIXTURES/golden-other-class.md"
  [[ -f "$golden" ]] || skip "golden-other-class.md not found"

  local actual expected
  actual="$(cat "$golden")"
  expected="$(cat <<'EOF'
## Symptom
Something went wrong when I ran GAIA but I am not sure which workflow caused it. The output was unexpected and the tool did not complete its task.

## Classification
class: other
evidence: no taxonomy class matched

## Capture
gaia_version: 1.2.0
node: v20.11.0
pnpm: 8.15.4
claude_code: 1.0.0
branch: main
dirty: false
class_state_files: []

## Reproduction context
The user ran a GAIA workflow but the description does not match any known failure taxonomy class. The failure is treated as a probable GAIA bug. The GH issue offer is made without user-config remediation steps.
EOF
)"
  [[ "$actual" == "$expected" ]]
}
