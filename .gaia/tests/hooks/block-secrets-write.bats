#!/usr/bin/env bats

# Tests for .claude/hooks/block-secrets-write.sh.
#
# The guard is a write-time heuristic, not a sandbox: it scans the content an
# Edit/Write/MultiEdit is about to introduce and denies four shapes of obvious
# committed secret (AWS access-key id, GitHub PAT, PEM private-key header, and a
# dotenv-style assignment to a suspicious name). It always exits 0, carrying the
# allow/deny decision in stdout JSON.
#
# The dotenv rule is the only one with an allowlist, because it is the only one
# that matches on a *name* rather than on secret-shaped material: a line whose
# name ends in _TOKEN/_SECRET/_KEY/_PASSWORD is suspicious, so the value decides.
# The allowlist therefore carries the whole weight of the rule's false-positive
# behavior, and the deny cases below are what pin down that widening it does not
# hollow it out.
#
# Writing this file is itself subject to the guard, so every secret-shaped
# fixture is concatenated at runtime from fragments that match no pattern as
# written. Do not "tidy" those into single literals; the guard will deny the
# edit that does it.

# shellcheck disable=SC2016
# SC2016 (expressions don't expand in single quotes) fires on every fixture that
# carries a `$`, which is most of them. Not expanding is the entire point: the
# fixture has to reach the hook as the literal text a real edit would contain,
# so `printf` takes it as an unexpanded argument. The directive is file-wide for
# the same reason the one above is, the fixtures are the file, and leaving it off
# buries the oracle's real output under a warning that is correct for every hit.

setup() {
  . "$BATS_TEST_DIRNAME/helpers/run-hook.sh"
  HOOKS_SOURCE_DIRECTORY=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)
  HOOK_ABSOLUTE_PATH="$HOOKS_SOURCE_DIRECTORY/block-secrets-write.sh"
}

# The payloads below carry shell snippets with quotes of their own, so
# delivery goes through `invoke_hook` (helpers/run-hook.sh) rather than any
# local variant.
run_hook_write() {
  local body="$1"
  local json
  json=$(jq -n --arg content "$body" '{tool_name: "Write", tool_input: {content: $content}}')
  invoke_hook "$json" "$HOOK_ABSOLUTE_PATH"
}

run_hook_edit() {
  local body="$1"
  local json
  json=$(jq -n --arg new_string "$body" '{tool_name: "Edit", tool_input: {new_string: $new_string}}')
  invoke_hook "$json" "$HOOK_ABSOLUTE_PATH"
}

# The two above carry no file_path, which is what every test written before the
# guard read one relies on. These carry one, for the path-scoped exemption.
run_hook_write_path() {
  local path="$1"
  local body="$2"
  local json
  json=$(jq -n --arg file_path "$path" --arg content "$body" \
    '{tool_name: "Write", tool_input: {file_path: $file_path, content: $content}}')
  invoke_hook "$json" "$HOOK_ABSOLUTE_PATH"
}

run_hook_edit_path() {
  local path="$1"
  local body="$2"
  local json
  json=$(jq -n --arg file_path "$path" --arg new_string "$body" \
    '{tool_name: "Edit", tool_input: {file_path: $file_path, new_string: $new_string}}')
  invoke_hook "$json" "$HOOK_ABSOLUTE_PATH"
}

# MultiEdit sits on the same `Edit|Write|MultiEdit` matcher as the two above and
# carries the content in a third place, `edits[].new_string`. It gets its own
# helper because the path-scoped branch is the first to read `file_path`, so the
# tool that reads BOTH fields differently is the one a change to either read is
# likeliest to break silently.
run_hook_multiedit_path() {
  local path="$1"
  local body="$2"
  local json
  json=$(jq -n --arg file_path "$path" --arg new_string "$body" \
    '{tool_name: "MultiEdit", tool_input: {file_path: $file_path, edits: [{new_string: $new_string}]}}')
  invoke_hook "$json" "$HOOK_ABSOLUTE_PATH"
}

