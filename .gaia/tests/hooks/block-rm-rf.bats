#!/usr/bin/env bats

# Tests for .claude/hooks/block-rm-rf.sh.
#
# The guard denies the well-known `rm -rf` footguns (root, $HOME / ~, cwd,
# unscoped glob, .git, node_modules, --no-preserve-root) while letting the
# whitelisted scratch paths and unknown relative paths through. It is
# best-effort defense-in-depth, not airtight: it always exits 0, carrying the
# allow/deny decision in stdout JSON, and broader policy lives in
# settings.json permissions.
#
# The quoting axis is the point of this suite. `read -r -a` word-splits but
# does not remove quote characters, so a target must be matched with its
# quotes stripped: `rm -rf "$HOME"` is the *careful* way to write the
# expansion and has to be denied exactly like the bare `rm -rf $HOME`. Each
# dangerous target is therefore asserted in three shapes, bare, double-quoted,
# and single-quoted, plus the partially-quoted `"$HOME"/projects` form where
# the quotes sit inside the token rather than around it.

setup() {
  . "$BATS_TEST_DIRNAME/helpers/run-hook.sh"
  HOOKS_SOURCE_DIRECTORY=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)
  HOOK_ABSOLUTE_PATH="$HOOKS_SOURCE_DIRECTORY/block-rm-rf.sh"
  SETTINGS_ABSOLUTE_PATH="${HOOKS_SOURCE_DIRECTORY%/hooks}/settings.json"
  # The session-scratchpad root follows CLAUDE_CODE_TMPDIR, and a session running
  # this suite may export one, so every case starts from the /tmp default and a case
  # that needs another root exports it itself.
  unset CLAUDE_CODE_TMPDIR
  CURRENT_USER_ID=$(id -u)
  SESSION_SCRATCHPAD="/private/tmp/claude-$CURRENT_USER_ID/-Users-you-projects-my-app/0b7c9e2a-1111-2222-3333-444455556666/scratchpad"
}

# Every payload here is about quoting, so the command text must reach the hook
# byte-for-byte: delivery goes through `invoke_hook` (helpers/run-hook.sh)
# rather than any local variant. Payloads are written in single quotes so
# `$HOME` stays the literal 5-character string the guard must match, never this
# machine's home.
run_hook_bash() {
  local command="$1"
  local json
  json=$(jq -n --arg command "$command" '{tool_name: "Bash", tool_input: {command: $command}}')
  invoke_hook "$json" "$HOOK_ABSOLUTE_PATH"
}

# expect_rm_verdict <case label> <deny|allow> <command> [needle ...] [--absent needle ...]
# One case-table row: runs the hook on <command>, then checks its verdict and
# that each needle is in the output (or, after --absent, is not). A needle pins
# the deny to its *stated* reason: without one, a target denied by the wrong
# case arm (say, `$HOME` caught by the absolute-path arm) still reads as a pass.
# Rows run as `expect_rm_verdict ... || failed=1`, and a `||` caller switches off
# errexit inside the function, so every check returns 1 explicitly and names
# its case.
expect_rm_verdict() {
  local label=$1 verdict=$2
  run_hook_bash "$3"
  shift 3
  check_rm_verdict "$label" "$verdict" "$@"
}

# The same row, run against the fixture main checkout (run_fixture_main_rmrf).
expect_fixture_rm_verdict() {
  local label=$1 verdict=$2
  run_fixture_main_rmrf "$3"
  shift 3
  check_rm_verdict "$label" "$verdict" "$@"
}

# check_rm_verdict <case label> <deny|allow> [needle ...] [--absent needle ...]
# Judges the last `run`: exit 0, the expected verdict, then the needles.
check_rm_verdict() {
  local label=$1 verdict=$2 needle mode=present
  shift 2
  if [ "$status" -ne 0 ]; then
    echo "case '$label': status $status, output: $output"
    return 1
  fi
  if grep -qF -- '"permissionDecision": "deny"' <<<"$output"; then
    [ "$verdict" = deny ] || { echo "case '$label': expected allow, got deny: $output"; return 1; }
  else
    [ "$verdict" = allow ] || { echo "case '$label': expected deny, got allow: $output"; return 1; }
  fi
  for needle in "$@"; do
    if [ "$needle" = --absent ]; then
      mode=absent
      continue
    fi
    if [ "$mode" = present ]; then
      grep -qF -- "$needle" <<<"$output" || { echo "case '$label': missing '$needle' in: $output"; return 1; }
    else
      grep -qF -- "$needle" <<<"$output" && { echo "case '$label': unexpected '$needle' in: $output"; return 1; }
    fi
  done
  return 0
}

# expect_helper_result <case label> <status|-> <output|-> <function> [argument ...]
# One case-table row for a sourced helper: `-` skips that check.
expect_helper_result() {
  local label=$1 expected_status=$2 expected_output=$3
  shift 3
  run "$@"
  if [ "$expected_status" != - ] && [ "$status" -ne "$expected_status" ]; then
    echo "case '$label': status $status, expected $expected_status"
    return 1
  fi
  if [ "$expected_output" != - ] && [ "$output" != "$expected_output" ]; then
    echo "case '$label': output [$output], expected [$expected_output]"
    return 1
  fi
  return 0
}

# --- denied: bare targets ---

# bats test_tags=protected
@test "rm -rf / is denied" {
  run_hook_bash 'rm -rf /'
  assert_denied_by_json
}

@test "dangerous rm targets are denied: \$HOME, ~, ~/, \$HOME/projects, ., *, node_modules, -fr /, --no-preserve-root -rf /" {
  local failed=0
  expect_rm_verdict "rm -rf \$HOME is denied" deny 'rm -rf $HOME' || failed=1
  expect_rm_verdict "rm -rf ~ is denied" deny 'rm -rf ~' || failed=1
  expect_rm_verdict "rm -rf ~/ is denied" deny 'rm -rf ~/' || failed=1
  expect_rm_verdict "rm -rf \$HOME/projects is denied" deny 'rm -rf $HOME/projects' || failed=1
  expect_rm_verdict "rm -rf . is denied" deny 'rm -rf .' || failed=1
  expect_rm_verdict "rm -rf * is denied" deny 'rm -rf *' || failed=1
  expect_rm_verdict "rm -rf node_modules is denied" deny 'rm -rf node_modules' || failed=1
  expect_rm_verdict "rm -fr / (reversed flags) is denied" deny 'rm -fr /' || failed=1
  expect_rm_verdict "rm --no-preserve-root -rf / is denied" deny 'rm --no-preserve-root -rf /' || failed=1
  [ "$failed" -eq 0 ]
}

# bats test_tags=protected
@test "rm -rf .git is denied" {
  run_hook_bash 'rm -rf .git'
  assert_denied_by_json
}

@test "each denial names its own arm and states its reason" {
  local failed=0
  stage_main_checkout_fixture
  # `pnpm store prune` cleans pnpm's global store, not a project's node_modules,
  # so naming it sent Claude after a repair that repairs nothing here.
  expect_rm_verdict "the node_modules denial names the repair Claude may run and hands removal to the user" deny 'rm -rf node_modules' "run 'pnpm install'" 'ask the user to run it themselves' --absent 'store prune' || failed=1
  # denied: for the right reason:
  #
  # A deny verdict alone cannot tell a correct deny from a deny by the wrong arm.
  expect_rm_verdict "\$HOME denies via the \$HOME arm, not the absolute-path arm" deny 'rm -rf "$HOME"' 'BLOCKED: rm -rf of $HOME / ~ is forbidden.' || failed=1
  expect_rm_verdict "\${HOME} denies via the \$HOME arm" deny 'rm -rf "${HOME}"' 'BLOCKED: rm -rf of $HOME / ~ is forbidden.' || failed=1
  expect_rm_verdict "/ denies via the absolute-path arm" deny 'rm -rf /' 'rm -rf of absolute path' || failed=1
  expect_rm_verdict ". denies via the cwd arm" deny 'rm -rf "."' "BLOCKED: rm -rf of cwd ('.') is forbidden." || failed=1
  expect_rm_verdict ".git denies via the .git arm" deny 'rm -rf ".git"' 'BLOCKED: rm -rf of .git is forbidden.' || failed=1
  expect_rm_verdict "node_modules denies via the node_modules arm" deny 'rm -rf "node_modules"' 'BLOCKED: rm -rf of node_modules is forbidden' || failed=1
  expect_rm_verdict "--no-preserve-root denies via its own arm" deny 'rm --no-preserve-root -rf /' 'BLOCKED: rm with --no-preserve-root is forbidden.' || failed=1
  # Every gate explains itself: each arm's denial says what the removal would
  # destroy, not only that it is forbidden.
  expect_rm_verdict "the --no-preserve-root denial states its reason" deny 'rm --no-preserve-root -rf /' "It switches off rm's own refusal to remove the filesystem root." || failed=1
  expect_rm_verdict "the absolute-path denial states its reason" deny 'rm -rf /etc' 'An absolute path can reach anywhere on this machine, outside the repository this session works in.' || failed=1
  expect_rm_verdict "the absolute-path traversal denial states its reason" deny 'rm -rf /tmp/../etc' "Its '..' segment makes it resolve somewhere its spelling does not name." || failed=1
  expect_rm_verdict "the \$HOME denial states its reason" deny 'rm -rf ~' 'The home directory holds far more than this repository, and git history cannot restore what it holds outside it. Name the target by a repository-relative path instead.' || failed=1
  expect_rm_verdict "the cwd denial states its reason" deny 'rm -rf .' 'It asks to wipe the whole working directory, .git and .claude included.' || failed=1
  expect_rm_verdict "the unscoped-glob denial states its reason" deny 'rm -rf *' 'It removes every file and folder in the working directory that is not hidden.' || failed=1
  expect_rm_verdict "the .git denial states its reason" deny 'rm -rf .git' "It holds the repository's history and refs, and a commit not yet pushed exists nowhere else." || failed=1
  # Proves the second segment is what fired, not an accidental match on the first.
  expect_rm_verdict "a chained dangerous segment denies via the target's own arm" deny 'rm -rf dist && rm -rf .git' 'BLOCKED: rm -rf of .git is forbidden.' || failed=1
  expect_fixture_rm_verdict "an absolute-path deny inside the repository names the repo-relative spelling" deny "rm -f $FIXTURE_MAIN_PHYSICAL/.gaia/local/stray-file" "its repo-relative spelling '.gaia/local/stray-file' is judged by the relative-path rules instead." || failed=1
  expect_fixture_rm_verdict "an absolute-path deny outside the repository names no repo-relative spelling" deny "rm -f /Users/you/elsewhere/notes.txt" "rm -f of absolute path" --absent 'repo-relative' || failed=1
  [ "$failed" -eq 0 ]
}

