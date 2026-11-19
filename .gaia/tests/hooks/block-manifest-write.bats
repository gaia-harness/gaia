#!/usr/bin/env bats

# Tests for .claude/hooks/block-manifest-write.sh.
#
# `.gaia/manifest.json` is release-generated; adopter feature work never adds
# to it. This guard denies writes to it through the edit tools (Edit / Write /
# MultiEdit, no exemption) and through common Bash write vectors (output
# redirects, tee, sed -i, sponge, cp/mv as destination), while allowing reads
# and the two legitimate Bash writers that prepend the GAIA_MANIFEST_WRITE=
# exemption marker. The guard is best-effort, not airtight: it always exits 0,
# carrying the allow/deny decision in stdout JSON.

setup() {
  . "$BATS_TEST_DIRNAME/helpers/run-hook.sh"
  HOOKS_SOURCE_DIRECTORY=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)
  HOOK_ABSOLUTE_PATH="$HOOKS_SOURCE_DIRECTORY/block-manifest-write.sh"
  SETTINGS_ABSOLUTE_PATH="${HOOKS_SOURCE_DIRECTORY%/hooks}/settings.json"
}

# Several payloads below carry Bash commands with single quotes of their own
# (echo '{}' > ..., sed -i '' ..., a jq '...' filter), so delivery goes through
# `invoke_hook` (helpers/run-hook.sh) rather than any local variant.
run_hook_edit() {
  local tool="$1" path="$2"
  local json
  json=$(jq -n --arg tool_name "$tool" --arg file_path "$path" '{tool_name: $tool_name, tool_input: {file_path: $file_path}}')
  invoke_hook "$json" "$HOOK_ABSOLUTE_PATH"
}

run_hook_bash() {
  local command_line="$1"
  local json
  json=$(jq -n --arg command "$command_line" '{tool_name: "Bash", tool_input: {command: $command}}')
  invoke_hook "$json" "$HOOK_ABSOLUTE_PATH"
}

# --- denied: edit tools, no exemption ---

# bats test_tags=protected
@test "Edit on .gaia/manifest.json is denied" {
  run_hook_edit "Edit" ".gaia/manifest.json"
  assert_denied_by_json
}

@test "an edit tool on the manifest is denied" {
  local row tool path
  local rows=(
    'Write|.gaia/manifest.json'
    'MultiEdit|.gaia/manifest.json'
    'Edit|/Users/you/projects/my-app/.gaia/manifest.json'
  )
  for row in "${rows[@]}"; do
    echo "case: $row"
    IFS='|' read -r tool path <<<"$row"
    run_hook_edit "$tool" "$path"
    assert_denied_by_json
  done
}

# Every gate explains itself: the denial names what a hand edit breaks, not
# only the rule it breaks.
@test "the manifest denial states its consequence" {
  run_hook_edit "Edit" ".gaia/manifest.json"
  assert_denied_by_json
  grep -qF -- "/gaia-fitness reads it to tell GAIA's files from yours, so an added entry can mark your own file GAIA-shipped and put it beyond the heal, and /update-gaia replaces the file wholesale from the release, discarding the edit." <<<"$output"
}

# --- allowed: edit tools ---

@test "a lookalike path is allowed by the edit tools" {
  local row tool path
  local rows=(
    'Edit|.gaia/manifest.json.tmp'
    'Edit|.gaia/manifest.json.bak'
    'Write|public/site.webmanifest'
    'Edit|.notebook/plans/x/README.md'
  )
  for row in "${rows[@]}"; do
    echo "case: $row"
    IFS='|' read -r tool path <<<"$row"
    run_hook_edit "$tool" "$path"
    assert_allowed_by_json
  done
}

# --- denied: Bash write vectors, no marker ---

# Rows carry single quotes of their own (echo '{}' > ..., sed -i '' ..., a jq
# filter); the `echo '{}'` row is the quote-safety canary: a denial there
# proves the harness's quote-safe delivery is wired, not just the guard logic.
@test "a Bash write vector to the manifest is denied" {
  local row
  local rows=(
    "jq '.files += {\"app/x.tsx\":\"owned\"}' .gaia/manifest.json > .gaia/manifest.json"
    "echo '{}' > .gaia/manifest.json"
    'cat frag >> .gaia/manifest.json'
    "sed -i '' 's/a/b/' .gaia/manifest.json"
    "sed -i 's/a/b/' .gaia/manifest.json"
    'cp /tmp/x.json .gaia/manifest.json'
    'mv /tmp/x.json .gaia/manifest.json'
    'tee .gaia/manifest.json'
    "jq '.files' .gaia/manifest.json | sponge .gaia/manifest.json"
    'echo x > ".gaia/manifest.json"'
    $'echo ok\nprintf x > .gaia/manifest.json'
    $'echo \'line one\nline two\' > .gaia/manifest.json'
    $'jq \'.a = 1\n| .b = 2\' x.json > /tmp/tmp.json && mv /tmp/tmp.json .gaia/manifest.json'
    $'jq \'.a = 1\n| .b = 2\' x.json > /tmp/tmp.json && mv /tmp/tmp.json .gaia/manifest.json && echo \'two words\''
    $'jq \'.a = 1\n| .b = 2\n\' x.json > /tmp/tmp.json && mv /tmp/tmp.json .gaia/manifest.json && echo \'two words\''
    $'jq ".a = 1\n| .b = 2\n" x.json > /tmp/tmp.json && mv /tmp/tmp.json .gaia/manifest.json && echo "two words"'
    $'echo \'tis the season\nmv /tmp/tmp.json .gaia/manifest.json'
    'cp /tmp/x.json .gaia/manifest.json >& /dev/null'
    '( mv /tmp/x.json .gaia/manifest.json )'
    'cp /tmp/x.json .gaia/manifest.json & wait'
    'cp /tmp/x.json .gaia/manifest.json # restore'
    'echo x >"/Users/you/my app/.gaia/manifest.json"'
    'echo x > .gaia/manifest.json; echo done'
    'cp /tmp/x.json .gaia/manifest.json&& echo done'
    $'sed -i \'s/a/b/\n s/c/d/\' .gaia/manifest.json'
    $'cp \'/tmp/a\n b.json\' .gaia/manifest.json'
    '(echo x > .gaia/manifest.json)'
    $'cp /tmp/x.json \\\n  .gaia/manifest.json'
    $'echo prep\n\nprintf x > .gaia/manifest.json'
    'echo x >.gaia/manifest.json'
    'echo x >>.gaia/manifest.json'
    'echo x >"$(pwd)/.gaia/manifest.json"'
  )
  for row in "${rows[@]}"; do
    echo "case: $row"
    run_hook_bash "$row"
    assert_denied_by_json
  done
}

