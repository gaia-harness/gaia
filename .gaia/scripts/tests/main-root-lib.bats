#!/usr/bin/env bats
#
# Conformance suite for .gaia/scripts/main-root-lib.sh, the shared
# main-checkout resolver (SPEC-058 task 2.2). Builds a committed fixture
# harness for every checkout shape git can answer for -- ordinary clone,
# submodule, and separate-git-dir, each with and without a linked worktree --
# plus a symlinked checkout and a battery of adversarial inputs, and asserts
# the resolver's output form, failure diagnostic, and predicate hold in every
# one.
#
# Run under bash 5 (bash 3.2's `[[ ]]` skip-under-set-e gap is real; see
# .claude/rules/bats-assertions.md): `source .gaia/scripts/bats5.sh && bats5
# .gaia/scripts/tests/main-root-lib.bats`.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.
#
# Submodule fixtures need `protocol.file.allow=always` for `submodule add`
# against a local-path origin (recent git defaults this narrower); it is
# passed per-invocation via `-c` rather than mutated into any config file.

setup() {
  LIBRARY_SCRIPT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/main-root-lib.sh"
  CLEANUP_DIRECTORIES=()
}

teardown() {
  if [ "${#CLEANUP_DIRECTORIES[@]}" -gt 0 ]; then
    local cleanup_directory
    for cleanup_directory in "${CLEANUP_DIRECTORIES[@]}"; do
      [ -n "$cleanup_directory" ] && rm -rf "$cleanup_directory"
    done
  fi
  return 0
}

# ---------- fixture helpers ----------
# Every fixture root is canonicalized via `mktemp -d` then `pwd -P`: macOS
# resolves /tmp -> /private/tmp inside `git rev-parse`, and the resolver's
# output is compared against these values byte-for-byte, so a non-canonical
# tmp path would desync from what the resolver reports for reasons that have
# nothing to do with the resolver itself (mirrors block-worktree-path-mismatch
# and link-worktree.bats).

git_identity() {
  git -C "$1" config user.email gaia-test@example.com
  git -C "$1" config user.name "GAIA Test"
  git -C "$1" config commit.gpgsign false
}

# make_repo: an ordinary clone. Sets REPO.
make_repo() {
  local raw
  raw=$(mktemp -d -t gaia-mrl-repo-XXXXXX)
  REPO="$(cd "$raw" && pwd -P)"
  CLEANUP_DIRECTORIES+=("$REPO")
  git -C "$REPO" init -q --initial-branch=main
  git_identity "$REPO"
  echo init >"$REPO/f"
  git -C "$REPO" add f
  git -C "$REPO" commit -q -m init
}

# make_worktree <repo> <relative_path> <branch>: a real linked worktree under
# <repo>/.claude/worktrees/<relative_path>, mirroring how GAIA creates plan/debt
# worktrees. Sets WORKTREE to the worktree's absolute path.
make_worktree() {
  local repo="$1" relative_path="$2" branch="$3"
  git -C "$repo" branch "$branch"
  mkdir -p "$repo/.claude/worktrees"
  git -C "$repo" worktree add -q "$repo/.claude/worktrees/$relative_path" "$branch"
  WORKTREE="$repo/.claude/worktrees/$relative_path"
}