assert_denied() {
  assert_denied_by_json
}

# A payload carrying a path and no content, the shape the dotenv path deny
# rules on before any scan.
run_write_hook_edit() {
  local tool="$1" path="$2"
  local json
  json=$(jq -n --arg tool_name "$tool" --arg file_path "$path" '{tool_name: $tool_name, tool_input: {file_path: $file_path}}')
  invoke_hook "$json" "$HOOK_ABSOLUTE_PATH"
}


# --- The three secret-shaped patterns still deny ---

# bats test_tags=protected
@test "an AWS access-key id is denied" {
  local aws_id="AKIA""IOSFODNN7EXAMPLE"
  run_hook_write "const id = '$aws_id'"
  assert_denied
}

# check_verdict LABEL deny|allow
# The run-hook pair leans on errexit for its status line, which a `||` caller
# switches off, so each case-table row checks the JSON verdict here with
# explicit returns and names its own label when it fails.
check_verdict() {
  [ "$status" -eq 0 ] || { echo "case $1: status=$status output=$output"; return 1; }
  if grep -qF -- '"permissionDecision": "deny"' <<<"$output"; then
    [ "$2" = deny ] || { echo "case $1: denied, expected allow: $output"; return 1; }
  else
    [ "$2" = allow ] || { echo "case $1: allowed, expected deny: $output"; return 1; }
  fi
}

# check_message LABEL present|absent NEEDLE
check_message() {
  if grep -qF -- "$3" <<<"$output"; then
    [ "$2" = present ] || { echo "case $1: '$3' present: $output"; return 1; }
  else
    [ "$2" = absent ] || { echo "case $1: '$3' missing: $output"; return 1; }
  fi
}

# Each row below is one call with its exact fixture, then its labelled verdict.

@test "a GitHub personal-access-token and a PEM private-key header are denied" {
  local pat="ghp""_0123456789abcdefghij"
  run_hook_write "const token = '$pat'"
  check_verdict github-pat deny
  local pem="-----BEGIN RSA PRIVATE ""KEY-----"
  run_hook_write "$pem"
  check_verdict pem-header deny
}

