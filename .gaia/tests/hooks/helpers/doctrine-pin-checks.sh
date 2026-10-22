# shellcheck shell=bash
#
# Pin-site guards for the workflow doctrine: which files pin a model, and
# whether the doctrine page lists each one. workflow-doctrine-sources.bats
# sources this file in setup(); each helper takes the file or root to check, so
# the same helper runs on the real tree (must pass) and on a mutated scratch
# copy (must fail).
#
# Bash 3.2 safe (no mapfile, no case-folding expansions, no associative
# arrays), BSD and GNU tools both. Helpers return explicitly and never lean on
# `set -e`; each one that can fail names what failed in a global.

# A pin site names a model for a skill, an agent, or one dispatch: frontmatter
# `model:`, a dispatch `model: "<name>"` or `model`: `"<name>"`, a
# "<Model> agent" or "<Model> subagent" line, or a model alone in a table cell.
# A mention that is not a pin (a cost table header) can match too; the safe
# direction is over-listing, never a silent miss.
# shellcheck disable=SC2016 # the backticks are literal markdown
PIN_RE='model[`"]*:[[:space:]]*[`"]*(haiku|opus|sonnet|fable)([^a-z]|$)|(haiku|opus|sonnet|fable)\**[[:space:]]+(sub-?)?agent|\|[[:space:]]*\**(haiku|opus|sonnet|fable)\**[[:space:]]*\|'

# Prints every tracked file outside the doctrine page that pins a model.
pin_site_files() {
  git -C "$1" grep -l -i -E -e "$PIN_RE" -- .claude frontend/.claude wiki .gaia/cli/health \
    ':!wiki/log.md' ':!wiki/meta' ':!wiki/concepts/Workflow Doctrine.md'
}

# Prints the backticked path tokens under the page's "### Pin sites" heading.
pin_site_entries() {
  # shellcheck disable=SC2016 # the backticks are literal markdown
  awk '
    $0 == "### Pin sites" { on = 1; next }
    on && /^##/ { exit }
    on { print }
  ' "$1" | grep -oE '`[^`]*/[^`]*`' | tr -d '`'
}

PIN_UNCOVERED=""
pin_sites_covered_ok() {
  local root="$1" page="$2" file_path entry covered entries
  entries="$(pin_site_entries "$page")"
  [ -n "$entries" ] || return 1
  PIN_UNCOVERED=""
  while IFS= read -r file_path; do
    [ -n "$file_path" ] || continue
    covered=0
    while IFS= read -r entry; do
      # shellcheck disable=SC2254 # the entry is a glob on purpose
      case "$file_path" in $entry) covered=1 ;; esac
    done <<<"$entries"
    [ "$covered" = 1 ] || PIN_UNCOVERED="$PIN_UNCOVERED $file_path"
  done < <(pin_site_files "$root")
  [ -z "$PIN_UNCOVERED" ] || return 1
  return 0
}

pin_site_entries_live_ok() {
  local root="$1" page="$2" entry
  while IFS= read -r entry; do
    [ -n "$(git -C "$root" ls-files -z -- "$entry" | tr -d '\0')" ] || return 1
  done < <(pin_site_entries "$page")
  return 0
}
