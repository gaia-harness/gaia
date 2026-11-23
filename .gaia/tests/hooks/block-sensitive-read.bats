#!/usr/bin/env bats

# Tests for .claude/hooks/block-sensitive-read.sh.
#
# One read-side guard for two path classes. The dotenv class covers the Read
# tool and the Bash readers (including the grep family) against .env and every
# variant (.env.local, .env.*, not .env.example), sourcing, redirection, and
# bare environment dumps (env/printenv). The secret-path class covers the paths
# four Read() deny globs used to hold: *.key, *.pem, any name containing
# "credential" except a TypeScript file, and anything under a
# secrets/ directory. When an input matches
# both classes the dotenv reason is the one emitted.
#
# The guard is heuristic defense-in-depth, not a sandbox: it always exits 0,
# carrying the allow/deny decision in stdout JSON.
#
# The settings.json assertions pin the absence of every Read() deny rule. That
# absence is load-bearing rather than incidental: a single Read() rule re-arms
# Claude Code's bypass-immune deniedPathInsideDirectory circuit breaker, which
# forces a manual approval prompt on every recursive search or copy in the tree.

setup() {
  . "$BATS_TEST_DIRNAME/helpers/run-hook.sh"
  HOOKS_SOURCE_DIRECTORY=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)
  HOOK_ABSOLUTE_PATH="$HOOKS_SOURCE_DIRECTORY/block-sensitive-read.sh"
  SETTINGS_ABSOLUTE_PATH="${HOOKS_SOURCE_DIRECTORY%/hooks}/settings.json"
}

# Several payloads below carry Bash commands with single quotes of their own
# (grep '.env' .gitignore), so delivery goes through `invoke_hook`
# (helpers/run-hook.sh) rather than any local variant.
run_hook_read() {
  local path="$1"
  local json
  json=$(jq -n --arg file_path "$path" '{tool_name: "Read", tool_input: {file_path: $file_path}}')
  invoke_hook "$json" "$HOOK_ABSOLUTE_PATH"
}

run_hook_bash() {
  local command_line="$1"
  local json
  json=$(jq -n --arg command "$command_line" '{tool_name: "Bash", tool_input: {command: $command}}')
  invoke_hook "$json" "$HOOK_ABSOLUTE_PATH"
}

run_hook_grep() {
  local path="$1" glob="$2"
  local json
  json=$(jq -n --arg search_path "$path" --arg glob "$glob" '{
    tool_name: "Grep",
    tool_input: ({pattern: "x"}
      + (if $search_path == "" then {} else {path: $search_path} end)
      + (if $glob == "" then {} else {glob: $glob} end))
  }')
  invoke_hook "$json" "$HOOK_ABSOLUTE_PATH"
}

# Run the hook with lib/reader-operands.sh absent, to exercise the grammar-load
# failure arm.
#
# The hook is COPIED into this test's own temporary directory and driven from
# there, with no library beside it. It must never be exercised by hiding the
# real one: every other suite and the live session's own Read, Grep and Bash calls
# run through the real hook at the identical absolute path, and would see the
# fail-closed deny for the width of the window the library was hidden.
#
# The hook resolves its library as `dirname "${BASH_SOURCE[0]}"/lib`, so a copy
# in a directory with an empty lib/ beside it reaches for a file that is not
# there, which is the missing-library arm exactly. The directory is created and
# left empty rather than omitted so the arm under test is the absent FILE rather
# than an unresolvable lib dir; both deny, and pinning the narrower one is what
# makes this a test of the probe instead of a test of `cd`.
run_hook_without_library() {
  local json directory command_line="${1:-cat README.md}"
  directory="$BATS_TEST_TMPDIR/nolib"
  mkdir -p "$directory/lib"
  cp "$HOOK_ABSOLUTE_PATH" "$directory/"
  json=$(jq -n --arg command "$command_line" '{tool_name: "Bash", tool_input: {command: $command}}')
  invoke_hook "$json" "$directory/$(basename "$HOOK_ABSOLUTE_PATH")"
}


# The Bash|Monitor matcher delivers Monitor payloads too, and a Monitor
# command reads files exactly as a Bash command does.
run_hook_monitor() {
  local command_line="$1"
  local json
  json=$(jq -n --arg command "$command_line" '{tool_name: "Monitor", tool_input: {command: $command}}')
  invoke_hook "$json" "$HOOK_ABSOLUTE_PATH"
}

