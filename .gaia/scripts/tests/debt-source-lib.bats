#!/usr/bin/env bats
#
# Suite for .gaia/scripts/debt-source-lib.sh: the source line, the branch
# digest, the tree-state read, the precedence resolve and the retry-file
# retention. Every fixture lives under $BATS_TEST_TMPDIR; no setup_file state
# is shared, so cases appended later cannot collide with it.
#
# Run: .gaia/scripts/bats5.sh .gaia/scripts/tests/debt-source-lib.bats < /dev/null
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

# shellcheck disable=SC2154,SC2030,SC2031
# The library sets the globals the tests read, and bats runs each test in a subshell.

bats_require_minimum_version 1.5.0

setup() {
  REAL_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  LIB="$REAL_ROOT/.gaia/scripts/debt-source-lib.sh"
  # shellcheck source=/dev/null
  . "$LIB"
}

# make_scratch_repo <directory> <branch>: a repository with one commit on <branch>.
make_scratch_repo() {
  mkdir -p "$1"
  git -C "$1" init -q -b "$2"
  git -C "$1" config user.email t@example.com
  git -C "$1" config user.name t
  git -C "$1" commit -q --allow-empty -m init
}

hasher_all_a() { printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'; }
hasher_short() { printf 'xyz'; }
hasher_fails() { return 1; }

@test "digest of a branch is pinned and the worktree spelling matches" {
  run gaia_debt_source_digest debt/1234-foo
  [ "$status" -eq 0 ]
  [ "$output" = "ce624e2ca1a2" ]
  run gaia_debt_source_digest worktree-debt+1234-foo
  [ "$status" -eq 0 ]
  [ "$output" = "ce624e2ca1a2" ]
}

@test "line for a branch has the exact format and no trailing newline" {
  run gaia_debt_source_line_for_branch debt/1234-foo
  [ "$status" -eq 0 ]
  [ "$output" = "<!-- gaia-debt-source: v1 branch=ce624e2ca1a2 -->" ]
  count="$(gaia_debt_source_line_for_branch debt/1234-foo | wc -c | tr -d ' ')"
  expected="$(printf '%s' '<!-- gaia-debt-source: v1 branch=ce624e2ca1a2 -->' | wc -c | tr -d ' ')"
  [ "$count" -eq "$expected" ]
}

@test "line prints the given value without a trailing newline" {
  run gaia_debt_source_line detached
  [ "$output" = "<!-- gaia-debt-source: v1 branch=detached -->" ]
  count="$(gaia_debt_source_line detached | wc -c | tr -d ' ')"
  expected="$(printf '%s' '<!-- gaia-debt-source: v1 branch=detached -->' | wc -c | tr -d ' ')"
  [ "$count" -eq "$expected" ]
}

@test "digest uses a supplied hasher that prints 64 hex characters" {
  run gaia_debt_source_digest debt/1234-foo hasher_all_a
  [ "$status" -eq 0 ]
  [ "$output" = "aaaaaaaaaaaa" ]
}

@test "digest fails and prints nothing for a malformed or failing hasher" {
  run gaia_debt_source_digest debt/1234-foo hasher_short
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  run gaia_debt_source_digest debt/1234-foo hasher_fails
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  run gaia_debt_source_line_for_branch debt/1234-foo hasher_fails
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "tree state names the checked-out branch" {
  make_scratch_repo "$BATS_TEST_TMPDIR/repo" debt/1234-foo
  status=0
  gaia_debt_source_tree_state "$BATS_TEST_TMPDIR/repo" || status=$?
  [ "$status" -eq 0 ]
  [ "$gaia_debt_source_tree_branch" = "debt/1234-foo" ]
}

@test "tree state reports a detached HEAD with an empty branch" {
  make_scratch_repo "$BATS_TEST_TMPDIR/repo" main
  git -C "$BATS_TEST_TMPDIR/repo" checkout -q --detach
  status=0
  gaia_debt_source_tree_state "$BATS_TEST_TMPDIR/repo" || status=$?
  [ "$status" -eq 1 ]
  [ -z "$gaia_debt_source_tree_branch" ]
}

@test "tree state reports a directory outside any repository" {
  mkdir -p "$BATS_TEST_TMPDIR/plain/inner"
  export GIT_CEILING_DIRECTORIES="$BATS_TEST_TMPDIR/plain"
  status=0
  gaia_debt_source_tree_state "$BATS_TEST_TMPDIR/plain/inner" || status=$?
  [ "$status" -eq 2 ]
  [ -z "$gaia_debt_source_tree_branch" ]
}

@test "tree state answers the short name when a tag shares the branch name" {
  make_scratch_repo "$BATS_TEST_TMPDIR/repo" x
  git -C "$BATS_TEST_TMPDIR/repo" tag x
  gaia_debt_source_tree_state "$BATS_TEST_TMPDIR/repo" || true
  [ "$gaia_debt_source_tree_branch" = "x" ]
}

@test "tree state ignores an inherited git directory variable" {
  make_scratch_repo "$BATS_TEST_TMPDIR/first" debt/1-first
  make_scratch_repo "$BATS_TEST_TMPDIR/second" debt/2-second
  export GIT_DIR="$BATS_TEST_TMPDIR/second/.git"
  gaia_debt_source_tree_state "$BATS_TEST_TMPDIR/first" || true
  [ "$gaia_debt_source_tree_branch" = "debt/1-first" ]
}

@test "resolve prefers the finding field over the flag" {
  printf '{"source_branch": "debt/7-a"}\n' >"$BATS_TEST_TMPDIR/f.json"
  gaia_debt_source_resolve "$BATS_TEST_TMPDIR/f.json" debt/8-b "$BATS_TEST_TMPDIR"
  [ "$gaia_debt_source_state" = "branch" ]
  [ "$gaia_debt_source_branch" = "debt/7-a" ]
  [ "$gaia_debt_source_line_text" = "<!-- gaia-debt-source: v1 branch=966c09ebcad9 -->" ]
}

@test "resolve uses the flag when the finding has no field" {
  printf '{"a": 1}\n' >"$BATS_TEST_TMPDIR/f.json"
  gaia_debt_source_resolve "$BATS_TEST_TMPDIR/f.json" debt/8-b "$BATS_TEST_TMPDIR"
  [ "$gaia_debt_source_state" = "branch" ]
  [ "$gaia_debt_source_branch" = "debt/8-b" ]
  [ "$gaia_debt_source_line_text" = "<!-- gaia-debt-source: v1 branch=fe4badbbc786 -->" ]
}

@test "resolve treats an empty source_branch as detached" {
  printf '{"source_branch": ""}\n' >"$BATS_TEST_TMPDIR/f.json"
  gaia_debt_source_resolve "$BATS_TEST_TMPDIR/f.json" debt/8-b "$BATS_TEST_TMPDIR"
  [ "$gaia_debt_source_state" = "detached" ]
  [ -z "$gaia_debt_source_branch" ]
  [ "$gaia_debt_source_line_text" = "<!-- gaia-debt-source: v1 branch=detached -->" ]
}

@test "resolve ignores a non-string source_branch" {
  printf '{"source_branch": 42}\n' >"$BATS_TEST_TMPDIR/f.json"
  gaia_debt_source_resolve "$BATS_TEST_TMPDIR/f.json" debt/8-b "$BATS_TEST_TMPDIR"
  [ "$gaia_debt_source_state" = "branch" ]
  [ "$gaia_debt_source_branch" = "debt/8-b" ]
  [ "$gaia_debt_source_line_text" = "<!-- gaia-debt-source: v1 branch=fe4badbbc786 -->" ]
}

@test "resolve falls to unknown with no field, no flag and no repository" {
  printf '{"a": 1}\n' >"$BATS_TEST_TMPDIR/f.json"
  mkdir -p "$BATS_TEST_TMPDIR/plain/inner"
  export GIT_CEILING_DIRECTORIES="$BATS_TEST_TMPDIR/plain"
  status=0
  gaia_debt_source_resolve "$BATS_TEST_TMPDIR/f.json" "" "$BATS_TEST_TMPDIR/plain/inner" || status=$?
  [ "$status" -eq 0 ]
  [ "$gaia_debt_source_state" = "unknown" ]
  [ -z "$gaia_debt_source_branch" ]
  [ "$gaia_debt_source_line_text" = "<!-- gaia-debt-source: v1 branch=unknown -->" ]
}

@test "resolve reads the tree when neither field nor flag is given" {
  printf '{"a": 1}\n' >"$BATS_TEST_TMPDIR/f.json"
  make_scratch_repo "$BATS_TEST_TMPDIR/repo" debt/5-x
  gaia_debt_source_resolve "$BATS_TEST_TMPDIR/f.json" "" "$BATS_TEST_TMPDIR/repo"
  [ "$gaia_debt_source_state" = "branch" ]
  [ "$gaia_debt_source_branch" = "debt/5-x" ]
  [ "$gaia_debt_source_line_text" = "<!-- gaia-debt-source: v1 branch=da97cdeaf0ed -->" ]
}

@test "resolve reads a detached tree as detached" {
  printf '{"a": 1}\n' >"$BATS_TEST_TMPDIR/f.json"
  make_scratch_repo "$BATS_TEST_TMPDIR/repo" main
  git -C "$BATS_TEST_TMPDIR/repo" checkout -q --detach
  gaia_debt_source_resolve "$BATS_TEST_TMPDIR/f.json" "" "$BATS_TEST_TMPDIR/repo"
  [ "$gaia_debt_source_state" = "detached" ]
  [ "$gaia_debt_source_line_text" = "<!-- gaia-debt-source: v1 branch=detached -->" ]
}

@test "resolve yields the unknown line when the digest fails" {
  printf '{"source_branch": "debt/7-a"}\n' >"$BATS_TEST_TMPDIR/f.json"
  gaia_debt_source_resolve "$BATS_TEST_TMPDIR/f.json" "" "$BATS_TEST_TMPDIR" hasher_fails
  [ "$gaia_debt_source_line_text" = "$GAIA_DEBT_SOURCE_UNKNOWN_LINE" ]
}

@test "retain records the branch on a retry file lacking the field" {
  printf '{"b": 2, "a": {"c": 1}}\n' >"$BATS_TEST_TMPDIR/retry.json"
  cp "$BATS_TEST_TMPDIR/retry.json" "$BATS_TEST_TMPDIR/orig.json"
  printf '{}\n' >"$BATS_TEST_TMPDIR/f.json"
  gaia_debt_source_resolve "$BATS_TEST_TMPDIR/f.json" debt/5-x "$BATS_TEST_TMPDIR"
  gaia_debt_source_retain "$BATS_TEST_TMPDIR/retry.json"
  [ "$(jq -r .source_branch "$BATS_TEST_TMPDIR/retry.json")" = "debt/5-x" ]
  [ "$(jq -S 'del(.source_branch)' "$BATS_TEST_TMPDIR/retry.json")" = "$(jq -S . "$BATS_TEST_TMPDIR/orig.json")" ]
}

@test "retain records an empty branch for a detached resolve" {
  printf '{"b": 2}\n' >"$BATS_TEST_TMPDIR/retry.json"
  printf '{"source_branch": ""}\n' >"$BATS_TEST_TMPDIR/f.json"
  gaia_debt_source_resolve "$BATS_TEST_TMPDIR/f.json" "" "$BATS_TEST_TMPDIR"
  [ "$gaia_debt_source_state" = "detached" ]
  gaia_debt_source_retain "$BATS_TEST_TMPDIR/retry.json"
  [ "$(jq -c '.source_branch' "$BATS_TEST_TMPDIR/retry.json")" = '""' ]
}

@test "retain leaves a file that already carries the field byte-identical" {
  printf '{"b": 2,   "source_branch": "debt/9-z"}\n' >"$BATS_TEST_TMPDIR/retry.json"
  cp "$BATS_TEST_TMPDIR/retry.json" "$BATS_TEST_TMPDIR/before.json"
  printf '{}\n' >"$BATS_TEST_TMPDIR/f.json"
  gaia_debt_source_resolve "$BATS_TEST_TMPDIR/f.json" debt/5-x "$BATS_TEST_TMPDIR"
  gaia_debt_source_retain "$BATS_TEST_TMPDIR/retry.json"
  cmp "$BATS_TEST_TMPDIR/retry.json" "$BATS_TEST_TMPDIR/before.json"
}

@test "retain leaves the file byte-identical after an unknown resolve" {
  printf '{"b":   2}\n' >"$BATS_TEST_TMPDIR/retry.json"
  cp "$BATS_TEST_TMPDIR/retry.json" "$BATS_TEST_TMPDIR/before.json"
  printf '{}\n' >"$BATS_TEST_TMPDIR/f.json"
  mkdir -p "$BATS_TEST_TMPDIR/plain/inner"
  export GIT_CEILING_DIRECTORIES="$BATS_TEST_TMPDIR/plain"
  gaia_debt_source_resolve "$BATS_TEST_TMPDIR/f.json" "" "$BATS_TEST_TMPDIR/plain/inner"
  [ "$gaia_debt_source_state" = "unknown" ]
  gaia_debt_source_retain "$BATS_TEST_TMPDIR/retry.json"
  cmp "$BATS_TEST_TMPDIR/retry.json" "$BATS_TEST_TMPDIR/before.json"
}

@test "retain keeps the file and returns 0 when the directory is read-only" {
  mkdir -p "$BATS_TEST_TMPDIR/ro"
  printf '{"b":   2}\n' >"$BATS_TEST_TMPDIR/ro/retry.json"
  cp "$BATS_TEST_TMPDIR/ro/retry.json" "$BATS_TEST_TMPDIR/before.json"
  printf '{}\n' >"$BATS_TEST_TMPDIR/f.json"
  gaia_debt_source_resolve "$BATS_TEST_TMPDIR/f.json" debt/5-x "$BATS_TEST_TMPDIR"
  chmod 555 "$BATS_TEST_TMPDIR/ro"
  status=0
  gaia_debt_source_retain "$BATS_TEST_TMPDIR/ro/retry.json" || status=$?
  chmod 755 "$BATS_TEST_TMPDIR/ro"
  [ "$status" -eq 0 ]
  cmp "$BATS_TEST_TMPDIR/ro/retry.json" "$BATS_TEST_TMPDIR/before.json"
}

@test "the metadata check ignores the source line and stays armed on the key line" {
  line="$(gaia_debt_source_line_for_branch debt/1234-foo)"
  key='<!-- gaia-debt-key: v1 class=holistic/swallowed-error path=app/a.ts line=10 -->'
  tail_text='**Location:** app/a.ts:10

**Failure mode:** swallowed error

**Suggested fix:** rethrow'
  printf '%s\n%s\n\n%s\n' "$key" "$line" "$tail_text" >"$BATS_TEST_TMPDIR/body.md"
  printf '%s\n\n%s\n' "$line" "$tail_text" >"$BATS_TEST_TMPDIR/nokey.md"
  run bash "$REAL_ROOT/.gaia/scripts/check-debt-issue-metadata.sh" --pre-file \
    --labels 'tech-debt,severity:minor,audience:adopter' --body-file "$BATS_TEST_TMPDIR/body.md"
  [ "$status" -eq 0 ]
  [ "${output##* }" = "clean" ]
  run bash "$REAL_ROOT/.gaia/scripts/check-debt-issue-metadata.sh" --pre-file \
    --labels 'tech-debt,severity:minor,audience:adopter' --body-file "$BATS_TEST_TMPDIR/nokey.md"
  [ "$status" -ne 0 ]
}

@test "sourcing twice and under set -u prints nothing and succeeds" {
  run bash -c 'set -u; . "$1"; . "$1"; echo "rc=$?"' _ "$LIB"
  [ "$status" -eq 0 ]
  [ "$output" = "rc=0" ]
}

@test "the library parses under the system bash" {
  run /bin/bash -n "$LIB"
  [ "$status" -eq 0 ]
}

# ---- filing through file-tech-debt.sh -------------------------------------
# A scratch repository on main holds copies of the filing script and its
# siblings; a linked worktree carries the branch under test. gh is a stub.

FX_SIBLINGS="file-tech-debt.sh main-root-lib.sh debt-dedup.sh check-debt-issue-metadata.sh branch-name-lib.sh debt-source-lib.sh debt-list-lib.sh"

# fx_copy_scripts <directory>: copies of the script and its siblings, never links.
fx_copy_scripts() {
  local name
  mkdir -p "$1/.gaia/scripts"
  for name in $FX_SIBLINGS; do
    cp "$REAL_ROOT/.gaia/scripts/$name" "$1/.gaia/scripts/$name"
  done
}

# fx_write_gh_stub: a gh answering from $FX_STUB; issue create keeps each body.
fx_write_gh_stub() {
  mkdir -p "$FX_STUB" "$BATS_TEST_TMPDIR/bin"
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
stub="$FX_STUB"
printf '%s\n' "$*" >>"$stub/log"
case "$*" in
  *"--json hasIssuesEnabled"*)
    if [ -f "$stub/probe-fail" ]; then
      cat "$stub/probe-fail" >&2
      exit 1
    fi
    echo '{"hasIssuesEnabled":true,"viewerPermission":"ADMIN"}'
    ;;
  "issue list"*"--limit 1 "*) echo '[]' ;;
  "issue list"*"--label severity:investigate"*) echo '[]' ;;
  "api --paginate"*"state=open"*) cat "$stub/open.json" 2>/dev/null || echo '[]' ;;
  "api --paginate"*"state=closed"*) echo '[]' ;;
  "issue create"*)
    body_file="$(printf '%s\n' "$@" | sed -n '/^--body-file$/{n;p;}')"
    count=0
    [ -f "$stub/open.json" ] && count="$(jq 'length' "$stub/open.json")"
    number=$((101 + count))
    cp "$body_file" "$stub/body-$number.md"
    [ -f "$stub/open.json" ] || echo '[]' >"$stub/open.json"
    jq -c --rawfile body "$body_file" --argjson number "$number" '. + [{number: $number, body: $body}]' \
      "$stub/open.json" >"$stub/open.next"
    mv "$stub/open.next" "$stub/open.json"
    echo "https://github.com/owner/name/issues/$number"
    ;;
  "issue view"*)
    number="$(printf '%s\n' "$@" | sed -n '3p')"
    jq -c --argjson number "$number" '.[] | select(.number == $number) | {body}' "$stub/open.json"
    ;;
  "label list"*) printf 'tech-debt\nseverity:major\nseverity:minor\naudience:adopter\n' ;;
  *) ;;
