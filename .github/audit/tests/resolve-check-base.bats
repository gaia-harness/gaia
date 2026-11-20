#!/usr/bin/env bats

# Tests for .github/audit/resolve-check-base.sh.
#
# The helper is consumed by required-check workflows (e.g. tests.yml's "Vitest
# and Playwright" gate). It emits a single line: the most recent PR ancestor of
# HEAD on which the named check concluded SUCCESS, or the main ref for a
# full-scope fallback.
#
# Like resolve-audit-base.bats, each test runs in an isolated `git init`'d temp
# dir whose HEAD sits on a FEATURE branch off `main`, so the merge-base bound
# leaves the branch's own commits walkable. There is no `origin` remote, so the
# fallback main ref resolves to the local `main` branch ("main").
#
# The Checks API path is mocked via a fake `gh` on a prepended PATH. The mock
# is keyed by "sha=check-name" pairs: it prints the success count (1) only when
# BOTH the queried SHA (in the URL) and the check name (embedded in the --jq
# filter) appear in the call's args, else 0. This exercises the name filter.
#

setup() {
  THIS_DIRECTORY="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  SCRIPT="$THIS_DIRECTORY/../resolve-check-base.sh"
  [ -x "$SCRIPT" ]

  CHECK="Vitest and Playwright"

  SANDBOX="$BATS_TEST_TMPDIR/sandbox"
  mkdir -p "$SANDBOX"

  git -C "$SANDBOX" init --quiet --initial-branch=main
  git -C "$SANDBOX" config user.email "test@example.com"
  git -C "$SANDBOX" config user.name "Test"
  git -C "$SANDBOX" config commit.gpgsign false

  # Base commit on main; the PR branch diverges from here.
  echo "# readme" > "$SANDBOX/README.md"
  git -C "$SANDBOX" add README.md
  git -C "$SANDBOX" commit --quiet -m "init"

  git -C "$SANDBOX" checkout --quiet -b feature

  # Default: gh reachable with a token, but no green checks mapped yet.
  install_gh_mock
}

# Run the script (default check name) with cwd inside the sandbox.
run_in_sandbox() {
  ( cd "$SANDBOX" && "$SCRIPT" "$CHECK" )
}

# Run the script with an explicit (or empty) check-name argument.
run_in_sandbox_named() {
  ( cd "$SANDBOX" && "$SCRIPT" "$@" )
}

# Add a commit on the feature branch. $1 = file/commit marker.
add_commit() {
  local marker="$1"
  echo "$marker" > "$SANDBOX/${marker}.txt"
  git -C "$SANDBOX" add "${marker}.txt"
  git -C "$SANDBOX" commit --quiet -m "$marker"
}

sha_of() {
  git -C "$SANDBOX" rev-parse "$1"
}

# Install a fake `gh`. $@ = "sha=check-name" pairs, each meaning "this commit
# has a green (success) check-run with this name". The mock prints 1 when both
# the SHA and the name appear in the call args (the SHA in the URL path, the
# name in the --jq filter), else 0, mirroring `[...] | length` on the real API.
install_gh_mock() {
  GH_BIN="$BATS_TEST_TMPDIR/bin"
  MAP="$BATS_TEST_TMPDIR/gh-check-map"
  mkdir -p "$GH_BIN"
  : > "$MAP"
  for pair in "$@"; do
    printf '%s\n' "$pair" >> "$MAP"
  done
  cat > "$GH_BIN/gh" <<EOF
#!/usr/bin/env bash
# Mock: resolve-check-base calls
#   gh api repos/<repo>/commits/<sha>/check-runs?per_page=100 --jq '[...] | length'
args="\$*"
while IFS= read -r line; do
  sha="\${line%%=*}"
  name="\${line#*=}"
  case "\$args" in
    *"\$sha"*)
      case "\$args" in
        *"\$name"*) printf '1\n'; exit 0 ;;
      esac
      ;;
  esac
done < "$MAP"
printf '0\n'
exit 0
EOF
  chmod +x "$GH_BIN/gh"
  export PATH="$GH_BIN:$PATH"
  export GH_TOKEN="fake-token"
  export GITHUB_REPOSITORY="gaia-react/gaia"
}