@test "a literal dotenv value, or an empty substitution, is denied however substitutions, declarations, expansions, separators or comments surround it" {
  run_hook_write "$(printf 'API_KEY=%s\n' 'sk-live-9f3a1c4e8b7d2064')"
  check_verdict literal deny
  run_hook_edit "$(printf 'DB_PASSWORD=%s\n' 'hunter2-not-a-placeholder')"
  check_verdict literal-edit deny
  run_hook_write "$(printf 'API_KEY=%s\n' '$(whoami)-sk-live-9f3a1c4e8b7d2064')"
  check_verdict substitution-before deny

  # These pin the allowlist's command-substitution arm to "wholly a
  # substitution" rather than "starts with $( and ends with )". The first three
  # are values a both-ends-anchored `\$\(.+\)` admits, because `.` matches the
  # very `)` the closing anchor is supposed to certify; they pin the trailing
  # anchor. The fourth pins the leading one: it never starts with `$(`, so it is
  # the shape a dropped `^` would silently let through.
  run_hook_write "$(printf 'API_KEY=%s\n' '$(true)sk-live-9f3a1c4e8b7d2064$(true)')"
  check_verdict between-substitutions deny
  run_hook_write "$(printf 'API_KEY=%s\n' '$(whoami)sk-live-9f3a1c4e8b7d2064)')"
  check_verdict ends-in-paren deny
  run_hook_write "$(printf 'API_KEY=%s\n' '"$(a)"sk-live-9f3a1c4e8b7d2064"$(b)"')"
  check_verdict quoted-substitutions deny
  run_hook_write "$(printf 'API_KEY=%s\n' 'sk-live-9f3a1c4e8b7d2064$(whoami)')"
  check_verdict substitution-after deny

  # The name grep anchors the suspicious name to the start of the line, so a
  # declaration keyword in front of it took the line out of the scan entirely.
  # `declare -r` and `local -r` are the idiomatic careful-bash spellings, so the
  # keyword carries its options; `typeset` is bash's synonym for `declare`.
  run_hook_write "$(printf 'export API_KEY=%s\n' 'sk-live-9f3a1c4e8b7d2064')"
  check_verdict export deny
  run_hook_write "$(printf 'local API_KEY=%s\n' 'sk-live-9f3a1c4e8b7d2064')"
  check_verdict local deny
  run_hook_edit "$(printf 'readonly DB_PASSWORD=%s\n' 'hunter2-not-a-placeholder')"
  check_verdict readonly-edit deny
  run_hook_write "$(printf 'declare -r API_KEY=%s\n' 'sk-live-9f3a1c4e8b7d2064')"
  check_verdict declare-r deny
  run_hook_write "$(printf 'local -r API_KEY=%s\n' 'sk-live-9f3a1c4e8b7d2064')"
  check_verdict local-r deny
  run_hook_write "$(printf 'readonly -g API_KEY=%s\n' 'sk-live-9f3a1c4e8b7d2064')"
  check_verdict readonly-g deny
  run_hook_write "$(printf 'export -- API_KEY=%s\n' 'sk-live-9f3a1c4e8b7d2064')"
  check_verdict end-of-options deny
  run_hook_write "$(printf 'declare -r -x API_KEY=%s\n' 'sk-live-9f3a1c4e8b7d2064')"
  check_verdict two-flags deny
  run_hook_write "$(printf 'typeset -r API_KEY=%s\n' 'sk-live-9f3a1c4e8b7d2064')"
  check_verdict typeset-r deny

  # The expansion allowance is bounded: a secret does not stop being a secret
  # for sitting inside a default. A segmented secret has the same structure a
  # placeholder does, so the operand arm requires an EMPTY operand rather than a
  # short one: a default value is exactly where a real secret lands, and a UUID
  # clears any per-segment bound.
  run_hook_write "$(printf 'API_KEY=%s\n' '${API_KEY:-sk-live-9f3a1c4e8b7d2064}')"
  check_verdict expansion-default deny
  run_hook_write "$(printf 'export API_KEY=%s\n' '"${PREFIX}sk-live-9f3a1c4e8b7d2064"')"
  check_verdict expansion-concatenated deny
  run_hook_write "$(printf 'API_KEY=%s\n' '${API_KEY:-550e8400-e29b-41d4-a716-446655440000}')"
  check_verdict expansion-default-segmented deny
  run_hook_write "$(printf 'API_KEY=%s\n' '${X}550e8400-e29b-41d4-a716-446655440000')"
  check_verdict expansion-non-path deny

  # The path arm bounds each segment, so the separator buys a path suffix and
  # not an unbounded tail: a secret behind the separator is exactly what the
  # separator must not admit.
  run_hook_write "$(printf 'API_KEY=%s\n' '${X}/sk-live-9f3a1c4e8b7d2064')"
  check_verdict behind-slash deny
  run_hook_write "$(printf 'API_KEY=%s\n' '${X}.sk-live-9f3a1c4e8b7d2064')"
  check_verdict behind-dot deny
  run_hook_write "$(printf 'export API_KEY=%s\n' '"${VAULT}/550e8400-e29b-41d4-a716-446655440000"')"
  check_verdict behind-path-segmented deny

  # A variable reference inside a command-substitution body must not buy the
  # value an expansion arm: that would re-open the very splice the `$(…)` arm
  # exists to close.
  run_hook_write "$(printf 'API_KEY=%s\n' '$(echo ${X})550e8400-e29b-41d4-a716-446655440000')"
  check_verdict substitution-body-variable deny

  # A trailing comment strips the comment, not the scan. The tail comes off the
  # value but is never discarded unread: a placeholder on the left with the real
  # key parked in the comment is the plausible accident; a second assignment
  # after `;` is worse in kind, because the discarded text is executable.
  run_hook_write "$(printf 'export API_KEY=%s\n' '"sk-live-9f3a1c4e8b7d2064" # from vault')"
  check_verdict ahead-of-comment deny
  run_hook_write "$(printf 'API_KEY=%s\n' '$MY_VAR # sk-live-9f3a1c4e8b7d2064')"
  check_verdict parked-in-comment deny
  run_hook_write "$(printf 'API_KEY=%s\n' '  # sk-live-9f3a1c4e8b7d2064')"
  check_verdict parked-beside-empty deny
  run_hook_write "$(printf 'API_KEY=%s\n' '<paste> # sk-live-9f3a1c4e8b7d2064')"
  check_verdict parked-behind-placeholder deny
  run_hook_write "$(printf 'API_KEY=%s\n' '"" ; API_TOKEN=sk-live-9f3a1c4e8b7d2064')"
  check_verdict second-assignment deny

  # An executable separator has to be preceded by whitespace to open a tail, so
  # a bare `;` behind a value is read as part of it and the line is denied. That
  # grammar stays on purpose: `a;b` is ordinary content in a dotenv value.
  run_hook_write "$(printf 'GH_TOKEN=%s; export GH_TOKEN\n' '$(gh auth token 2>/dev/null || true)')"
  check_verdict bare-separator deny

  # The tail's shape rule only sees a run of 13+ alphanumerics mixing letters
  # and digits, so an assignment parked after a separator clears it whenever the
  # value is shorter or carries no digit; an executable tail carrying an
  # assignment is judged by the assignment rule instead.
  run_hook_write "$(printf 'API_KEY=%s\n' '"" ; API_TOKEN=abc123xyz')"
  check_verdict short-second-assignment deny
  run_hook_write "$(printf 'API_KEY=%s\n' '<paste> ; REAL_KEY=correcthorsebattery')"
  check_verdict all-letter-second-assignment deny

  # A tail carrying no watched assignment still reaches the shape rule; the
  # substitution arm's own `[^)]+` declines an empty body.
  run_hook_write "$(printf 'export API_KEY=%s\n' '$X ; OUT=$(echo hunter2xyz123)')"
  check_verdict tail-substitution-no-assignment deny
  run_hook_write "$(printf 'export API_KEY=%s\n' '$X ; A_TOKEN=$()')"
  check_verdict tail-empty-substitution deny

  # `secret_shaped` is fed by process substitution rather than sitting at the
  # end of a pipe, and it fails in the worse direction. Under `pipefail` the
  # pipeline's status IS the function's return value, and its `grep -q` leaves
  # on the first match; on a tail carrying enough runs that the producer is
  # still writing, the producer takes SIGPIPE and the pipeline reports 141.
  # Written as a bare pipeline the shape backstop then reports NOT
  # secret-shaped on exactly the tails densest with secret-shaped material, so
  # the guard fails OPEN. Only length exposes it; the short parked-in-comment
  # row above passes either way.
  local runs
  runs=$(yes 'hunter2xyz123' | head -n 4000 | tr '\n' ' ')
  run_hook_write "$(printf 'export API_KEY=%s\n' "\$X # ${runs}")"
  check_verdict long-comment-tail deny
}

