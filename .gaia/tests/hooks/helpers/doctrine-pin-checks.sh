# shellcheck shell=bash
#
# Pin-site guards for the workflow doctrine: which files pin a model or a
# dispatch effort, whether every dispatch block carries its pin, and the shared
# regexes. workflow-doctrine-sources.bats and workflow-doctrine-effort-pins.bats
# source this file in setup(); each helper takes the file or root to check, so
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

# The four dispatch-block regexes (ERE, matched with grep -iE). A compact JSON
# example ("effort":"high") and prose such as the per-call `effort` parameter
# or /effort high are never a pin: the first is refused by the leading quote,
# the others lack the colon after the word.
# shellcheck disable=SC2016 # the backticks are literal markdown
EFFORT_PIN_RE='(^|[^"[:alnum:]_])effort[`"]*:[[:space:]]*[`"\\]*(low|medium|high|xhigh|max)([^[:alnum:]_]|$)'
# shellcheck disable=SC2016 # the backticks are literal markdown
MODEL_PIN_RE='(^|[^[:alnum:]_])model[`"]*:[[:space:]]*[`"\\]*(haiku|opus|sonnet|fable)([^[:alnum:]_]|$)'
# shellcheck disable=SC2016 # the backticks are literal markdown
GP_DISPATCH_RE='(spawn|dispatch|launch)[^.;]{0,80}general-purpose|subagent_type[`"]*:[[:space:]]*[`"\\]*general-purpose'
# shellcheck disable=SC2016 # the backticks are literal markdown
SUBAGENT_TYPE_RE='subagent_type[`"]*:[[:space:]]*[`"\\]*[^`"\\[:space:],)]+'

# The planner's session-effort mark (ERE). A dispatch block carrying it runs at
# the session level on purpose: blocks_anchored_pinned_ok exempts it from the
# pin and fails it if it carries one anyway. The exemption is per block, so a
# second dispatch written into a marked block's own paragraph is not seen; that
# is why session_effort_mark_files confines the mark to the planner's file.
SESSION_EFFORT_MARK_RE='runs at the session effort'

# Prints every tracked file outside the doctrine page that pins a model or a
# dispatch effort.
pin_site_files() {
  git -C "$1" grep -l -i -E -e "$PIN_RE" -e "$EFFORT_PIN_RE" -- .claude frontend/.claude wiki .gaia/cli/health \
    ':!wiki/log.md' ':!wiki/hot.md' ':!wiki/meta' ':!wiki/concepts/Workflow Doctrine.md'
}

# Prints every tracked file in the same scan roots, same exclusions, that
# carries the session-effort mark.
session_effort_mark_files() {
  git -C "$1" grep -l -i -E -e "$SESSION_EFFORT_MARK_RE" -- .claude frontend/.claude wiki .gaia/cli/health \
    ':!wiki/log.md' ':!wiki/hot.md' ':!wiki/meta' ':!wiki/concepts/Workflow Doctrine.md'
  return 0
}

