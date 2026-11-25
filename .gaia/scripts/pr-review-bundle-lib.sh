#!/usr/bin/env bash
# pr-review-bundle-lib.sh: the selection and extraction helpers behind
# pr-review-bundle.sh. Sourced, never executed; does no work at source time.
# Bash 3.2 compatible (macOS default). Never `cd`.
#
# The caller sources, before calling anything here:
#   .claude/hooks/lib/audit-scope.sh      audit_glob_matches (rule `paths:` globs)
#   .claude/hooks/lib/pr-body-stamp.sh    pr_body_stamp_pattern (the hidden head stamp)
#   .gaia/scripts/pr-body-sections-lib.sh gaia_pr_body_audit_headings (the strip set)
#
#   prb_strip_body                      stdin: PR body; stdout: the body without
#                                       the audit-written sections
#   prb_closed_issues <body>            closed issue numbers, one per line
#   prb_done_when                       stdin: issue body; stdout: every Done-when section
#   prb_spec_sections <spec-path>       the SPEC's success_criteria and ## Behaviors
#   prb_select_rules <root> <changed-files-file>   selected CLAUDE.md and rule paths

# A line opening with an HTML comment whose key starts `gaia:`.
PRB_MARKER_COMMENT_PATTERN='^[[:space:]]*<!--[[:space:]]*gaia:'