@test "quoted and brace spellings of a dangerous target are denied" {
  local failed=0
  # denied: double-quoted targets:
  #
  # Quoting the expansion is the correct, careful shell idiom, and it is exactly
  # the shape a quote-blind guard misses. These must deny identically to the
  # bare forms above.
  expect_rm_verdict "rm -rf \"\$HOME\" (quoted) is denied" deny 'rm -rf "$HOME"' || failed=1
  expect_rm_verdict "rm -rf \"/\" (quoted) is denied" deny 'rm -rf "/"' || failed=1
  expect_rm_verdict "rm -rf \".\" (quoted) is denied" deny 'rm -rf "."' || failed=1
  expect_rm_verdict "rm -rf \"*\" (quoted) is denied" deny 'rm -rf "*"' || failed=1
  expect_rm_verdict "rm -rf \"~\" (quoted) is denied" deny 'rm -rf "~"' || failed=1
  expect_rm_verdict "rm -rf \".git\" (quoted) is denied" deny 'rm -rf ".git"' || failed=1
  expect_rm_verdict "rm -rf \"node_modules\" (quoted) is denied" deny 'rm -rf "node_modules"' || failed=1
  expect_rm_verdict "rm -rf \"\$HOME/projects\" (fully quoted path) is denied" deny 'rm -rf "$HOME/projects"' || failed=1
  # Quoting only the expansion and leaving the rest bare is just as idiomatic,
  # and leaves the quote characters mid-token rather than surrounding it.
  expect_rm_verdict "rm -rf \"\$HOME\"/projects (quotes inside the token) is denied" deny 'rm -rf "$HOME"/projects' || failed=1
  # denied: single-quoted targets:
  expect_rm_verdict "rm -rf '\$HOME' (single-quoted) is denied" deny "rm -rf '\$HOME'" || failed=1
  expect_rm_verdict "rm -rf '/' (single-quoted) is denied" deny "rm -rf '/'" || failed=1
  expect_rm_verdict "rm -rf '.git' (single-quoted) is denied" deny "rm -rf '.git'" || failed=1
  # denied: the ${HOME} brace form:
  #
  # `${HOME}` is, if anything, the more deliberate spelling of the expansion, so
  # omitting it reproduces the very bug this suite exists to lock down: the guard
  # catching the casual form and missing the careful one.
  expect_rm_verdict "rm -rf \${HOME} (brace form) is denied" deny 'rm -rf ${HOME}' || failed=1
  expect_rm_verdict "rm -rf \"\${HOME}\" (quoted brace form) is denied" deny 'rm -rf "${HOME}"' || failed=1
  expect_rm_verdict "rm -rf \"\${HOME}/projects\" (quoted brace path) is denied" deny 'rm -rf "${HOME}/projects"' || failed=1
  expect_rm_verdict "rm -rf \${HOME}/.config (brace path) is denied" deny 'rm -rf ${HOME}/.config' || failed=1
  [ "$failed" -eq 0 ]
}

@test "a dangerous target in a later segment or with the operand before the flags is denied" {
  local failed=0
  # denied: a dangerous target in a non-first rm segment:
  #
  # `rm -rf node_modules && rm -rf dist` is an ordinary cleanup chain, so a guard
  # that inspects only the first rm segment lets a dangerous target ride behind a
  # harmless one.
  expect_rm_verdict "a dangerous target in the second rm segment (&&) is denied" deny 'rm -rf dist && rm -rf /' || failed=1
  expect_rm_verdict "a dangerous target in the second rm segment (;) is denied" deny 'rm -rf dist ; rm -rf ~' || failed=1
  expect_rm_verdict "a dangerous target in the second rm segment (||) is denied" deny 'rm -rf dist || rm -rf .git' || failed=1
  expect_rm_verdict "a dangerous target in the third rm segment is denied" deny 'cd /tmp && rm -rf build && rm -rf $HOME' || failed=1
  # denied: operand-first flag order:
  #
  # GNU getopt permutes argv, so `rm $HOME -rf` is exactly `rm -rf $HOME` and
  # deletes home on Linux. BSD/macOS rm does not permute, which is why this shape
  # looks harmless when hand-tested on a Mac and must be covered by the suite.
  expect_rm_verdict "rm \$HOME -rf (operand before flags) is denied" deny 'rm $HOME -rf' || failed=1
  expect_rm_verdict "rm .git -rf (operand before flags) is denied" deny 'rm .git -rf' || failed=1
  expect_rm_verdict "rm ~ -rf (operand before flags) is denied" deny 'rm ~ -rf' || failed=1
  # denied: remaining flag-shape gaps:
  # The bare form carries no -r/-f at all, so only the widened short-circuit
  # reaches it. The -rf variant above does not cover this path.
  expect_rm_verdict "rm --no-preserve-root / (no recursive flag) is denied" deny 'rm --no-preserve-root /' || failed=1
  expect_rm_verdict "rm \${HOME} -rf (brace form, operand first) is denied" deny 'rm ${HOME} -rf' || failed=1
  [ "$failed" -eq 0 ]
}

@test "continuation-line splits deny a dangerous target and allow a benign cleanup" {
  local failed=0
  # denied: backslash-newline continuations:
  #
  # Both greps in the hook are line-oriented, so a target parked on a continuation
  # line carries no `rm` token of its own and, unspliced, is never extracted. The
  # multi-line form is idiomatic and the target is a plain literal token, so it
  # must deny exactly like the one-liner it is equivalent to.
  expect_rm_verdict "a continuation-line \$HOME target is denied" deny 'rm -rf \
  $HOME/.cache/foo' || failed=1
  expect_rm_verdict "a continuation-line root target is denied" deny 'rm -rf \
  /' || failed=1
  expect_rm_verdict "a continuation-line quoted brace target is denied" deny 'rm -rf \
  "${HOME}"' || failed=1
  expect_rm_verdict "a continuation split between rm and its flags is denied" deny 'rm \
  -rf /' || failed=1
  # Splicing continuations must not turn an ordinary multi-line cleanup into a deny.
  expect_rm_verdict "a benign continuation-line cleanup is allowed" allow 'rm -rf \
  dist \
  build/output' || failed=1
  # A continuation may split a token mid-word. Bash removes the backslash-newline
  # with nothing, so the fragments reassemble into one token and the command runs
  # against the reassembled target. The splice must join the same way: a space-join
  # would cut the token into fragments that match no pattern, which is a bypass.
  expect_rm_verdict "a continuation splitting \$HOME mid-token is denied" deny 'rm -rf $HOM\
E' || failed=1
  expect_rm_verdict "a continuation splitting a quoted \$HOME mid-token is denied" deny 'rm -rf "$HO\
ME"' || failed=1
  expect_rm_verdict "a continuation splitting node_modules mid-token is denied" deny 'rm -rf node_modul\
es' || failed=1
  expect_rm_verdict "a continuation splitting .git mid-token is denied" deny 'rm -rf .gi\
t' || failed=1
  [ "$failed" -eq 0 ]
}

@test "escaped spellings of a dangerous target are denied" {
  local failed=0
  # denied: backslash-escaped targets:
  #
  # Bash strips a backslash before an ordinary character, so the escaped token
  # reassembles into the dangerous one and rm receives the real target. Stripping
  # quotes but not escapes would be half a fix.
  expect_rm_verdict "rm -rf \\\\/ (escaped root) is denied" deny 'rm -rf \/' 'rm -rf of absolute path' || failed=1
  expect_rm_verdict "rm -rf \\\\.git (escaped .git) is denied" deny 'rm -rf \.git' 'BLOCKED: rm -rf of .git is forbidden.' || failed=1
  expect_rm_verdict "rm -rf .\\\\git (escape inside the token) is denied" deny 'rm -rf .\git' 'BLOCKED: rm -rf of .git is forbidden.' || failed=1
  expect_rm_verdict "rm -rf \\\\node_modules (escaped node_modules) is denied" deny 'rm -rf \node_modules' 'BLOCKED: rm -rf of node_modules is forbidden' || failed=1
  # Honest framing: bash hands rm a file literally NAMED '$HOME' here, not the
  # home directory, so this shape was never dangerous. It denies, which fails
  # safe, and that is all this asserts. Unlike its siblings above it does
  # NOT gate the backslash strip: the legacy '\$HOME' case arm catches the raw
  # token even with the strip deleted. Kept as a behavior lock, not as evidence
  # the strip works.
  expect_rm_verdict "rm -rf \\\\\$HOME denies, though it is a fail-safe false deny, not a closed hole" deny 'rm -rf \$HOME' 'BLOCKED: rm -rf of $HOME / ~ is forbidden.' || failed=1
  [ "$failed" -eq 0 ]
}

