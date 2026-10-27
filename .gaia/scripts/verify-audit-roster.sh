#!/usr/bin/env bash
# SC2016 is intentional file-wide: single-quoted printf format strings where any
# $ or backtick is literal output text, not a shell expansion.
# shellcheck disable=SC2016
# verify-audit-roster.sh: the Code Audit Team roster's deterministic check.
#
# The roster is meant to grow, by adopters and by the maintainer, as a project
# adds languages and surfaces. Its silent failure modes, each made loud here:
#
#   * A member's own definition disagreeing with the roster about what it owns.
#     Claiming less makes a dispatched member self-skip work it was sent to do;
#     claiming more makes a file read as covered while dispatching nobody, so
#     the diff clears the merge gate having been reviewed by no one.
#   * A tracked path no member's globs match and no `unowned:` entry declares.
#     It resolves an empty dispatched set, which the merge gate reads as
#     nothing owed, so the diff merges reviewed by no one.
#
# Reads live state, never writes: no API write, no file write, no git mutation.
# One finding block per violation on stdout; exit 1 if any fired. `--emit-roster`
# is a read-only output mode the remit writer (write-audit-remits.sh) consumes
# to obtain the roster's raw globs.
#
# The invariants:
#
#   1. Remit region parity. Every member's agent definition carries exactly one
#      balanced remit region, and the globs inside it are that member's roster
#      globs, complete and in roster order. A region that is absent, duplicated,
#      unbalanced, or reversed (its end marker appearing before its start
#      marker) fails; so does a roster glob the region omits, a region glob
#      the roster does not grant, and the same set in a different order, because
#      ownership is first-match-wins over roster order and a reordered region is
#      a different reading order. Every glob inside a region is classified by
#      the bounded dialect below, the default member's and a lone claimant's
#      included. The region's SENTENCE text is deliberately not
#      compared here; the writer (write-audit-remits.sh) owns the region's exact
#      form, and re-running it is the repair for every finding in this group.
#   2. Coverage: every tracked path resolves an owner, or is declared in the
#      roster's `unowned:` list. The inverse of (1), which asks whether the
#      roster's entries are well-formed and never asks whether they reach the
#      repository at all. An `unowned:` entry reaching an owned path fails as
#      overbroad, which is what stops the list being a free opt-out. The
#      section's own docblock below carries the reasoning, including why the
#      universe is the tracked files of the repository ROOTED AT --root and
#      nothing wider. On an adopter clone, an unclaimed path under the
#      harness trees is not counted as ownerless (see `harness_prefixes`).
#   3. Roster-reader drift: this check's raw-glob scrape and the classifier's
#      compiled globs must agree per member on the count. On drift the
#      remit-parity, unowned-dialect and light_hard_full dialect-and-coverage
#      verdicts are withheld; region-shape and coverage verdicts still render.
#   4. Light-review keys. Every member carrying `light_review`,
#      `light_line_cap` or `light_hard_full` states them in a form the router
#      can trust: `light_review` is the literal `true` or `false`;
#      `light_line_cap` is a positive integer no greater than 50 (the router
#      clamps a larger value, so the roster would state a cap that does not
#      apply); every `light_hard_full` glob fits the bounded dialect below and
#      lies inside the member's own globs, because a hard-Full glob the member
#      does not own can never be reached by that member's diff. Coverage is
#      decided as: identical to an owned glob, or under an owned glob's literal
#      `<prefix>/**`, or a wildcard-free path the classifier's own matcher
#      (audit_glob_matches) places inside an owned glob. Any other shape is
#      reported as undecidable, never passed.
#   5. Member registration. Every member's name starts with `code-audit-`,
#      the prefix the audit loop's hook reads to tell a member from any other
#      agent, and every member's agent definition is in AUDIT_MACHINERY_PATHS,
#      so an edit to a member's own instructions rotates every member's digest
#      instead of merging unreviewed by the member it rewrites.
#   6. Zero-match globs. Every remit glob and every `unowned:` glob matches at
#      least one tracked file, unless it sits on the allowlist inside this
#      script. A roster comment never exempts a glob. Runs with the coverage
#      invariant and is skipped with it.
#   7. The release-skip key. A member carrying `skip_gaia_release_changes`
#      states it as the literal `true` or `false`, and the default member does
#      not carry it. The classifier honors only a literal `true`, so any other
#      spelling would read as opted in here and not there. The raw scrape's set
#      of `true` members must also equal the classifier's
#      (audit_roster_release_skip_members); a disagreement is roster-reader
#      drift and withholds the same verdicts as a glob-count disagreement.
#
# This check classifies the whole tracked tree with no diff, so the classifier's
# release context is never armed here: zero-match, coverage and OVERBROAD read
# raw owners, which is also the post-skip answer for every state that applies
# no GAIA release.
#
# A retired member-level key left in an adopter's roster is an ordinary scalar
# to both readers here: they end the `globs:` list on it and read nothing from
# it, so a roster that still carries one verifies the same as one without.
#
# THE BOUNDED DIALECT a glob must fit to be classified. The classifier compiles
# three constructs (glob_to_regex, in the roster module sourced below):
#
#   literal  -> escaped literal   itself
#   *        -> [^/]*             any run within one segment, never crossing /
#   **       -> .*                anything, including /
#   **/      -> (.*/)?            any depth, INCLUDING zero segments
#
# Over that dialect a glob is a sequence of path segments, where each segment
# either matches exactly one path segment (a pattern of literals and single
# `*`s) or is a whole-segment `**` matching a run of segments: zero or more when
# a segment follows it, one or more when it ends the glob.
#
# THE FRAGMENT THIS CHECK DECIDES, stated exactly, because a maintainer who
# teaches the classifier a new construct must teach it here too:
#
#   ACCEPTED: a glob whose `/`-separated segments are each either the whole
#   segment `**`, or a non-empty pattern of literal characters and single `*`s.
#
#   REJECTED as undecidable, never passed: an empty glob or an empty segment
#   (`a//b`, a leading or trailing `/`); any of ? [ ] { } or \, which a reader may
#   intend as wildcards and which the classifier does not compile as one (it
#   escapes them into literals, except `?`, which it leaves as a regex
#   quantifier);
#   `**` inside a segment rather than as a whole one (`app/**.ts`), whose
#   compiled form the segment model cannot represent; a run of three or more
#   `*`; whitespace, which the classifier's record contract cannot carry.
#
# Do not extend the dialect here, and do not make this checker cleverer than the
# classifier. The undecidable-glob failure, in whichever position reads it, is
# what makes a dialect drift loud instead of silent.
#
# DO NOT add `set -e` (matches verify-required-checks.sh): the loops below rely
# on grep and comparison exit status without aborting the script.
#
# Bash 3.2 compatible (macOS default): no associative arrays, no `mapfile`, no
# `${var^^}`. The script's own working directory never moves: both `cd`s are
# inside command substitutions, so each ends with its subshell -- the source-time
# lib resolution, and the coverage guard's `$(cd … && pwd -P)` pair, whose `-P`
# is what makes that a symlink-normalized comparison rather than a string
# compare. Never `cd` in the script's own shell.
set -uo pipefail