# make_submodule: a superproject with a real "gaia" submodule at
# <SUPERPROJECT>/gaia. Sets SUPERPROJECT, SUBMODULE, SUBMODULE_ORIGIN.
make_submodule() {
  local submodule_raw superproject_raw
  submodule_raw=$(mktemp -d -t gaia-mrl-subsrc-XXXXXX)
  SUBMODULE_ORIGIN="$(cd "$submodule_raw" && pwd -P)"
  CLEANUP_DIRECTORIES+=("$SUBMODULE_ORIGIN")
  git -C "$SUBMODULE_ORIGIN" init -q --initial-branch=main
  git_identity "$SUBMODULE_ORIGIN"
  echo sub >"$SUBMODULE_ORIGIN/g"
  git -C "$SUBMODULE_ORIGIN" add g
  git -C "$SUBMODULE_ORIGIN" commit -q -m init

  superproject_raw=$(mktemp -d -t gaia-mrl-super-XXXXXX)
  SUPERPROJECT="$(cd "$superproject_raw" && pwd -P)"
  CLEANUP_DIRECTORIES+=("$SUPERPROJECT")
  git -C "$SUPERPROJECT" init -q --initial-branch=main
  git_identity "$SUPERPROJECT"
  echo root >"$SUPERPROJECT/r"
  git -C "$SUPERPROJECT" add r
  git -C "$SUPERPROJECT" commit -q -m init

  git -C "$SUPERPROJECT" -c protocol.file.allow=always submodule add -q "$SUBMODULE_ORIGIN" gaia
  git -C "$SUPERPROJECT" commit -q -m "add submodule"
  SUBMODULE="$SUPERPROJECT/gaia"
}

# make_separate_gitdir: a --separate-git-dir main checkout. Sets WORK (the
# working tree), ELSEWHERE (the relocated git dir's parent), GITDIR.
make_separate_gitdir() {
  local origin_raw origin elsewhere_raw work_raw
  origin_raw=$(mktemp -d -t gaia-mrl-sepsrc-XXXXXX)
  origin="$(cd "$origin_raw" && pwd -P)"
  CLEANUP_DIRECTORIES+=("$origin")
  git -C "$origin" init -q --initial-branch=main
  git_identity "$origin"
  echo o >"$origin/o"
  git -C "$origin" add o
  git -C "$origin" commit -q -m init

  elsewhere_raw=$(mktemp -d -t gaia-mrl-elsewhere-XXXXXX)
  ELSEWHERE="$(cd "$elsewhere_raw" && pwd -P)"
  CLEANUP_DIRECTORIES+=("$ELSEWHERE")
  GITDIR="$ELSEWHERE/gaia.git"

  work_raw=$(mktemp -d -t gaia-mrl-work-XXXXXX)
  WORK="$(cd "$work_raw" && pwd -P)"
  CLEANUP_DIRECTORIES+=("$WORK")
  git clone -q --separate-git-dir="$GITDIR" "$origin" "$WORK"
  git_identity "$WORK"
}

# ---------- invocation helpers ----------

# resolve <directory>: runs the executable entry with a dir operand. bats' `run`
# merges stdout and stderr into a single `$output`, and the resolver's
# failure diagnostic is stderr-only by contract, so every invocation here
# discards the target's own stderr *inside* the inner bash -c, before bats
# ever captures anything -- an outer `2>/dev/null` on `run` itself would not
# work, since `run` internally does its own `2>&1` merge for the command
# under test regardless of the ambient fd. This makes `$output` reflect
# stdout alone, matching what these tests assert against. The diagnostic
# tests below capture stderr on its own terms with the mirror-image `2>&1
# 1>/dev/null` form.
resolve() {
  local directory="$1"
  run bash -c 'bash "$1" "$2" 2>/dev/null' _ "$LIBRARY_SCRIPT" "$directory"
}

# resolve_from <cwd> <directory>: process cwd=$1 (unrelated to $2), operand=$2.
# Quote-safe delivery: positional args to an inner bash -c rather than
# re-wrapping in an outer single-quoted string (mirrors
# block-worktree-path-mismatch.bats's run_staged_hook).
resolve_from() {
  local cwd="$1" directory="$2"
  run bash -c 'cd "$1" && bash "$2" "$3" 2>/dev/null' _ "$cwd" "$LIBRARY_SCRIPT" "$directory"
}

is_worktree() {
  local directory="$1"
  run bash -c 'bash "$1" --is-worktree "$2" 2>/dev/null' _ "$LIBRARY_SCRIPT" "$directory"
}

# resolve_tree <directory>: runs the executable entry's --tree-root operand.
# Mirrors resolve()'s stderr-discard-inside-bash-c note.
resolve_tree() {
  local directory="$1"
  run bash -c 'bash "$1" --tree-root "$2" 2>/dev/null' _ "$LIBRARY_SCRIPT" "$directory"
}