# run_verdict_row <tool>|<allow|deny>|<input>: drive one case-table row and
# check its verdict, reporting the row on failure. <tool> is Read, Bash,
# Monitor, GrepPath or GrepGlob. The input is everything after the second `|`,
# so a command may carry pipes of its own.
run_verdict_row() {
  local row="$1" tool verdict input
  tool=${row%%|*}; row=${row#*|}; verdict=${row%%|*}; input=${row#*|}
  case "$tool" in
    Read) run_hook_read "$input" ;;
    Bash) run_hook_bash "$input" ;;
    Monitor) run_hook_monitor "$input" ;;
    GrepPath) run_hook_grep "$input" "" ;;
    GrepGlob) run_hook_grep "" "$input" ;;
    *) echo "unknown row tool: $tool"; return 1 ;;
  esac
  [ "$status" -eq 0 ] || { echo "case $tool $input: status=$status output=$output"; return 1; }
  if grep -qF -- '"permissionDecision": "deny"' <<<"$output"; then
    [ "$verdict" = deny ] || { echo "case $tool $input: denied, expected allow"; return 1; }
  else
    [ "$verdict" = allow ] || { echo "case $tool $input: allowed, expected deny"; return 1; }
  fi
}

# run_settings_row <label> <jq expression>: the expression holds over settings.json.
run_settings_row() {
  run jq -e "$2" "$SETTINGS_ABSOLUTE_PATH"
  [ "$status" -eq 0 ] || { echo "case $1: settings.json fails: $2"; return 1; }
}

# --- Read-tool denies ---

# bats test_tags=protected
@test "Read a nested packages/api/.env.production is denied" {
  run_hook_read "packages/api/.env.production"
  assert_denied_by_json
}

# --- Bash denies: readers, residual read paths and shell forms ---
#
# The segment walk splits on each of `|`, `&`, `;`, `(` and `)`, so it covers
# &&, ; and || and reaches into `$(...)`. `.env*`, `.env.*` and `.env?` each expand
# to dotenv files in the directory, so they read the same bytes the literal path
# does; the predicate once matched only the literal spellings with a regex no
# metacharacter satisfies, so the globs were allowed while `cat .env` was denied.
# The single-quoted rows are deliberate: the payload must reach the hook
# verbatim so it classifies the literal command text.
@test "a dotenv read through a reader command or a shell form is denied" {
  local row
  # shellcheck disable=SC2016
  for row in \
    "Bash|deny|cat .env.local" \
    "Bash|deny|cat packages/api/.env.production" \
    "Bash|deny|source .env" \
    "Bash|deny|. ./.env" \
    'Bash|deny|x=$(<.env)' \
    "Bash|deny|xxd .env" \
    "Bash|deny|true && cat .env.local" \
    "Bash|deny|cd /tmp; cat .env.local" \
    "Bash|deny|false || cat .env.local" \
    'Bash|deny|x=$(cat .env)' \
    'Bash|deny|cat .env*' \
    'Bash|deny|cat .env.*' \
    'Bash|deny|cat .env?'; do
    run_verdict_row "$row" || return 1
  done
}

# --- Bash denies: bare environment dumps ---

@test "printenv NODE_ENV is denied (printenv has no runner form)" {
  run_hook_bash "printenv NODE_ENV"
  assert_denied_by_json
}

# --- Bash: heredoc bodies and the dump reason ---
#
# Built with printf so each payload carries real newlines and tabs. A cat or
# tee heredoc with a quoted delimiter and no pipe only writes data; anything a
# shell runs, or whose body cannot be proven closed, keeps its body judged.
@test "a data heredoc is allowed and a runnable or unproven body is denied" {
  local row verdict payload
  for row in \
    "allow|cat > notes.md <<'EOF'\n(env) plus the transcript\nEOF" \
    "allow|tee notes.md <<-\"END\"\n\tprintenv\n\tEND" \
    "allow|git commit -m \"\$(cat <<'EOF'\nenv\nEOF\n)\"" \
    "deny|cat > notes.md <<'EOF'\nx\nEOF\nprintenv" \
    "deny|bash <<'EOF'\ncat .env\nEOF" \
    "deny|cat <<'EOF' | sh\nprintenv\nEOF" \
    "deny|cat > notes.md <<EOF\nenv\nEOF" \
    "deny|cat > notes.md <<'EOF'\nprintenv" \
    "deny|cat <<<'EOF'\nprintenv\nEOF"; do
    verdict=${row%%|*}
    payload=$(printf "${row#*|}")
    run_hook_bash "$payload"
    if [ "$verdict" = allow ]; then
      assert_allowed_by_json || { echo "not allowed: ${row#*|}"; return 1; }
    else
      assert_denied_by_json || { echo "not denied: ${row#*|}"; return 1; }
    fi
  done
}

@test "a regex alternation naming the dump words is denied with a reason naming the split and the -e spelling" {
  run_hook_bash "grep -n -E '(env|printenv)' notes.md"
  assert_denied_by_json
  grep -qF -- "without regard for quotes" <<<"$output"
  grep -qF -- "own -e operand" <<<"$output"
}

