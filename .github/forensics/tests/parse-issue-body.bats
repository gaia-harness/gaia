#!/usr/bin/env bats
# Tests for `.github/forensics/parse-issue-body.sh`.
#
# Coverage:
#   - deterministic regex extraction (no LLM)
#   - malformed body → needs-human signal (script returns
#     valid=false with a precise error code)
#   - redaction tokens pass through verbatim
#   - frontmatter is optional; when absent, `class` is derived from
#     the `## Classification` section content

setup() {
  THIS_DIRECTORY="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  PARSER="$THIS_DIRECTORY/../parse-issue-body.sh"
  FIXTURES="$THIS_DIRECTORY/fixtures"
}

# ---------------------------------------------------------------------------
# Happy path: a SPEC-001-conformant body parses to valid JSON with the four
# required sections and the three required frontmatter keys.
# ---------------------------------------------------------------------------

@test "valid body parses: valid:true and frontmatter fields class, gaia_version, created, gh_issue_url" {
  # One parse serves every case below.
  run "$PARSER" "$FIXTURES/valid.md"
  [ "$status" -eq 0 ]

  echo "case: valid body returns valid:true"
  [[ "$output" == *'"valid":true'* ]] || return 1

  echo "case: valid body extracts class from frontmatter"
  [[ "$output" == *'"class":"quality-gate"'* ]] || return 1

  echo "case: valid body extracts gaia_version from frontmatter"
  [[ "$output" == *'"gaia_version":"1.4.2"'* ]] || return 1

  echo "case: valid body extracts created from frontmatter"
  [[ "$output" == *'"created":"2026-05-08"'* ]] || return 1

  echo "case: valid body extracts optional gh_issue_url when present"
  [[ "$output" == *'"gh_issue_url":"https://github.com/gaia-react/gaia/issues/123"'* ]] || return 1
}

@test "valid body extracts the four sections and the JSON shape" {
  # One parse serves every case below.
  run "$PARSER" "$FIXTURES/valid.md"
  [ "$status" -eq 0 ]

  echo "case: valid body extracts symptom section"
  # Body contains backtick-fenced inline code; ensure it survives.
  [[ "$output" == *'pnpm typecheck'* ]] || return 1
  [[ "$output" == *'TS2304'* ]] || return 1

  echo "case: valid body extracts classification section"
  [[ "$output" == *'class: quality-gate'* ]] || return 1
  [[ "$output" == *'evidence:'* ]] || return 1

  echo "case: valid body extracts capture section preserving fenced block"
  [[ "$output" == *'node_version: v20.11.0'* ]] || return 1
  [[ "$output" == *'pnpm_version: 9.0.0'* ]] || return 1

  echo "case: valid body extracts reproduction_context section"
  [[ "$output" == *'.claude/hooks/wiki-session-stop.sh'* ]] || return 1
  [[ "$output" == *'.claude/hooks/post-tool.sh'* ]] || return 1

  echo "case: success JSON contains frontmatter and sections objects"
  [[ "$output" == *'"frontmatter":{'* ]] || return 1
  [[ "$output" == *'"sections":{'* ]] || return 1
  [[ "$output" == *'"symptom":'* ]] || return 1
  [[ "$output" == *'"classification":'* ]] || return 1
  [[ "$output" == *'"capture":'* ]] || return 1
  [[ "$output" == *'"reproduction_context":'* ]] || return 1
}

# ---------------------------------------------------------------------------
# Failure modes, UAT-013 (malformed body → needs-human without LLM).
# Each failure emits valid:false plus a precise error code.
# ---------------------------------------------------------------------------

