#!/usr/bin/env bats
# UAT-003: absolute paths converted to repo-relative, token-shaped values replaced with <redacted>
# UAT-010: body post-redaction is byte-identical for local save and GH issue surfaces

# TST-03's recheck-halt test uses `run --separate-stderr` (bats >= 1.5.0).
bats_require_minimum_version 1.5.0

HERE="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"
LIBRARY_DIRECTORY="$HERE/lib"
FIXTURES="$HERE/fixtures"

setup() {
  # Source the redact library (defines redact_body)
  # shellcheck source=lib/redact.sh
  source "$LIBRARY_DIRECTORY/redact.sh"

  # Use a synthetic project root for path-conversion tests
  FAKE_ROOT="/Users/testuser/Development/my-project"
}

# Synthetic token bodies are built at run time and never stored in fixture files.
repeat_char() {
  printf '%*s' "$2" '' | tr ' ' "$1"
}

# redact_equals <label> <input> <expected>: the redacted body is exactly <expected>.
redact_equals() {
  local result
  echo "case: $1"
  result="$(redact_body "$FAKE_ROOT" "$2")"
  [[ "$result" == "$3" ]]
}

# redact_case <label> <input> <leaked> [<must-contain>...]: <leaked> (when not
# empty) is gone from the redacted body and each <must-contain> is present.
redact_case() {
  local label="$1" input="$2" leaked="$3" result needle
  shift 3
  echo "case: $label"
  result="$(redact_body "$FAKE_ROOT" "$input")"
  if [[ -n "$leaked" && "$result" == *"$leaked"* ]]; then
    return 1
  fi
  for needle in "$@"; do
    [[ "$result" == *"$needle"* ]] || return 1
  done
  return 0
}

# ---------------------------------------------------------------------------
# Path conversion: rule A (under project root), rule B (outside project root,
# machine-leak fallback) and bare home dirs (/Users/<name>, /home/<name>, /root)
# ---------------------------------------------------------------------------

# bats test_tags=protected
@test "redact_body path conversion and home collapse, one case per input" {
  redact_equals "absolute path under project root becomes repo-relative" \
    "The failing file is $FAKE_ROOT/.claude/hooks/wiki-session-stop.sh" \
    "The failing file is .claude/hooks/wiki-session-stop.sh" || return 1
  redact_equals "multiple absolute paths under project root all converted" \
    "Files: $FAKE_ROOT/app/i18n.ts and $FAKE_ROOT/wiki/.state.json" \
    "Files: app/i18n.ts and wiki/.state.json" || return 1
  redact_equals "absolute path outside project root collapses to filename only" \
    "Config at /Users/testuser/.config/other-tool.json" \
    "Config at other-tool.json" || return 1
  redact_equals "/home/ path outside project root collapses to filename only" \
    "File at /home/runner/.ssh/known_hosts" \
    "File at known_hosts" || return 1
  redact_case "bare /Users/<name> home dir collapses to <home>" \
    "User home is /Users/alice and nothing else" "/Users/alice" "<home>" || return 1
  redact_case "bare /home/<name> home dir collapses to <home>" \
    "The account lives at /home/bob today" "/home/bob" "<home>" || return 1
  # No /root survives the trailing-component collapse.
  redact_equals "/root path with trailing component collapses (no /root survives)" \
    "Running as root from /root/.ssh/id_rsa" \
    "Running as root from id_rsa" || return 1
  redact_case "bare /root collapses to <home>" \
    "Home directory: /root end" "/root" "<home>"
}

# ---------------------------------------------------------------------------
# Token patterns. Each SEC-3 shape sits mid-line with no token|key|secret
# keyword nearby, so the generic fallback cannot mask a missing dedicated pass.
# ---------------------------------------------------------------------------