# --- allows: env as a runner, false-positive guards, non-reading uses ---
#
# `grep '.env' .gitignore` names .env as a pattern, not a file read; `ls` reads
# no content; `.environment` is not a dotenv variant.
@test "benign commands and non-reading uses of dotenv names are allowed" {
  local row
  for row in \
    "Read|allow|.env.example" \
    "Bash|allow|env NODE_ENV=production node app.js" \
    "Bash|allow|pnpm dev" \
    "Bash|allow|pnpm i && pnpm dev" \
    "Bash|allow|cat app/services/env.ts" \
    "Bash|allow|cat README.md" \
    "Bash|allow|cp .env.example .env" \
    "Bash|allow|grep '.env' .gitignore" \
    "Bash|allow|ls -la .env" \
    "Bash|allow|cat .env.example" \
    "Bash|allow|cat .environment"; do
    run_verdict_row "$row" || return 1
  done
}

# --- Bash: the grep family, which needs argument grammar (dotenv) ---
#
# -f names a file of patterns and -e supplies the pattern, which grep opens or
# reads itself; this walk does not treat that value as a candidate, and the
# positional target after it still is. --ignore-file names a file of globs and
# supplies no pattern, so the positional after it is still the pattern. A filter
# flag whose value SELECTS the files a recursive search reads (--include, -g,
# --glob) is judged on that value; ugrep negates each comma-list element alone,
# so every element is judged; --exclude names files not read. A select flag
# still consumes its value, so in `rg -g '*.ts' .env app` the .env is the
# pattern. The `!.env*` row is not a guard on the negation skip: the dotenv
# predicate never matches a basename starting with `!`, so it stays green with
# the skip removed; the skip is guarded by the derived negated-glob test below.
@test "grep and rg are judged on the target file and select-filter value, not the pattern or exclude operand (dotenv)" {
  local row
  for row in \
    "Bash|deny|grep SECRET .env" \
    "Bash|deny|grep -rn SECRET .env.local" \
    "Bash|deny|rg SECRET .env.production" \
    "Bash|deny|grep -f pats.txt .env.local" \
    "Bash|allow|grep -e .env .gitignore" \
    "Bash|allow|grep --include=*.ts SECRET app" \
    "Bash|deny|grep -r SECRET --include='.env' ." \
    "Bash|deny|rg -g '.env*' SECRET" \
    "Bash|deny|rg --glob=.env.local SECRET" \
    "Bash|allow|rg -g '!.env*' SECRET" \
    "Bash|deny|grep -r -g '!*.md,.env*' SECRET ." \
    "Bash|deny|grep -r -g '*.md,.env.local' SECRET ." \
    "Bash|allow|grep -r SECRET --exclude=.env ." \
    "Bash|allow|rg -g '*.ts' .env app" \
    "Bash|allow|grep SECRET .env.example" \
    "Bash|allow|rg --ignore-file .rgignore SECRET app"; do
    run_verdict_row "$row" || return 1
  done
}

@test "Monitor applies the same read deny" {
  local row
  for row in \
    "Monitor|deny|cat .env.local" \
    "Monitor|deny|tail -f secrets/api.key" \
    "Monitor|allow|tail -f app.log"; do
    run_verdict_row "$row" || return 1
  done
}

# Not merely "no Read(.env)": ANY Read() deny rule arms the bypass-immune
# deniedPathInsideDirectory breaker, so the guarantee this hook is paid to
# provide is the empty set, and a well-meaning re-addition of any one of them
# silently reinstates the prompt storm this suite exists to keep away.
# Edit(.env) blocks every file-writing tool (Write, Edit, MultiEdit,
# NotebookEdit), so a separate Write(.env) deny is redundant and is
# intentionally absent. Only the READ half moved to the hook layer; an Edit()
# rule arms no read breaker and therefore costs nothing to keep.
@test "permissions.deny keeps only the write-side backstop" {
  run_settings_row no-read-rule '[.permissions.deny[] | select(startswith("Read("))] | length == 0' || return 1
  run_settings_row edit-env-backstop '.permissions.deny | index("Edit(.env)")' || return 1
  run_settings_row no-example-or-glob-deny '[.permissions.deny[] | select(contains(".env.example") or contains(".env.*"))] | length == 0' || return 1
}

