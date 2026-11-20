#!/usr/bin/env bats
# Tests for .gaia/scripts/toolchain-check.sh and the floors file it reads.
#
# Every tool the check reads is a stub on an otherwise empty PATH, so each
# version and each absence is exact, and the script is proved to need nothing
# but bash. A machine with no jq has to be able to run it.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

bats_require_minimum_version 1.5.0

setup() {
  THIS_DIRECTORY="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
  REPO_ROOT="$(cd "$THIS_DIRECTORY/../../.." && pwd)"
  CHECK="$REPO_ROOT/.gaia/scripts/toolchain-check.sh"
  FLOORS="$REPO_ROOT/.gaia/toolchain-floors.tsv"
  NOTE="$REPO_ROOT/.gaia/migrations/2.4.0.md"
  STUBS="$(mktemp -d -t toolchain-check-XXXXXX)"
  ABSOLUTE_BASH_PATH="$(command -v bash)"
}

teardown() {
  [ -n "${STUBS:-}" ] && [ -d "$STUBS" ] && rm -rf "$STUBS"
  return 0
}

# stub <tool> <line printed for --version>
stub() {
  printf '#!%s\nprintf "%%s\\n" "%s"\n' "$ABSOLUTE_BASH_PATH" "$2" >"$STUBS/$1"
  chmod +x "$STUBS/$1"
}

stub_current() {
  stub git 'git version 2.56.0'
  stub jq 'jq-1.7.1-apple'
  stub node 'v26.13.1'
  stub pnpm '12.11.2'
  stub lsof 'lsof 4.91'
  stub ss 'ss utility, iproute2-6.1.0'
}

check() {
  run env -i PATH="$STUBS" "$ABSOLUTE_BASH_PATH" "$CHECK" "$@"
}

floor_of() {
  awk -F '\t' -v tool="$1" '$1 == tool { print $2 }' "$FLOORS"
}

@test "at or above every floor: exit 0, no guidance" {
  stub_current
  check --platform darwin
  [ "$status" -eq 0 ]
  [[ "$output" == *"OK git 2.56.0"* ]]
  [[ "$output" != *"GUIDE"* ]]
}

# reset_stubs: every tool back to a passing version, nothing else on PATH.
reset_stubs() {
  rm -rf "$STUBS"
  mkdir -p "$STUBS"
  stub_current
}

# has_text <case> <text>: $output holds the text, or the case is named.
has_text() {
  case "$output" in *"$2"*) return 0 ;; esac
  echo "case $1: output lacks [$2]" >&2
  return 1
}

# has_line <case> <line>: $output holds the exact line, or the case is named.
has_line() {
  printf '%s\n' "$output" | grep -qxF -- "$2" || { echo "case $1: no line [$2]" >&2; return 1; }
}

@test "version compare: exactly at floor, numeric (2.100 > 2.40), vendor suffix all pass" {
  local case_name git_line
  for case_name in at-floor numeric vendor-suffix; do
    reset_stubs
    case "$case_name" in
      at-floor) git_line="git version $(floor_of git)" ;;
      numeric) git_line='git version 2.100.1' ;;
      vendor-suffix) git_line='git version 2.50.1 (Apple Git-155)' ;;
    esac
    stub git "$git_line"
    check --platform darwin
    [ "$status" -eq 0 ] || { echo "case $case_name: status $status" >&2; return 1; }
    if [ "$case_name" = "vendor-suffix" ]; then
      has_text "$case_name" "OK git 2.50.1" || return 1
    fi
  done
}

@test "a tool short of its floor blocks: git, pnpm, absent jq, lsof missing, unreadable version" {
  reset_stubs
  stub git 'git version 2.39.5'
  check --platform linux --os-id debian
  [ "$status" -eq 1 ] || { echo "case git below: status $status" >&2; return 1; }
  has_line "git below" "BELOW git 2.39.5 $(floor_of git)" || return 1
  has_text "git below" "Update to the latest git" || return 1
  has_text "git below" "apt stays behind" || return 1
  has_text "git below" "brew install git" || return 1

  reset_stubs
  stub pnpm '11.2.0'
  rm "$STUBS/jq"
  check --platform darwin
  [ "$status" -eq 1 ] || { echo "case pnpm below and jq absent: status $status" >&2; return 1; }
  has_line "pnpm below" "BELOW pnpm 11.2.0 $(floor_of pnpm)" || return 1
  has_line "jq absent" "MISSING jq $(floor_of jq)" || return 1
  has_text "pnpm below" "npm install -g pnpm@latest" || return 1

  reset_stubs
  rm "$STUBS/lsof"
  check --platform darwin
  [ "$status" -eq 1 ] || { echo "case lsof missing: status $status" >&2; return 1; }
  has_line "lsof missing" "MISSING lsof -" || return 1
  has_text "lsof missing" "dev-smoke" || return 1

  reset_stubs
  stub jq 'not a version'
  check --platform darwin
  [ "$status" -eq 1 ] || { echo "case unreadable version: status $status" >&2; return 1; }
  has_text "unreadable version" "BELOW jq unknown" || return 1
}