@test "dotfile globs, repeated ./ prefixes, \$PWD forms and ~user are denied" {
  local failed=0
  # denied: the dotfile glob:
  #
  # `rm -rf .*` sits precisely between `rm -rf .` and `rm -rf *`, both denied, and
  # it removes .git and .claude. It is the one hole in the glob arm that is
  # plausibly an ACCIDENT rather than evasion: the person reaching for `.*` is
  # trying to clear dotfiles, which is exactly when .git is what they least want
  # to lose.
  expect_rm_verdict "rm -rf .* (dotfile glob) is denied" deny 'rm -rf .*' 'dotfile glob' || failed=1
  expect_rm_verdict "rm -rf ./.* (dotfile glob behind ./) is denied" deny 'rm -rf ./.*' 'dotfile glob' || failed=1
  # The idiom people reach for to avoid `.` and `..` still matches `.git`, so it
  # is the same hole, not a safer spelling of it.
  expect_rm_verdict "rm -rf .[!.]* (the skip-dot-and-dotdot idiom) is denied" deny 'rm -rf .[!.]*' 'dotfile glob' || failed=1
  expect_rm_verdict "rm -rf ..?* (the other skip-dotdot idiom) is denied" deny 'rm -rf ..?*' 'dotfile glob' || failed=1
  # Expands to `.* *`: the dotfile glob and the unscoped glob at once, spelled
  # so that neither arm sees it.
  expect_rm_verdict "rm -rf {.,}* (brace form of the dotfile glob) is denied" deny 'rm -rf {.,}*' 'unscoped brace glob' || failed=1
  expect_rm_verdict "rm -rf {,.}* (reversed brace form) is denied" deny 'rm -rf {,.}*' 'unscoped brace glob' || failed=1
  expect_rm_verdict "rm .* -rf (dotfile glob, operand first) is denied" deny 'rm .* -rf' 'dotfile glob' || failed=1
  # A `./` prefix is cosmetic and repeatable, and bash collapses `//`, so `././.*`
  # and `.//.*` reach the cwd exactly like `.*`. Stripping a single `./` would
  # close the accidental spelling and leave its evasion spellings open, which is
  # the half-fix this arm exists to avoid.
  expect_rm_verdict "rm -rf ././.* (repeated ./ prefix) is denied" deny 'rm -rf ././.*' 'dotfile glob' || failed=1
  expect_rm_verdict "rm -rf .//.* (collapsed // prefix) is denied" deny 'rm -rf .//.*' 'dotfile glob' || failed=1
  expect_rm_verdict "rm -rf ././.git (repeated ./ prefix) is denied" deny 'rm -rf ././.git' 'BLOCKED: rm -rf of .git is forbidden.' || failed=1
  expect_rm_verdict "rm -rf .///.git (repeated slashes) is denied" deny 'rm -rf .///.git' 'BLOCKED: rm -rf of .git is forbidden.' || failed=1
  expect_rm_verdict "rm -rf .//node_modules is denied" deny 'rm -rf .//node_modules' 'BLOCKED: rm -rf of node_modules is forbidden' || failed=1
  # denied: $PWD and ~user spellings of a target that already has an arm:
  expect_rm_verdict "rm -rf \$PWD/.git is denied" deny 'rm -rf $PWD/.git' 'BLOCKED: rm -rf of .git is forbidden.' || failed=1
  expect_rm_verdict "rm -rf \${PWD}/.git (brace form) is denied" deny 'rm -rf ${PWD}/.git' 'BLOCKED: rm -rf of .git is forbidden.' || failed=1
  # `$PWD` IS the cwd, so it must land on the same arm as a bare `.`.
  expect_rm_verdict "rm -rf \$PWD (bare) denies via the cwd arm" deny 'rm -rf $PWD' "BLOCKED: rm -rf of cwd ('.') is forbidden." || failed=1
  expect_rm_verdict "rm -rf \$PWD/* denies via the unscoped-glob arm" deny 'rm -rf $PWD/*' "BLOCKED: rm -rf of unscoped glob ('*') is forbidden." || failed=1
  # `$PWD/` is still the cwd. Rewriting the prefix must not leave an empty token
  # that falls through to the catch-all.
  expect_rm_verdict "rm -rf \$PWD/ (trailing slash) denies via the cwd arm" deny 'rm -rf $PWD/' "BLOCKED: rm -rf of cwd ('.') is forbidden." || failed=1
  expect_rm_verdict "rm -rf \${PWD}/ (brace form, trailing slash) denies via the cwd arm" deny 'rm -rf ${PWD}/' "BLOCKED: rm -rf of cwd ('.') is forbidden." || failed=1
  expect_rm_verdict "rm -rf ~root (a named user's home) is denied" deny 'rm -rf ~root' 'BLOCKED: rm -rf of $HOME / ~ is forbidden.' || failed=1
  [ "$failed" -eq 0 ]
}

@test "a quoted separator before the target does not hide it" {
  local failed=0
  # denied: a quoted ; & or | in an operand:
  #
  # Segment extraction stops at the first `;`, `&`, or `|` byte, on the assumption
  # that those bytes always terminate a command. Inside quotes they do not: they
  # are ordinary characters in an operand. `rm -rf ";" $HOME` hands bash the argv
  # [-rf] [;] [$HOME] and deletes home, while an unrepaired guard extracts only
  # `rm -rf "`, never tokenizes $HOME, and allows it.
  expect_rm_verdict "a quoted ; before the target does not hide it (\$HOME)" deny 'rm -rf ";" $HOME' 'BLOCKED: rm -rf of $HOME / ~ is forbidden.' || failed=1
  expect_rm_verdict "a quoted ; before the target does not hide it (root)" deny 'rm -rf ";" /' 'rm -rf of absolute path' || failed=1
  expect_rm_verdict "a quoted & before the target does not hide it" deny 'rm -rf "a&b" .git' 'BLOCKED: rm -rf of .git is forbidden.' || failed=1
  expect_rm_verdict "a quoted | before the target does not hide it" deny 'rm -rf "x|y" ~' 'BLOCKED: rm -rf of $HOME / ~ is forbidden.' || failed=1
  # The short-circuit grep is quote-blind the same way, and it runs first: if it
  # exits here, none of the deny logic is ever reached. GNU getopt permutes argv,
  # so this deletes home on Linux.
  expect_rm_verdict "a quoted ; between rm and its flags does not defeat the short-circuit" deny 'rm ";" -rf $HOME' 'BLOCKED: rm -rf of $HOME / ~ is forbidden.' || failed=1
  # Neutralizing the quoted separator must not glue a stray byte onto the token:
  # the arms are anchored, so `$HOME;` would match none of them.
  expect_rm_verdict "a trailing quoted ; inside the target still reaches the \$HOME arm" deny 'rm -rf "$HOME;"' 'BLOCKED: rm -rf of $HOME / ~ is forbidden.' || failed=1
  expect_rm_verdict "a dangerous rm after a command carrying a quoted ; is denied" deny 'echo "a;b" && rm -rf /' 'rm -rf of absolute path' || failed=1
  [ "$failed" -eq 0 ]
}

@test ".claude deletions are denied except flagless removal of one marker file" {
  local failed=0
  # denied: .claude, the framework config:
  #
  # `.git` and `.claude` are the same class of target: the one you least want to
  # lose, sitting in the cwd of every session. The dotfile-glob arm above already
  # denies the glob that sweeps up both, and names both in its message, so the
  # direct spelling of either has to deny too.
  expect_rm_verdict "rm -rf .claude is denied" deny 'rm -rf .claude' 'BLOCKED: rm -rf of .claude is forbidden' || failed=1
  expect_rm_verdict "rm -rf \".claude\" (quoted) is denied" deny 'rm -rf ".claude"' 'BLOCKED: rm -rf of .claude is forbidden' || failed=1
  expect_rm_verdict "rm -rf ./.claude is denied" deny 'rm -rf ./.claude' 'BLOCKED: rm -rf of .claude is forbidden' || failed=1
  expect_rm_verdict "rm -rf .claude/* is denied" deny 'rm -rf .claude/*' 'BLOCKED: rm -rf of .claude is forbidden' || failed=1
  expect_rm_verdict "rm -rf .claude/hooks (a path inside .claude) is denied with the subpath reason" deny 'rm -rf .claude/hooks' 'under .claude/ is forbidden' || failed=1
  # A subpath denies with its own text, which names the spelling that passes: the
  # whole-directory text is false for one marker file, and an adopter following a
  # documented cleanup step needs the next command, not a misdescription.
  expect_rm_verdict "rm -f of one marker file under .claude denies and names the flagless spelling" deny 'rm -f .claude/i18n-strings-checked' "flagless 'rm <file>'" || failed=1
  expect_rm_verdict "rm -f of one marker file under .claude does not claim the whole directory" deny 'rm -f .claude/i18n-strings-checked' --absent 'rm -rf of .claude is forbidden' || failed=1
  expect_rm_verdict "rm -rf of a skill directory under .claude denies with the subpath reason" deny 'rm -rf .claude/skills/speckit-plan' 'under .claude/ is forbidden' || failed=1
  expect_rm_verdict "git rm -r -q of a skill directory under .claude denies with the subpath reason" deny 'git rm -r -q .claude/skills/speckit-plan' 'under .claude/ is forbidden' || failed=1
  expect_rm_verdict "flagless rm of one marker file under .claude is allowed" allow 'rm .claude/i18n-strings-checked' || failed=1
  expect_rm_verdict "git rm -q -- of one tracked file under .claude is allowed" allow 'git rm -q -- .claude/skills/speckit-plan/SKILL.md' || failed=1
  expect_rm_verdict "rm -rf \$PWD/.claude is denied" deny 'rm -rf $PWD/.claude' 'BLOCKED: rm -rf of .claude is forbidden' || failed=1
  expect_rm_verdict "rm .claude -rf (operand before flags) is denied" deny 'rm .claude -rf' 'BLOCKED: rm -rf of .claude is forbidden' || failed=1
  [ "$failed" -eq 0 ]
}

@test "an obfuscated rm command word (case, quote or backslash split) is still judged" {
  local failed=0
  # denied: spellings of the rm command word:
  #
  # Bash removes quote and backslash bytes from a word before resolving it, so
  # `r""m`, `"r"m`, and `r\m` are all the command `rm`, and macOS ships a
  # case-insensitive volume by default, so `/bin/RM` really is `/bin/rm`. The
  # guard's target matching already normalizes that way; its command-word matching
  # has to agree, or a spelling of the word carries every protected target out
  # through the short-circuit before a single deny arm is reachable.
  expect_rm_verdict "RM -rf ~ (uppercase command word) is denied" deny 'RM -rf ~' 'BLOCKED: rm -rf of $HOME / ~ is forbidden.' || failed=1
  expect_rm_verdict "Rm -rf \$HOME (mixed-case command word) is denied" deny 'Rm -rf $HOME' 'BLOCKED: rm -rf of $HOME / ~ is forbidden.' || failed=1
  expect_rm_verdict "rM -rf / (mixed-case command word) is denied" deny 'rM -rf /' 'rm -rf of absolute path' || failed=1
  expect_rm_verdict "RM -rf .git (uppercase command word) is denied" deny 'RM -rf .git' 'BLOCKED: rm -rf of .git is forbidden.' || failed=1
  expect_rm_verdict "r\"\"m -rf / (quote-split command word) is denied" deny 'r""m -rf /' 'rm -rf of absolute path' || failed=1
  expect_rm_verdict "\"r\"m -rf / (leading-quoted command word) is denied" deny '"r"m -rf /' 'rm -rf of absolute path' || failed=1
  expect_rm_verdict "r\"m\" -rf \$HOME (trailing-quoted command word) is denied" deny 'r"m" -rf $HOME' 'BLOCKED: rm -rf of $HOME / ~ is forbidden.' || failed=1
  expect_rm_verdict "'r'm -rf .git (single-quote-split command word) is denied" deny "'r'm -rf .git" 'BLOCKED: rm -rf of .git is forbidden.' || failed=1
  expect_rm_verdict "\"rm\" -rf / (fully quoted command word) is denied" deny '"rm" -rf /' 'rm -rf of absolute path' || failed=1
  # Bash strips a backslash before an ordinary character, so `r\m` IS `rm`, the
  # same defect as the quote-split spellings and the same fix.
  expect_rm_verdict "r\\\\m -rf / (backslash-split command word) is denied" deny 'r\m -rf /' 'rm -rf of absolute path' || failed=1
  # The command-word rule has to hold at all three `rm`-matching sites, not just
  # the two greps. The quoted-separator walk is gated on the command looking like
  # an `rm` at all, so a gate that only knows the literal lowercase spelling skips
  # the walk here, segment extraction then stops at the quoted `;`, and the target
  # behind it is never tokenized.
  expect_rm_verdict "RM -rf \";\" \$HOME (uppercase word + quoted separator) is denied" deny 'RM -rf ";" $HOME' 'BLOCKED: rm -rf of $HOME / ~ is forbidden.' || failed=1
  expect_rm_verdict "r\"\"m -rf \";\" / (quote-split word + quoted separator) is denied" deny 'r""m -rf ";" /' 'rm -rf of absolute path' || failed=1
  # allowed: the command-word rule must not manufacture a denial:
  #
  # Matching the word the way bash resolves it widens what gets INSPECTED. The case
  # arms still decide what gets blocked, so a benign target stays benign no matter
  # how its command word is spelled.
  expect_rm_verdict "RM file.txt (uppercase word, no -rf) is allowed" allow 'RM file.txt' || failed=1
  expect_rm_verdict "r\"\"m file.txt (quote-split word, no -rf) is allowed" allow 'r""m file.txt' || failed=1
  expect_rm_verdict "RM -rf dist (uppercase word, whitelisted target) is allowed" allow 'RM -rf dist' || failed=1
  expect_rm_verdict "r\"\"m -rf build/output (quote-split word, whitelisted target) is allowed" allow 'r""m -rf build/output' || failed=1
  [ "$failed" -eq 0 ]
}