# Prints every tracked markdown file in the same scan roots, same exclusions.
scan_root_markdown_files() {
  git -C "$1" ls-files -z -- .claude frontend/.claude wiki .gaia/cli/health \
    ':!wiki/log.md' ':!wiki/hot.md' ':!wiki/meta' ':!wiki/concepts/Workflow Doctrine.md' | tr '\0' '\n' | grep -E '\.md$'
  return 0
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

# Prints the backticked path tokens on the one Pin sites bullet that starts
# with the given prefix.
pin_site_bullet_entries() {
  # shellcheck disable=SC2016 # the backticks are literal markdown
  BULLET_PREFIX="$2" awk '
    BEGIN { prefix = ENVIRON["BULLET_PREFIX"] }
    $0 == "### Pin sites" { on = 1; next }
    on && /^##/ { exit }
    on && index($0, prefix) == 1 { print }
  ' "$1" | grep -oE '`[^`]*/[^`]*`' | tr -d '`'
  return 0
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

# ------------------------------------------------------- agent frontmatter

# Prints a file's frontmatter: the lines between a first-line `---` and the
# next `---`. Prints nothing when line 1 is not `---`.
frontmatter_of() {
  awk '
    NR == 1 { if ($0 != "---") exit; next }
    /^---[[:space:]]*$/ { exit }
    { print }
  ' "$1"
  return 0
}

AGENT_EFFORT_BAD=""
# One frontmatter `effort:` line, a valid level, in every agent file, at least
# one file.
agents_effort_ok() {
  local dir="$1" file_path seen=0 effort_lines
  AGENT_EFFORT_BAD=""
  for file_path in "$dir"/*.md; do
    [ -f "$file_path" ] || continue
    seen=$((seen + 1))
    effort_lines="$(frontmatter_of "$file_path" | grep '^effort:')"
    if [ "$(printf '%s\n' "$effort_lines" | grep -c '^effort:')" != 1 ] ||
      ! printf '%s\n' "$effort_lines" | grep -qE '^effort:[[:space:]]*(low|medium|high|xhigh|max)[[:space:]]*$'; then
      AGENT_EFFORT_BAD="$AGENT_EFFORT_BAD $file_path"
    fi
  done
  [ "$seen" -gt 0 ] || { AGENT_EFFORT_BAD="no agent files in $dir"; return 1; }
  [ -z "$AGENT_EFFORT_BAD" ] || return 1
  return 0
}

# Every agent file's frontmatter `effort:` value equals the level.
agents_effort_level_ok() {
  local dir="$1" level="$2" file_path seen=0 value
  AGENT_EFFORT_BAD=""
  for file_path in "$dir"/*.md; do
    [ -f "$file_path" ] || continue
    seen=$((seen + 1))
    value="$(frontmatter_of "$file_path" | grep '^effort:' | sed -e 's/^effort:[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [ "$value" = "$level" ] || AGENT_EFFORT_BAD="$AGENT_EFFORT_BAD $file_path"
  done
  [ "$seen" -gt 0 ] || { AGENT_EFFORT_BAD="no agent files in $dir"; return 1; }
  [ -z "$AGENT_EFFORT_BAD" ] || return 1
  return 0
}

SKILL_EFFORT_BAD=""
# No SKILL.md frontmatter holds an `effort:` line.
skills_frontmatter_no_effort_ok() {
  local file_path seen=0
  SKILL_EFFORT_BAD=""
  for file_path in "$@"; do
    [ -f "$file_path" ] || { SKILL_EFFORT_BAD="$SKILL_EFFORT_BAD missing:$file_path"; continue; }
    seen=$((seen + 1))
    if frontmatter_of "$file_path" | grep -q '^effort:'; then
      SKILL_EFFORT_BAD="$SKILL_EFFORT_BAD $file_path"
    fi
  done
  [ "$seen" -gt 0 ] || { SKILL_EFFORT_BAD="no skill files given"; return 1; }
  [ -z "$SKILL_EFFORT_BAD" ] || return 1
  return 0
}

# ------------------------------------------------------------- dispatch files

# Prints every tracked file that the three dispatch bullets name (entries may
# be globs). Fails when that set is empty.
dispatch_files() {
  local root="$1" page="$2" prefix entry found
  found="$(
    for prefix in '- Dispatch pins in playbooks:' '- Effort-only dispatch pins in the audit pipelines:' '- Executed wiki pages:'; do
      pin_site_bullet_entries "$page" "$prefix"
    done | while IFS= read -r entry; do
      [ -n "$entry" ] || continue
      git -C "$root" ls-files -z -- "$entry" | tr '\0' '\n'
    done | sort -u
  )"
  [ -n "$found" ] || return 1
  printf '%s\n' "$found"
  return 0
}

# Prints "<number><TAB><text>" for each block of a file: a maximal run of
# non-blank lines with its newlines flattened to spaces.
dispatch_blocks() {
  awk 'BEGIN { RS = "" } { gsub(/\n/, " "); print NR "\t" $0 }' "$1"
}

UNPINNED_BLOCKS=""
# Every block of every file that matches the anchor also matches EFFORT_PIN_RE,
# except a block carrying SESSION_EFFORT_MARK_RE, which must not match it and
# is reported as marked-pinned when it does.
blocks_anchored_pinned_ok() {
  local anchor="$1" file_path block_number block_text
  shift
  UNPINNED_BLOCKS=""
  [ "$#" -gt 0 ] || { UNPINNED_BLOCKS="no files given"; return 1; }
  for file_path in "$@"; do
    [ -f "$file_path" ] || { UNPINNED_BLOCKS="$UNPINNED_BLOCKS missing:$file_path"; continue; }
    grep -qiE -- "$anchor" "$file_path" || continue
    while IFS=$'\t' read -r block_number block_text; do
      printf '%s' "$block_text" | grep -qiE -- "$anchor" || continue
      if printf '%s' "$block_text" | grep -qiE -- "$SESSION_EFFORT_MARK_RE"; then
        if printf '%s' "$block_text" | grep -qiE -- "$EFFORT_PIN_RE"; then
          UNPINNED_BLOCKS="$UNPINNED_BLOCKS marked-pinned:$file_path:$block_number"
        fi
        continue
      fi
      printf '%s' "$block_text" | grep -qiE -- "$EFFORT_PIN_RE" || UNPINNED_BLOCKS="$UNPINNED_BLOCKS $file_path:$block_number"
    done < <(dispatch_blocks "$file_path")
  done
  [ -z "$UNPINNED_BLOCKS" ] || return 1
  return 0
}

NAMED_PINNED_BLOCKS=""
# No block whose subagent_type value is anything but general-purpose (a fork,
# a <member-name> placeholder, a real agent name) carries an effort pin.
named_dispatch_no_effort_ok() {
  local file_path block_number block_text value named
  NAMED_PINNED_BLOCKS=""
  [ "$#" -gt 0 ] || { NAMED_PINNED_BLOCKS="no files given"; return 1; }
  for file_path in "$@"; do
    [ -f "$file_path" ] || { NAMED_PINNED_BLOCKS="$NAMED_PINNED_BLOCKS missing:$file_path"; continue; }
    grep -qiE -- "$SUBAGENT_TYPE_RE" "$file_path" || continue
    while IFS=$'\t' read -r block_number block_text; do
      printf '%s' "$block_text" | grep -qiE -- "$SUBAGENT_TYPE_RE" || continue
      named=0
      while IFS= read -r value; do
        value="$(printf '%s' "${value#*:}" | tr -d '`"\\[:space:]' | tr '[:upper:]' '[:lower:]')"
        [ "$value" = "general-purpose" ] || named=1
      done < <(printf '%s' "$block_text" | grep -oiE -- "$SUBAGENT_TYPE_RE")
      [ "$named" = 1 ] || continue
      if printf '%s' "$block_text" | grep -qiE -- "$EFFORT_PIN_RE"; then
        NAMED_PINNED_BLOCKS="$NAMED_PINNED_BLOCKS $file_path:$block_number"
      fi
    done < <(dispatch_blocks "$file_path")
  done
  [ -z "$NAMED_PINNED_BLOCKS" ] || return 1
  return 0
}

PIPELINE_BAD=""
# Each relative file is covered by a Pin sites entry, carries at least one
# effort pin, and has every model-anchored and general-purpose-anchored block
# pinned.
pipeline_files_ok() {
  local root="$1" page="$2" relative entry covered entries
  shift 2
  PIPELINE_BAD=""
  entries="$(pin_site_entries "$page")"
  [ -n "$entries" ] || { PIPELINE_BAD="no pin site entries"; return 1; }
  [ "$#" -gt 0 ] || { PIPELINE_BAD="no files given"; return 1; }
  for relative in "$@"; do
    if [ ! -f "$root/$relative" ]; then
      PIPELINE_BAD="$PIPELINE_BAD missing:$relative"
      continue
    fi
    covered=0
    while IFS= read -r entry; do
      # shellcheck disable=SC2254 # the entry is a glob on purpose
      case "$relative" in $entry) covered=1 ;; esac
    done <<<"$entries"
    [ "$covered" = 1 ] || PIPELINE_BAD="$PIPELINE_BAD uncovered:$relative"
    grep -qiE -- "$EFFORT_PIN_RE" "$root/$relative" || PIPELINE_BAD="$PIPELINE_BAD nopin:$relative"
    blocks_anchored_pinned_ok "$MODEL_PIN_RE" "$root/$relative" ||
      PIPELINE_BAD="$PIPELINE_BAD model-unpinned:$UNPINNED_BLOCKS"
    blocks_anchored_pinned_ok "$GP_DISPATCH_RE" "$root/$relative" ||
      PIPELINE_BAD="$PIPELINE_BAD gp-unpinned:$UNPINNED_BLOCKS"
  done
  [ -z "$PIPELINE_BAD" ] || return 1
  return 0
}