@test "empty, variable, placeholder, expansion and computed values, and secret-free shell tails, are allowed" {
  run_hook_write "$(printf 'API_KEY=\n')"
  check_verdict empty allow
  run_hook_write "$(printf 'API_KEY=%s\n' '$MY_API_KEY')"
  check_verdict bare-var allow
  run_hook_write "$(printf 'API_KEY=%s\n' '${MY_API_KEY}')"
  check_verdict braced-var allow
  run_hook_write "$(printf 'API_KEY=%s\n' 'placeholder')"
  check_verdict named-placeholder allow
  run_hook_write "export function add(a, b) { return a + b }"
  check_verdict no-secret-shape allow

  # The tightened substitution arms have to stay usable: these are the
  # placeholder values the arms exist to admit, and the ones a too-eager anchor
  # would take down with the splices.
  run_hook_write "$(printf 'API_KEY=%s\n' '<your-key-here>')"
  check_verdict angle-bracket allow
  run_hook_write "$(printf 'API_KEY=%s\n' 'your-api-key-here')"
  check_verdict your-dash allow
  run_hook_write "$(printf 'API_KEY=%s\n' 'example')"
  check_verdict example allow
  run_hook_write "$(printf 'API_KEY=%s\n' 'example.com')"
  check_verdict example-domain allow
  run_hook_write "$(printf 'export API_KEY=%s\n' '$MY_API_KEY')"
  check_verdict exported-var allow
  run_hook_write "$(printf 'GITHUB_TOKEN=%s\n' 'your-github-personal-access-token')"
  check_verdict long-segmented-your allow
  run_hook_write "$(printf 'SUPABASE_ANON_KEY=%s\n' 'your_supabase_anon_key_here')"
  check_verdict underscore-your allow

  # Recognizing the declaration keywords pulls shell lines into a rule written
  # for dotenv files, and a shell value references a variable far more often
  # than a dotenv value does. These carry no literal secret but the
  # bare-identifier `${VAR}` arm alone would deny the expansions.
  run_hook_write "$(printf 'export GITHUB_TOKEN=%s\n' '"${GITHUB_TOKEN:-}"')"
  check_verdict default-operator allow
  run_hook_write "$(printf 'local CACHE_KEY=%s\n' '"${1}"')"
  check_verdict positional-braced allow
  run_hook_write "$(printf 'readonly SIGNING_KEY=%s\n' '"${REPO_ROOT}/dev.pem"')"
  check_verdict expansion-path allow
  run_hook_write "$(printf 'export GH_TOKEN=%s\n' '"fake-token"')"
  check_verdict fake-placeholder allow

  # A value that is wholly a command substitution is resolved at run time, so
  # the source line carries nothing to leak. Denying it taught callers to launder
  # the assignment through a throwaway variable or an off-target name. The arm
  # reads shape, not meaning: a nested `$(op read op://vault/$(hostname))` is
  # denied, and `$(echo <a-literal-secret>)` is allowed; neither is pinned,
  # because neither is behavior worth freezing.
  run_hook_write "$(printf 'AUDIT_KEY="%s"\n' '$(gaia_audit_key "$BASE_SHA")')"
  check_verdict wholly-substitution allow
  run_hook_write "$(printf 'SESSION_TOKEN=%s\n' '$(mint_token)')"
  check_verdict unquoted-substitution allow
  run_hook_edit "$(printf 'AUDIT_KEY="%s"\n' '$(gaia_audit_key "$BASE_SHA")')"
  check_verdict substitution-edit allow

  # Pulling shell lines into a dotenv rule means it sees shapes a dotenv file
  # never carries: a trailing comment, a trailing operator, an unbraced
  # positional, two references concatenated. None holds a literal, and denying
  # them is a hard block whose stated remedy is what the line already does.
  # Ordinary prose in a comment is not secret-shaped either.
  run_hook_write "$(printf 'export GITHUB_TOKEN=%s\n' '"$GH_PAT" # for gh cli')"
  check_verdict trailing-comment allow
  run_hook_write "$(printf 'local API_KEY=%s\n' '"$1" || true')"
  check_verdict trailing-or-clause allow
  run_hook_write "$(printf 'local API_KEY=%s\n' '"$1"')"
  check_verdict unbraced-positional allow
  run_hook_write "$(printf 'export API_KEY=%s\n' '"${A}${B}"')"
  check_verdict two-references allow
  run_hook_write "$(printf 'export GITHUB_TOKEN=%s\n' '"$GH_PAT" # authentication for the gh cli')"
  check_verdict prose-comment allow

  # A `;`, `&&`, or `||` can sit INSIDE the value rather than after it, and the
  # tail strip is a regex with no quoting context. Judging the untrimmed value
  # FIRST bounds the strip to turning a deny into an allow, never the reverse.
  # The guarded-substitution idiom is how this repo's own audit scripts write a
  # fallible command substitution, so getting the order wrong hard-blocks them.
  run_hook_write "$(printf 'AUDIT_KEY=%s\n' '"$(gaia_audit_key "$BASE" "$ROOT" 2>/dev/null || true)"')"
  check_verdict or-inside-substitution allow
  run_hook_write "$(printf 'GH_TOKEN=%s\n' '$(gh auth token 2>/dev/null && :)')"
  check_verdict and-inside-substitution allow
  run_hook_write "$(printf 'API_KEY=%s\n' '<paste || generate>')"
  check_verdict separator-in-placeholder allow

  # The rescan reuses the value allowlist rather than denying on the name alone.
  # The fragment loop is fed by process substitution rather than a pipe so
  # `tail_has_assignment` survives it; a pipe-fed rewrite shows only when the
  # tail is BOTH assignment-carrying and secret-shaped (the last row).
  run_hook_write "$(printf 'API_KEY=%s\n' '$X ; OTHER_TOKEN=${Y}')"
  check_verdict allowed-tail-assignment allow
  local long_variable_name="LONGVARNAME""1234567"
  run_hook_write "$(printf 'API_KEY=%s\n' "\$X ; OTHER_TOKEN=\${$long_variable_name}")"
  check_verdict allowed-secret-shaped-tail-assignment allow
}