@test "a platform tool is checked only on its platform" {
  stub_current
  rm "$STUBS/ss"
  check --platform darwin
  [ "$status" -eq 0 ]
  stub ss 'ss'
  rm "$STUBS/lsof"
  check --platform linux --os-id debian
  [ "$status" -eq 0 ]
  rm "$STUBS/ss"
  check --platform linux --os-id debian
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -qxF "MISSING ss -"
  [[ "$output" == *"iproute2"* ]]
  [[ "$output" == *"dev-smoke"* ]]
}

@test "--scope user leaves out what GAIA installs itself, so a fresh clone with no pnpm passes" {
  stub_current
  rm "$STUBS/pnpm"
  check --platform darwin --scope user
  [ "$status" -eq 0 ]
  [[ "$output" != *"pnpm"* ]]
}

@test "--tool reads one tool only" {
  stub_current
  stub git 'git version 2.10.0'
  check --platform darwin --tool pnpm
  [ "$status" -eq 0 ]
  [[ "$output" == "OK pnpm 12.11.2 $(floor_of pnpm)" ]]
}

@test "the floor is read from the file, so a target bundle's newer floor governs" {
  stub_current
  printf 'git\t3.0\tany\tuser\n' >"$STUBS/floors.tsv"
  check --platform darwin --floors "$STUBS/floors.tsv"
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -qxF "BELOW git 2.56.0 3.0"
}

@test "a target bundle's copy runs with the Node helpers the release ships beside it" {
  grep -qF '".gaia/scripts/toolchain-node-lib.sh": "owned"' "$REPO_ROOT/.gaia/manifest.json"
  local bundle="$BATS_TEST_TMPDIR/bundle" major
  mkdir -p "$bundle/.gaia/scripts"
  cp "$CHECK" "$REPO_ROOT/.gaia/scripts/toolchain-node-lib.sh" "$bundle/.gaia/scripts/"
  cp "$FLOORS" "$bundle/.gaia/"
  stub_current
  stub node 'v24.11.0'
  stub fnm 'fnm 1.38.1'
  major="$(floor_of node)"
  run env -i PATH="$STUBS" "$ABSOLUTE_BASH_PATH" "$bundle/.gaia/scripts/toolchain-check.sh" --platform darwin
  [ "$status" -eq 1 ]
  [[ "$(printf '%s\n' "$output" | grep '^ROUTE node ')" == "ROUTE node terminal fnm install $major && "* ]]
}

@test "a missing floors file and an unknown argument are refusals" {
  check --floors "$STUBS/absent.tsv"
  [ "$status" -eq 2 ]
  check --nonsense
  [ "$status" -eq 2 ]
}

# route_line <tool>: the one ROUTE line for that tool in $output, or nothing.
route_line() {
  printf '%s\n' "$output" | grep "^ROUTE $1 " || true
}

# route_is <case> <tool> <exact line>: the tool's ROUTE line is exactly that.
route_is() {
  local got
  got="$(route_line "$2")"
  [ "$got" = "$3" ] || { echo "case $1: route $2 is [$got], want [$3]" >&2; return 1; }
}

# route_like <case> <tool> <glob>: the tool's ROUTE line matches the glob.
route_like() {
  local got
  got="$(route_line "$2")"
  # shellcheck disable=SC2254
  case "$got" in $3) return 0 ;; esac
  echo "case $1: route $2 is [$got], want [$3]" >&2
  return 1
}

# route_absent <case> <tool>: no ROUTE line for the tool.
route_absent() {
  [ -z "$(route_line "$2")" ] || { echo "case $1: unexpected route for $2" >&2; return 1; }
}