@test "a path-qualified rm word is judged on its target" {
  local failed=0
  # the command word may be PATH-QUALIFIED:
  #
  # `/bin/rm` and `/usr/bin/rm` are the command `rm`, spelled with a path. The
  # anchor's leading boundary byte is the `/` in front of the word, so segment
  # extraction begins at `/rm …` and the token `/rm` gets judged as though it were a
  # TARGET: it trips the absolute-path arm, denies a whitelisted target, and blames
  # `/rm`, a path the user never wrote.
  #
  # The word is skipped by POSITION (it is always the segment's first token), never by
  # spelling. A spelling test broad enough to cover `/rm` (say `*/[Rr][Mm]`) would
  # equally skip `/usr/bin/rm` when it is the TARGET, turning an absolute-path deny
  # into an allow. Both directions are pinned below.
  expect_rm_verdict "/bin/rm -rf dist (path-qualified word, whitelisted target) is allowed" allow '/bin/rm -rf dist' || failed=1
  expect_rm_verdict "/usr/bin/rm -rf dist (path-qualified word, whitelisted target) is allowed" allow '/usr/bin/rm -rf dist' || failed=1
  expect_rm_verdict "/bin/RM -rf dist (path-qualified, uppercase word) is allowed" allow '/bin/RM -rf dist' || failed=1
  expect_rm_verdict "/bin/rm -rf build/output (path-qualified word) is allowed" allow '/bin/rm -rf build/output' || failed=1
  expect_rm_verdict "echo hi && /bin/rm -rf dist (path-qualified word in a later segment) is allowed" allow 'echo hi && /bin/rm -rf dist' || failed=1
  # The dangerous shapes must still deny, and must deny via the TARGET's own arm.
  # They deny today as well, but for the wrong reason: the `/rm` token is what trips
  # the absolute-path arm, not the operand. So a fix that merely stops `/rm` being
  # read as a target could silently turn these into allows. The reason needle is
  # what pins the right reason, and therefore the real fix.
  expect_rm_verdict "/bin/rm -rf / denies via the target's own absolute-path arm" deny '/bin/rm -rf /' "BLOCKED: rm -rf of absolute path '/' is forbidden." || failed=1
  expect_rm_verdict "/bin/rm -rf \$HOME denies via the \$HOME arm" deny '/bin/rm -rf $HOME' 'BLOCKED: rm -rf of $HOME / ~ is forbidden.' || failed=1
  expect_rm_verdict "/bin/rm -rf .git denies via the .git arm" deny '/bin/rm -rf .git' 'BLOCKED: rm -rf of .git is forbidden.' || failed=1
  expect_rm_verdict "/usr/bin/rm -rf .claude denies via the .claude arm" deny '/usr/bin/rm -rf .claude' 'BLOCKED: rm -rf of .claude is forbidden' || failed=1
  # The rm binary as the TARGET is an absolute path and stays denied. This is the
  # case that forbids recognizing the command word by spelling.
  expect_rm_verdict "rm -rf /usr/bin/rm (the rm binary as the target) is denied" deny 'rm -rf /usr/bin/rm' "BLOCKED: rm -rf of absolute path '/usr/bin/rm' is forbidden." || failed=1
  expect_rm_verdict "rm -rf /bin/rm (the rm binary as the target) is denied" deny 'rm -rf /bin/rm' "BLOCKED: rm -rf of absolute path '/bin/rm' is forbidden." || failed=1
  [ "$failed" -eq 0 ]
}

@test "whitelisted relative scratch targets are allowed" {
  local failed=0
  # allowed: whitelisted scratch paths:
  expect_rm_verdict "rm -rf .gaia/local/audit/x is allowed" allow 'rm -rf .gaia/local/audit/x' || failed=1
  expect_rm_verdict "rm -rf .gaia/local/cache/x is allowed" allow 'rm -rf .gaia/local/cache/x' || failed=1
  expect_rm_verdict "rm -rf dist is allowed" allow 'rm -rf dist' || failed=1
  expect_rm_verdict "rm -rf build/output is allowed" allow 'rm -rf build/output' || failed=1
  # Quote-stripping must not turn a benign quoted target into a denial.
  expect_rm_verdict "rm -rf \"dist\" (quoted whitelist entry) is allowed" allow 'rm -rf "dist"' || failed=1
  expect_rm_verdict "rm -rf ./\"dist\" (quotes inside a benign token) is allowed" allow 'rm -rf ./"dist"' || failed=1
  [ "$failed" -eq 0 ]
}

@test "absolute whitelisted scratch paths are allowed and the containers themselves denied" {
  local failed=0
  # allowed: the ABSOLUTE spelling of a whitelisted scratch path:
  #
  # `.claude/rules/shell-cwd.md` mandates an absolute path on every Bash call,
  # repo-wide, because a `cd` off the repo root persists for the rest of the session
  # and silently disarms the hooks that load their libraries by a cwd-relative path.
  # A guard that whitelists a scratch directory in its relative spelling only denies
  # the exact form that rule requires, so an agent cannot satisfy both at once. The
  # absolute spelling is authoritative; both are accepted, and these arms are what
  # make the rule and the guard agree.
  #
  # The match is a SUFFIX on the scratch segment, never a resolved root. Computing
  # the repo root would need a live `git rev-parse`, which this guard deliberately
  # does without, and baking a literal absolute prefix into a `.claude/`-distributed
  # file would violate the no-hardcoded-absolute-paths principle (root CLAUDE.md).
  # A suffix match needs neither.
  expect_rm_verdict "rm -f of an absolute .gaia/local/audit path is allowed" allow 'rm -f /Users/you/projects/my-app/.gaia/local/audit/issue-body-x.md' || failed=1
  expect_rm_verdict "rm -rf of an absolute .gaia/local/cleanse path is allowed" allow 'rm -rf /Users/you/projects/my-app/.gaia/local/cleanse/x' || failed=1
  # The PR Merge Workflow prescribes this exact pre-clear of a dispatch artifact,
  # absolute per shell-cwd.md, so the guard must not deny it.
  expect_rm_verdict "rm -f of an absolute .gaia/local/runs artifact (the prescribed pre-clear) is allowed" allow 'rm -f /Users/you/projects/my-app/.gaia/local/runs/debt/9-sample/unit-1.json' || failed=1
  expect_rm_verdict "rm -rf of the absolute .gaia/local/runs container itself is denied (children only)" deny 'rm -rf /Users/you/projects/my-app/.gaia/local/runs' 'rm -rf of absolute path' || failed=1
  expect_rm_verdict "the absolute-path deny names the whitelisted scratch roots as the next step" deny 'rm -f /Users/you/projects/my-app/notes.txt' '.gaia/local/runs/*' 'dist' || failed=1
  expect_rm_verdict "rm -rf of an absolute dist path is allowed" allow 'rm -rf /Users/you/projects/my-app/dist' || failed=1
  expect_rm_verdict "rm -rf of an absolute build path is allowed" allow 'rm -rf /Users/you/projects/my-app/build/output' || failed=1
  expect_rm_verdict "rm -rf of an absolute node_modules path is denied" deny 'rm -rf /Users/you/projects/my-app/node_modules' 'rm -rf of absolute path' || failed=1
  [ "$failed" -eq 0 ]
}

@test "absolute paths with dot, dotdot or root-anchored segments are denied" {
  local failed=0
  # The suffix match must not reach up to a filesystem-root directory. `/dist` is a
  # top-level removal that happens to share a name with a build output, and the
  # whitelist is about scratch INSIDE a project, so a non-empty parent segment is
  # required.
  expect_rm_verdict "rm -rf /dist (whitelist name at the filesystem root) is denied" deny 'rm -rf /dist' 'rm -rf of absolute path' || failed=1
  expect_rm_verdict "rm -rf /.gaia/local/audit/x (scratch at the filesystem root) is denied" deny 'rm -rf /.gaia/local/audit/x' 'rm -rf of absolute path' || failed=1
  # A `.` or `..` parent segment must not satisfy the non-empty-parent guard. Both
  # `/./dist` and `/../dist` resolve to `/dist`, the filesystem-root removal the
  # arm above exists to refuse, so pinning the intent in the bare spelling alone
  # leaves the whole family of dot-segment spellings open. This is the same class
  # the `//` collapse already handles, and it is normalized the same way rather
  # than being given arms of its own.
  expect_rm_verdict "rm -rf /./dist (dot parent segment) is denied" deny 'rm -rf /./dist' 'rm -rf of absolute path' || failed=1
  expect_rm_verdict "rm -rf /../dist (dotdot parent segment) is denied" deny 'rm -rf /../dist' 'rm -rf of absolute path' || failed=1
  expect_rm_verdict "rm -rf /.//dist (dot segment plus doubled slash) is denied" deny 'rm -rf /.//dist' 'rm -rf of absolute path' || failed=1
  # The collapse has to run to a fixed point, not once.
  expect_rm_verdict "rm -rf /././dist (repeated dot segments) is denied" deny 'rm -rf /././dist' 'rm -rf of absolute path' || failed=1
  expect_rm_verdict "rm -rf /./build (dot parent segment, build) is denied" deny 'rm -rf /./build' 'rm -rf of absolute path' || failed=1
  expect_rm_verdict "rm -rf /./.gaia/local/audit/x (dot parent segment, scratch) is denied" deny 'rm -rf /./.gaia/local/audit/x' 'rm -rf of absolute path' || failed=1
  expect_rm_verdict "rm -rf /.. (bare dotdot at the root) is denied" deny 'rm -rf /..' 'rm -rf of absolute path' || failed=1
  # Collapsing the dot segment must land the token ON the whitelist, not merely
  # off the deny arm: this is the same directory as the plain spelling.
  expect_rm_verdict "an interior ./ inside a genuinely whitelisted absolute path is allowed" allow 'rm -rf /Users/you/projects/my-app/./dist' || failed=1
  # A `..` segment makes an absolute path resolve somewhere the spelling does not
  # name, so it can never reach the whitelist: this one spells the audit directory
  # and resolves to `.git`. Relative `..` escapes stay out of reach by design (see
  # the hook header), but an absolute one is denied today and must stay denied.
  expect_rm_verdict "an absolute whitelisted path with a .. escape is denied" deny 'rm -rf /Users/you/projects/my-app/.gaia/local/audit/../../../.git' 'rm -rf of absolute path' || failed=1
  [ "$failed" -eq 0 ]
}