# bats test_tags=protected
@test "redact_body redacts each token shape, one case per shape" {
  local token

  token="gho_$(repeat_char A 20)"
  redact_case "gho_ GitHub OAuth token is redacted" \
    "Token: $token in the env" "$token" "<redacted>" || return 1

  token="ghp_$(repeat_char B 20)"
  redact_case "ghp_ GitHub PAT is redacted" "GITHUB_TOKEN=$token" "$token" || return 1

  token="sk-ant-api03-$(repeat_char C 20)"
  redact_case "sk-ant- Anthropic API key is redacted" \
    "ANTHROPIC_API_KEY=$token" "$token" || return 1

  token="sk-$(repeat_char D 20)"
  redact_case "sk- OpenAI key is redacted" "key=$token" "$token" || return 1
  token="sk-ant-$(repeat_char E 20)"
  redact_case "sk-ant- takes priority over sk-" "key=$token" "$token" || return 1

  token="glpat-$(repeat_char F 20)"
  redact_case "glpat- GitLab PAT is redacted" "GITLAB_TOKEN=$token" "$token" || return 1

  token="xoxb-$(repeat_char G 10)"
  redact_case "xoxb- Slack token is redacted" "SLACK_TOKEN=$token" "$token" || return 1

  # Lowercase body: no other pattern (AWS, generic) catches it without the github_pat_ pass.
  token="github_pat_$(repeat_char a 30)"
  redact_case "github_pat_ fine-grained PAT is redacted" \
    "Found in shell environment: $token was present" "$token" "<redacted>" || return 1

  token="eyJhbGci.eyJzdW0iOne.abcdefghij0123"
  redact_case "JWT triple-segment token is redacted" \
    "Session JWT was $token in the log" "$token" "<redacted>" || return 1

  token="$(repeat_char a 24)"
  redact_case "Bearer token value is redacted, label preserved" \
    "Authorization: Bearer $token" "Bearer $token" "Bearer <redacted>" || return 1

  token="xapp-1-$(repeat_char G 12)"
  redact_case "xapp- Slack app-level token is redacted" \
    "Slack app credential $token present" "$token" "<redacted>" || return 1

  redact_case "connection-string credentials are redacted, scheme and host preserved" \
    "DB at postgres://dbuser:s3cr3tpass@db.example.com:5432/mydb" \
    "dbuser:s3cr3tpass" "postgres://<redacted>@db.example.com"
}

# ---------------------------------------------------------------------------
# TST-03: sanity-recheck halt path (survivor -> non-zero exit, empty stdout)
# Override sed with cat so the forward passes no-op and a raw token reaches
# the recheck untouched; the recheck greps still fire and must halt.
# ---------------------------------------------------------------------------

# bats test_tags=protected
@test "TST-03: recheck halts with no partial body when a token survives the forward passes" {
  sed() { cat; }
  local fake_token; fake_token="gho_$(repeat_char Z 24)"
  run --separate-stderr redact_body "$FAKE_ROOT" "leaked credential: $fake_token"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
  [[ "$stderr" == *"REDACTION BUG"* ]]
}

# ---------------------------------------------------------------------------
# Env-var value scrub (step 3): names preserved, values scrubbed
# ---------------------------------------------------------------------------

@test "redact_body scrubs env-var values and keeps names" {
  redact_case "env-var name is preserved but value is scrubbed" \
    "HOME=/Users/testuser" "/Users/testuser" "HOME=" "<redacted>" || return 1
  redact_case "ANTHROPIC_API_KEY env-var name preserved, value scrubbed" \
    "ANTHROPIC_API_KEY=some-value-here" "" "ANTHROPIC_API_KEY=<redacted>"
}

# ---------------------------------------------------------------------------
# Idempotency; running redact twice yields same output
# ---------------------------------------------------------------------------

@test "UAT-003: redaction is idempotent (double-pass equals single-pass)" {
  local input="The file at $FAKE_ROOT/app/i18n.ts and HOME=/Users/testuser"
  local first_pass
  first_pass="$(redact_body "$FAKE_ROOT" "$input")"
  local second_pass
  second_pass="$(redact_body "$FAKE_ROOT" "$first_pass")"
  [[ "$first_pass" == "$second_pass" ]]
  # TST-04: the mid-line HOME=/Users/testuser must not survive (env-scrub is
  # line-anchored and misses it; SEC-4's bare-home collapse catches it).
  # Discriminating assertion last (bats keys off the final command's status).
  [[ "$first_pass" != *"/home/"* ]]
  [[ "$first_pass" != *"/Users/"* ]]
}

# ---------------------------------------------------------------------------
# Golden-file roundtrip: redacted input equals the golden, byte for byte
# ---------------------------------------------------------------------------

@test "redact_body output matches each golden fixture byte-for-byte" {
  local pair input_file golden_file result
  for pair in "input-with-secrets.txt golden-secrets-redacted.md" \
    "input-init-failure.txt golden-init-redacted.md"; do
    input_file="$FIXTURES/${pair% *}"
    golden_file="$FIXTURES/${pair#* }"
    echo "case: ${pair% *} redacts to ${pair#* }"
    [[ -f "$input_file" ]] || return 1
    [[ -f "$golden_file" ]] || return 1
    result="$(redact_body "$FAKE_ROOT" "$(cat "$input_file")")"
    [[ "$result" == "$(cat "$golden_file")" ]] || return 1
  done
  return 0
}