@test "ROUTE and GUIDE lines per platform family and tool (run, user, terminal, none)" {
  local family platform route_count

  # every git route names a package source, on every platform family
  reset_stubs
  stub git 'git version 2.39.5'
  for family in 'darwin' 'windows' 'linux ubuntu' 'linux debian' 'linux fedora' 'linux rhel' 'linux arch' 'linux alpine' 'linux gentoo'; do
    # shellcheck disable=SC2086
    set -- $family
    if [ "$#" -eq 2 ]; then check --platform "$1" --os-id "$2"; else check --platform "$1"; fi
    has_text "git route $family" "GUIDE git: " || return 1
    has_text "git route $family" "latest git" || return 1
  done

  # ROUTE run: on macOS with Homebrew, Claude can run the install itself
  reset_stubs
  stub brew 'Homebrew 4.6.0'
  stub git 'git version 2.39.5'
  rm "$STUBS/lsof"
  check --platform darwin
  [ "$status" -eq 1 ] || { echo "case run macOS: status $status" >&2; return 1; }
  route_is "run macOS" git "ROUTE git run brew install git" || return 1
  route_absent "run macOS" lsof || return 1
  grep -qF -- "GUIDE lsof: Install" <<<"$output" && { echo "case run macOS: lsof guide offers an install" >&2; return 1; }
  has_text "run macOS" "GUIDE lsof: " || return 1
  has_text "run macOS" "/usr/sbin" || return 1

  # ROUTE terminal: without Homebrew, installing it needs the user's own terminal
  reset_stubs
  stub git 'git version 2.39.5'
  check --platform darwin
  route_like "terminal no Homebrew darwin" git 'ROUTE git terminal *Homebrew/install*' || return 1
  check --platform linux --os-id debian
  route_like "terminal no Homebrew debian" git 'ROUTE git terminal *Homebrew/install*' || return 1

  # ROUTE terminal: winget on Windows, whose PATH change only a new shell sees
  reset_stubs
  stub git 'git version 2.39.5'
  rm "$STUBS/jq"
  check --platform windows
  route_is "terminal winget" git "ROUTE git terminal winget install --id Git.Git -e" || return 1
  route_is "terminal winget" jq "ROUTE jq terminal winget install --id jqlang.jq -e" || return 1

  # ROUTE user: a sudo route is handed to the user, never run by Claude
  reset_stubs
  stub git 'git version 2.39.5'
  check --platform linux --os-id ubuntu
  route_is "user ubuntu" git "ROUTE git user sudo add-apt-repository -y ppa:git-core/ppa && sudo apt-get update && sudo apt-get install -y git" || return 1
  check --platform linux --os-id fedora
  route_is "user fedora" git "ROUTE git user sudo dnf upgrade --refresh -y git" || return 1
  reset_stubs
  rm "$STUBS/ss"
  check --platform linux --os-id debian
  route_is "user debian ss" ss "ROUTE ss user sudo apt-get install -y iproute2" || return 1

  # ROUTE run on Linux with Homebrew, and pnpm through npm
  reset_stubs
  stub brew 'Homebrew 4.6.0'
  rm "$STUBS/jq"
  stub pnpm '11.2.0'
  check --platform linux --os-id debian
  route_is "run Linux brew" jq "ROUTE jq run brew install jq" || return 1
  route_like "run Linux pnpm" pnpm 'ROUTE pnpm run *npm install -g pnpm@latest' || return 1

  # no ROUTE line without an exact command, and none for a passing tool
  reset_stubs
  rm "$STUBS/ss"
  check --platform linux --os-id gentoo
  [ "$status" -eq 1 ] || { echo "case no exact command: status $status" >&2; return 1; }
  route_absent "no exact command" ss || return 1
  has_text "no exact command" "GUIDE ss: " || return 1
  route_absent "passing tool" git || return 1

  # every ROUTE line names a short tool and a class of run, user or terminal
  reset_stubs
  stub git 'git version 2.39.5'
  rm "$STUBS/jq"
  for platform in 'darwin' 'windows' 'linux ubuntu' 'linux debian' 'linux fedora' 'linux arch' 'linux alpine' 'linux rhel'; do
    # shellcheck disable=SC2086
    set -- $platform
    if [ "$#" -eq 2 ]; then check --platform "$1" --os-id "$2"; else check --platform "$1"; fi
    route_count="$(printf '%s\n' "$output" | grep -c '^ROUTE ' || true)"
    [ "$route_count" -eq 2 ] || { echo "case shape $platform: $route_count ROUTE lines" >&2; return 1; }
    printf '%s\n' "$output" | grep '^ROUTE ' | grep -vE '^ROUTE (git|jq) (run|user|terminal) .+' && { echo "case shape $platform: malformed ROUTE line" >&2; return 1; }
  done
  true
}