esac
exit 0
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  export FX_STUB
}

# fx_build <worktree-branch>: FX_MAIN (on main, scripts committed) and FX_WT.
fx_build() {
  FX_STUB="$BATS_TEST_TMPDIR/stub"
  FX_MAIN="$BATS_TEST_TMPDIR/fx/main"
  FX_WT="$BATS_TEST_TMPDIR/fx/wt"
  mkdir -p "$FX_MAIN"
  git -C "$FX_MAIN" init -q
  git -C "$FX_MAIN" symbolic-ref HEAD refs/heads/main
  git -C "$FX_MAIN" config user.email t@example.com
  git -C "$FX_MAIN" config user.name t
  fx_copy_scripts "$FX_MAIN"
  git -C "$FX_MAIN" add -A
  git -C "$FX_MAIN" commit -q -m init
  git -C "$FX_MAIN" worktree add -q -b "$1" "$FX_WT"
  fx_write_gh_stub
}

# fx_finding <file> <path> <line> [<jq filter>]: a non-security adopter finding.
fx_finding() {
  jq -n -c --arg path "$2" --argjson line "$3" '{member: "code-audit-frontend",
    finding_class: "holistic/swallowed-error", path: $path, line: $line, severity: "major",
    security: false, title: "TITLE", failure_mode: "FAILURE", suggested_fix: "FIX", audience: "adopter"} | '"${4:-.}" >"$1"
}