# Every input here leaves no green ancestor that can anchor a base, so the
# helper falls back to the full-scope main ref rather than skip un-passed code.
# bats test_tags=protected
@test "falls back to the main ref when no green ancestor can anchor a base (case table)" {
  echo "case: single-commit PR → main ref"
  add_commit a
  run run_in_sandbox
  [ "$status" -eq 0 ]
  [ "$output" = "main" ]

  echo "case: green check on HEAD is not used as its own base"
  head="$(sha_of HEAD)"
  install_gh_mock "${head}=${CHECK}"
  run run_in_sandbox
  [ "$status" -eq 0 ]
  [ "$output" = "main" ]

  base="$head"
  add_commit b

  echo "case: no green check on any PR commit → main ref"
  install_gh_mock
  run run_in_sandbox
  [ "$status" -eq 0 ]
  [ "$output" = "main" ]

  echo "case: no GH_TOKEN → API unreachable → main ref"
  # A green check exists in principle, but without GH_TOKEN the helper never
  # queries it.
  install_gh_mock "${base}=${CHECK}"
  unset GH_TOKEN || true
  run run_in_sandbox
  [ "$status" -eq 0 ]
  [ "$output" = "main" ]

  echo "case: green check for a different context is ignored → main ref"
  install_gh_mock "${base}=Some Other Check"
  run run_in_sandbox
  [ "$status" -eq 0 ]
  [ "$output" = "main" ]

  echo "case: missing check-name argument → main ref"
  install_gh_mock "${base}=${CHECK}"
  run run_in_sandbox_named
  [ "$status" -eq 0 ]
  [ "$output" = "main" ]
}

# -----------------------------------------------------------------------------
# Which ref the full-scope fallback names. This helper mirrors
# resolve-audit-base.sh's fallback contract, so a pull request stacked on a
# branch other than the default one falls back to ITS OWN base here too:
# falling back to the default would re-run the check over the base branch's
# whole divergence. The sandbox has no remote, which
# is why every other test sees the bare local `main`; these write
# remote-tracking refs by hand so an `origin/<ref>` can resolve.
# -----------------------------------------------------------------------------

set_origin_reference() {
  git -C "$SANDBOX" update-ref "refs/remotes/origin/$1" "$(git -C "$SANDBOX" rev-parse "$2")"
}

# GITHUB_BASE_REF is read only where the event sets it, the same gate and the
# same reason as the sibling resolver: outside Actions the variable belongs to
# the caller, and a value resolving near HEAD would skip work nothing proved
# green. Each case: label, GITHUB_ACTIONS ("-" unset), GITHUB_BASE_REF ("-"
# unset), the expected ref.
BASE_REFERENCE_CASES="the pull request's own base ref wins over the repository default|true|release|origin/release
no base ref declared → the repository default|true|-|origin/main
a base ref naming no remote branch → the repository default|true|deleted-branch|origin/main
a base ref declared outside Actions is ignored|-|release|origin/main"

# bats test_tags=protected
@test "the fallback names the pull request's own base ref, else the default (case table)" {
  local label actions base_reference expected cases=0
  add_commit a
  add_commit b
  set_origin_reference main main
  set_origin_reference release main

  while IFS='|' read -r label actions base_reference expected; do
    echo "case: $label"
    cases=$((cases + 1))
    unset GITHUB_ACTIONS GITHUB_BASE_REF
    [ "$actions" = - ] || export GITHUB_ACTIONS="$actions"
    [ "$base_reference" = - ] || export GITHUB_BASE_REF="$base_reference"
    run run_in_sandbox
    [ "$status" -eq 0 ] || return 1
    [ "$output" = "$expected" ] || return 1
  done <<<"$BASE_REFERENCE_CASES"
  [ "$cases" -eq 4 ]
}

# A failed or cancelled run leaves no green signal, so the base is the last
# GREEN ancestor, not the last run. (A skipped-but-green run is
# indistinguishable here: its job check-run is also conclusion=success.)
@test "the newest green ancestor of HEAD is the resolved base (case table)" {
  add_commit a
  older="$(sha_of HEAD)"
  add_commit b
  newer="$(sha_of HEAD)"
  add_commit c

  echo "case: green check on parent → parent SHA"
  install_gh_mock "${newer}=${CHECK}"
  run run_in_sandbox
  [ "$status" -eq 0 ]
  [ "$output" = "$newer" ]

  echo "case: non-green parent with green grandparent → grandparent SHA"
  install_gh_mock "${older}=${CHECK}"
  run run_in_sandbox
  [ "$status" -eq 0 ]
  [ "$output" = "$older" ]

  echo "case: newest green commit wins over an older green commit"
  install_gh_mock "${older}=${CHECK}" "${newer}=${CHECK}"
  run run_in_sandbox
  [ "$status" -eq 0 ]
  [ "$output" = "$newer" ]
  [ "$output" != "$older" ]
}