@test "Node 24 is below the floor: it blocks, and with no version manager the guide alone names the install and the pnpm reinstall" {
  stub_current
  stub node 'v24.11.0'
  check --platform darwin
  [ "$status" -eq 1 ]
  printf '%s\n' "$output" | grep -qxF "BELOW node 24.11.0 $(floor_of node)"
  local major
  major="$(floor_of node)"
  [[ "$output" == *"GUIDE node: Install Node $major with nvm or fnm: run nvm install $major, nvm use $major and nvm alias default $major, or fnm install $major, fnm use $major and fnm default $major"*"npm install -g pnpm@latest"*"fresh terminal in the project folder"*"select Node $major there"*"Then start Claude Code"*"GAIA's CLI run on it."* ]] || return 1
  [ -z "$(route_line node)" ]
}

@test "the per-folder switcher advice holds for asdf and mise: it says to select the floor's Node there, never an fnm or nvm command" {
  stub_current
  stub node 'v24.11.0'
  stub fnm 'fnm 1.38.1'
  local major platform
  major="$(floor_of node)"
  for platform in darwin windows; do
    check --platform "$platform"
    [[ "$output" == *"(fnm --use-on-cd, nvm auto-use, asdf, mise), select Node $major there, or the old pin is reselected"* ]] || return 1
    grep '^GUIDE node:' <<<"$output" | grep -qE '(fnm|nvm) use [0-9]+ there' && return 1
  done
  true
}

@test "with no version manager to run the guide's commands, the node guide says to install one first or get Node another way" {
  stub_current
  stub node 'v24.11.0'
  local major
  major="$(floor_of node)"
  check --platform darwin
  [[ "$output" == *"GUIDE node: "*"Neither nvm nor fnm is installed here, so install one of them first, or install Node $major another way and make it your default."* ]] || return 1
  check --platform windows
  [[ "$output" == *"GUIDE node: "*"fnm is not installed here, so install it first, or install Node $major another way and make it your default."* ]] || return 1
  stub fnm 'fnm 1.38.1'
  check --platform darwin
  grep '^GUIDE node:' <<<"$output" | grep -qE 'is not installed here|is installed here' && return 1
  mkdir -p "$STUBS/nvm"
  printf 'x\n' >"$STUBS/nvm/nvm.sh"
  rm "$STUBS/fnm"
  run env -i PATH="$STUBS" NVM_DIR="$STUBS/nvm" "$ABSOLUTE_BASH_PATH" "$CHECK" --platform darwin
  grep '^GUIDE node:' <<<"$output" | grep -qE 'is not installed here|is installed here' && return 1
  rm -r "$STUBS/nvm"
  mkdir -p "$STUBS/brew/opt/nvm" "$STUBS/home"
  printf 'x\n' >"$STUBS/brew/opt/nvm/nvm.sh"
  run env -i PATH="$STUBS" HOME="$STUBS/home" HOMEBREW_PREFIX="$STUBS/brew" "$ABSOLUTE_BASH_PATH" "$CHECK" --platform darwin
  grep '^GUIDE node:' <<<"$output" | grep -qE 'is not installed here|is installed here' && return 1
  true
}

@test "ROUTE terminal for node through fnm or nvm, reinstalling pnpm with the pnpm route's own command, and none on Windows" {
  stub_current
  stub pnpm '11.2.0'
  stub node 'v24.11.0'
  mkdir -p "$STUBS/nvm"
  printf 'x\n' >"$STUBS/nvm/nvm.sh"
  run env -i PATH="$STUBS" NVM_DIR="$STUBS/nvm" "$ABSOLUTE_BASH_PATH" "$CHECK" --platform darwin
  local pnpm_command major
  major="$(floor_of node)"
  pnpm_command="$(route_line pnpm)"
  pnpm_command="${pnpm_command#ROUTE pnpm run }"
  [ -n "$pnpm_command" ]
  [ "$(route_line node)" = "ROUTE node terminal nvm install $major && nvm use $major && nvm alias default $major && { $pnpm_command; }" ]
  stub fnm 'fnm 1.38.1'
  run env -i PATH="$STUBS" NVM_DIR="$STUBS/nvm" "$ABSOLUTE_BASH_PATH" "$CHECK" --platform linux --os-id debian
  [ "$(route_line node)" = "ROUTE node terminal fnm install $major && fnm use $major && fnm default $major && { $pnpm_command; }" ]
  check --platform windows
  [ "$status" -eq 1 ]
  [ -z "$(route_line node)" ]
  [[ "$output" == *"GUIDE node: Install Node $major with fnm: run fnm install $major"*"fresh terminal"* ]] || return 1
  grep '^GUIDE node:' <<<"$output" | grep -qE 'nvm (install|use|alias)' && return 1
  true
}