# RT-03: the same canonical header appearing twice is a duplicate. The
# parser rejects loudly rather than silently corrupting the body.
# bats test_tags=protected
@test "malformed bodies return valid:false with a precise error code" {
  echo "case: missing symptom returns missing-section"
  run "$PARSER" "$FIXTURES/missing-symptom.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"valid":false'* ]] || return 1
  [[ "$output" == *'"error":"missing-section"'* ]] || return 1
  [[ "$output" == *'"symptom"'* ]] || return 1

  echo "case: duplicate canonical header returns duplicate-section-header (RT-03)"
  run "$PARSER" "$FIXTURES/duplicate-section-header.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"valid":false'* ]] || return 1
  [[ "$output" == *'"error":"duplicate-section-header"'* ]] || return 1
  [[ "$output" == *'"Capture"'* ]] || return 1

  echo "case: frontmatter without closing delimiter returns malformed-frontmatter"
  body_file="$BATS_TEST_TMPDIR/no-close.md"
  cat > "$body_file" <<'EOF'
---
class: hook
gaia_version: 1.4.2
created: 2026-05-08

## Symptom

Body without the closing frontmatter delimiter.

## Classification

class: hook
evidence: none.

## Capture

```
empty
```

## Reproduction context

- `.claude/hooks/x.sh`
EOF
  run "$PARSER" "$body_file"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"valid":false'* ]] || return 1
  [[ "$output" == *'"error":"malformed-frontmatter"'* ]] || return 1

  echo "case: frontmatter missing class falls through to Classification derivation"
  # When the frontmatter doesn't carry `class:` and the `## Classification`
  # section also lacks a `class: <tag>` line, the parser reports the
  # missing class explicitly rather than treating it as a frontmatter
  # problem, `class` is the one load-bearing field downstream.
  body_file="$BATS_TEST_TMPDIR/no-class.md"
  cat > "$body_file" <<'EOF'
---
gaia_version: 1.4.2
created: 2026-05-08
---

## Symptom

x

## Classification

x

## Capture

x

## Reproduction context

x
EOF
  run "$PARSER" "$body_file"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"valid":false'* ]] || return 1
  [[ "$output" == *'"error":"missing-class"'* ]] || return 1

  echo "case: empty section body returns empty-section"
  body_file="$BATS_TEST_TMPDIR/empty-symptom.md"
  cat > "$body_file" <<'EOF'
---
class: hook
gaia_version: 1.4.2
created: 2026-05-08
---

## Symptom

## Classification

x

## Capture

x

## Reproduction context

x
EOF
  run "$PARSER" "$body_file"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"valid":false'* ]] || return 1
  [[ "$output" == *'"error":"empty-section"'* ]] || return 1
  [[ "$output" == *'"symptom"'* ]] || return 1

  echo "case: all four sections missing reports them all"
  body_file="$BATS_TEST_TMPDIR/no-sections.md"
  cat > "$body_file" <<'EOF'
---
class: other
gaia_version: 1.4.2
created: 2026-05-08
---

just freeform text, no headers at all.
EOF
  run "$PARSER" "$body_file"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"valid":false'* ]] || return 1
  [[ "$output" == *'"error":"missing-section"'* ]] || return 1
  [[ "$output" == *'"symptom"'* ]] || return 1
  [[ "$output" == *'"classification"'* ]] || return 1
  [[ "$output" == *'"capture"'* ]] || return 1
  [[ "$output" == *'"reproduction_context"'* ]] || return 1
}

@test "absent frontmatter: class derived from Classification section" {
  echo "case: missing frontmatter still parses; class is derived from Classification"
  # Frontmatter is optional. The GH-issue body shape ships without one
  # in some workflows; `class` is derived from the `class: <tag>` line
  # inside the `## Classification` section instead.
  run "$PARSER" "$FIXTURES/missing-frontmatter.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"valid":true'* ]] || return 1
  [[ "$output" == *'"class":"other"'* ]] || return 1

  echo "case: frontmatterless body with class in Classification parses cleanly"
  body_file="$BATS_TEST_TMPDIR/no-fm.md"
  cat > "$body_file" <<'EOF'
## Symptom

`/update-gaia` skipped a file even though the manifest declared it owned.

## Classification

class: update
evidence: "three-way merge" + .gaia/manifest.json

## Capture

gaia_version: 1.4.2
node: v22.0.0

## Reproduction context

Routine /update-deps run; downstream CI broke because a file was missing.
EOF
  run "$PARSER" "$body_file"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"valid":true'* ]] || return 1
  [[ "$output" == *'"class":"update"'* ]] || return 1
  [[ "$output" == *'"gaia_version":"1.4.2"'* ]] || return 1
}