# Strips every audit-written section: each heading the shared definition prints,
# with every line under it, up to the next `## ` heading that is not in the set.
# The head-stamp line and the `gaia:` marker comment lines go too, wherever they
# sit. Carriage returns are dropped first, since GitHub stores a body edited in
# its web form with CRLF endings.
prb_strip_body() {
  local headings
  headings="$(gaia_pr_body_audit_headings)"
  # shellcheck disable=SC2154 # pr_body_stamp_pattern comes from the sourced stamp library
  tr -d '\r' | HEADINGS="$headings" STAMP="$pr_body_stamp_pattern" MARKER="$PRB_MARKER_COMMENT_PATTERN" awk '
    BEGIN {
      count = split(ENVIRON["HEADINGS"], listed, "\n")
      for (i = 1; i <= count; i++) strip[listed[i]] = 1
      stamp = ENVIRON["STAMP"]
      marker = ENVIRON["MARKER"]
    }
    {
      line = $0
      heading = line
      sub(/[[:space:]]+$/, "", heading)
      if (line ~ /^## /) skipping = (heading in strip) ? 1 : 0
      if (skipping) next
      if (line ~ stamp || line ~ marker) next
      print line
    }
  '
}

# Closed issue numbers: a number after a closing keyword and `#`, in order of
# first appearance. Written as a pattern, not a word list, so no literal set
# lives here.
prb_closed_issues() {
  printf '%s\n' "$1" | tr -d '\r' \
    | grep -oiE '(^|[^[:alnum:]_])(close[sd]?|fix(e[sd])?|resolve[sd]?)[[:space:]]+#[0-9]+' \
    | sed -E 's/.*#([0-9]+)$/\1/' \
    | awk '!seen[$0]++' || true
}

# Every Done-when section of an issue body: the lines under a heading of level 2
# to 4 reading `Done when` (any case), up to the next heading of the same or
# higher level. A level-1 or level-5 heading is not one. Prints nothing when
# there is none.
prb_done_when() {
  tr -d '\r' | awk '
    {
      level = 0
      if (match($0, /^#+/)) level = RLENGTH
      isheading = (level > 0 && substr($0, level + 1, 1) ~ /[ \t]/)
      if (active && isheading && level <= startlevel) active = 0
      if (isheading) {
        title = substr($0, level + 1)
        gsub(/^[ \t]+|[ \t]+$/, "", title)
        if (level >= 2 && level <= 4 && tolower(title) == "done when") {
          active = 1; startlevel = level; next
        }
      }
      if (active) print
    }
  '
}

# The SPEC's `success_criteria` list from the front matter and its whole
# `## Behaviors` section.
prb_spec_sections() {
  awk '
    NR == 1 && $0 == "---" { infront = 1; next }
    infront && $0 == "---" { infront = 0; incriteria = 0; next }
    infront {
      if ($0 ~ /^success_criteria:/) { incriteria = 1; print; next }
      if (incriteria && $0 ~ /^[^ \t-]/) incriteria = 0
      if (incriteria) print
      next
    }
    /^## Behaviors[ \t]*$/ { inbehaviors = 1; print ""; print; next }
    inbehaviors && /^## / { inbehaviors = 0 }
    inbehaviors { print }
  ' "$1"
}

# Prints the globs of a rule file's `paths:` front matter key, one per line,
# quotes removed. Exit 0 when the key exists (even with no globs), 1 when the
# file has no `paths:` key.
_prb_rule_globs() {
  local output
  output="$(awk -v quote="'" '
    function emit(value) {
      gsub(/^[ \t]+|[ \t]+$/, "", value)
      if (substr(value, 1, 1) == "\"" || substr(value, 1, 1) == quote) value = substr(value, 2)
      n = length(value)
      if (substr(value, n, 1) == "\"" || substr(value, n, 1) == quote) value = substr(value, 1, n - 1)
      if (value != "") print value
    }
    NR == 1 { if ($0 != "---") exit 1; infront = 1; next }
    infront && $0 == "---" { exit (found ? 0 : 1) }
    /^paths:/ {
      found = 1; inlist = 1
      rest = $0; sub(/^paths:[ \t]*/, "", rest)
      gsub(/^\[|\]$/, "", rest)
      count = split(rest, items, ",")
      for (i = 1; i <= count; i++) emit(items[i])
      next
    }
    inlist && /^[ \t]+-/ { item = $0; sub(/^[ \t]+-[ \t]*/, "", item); emit(item); next }
    inlist && /^[^ \t]/ { inlist = 0 }
    END { if (!found) exit 1 }
  ' "$1")" || return 1
  if [ -n "$output" ]; then
    printf '%s\n' "$output"
  fi
  return 0
}

# Whether a rule file applies to the changed paths under its directory.
#   _prb_rule_applies <rule-file> <base-directory-or-empty> <changed-files-file>
_prb_rule_applies() {
  local rule_file="$1" base="$2" changed_file="$3" globs glob changed relative
  if ! globs="$(_prb_rule_globs "$rule_file")"; then
    return 0
  fi
  [ -n "$globs" ] || return 1
  while IFS= read -r changed || [ -n "$changed" ]; do
    [ -n "$changed" ] || continue
    if [ -n "$base" ]; then
      case "$changed" in
        "$base"/*) relative="${changed#"$base"/}" ;;
        *) continue ;;
      esac
    else
      relative="$changed"
    fi
    while IFS= read -r glob || [ -n "$glob" ]; do
      [ -n "$glob" ] || continue
      if audit_glob_matches "$glob" "$relative"; then
        return 0
      fi
    done <<EOF_GLOBS
$globs
EOF_GLOBS
  done <"$changed_file"
  return 1
}

# Prints the selected context paths, sorted and unique: every CLAUDE.md on the
# ancestor chain of a changed path (root included), then every rule file under
# a tracked `.claude/rules/` at any depth with no `paths:` key or with a glob
# matching a changed path taken relative to the directory holding that
# `.claude/`. Candidates come only from `git ls-files`, so ignored trees never
# contribute. A nested rules directory contributes only when a changed path
# lies under the directory that holds it.
prb_select_rules() {
  local root="$1" changed_file="$2" tracked changed directory rule base touched
  tracked="$(git -C "$root" ls-files -z | tr '\0' '\n')" || return 1

  {
    # The ancestor chain of every changed path.
    while IFS= read -r changed || [ -n "$changed" ]; do
      [ -n "$changed" ] || continue
      directory="$changed"
      while :; do
        case "$directory" in
          */*) directory="${directory%/*}" ;;
          *) directory="" ;;
        esac
        if [ -n "$directory" ]; then
          printf '%s\n' "$directory/CLAUDE.md"
        else
          printf '%s\n' "CLAUDE.md"
          break
        fi
      done
    done <"$changed_file" | sort -u | grep -xF -f <(printf '%s\n' "$tracked") || true

    printf '%s\n' "$tracked" | grep -E '(^|/)\.claude/rules/.+\.md$' | while IFS= read -r rule; do
      case "$rule" in
        .claude/rules/*) base="" ;;
        *) base="${rule%%/.claude/rules/*}" ;;
      esac
      if [ -n "$base" ]; then
        touched=0
        while IFS= read -r changed || [ -n "$changed" ]; do
          case "$changed" in "$base"/*) touched=1; break ;; esac
        done <"$changed_file"
        [ "$touched" -eq 1 ] || continue
      fi
      if _prb_rule_applies "$root/$rule" "$base" "$changed_file"; then
        printf '%s\n' "$rule"
      fi
    done
  } | sort -u
}