@test "no guidance pins a version: each route reaches latest, and node alone names its floor major" {
  run grep -inE '(git|jq|node|pnpm)@?[ -]?v?[0-9]+([^0-9>]|$)' "$CHECK"
  [ "$status" -ne 0 ]
  stub_current
  stub node 'v24.11.0'
  stub git 'git version 2.39.5'
  stub jq 'jq-1.5'
  stub pnpm '11.2.0'
  local platform guide_text major
  major="$(floor_of node)"
  for platform in darwin windows; do
    check --platform "$platform"
    guide_text="$(printf '%s\n' "$output" | grep '^GUIDE ')"
    [ "$(printf '%s\n' "$guide_text" | grep -c '^GUIDE ')" -ge 4 ]
    printf '%s\n' "$guide_text" | grep '^GUIDE node:' | grep -qF "Install Node $major with" || return 1
    printf '%s\n' "$guide_text" | grep -v '^GUIDE node:' | grep -qE '[0-9]+(\.[0-9]+)?' && return 1
    printf '%s\n' "$guide_text" | grep '^GUIDE node:' | sed "s/Node $major /Node /g; s/install $major/install/" | grep -qiE '(node|v|@)[ ]?[0-9]+|[0-9]+\.[0-9]+\.[0-9]+' && return 1
  done
  true
}

@test "the floors file has one row per tool, and the note states the same floors" {
  run awk -F '\t' '!/^#/ && NF != 4 { print }' "$FLOORS"
  [ -z "$output" ]
  run awk -F '\t' '!/^#/ && NF { n++ } END { print n + 0 }' "$FLOORS"
  [ "$output" -gt 0 ]
  grep -qiw 'warn' "$NOTE" && return 1
  grep -q "git $(floor_of git)" "$NOTE"
  grep -q "jq $(floor_of jq)" "$NOTE"
  grep -q "node $(floor_of node)" "$NOTE"
  grep -q "pnpm $(floor_of pnpm)" "$NOTE"
}

# bats test_tags=whole-tree
@test "a 2.3.x project crosses the 2.4.0 note, and it is blocking" {
  run --separate-stderr bash "$REPO_ROOT/.gaia/scripts/select-migration-notes.sh" "$REPO_ROOT" 2.3.1 2.4.0
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf '2.4.0\tblocking\t%s/.gaia/migrations/2.4.0.md' "$REPO_ROOT")" ]
}

# bats test_tags=whole-tree
@test "a project at 2.4.0 selects no 2.4.0 note, so a re-run after the crossing is clean" {
  run --separate-stderr bash "$REPO_ROOT/.gaia/scripts/select-migration-notes.sh" "$REPO_ROOT" 2.4.0 2.4.0
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run --separate-stderr bash "$REPO_ROOT/.gaia/scripts/select-migration-notes.sh" "$REPO_ROOT" 2.4.0 2.99.0
  [ "$status" -eq 0 ]
  [ "${output#*2.4.0.md}" = "$output" ]
}

@test "the note owns its hop: on a pass it runs the ordinary walk inline through the version and manifest write" {
  grep -qF 'Run the ordinary three-way walk to `<target>`, through `.gaia/VERSION` and the manifest write at `<target>`' "$NOTE"
  grep -qF 'Run the walk inline in this session' "$NOTE"
}