# resolve_tree_from <cwd> <directory>: process cwd=$1 (unrelated to $2), operand=$2.
# Mirrors resolve_from().
resolve_tree_from() {
  local cwd="$1" directory="$2"
  run bash -c 'cd "$1" && bash "$2" --tree-root "$3" 2>/dev/null' _ "$cwd" "$LIBRARY_SCRIPT" "$directory"
}

# The current (pre-resolver) physical derivation, matching
# .gaia/statusline/gaia-statusline.sh's own formula:
# dirname(absolute(git rev-parse --git-common-dir)), physically resolved via
# `pwd -P`. This is the differential test's oracle for SPEC-058 success
# criterion 2 / MIG-011: the statusline is one of the existing sites that
# already normalizes physically, so it is the self-consistent predecessor to
# compare against, not the sites that normalize logically.
old_derivation() {
  local directory="$1" common absolute_common
  common="$(git -C "$directory" rev-parse --git-common-dir 2>/dev/null)" || return 1
  case "$common" in
    /*) absolute_common="$common" ;;
    *) absolute_common="$directory/$common" ;;
  esac
  (cd "$(dirname "$absolute_common")" 2>/dev/null && pwd -P)
}

# ---------- resolver per checkout shape ----------

# assert_resolves <row> <directory> <expected>: the main-root resolver answers
# <expected> for <directory>, naming the row on failure.
assert_resolves() {
  local row="$1" directory="$2" expected="$3"
  resolve "$directory"
  [ "$status" -eq 0 ] || { echo "row $row: status $status"; return 1; }
  [ "$output" = "$expected" ] || { echo "row $row: got '$output', expected '$expected'"; return 1; }
}

@test "main root resolves to the right root for each checkout shape" {
  make_repo
  make_worktree "$REPO" "w" "wtbranch"
  local clone_worktree="$WORKTREE"
  make_submodule
  make_worktree "$SUBMODULE" "w" "subwtbranch"
  local submodule_worktree="$WORKTREE"
  local symlink="${REPO}-symlink"
  ln -s "$REPO" "$symlink"
  CLEANUP_DIRECTORIES+=("$symlink")

  assert_resolves "submodule main" "$SUBMODULE" "$SUBMODULE" || return 1
  assert_resolves "submodule linked worktree, not .git/modules" "$submodule_worktree" "$SUBMODULE" || return 1
  assert_resolves "clone main" "$REPO" "$REPO" || return 1
  assert_resolves "clone linked worktree" "$clone_worktree" "$REPO" || return 1
  assert_resolves "clone main vs physical derivation" "$REPO" "$(old_derivation "$REPO")" || return 1
  assert_resolves "clone worktree vs physical derivation" "$clone_worktree" "$(old_derivation "$clone_worktree")" || return 1
  assert_resolves "symlinked clone vs physical derivation" "$symlink" "$(old_derivation "$symlink")" || return 1
  assert_resolves "symlinked clone physical root" "$symlink" "$REPO" || return 1

  make_separate_gitdir
  assert_resolves "separate-git-dir main" "$WORK" "$WORK" || return 1
  [ "$WORK" != "$ELSEWHERE" ] || return 1
  [ "$WORK" != "$GITDIR" ] || return 1
}

# ---------- predicate ----------

@test "linked-worktree predicate answers per shape" {
  make_repo
  make_worktree "$REPO" "w" "wtbranch2"
  local clone_worktree="$WORKTREE"
  make_submodule
  make_worktree "$SUBMODULE" "w" "subwtbranch2"
  local submodule_worktree="$WORKTREE"
  local nongit symlink
  nongit=$(mktemp -d -t gaia-mrl-nongit-XXXXXX)
  CLEANUP_DIRECTORIES+=("$nongit")
  symlink="${REPO}-symlink2"
  ln -s "$REPO" "$symlink"
  CLEANUP_DIRECTORIES+=("$symlink")

  local row label directory expected
  for row in \
    "clone linked worktree|$clone_worktree|0" \
    "submodule linked worktree|$submodule_worktree|0" \
    "submodule main checkout|$SUBMODULE|1" \
    "clone main checkout|$REPO|1" \
    "outside any repository|$nongit|1" \
    "symlinked main checkout|$symlink|1"; do
    label=${row%%|*}
    expected=${row##*|}
    directory=${row#*|}
    directory=${directory%|*}
    is_worktree "$directory"
    [ "$status" -eq "$expected" ] || { echo "row $label: status $status"; return 1; }
    [ -z "$output" ] || { echo "row $label: printed '$output'"; return 1; }
  done
}

# ---------- dir operand ----------

@test "a supplied dir operand resolves independent of cwd and of other calls" {
  make_repo
  make_worktree "$REPO" "w" "wtbranch3"
  local clone_worktree="$WORKTREE"
  make_submodule
  mkdir -p "$REPO/sub"
  local neutral
  neutral=$(mktemp -d -t gaia-mrl-neutral-XXXXXX)
  CLEANUP_DIRECTORIES+=("$neutral")

  resolve_from "$neutral" "$REPO"
  [ "$status" -eq 0 ] || { echo "row main root from unrelated cwd: status $status"; return 1; }
  [ "$output" = "$REPO" ] || { echo "row main root from unrelated cwd: got '$output'"; return 1; }

  resolve_tree_from "$neutral" "$REPO"
  [ "$status" -eq 0 ] || { echo "row tree root from unrelated cwd: status $status"; return 1; }
  [ "$output" = "$REPO" ] || { echo "row tree root from unrelated cwd: got '$output'"; return 1; }

  resolve_key_from "$neutral" "$REPO"
  [ "$status" -eq 0 ] || { echo "row tree key from unrelated cwd: status $status"; return 1; }
  [ "$output" = "$(printf '%s' "$REPO" | shasum -a 256 | cut -c1-16)" ] || { echo "row tree key from unrelated cwd: got '$output'"; return 1; }

  run bash -c 'cd "$1" && bash "$2" --common-dir sub 2>/dev/null' _ "$REPO" "$LIBRARY_SCRIPT"
  [ "$status" -eq 0 ] || { echo "row relative common directory: status $status"; return 1; }
  [ "$output" = "$REPO/.git" ] || { echo "row relative common directory: got '$output'"; return 1; }

  run bash -c '
    cd "$1" || exit 1
    # shellcheck disable=SC1090
    source "$2"
    repository_main_root="$(gaia_resolve_main_root "$3")" || exit 10
    submodule_main_root="$(gaia_resolve_main_root "$4")" || exit 11
    repository_tree_root="$(gaia_resolve_tree_root "$3")" || exit 12
    worktree_tree_root="$(gaia_resolve_tree_root "$5")" || exit 13
    if gaia_is_linked_worktree "$5"; then worktree_answer=0; else worktree_answer=1; fi
    if gaia_is_linked_worktree "$3"; then main_checkout_answer=0; else main_checkout_answer=1; fi
    printf "%s\n%s\n%s\n%s\n%s\n%s\n" "$repository_main_root" "$submodule_main_root" "$repository_tree_root" "$worktree_tree_root" "$worktree_answer" "$main_checkout_answer"
  ' _ "$neutral" "$LIBRARY_SCRIPT" "$REPO" "$SUBMODULE" "$clone_worktree"
  [ "$status" -eq 0 ] || { echo "row two calls in one process: status $status"; return 1; }
  [ "${lines[0]}" = "$REPO" ] || { echo "row repository main root in one process: got '${lines[0]}'"; return 1; }
  [ "${lines[1]}" = "$SUBMODULE" ] || { echo "row submodule main root in one process: got '${lines[1]}'"; return 1; }
  [ "${lines[2]}" = "$REPO" ] || { echo "row repository tree root in one process: got '${lines[2]}'"; return 1; }
  [ "${lines[3]}" = "$clone_worktree" ] || { echo "row worktree tree root in one process: got '${lines[3]}'"; return 1; }
  [ "${lines[4]}" = "0" ] || { echo "row predicate on worktree in one process: got '${lines[4]}'"; return 1; }
  [ "${lines[5]}" = "1" ] || { echo "row predicate on main in one process: got '${lines[5]}'"; return 1; }
}

# ---------- adversarial ----------

@test "adversarial environment and config never override the layout-derived answer" {
  make_repo
  make_worktree "$REPO" "w" "wtbranch5"
  local other neutral common_config
  other=$(mktemp -d -t gaia-mrl-other-XXXXXX)
  CLEANUP_DIRECTORIES+=("$other")
  git -C "$other" init -q --initial-branch=main
  neutral=$(mktemp -d -t gaia-mrl-neutral3-XXXXXX)
  CLEANUP_DIRECTORIES+=("$neutral")
  common_config="$(cd "$REPO/.git" && pwd -P)/config"

  local poisoned
  for poisoned in "/nonexistent/evil/path" "$other"; do
    git config --file "$common_config" core.worktree "$poisoned"
    resolve "$WORKTREE"
    git config --file "$common_config" --unset core.worktree || true
    [ "$status" -ne 0 ] || { echo "row core.worktree=$poisoned: status $status, output '$output'"; return 1; }
    [ -z "$output" ] || { echo "row core.worktree=$poisoned: printed '$output'"; return 1; }
  done

  run bash -c 'cd "$1" && GIT_DIR="$2/.git" GIT_WORK_TREE="$2" bash "$3" "$4"' _ "$neutral" "$other" "$LIBRARY_SCRIPT" "$REPO"
  [ "$status" -eq 0 ] || { echo "row GIT_DIR main root: status $status"; return 1; }
  [ "$output" = "$REPO" ] || { echo "row GIT_DIR main root: got '$output'"; return 1; }

  run bash -c 'cd "$1" && GIT_DIR="$2/.git" GIT_WORK_TREE="$2" bash "$3" --tree-root "$4"' _ "$neutral" "$other" "$LIBRARY_SCRIPT" "$REPO"
  [ "$status" -eq 0 ] || { echo "row GIT_DIR tree root: status $status"; return 1; }
  [ "$output" = "$REPO" ] || { echo "row GIT_DIR tree root: got '$output'"; return 1; }

  run bash -c 'GIT_DIR="$1/.git" bash "$2" --common-dir "$3" 2>/dev/null' _ "$other" "$LIBRARY_SCRIPT" "$REPO"
  [ "$status" -eq 0 ] || { echo "row GIT_DIR common directory: status $status"; return 1; }
  [ "$output" = "$REPO/.git" ] || { echo "row GIT_DIR common directory: got '$output'"; return 1; }
}

# ---------- gaia_resolve_tree_root ----------
# Its one divergence from gaia_resolve_main_root: a linked worktree resolves
# to its own root, not main's.

@test "gaia_resolve_tree_root answers each tree's own physical root and fails outside a tree" {
  make_repo
  make_worktree "$REPO" "w" "treewtbranch"
  local symlink nongit
  symlink="${REPO}-treesymlink"
  ln -s "$REPO" "$symlink"
  CLEANUP_DIRECTORIES+=("$symlink")
  nongit=$(mktemp -d -t gaia-mrl-treenongit-XXXXXX)
  CLEANUP_DIRECTORIES+=("$nongit")

  local row label directory expected
  for row in \
    "clone|$REPO|$REPO" \
    "linked worktree|$WORKTREE|$WORKTREE" \
    "symlinked checkout|$symlink|$REPO"; do
    label=${row%%|*}
    expected=${row##*|}
    directory=${row#*|}
    directory=${directory%|*}
    resolve_tree "$directory"
    [ "$status" -eq 0 ] || { echo "row $label: status $status"; return 1; }
    [ "$output" = "$expected" ] || { echo "row $label: got '$output', expected '$expected'"; return 1; }
  done

  resolve "$WORKTREE"
  [ "$status" -eq 0 ] || return 1
  [ "$output" = "$REPO" ] || { echo "row main root diverges from tree root for the worktree: got '$output'"; return 1; }

  resolve_tree "$nongit"
  [ "$status" -ne 0 ] || { echo "row outside any work tree: status $status"; return 1; }
  [ -z "$output" ] || { echo "row outside any work tree: printed '$output'"; return 1; }
}

# ---------- gaia_tree_key ----------
# The path-safe rendering of the tree identity gaia_resolve_tree_root returns:
# the first 16 hex characters of the sha256 of that physically resolved root.

# resolve_key <directory>: runs the executable entry's --tree-key operand. Mirrors
# resolve()'s stderr-discard-inside-bash-c note.
resolve_key() {
  local directory="$1"
  run bash -c 'bash "$1" --tree-key "$2" 2>/dev/null' _ "$LIBRARY_SCRIPT" "$directory"
}

# resolve_key_from <cwd> <directory>: process cwd=$1 (unrelated to $2), operand=$2.
# Mirrors resolve_from().
resolve_key_from() {
  local cwd="$1" directory="$2"
  run bash -c 'cd "$1" && bash "$2" --tree-key "$3" 2>/dev/null' _ "$cwd" "$LIBRARY_SCRIPT" "$directory"
}

@test "gaia_tree_key: stable 16-hex sha256 prefix, distinct per tree and worktree, fails outside a tree" {
  make_repo
  make_worktree "$REPO" "w" "keywtbranch"
  make_submodule
  local nongit expected
  nongit=$(mktemp -d -t gaia-mrl-keynongit-XXXXXX)
  CLEANUP_DIRECTORIES+=("$nongit")

  resolve_key "$REPO"
  [ "$status" -eq 0 ] || return 1
  local key_repo="$output"
  resolve_key "$REPO"
  [ "$output" = "$key_repo" ] || { echo "row same tree twice: got '$output' then '$key_repo'"; return 1; }
  [[ "$key_repo" =~ ^[0-9a-f]{16}$ ]] || { echo "row key form: got '$key_repo'"; return 1; }
  expected=$(printf '%s' "$REPO" | shasum -a 256 | cut -c1-16)
  [ "$key_repo" = "$expected" ] || { echo "row differential: got '$key_repo', expected '$expected'"; return 1; }

  resolve_key "$SUBMODULE"
  [ "$status" -eq 0 ] || return 1
  [ "$output" != "$key_repo" ] || { echo "row two different trees share a key"; return 1; }

  resolve_key "$WORKTREE"
  [ "$status" -eq 0 ] || return 1
  [ "$output" != "$key_repo" ] || { echo "row linked worktree shares main's key"; return 1; }

  resolve_key "$nongit"
  [ "$status" -eq 1 ] || { echo "row outside any work tree: status $status"; return 1; }
  [ -z "$output" ] || { echo "row outside any work tree: printed '$output'"; return 1; }
  run bash -c 'bash "$1" --tree-key "$2" 2>&1 1>/dev/null' _ "$LIBRARY_SCRIPT" "$nongit"
  grep -qF -- "GAIA_TREE_KEY_UNRESOLVABLE" <<<"$output" || return 1
}

# ---------- gaia_resolve_common_directory ----------
# The repository-identity half of the resolver: a main checkout and every
# linked worktree of it answer with one directory, and two repositories never
# do.

resolve_common() {
  run bash -c 'bash "$1" --common-dir "$2" 2>/dev/null' _ "$LIBRARY_SCRIPT" "$1"
}

@test "gaia_resolve_common_directory: shared across worktrees, distinct per repo, fails outside a repo" {
  make_repo
  make_worktree "$REPO" "w" "commonwtbranch"
  local first="$REPO" first_worktree="$WORKTREE"
  local outside
  outside=$(mktemp -d -t gaia-mrl-cd-outside-XXXXXX)
  CLEANUP_DIRECTORIES+=("$outside")

  resolve_common "$first"
  [ "$status" -eq 0 ] || return 1
  [ "$output" = "$first/.git" ] || { echo "row main checkout: got '$output'"; return 1; }
  resolve_common "$first_worktree"
  [ "$status" -eq 0 ] || return 1
  [ "$output" = "$first/.git" ] || { echo "row linked worktree: got '$output'"; return 1; }

  make_repo
  resolve_common "$REPO"
  [ "$status" -eq 0 ] || return 1
  [ "$output" != "$first/.git" ] || { echo "row two repositories share a common directory"; return 1; }

  resolve_common "$outside"
  [ "$status" -ne 0 ] || { echo "row outside any repository: status $status"; return 1; }
  [ -z "$output" ] || { echo "row outside any repository: printed '$output'"; return 1; }
}

# ---------- separate-git-dir entered from a linked worktree ----------

@test "separate-git-dir linked worktree fails with one named diagnostic, empty stdout, unmodified git dir" {
  make_separate_gitdir
  make_worktree "$WORK" "w" "sepwtbranch"
  local expected_gitdir gitdir_before gitdir_after
  expected_gitdir="$(cd "$(git -C "$WORKTREE" rev-parse --absolute-git-dir)" && pwd -P)"
  gitdir_before="$(find "$GITDIR" | sort)"

  resolve "$WORKTREE"
  [ "$status" -eq 3 ]
  [ -z "$output" ]

  gitdir_after="$(find "$GITDIR" | sort)"
  [ "$gitdir_before" = "$gitdir_after" ]

  run bash -c 'bash "$1" "$2" 2>&1 1>/dev/null' _ "$LIBRARY_SCRIPT" "$WORKTREE"
  grep -qF -- "GAIA_MAIN_ROOT_UNRESOLVABLE" <<<"$output" || return 1
  grep -qF -- "$expected_gitdir" <<<"$output" || return 1
  [ "$(wc -l <<<"$output" | tr -d ' ')" -eq 1 ]
}

# ---------- output form ----------

@test "output form: stdout is exactly one line terminated by a single newline on success" {
  make_repo
  local outfile
  outfile=$(mktemp -t gaia-mrl-outfile-XXXXXX)
  CLEANUP_DIRECTORIES+=("$outfile")
  bash "$LIBRARY_SCRIPT" "$REPO" >"$outfile" 2>/dev/null
  [ "$(wc -l <"$outfile" | tr -d ' ')" -eq 1 ]
  [ "$(tail -c1 "$outfile" | od -An -tx1 | tr -d ' ')" = "0a" ]
  [ "$(cat "$outfile")" = "$REPO" ]
}

# ---------- bare repository / no working tree ----------

@test "a bare repository fails with a named diagnostic rather than silently falling back" {
  local bare
  bare=$(mktemp -d -t gaia-mrl-bare2-XXXXXX)
  CLEANUP_DIRECTORIES+=("$bare")
  git init -q --bare "$bare"

  run bash -c 'bash "$1" "$2" 2>&1 1>/dev/null' _ "$LIBRARY_SCRIPT" "$bare"
  grep -qF -- "GAIA_MAIN_ROOT_UNRESOLVABLE" <<<"$output" || return 1

  resolve "$bare"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

# ---------- fast layout read: parity with the full resolver ----------

# resolve_fast <directory>: the bash-only layout read alone, stdout only.
resolve_fast() {
  run bash -c 'source "$1"; source "$2"; gaia_resolve_main_root_fast "$3" 2>/dev/null' _ "$LIBRARY_SCRIPT" "${LIBRARY_SCRIPT%/*}/rate-limit-main-root-probe-lib.sh" "$1"
}

# resolve_full <directory>: the full resolver itself, which never calls the
# fast read, so the two answers come from independent code.
resolve_full() {
  run bash -c 'source "$1"; gaia_resolve_main_root "$2" 2>/dev/null' _ "$LIBRARY_SCRIPT" "$1"
}

# assert_fast_agrees_with_full <directory>: whenever the fast read yields a
# root, the full resolution yields the same one; a deferral prints nothing.
assert_fast_agrees_with_full() {
  resolve_fast "$1"
  local fast_status="$status" fast_output="$output"
  resolve_full "$1"
  if [ "$fast_status" -eq 0 ]; then
    [ "$status" -eq 0 ]
    [ "$output" = "$fast_output" ]
  else
    [ -z "$fast_output" ]
  fi
}

@test "fast read: a plain checkout, at its root and from a subdirectory, yields the full resolver's root" {
  make_repo
  mkdir -p "$REPO/a/b"
  local directory
  for directory in "$REPO" "$REPO/a/b"; do
    resolve_fast "$directory"
    [ "$status" -eq 0 ]
    [ "$output" = "$REPO" ]
    assert_fast_agrees_with_full "$directory"
  done
}

@test "fast read: a linked worktree yields the main root, as the full resolver does" {
  make_repo
  make_worktree "$REPO" "w" "fastbranch1"
  mkdir -p "$WORKTREE/sub"
  local directory
  for directory in "$WORKTREE" "$WORKTREE/sub"; do
    resolve_fast "$directory"
    [ "$status" -eq 0 ]
    [ "$output" = "$REPO" ]
    assert_fast_agrees_with_full "$directory"
  done
}

@test "fast read: a symlinked checkout yields the physical root" {
  make_repo
  local symlink="${REPO}-fastlink"
  ln -s "$REPO" "$symlink"
  CLEANUP_DIRECTORIES+=("$symlink")
  resolve_fast "$symlink"
  [ "$status" -eq 0 ]
  [ "$output" = "$REPO" ]
  assert_fast_agrees_with_full "$symlink"
}

@test "fast read: a core.worktree checkout defers and the full resolver decides" {
  make_repo
  make_worktree "$REPO" "w" "fastbranch2"
  local common_config="$REPO/.git/config"
  git config --file "$common_config" core.worktree "$REPO"
  resolve_fast "$REPO"
  local plain_status="$status" plain_output="$output"
  resolve_fast "$WORKTREE"
  local linked_status="$status" linked_output="$output"
  assert_fast_agrees_with_full "$REPO"
  assert_fast_agrees_with_full "$WORKTREE"
  git config --file "$common_config" --unset core.worktree || true
  [ "$plain_status" -ne 0 ]
  [ -z "$plain_output" ]
  [ "$linked_status" -ne 0 ]
  [ -z "$linked_output" ]
}

@test "fast read: an unrelated core.worktree never yields a root the full resolver refuses" {
  make_repo
  make_worktree "$REPO" "w" "fastbranch3"
  git config --file "$REPO/.git/config" core.worktree "/nonexistent/evil/path"
  assert_fast_agrees_with_full "$WORKTREE"
  git config --file "$REPO/.git/config" --unset core.worktree || true
}

@test "fast read: submodule, separate git dir, a .git directory interior and a non-repository all defer" {
  make_submodule
  make_separate_gitdir
  make_repo
  local outside
  outside=$(mktemp -d -t gaia-mrl-outside-XXXXXX)
  CLEANUP_DIRECTORIES+=("$outside")
  local directory
  for directory in "$SUBMODULE" "$WORK" "$REPO/.git" "$REPO/.git/refs" "$outside"; do
    resolve_fast "$directory"
    [ "$status" -ne 0 ]
    [ -z "$output" ]
    assert_fast_agrees_with_full "$directory"
  done
}

@test "fast read: a worktree whose back-link no longer names it defers" {
  make_repo
  make_worktree "$REPO" "w" "fastbranch4"
  printf '%s\n' "$REPO/.claude/worktrees/elsewhere/.git" >"$REPO/.git/worktrees/w/gitdir"
  resolve_fast "$WORKTREE"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}