# fx_file <script-tree> <cwd> <finding> [args]: files through that tree's script.
fx_file() {
  local tree="$1" directory="$2" finding="$3"
  shift 3
  cd "$directory" || return 1
  run bash "$tree/.gaia/scripts/file-tech-debt.sh" file --finding "$finding" \
    --outcome-file "$directory/outcome/outcomes.jsonl" --repo owner/name "$@"
}

fx_body_line() { sed -n "${2}p" "$FX_STUB/body-$1.md"; }

@test "a worktree copy files with the source line of its own branch and no raw name" {
  fx_build debt/1234-foo
  fx_finding "$FX_WT/f.json" app/a.ts 10
  fx_file "$FX_WT" "$FX_MAIN" "$FX_WT/f.json"
  [ "$status" -eq 0 ]
  [ "$output" = "filed 101" ]
  [ "$(jq -r '.outcome' "$FX_MAIN/outcome/outcomes.jsonl")" = filed ]
  [ "$(fx_body_line 101 1)" = '<!-- gaia-debt-key: v1 class=holistic/swallowed-error path=app/a.ts line=10 -->' ]
  [ "$(fx_body_line 101 2)" = '<!-- gaia-debt-source: v1 branch=ce624e2ca1a2 -->' ]
  [ -z "$(fx_body_line 101 3)" ]
  run grep -c -e 'debt/1234-foo' -e '1234-foo' "$FX_STUB/body-101.md"
  [ "$output" = 0 ]
}