usage() {
  cat <<'USAGE'
Usage: verify-audit-roster.sh [--root <dir>] [--config <file>] [--emit-roster]
  --root <dir>     repo root. Default: the repo holding this script.
                   Injection point for the machinery list and the agent files.
  --config <file>  roster to verify. Default: <root>/.gaia/audit-ci.yml.
                   Injection point for the roster.
  --emit-roster    print the roster's raw member/glob/release-skip/default
                   records and exit; read-only, runs no invariant.
  --help | -h      this text.

Exit codes:
  0  every invariant holds. With --emit-roster: always, once the roster parses.
  1  at least one invariant is violated (one finding block per violation).
  2  usage error.
USAGE
}

root=""
config=""
emit_roster=0

while [ $# -gt 0 ]; do
  case "$1" in
    --help|-h)
      usage
      exit 0
      ;;
    --emit-roster)
      emit_roster=1
      shift
      ;;
    --root|--config)
      if [ $# -lt 2 ]; then
        printf 'verify-audit-roster: %s needs a value\n' "$1" >&2
        exit 2
      fi
      case "$1" in
        --root)   root="$2" ;;
        --config) config="$2" ;;
      esac
      shift 2
      ;;
    *)
      printf 'verify-audit-roster: unknown argument: %s\n' "$1" >&2
      exit 2
      ;;
  esac