# RT-02: a non-canonical `## ` line (inside a fenced block or in a
# section body) is retained as section content, never flagged malformed.
# Only the four exact canonical headers start a section.
@test "non-canonical ## line is retained as content (RT-02)" {
  run "$PARSER" "$FIXTURES/noncanonical-header.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"valid":true'* ]]
  # Inside a fenced block: the pasted `## Error output` line survives.
  [[ "$output" == *'## Error output'* ]]
  [[ "$output" == *'Traceback (most recent call last):'* ]]
  # Outside a fence, in a section body: `## Notes from the report` is
  # content of `## Reproduction context`, not a malformed header.
  [[ "$output" == *'## Notes from the report'* ]]
  [[ "$output" == *'.claude/hooks/x.sh'* ]]
}

# ---------------------------------------------------------------------------
# UAT-015, redaction tokens pass through verbatim.
# ---------------------------------------------------------------------------

@test "redaction tokens pass through each section verbatim" {
  # One parse serves every case below.
  run "$PARSER" "$FIXTURES/redaction-passthrough.md"
  [ "$status" -eq 0 ]

  echo "case: redaction tokens pass through symptom verbatim"
  [[ "$output" == *'<redacted>'* ]] || return 1

  echo "case: redaction tokens pass through capture verbatim"
  # capture section contains both tokens; both must appear byte-identically.
  [[ "$output" == *'api_key: <redacted>'* ]] || return 1
  [[ "$output" == *'config_path: <repo-relative-paths>'* ]] || return 1
  [[ "$output" == *'git_branch: feature/<redacted>-fix'* ]] || return 1

  echo "case: redaction tokens pass through reproduction_context verbatim"
  [[ "$output" == *'- `<repo-relative-paths>`'* ]] || return 1
  [[ "$output" == *'file at `<repo-relative-paths>` referencing `<redacted>`'* ]] || return 1
}

@test "optional gh_issue_url is null when absent from frontmatter" {
  run "$PARSER" "$FIXTURES/redaction-passthrough.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"gh_issue_url":null'* ]]
}

# ---------------------------------------------------------------------------
# CLI / script-error contract.
# ---------------------------------------------------------------------------

@test "usage errors exit 2" {
  echo "case: no args prints usage and exits 2"
  run "$PARSER"
  [ "$status" -eq 2 ]

  echo "case: missing input file exits 2"
  run "$PARSER" "$BATS_TEST_TMPDIR/does-not-exist.md"
  [ "$status" -eq 2 ]
}

# ---------------------------------------------------------------------------
# Internal-error JSON envelope. When awk fails, the script must NOT fall
# through to a default valid:false; it must emit `{"internal_error":true,...}`
# so the workflow can distinguish infrastructure failure from a malformed
# body.
# ---------------------------------------------------------------------------

@test "awk failure emits internal-error JSON envelope (not valid:false)" {
  # Shadow `awk` with a stub that always exits non-zero. The script is
  # invoked via `env PATH=...` so it picks up the stub before the system
  # awk. Exit-code check on the FIRST awk call (frontmatter-extract)
  # fires immediately.
  fake_bin="$BATS_TEST_TMPDIR/fake-bin"
  mkdir -p "$fake_bin"
  cat > "$fake_bin/awk" <<'STUB'
#!/usr/bin/env bash
exit 7
STUB
  chmod +x "$fake_bin/awk"

  run env PATH="$fake_bin:$PATH" "$PARSER" "$FIXTURES/valid.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"internal_error":true'* ]]
  [[ "$output" == *'"stage":"frontmatter-extract"'* ]]
  [[ "$output" == *'"exit_code":7'* ]]
  # Critical: the failure path does NOT pretend to be a malformed body.
  [[ "$output" != *'"valid":false'* ]]
}