@test "the worktree branch spelling files with the same digest as the plain branch" {
  fx_build worktree-debt+1234-foo
  fx_finding "$FX_WT/f.json" app/a.ts 10
  fx_file "$FX_WT" "$FX_MAIN" "$FX_WT/f.json"
  [ "$status" -eq 0 ]
  [ "$(fx_body_line 101 2)" = '<!-- gaia-debt-source: v1 branch=ce624e2ca1a2 -->' ]
}

@test "a detached worktree files with branch detached" {
  fx_build debt/1234-foo
  git -C "$FX_WT" checkout -q --detach
  fx_finding "$FX_WT/f.json" app/a.ts 10
  fx_file "$FX_WT" "$FX_MAIN" "$FX_WT/f.json"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.outcome' "$FX_MAIN/outcome/outcomes.jsonl")" = filed ]
  [ "$(fx_body_line 101 2)" = '<!-- gaia-debt-source: v1 branch=detached -->' ]
}

@test "the main checkout's script run from inside a worktree records main, not the cwd branch" {
  fx_build debt/1234-foo
  fx_finding "$FX_WT/f.json" app/a.ts 10
  fx_file "$FX_MAIN" "$FX_WT" "$FX_WT/f.json"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.outcome' "$FX_WT/outcome/outcomes.jsonl")" = filed ]
  [ "$(fx_body_line 101 2)" = '<!-- gaia-debt-source: v1 branch=0d6e4079e367 -->' ]
}