# --- grep flag arity: a discard-listed flag that is value-less for the invoked tool ---
#
# Each deny row was ALLOWED before the flag tables dropped -r, -T and the bare
# --color/--colour spelling. The flag ate the pattern, the path was then taken
# as the pattern, and the walk emitted no operand at all, so the guard passed a
# dotenv or secret read through in silence. `-rn` and `-R` denied throughout,
# which is what kept the class invisible: `grep -r PATTERN PATH` is the most
# idiomatic recursive spelling there is. rg's -r over-reads the pattern and
# fails closed; an `=` form supplies its own value.
@test "grep flag arity: value-less, optional-value and equals forms (dotenv and secret)" {
  local row
  for row in \
    "Bash|deny|grep -r SECRET .env" \
    "Bash|deny|grep -ir PASSWORD .env.production" \
    "Bash|deny|grep -T SECRET .env" \
    "Bash|deny|grep --color SECRET .env" \
    "Bash|deny|grep --colour SECRET .env" \
    "Bash|deny|rg -r X .env.local" \
    "Bash|allow|grep --color=auto .env .gitignore" \
    "Bash|deny|grep -r TOKEN certs/server.key" \
    "Bash|deny|grep -T TOKEN certs/server.pem" \
    "Bash|deny|grep --color TOKEN certs/server.key" \
    "Bash|deny|rg -r X secrets/prod.json" \
    "Bash|allow|grep --color=auto server.key .gitignore"; do
    run_verdict_row "$row" || return 1
  done
}

# --- Grep tool: content mode returns file contents, so it reads a path ---

@test "the Grep tool is denied on dotenv and secret paths and globs" {
  local row
  for row in \
    "GrepPath|deny|.env.production" \
    "GrepGlob|deny|.env" \
    "GrepPath|allow|.env.example" \
    "GrepPath|allow|app/routes" \
    "GrepPath|deny|certs/server.key" \
    "GrepPath|deny|secrets/prod.json" \
    "GrepGlob|deny|*.key" \
    "GrepPath|allow|app/lib/keychain.ts"; do
    run_verdict_row "$row" || return 1
  done
}

# --- Fail-closed on a library-load failure ---
#
# The reader-operands arm used to be `exit 1`. Only exit 2 or a structured deny
# blocks a PreToolUse call, so a missing library allowed every dotenv and secret
# read with a stderr line as the only trace. Asserting the deny payload rather
# than the exit status is the point: the exit status was 1 then and is 0 now,
# and neither value distinguishes a guard that is running from one that is not.
# The hook-payload row runs a scratch copy of the hooks directory with
# lib/hook-payload.sh removed, so the real library is never hidden from the live
# session's own calls; it refuses with exit 2.
@test "a missing reader-operands or hook-payload library denies rather than allows" {
  local label command_line scratch_directory json
  local reader_operands_message='BLOCKED: block-sensitive-read.sh could not load lib/reader-operands.sh, so the read-side dotenv and secret-path guard is not running. This denial is fail-closed by design. Restore .claude/hooks/lib/reader-operands.sh to clear it.'
  for label in reader-operands-dotenv reader-operands-secret-path; do
    case "$label" in
      reader-operands-dotenv) command_line='cat .env.local' ;;
      reader-operands-secret-path) command_line='cat certs/server.key' ;;
    esac
    run_hook_without_library "$command_line"
    [ "$status" -eq 0 ] || { echo "case $label: status=$status"; return 1; }
    grep -qF -- '"permissionDecision": "deny"' <<<"$output" || { echo "case $label: not denied"; return 1; }
    grep -qF -- "$reader_operands_message" <<<"$output" || { echo "case $label: no fail-closed reason"; return 1; }
  done

  scratch_directory="$BATS_TEST_TMPDIR/no-payload-lib"
  mkdir -p "$scratch_directory"
  cp -R "$HOOKS_SOURCE_DIRECTORY/lib" "$scratch_directory/lib"
  rm -f "$scratch_directory/lib/hook-payload.sh"
  cp "$HOOK_ABSOLUTE_PATH" "$scratch_directory/"
  json=$(jq -n --arg file_path ".env" '{tool_name: "Read", tool_input: {file_path: $file_path}}')
  invoke_hook "$json" "$scratch_directory/block-sensitive-read.sh"
  [ "$status" -eq 2 ] || { echo "case hook-payload-dotenv: status=$status, expected 2"; return 1; }
  grep -qF -- 'cannot load lib/hook-payload.sh' <<<"$output" || { echo "case hook-payload-dotenv: no load reason"; return 1; }
}