# later_bundle <mode>: a target bundle above 2.4.0, carrying the shipped notes
# and the selector plus a 2.5.0 note in the given mode.
later_bundle() {
  LATER="$BATS_TEST_TMPDIR/later"
  mkdir -p "$LATER/.gaia/scripts/lib" "$LATER/.gaia/migrations"
  cp "$REPO_ROOT"/.gaia/migrations/*.md "$LATER/.gaia/migrations/"
  cp "$REPO_ROOT/.gaia/scripts/select-migration-notes.sh" "$LATER/.gaia/scripts/"
  cp "$REPO_ROOT/.gaia/scripts/lib/version-compare.awk" "$LATER/.gaia/scripts/lib/"
  printf -- '---\nmode: %s\n---\n\nbody\n' "$1" >"$LATER/.gaia/migrations/2.5.0.md"
}

@test "a run from below 2.4.0 to a later target reaches a later after-merge note only through the note's selection from 2.4.0" {
  later_bundle after-merge
  run --separate-stderr bash "$REPO_ROOT/.gaia/scripts/update-gaia-preflight.sh" select-notes --latest-dir "$LATER" --baseline 2.3.1 --latest 2.5.0
  [ "$status" -eq 0 ]
  [ "$output" = "BLOCKING 2.4.0 $LATER/.gaia/migrations/2.4.0.md" ]
  run --separate-stderr bash "$REPO_ROOT/.gaia/scripts/update-gaia-preflight.sh" select-notes --latest-dir "$LATER" --baseline 2.4.0 --latest 2.5.0
  [ "$status" -eq 0 ]
  [ "$output" = "AFTER_MERGE 2.5.0 $LATER/.gaia/migrations/2.5.0.md" ]
  grep -qF 'select-notes --latest-dir <bundle folder> --baseline 2.4.0 --latest <target>' "$NOTE"
  grep -qF 'Persist the `AFTER_MERGE` lines' "$NOTE"
}

@test "a later blocking note surfaces in that selection, and the note stops before any merge on it" {
  later_bundle blocking
  run --separate-stderr bash "$REPO_ROOT/.gaia/scripts/update-gaia-preflight.sh" select-notes --latest-dir "$LATER" --baseline 2.4.0 --latest 2.5.0
  [ "$status" -eq 0 ]
  [ "$output" = "BLOCKING 2.5.0 $LATER/.gaia/migrations/2.5.0.md" ]
  grep -qF 'A `BLOCKING` line from it: stop before any merge' "$NOTE"
}

# bats test_tags=whole-tree
@test "no shipped note above 2.4.0 is blocking: the 2.4.0 note's hop stops at one" {
  local note version highest offenders=""
  for note in "$REPO_ROOT"/.gaia/migrations/*.md; do
    version="${note##*/}"
    version="${version%.md}"
    highest="$(printf '%s\n%s\n' 2.4.0 "$version" | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1)"
    if [ "$version" != 2.4.0 ] && [ "$highest" = "$version" ] && [ "$(sed -n 2p "$note")" = "mode: blocking" ]; then
      offenders="$offenders $version"
    fi
  done
  if [ -n "$offenders" ]; then
    printf 'Blocking note(s) above 2.4.0:%s. Extend the hop in .gaia/migrations/2.4.0.md to run them, in the same PR, then update this test.\n' "$offenders"
    return 1
  fi
}

@test "the setup and init commands hold no literal floor" {
  run grep -nE 'pnpm 1[0-9]|git 2\.[0-9]+|jq 1\.[0-9]' \
    "$REPO_ROOT/.claude/commands/setup-gaia.md" \
    "$REPO_ROOT/.claude/commands/gaia-init.md" \
    "$REPO_ROOT/.claude/skills/gaia/references/toolchain.md"
  [ "$status" -ne 0 ]
}

@test "no jq filter binds a reserved word, which jq 1.6 refuses to parse" {
  run grep -rnE --include='*.sh' --exclude-dir=fixtures \
    '( as |def [a-z_]+\([^)]*)\$(end|if|then|else|elif|and|or|not|def|reduce|foreach|try|catch|label|import|include)\b' \
    "$REPO_ROOT/.gaia/scripts" "$REPO_ROOT/.claude/hooks"
  [ "$status" -ne 0 ]
}

@test "no jq object uses a reserved word as a shorthand key, which jq 1.6 refuses to parse" {
  run grep -rnE --include='*.sh' --exclude-dir=fixtures \
    '\{(end|if|then|else|elif|and|or|not|def|reduce|foreach|try|catch|label|import|include), ' \
    "$REPO_ROOT/.gaia/scripts" "$REPO_ROOT/.claude/hooks"
  [ "$status" -ne 0 ]
}
