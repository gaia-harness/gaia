#!/usr/bin/env bats

# Tests for .claude/hooks/classify-git-command.sh.
#
# The hook returns an allow or nothing, never a deny, so every case here asserts
# one of two outcomes: `allow` (an allow decision on stdout, exit 0) or `fall`
# (exit 0 and no output, the normal permission flow). Commands reach the hook as
# payload text and never run.
#
# The hook allows only inside its own repository, read from its own on-disk
# location, so each test copies the hook and the libraries it loads into a
# fresh fixture repository and runs that copy. A missing-library case deletes
# one file from the copy.

# shellcheck disable=SC2016  # fixtures carry `$` and backticks the hook must see unexpanded

setup() {
  SOURCE_ROOT=$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)
  REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$REPO/.claude/hooks/lib" "$REPO/.gaia/scripts"
  cp "$SOURCE_ROOT/.claude/hooks/classify-git-command.sh" "$REPO/.claude/hooks/"
  cp "$SOURCE_ROOT"/.claude/hooks/lib/*.sh "$REPO/.claude/hooks/lib/"
  cp "$SOURCE_ROOT/.gaia/scripts/main-root-lib.sh" "$REPO/.gaia/scripts/"
  HOOK="$REPO/.claude/hooks/classify-git-command.sh"
  git -C "$REPO" init --quiet --initial-branch=main
  git -C "$REPO" config user.email "test@example.com"
  git -C "$REPO" config user.name "Test"
  git -C "$REPO" config commit.gpgsign false
  git -C "$REPO" commit --quiet --allow-empty -m init
  git -C "$REPO" checkout --quiet -b feature
  FOREIGN="$BATS_TEST_TMPDIR/foreign"
  git init --quiet "$FOREIGN"
}

# classify <command> [<payload cwd>]: run the fixture's hook copy on a Bash
# payload, from the fixture repository.
classify() {
  local json
  json=$(jq -n --arg command "$1" --arg directory "${2-$REPO}" \
    '{tool_name: "Bash", cwd: $directory, tool_input: {command: $command}}')
  run bash -c 'cd "$1" && printf %s "$2" | bash "$3"' _ "$REPO" "$json" "$HOOK"
}

assert_allowed() {
  [ "$status" -eq 0 ]
  grep -qF -- '"permissionDecision": "allow"' <<<"$output"
}

assert_fell_through() {
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# expect <allow|fall> <command> [<payload cwd>]
expect() {
  echo "case: $1 | $2"
  classify "$2" "${3-$REPO}"
  case "$1" in
    allow) assert_allowed ;;
    fall) assert_fell_through ;;
    *) echo "bad verdict: $1"; return 1 ;;
  esac
}

# allow_list_entries: print each entry of the allow list, one per line.
allow_list_entries() {
  bash -c '. "$1/.claude/hooks/lib/git-allow-list.sh"; printf "%s\n" "${GAIA_GIT_ALLOWED_SUBCOMMANDS[@]}"' _ "$SOURCE_ROOT"
}

# fall_through_neighbour <spec>: an operand that matches one fall-through spec.
fall_through_neighbour() {
  case "$1" in
    --*=*) printf '%sx' "$1" ;;
    --*) printf '%s=x' "$1" ;;
    -?) printf '%s' "$1" ;;
  esac
}

# The allowed form of a subcommand whose entry vouches only for reads.
read_only_form() {
  case "$1" in
    config) printf 'git config --get user.name' ;;
    remote) printf 'git remote -v' ;;
  esac
}

# bats test_tags=protected
@test "every allow-list subcommand is allowed, and each of its fall-through options falls through" {
  local entry name spec read_form entry_count=0 spec_count=0
  local -a specs
  while IFS= read -r entry; do
    entry_count=$((entry_count + 1))
    name="${entry%% *}"
    read -r -a specs <<<"${entry#"$name"}"
    read_form=$(read_only_form "$name")
    if [ -n "$read_form" ]; then
      expect allow "$read_form"
    else
      expect allow "git $name"
    fi
    for spec in ${specs[@]+"${specs[@]}"}; do
      case "$spec" in @read-only | @no-pathspec) continue ;; esac
      spec_count=$((spec_count + 1))
      expect fall "git $name $(fall_through_neighbour "$spec") x"
    done
  done < <(allow_list_entries)
  [ "$entry_count" -eq "$(allow_list_entries | wc -l | tr -d ' ')" ]
  [ "$entry_count" -gt 0 ]
  [ "$spec_count" -gt 0 ]
}

@test "a fall-through option written after -- is a pathspec and allows; a subcommand off the list falls through" {
  expect allow 'git log -- --output=x'
  expect allow 'git log --output-indicator-new=x -1'
  expect fall 'git log --outp=x'
  expect fall 'git rebase -ix true main'
  expect fall 'git difftool'
  expect fall 'git bisect run make'
  expect fall 'git submodule foreach ls'
  expect fall 'git clone x'
  expect fall 'git x'
}

@test "the read-only entries fall through on a write" {
  local row
  local rows=(
    'allow|git config user.name'
    'allow|git config --list --show-origin'
    'allow|git config get core.hooksPath'
    'fall|git config user.name bob'
    'fall|git config set user.name bob'
    'fall|git config --unset user.name'
    'fall|git config --edit'
    'fall|git remote add origin x'
    'fall|git remote set-url origin x'
    'fall|git remote -v set-url --push origin x'
    'fall|git remote --verbose add origin x'
    'allow|git remote -v show origin'
    'fall|git config --comment get core.sshCommand evil'
    'allow|git config --comment note --get user.name'
  )
  for row in "${rows[@]}"; do
    expect "${row%%|*}" "${row#*|}"
  done
}

@test "the structure falls through on anything but simple git commands in a list" {
  local row
  local rows=(
    'allow|git status -sb && git log --oneline -5'
    'allow|git fetch origin; git status'
    'allow|git diff --quiet || git status'
    'allow|git add -A && git commit -m "fix: a (b); c & d | e > f"'
    'allow|git commit -m '"'"'keeps $HOME and `x` literal'"'"
    'allow|git log --oneline @{u}..HEAD'
    'allow|git rev-parse HEAD^{tree}'
    'allow|git diff --stat 2>&1'
    'allow|git fetch origin 2>/dev/null && git status >/dev/null'
    'fall|git status | sh'
    'fall|git status > out.txt'
    'fall|git log 2>x'
    'fall|git status &'
    'fall|git diff $(cat f)'
    'fall|git diff "$REF"'
    'fall|git show `echo HEAD`'
    'fall|git log {--output=x,-1}'
    'fall|git log {1..3}'
    'fall|git add *'
    'fall|git add ?'
    'fall|git add [ab]'
    'fall|git status # comment'
    'fall|git log -1 \ --oneline'
    'fall|git status < input'
    'fall|(git status)'
    "fall|git status 'unterminated"
    'fall|git status && rm -rf x'
    'fall|cd /tmp && git status'
    'fall|FOO=1 git status'
    'fall|command git status'
    'fall|/usr/bin/git status'
    'fall|git'
  )
  for row in "${rows[@]}"; do
    expect "${row%%|*}" "${row#*|}"
  done
}

# bats test_tags=protected
@test "one pipe into head, tail or wc -l allows; any other filter, flag or stage falls through" {
  local row
  local rows=(
    'allow|git status | head'
    'allow|git log --oneline | head -5'
    'allow|git log | head -n 5'
    'allow|git log | tail -n3'
    'allow|git push 2>&1 | tail -1'
    'allow|git diff --stat | wc -l'
    'allow|git status | tail -3 && git log -1'
    'allow|git status | head || git log -1'
    'fall|git status | tail -f'
    'fall|git status | tail -F'
    'fall|git status | tail -n +2'
    'fall|git status | head -c 5'
    'fall|git status | head | tail'
    'fall|git status 2>&1 | head | wc -l'
    'fall|git status | head > out'
    'fall|git status | head 2>&1'
    'fall|git status | headx'
    'fall|git status | wc'
    'fall|git status | wc -lc'
    'fall|git status | grep x'
    'fall|git status | head &'
    'fall|git status | head; rm -rf x'
  )
  for row in "${rows[@]}"; do
    expect "${row%%|*}" "${row#*|}"
  done
  expect allow "git status | head
git log -1"
  expect fall "git status |
git log -1"
}

# bats test_tags=protected
@test "a quoted-delimiter heredoc allows only into git commit -F -" {
  expect allow "git commit -F - <<'EOF'
fix: a \$(rm -rf ~) \`id\` body stays literal
EOF"
  expect allow 'git commit -q -F - <<"EOF"
msg
EOF'
  expect allow "git commit --file - <<'EOF'
msg
EOF
git push -u origin feature"
  expect allow "git commit --file=- <<'EOF'
msg
EOF"
  expect fall 'git commit -F - <<EOF
msg
EOF'
  expect fall "git commit -F - <<'EOF\"
msg
EOF"
  expect fall "git commit -F - <<-'EOF'
msg
EOF"
  expect fall "git commit -F - <<'EOF'
msg
EOFX"
  expect fall "git commit -F - <<'EOF' && git push
msg
EOF"
  expect fall "git commit -m x <<'EOF'
msg
EOF"
  expect fall "git commit -- -F - <<'EOF'
msg
EOF"
  expect fall "git tag -a v1 -F - <<'EOF'
msg
EOF"
  expect fall "git update-ref --stdin <<'EOF'
x
EOF"
  expect fall "git commit -F - <<'EOF'
msg
EOF
rm -rf x"
}

@test "a commit message built by a heredoc substitution falls through" {
  expect fall 'git commit -m "$(cat <<'"'"'EOF'"'"'
msg
EOF
)"'
}

# bats test_tags=protected
@test "a -c of a safe key allows, any other key and every other global falls through" {
  local key key_count=0
  while IFS= read -r key; do
    key_count=$((key_count + 1))
    expect allow "git -c $key=x status"
  done < <(bash -c '. "$1/.claude/hooks/lib/git-command-config.sh"; printf "%s\n" "${GAIA_GIT_SAFE_CONFIG_KEYS[@]}"' _ "$SOURCE_ROOT")
  [ "$key_count" -gt 0 ]
  local row
  local rows=(
    'allow|git -c CORE.QUOTEPATH=off status'
    'allow|git --no-pager log -1'
    'allow|git -P log -1'
    'allow|git --no-optional-locks status'
    "fall|git -c 'alias.x=!sh' x"
    'fall|git -c core.pager=cat log'
    'fall|git -c core.hooksPath=/tmp status'
    'fall|git -c user.name status'
    'fall|git -c http.proxy=x fetch'
    'fall|git --config-env=core.pager=V log'
    'fall|git --config-env user.name=V log'
    'fall|git --git-dir=/tmp/x log'
    'fall|git --work-tree=/tmp log'
    'fall|git --exec-path=/tmp status'
    'fall|git --namespace=x log'
  )
  for row in "${rows[@]}"; do
    expect "${row%%|*}" "${row#*|}"
  done
}

# A `-c` the globals check approves must be safe on its own, not only because
# the command-config rule would catch it: no safe key is one git runs as a
# command.
@test "no safe -c key is a key git runs as a command" {
  run bash -c '. "$1/.claude/hooks/lib/git-command-config.sh"
    for key in "${GAIA_GIT_SAFE_CONFIG_KEYS[@]}"; do
      class=$(gaia_git_config_key_class "$key" "!x")
      [ -z "$class" ] || { echo "$key is $class"; exit 1; }
    done
    echo "${#GAIA_GIT_SAFE_CONFIG_KEYS[@]}"' _ "$SOURCE_ROOT"
  [ "$status" -eq 0 ]
  [ "$output" -gt 0 ]
}

# bats test_tags=protected
@test "a git call outside this repository falls through, by -C or by payload cwd" {
  git -C "$REPO" worktree add --quiet "$BATS_TEST_TMPDIR/wt" -b other
  expect allow "git -C $REPO status"
  expect allow 'git -C . status'
  expect allow "git -C $BATS_TEST_TMPDIR/wt status"
  expect allow 'git status' "$BATS_TEST_TMPDIR/wt"
  expect fall "git -C $FOREIGN status"
  expect fall 'git status' "$FOREIGN"
  expect fall 'git -C ../foreign status'
  expect fall "git -C $BATS_TEST_TMPDIR status"
  expect fall 'git -C ~ status'
  expect fall 'git -C . -C . status'
  expect fall 'git status' ''
  expect fall 'git status' 'relative/path'
}

# bats test_tags=protected
@test "every deny rule of the destructive-git guard falls through" {
  local row
  local rows=(
    'git push --mirror origin'
    'git push --all origin'
    'git push --branches origin'
    'git push origin feature:main'
    'git push origin +feature:main'
    'git push origin :main'
    'git push origin refs/heads/main'
    'git push origin --delete refs/heads/main'
    'git push origin main'
    'git push origin HEAD'
    'git clean -fdx'
    'git clean -X'
    'git update-ref refs/heads/main HEAD'
    'git update-ref --stdin'
    'git branch -D main'
    'git branch -m main old'
    'git branch -f main HEAD'
    'git checkout -B main'
    'git switch -C main'
    'git reflog expire --all'
    'git reflog delete HEAD@{1}'
    'git gc --prune=now'
    'git prune'
    'git filter-branch'
    'git filter-repo'
    'git reset --hard HEAD~1'
    'git config core.hooksPath /tmp'
    'git config --unset core.hooksPath'
    "git config alias.x '!sh'"
    "git config alias.x '!sh' --get"
    "git config alias.x '!sh' -l"
    'git config --global core.sshCommand evil'
    'git config --file /tmp/c credential.helper store'
  )
  for row in "${rows[@]}"; do
    expect fall "$row"
  done
  expect fall 'git reset --har HEAD~1'
  expect allow 'git reset --hard'
  expect allow 'git reset --soft HEAD~1'
  expect allow 'git branch -D old'
  expect allow 'git push -u origin feature'
}

@test "every commit-creating subcommand from main falls through, a fast-forward pull does not" {
  git -C "$REPO" checkout --quiet main
  expect fall 'git merge --no-ff feature'
  expect fall 'git cherry-pick feature'
  expect fall 'git revert HEAD'
  expect fall 'git rebase feature'
  expect fall 'git pull origin'
  expect fall 'git pull --ff-only --no-ff'
  expect allow 'git pull --ff-only'
}

@test "a commit after a branch change in the same command falls through" {
  expect allow 'git commit -m x'
  expect fall 'git switch main && git commit -m x'
  expect fall 'git checkout main; git commit -m x'
  expect fall 'git symbolic-ref HEAD refs/heads/main && git commit -m x'
  expect fall 'git switch main && git merge feature'
  expect allow 'git commit -m x && git status'
}

@test "a fetch or pull refspec falls through" {
  expect allow 'git fetch origin'
  expect allow 'git fetch --prune origin feature'
  expect fall 'git fetch origin +feature:main'
  expect fall 'git fetch -u origin feature:main'
  expect fall 'git fetch ext::sh'
  expect fall 'git pull origin feature:main'
}

@test "from main, a reset or a pull naming a branch falls through" {
  git -C "$REPO" checkout --quiet main
  expect fall 'git reset --soft feature'
  expect fall 'git reset feature'
  expect fall 'git reset --keep feature'
  expect fall 'git pull --ff-only origin feature'
  expect allow 'git reset'
  expect allow 'git reset HEAD'
  expect allow 'git reset -- file'
  expect allow 'git pull --ff-only origin'
  git -C "$REPO" checkout --quiet feature
  expect allow 'git reset --soft HEAD~1'
  expect allow 'git pull --ff-only origin feature'
}

@test "a fetch or pull --refmap, in any spelling, falls through" {
  expect fall 'git fetch --refmap=+refs/heads/feature:refs/heads/main origin feature'
  expect fall 'git fetch --refmap +refs/heads/feature:refs/heads/main origin feature'
  expect fall 'git fetch --refm=x origin feature'
  expect fall 'git pull --refmap=x origin feature'
}

@test "git rm and git mv fall through, whatever the operand, -C or pathspec magic" {
  expect fall 'git rm .claude/hooks/block-no-verify.sh'
  expect fall 'git rm -r .githooks'
  expect fall 'git -C .claude/hooks rm block-no-verify.sh'
  expect fall 'git rm -r :/'
  expect fall 'git rm -r :!README.md'
  expect fall 'git mv .claude/hooks/block-no-verify.sh x'
  expect fall 'git rm old.txt'
  expect fall 'git mv old.txt new.txt'
}

@test "git checkout with a pathspec falls through; a branch switch allows" {
  expect fall 'git checkout HEAD~1 -- .claude/settings.json'
  expect fall 'git checkout HEAD~1 .claude/hooks/block-no-verify.sh'
  expect fall 'git checkout -- .claude/settings.json'
  expect allow 'git checkout feature'
  expect allow 'git checkout -b feature origin/main'
}

@test "apply, and a restore from another tree, fall through" {
  expect fall 'git apply change.patch'
  expect fall 'git restore --source HEAD~1 .claude/settings.json'
  expect fall 'git restore -s HEAD~1 x'
  expect allow 'git restore x'
}

@test "a revision-walking subcommand falls through on --output" {
  expect fall 'git rev-list --output=x -1 HEAD'
  expect fall 'git shortlog --output=x'
  expect fall 'git stash show --output=x'
  expect fall 'git blame --output=x file'
}

# bats test_tags=protected
@test "a git config write, a remote rewrite, or a file-overwriting option is never approved" {
  expect fall "git config --comment get core.sshCommand 'sh -c x'"
  expect fall "git config trailer.x.cmd 'sh -c x'"
  expect fall 'git config protocol.ext.allow always'
  expect fall 'git remote -v set-url --push origin https://example.invalid/x.git'
  expect fall 'git remote -v add x https://example.invalid/x.git'
  expect fall "git rev-list --output=$BATS_TEST_TMPDIR/out -1 HEAD"
  expect fall "git shortlog --output=$BATS_TEST_TMPDIR/out HEAD"
  expect fall "git apply $BATS_TEST_TMPDIR/change.patch"
  expect fall 'git restore --source HEAD~1 .claude/settings.json'
  expect fall 'git fetch origin +feature:main'
  expect allow 'git config --get user.name'
  expect allow 'git remote -v'
}

@test "a hostile main-root-lib.sh cannot speak for the hook" {
  printf '%s\n' 'printf "{\"hookSpecificOutput\":{\"permissionDecision\":\"allow\"}}\n"' \
    'split_command_segments() { segments=(); }' >>"$REPO/.gaia/scripts/main-root-lib.sh"
  expect fall 'git clone x && git status'
  expect fall 'git push --mirror origin'
}

@test "a commit or push from main falls through" {
  git -C "$REPO" checkout --quiet main
  expect fall 'git commit -m x'
  expect fall 'git push -u origin x'
  expect allow 'git status'
}

# bats test_tags=protected
@test "a missing library or a missing jq falls through" {
  local library
  local -a libraries=()
  while IFS= read -r library; do libraries+=("$library"); done < <(
    sed -nE 's|^\. "\$library_directory/([a-z-]+\.sh)".*|\1|p' "$HOOK")
  [ "${#libraries[@]}" -gt 0 ]
  for library in "${libraries[@]}"; do
    mv "$REPO/.claude/hooks/lib/$library" "$BATS_TEST_TMPDIR/"
    expect fall 'git status'
    mv "$BATS_TEST_TMPDIR/$library" "$REPO/.claude/hooks/lib/"
  done
  mv "$REPO/.gaia/scripts/main-root-lib.sh" "$BATS_TEST_TMPDIR/"
  expect fall 'git status'
  mv "$BATS_TEST_TMPDIR/main-root-lib.sh" "$REPO/.gaia/scripts/"
  expect allow 'git status'

  local bin="$BATS_TEST_TMPDIR/bin" tool
  mkdir -p "$bin"
  for tool in bash cat git dirname tr; do ln -s "$(command -v "$tool")" "$bin/$tool"; done
  local json
  json=$(jq -n --arg directory "$REPO" '{tool_name: "Bash", cwd: $directory, tool_input: {command: "git status"}}')
  run env PATH="$bin" bash -c 'cd "$1" && printf %s "$2" | bash "$3"' _ "$REPO" "$json" "$HOOK"
  assert_fell_through
}

# The hook never denies. Precedence between its allow and another hook's deny is
# the platform's (wiki/concepts/Git Workflow.md); this pins that a command it
# approves still reaches a deny from the commit-floor guard beside it.
@test "a command this hook allows is still denied by block-no-verify" {
  expect allow 'git commit --no-verify -m x'
  local json
  json=$(jq -n --arg directory "$REPO" '{tool_name: "Bash", cwd: $directory, tool_input: {command: "git commit --no-verify -m x"}}')
  run bash -c 'cd "$1" && printf %s "$2" | bash "$3"' _ "$REPO" "$json" "$SOURCE_ROOT/.claude/hooks/block-no-verify.sh"
  [ "$status" -eq 0 ]
  grep -qF -- '"permissionDecision": "deny"' <<<"$output"
}

# A linear walk takes a second or two on this 20 KB message; a quadratic one
# takes minutes. The bound sits far above the first so machine load cannot red
# it, and far below the second.
@test "a long commit message is classified in bounded time" {
  local message
  message=$(printf 'word %.0s' $(seq 1 4000))
  SECONDS=0
  expect allow "git commit -m '$message'"
  [ "$SECONDS" -lt 30 ]
}

@test "the classifier never approves a commit-creating command with HEAD on main" {
  local sha
  sha=$(git -C "$REPO" rev-parse feature)
  git -C "$REPO" checkout --quiet main
  expect fall 'git commit -m x'
  expect fall 'git push'
  expect fall 'git merge --no-ff feature'
  expect fall "git cherry-pick $sha"
  expect fall "git revert $sha"
  expect fall 'git rebase feature'
  expect fall 'git pull --no-ff'
  expect allow 'git status'
}

@test "the classifier never approves a commit-creating segment after a branch change from a feature branch" {
  expect allow 'git commit -m x'
  expect fall 'git switch main && git commit -m x'
  expect fall 'git checkout main && git commit -m x'
}