@test "session scratchpad removal is allowed for children only, under the resolved root" {
  local failed=0
  # the Claude Code session scratchpad:
  #
  # Claude Code tells every session to keep temporary files in
  # <temp root>/claude-<uid>/<project>/<session>/scratchpad, and
  # `.claude/rules/subagent-dispatch.md` pre-clears a dispatch output path with
  # `rm -f`. The observed denial was exactly that pre-clear. Only a CHILD of a
  # scratchpad is removable: the scratchpad itself, the claude-<uid> directory, the
  # temp root, another user's tree, and a `..` escape all stay denied.
  expect_rm_verdict "rm -f of a file in the session scratchpad is allowed" allow "rm -f $SESSION_SCRATCHPAD/unit-1.json" || failed=1
  expect_rm_verdict "rm -rf of a directory in the session scratchpad is allowed" allow "rm -rf $SESSION_SCRATCHPAD/probe" || failed=1
  expect_rm_verdict "rm -rf of a session scratchpad child under the /tmp spelling is allowed" allow "rm -rf ${SESSION_SCRATCHPAD#/private}/probe" || failed=1
  expect_rm_verdict "rm -rf of the session scratchpad directory itself is denied" deny "rm -rf $SESSION_SCRATCHPAD" 'rm -rf of absolute path' || failed=1
  expect_rm_verdict "rm -rf of the claude-<uid> directory is denied" deny "rm -rf /private/tmp/claude-$CURRENT_USER_ID" 'rm -rf of absolute path' || failed=1
  expect_rm_verdict "rm -rf of a claude-<uid> path outside any scratchpad is denied" deny "rm -rf /private/tmp/claude-$CURRENT_USER_ID/-Users-you-projects-my-app/0b7c9e2a/tasks" 'rm -rf of absolute path' || failed=1
  expect_rm_verdict "rm -rf of the system temp dir is denied" deny 'rm -rf /tmp' 'rm -rf of absolute path' || failed=1
  expect_rm_verdict "rm -rf of a file directly under the system temp dir is denied" deny 'rm -f /tmp/probe.txt' 'rm -f of absolute path' || failed=1
  expect_rm_verdict "rm -rf of another user's session scratchpad is denied" deny "rm -rf /private/tmp/claude-${CURRENT_USER_ID}9/-x/0b7c9e2a/scratchpad/probe" 'rm -rf of absolute path' || failed=1
  expect_rm_verdict "a .. escape out of the session scratchpad is denied" deny "rm -rf $SESSION_SCRATCHPAD/../../../../../Users/you" 'rm -rf of absolute path' || failed=1
  # The rows below set the root variables; each unsets or restores them after, so
  # every row judges from the /tmp default except the variable it names.
  export CLAUDE_CODE_TMPDIR=/Volumes/scratch/claude-temp/
  expect_rm_verdict "CLAUDE_CODE_TMPDIR moves the session scratchpad root" allow "rm -rf /Volumes/scratch/claude-temp/claude-$CURRENT_USER_ID/-x/0b7c9e2a/scratchpad/probe" || failed=1
  export CLAUDE_CODE_TMPDIR=/Volumes/scratch/claude-temp
  expect_rm_verdict "with CLAUDE_CODE_TMPDIR set, /tmp is not a session scratchpad root" deny "rm -rf $SESSION_SCRATCHPAD/probe" 'rm -rf of absolute path' || failed=1
  unset CLAUDE_CODE_TMPDIR
  local saved_tmpdir=${TMPDIR-}
  export TMPDIR=/var/folders/pn/xyz/T/
  expect_rm_verdict "TMPDIR is not a session scratchpad root" deny "rm -rf /var/folders/pn/xyz/T/claude-$CURRENT_USER_ID/-x/0b7c9e2a/scratchpad/probe" 'rm -rf of absolute path' || failed=1
  export TMPDIR=$saved_tmpdir
  [ "$failed" -eq 0 ]
}

@test "the deny message names each flag as given" {
  local failed=0
  # the deny text names the flags actually given:
  expect_rm_verdict "an absolute-path deny for rm -f says rm -f, not rm -rf" deny 'rm -f /Users/you/projects/my-app/notes.txt' "BLOCKED: rm -f of absolute path '/Users/you/projects/my-app/notes.txt' is forbidden." --absent 'rm -rf' || failed=1
  expect_rm_verdict "a deny for split flags names each flag as given" deny 'rm -r -f $HOME' 'BLOCKED: rm -r -f of $HOME / ~ is forbidden.' || failed=1
  expect_rm_verdict "a deny for a quoted flag names the flag without its quotes" deny 'rm "-rf" /' "BLOCKED: rm -rf of absolute path '/' is forbidden." || failed=1
  expect_rm_verdict "a deny names only flag-shaped tokens, not dashed numbers or values beside them" deny 'echo "rm -f /Users/you/projects/my-app/notes.txt costs -2 and -x1 items"' "BLOCKED: rm -f of absolute path '/Users/you/projects/my-app/notes.txt' is forbidden." || failed=1
  expect_rm_verdict "a deny names no token after a bare --" deny 'echo "rm -f /Users/you/projects/my-app/notes.txt -- see the -foo and --bar-baz notes"' "BLOCKED: rm -f of absolute path '/Users/you/projects/my-app/notes.txt' is forbidden." || failed=1
  expect_rm_verdict "the absolute-path deny names the session scratchpad as a removable root" deny 'rm -f /Users/you/projects/my-app/notes.txt' "/tmp/claude-$CURRENT_USER_ID/*/scratchpad/*" || failed=1
  [ "$failed" -eq 0 ]
}

@test "setup sentinel, worktree scratch and main-checkout scratch allowances" {
  local failed=0
  stage_main_checkout_fixture
  # /setup-gaia removes its main-branch standdown sentinel with `rm -f`, and shell-cwd.md
  # has Claude spell that path absolutely. A denied removal leaves the commit guard
  # suspended until the sentinel ages out, so both spellings must pass. The absolute case
  # runs against the staged fixture (the last row), because the registry is read from the
  # main checkout and a linked worktree's edit to it is invisible to this suite's hook.
  expect_rm_verdict "rm -f of the relative setup-in-progress sentinel is allowed" allow 'rm -f .gaia/local/setup-in-progress' || failed=1
  expect_rm_verdict "rm -rf of the absolute .gaia/local container is still denied beside the sentinel entry" deny 'rm -rf /Users/you/projects/my-app/.gaia/local' 'rm -rf of absolute path' || failed=1
  # the observed worktree-cleanup incident:
  #
  # An agent working inside a linked worktree could not delete its own scratch
  # files. `rm`, `rm -f`, and `rm -rf` on the absolute path were ALL denied, and it
  # completed the deletion with `find -delete` instead. That is the motivating
  # repro for this whole arm: the guard did not prevent a removal, it redirected a
  # competent agent to a tool the deny list does not inspect at all.
  #
  # The path below is the real shape: a worktree checkout under `.claude/worktrees/`
  # whose branch directory carries a hyphenated name, reaching the `.gaia/local/`
  # scratch that is symlinked back to the main checkout. It exercises both defects
  # at once, which is why all three shapes denied rather than just the flagged one.
  expect_rm_verdict "rm -rf of worktree scratch under .gaia/local is allowed" allow 'rm -rf /Users/you/projects/my-app/.claude/worktrees/c-text-matcher-guards/.gaia/local/audit/issue-body.md' || failed=1
  expect_rm_verdict "rm -f of worktree scratch under .gaia/local is allowed" allow 'rm -f /Users/you/projects/my-app/.claude/worktrees/c-text-matcher-guards/.gaia/local/audit/issue-body.md' || failed=1
  expect_rm_verdict "flagless rm of worktree scratch under .gaia/local is allowed" allow 'rm /Users/you/projects/my-app/.claude/worktrees/c-text-matcher-guards/.gaia/local/audit/issue-body.md' || failed=1
  # `.gaia/local/audit` is a symlink out of the worktree, so an agent may spell
  # either end of it. Both are the same directory and both must be allowed.
  expect_rm_verdict "the same scratch path resolved to the main checkout is allowed" allow 'rm -f /Users/you/projects/my-app/.gaia/local/audit/issue-body.md' || failed=1
  expect_fixture_rm_verdict "rm -f of the absolute setup-in-progress sentinel is allowed" allow "rm -f $FIXTURE_MAIN_PHYSICAL/.gaia/local/setup-in-progress" || failed=1
  [ "$failed" -eq 0 ]
}