@test "a transient filing keeps the first branch in the retry file and a replay records it" {
  fx_build debt/5-x
  fx_finding "$FX_WT/f.json" app/a.ts 10
  printf 'HTTP 502\n' >"$FX_STUB/probe-fail"
  fx_file "$FX_WT" "$FX_MAIN" "$FX_WT/f.json"
  [ "$status" -eq 0 ]
  [ "$output" = transient ]
  [ "$(jq -r '.outcome' "$FX_MAIN/outcome/outcomes.jsonl")" = transient ]
  local retry_file
  retry_file="$(find "$FX_MAIN/outcome/filing-retry" -type f -name '*.json' | head -n1)"
  [ -n "$retry_file" ]
  [ "$(jq -r '.source_branch' "$retry_file")" = debt/5-x ]
  [ "$(jq -S 'del(.source_branch)' "$retry_file")" = "$(jq -S . "$FX_WT/f.json")" ]
  git -C "$FX_WT" checkout -q -b feat/other
  rm -f "$FX_STUB/probe-fail"
  fx_file "$FX_WT" "$FX_MAIN" "$retry_file"
  [ "$status" -eq 0 ]
  [ "$(tail -n1 "$FX_MAIN/outcome/outcomes.jsonl" | jq -r '.outcome')" = filed ]
  [ "$(fx_body_line 101 2)" = '<!-- gaia-debt-source: v1 branch=da97cdeaf0ed -->' ]
  run grep -c 3b0035df5844 "$FX_STUB/body-101.md"
  [ "$output" = 0 ]
}

