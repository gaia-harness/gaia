#!/usr/bin/env bats
# Real-worktree survival: work written from a linked worktree lands in the main
# checkout's notebook and outlives the worktree. Uses a real `git worktree add`
# and a plain `git worktree remove` (no --force), because the point is that the
# notebook link is gitignored, so removing the worktree never needs force and
# never takes the notebook with it.
#
# Without the link, whether the worktree's .notebook is absent or a real
# directory, the library resolves the main checkout itself, so the writes still
# land in main and the worktree gains no notebook content.
#
# Assertion style: .claude/rules/bats-assertions.md.

bats_require_minimum_version 1.5.0

setup() {
  HELPERS="$BATS_TEST_DIRNAME/helpers"
  REAL_ROOT="$(git -C "$BATS_TEST_DIRNAME" rev-parse --show-toplevel)"
}

teardown() {
  if [ -n "${REPO:-}" ]; then
    git -C "$REPO" worktree remove --force "$WORKTREE" 2>/dev/null || true
    rm -rf "$REPO" "$WORKTREE"
  fi
}

# Builds the fixture repository and its linked worktree with no pre-made links;
# sets REPO and WORKTREE.
_fixture_repository() {
  local built
  built="$("$HELPERS/tmp-notebook-repo.sh" --worktree-bare wt)"
  REPO="$(printf '%s\n' "$built" | sed -n 1p)"
  WORKTREE="$(printf '%s\n' "$built" | sed -n 2p)"
  cp "$REAL_ROOT/.gaia/scripts/link-worktree.sh" "$REPO/.gaia/scripts/link-worktree.sh"
  mkdir -p "$REPO/.claude/hooks/lib"
  cp "$REAL_ROOT/.claude/hooks/lib/gaia-packages.sh" "$REPO/.claude/hooks/lib/gaia-packages.sh"
}

# Runs the library CLI from inside the worktree.
_library_from_worktree() {
  ( cd "$WORKTREE" && bash "$REPO/.gaia/scripts/notebook/notebook-lib.sh" "$@" )
}

# Registers one item of each kind from the worktree and writes a file in each
# folder the library names.
_write_three_items() {
  local spec_directory plan_directory research_directory
  _library_from_worktree register spec SPEC-001 draft --subject "survival spec"
  _library_from_worktree register plan PLAN-001 ready --subject "survival plan"
  _library_from_worktree register research survival-topic-2026-10-01 active --subject "survival note"
  spec_directory="$(_library_from_worktree path spec SPEC-001)"
  plan_directory="$(_library_from_worktree path plan PLAN-001)"
  research_directory="$(_library_from_worktree path research survival-topic-2026-10-01)"
  mkdir -p "$spec_directory" "$plan_directory" "$research_directory"
  printf 'spec body\n' > "$spec_directory/SPEC.md"
  printf 'plan body\n' > "$plan_directory/PROGRESS.md"
  printf 'research body\n' > "$research_directory/README.md"
}

# bats test_tags=protected
@test "link-worktree links the worktree's notebook to main's, and the work outlives a plain worktree removal" {
  _fixture_repository
  [ ! -e "$WORKTREE/.notebook" ]
  [ ! -L "$WORKTREE/.notebook" ]

  run bash -c 'cd "$1" && bash "$2/.gaia/scripts/link-worktree.sh" 2>&1' _ "$WORKTREE" "$REPO"
  [ "$status" -eq 0 ]
  grep -qF "linked: $WORKTREE/.notebook" <<<"$output"
  [ -L "$WORKTREE/.notebook" ]
  [ "$(readlink "$WORKTREE/.notebook")" = "$REPO/.notebook" ]

  _write_three_items

  run git -C "$REPO" worktree remove "$WORKTREE"
  [ "$status" -eq 0 ]
  [ ! -e "$WORKTREE" ]

  [ "$(cat "$REPO/.notebook/specs/SPEC-001/SPEC.md")" = "spec body" ]
  [ "$(cat "$REPO/.notebook/plans/PLAN-001/PROGRESS.md")" = "plan body" ]
  [ "$(cat "$REPO/.notebook/research/survival-topic-2026-10-01/README.md")" = "research body" ]

  GAIA_NOTEBOOK_TREE="$REPO" run bash "$REPO/.gaia/scripts/notebook/notebook-lib.sh" get spec SPEC-001
  [ "$status" -eq 0 ]
  [ "$(jq -r '.id' <<<"$output")" = SPEC-001 ]
  GAIA_NOTEBOOK_TREE="$REPO" run bash "$REPO/.gaia/scripts/notebook/notebook-lib.sh" get plan PLAN-001
  [ "$status" -eq 0 ]
  [ "$(jq -r '.id' <<<"$output")" = PLAN-001 ]
  GAIA_NOTEBOOK_TREE="$REPO" run bash "$REPO/.gaia/scripts/notebook/notebook-lib.sh" get research survival-topic-2026-10-01
  [ "$status" -eq 0 ]
  [ "$(jq -r '.id' <<<"$output")" = survival-topic-2026-10-01 ]
  [ "$(jq '[.items[] | select(.id == "SPEC-001" or .id == "PLAN-001" or .id == "survival-topic-2026-10-01")] | length' "$REPO/.notebook/catalog.json")" -eq 3 ]
}

@test "the library writes to main from a worktree whose notebook link is absent or a real directory, and the worktree gains no notebook content" {
  local shape
  for shape in absent directory; do
    _fixture_repository
    if [ "$shape" = directory ]; then
      mkdir "$WORKTREE/.notebook"
    fi

    _write_three_items

    if [ "$shape" = directory ]; then
      [ -z "$(ls -A "$WORKTREE/.notebook")" ] || { echo "shape $shape: the worktree directory holds content"; return 1; }
    else
      [ ! -e "$WORKTREE/.notebook" ] || { echo "shape $shape: a notebook appeared in the worktree"; return 1; }
    fi
    [ "$(cat "$REPO/.notebook/specs/SPEC-001/SPEC.md")" = "spec body" ] || { echo "shape $shape: spec not in main"; return 1; }
    [ "$(cat "$REPO/.notebook/plans/PLAN-001/PROGRESS.md")" = "plan body" ] || { echo "shape $shape: plan not in main"; return 1; }
    [ "$(cat "$REPO/.notebook/research/survival-topic-2026-10-01/README.md")" = "research body" ] || { echo "shape $shape: research not in main"; return 1; }
    [ "$(jq '[.items[] | select(.id == "SPEC-001" or .id == "PLAN-001" or .id == "survival-topic-2026-10-01")] | length' "$REPO/.notebook/catalog.json")" -eq 3 ] || { echo "shape $shape: catalog rows missing"; return 1; }
    git -C "$REPO" worktree remove --force "$WORKTREE"
    rm -rf "$REPO" "$WORKTREE"
  done
  REPO=""
}