# --- The sandbox tier the removed Read() rules used to carry ---
#
# Read(.env) merged into the OS sandbox boundary, where it reached a subprocess
# spawned by sandboxed Bash. A hook never sees a subprocess open(), so deleting
# the rule without this declaration would have dropped that tier in silence.
# A sandbox filesystem path with no prefix resolves against the project root, so
# the bare dotenv pair reaches the root dotenv and nothing deeper; this hook
# decides on the basename and denies a dotenv at any depth, so without the
# depth-qualified pair the tool tier and the subprocess tier disagree about the
# same file in a monorepo. The hook lets a TypeScript file whose name mentions
# credentials through, so the sandbox re-opens the same spellings, or a
# sandboxed Playwright or Vitest run cannot open a login UAT spec the Read tool
# can. The docs never rank one glob against another, so each allow carries a
# narrower secrets/ re-deny that keeps such a file under a secrets directory
# denied. Markdown stays denied at both tiers.
@test "the settings.json sandbox denyRead block covers dotenv and secret classes" {
  run_settings_row dotenv-at-root '
    .sandbox.filesystem.denyRead as $d
    | ($d | index(".env")) != null and ($d | index(".env.*")) != null
  ' || return 1
  run_settings_row dotenv-at-any-depth '
    .sandbox.filesystem.denyRead as $d
    | ($d | index("**/.env")) != null and ($d | index("**/.env.*")) != null
  ' || return 1
  run_settings_row env-example-readable '
    .sandbox.filesystem.allowRead as $a
    | ($a | index(".env.example")) != null
      and ($a | index("**/.env.example")) != null
  ' || return 1
  run_settings_row secret-classes '
    .sandbox.filesystem.denyRead as $d
    | ["**/*.key", "**/*.pem", "**/*credential*", "**/secrets/**"]
    | all(. as $needle | $d | index($needle) != null)
  ' || return 1
  run_settings_row credential-typescript-reopened-only '
    .sandbox.filesystem as $f
    | ["ts", "tsx", "mts", "cts"]
    | all(. as $ext
          | ($f.allowRead | index("**/*credential*." + $ext)) != null
            and ($f.denyRead | index("**/secrets/**/*credential*." + $ext)) != null)
      and ($f.allowRead | map(select(test("credential"))) | length) == 4
  ' || return 1
}

# --- Read-tool denies, one per path class the removed Read() globs covered ---

# bats test_tags=protected
@test "Read certs/server.key is denied" {
  run_hook_read "certs/server.key"
  assert_denied_by_json
}

# The replaced secrets/ glob matched only a file DIRECTLY inside secrets/;
# covering the whole subtree is a deliberate widening, as is the
# case-insensitive credential match. Every credential-store spelling stays
# denied through the Read tool and a Bash reader once TypeScript names are
# carved out of the match, a TypeScript file under a secrets/ directory stays
# denied, and the near-misses a substring match would get wrong stay readable.
@test "credential-store paths are denied through Read and cat, TypeScript mentions stay readable" {
  local rows=() row credential_path source_path
  rows+=(
    "Read|deny|config/aws-credentials.json"
    "Read|deny|secrets/prod.json"
    "Read|deny|deploy/secrets/live/token.txt"
    "Read|deny|config/AWS_Credentials.json"
  )
  for credential_path in credentials credentials.json .aws/credentials \
    config/aws-credentials.json db.credentials CREDENTIALS credential.yml \
    gcloud/application_default_credentials.json google-credentials.txt \
    credentials.ini credentials.js docs/credentials.md docs/Credentials.MDX; do
    rows+=("Read|deny|$credential_path" "Bash|deny|cat $credential_path")
  done
  rows+=("Read|allow|apps/web/.playwright/e2e/auth/login-rejects-invalid-credentials.spec.ts")
  for source_path in app/auth/credentials.test.ts app/auth/credential-form.tsx \
    app/auth/credentials.ts app/auth/credentials.mts; do
    rows+=("Read|allow|$source_path" "Bash|allow|cat $source_path")
  done
  rows+=(
    "Read|deny|deploy/secrets/credentials.ts"
    "Read|allow|app/components/button/index.tsx"
    "Read|allow|app/lib/keychain.ts"
    "Read|allow|mysecrets/notes.md"
    "Read|allow|secrets-old/notes.md"
  )
  for row in "${rows[@]}"; do
    run_verdict_row "$row" || return 1
  done
}