# --- `.env.example` drops the ALLOWLIST, not the rule ---
#
# `.env.example` is a committed file whose entire purpose is to carry
# placeholder assignments, and both sibling guards already say so: the read
# guard exempts it while denying the rest of the dotenv family, and the env
# write guard exempts it by the same basename on this very matcher. The
# assignment rule was the one holdout, so the file that exists to hold
# placeholders could not be edited, and its deny told the author to use a
# gitignored `.env`, which is backwards for exactly this file. Its own tracked
# `SESSION_SECRET` line is the worked example: five letters, so it clears no
# placeholder arm at all.
#
# What replaces the allowlist there is the shape rule, not nothing. The
# allowlist asks "is this a recognized placeholder", which every honest
# `.env.example` value fails; shape asks "is this an unbroken 13+ alphanumeric
# run mixing letters and digits", which every one of them passes and a pasted
# key does not. The pattern rules run there as everywhere.

@test "a .env.example value is allowed when short, all-letter, a URL, segmented or slash-broken, through Write, Edit and MultiEdit" {
  run_hook_write_path '.env.example' "$(printf 'SESSION_SECRET=%s\n' 'local')"
  check_verdict short-placeholder allow
  run_hook_write_path '.env.example' "$(printf '%s\n%s\n%s\n' \
    'SITE_URL=http://localhost:5173' 'SESSION_SECRET=local' 'MSW_ENABLED=true')"
  check_verdict tracked-content-whole allow
  # The values the ALLOWLIST would refuse and shape accepts: the whole point of
  # dropping the allowlist for this file.
  run_hook_write_path '.env.example' "$(printf 'SESSION_SECRET=%s\n' 'development')"
  check_verdict all-letter allow
  run_hook_write_path '.env.example' "$(printf 'API_KEY=%s\n' 'http://localhost:3001/api/')"
  check_verdict localhost-url allow
  run_hook_edit_path '.env.example' "$(printf 'SESSION_SECRET=%s\n' '"local"')"
  check_verdict short-edit allow
  run_hook_multiedit_path '.env.example' "$(printf 'SESSION_SECRET=%s\n' 'local')"
  check_verdict short-multiedit allow
  run_hook_write_path 'packages/api/.env.example' "$(printf 'SESSION_SECRET=%s\n' 'local')"
  check_verdict nested-basename allow
  # Where the shape backstop stops, pinned so the limit is enforced as
  # documented. The bound is on the RUN, not the value, so a segmented secret
  # clears however much material it carries: every run in a UUID-format key is
  # under 13 or all digits, and a `/` breaks a base64 secret the same way. That
  # is the accepted cost of judging this one file by shape; these rows (and the
  # outside-UUID deny row) fail the moment someone narrows or widens it.
  run_hook_write_path '.env.example' \
    "$(printf 'API_KEY=%s\n' '550e8400-e29b-41d4-a716-446655440000')"
  check_verdict segmented-uuid allow
  run_hook_write_path '.env.example' \
    "$(printf 'API_KEY=%s\n' 'aB3xK9pQ7zR2/wL5tN8mV4cX/pQ7zR2wL5tN')"
  check_verdict slash-broken allow
}

