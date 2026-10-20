#!/usr/bin/env bash
# Saves a confirmed /gaia-spec draft as the canonical SPEC.md and finalizes its
# catalog row, as one command under one allow entry. Run as separate snippets
# the save loses its shell state between calls, so a caller fuses them into a
# compound command (a nested `bash -c`, command substitutions, a redirect, a cp
# into the notebook) that the permission checker cannot read and always asks
# about; an unattended session is then denied and the SPEC is never saved.
#
# Usage: spec-save.sh <repo_root> <SPEC-NNN>
#
#   <repo_root>  absolute path of the tree the session runs in; the main
#                checkout is resolved from it, so a linked worktree saves into
#                the main checkout's notebook.
#   <SPEC-NNN>   the SPEC id step 3 allocated.
#
# Reads the working draft <repo_root>/.gaia/local/cache/draft-<id>.md. In order:
#   1. resolves the SPEC folder through the notebook library, fail-closed;
#   2. writes the draft to <folder>/SPEC.md with the frontmatter `updated:` set
#      to today, and compares the written file against the stamped copy;
#   3. flips the catalog row to ready, stamping the intent's first sentence;
#   4. records the frontmatter's `research:<slug>` lineage entries on the row;
#   5. removes the draft, gate-1, session-shape and audit caches;
#   6. releases the session lock;
#   7. records the usage run and materializes the lineage edges.
# Steps 1 and 2 refuse (exit 1) and leave every cache in place, so the draft
# survives for a retry. Steps 3 to 7 are best-effort: each failure prints one
# `spec-save: <step> skipped (<reason>)` line on stderr and the save still exits 0.
#
# Stdout: the saved SPEC.md path on the first line, for the caller's lint.
# Exit codes: 0 saved; 1 refused, reason on stderr; 2 usage error.
#
# Bash 3.2 compatible; BSD and GNU tools.
set -uo pipefail

usage() {
  printf 'usage: spec-save.sh <repo_root> <SPEC-NNN>\n' >&2
  exit 2
}

refuse() {
  printf 'spec-save: %s\n' "$1" >&2
  exit 1
}

skipped() {
  printf 'spec-save: %s skipped (%s)\n' "$1" "$2" >&2
}

[ "$#" -eq 2 ] || usage
repo_root="$1"
spec_id="$2"
case "$repo_root" in /*) ;; *) usage ;; esac
[[ "$spec_id" =~ ^SPEC-[0-9]{3,}$ ]] || usage

script_directory="$(cd "$(dirname "$0")" && pwd)"
scripts_root="$(dirname "$script_directory")"
cache_directory="$repo_root/.gaia/local/cache"
draft="$cache_directory/draft-$spec_id.md"

[ -f "$draft" ] && [ -s "$draft" ] || refuse "no draft at $draft; nothing to save"

spec_folder="$(GAIA_NOTEBOOK_TREE="$repo_root" bash "$scripts_root/notebook/notebook-lib.sh" path spec "$spec_id" 2>/dev/null)" || spec_folder=""
[ -n "$spec_folder" ] || refuse "cannot resolve the notebook's SPEC folder for $spec_id; refusing to save"
mkdir -p "$spec_folder" || refuse "cannot create $spec_folder"
spec_path="$spec_folder/SPEC.md"

stamped="$(mktemp "${TMPDIR:-/tmp}/spec-save.XXXXXX")" || refuse "cannot create a temporary file"
trap 'rm -f "$stamped"' EXIT
# Only the frontmatter's `updated:` line is stamped: a body line that happens to
# start with `updated:` is SPEC prose and keeps its text.
awk -v today="$(date +%Y-%m-%d)" '
  NR == 1 && $0 == "---" { in_frontmatter = 1; print; next }
  in_frontmatter && $0 == "---" { in_frontmatter = 0 }
  in_frontmatter && /^updated:/ { print "updated: " today; next }
  { print }
' "$draft" >"$stamped" || refuse "cannot stamp $draft"
if ! cp "$stamped" "$spec_path" || ! cmp -s "$stamped" "$spec_path"; then
  refuse "the write to $spec_path did not match the draft"
fi
printf '%s\n' "$spec_path"

intent_raw="$(awk '
  /^intent:[[:space:]]*\|/ { in_block = 1; next }
  /^intent:[[:space:]]*[^|[:space:]]/ { sub(/^intent:[[:space:]]*/, ""); print; exit }
  in_block && /^[a-zA-Z_]+:/ { exit }
  in_block && /^[[:space:]]+[^[:space:]]/ { sub(/^[[:space:]]+/, ""); print }
' "$spec_path" 2>/dev/null)" || intent_raw=""
intent="$(printf '%s' "$intent_raw" | bash "$script_directory/title-normalize.sh" 2>/dev/null)" || intent=""
patch="$(jq -nc --arg intent "$intent" '{status: "ready"} + (if $intent == "" then {} else {intent: $intent} end)')"
bash "$script_directory/ledger-update.sh" "$repo_root" "$spec_id" "$patch" >/dev/null 2>&1 \
  || skipped "catalog flip" "row missing or catalog unwritable"

# shellcheck source=.gaia/scripts/usage-resolve-lib.sh
if . "$scripts_root/usage-resolve-lib.sh" 2>/dev/null; then
  # The first line is the spec_id; the rest are the lineage entries.
  research_links="$(gaia_usage_spec_lineage "$spec_path" | sed 1d | sed -n 's/^research://p' | jq -Rnc '[inputs | select(length > 0)]')" || research_links="[]"
  if [ "$research_links" != "[]" ]; then
    GAIA_NOTEBOOK_TREE="$repo_root" bash "$scripts_root/notebook/notebook-lib.sh" update spec "$spec_id" \
      "$(jq -nc --argjson research "$research_links" '{links: {research: $research}}')" >/dev/null 2>&1 \
      || skipped "research links" "row missing"
  fi
else
  skipped "research links" "usage-resolve-lib.sh unreadable"
fi

rm -f "$draft" "$cache_directory/gate1-$spec_id.json" "$cache_directory/spec-session-$spec_id.json"
rm -rf "$cache_directory/audit-$spec_id"
bash "$script_directory/spec-session-lock.sh" release "$repo_root" "$spec_id" >/dev/null 2>&1 || true

# shellcheck source=.gaia/scripts/main-root-lib.sh
main_root="$(. "$scripts_root/main-root-lib.sh" && gaia_resolve_main_root "$repo_root" 2>/dev/null)" || main_root="$repo_root"
bash "$scripts_root/usage.sh" record "spec:$spec_id" --workflow gaia-spec --quiet --main-root "$main_root" >/dev/null \
  || skipped "usage record" "usage.sh named the cause above"
bash "$scripts_root/usage.sh" lineage "$spec_path" --main-root "$main_root" >/dev/null \
  || skipped "lineage edges" "usage.sh named the cause above"
exit 0