@test "flag detection is not fooled by hyphenated components, quoting or sibling segments" {
  local failed=0
  # a hyphenated PATH COMPONENT is not a destructive flag:
  #
  # The flag probe matches `-[a-zA-Z]*[rRfF]`, which a hyphenated path component
  # ending in `r` or `f` satisfies: `my-matcher`, `my-perf`, and the incident's own
  # `c-text-matcher-guards` all contain one. So a flagless `rm <abs path>` was read
  # as a destructive `rm -r` purely because of a directory name, which is the half
  # of the incident neither issue explains.
  #
  # A genuine flag is always its own shell word, so the probe now requires a token
  # boundary in front of the dash. Quote and backslash bytes count as boundaries,
  # because bash drops them during quote removal and `rm "-rf" /` is a real flag.
  expect_rm_verdict "a hyphenated path component ending in r is not read as a flag" allow 'rm /Users/you/projects/my-matcher/notes.md' || failed=1
  expect_rm_verdict "a hyphenated path component ending in f is not read as a flag" allow 'rm /Users/you/projects/my-perf/notes.md' || failed=1
  # The boundary set includes the quote bytes precisely so this stays denied.
  expect_rm_verdict "rm \"-rf\" / (quoted flag) is still denied" deny 'rm "-rf" /' 'rm -rf of absolute path' || failed=1
  # A real flag beside a flag-shaped directory name must not be masked by the fix.
  expect_rm_verdict "rm -rf / with a hyphenated path component is still denied" deny 'rm -rf /Users/you/projects/my-matcher' 'rm -rf of absolute path' || failed=1
  # GNU getopt permutes argv, so the flag may follow the target. The boundary
  # requirement must not cost the operand-first shape.
  expect_rm_verdict "a genuine flag after an operand is still found" deny 'rm /Users/you/projects/my-matcher -rf' 'rm -rf of absolute path' || failed=1
  # a segment is judged only when IT carries a destructive flag:
  #
  # The flag test and the target test have to apply to the same segment. The guard
  # short-circuits on a flag found anywhere in the command, then extracts and judges
  # every `rm` segment; a segment carrying no `-r`/`-f` at all therefore got judged
  # on the strength of a flag belonging to a different command entirely.
  #
  # That was never a security property. `rm /abs/path/file` on its own is allowed
  # (the guard's whole advertised scope is `rm -rf`), and it stayed allowed however
  # it was spelled, so the denial only ever fired when a harmless sibling like
  # `rm -rf dist` happened to share the invocation. Nothing was prevented that
  # dropping the sibling would not have carried straight through; the cost was
  # denying prose that quotes a non-recursive `rm`.
  expect_rm_verdict "an unflagged rm segment is not judged on a sibling's flag" allow 'rm -rf dist && rm /abs/path/file' || failed=1
  expect_rm_verdict "a heredoc quoting a non-recursive rm example beside a real rm -rf is allowed" allow 'rm -rf dist
cat > /tmp/body.md <<EOF
- `rm /abs/path/file`, not `cd /abs/path && rm file`
EOF' || failed=1
  # The narrowing is per-segment, not per-command: a second segment that carries
  # its own -rf is a real removal and stays fully inspected.
  expect_rm_verdict "a FLAGGED sibling segment is still judged" deny 'rm -rf dist && rm -rf /' 'rm -rf of absolute path' || failed=1
  # The documented false-deny direction is deliberate and unchanged: a text matcher
  # cannot tell `bash -c "rm -rf /"` from prose quoting it, and of the two failure
  # directions the false deny is the safe one.
  expect_rm_verdict "a flagged rm inside a quoted string is still denied" deny 'git commit -m "fix: stop rm -rf $HOME from bypassing the guard"' 'BLOCKED: rm -rf of $HOME / ~ is forbidden.' || failed=1
  [ "$failed" -eq 0 ]
}

@test "benign rm targets and neighbours of dangerous names are allowed" {
  local failed=0
  # allowed: everything the guard deliberately does not gate:
  expect_rm_verdict "rm -rf on an unknown relative path is allowed" allow 'rm -rf some/scratch/dir' || failed=1
  expect_rm_verdict "rm -rf on an unrelated quoted variable is allowed" allow 'rm -rf "$SCRATCH_DIR"' || failed=1
  # The brace arms must be anchored, not prefix matches: a variable whose name
  # merely starts with HOME is not $HOME.
  expect_rm_verdict "rm -rf \${HOMEBREW_PREFIX} (a \$HOME-prefixed neighbour) is allowed" allow 'rm -rf ${HOMEBREW_PREFIX}' || failed=1
  # `$PWD/x` IS `x`, so rewriting the prefix must land this on the dist
  # whitelist. Denying every $PWD path would be the easy over-fix.
  expect_rm_verdict "rm -rf \${PWD}/dist (a \$PWD-prefixed whitelist entry) is allowed" allow 'rm -rf ${PWD}/dist' || failed=1
  expect_rm_verdict "rm -rf \$PWD/.gaia/local/cache/x is allowed" allow 'rm -rf $PWD/.gaia/local/cache/x' || failed=1
  # allowed: globs and dots the dotfile-glob arm must not swallow:
  #
  # The dotfile glob is dangerous because it expands in the CWD. A glob deeper in
  # the path expands inside a named directory, which is the ordinary cleanup shape
  # the whitelist exists for, so only the first path segment can trip the arm.
  expect_rm_verdict "rm -rf .gaia/local/cleanse/* (a glob inside a whitelisted path) is allowed" allow 'rm -rf .gaia/local/cleanse/*' || failed=1
  expect_rm_verdict "rm -rf .gaia/local/audit/*/findings is allowed" allow 'rm -rf .gaia/local/audit/*/findings' || failed=1
  # Starting with a dot is not the hazard; expanding in the cwd is.
  expect_rm_verdict "rm -rf .gitignore (a dotfile with no glob) is allowed" allow 'rm -rf .gitignore' || failed=1
  expect_rm_verdict "rm -rf dist/{a,b} (a scoped brace list with no glob) is allowed" allow 'rm -rf dist/{a,b}' || failed=1
  # allowed: quoted separators must not manufacture a denial:
  expect_rm_verdict "a benign chain whose first command carries a quoted ; is allowed" allow 'echo "a;b" && rm -rf dist' || failed=1
  expect_rm_verdict "a benign quoted chain is still split on its real separators" allow 'rm -rf dist && rm -rf "build/output"' || failed=1
  # Inspecting every segment must not turn an ordinary cleanup chain into a deny.
  expect_rm_verdict "a benign multi-segment rm chain is allowed" allow 'rm -rf dist && rm -rf build/output' || failed=1
  expect_rm_verdict "rm -rf node_modules_backup (a node_modules-prefixed neighbour) is allowed" allow 'rm -rf node_modules_backup' || failed=1
  expect_rm_verdict "rm without -rf is allowed" allow 'rm file.txt' || failed=1
  expect_rm_verdict "a command with no rm at all is allowed" allow 'ls -la node_modules' || failed=1
  # allowed: the .claude arm must not swallow its neighbours:
  # The arm is anchored, not a prefix match: a directory whose name merely starts
  # with `.claude` is not `.claude`.
  expect_rm_verdict "rm -rf .claudia (a .claude-prefixed neighbour) is allowed" allow 'rm -rf .claudia' || failed=1
  expect_rm_verdict "git commit -m \"warm restart\" (rm inside a word) is allowed" allow 'git commit -m "warm restart"' || failed=1
  [ "$failed" -eq 0 ]
}

@test "charm -rf x (a word merely ENDING in rm) is allowed" {
  # The leading boundary is what keeps the widened command-word match from firing
  # on every word that happens to contain `rm`.
  run_hook_bash 'charm -rf x'
  assert_allowed_by_json
}

# --- the walk's position-preserving invariant, asserted directly ---
#
# The `*rm*` fast-path gate skips the quoted-separator walk for any command whose
# raw text holds no `rm`. That skip is a no-op ONLY because the walk is
# position-preserving: it writes every character back into its own slot and the
# only byte it ever writes is a space, so it can never close a gap and manufacture
# an `rm` the raw text lacked. A deletion could: a quoted `r;m` would close up into
# `rm`.
#
# Nothing above can catch a regression here. Substitution-plus-gate and
# deletion-plus-gate return identical verdicts on every command a caller could
# actually send, so a contributor who "simplifies" `character=' '` to a `continue` breaks
# the gate's justification while all 130+ behavioral cases stay green. The invariant
# is a property of the helper, so it is asserted on the helper, which is what the
# hook's sourceable entry point exists for.

source_hook() {
  # The hook body sits behind a `main` that runs only when the file is executed, so
  # sourcing defines the helpers and consumes no stdin.
  # shellcheck source=/dev/null
  source "$HOOK_ABSOLUTE_PATH"
}

assert_position_preserving() {
  local input_text=$1 neutralized_text input_length i input_character neutralized_character
  neutralized_text=$(neutralize_quoted_separators "$input_text")

  # 1. Length is preserved: the walk substitutes, it never inserts or deletes.
  [ "${#neutralized_text}" -eq "${#input_text}" ] || return 1

  input_length=${#input_text}
  for ((i = 0; i < input_length; i++)); do
    input_character=${input_text:i:1}
    neutralized_character=${neutralized_text:i:1}
    if [ "$input_character" != "$neutralized_character" ]; then
      # 2. The only byte it ever writes is a space...
      [ "$neutralized_character" = " " ] || return 1
      # 3. ...and it only ever writes one over a `;`, `&`, or `|`.
      case "$input_character" in
        ';' | '&' | '|') ;;
        *) return 1 ;;
      esac
    fi
  done

  # 4. The consequence the fast-path gate actually leans on: no `rm` appears at an
  #    offset where the input held none. A deletion falsifies exactly this.
  for ((i = 0; i + 2 <= input_length; i++)); do
    if [ "${neutralized_text:i:2}" = "rm" ] && [ "${input_text:i:2}" != "rm" ]; then
      return 1
    fi
  done
  return 0
}

@test "the walk substitutes rather than deletes: a quoted r;m never closes into rm" {
  source_hook
  local neutralized_text
  neutralized_text=$(neutralize_quoted_separators '"r;m"')

  # Substitution writes a space into the separator's slot, giving `"r m"`. A
  # deletion would close the gap into `"rm"` and manufacture the very token the
  # fast-path gate assumes the walk can never create. Both spellings produce the
  # same end-to-end verdict (bash resolves `"r;m"` to a command literally named
  # `r;m`, never to `rm`), which is precisely why only a direct assertion catches it.
  [ "$neutralized_text" = '"r m"' ] || return 1
  grep -qF -- 'rm' <<<"$neutralized_text" && return 1
  return 0
}

@test "the walk is position-preserving across an adversarial corpus" {
  source_hook
  # Each string attacks the invariant: separators wedged between the letters of
  # `rm`, quoted and unquoted separators, nested and unbalanced quotes.
  local corpus=(
    'r;m'
    '"r;m"'
    "'r;m'"
    'r|m'
    'r&m'
    '"r|m" "r&m"'
    'a"r;m"b'
    '"r;;m"'
    'r"";m'
    'echo "r;m"'
    'rm -rf ";" $HOME'
    'echo "a;b" && rm -rf dist'
    'git commit -m "fix: a;b|c&d"'
    'rm -rf dist && rm -rf build/output'
    'unbalanced " quote ; here'
    'no separators or quotes at all'
    ';&|'
    '""'
  )
  local corpus_entry
  for corpus_entry in "${corpus[@]}"; do
    if ! assert_position_preserving "$corpus_entry"; then
      printf 'position-preserving invariant broken on: %s\n' "$corpus_entry" >&2
      return 1
    fi
  done
}

# --- the notebook allowance, against a fixture main checkout holding this tree's registry ---
#
# The hook reads the registry of the main checkout it runs in, so a linked
# worktree running this suite would otherwise judge these paths by another
# branch's registry. The fixture is a git repository carrying copies of the
# hook, its libraries and the registry under test, and the hook runs with the
# fixture as its working directory.

stage_main_checkout_fixture() {
  FIXTURE_MAIN="$BATS_TEST_TMPDIR/fixture-main"
  FIXTURE_MAIN_PHYSICAL=""
  rm -rf "$FIXTURE_MAIN"
  mkdir -p "$FIXTURE_MAIN/.claude" "$FIXTURE_MAIN/.gaia/scripts"
  local source_root="${HOOKS_SOURCE_DIRECTORY%/.claude/hooks}"
  cp -R "$HOOKS_SOURCE_DIRECTORY" "$FIXTURE_MAIN/.claude/hooks"
  cp "$source_root/.gaia/scripts/main-root-lib.sh" "$source_root/.gaia/scripts/state-registry-lib.sh" "$FIXTURE_MAIN/.gaia/scripts/"
  cp "$source_root/.gaia/state-registry.json" "$FIXTURE_MAIN/.gaia/state-registry.json"
  git -C "$FIXTURE_MAIN" init -q
  FIXTURE_MAIN_PHYSICAL="$(cd "$FIXTURE_MAIN" && pwd -P)"
}