# A committed file is the worst place for a real key, so dropping the allowlist
# must not drop the backstop; the pattern rules do not care which file they are
# writing into; and the exemption is scoped to that one basename.
@test "a secret-shaped value in .env.example is denied (shape, comment, AWS, PAT, PEM), and values it exempts are denied outside it" {
  run_hook_write_path '.env.example' "$(printf 'API_KEY=%s\n' 'sk-live-9f3a1c4e8b7d2064')"
  check_verdict shaped-literal deny
  run_hook_edit_path '.env.example' "$(printf 'API_KEY=%s\n' 'aB3xK9pQ7zR2wL5t')"
  check_verdict shaped-literal-edit deny
  run_hook_multiedit_path '.env.example' "$(printf 'API_KEY=%s\n' 'aB3xK9pQ7zR2wL5t')"
  check_verdict shaped-literal-multiedit deny
  run_hook_write_path '.env.example' "$(printf 'SESSION_SECRET=%s\n' 'local # real: sk-live-9f3a1c4e8b7d2064')"
  check_verdict parked-in-comment deny
  run_hook_write_path 'app/config.ts' \
    "$(printf 'API_KEY=%s\n' '550e8400-e29b-41d4-a716-446655440000')"
  check_verdict uuid-outside deny
  local aws_id="AKIA""IOSFODNN7EXAMPLE"
  run_hook_write_path '.env.example' "$(printf 'AWS_ACCESS_KEY_ID=%s\n' "$aws_id")"
  check_verdict aws-id deny
  local pat="ghp""_0123456789abcdefghij"
  run_hook_write_path '.env.example' "$(printf 'GH_TOKEN=%s\n' "$pat")"
  check_verdict github-pat deny
  local pem="-----BEGIN RSA PRIVATE ""KEY-----"
  run_hook_write_path '.env.example' "$pem"
  check_verdict pem-header deny
  run_hook_write_path 'app/config.ts' "$(printf 'SESSION_SECRET=%s\n' 'local')"
  check_verdict short-value-outside deny
}