done

if [ -z "$root" ]; then
  root="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel 2>/dev/null || true)"
fi
if [ -z "$root" ]; then
  printf 'verify-audit-roster: could not resolve the repo root (pass --root)\n' >&2
  exit 2
fi
[ -n "$config" ] || config="${root}/.gaia/audit-ci.yml"
if [ ! -f "$config" ]; then
  printf 'verify-audit-roster: roster not found: %s\n' "$config" >&2
  exit 2
fi

# Source the roster-parsing module from THIS script's own on-disk location,
# never cwd and never $root: it is code, and there is one copy of it.
# .gaia/scripts -> ../../.claude/hooks/lib. Note the asymmetry with the
# machinery list below, which resolves under --root because it is data a
# fixture must be able to inject.
_self_library_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.claude/hooks/lib" 2>/dev/null && pwd)" || true
if [ -n "${_self_library_directory:-}" ] && [ -f "$_self_library_directory/audit-scope.sh" ]; then
  # shellcheck source=/dev/null
  . "$_self_library_directory/audit-scope.sh"
fi

if ! command -v _audit_scope_parse_light >/dev/null 2>&1 || ! command -v audit_glob_matches >/dev/null 2>&1; then
  printf 'verify-audit-roster: light-review roster reader unavailable in the roster-parsing library\n' >&2
  exit 1
fi

if ! command -v _audit_scope_parse_auditors >/dev/null 2>&1; then
  printf 'verify-audit-roster: roster-parsing library unavailable\n' >&2
  exit 1
fi

findings=0

# --- The raw-glob reader -----------------------------------------------------
#
# The classifier emits COMPILED regexes; the remit-region parity comparison
# needs the RAW globs, and a raw-glob record would be a field no router reads,
# carried by every consumer, to serve this one caller. So this reads the glob
# strings itself. It is a YAML list-item scrape, not a second classifier: it
# never compiles, never matches a path, and never decides an owner. The one
# question with a real answer, which member is the default, still comes from
# the module. The two readers are held in lockstep by the per-member
# glob-count comparison below, and drift between them fails loudly rather than
# producing a verdict neither reader stands behind.
#
# Emits, tab-separated so a glob may legally contain a space:
#   MEMBER <name>
#   RAW <name> <glob>
#   RELEASESKIP <name> <raw value>   (only a member carrying the key; the value
#                                     is comment-stripped, never unquoted)