# The text from `## Caller slots` up to (not including) `## Write and return`
# holds no `effort`, and both headings exist.
lens_preamble_no_effort_ok() {
  local file_path="$1" span
  [ -f "$file_path" ] || return 1
  grep -q '^## Caller slots' "$file_path" || return 1
  grep -q '^## Write and return' "$file_path" || return 1
  span="$(awk '
    /^## Caller slots/ { on = 1 }
    /^## Write and return/ { on = 0 }
    on { print }
  ' "$file_path")"
  [ -n "$span" ] || return 1
  if printf '%s\n' "$span" | grep -qi 'effort'; then return 1; fi
  return 0
}

DESCRIPTIVE_PINNED=""
# No page on the "Descriptive wiki pages" bullet carries an effort pin. A listed
# page that is missing under the root fails, so a stale entry cannot pass.
descriptive_pages_no_pin_ok() {
  local page="$1" root="$2" entry seen=0
  DESCRIPTIVE_PINNED=""
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    seen=$((seen + 1))
    if [ ! -f "$root/$entry" ]; then
      DESCRIPTIVE_PINNED="$DESCRIPTIVE_PINNED missing:$entry"
      continue
    fi
    if grep -qiE -- "$EFFORT_PIN_RE" "$root/$entry"; then
      DESCRIPTIVE_PINNED="$DESCRIPTIVE_PINNED $entry"
    fi
  done < <(pin_site_bullet_entries "$page" '- Descriptive wiki pages')
  [ "$seen" -gt 0 ] || { DESCRIPTIVE_PINNED="no descriptive entries"; return 1; }
  [ -z "$DESCRIPTIVE_PINNED" ] || return 1
  return 0
}