@test "a transient filing of a finding that already carries source_branch retains it byte for byte" {
  fx_build debt/5-x
  fx_finding "$FX_WT/f.json" app/a.ts 10 '. + {source_branch: "debt/7-a"}'
  printf 'HTTP 502\n' >"$FX_STUB/probe-fail"
  fx_file "$FX_WT" "$FX_MAIN" "$FX_WT/f.json"
  [ "$output" = transient ]
  local retry_file
  retry_file="$(find "$FX_MAIN/outcome/filing-retry" -type f -name '*.json' | head -n1)"
  cmp "$retry_file" "$FX_WT/f.json"
}

@test "through the script the finding field beats the flag and the flag beats the tree" {
  fx_build feat/other
  fx_finding "$FX_WT/a.json" app/a.ts 10 '. + {source_branch: "debt/7-a"}'
  fx_finding "$FX_WT/b.json" app/b.ts 20
  fx_file "$FX_WT" "$FX_MAIN" "$FX_WT/a.json" --source-branch debt/8-b
  [ "$status" -eq 0 ]
  [ "$(jq -r '.outcome' "$FX_MAIN/outcome/outcomes.jsonl")" = filed ]
  [ "$(fx_body_line 101 2)" = '<!-- gaia-debt-source: v1 branch=966c09ebcad9 -->' ]
  fx_file "$FX_WT" "$FX_MAIN" "$FX_WT/b.json" --source-branch debt/8-b
  [ "$status" -eq 0 ]
  [ "$(tail -n1 "$FX_MAIN/outcome/outcomes.jsonl" | jq -r '.outcome')" = filed ]
  [ "$(fx_body_line 102 2)" = '<!-- gaia-debt-source: v1 branch=fe4badbbc786 -->' ]
  run grep -c 3b0035df5844 "$FX_STUB/body-101.md"
  [ "$output" = 0 ]
  run grep -c 3b0035df5844 "$FX_STUB/body-102.md"
  [ "$output" = 0 ]
}