run_fixture_main_rmrf() {
  local json
  json=$(jq -n --arg command "$1" '{tool_name: "Bash", tool_input: {command: $command}}')
  run bash -c 'cd "$3" && printf %s "$1" | bash "$2"' _ "$json" "$FIXTURE_MAIN/.claude/hooks/block-rm-rf.sh" "$FIXTURE_MAIN"
}

@test "notebook allowance: only spec and plan folders under the main checkout are removable" {
  local failed=0
  stage_main_checkout_fixture
  expect_fixture_rm_verdict "notebook allowance: rm -rf of a spec folder under the main checkout's notebook is allowed" allow "rm -rf $FIXTURE_MAIN_PHYSICAL/.notebook/specs/SPEC-001" || failed=1
  expect_fixture_rm_verdict "notebook allowance: rm -rf of a plan folder under the main checkout's notebook is allowed" allow "rm -rf $FIXTURE_MAIN_PHYSICAL/.notebook/plans/PLAN-001" || failed=1
  expect_fixture_rm_verdict "notebook allowance: rm -rf of the notebook's specs folder itself is denied" deny "rm -rf $FIXTURE_MAIN_PHYSICAL/.notebook/specs" "BLOCKED: rm -rf of absolute path '$FIXTURE_MAIN_PHYSICAL/.notebook/specs' is forbidden." || failed=1
  expect_fixture_rm_verdict "notebook allowance: rm -rf of a research folder is denied" deny "rm -rf $FIXTURE_MAIN_PHYSICAL/.notebook/research/topic-2026-10-01" "BLOCKED: rm -rf of absolute path '$FIXTURE_MAIN_PHYSICAL/.notebook/research/topic-2026-10-01' is forbidden." || failed=1
  expect_fixture_rm_verdict "notebook allowance: rm -rf of a spec folder under the old local root is denied" deny "rm -rf $FIXTURE_MAIN_PHYSICAL/.gaia/local/specs/SPEC-001" "BLOCKED: rm -rf of absolute path '$FIXTURE_MAIN_PHYSICAL/.gaia/local/specs/SPEC-001' is forbidden." || failed=1
  [ "$failed" -eq 0 ]
}

@test "_rm_whitelisted_absolute matches children_only bases, registry additions and the empty registry" {
  local failed=0
  source_hook
  # _rm_whitelisted_absolute: the registry-driven absolute-whitelist matcher:
  #
  # Tested directly against a SYNTHETIC tsv, no fixture repo and no real
  # registry read: the helper takes the whitelist as an argument precisely so
  # its match logic can be pinned here independent of the real registry's
  # contents.
  expect_helper_result "_rm_whitelisted_absolute: a child under a children_only base matches" 0 - _rm_whitelisted_absolute "/x/y/.gaia/local/audit/f" $'.gaia/local/audit\ttrue' || failed=1
  expect_helper_result "_rm_whitelisted_absolute: the bare base itself does NOT match when children_only" 1 - _rm_whitelisted_absolute "/x/y/.gaia/local/plans" $'.gaia/local/plans\ttrue' || failed=1
  expect_helper_result "_rm_whitelisted_absolute: the bare base matches when children_only is false" 0 - _rm_whitelisted_absolute "/x/y/dist" $'dist\tfalse' || failed=1
  expect_helper_result "_rm_whitelisted_absolute: a child under a children_only=false base also matches" 0 - _rm_whitelisted_absolute "/x/y/dist/a" $'dist\tfalse' || failed=1
  expect_helper_result "_rm_whitelisted_absolute: a non-empty parent segment is required" 1 - _rm_whitelisted_absolute "/dist" $'dist\tfalse' || failed=1
  expect_helper_result "_rm_whitelisted_absolute: a base absent from the tsv does not match" 1 - _rm_whitelisted_absolute "/x/y/notlisted" $'dist\tfalse' || failed=1
  # The auto-extend proof: a new registry base is whitelisted with no hook
  # edit, the 3.3 analog of the write-guard's own catch.
  expect_helper_result "_rm_whitelisted_absolute: a base ADDED to the tsv matches with no hook edit" 0 - _rm_whitelisted_absolute "/x/y/newbase" $'dist\tfalse\nnewbase\tfalse' || failed=1
  expect_helper_result "_rm_whitelisted_absolute: an empty tsv matches nothing (the fail-toward-deny substrate)" 1 - _rm_whitelisted_absolute "/x/y/dist" "" || failed=1
  [ "$failed" -eq 0 ]
}

@test "_rm_whitelist_hint lists the registry roots, children_only bases as <base>/*, then the extra root" {
  local failed=0
  source_hook
  # _rm_whitelist_hint: the absolute-path deny's next step:
  expect_helper_result "_rm_whitelist_hint: names every root, children_only bases as <base>/*" 0 ' An absolute path is removable only inside a scratch root: .gaia/local/runs/*, dist.' _rm_whitelist_hint $'.gaia/local/runs\ttrue\ndist\tfalse' || failed=1
  expect_helper_result "_rm_whitelist_hint: appends the extra root after the registry roots" 0 ' An absolute path is removable only inside a scratch root: dist, /tmp/claude-501/*/scratchpad/*.' _rm_whitelist_hint $'dist\tfalse' '/tmp/claude-501/*/scratchpad/*' || failed=1
  expect_helper_result "_rm_whitelist_hint: an empty tsv still names the extra root" 0 ' An absolute path is removable only inside a scratch root: /tmp/claude-501/*/scratchpad/*.' _rm_whitelist_hint "" '/tmp/claude-501/*/scratchpad/*' || failed=1
  expect_helper_result "_rm_whitelist_hint: an empty tsv prints nothing" 0 "" _rm_whitelist_hint "" || failed=1
  [ "$failed" -eq 0 ]
}

@test "_rm_in_session_scratchpad matches only a child of a scratchpad under a listed root" {
  local failed=0
  source_hook
  # _rm_in_session_scratchpad: the session-scratchpad allow:
  expect_helper_result "_rm_in_session_scratchpad: a child of a scratchpad under a listed root matches" 0 - _rm_in_session_scratchpad /tmp/claude-501/-p/session/scratchpad/x 501 /tmp || failed=1
  expect_helper_result "_rm_in_session_scratchpad: every listed root is tried" 0 - _rm_in_session_scratchpad /private/tmp/claude-501/-p/session/scratchpad/x 501 /tmp /private/tmp || failed=1
  expect_helper_result "_rm_in_session_scratchpad: a trailing slash on the root is ignored" 0 - _rm_in_session_scratchpad /tmp/claude-501/-p/session/scratchpad/x 501 /tmp// || failed=1
  expect_helper_result "_rm_in_session_scratchpad: an empty root (no alias, or a root of /) is skipped, never read as the filesystem root" 1 - _rm_in_session_scratchpad /claude-501/-p/session/scratchpad/x 501 "" / || failed=1
  expect_helper_result "_rm_in_session_scratchpad: the scratchpad directory itself does not match" 1 - _rm_in_session_scratchpad /tmp/claude-501/-p/session/scratchpad 501 /tmp || failed=1
  expect_helper_result "_rm_in_session_scratchpad: a scratchpad straight under claude-<uid> does not match" 1 - _rm_in_session_scratchpad /tmp/claude-501/scratchpad/x 501 /tmp || failed=1
  expect_helper_result "_rm_in_session_scratchpad: a root that is not listed does not match" 1 - _rm_in_session_scratchpad /private/tmp/claude-501/-p/session/scratchpad/x 501 /tmp || failed=1
  expect_helper_result "_rm_in_session_scratchpad: another uid does not match" 1 - _rm_in_session_scratchpad /tmp/claude-502/-p/session/scratchpad/x 501 /tmp || failed=1
  expect_helper_result "_rm_in_session_scratchpad: an empty uid matches nothing (the fail-toward-deny substrate)" 1 - _rm_in_session_scratchpad /tmp/claude-/-p/session/scratchpad/x "" /tmp || failed=1
  [ "$failed" -eq 0 ]
}

@test "_rm_repository_relative_hint names the relative spelling only for a path inside a root" {
  local failed=0
  source_hook
  expect_helper_result "_rm_repository_relative_hint: a path inside a root names its relative spelling" 0 " From the repository root, its repo-relative spelling '.gaia/local/x' is judged by the relative-path rules instead." _rm_repository_relative_hint /repo/.gaia/local/x /repo || failed=1
  expect_helper_result "_rm_repository_relative_hint: every root is tried, so the physical spelling matches" 0 " From the repository root, its repo-relative spelling 'notes.txt' is judged by the relative-path rules instead." _rm_repository_relative_hint /private/tmp/repo/notes.txt /tmp/repo /private/tmp/repo || failed=1
  expect_helper_result "_rm_repository_relative_hint: the root itself, a sibling, and an empty or / root print nothing (the root itself)" - "" _rm_repository_relative_hint /repo /repo || failed=1
  expect_helper_result "_rm_repository_relative_hint: the root itself, a sibling, and an empty or / root print nothing (a sibling)" - "" _rm_repository_relative_hint /repository-two/x /repo || failed=1
  expect_helper_result "_rm_repository_relative_hint: the root itself, a sibling, and an empty or / root print nothing (an empty or / root)" 0 "" _rm_repository_relative_hint /repo/x "" / || failed=1
  [ "$failed" -eq 0 ]
}

@test "sourcing the hook defines its helpers, consumes no stdin and leaves caller shell options alone" {
  local failed=0
  # the hook is sourceable: sourcing defines the helpers and runs no body.
  # `payload=$(cat)` at the top level blocks on stdin, so a suite that sources the
  # hook to reach an internal helper hangs instead of defining one. The `main`
  # entry point is what makes the invariant cases above reachable at all: sourcing
  # must define the helper, consume no stdin, and emit nothing.
  run bash -c 'printf %s SENTINEL | { source "$1"; printf "helper=%s stdin=%s" "$(type -t neutralize_quoted_separators)" "$(cat)"; }' _ "$HOOK_ABSOLUTE_PATH"
  [ "$status" -eq 0 ] || { echo "case 'sourceable': status $status, output: $output"; failed=1; }
  grep -qF -- 'helper=function' <<<"$output" || { echo "case 'sourceable': helper undefined: $output"; failed=1; }
  grep -qF -- 'stdin=SENTINEL' <<<"$output" || { echo "case 'sourceable': stdin consumed: $output"; failed=1; }
  # sourcing the hook does not push its shell options onto the caller.
  # `set -euo pipefail` sits inside `main`, not at the top level, so a `source`
  # cannot silently switch on errexit/nounset/pipefail in the sourcing shell. At
  # the top level it would, and every caller that sources the hook to reach a
  # helper would inherit them.
  run bash -c 'source "$1"; enabled_options=""; [[ -o errexit ]] && enabled_options="${enabled_options}e"; [[ -o nounset ]] && enabled_options="${enabled_options}u"; [[ -o pipefail ]] && enabled_options="${enabled_options}p"; printf "leaked=[%s]" "$enabled_options"' _ "$HOOK_ABSOLUTE_PATH"
  [ "$status" -eq 0 ] || { echo "case 'shell options': status $status, output: $output"; failed=1; }
  grep -qF -- 'leaked=[]' <<<"$output" || { echo "case 'shell options': leaked into the caller: $output"; failed=1; }
  [ "$failed" -eq 0 ]
}