_verify_roster_read_globs() {
  awk '
    function unquote(text) {
      if (text ~ /^".*"$/) return substr(text, 2, length(text) - 2)
      if (text ~ /^'\''.*'\''$/) return substr(text, 2, length(text) - 2)
      return text
    }
    BEGIN { OFS = "\t"; in_auditors = 0; in_globs = 0; member = "" }
    {
      raw = $0
      if (raw ~ /^auditors[[:space:]]*:/) { in_auditors = 1; next }
      if (!in_auditors) next
      # Any other top-level key closes the block.
      if (raw ~ /^[A-Za-z_]/) { in_auditors = 0; in_globs = 0; next }
      # Blank lines and comments (the maintainer-only markers included) never
      # end a member or the block.
      if (raw ~ /^[[:space:]]*$/) next
      if (raw ~ /^[[:space:]]*#/) next
      if (raw ~ /^[[:space:]]*-[[:space:]]+name[[:space:]]*:/) {
        in_globs = 0
        member_name_text = raw
        sub(/^[[:space:]]*-[[:space:]]+name[[:space:]]*:[[:space:]]*/, "", member_name_text)
        sub(/[[:space:]]+#.*$/, "", member_name_text)
        sub(/^[[:space:]]+/, "", member_name_text); sub(/[[:space:]]+$/, "", member_name_text)
        member = unquote(member_name_text)
        print "MEMBER", member
        next
      }
      if (raw ~ /^[[:space:]]+globs[[:space:]]*:/) { in_globs = 1; next }
      if (raw ~ /^[[:space:]]+skip_gaia_release_changes[[:space:]]*:/) {
        in_globs = 0
        skip_text = raw
        sub(/^[[:space:]]+skip_gaia_release_changes[[:space:]]*:[[:space:]]*/, "", skip_text)
        sub(/[[:space:]]+#.*$/, "", skip_text)
        sub(/[[:space:]]+$/, "", skip_text)
        print "RELEASESKIP", member, skip_text
        next
      }
      # Any other member-level scalar key ends the glob sublist.
      if (raw ~ /^[[:space:]]+[A-Za-z_]+[[:space:]]*:/) { in_globs = 0; next }
      if (in_globs && raw ~ /^[[:space:]]*-[[:space:]]+/) {
        glob = raw
        sub(/^[[:space:]]*-[[:space:]]+/, "", glob)
        sub(/[[:space:]]+#.*$/, "", glob)
        sub(/^[[:space:]]+/, "", glob); sub(/[[:space:]]+$/, "", glob)
        glob = unquote(glob)
        if (glob != "") print "RAW", member, glob
        next
      }
    }
  '
}

# --- The remit-region reader -------------------------------------------------
#
# Each member's agent definition carries one marker-delimited remit region, and
# the globs bulleted inside it are what the dispatched member filters its
# changed-file list against. This reads that region back so the parity invariant
# can compare it to the roster. Shape only: it never interprets a glob and never
# reads the region's sentence, which is the writer's to own.
#
# Emits, tab-separated so a glob may legally contain a space:
#   REGIONMISSING <name> <agent-rel>
#   REGIONDUP <name> <agent-rel> <start_marker_count> <end_marker_count>
#   REGIONUNBALANCED <name> <agent-rel> <start_marker_count> <end_marker_count>
#   REGIONREVERSED <name> <agent-rel> <start-line> <end-line>
#   REGIONOK <name>
#   REGION <name> <glob>

REMIT_START='<!-- gaia:audit-remit:start -->'
REMIT_END='<!-- gaia:audit-remit:end -->'

# shellcheck disable=SC2329  # called from verify-audit-roster-registration.sh
_verify_roster_read_regions() {
  # <root> <raw-records>
  local repo_root="$1" records="$2" kind name agent_relative_path agent start_marker_count end_marker_count start_line end_line
  while IFS=$'\t' read -r kind name; do
    [ "$kind" = "MEMBER" ] || continue
    [ -n "$name" ] || continue
    agent_relative_path=".claude/agents/${name}.md"
    agent="${repo_root}/${agent_relative_path}"
    # A member with no definition at all fails loud at dispatch time, so a
    # region finding piled on top of that is noise; every fixture that deletes
    # an agent file depends on this.
    [ -f "$agent" ] || continue
    # grep -c prints 0 and exits 1 on no match, and this script carries no
    # `set -e`; the `|| true` says so rather than leaving it to be inferred.
    start_marker_count="$(grep -cxF -- "$REMIT_START" "$agent" || true)"
    end_marker_count="$(grep -cxF -- "$REMIT_END" "$agent" || true)"
    if [ "$start_marker_count" -eq 0 ] && [ "$end_marker_count" -eq 0 ]; then
      printf 'REGIONMISSING\t%s\t%s\n' "$name" "$agent_relative_path"
    elif [ "$start_marker_count" -gt 1 ] || [ "$end_marker_count" -gt 1 ]; then
      printf 'REGIONDUP\t%s\t%s\t%s\t%s\n' "$name" "$agent_relative_path" "$start_marker_count" "$end_marker_count"
    elif [ "$start_marker_count" -ne "$end_marker_count" ]; then
      printf 'REGIONUNBALANCED\t%s\t%s\t%s\t%s\n' "$name" "$agent_relative_path" "$start_marker_count" "$end_marker_count"
    else
      start_line="$(grep -nxF -- "$REMIT_START" "$agent" | cut -d: -f1)"
      end_line="$(grep -nxF -- "$REMIT_END" "$agent" | cut -d: -f1)"
      if [ "$start_line" -gt "$end_line" ]; then
        printf 'REGIONREVERSED\t%s\t%s\t%s\t%s\n' "$name" "$agent_relative_path" "$start_line" "$end_line"
      else
        printf 'REGIONOK\t%s\n' "$name"
        # A marker state machine over the file, capturing every `- ` + backtick
        # bullet strictly between the pair, in file order. A line between the
        # markers that is not a bullet (the blank line, the canonical sentence)
        # contributes nothing.
        awk -v start_marker="$REMIT_START" -v end_marker="$REMIT_END" -v member="$name" '
          BEGIN { OFS = "\t" }
          $0 == start_marker { in_region = 1; next }
          $0 == end_marker { in_region = 0; next }
          in_region && match($0, /^- `.*`$/) { print "REGION", member, substr($0, 4, length($0) - 4) }
        ' "$agent"
      fi
    fi
  done < <(printf '%s\n' "$records")
}

class_records="$(_audit_scope_parse_auditors < "$config")"
raw_records="$(_verify_roster_read_globs < "$config")"

# --- Read-only roster emit ---------------------------------------------------
#
# The writer (.gaia/scripts/write-audit-remits.sh) needs the roster's RAW globs
# to generate each member's remit region. This mode is how it gets them: the
# scrape above is deliberately a second, independent reader of the same YAML, and
# the roster-reader-drift invariant is exactly the comparison between it and the
# classifier, so the writer reuses this reader rather than adding a third. Still
# read-only: it prints and exits before any invariant runs, and writes nothing.
if [ "$emit_roster" -eq 1 ]; then
  printf '%s\n' "$raw_records"
  printf '%s\n' "$class_records" |
    awk '$1 == "DEFAULT" { printf "DEFAULT\t%s\n", $2 }'
  exit 0
fi

# The invariants live in siblings beside this file, verify-audit-roster-<name>.sh,
# each one contiguous span with its own header, sourced here in their original
# order. A missing or cut-short one would skip its invariants and report the
# roster clean, so every sibling must exist before any runs and must reach its
# last line once sourced (bash 3.2 can stop part way through a file it cannot
# parse and carry on); either failure exits 1, never clean.
_verify_roster_sibling_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)" || _verify_roster_sibling_directory=''
_verify_roster_siblings='registration dialect keys coverage'
for _verify_roster_sibling in $_verify_roster_siblings; do
  if [ -z "$_verify_roster_sibling_directory" ] || [ ! -f "$_verify_roster_sibling_directory/verify-audit-roster-$_verify_roster_sibling.sh" ]; then
    printf 'verify-audit-roster: cannot load verify-audit-roster-%s.sh: it is missing beside this script\n' "$_verify_roster_sibling" >&2
    exit 1
  fi
done
for _verify_roster_sibling in $_verify_roster_siblings; do
  _verify_roster_sibling_loaded=''
  # shellcheck source=/dev/null
  . "$_verify_roster_sibling_directory/verify-audit-roster-$_verify_roster_sibling.sh"
  if [ "$_verify_roster_sibling_loaded" != "$_verify_roster_sibling" ]; then
    printf 'verify-audit-roster: cannot load verify-audit-roster-%s.sh: it stopped before its last line\n' "$_verify_roster_sibling" >&2
    exit 1
  fi
done

if [ "$findings" -gt 0 ]; then
  printf 'verify-audit-roster: %d invariant violation(s).\n' "$findings"
  exit 1
fi

printf 'verify-audit-roster: roster clean (%s).\n' "$config"
exit 0
