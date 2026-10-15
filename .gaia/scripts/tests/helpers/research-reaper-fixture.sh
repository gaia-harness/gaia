# shellcheck shell=bash
# Fixture helpers shared by the research reaper suites. Source it; it defines
# functions only.
#
# A fixture is a throwaway git repository holding copies of the notebook
# scripts, with a fake HOME (so the auto-memory folder and the session
# transcript are the fixture's own) and a `gh` stand-in first on PATH. The
# stand-in serves canned JSON from files in GH_STUB_DIR, logs each call, and
# fails on request. Rows are written straight into the catalog file, and each
# research folder gets a README that is old by mtime, so a folder is eligible
# unless a test makes it young or cited.
#
# Call reaper_setup from setup(), then reaper_fixture once per test.

reaper_setup() {
  unset GAIA_NOTEBOOK_TREE GAIA_NOTEBOOK_MEMORY_DIR GAIA_NOTEBOOK_CATALOG_LOCK_HELD \
    GAIA_RESEARCH_RETENTION_DAYS GAIA_RESEARCH_GH_TIMEOUT_SECONDS CLAUDE_CODE_ENTRYPOINT \
    CLAUDE_CODE_SESSION_ID CLAUDE_CONFIG_DIR GAIA_TALLY_PROJECTS_ROOT GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR
  SOURCE_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd -P)"
  SCRATCH="$(cd "$BATS_TEST_TMPDIR" && pwd -P)"
  # A cwd outside any repository: a call that ignored the tree selector fails
  # to resolve rather than reaching the checkout that runs this suite.
  cd "$SCRATCH" || return 1
  export HOME="$SCRATCH/home"
  mkdir -p "$HOME"
  export GAIA_NOTEBOOK_MEMORY_DIR="$SCRATCH/memory"
  mkdir -p "$GAIA_NOTEBOOK_MEMORY_DIR"
  GH_STUB_DIR="$SCRATCH/gh-stub"
  export GH_STUB_DIR
  mkdir -p "$GH_STUB_DIR/bin"
  cat >"$GH_STUB_DIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_STUB_DIR/calls.log"
mode="$(cat "$GH_STUB_DIR/mode" 2>/dev/null || echo ok)"
case "$mode" in
  fail) echo "gh: something went wrong" >&2; exit 1 ;;
  unauth)
    echo "To get started with GitHub CLI, please run:  gh auth login" >&2
    exit 4
    ;;
  slow) sleep 8; exit 0 ;;
esac
case "$1" in
  api)
    if [ "$mode" = nonjson ]; then echo "this is not json"; exit 0; fi
    cat "$GH_STUB_DIR/issues.json"
    ;;
  pr)
    if [ "$mode" = nonjson ]; then echo "this is not json"; exit 0; fi
    cat "$GH_STUB_DIR/prs.json"
    ;;
  *) echo "gh stub: unexpected call: $*" >&2; exit 9 ;;
esac
STUB
  chmod +x "$GH_STUB_DIR/bin/gh"
  printf '[]\n' >"$GH_STUB_DIR/issues.json"
  printf '[]\n' >"$GH_STUB_DIR/prs.json"
  export PATH="$GH_STUB_DIR/bin:$PATH"
  OLD_STAMP="2026-01-01T00:00:00Z"
}

# reaper_fixture [--no-remote] [--legacy]: builds the repository in REPO.
reaper_fixture() {
  local with_remote=1 helper_arguments=() argument
  for argument in "$@"; do
    case "$argument" in
      --no-remote) with_remote=0 ;;
      *) helper_arguments+=("$argument") ;;
    esac
  done
  REPO="$(bash "$SOURCE_ROOT/.gaia/tests/lib/helpers/tmp-notebook-repo.sh" ${helper_arguments[@]+"${helper_arguments[@]}"})" || return 1
  CATALOG="$REPO/.notebook/catalog.json"
  RESEARCH="$REPO/.notebook/research"
  REAPER="$REPO/.gaia/scripts/notebook/research-reaper.sh"
  if [ "$with_remote" -eq 1 ]; then
    git -C "$REPO" remote add origin https://github.com/acme/widgets.git
  fi
  # shellcheck source=/dev/null
  source "$REPO/.gaia/scripts/notebook/legacy-roots.sh"
  # shellcheck disable=SC2034  # read by the suites that source this file
  OLD_PREFIX="$(gaia_notebook_legacy_prefix research)"
  # shellcheck disable=SC2034
  NEW_PREFIX=".notebook/research/"
  export GAIA_NOTEBOOK_TREE="$REPO"
}

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# days_from_now_iso <signed days>
days_from_now_iso() {
  jq -rn --argjson days "$1" '(now + ($days * 86400)) | strftime("%Y-%m-%dT%H:%M:%SZ")'
}

# append_row <json-object>
append_row() {
  local updated
  updated="$(jq --argjson row "$1" '.items += [$row]' "$CATALOG")" || return 1
  printf '%s\n' "$updated" >"$CATALOG"
}