@test "a script tree git cannot read files with branch unknown" {
  fx_build debt/1234-foo
  local outside="$BATS_TEST_TMPDIR/outside"
  fx_copy_scripts "$outside"
  fx_finding "$FX_MAIN/f.json" app/a.ts 10
  export GIT_CEILING_DIRECTORIES="$BATS_TEST_TMPDIR"
  fx_file "$outside" "$FX_MAIN" "$FX_MAIN/f.json"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.outcome' "$FX_MAIN/outcome/outcomes.jsonl")" = filed ]
  [ "$(fx_body_line 101 2)" = '<!-- gaia-debt-source: v1 branch=unknown -->' ]
}

@test "--source-branch without a value or with an empty value is a usage error and writes nothing" {
  fx_build debt/1234-foo
  fx_finding "$FX_WT/f.json" app/a.ts 10
  fx_file "$FX_WT" "$FX_MAIN" "$FX_WT/f.json" --source-branch
  [ "$status" -eq 2 ]
  [[ "$output" == *"file-tech-debt:"* ]]
  fx_file "$FX_WT" "$FX_MAIN" "$FX_WT/f.json" --source-branch ""
  [ "$status" -eq 2 ]
  [[ "$output" == *"file-tech-debt:"* ]]
  [ ! -f "$FX_STUB/log" ] || ! grep -Eq '^(issue create|issue edit|label create)' "$FX_STUB/log"
}