# --- Each path class keeps its own deny reason, dotenv ruling first ---
#
# Each row: <label>|<tool>|<input>|<needles, ^-separated>|<forbidden needle>.
# Both dotenv denies name what Claude can do without the value; the secret-path
# deny names the next step. When an input matches both classes, the dotenv
# reason is the one emitted.
@test "each denial carries the reason for its class" {
  local row label tool input needles forbidden needle
  for row in \
    "dotenv-next-step-read|Read|.env.local|Next step: refer to the variable by its name^read '.env.example' for the list of keys|" \
    "dotenv-next-step-cat|Bash|cat .env.local|Next step: refer to the variable by its name^read '.env.example' for the list of keys|" \
    "secret-next-step-read|Read|credentials.json|Next step:|" \
    "secret-next-step-cat|Bash|cat credentials.json|Next step:|" \
    "bare-env-dump|Bash|env|reads as an environment dump|key, certificate, or credential" \
    "dotenv-tool-reason|Read|.env.local|reading '.env' / '.env.*' files is denied to protect local secrets. Only '.env.example' is readable.|" \
    "secret-tool-reason|Read|id_rsa.pem|reading key, certificate, and credential files is denied to protect local secrets.|" \
    "dotenv-reader-reason|Bash|cat .env|reading a .env / .env.* file (a reader, sourcing, or redirection) is denied|" \
    "secret-reader-reason|Bash|cat certs/server.key|a command here reads a key, certificate, or credential path|" \
    "printenv-dump-reason|Bash|printenv|begins with env or printenv and names no command to run|" \
    "grep-secrets-directory|GrepPath|secrets/|reading key, certificate, and credential files is denied|" \
    "dotenv-wins-read|Read|secrets/.env|reading '.env' / '.env.*' files is denied|reading key, certificate, and credential files" \
    "dotenv-wins-command|Bash|cat certs/server.key; cat .env.local|reading a .env / .env.* file|reads a key, certificate, or credential path"; do
    label=${row%%|*}; row=${row#*|}; tool=${row%%|*}; row=${row#*|}
    input=${row%%|*}; row=${row#*|}; needles=${row%%|*}; forbidden=${row#*|}
    run_verdict_row "$tool|deny|$input" || { echo "case $label: not denied"; return 1; }
    while [ -n "$needles" ]; do
      needle=${needles%%^*}
      grep -qF -- "$needle" <<<"$output" || { echo "case $label: missing reason: $needle"; return 1; }
      [ "$needle" = "$needles" ] && needles='' || needles=${needles#*^}
    done
    if [ -n "$forbidden" ] && grep -qF -- "$forbidden" <<<"$output"; then
      echo "case $label: carries the other class's reason: $forbidden"; return 1
    fi
  done
}

# --- Bash: the grep family over a secret path ---
#
# --file (long form of -f) supplies the pattern the same way -e/--regexp does,
# so the positional after it is still an ordinary target file; --exclude-from
# and --ignore-file name a file of globs and supply no pattern, so one still
# has to follow. None of the three flags' own values reach the predicate. The
# Grep tool arm already denies a `glob` naming a secret class; the filter rows
# pin the Bash spellings of the same filter to the same verdict. ugrep negates
# each comma-list element alone and reads a leading ^ as an exclusion. If -g
# stopped consuming its value in `rg -g '*.ts' server.key app`, '*.ts' would be
# taken as the pattern and server.key emitted as a file operand.
@test "grep and rg over a secret-path target or class filter" {
  local row
  for row in \
    "Bash|deny|grep TOKEN certs/server.pem" \
    "Bash|deny|rg TOKEN secrets/prod.json" \
    "Bash|deny|grep -f pats.txt certs/server.key" \
    "Bash|deny|grep --file pats.txt certs/server.key" \
    "Bash|deny|grep --exclude-from globs.txt TOKEN certs/server.key" \
    "Bash|deny|rg -g '*.key' TOKEN" \
    "Bash|deny|rg --glob '*.key' TOKEN" \
    "Bash|deny|rg --iglob '*.key' TOKEN" \
    "Bash|deny|grep -r TOKEN --include='*.key' ." \
    "Bash|deny|grep -r TOKEN --include='*.pem' ." \
    "Bash|allow|rg -g '!*.key' TOKEN" \
    "Bash|deny|grep -r -g '!*.md,*.key' TOKEN ." \
    "Bash|deny|grep -r --glob='*.md,*.key' TOKEN ." \
    "Bash|allow|grep -r -g '!*.key,!*.pem' TOKEN ." \
    "Bash|allow|grep -r -g '^*.key' TOKEN ." \
    "Bash|allow|grep -r TOKEN --exclude=*.key ." \
    "Bash|allow|grep -r TOKEN --exclude-dir=secrets ." \
    "Bash|allow|rg -g '*.ts' server.key app"; do
    run_verdict_row "$row" || return 1
  done
}

@test "every select flag reader-operands.sh carries denies a secret passed as its value" {
  local library_path="$HOOKS_SOURCE_DIRECTORY/lib/reader-operands.sh"
  # shellcheck source=.claude/hooks/lib/reader-operands.sh disable=SC1091
  . "$library_path"

  # Which tables exist is the library's to say, so read it rather than restate
  # it. Each table needs its own grammar arm below, so one added there and not
  # here would leave this test driving a subset under a name claiming the whole
  # set; comparing the two reds instead, and names the arm to write.
  #
  local declared mentioned missed found known
  declared=$(grep -oE '^_GAIA_RO_[A-Z0-9_]+=' "$library_path" | sed 's/=$//' | sort -u)

  # That anchor reads a bare column-0 assignment, which is how this library
  # declares every table today. Rather than widen it once per declaration
  # keyword someone might later reach for, sweep every _GAIA_RO_ name the file
  # mentions at all and require the anchor to have reached each one. A table
  # declared in a shape the anchor cannot read then reds here, rather than
  # sitting outside the comparison below with nothing left to notice it.
  mentioned=$(grep -ohE '_GAIA_RO_[A-Z0-9_]+' "$library_path" | sort -u)
  missed=$(comm -23 <(printf '%s\n' "$mentioned") <(printf '%s\n' "$declared"))
  if [ -n "$missed" ]; then
    echo "lib/reader-operands.sh names tables this test's discovery cannot read:" >&2
    echo "  $(echo "$missed" | tr '\n' ' ')" >&2
    return 1
  fi

  # Subtract the tables that carry no flag whose value reaches the predicate,
  # rather than selecting the ones that do by name. Selecting would rest the
  # comparison on a naming convention this test cannot enforce; subtracting puts
  # the burden the other way, so a new table is a mismatch until someone either
  # gives it a grammar arm below or writes it into this list. Deliberately not
  # judged tables: PLAIN_READERS and GREP_READERS hold command words rather than
  # flags, and SHORT_DISCARD and LONG_DISCARD hold the flags whose value the
  # walk throws away (including the file-of-patterns/globs flags: their value is
  # opened by grep itself, but this walk does not treat it as a candidate). The
  # SELECT tables name a glob choosing which files a recursive search opens.
  found=$(printf '%s\n' "$declared" \
    | grep -vxE '_GAIA_RO_(PLAIN_READERS|GREP_READERS|SHORT_DISCARD|LONG_DISCARD)') || true
  known=$(printf '%s\n' _GAIA_RO_LONG_SELECT _GAIA_RO_SHORT_SELECT | sort)
  if [ "$found" != "$known" ]; then
    echo "the judged-flag tables in lib/reader-operands.sh are not the ones this test builds commands for" >&2
    echo "  lib:  $(echo "$found" | tr '\n' ' ')" >&2
    echo "  test: $(echo "$known" | tr '\n' ' ')" >&2
    return 1
  fi

  # An empty table contributes no command and leaves this test asserting
  # nothing, which reads exactly like a pass. A table emptied in place passes
  # the comparison above, since the name is still there, so name whichever one
  # went hollow rather than iterating a set that quietly shrank.
  local name
  for name in $known; do
    if [ -z "${!name}" ]; then
      echo "$name is empty in lib/reader-operands.sh" >&2
      return 1
    fi
  done

  # Two spellings per flag, because the walk reaches the value down two
  # different paths: a separate token arrives through the pending branch, an
  # attached or `=` value through the emit beside it. Driving one leaves the
  # other free to be deleted with nothing red.
  #
  # The tables are the union of GNU grep's flags and ripgrep's, so no single
  # command word spells every member and the mismatches below are deliberate.
  # What is under test is the flag's grammar, which the guard reads the same way
  # for every word in its grep family, so one word per grammar is enough.
  local command_lines=() long_flag flag_letter i=0
  while [ "$i" -lt "${#_GAIA_RO_SHORT_SELECT}" ]; do
    flag_letter="${_GAIA_RO_SHORT_SELECT:$i:1}"
    command_lines+=("rg -$flag_letter '*.key' TOKEN")
    command_lines+=("rg -$flag_letter*.key TOKEN")
    i=$((i + 1))
  done
  for long_flag in $_GAIA_RO_LONG_SELECT; do
    command_lines+=("rg $long_flag '*.key' TOKEN")
    command_lines+=("rg $long_flag='*.key' TOKEN")
  done

  local command_line allowed=0
  for command_line in "${command_lines[@]}"; do
    run_hook_bash "$command_line"
    if [ "$status" -ne 0 ] || ! grep -qF -- '"permissionDecision": "deny"' <<<"$output"; then
      echo "not denied: $command_line" >&2
      allowed=1
    fi
  done
  [ "$allowed" -eq 0 ]
}

@test "every select flag reader-operands.sh carries allows a negated glob naming the secret class" {
  local library_path="$HOOKS_SOURCE_DIRECTORY/lib/reader-operands.sh"
  # shellcheck source=.claude/hooks/lib/reader-operands.sh disable=SC1091
  . "$library_path"

  # The test above holds the select tables to the library's declarations, so
  # this one only refuses a table emptied in place before deriving from it.
  if [ -z "$_GAIA_RO_SHORT_SELECT" ] || [ -z "$_GAIA_RO_LONG_SELECT" ]; then
    echo "a select table is empty in lib/reader-operands.sh" >&2
    return 1
  fi

  local command_lines=() long_flag flag_letter i=0
  while [ "$i" -lt "${#_GAIA_RO_SHORT_SELECT}" ]; do
    flag_letter="${_GAIA_RO_SHORT_SELECT:$i:1}"
    command_lines+=("rg -$flag_letter '!*.key' TOKEN")
    command_lines+=("rg -$flag_letter!*.key TOKEN")
    i=$((i + 1))
  done
  for long_flag in $_GAIA_RO_LONG_SELECT; do
    command_lines+=("rg $long_flag '!*.key' TOKEN")
    command_lines+=("rg $long_flag='!*.key' TOKEN")
  done

  local command_line denied=0
  for command_line in "${command_lines[@]}"; do
    run_hook_bash "$command_line"
    if [ "$status" -ne 0 ] || grep -qF -- '"permissionDecision": "deny"' <<<"$output"; then
      echo "not allowed: $command_line" >&2
      denied=1
    fi
  done
  [ "$denied" -eq 0 ]
}

# The single-quoted rows reach the hook verbatim, so it classifies the literal
# command text. `grep server.key .gitignore` is the single most important allow
# in this file: without grep argument grammar the pattern operand reads as a
# path and it denies.
@test "a secret read through redirection, substitution or segments is denied" {
  local row
  # shellcheck disable=SC2016
  for row in \
    'Bash|deny|x=$(<certs/server.key)' \
    "Bash|deny|true && cat certs/server.key" \
    "Bash|allow|grep server.key .gitignore" \
    "Bash|allow|ls -la certs/server.key" \
    "Bash|allow|cat mysecrets/notes.md" \
    'Bash|deny|x=$(cat certs/server.key)'; do
    run_verdict_row "$row" || return 1
  done
}

# --- Structural ---

@test "no settings.json handler names a retired read guard" {
  run jq -e '[.. | strings | select(contains("block-env-read.sh") or contains("block-secrets-read.sh") or contains("block-env-write.sh"))] | length == 0' "$SETTINGS_ABSOLUTE_PATH"
  [ "$status" -eq 0 ]
}

@test "settings.json registers block-sensitive-read.sh exactly once under the Read matcher" {
  run jq -e '[.hooks.PreToolUse[] | select(.matcher == "Read") | .hooks[] | select(.command | contains("block-sensitive-read.sh"))] | length == 1' "$SETTINGS_ABSOLUTE_PATH"
  [ "$status" -eq 0 ]
}

@test "settings.json registers block-sensitive-read.sh exactly once on the Bash|Monitor matcher" {
  run jq -e '[.hooks.PreToolUse[] | select(.matcher == "Bash|Monitor") | .hooks[] | select(.command | contains("block-sensitive-read.sh"))] | length == 1' "$SETTINGS_ABSOLUTE_PATH"
  [ "$status" -eq 0 ]
}

@test "settings.json registers block-sensitive-read.sh exactly once under the Grep matcher" {
  run jq -e '[.hooks.PreToolUse[] | select(.matcher == "Grep") | .hooks[] | select(.command | contains("block-sensitive-read.sh"))] | length == 1' "$SETTINGS_ABSOLUTE_PATH"
  [ "$status" -eq 0 ]
}

# --- the shared payload reader ---

@test "an ordinary Bash call and a Read call each run at most one jq" {
  local shim_directory="$BATS_TEST_TMPDIR/shim" real_jq json
  real_jq=$(command -v jq)
  mkdir -p "$shim_directory"
  printf '#!/usr/bin/env bash\nprintf "jq\\n" >> "%s/calls.log"\nexec "%s" "$@"\n' "$BATS_TEST_TMPDIR" "$real_jq" >"$shim_directory/jq"
  chmod +x "$shim_directory/jq"
  json=$(jq -n '{tool_name: "Bash", tool_input: {command: "ls -la"}}')
  PATH="$shim_directory:$PATH" invoke_hook "$json" "$HOOK_ABSOLUTE_PATH"
  assert_allowed_by_json
  [ "$(wc -l <"$BATS_TEST_TMPDIR/calls.log")" -le 1 ]
  rm -f "$BATS_TEST_TMPDIR/calls.log"
  json=$(jq -n '{tool_name: "Read", tool_input: {file_path: "app/root.tsx"}}')
  PATH="$shim_directory:$PATH" invoke_hook "$json" "$HOOK_ABSOLUTE_PATH"
  assert_allowed_by_json
  [ "$(wc -l <"$BATS_TEST_TMPDIR/calls.log")" -le 1 ]
}