# Dropping the allowlist drops the executable-tail rescan with it: the whole
# post-`=` remainder is shape-tested as one string here, so a second assignment
# parked after a separator is judged by shape rather than allowlist-rescanned.
# That inverts what the general path's own tail rows pin, which is why it is
# pinned here.
#
# The SPACE before each `;` is load-bearing. The tail extractor requires
# `[[:space:]]+` ahead of the separator, so `local;` opens no tail at all and
# the general-path deny would arrive from the primary-value allowlist instead,
# leaving these rows naming a rescan they never reach. The outside row asserts
# the rescan's own message for that reason: it fails if the space is ever
# dropped, rather than passing on the wrong arm.
@test "an executable tail in .env.example is judged by shape, elsewhere by the rescan" {
  run_hook_write_path '.env.example' \
    "$(printf 'SESSION_SECRET=%s ; API_KEY=%s\n' 'local' 'abcd')"
  check_verdict example-shape-allow allow
  run_hook_write_path 'app/config.ts' \
    "$(printf 'SESSION_SECRET=%s ; API_KEY=%s\n' 'local' 'abcd')"
  check_message outside-rescan present 'parks a secret assignment after a shell separator'
  check_verdict outside-rescan deny
  run_hook_write_path '.env.example' \
    "$(printf 'SESSION_SECRET=%s ; API_KEY=%s\n' 'local' 'aB3xK9pQ7zR2wL5t')"
  check_verdict example-shaped-tail deny
}