# --- allowed: Bash with the GAIA_MANIFEST_WRITE= exemption marker ---

@test "a marked release writer is allowed" {
  local row
  local rows=(
    'GAIA_MANIFEST_WRITE=release cp "$LATEST_DIR/.gaia/manifest.json" .gaia/manifest.json'
    $'echo prep\nGAIA_MANIFEST_WRITE=release cp x .gaia/manifest.json'
    "GAIA_MANIFEST_WRITE=remove-i18n jq 'del(.files[\"app/i18n.ts\"])' .gaia/manifest.json > .gaia/manifest.json.tmp"
    'GAIA_MANIFEST_WRITE=remove-i18n mv .gaia/manifest.json.tmp .gaia/manifest.json'
    'FOO=1 GAIA_MANIFEST_WRITE=release cp x .gaia/manifest.json'
  )
  for row in "${rows[@]}"; do
    echo "case: $row"
    run_hook_bash "$row"
    assert_allowed_by_json
  done
}

# --- allowed: Bash with no write vector (legitimate reads / release CLI) ---

@test "reads and look-alike Bash writes are allowed" {
  local row
  local rows=(
    'echo x >.gaia/manifest.json.bak'
    '.gaia/cli/gaia-maintainer release manifest'
    'cat .gaia/manifest.json'
    "jq '.files' .gaia/manifest.json"
    'grep owned .gaia/manifest.json'
    'git add .gaia/manifest.json'
    'cp .gaia/manifest.json /tmp/backup.json'
    'echo x > .gaia/manifest.json.bak'
  )
  for row in "${rows[@]}"; do
    echo "case: $row"
    run_hook_bash "$row"
    assert_allowed_by_json
  done
}

# --- structural ---

@test "block-manifest-write.sh is executable" {
  [ -x "$HOOK_ABSOLUTE_PATH" ]
}

@test "settings.json registers the hook on both matchers" {
  hook_registered "$SETTINGS_ABSOLUTE_PATH" '.hooks.PreToolUse[] | select(.matcher == "Edit|Write|MultiEdit")' block-manifest-write.sh
  hook_registered "$SETTINGS_ABSOLUTE_PATH" '.hooks.PreToolUse[] | select(.matcher == "Bash|Monitor")' block-manifest-write.sh
}

# --- the shared payload reader ---

@test "a missing lib/hook-payload.sh refuses a manifest edit rather than allowing the call" {
  local scratch_directory="$BATS_TEST_TMPDIR/no-payload-lib" json
  mkdir -p "$scratch_directory"
  cp -R "$HOOKS_SOURCE_DIRECTORY/lib" "$scratch_directory/lib"
  rm -f "$scratch_directory/lib/hook-payload.sh"
  cp "$HOOK_ABSOLUTE_PATH" "$scratch_directory/"
  json=$(jq -n --arg file_path ".gaia/manifest.json" '{tool_name: "Edit", tool_input: {file_path: $file_path}}')
  invoke_hook "$json" "$scratch_directory/block-manifest-write.sh"
  [ "$status" -eq 2 ]
  grep -qF -- 'cannot load lib/hook-payload.sh' <<<"$output"
}

@test "an ordinary Bash call runs at most one jq" {
  local shim_directory="$BATS_TEST_TMPDIR/shim" real_jq json
  real_jq=$(command -v jq)
  mkdir -p "$shim_directory"
  printf '#!/usr/bin/env bash\nprintf "jq\\n" >> "%s/calls.log"\nexec "%s" "$@"\n' "$BATS_TEST_TMPDIR" "$real_jq" >"$shim_directory/jq"
  chmod +x "$shim_directory/jq"
  json=$(jq -n '{tool_name: "Bash", tool_input: {command: "ls -la"}}')
  PATH="$shim_directory:$PATH" invoke_hook "$json" "$HOOK_ABSOLUTE_PATH"
  assert_allowed_by_json
  [ "$(wc -l <"$BATS_TEST_TMPDIR/calls.log")" -le 1 ]
}