@test "block-rm-rf.sh is executable" {
  [ -x "$HOOK_ABSOLUTE_PATH" ]
}

@test "settings.json registers the hook for both tools it binds" {
  hook_registered "$SETTINGS_ABSOLUTE_PATH" '.hooks.PreToolUse[] | select(.matcher == "Bash|Monitor")' block-rm-rf.sh
}

# --- an unparseable registry lib degrades, it does not deny everything ---
#
# The guard resolves .gaia/scripts/main-root-lib.sh and state-registry-lib.sh
# off BASH_SOURCE to read the scratch whitelist, under the `set -euo pipefail`
# at :269. That errexit sits inside main(), which is a function rather than a
# subshell, so an abort there IS the hook's exit -- and exit 2 is the
# PreToolUse deny code, refusing every Bash tool call rather than the rm
# footguns alone.
#
# Expressing this needs a COPY of the hook in a tree the test controls, since
# the real $HOOK_ABSOLUTE_PATH always resolves the real checkout's libs. Pinned to stock
# /bin/bash: the `|| true` arm both loads already carried survives on bash 5,
# so only 3.2 tells the fix apart from the arm it replaced.
#
# The filesystem root is the deliberate probe target. It is denied by a
# hardcoded arm that does not consult the registry at all, so the assertion
# isolates "did the hook survive the load" from "did the whitelist come back":
# an unreadable registry legitimately yields an empty whitelist, which changes
# what is ALLOWED but never what is denied here.

stage_rmrf_tree() {
  STAGED_ROOT="$BATS_TEST_TMPDIR/staged"
  rm -rf "$STAGED_ROOT"
  # `mkdir -p` stops at .claude on purpose: the copy below becomes
  # $STAGED_ROOT/.claude/hooks, and creating that destination first would nest
  # the source inside it instead.
  mkdir -p "$STAGED_ROOT/.claude" "$STAGED_ROOT/.gaia/scripts"
  # Staged wholesale rather than named library by library, so the staged set is
  # derived from the hooks directory instead of restated here: a library this
  # hook gains reaches the staged tree without anyone remembering this helper,
  # and each case below then degrades only the library it is named for. It also
  # keeps the jq-availability arm present, which runs ahead of everything these
  # fixtures degrade and refuses when it cannot load its own library, so a
  # staged tree without it would answer every case with that refusal rather
  # than with the degrade under test.
  cp -R "$HOOKS_SOURCE_DIRECTORY" "$STAGED_ROOT/.claude/hooks"
  restore_staged_libraries
  STAGED_HOOK="$STAGED_ROOT/.claude/hooks/block-rm-rf.sh"
}

# Copies the real .gaia/scripts libraries over the staged ones, so each case
# degrades only the library it names, from one staged tree.
restore_staged_libraries() {
  # Outside the hooks directory, so the wholesale copy above does not reach it.
  # This line stays a hand-maintained list for that reason: a further
  # .gaia/scripts load the hook's live path gains has to be added here, unless a
  # case deliberately pins that library's absence, or the staged tree goes short
  # with nothing red.
  cp "${HOOKS_SOURCE_DIRECTORY%/.claude/hooks}/.gaia/scripts/main-root-lib.sh" \
     "${HOOKS_SOURCE_DIRECTORY%/.claude/hooks}/.gaia/scripts/state-registry-lib.sh" \
     "$STAGED_ROOT/.gaia/scripts/"
}

# Overwrites <path> with an unresolved-merge-conflict body: the file opens and
# reads fine, so an existence test passes it, and bash cannot parse it.
write_conflicted_library() {
  { printf '<<<<<<< HEAD\n'; printf 'x() { :; }\n'; printf '=======\n'
    printf 'y() { :; }\n'; printf '>>>>>>> other\n'; } > "$1"
}

# run_staged_rmrf <command> <interpreter>
run_staged_rmrf() {
  local json
  json=$(jq -n --arg command "$1" '{tool_name: "Bash", tool_input: {command: $command}}')
  run bash -c 'printf %s "$1" | $3 "$2"' _ "$json" "$STAGED_HOOK" "$2"
}

@test "a broken library degrades the guard: conflict markers keep the root denied and lose only the scratch carve-out, an absent payload library exits 2" {
  local failed=0
  stage_rmrf_tree
  # The pinned rows need stock /bin/bash; without one they are skipped and the
  # unpinned rows still run.
  if [ -x /bin/bash ]; then
    restore_staged_libraries
    run_staged_rmrf 'rm -rf /' /bin/bash
    check_rm_verdict "control: the staged guard denies the filesystem root under stock /bin/bash" deny || failed=1
    restore_staged_libraries
    write_conflicted_library "$STAGED_ROOT/.gaia/scripts/main-root-lib.sh"
    run_staged_rmrf 'rm -rf /' /bin/bash
    check_rm_verdict "main-root-lib.sh holding conflict markers: the root target is still denied, on stock /bin/bash" deny || failed=1
    restore_staged_libraries
    write_conflicted_library "$STAGED_ROOT/.gaia/scripts/state-registry-lib.sh"
    run_staged_rmrf 'rm -rf /' /bin/bash
    check_rm_verdict "state-registry-lib.sh holding conflict markers: the root target is still denied, on stock /bin/bash" deny || failed=1
    # The discriminating twin for the pair above. "Still denied" is equally satisfied
    # by a guard that denies everything, so this pins what the degrade actually costs:
    # the whitelist comes back empty, so the absolute spelling of a scratch path falls
    # to the absolute-path deny instead of being allowed on a list that could not be
    # read. That is the direction the load comment promises and the direction
    # _rm_whitelisted_absolute is written for. The control proves the same staging allows
    # it when the registry parses, so the deny below is the lost carve-out and not a
    # guard that stopped reading its own whitelist.
    restore_staged_libraries
    run_staged_rmrf 'rm -rf /Users/you/projects/my-app/.gaia/local/audit/x' /bin/bash
    check_rm_verdict "control: the staged guard allows an absolute scratch path when the registry parses, on stock /bin/bash" allow || failed=1
    restore_staged_libraries
    write_conflicted_library "$STAGED_ROOT/.gaia/scripts/state-registry-lib.sh"
    run_staged_rmrf 'rm -rf /Users/you/projects/my-app/.gaia/local/audit/x' /bin/bash
    check_rm_verdict "state-registry-lib.sh holding conflict markers: the carve-out is lost, not the protection, on stock /bin/bash" deny || failed=1
  fi
  # Unpinned twins of the two registry cases above, and they are not redundant with
  # them. The pinned cases cover the bash-3.2 abort on the load itself; these cover
  # a SECOND failure on the same degrade path that only 4.4+ has. `rm_whitelist` is
  # assigned only when the registry loads, and bash 3.2 reads a declared-but-
  # unassigned local as empty while 4.4+ reads it as unset and dies on `set -u`. So
  # the /bin/bash pin that gives the cases above their teeth is exactly what blinds
  # them here on a stock Mac, and without these twins the class is caught by CI
  # alone.
  restore_staged_libraries
  write_conflicted_library "$STAGED_ROOT/.gaia/scripts/state-registry-lib.sh"
  run_staged_rmrf 'rm -rf /' "$BASH"
  check_rm_verdict "state-registry-lib.sh holding conflict markers: the root target is still denied, unpinned" deny || failed=1
  restore_staged_libraries
  write_conflicted_library "$STAGED_ROOT/.gaia/scripts/main-root-lib.sh"
  run_staged_rmrf 'rm -rf /' "$BASH"
  check_rm_verdict "main-root-lib.sh holding conflict markers: the root target is still denied, unpinned" deny || failed=1
  # the one-jq payload reader:
  local hooks_directory scratch_hooks payload
  hooks_directory=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)
  scratch_hooks="$BATS_TEST_TMPDIR/scratch-hooks"
  mkdir -p "$scratch_hooks"
  cp -R "$hooks_directory/." "$scratch_hooks/"
  rm -f "$scratch_hooks/lib/hook-payload.sh"
  payload=$(jq -nc --arg command 'rm -rf /' '{tool_name: "Bash", tool_input: {command: $command}}')
  run bash -c 'cd "$1" && printf %s "$2" | bash "$3"' _ "$BATS_TEST_TMPDIR" "$payload" "$scratch_hooks/block-rm-rf.sh"
  [ "$status" -eq 2 ] || { echo "case 'lib/hook-payload.sh absent': status $status, output: $output"; failed=1; }
  grep -qF 'BLOCKED: block-rm-rf.sh cannot load lib/hook-payload.sh' <<<"$output" || { echo "case 'lib/hook-payload.sh absent': library not named: $output"; failed=1; }
  [ "$failed" -eq 0 ]
}

@test "a non-arming Bash payload spawns exactly one jq process" {
  local hooks_directory shim_directory spawn_log real_jq payload spawn_count
  hooks_directory=$(cd "$BATS_TEST_DIRNAME/../../../.claude/hooks" && pwd)
  shim_directory="$BATS_TEST_TMPDIR/jq-shim"
  spawn_log="$BATS_TEST_TMPDIR/jq-spawns"
  real_jq=$(command -v jq)
  mkdir -p "$shim_directory"
  printf '#!/bin/sh\nprintf x >>"%s"\nexec "%s" "$@"\n' "$spawn_log" "$real_jq" >"$shim_directory/jq"
  chmod +x "$shim_directory/jq"
  : >"$spawn_log"
  payload=$(jq -nc '{tool_name: "Bash", tool_input: {command: "ls -la"}}')
  run env PATH="$shim_directory:$PATH" bash -c 'cd "$1" && printf %s "$2" | bash "$3"' _ "$BATS_TEST_TMPDIR" "$payload" "$hooks_directory/block-rm-rf.sh"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  spawn_count=$(wc -c <"$spawn_log" | tr -d ' ')
  [ "$spawn_count" -eq 1 ]
}