# patch_row <kind> <id> <json-patch>
patch_row() {
  local updated
  updated="$(jq --arg kind "$1" --arg id "$2" --argjson patch "$3" \
    '.items |= map(if .kind == $kind and .id == $id then . + $patch else . end)' "$CATALOG")" || return 1
  printf '%s\n' "$updated" >"$CATALOG"
}

# age_folder <slug>: every file in the folder gets an old mtime.
age_folder() {
  find "$RESEARCH/$1" -type f -exec touch -t 202601010000 {} +
}

# add_folder <slug>: a research folder with an old README and no row.
add_folder() {
  mkdir -p "$RESEARCH/$1"
  printf '# %s\n\nResearch body.\n' "$1" >"$RESEARCH/$1/README.md"
  age_folder "$1"
}

# add_research <slug> <status> [<extra-json>] [<status_changed_at>]
add_research() {
  local slug="$1" status="$2" extra="${3:-{\}}" stamp="${4:-$OLD_STAMP}"
  add_folder "$slug"
  append_row "$(jq -cn --arg id "$slug" --arg status "$status" --arg stamp "$stamp" --argjson extra "$extra" \
    '{kind: "research", id: $id, path: ("research/" + $id), status: $status, subject: $id,
      created_at: $stamp, status_changed_at: $stamp} + $extra')"
}

# add_spec <SPEC-NNN> <status> <links-json> [<extra-json>]
add_spec() {
  append_row "$(jq -cn --arg id "$1" --arg status "$2" --argjson links "$3" --argjson extra "${4:-{\}}" --arg stamp "$OLD_STAMP" \
    '{kind: "spec", id: $id, path: ("specs/" + $id), status: $status, subject: $id,
      created_at: $stamp, status_changed_at: $stamp, links: $links} + $extra')"
}

# add_plan <PLAN-NNN> <status> <links-json> [<extra-json>]
add_plan() {
  append_row "$(jq -cn --arg id "$1" --arg status "$2" --argjson links "$3" --argjson extra "${4:-{\}}" --arg stamp "$OLD_STAMP" \
    '{kind: "plan", id: $id, path: ("plans/" + $id), status: $status, subject: $id,
      created_at: $stamp, status_changed_at: $stamp, links: $links} + $extra')"
}

# gh_stub_mode ok|fail|nonjson|unauth|slow
gh_stub_mode() { printf '%s\n' "$1" >"$GH_STUB_DIR/mode"; }

# gh_stub_issue <number> <title> <body> [pr]: appends one open item.
gh_stub_issue() {
  local updated
  updated="$(jq --argjson number "$1" --arg title "$2" --arg body "$3" --arg pr "${4:-}" \
    '. += [{number: $number, title: $title, body: $body} + (if $pr == "pr" then {pull_request: {url: "x"}} else {} end)]' \
    "$GH_STUB_DIR/issues.json")"
  printf '%s\n' "$updated" >"$GH_STUB_DIR/issues.json"
}

# gh_stub_pull_request <number> <OPEN|MERGED|CLOSED> <head-branch>
gh_stub_pull_request() {
  local updated
  updated="$(jq --argjson number "$1" --arg state "$2" --arg head "$3" \
    '. += [{number: $number, state: $state, headRefName: $head}]' "$GH_STUB_DIR/prs.json")"
  printf '%s\n' "$updated" >"$GH_STUB_DIR/prs.json"
}

gh_stub_call_count() {
  if [ -f "$GH_STUB_DIR/calls.log" ]; then wc -l <"$GH_STUB_DIR/calls.log" | tr -d ' '; else printf '0\n'; fi
}

# memory_cites <file-name> <text>
memory_cites() { printf '%s\n' "$2" >"$GAIA_NOTEBOOK_MEMORY_DIR/$1"; }

# session_transcript <entrypoint> [<second-entrypoint>]: an interactive-looking
# session in the fixture's fake HOME. The environment variables are set by
# the caller through interactive_session.
session_transcript() {
  local directory
  directory="$HOME/.claude/projects/$(printf '%s' "$REPO" | sed 's/[^A-Za-z0-9]/-/g')"
  mkdir -p "$directory"
  : >"$directory/sess-fixture.jsonl"
  local entrypoint
  for entrypoint in "$@"; do
    printf '{"type":"user","entrypoint":"%s"}\n' "$entrypoint" >>"$directory/sess-fixture.jsonl"
  done
}

# interactive_session: the reaper sees a CLI session.
interactive_session() {
  export CLAUDE_CODE_ENTRYPOINT=cli CLAUDE_CODE_SESSION_ID=sess-fixture
  session_transcript cli cli
}

# run_reaper <args...>: stdout in $output, stderr in $stderr, status in $status.
run_reaper() {
  run --separate-stderr bash "$REAPER" "$@"
}

# catalog_snapshot: the catalog in canonical key order, for before/after
# comparisons.
catalog_snapshot() { jq -S . "$CATALOG"; }

# tree_digest: a digest of every file under the notebook (names and bytes).
tree_digest() {
  (cd "$REPO/.notebook" && find . -type f | LC_ALL=C sort | while IFS= read -r file; do
    printf '%s %s\n' "$file" "$(shasum <"$file" | cut -d' ' -f1)"
  done)
}