# A dash-leading path must not be read as a basename option. The verdict is safe
# either way (no exemption, full scan), but `basename --` keeps the usage error
# off the hook's stderr, matching block-sensitive-read.sh.

# The needle has to cover BOTH basename flavors, because the VERDICT does not
# move when `--` is dropped: an empty basename matches no exemption and the file
# is scanned in full, so `assert_denied` passes either way and these two lines
# are the only thing standing between the mutant and a green run. BSD says
# `illegal option`, GNU says `invalid option` and points at `basename --help`,
# so a BSD-only needle is inert on the ubuntu runner, which is the authoritative
# gate (see .claude/rules/bats-assertions.md).
@test "a dash-leading path is scanned without a basename usage error" {
  run_hook_write_path '-.env.example' "$(printf 'SESSION_SECRET=%s\n' 'local')"
  grep -qiE -- 'illegal option|invalid option|usage: basename|basename --help' <<<"$output" && return 1
  assert_denied
}

@test "a real dotenv file or a name merely starting with .env.example is not exempt" {
  run_hook_write_path '.env' "$(printf 'SESSION_SECRET=%s\n' 'local')"
  check_verdict real-dotenv deny
  run_hook_write_path '.env.example.local' "$(printf 'SESSION_SECRET=%s\n' 'local')"
  check_verdict lookalike-name deny
}

# A payload carrying no file_path cannot be exempted, so it is scanned. This is
# what keeps every row written before the guard read a path meaningful, and it
# is the fail-closed direction.

@test "a payload with no file_path is still scanned" {
  run_hook_write "$(printf 'SESSION_SECRET=%s\n' 'local')"
  assert_denied
}

# --- The dotenv path deny: rules on the target path before any content scan ---

# bats test_tags=protected
@test "Write to .env.production is denied with the dotenv write message" {
  run_hook_write_path '.env.production' 'PORT=3000'
  assert_denied_by_json
  grep -qF -- "BLOCKED: writes to '.env.production' are forbidden. .env files must remain gitignored and edited manually by the developer." <<<"$output"
}

# Every gate explains itself: the dotenv denial says why the write is blocked,
# not only that the developer edits the file. The path message wins over the
# content scan when both would deny.
@test "dotenv path deny: Edit on .env.local, a nested .env, the reason, the path message first; .env.example passes to the content scan" {
  run_write_hook_edit "Edit" ".env.local"
  check_verdict edit-env-local deny
  run_write_hook_edit "Write" ".env.example"
  check_verdict path-only-env-example allow
  run_hook_write_path '.env' 'PORT=3000'
  check_verdict reason deny
  check_message reason present 'They hold local secrets this session is kept from reading, so a write here would overwrite values it cannot see.'
  local aws_id="AKIA""IOSFODNN7EXAMPLE"
  run_hook_write_path '.env.production' "const id = '$aws_id'"
  check_verdict path-message-wins deny
  check_message path-message-wins present "writes to '.env.production' are forbidden"
  check_message path-message-wins absent "AWS access-key"
  run_hook_write_path '.env.example' 'PORT=3000'
  check_verdict env-example-clean allow
  run_hook_write_path 'packages/api/.env' 'PORT=3000'
  check_verdict nested-env deny
  check_message nested-env present "writes to 'packages/api/.env' are forbidden"
}
