#!/usr/bin/env bash
# audit-machinery.sh: the one machinery path list for the Code Audit Team.
# Sourced, never executed; does no work at source time.
#
# Generating rule: every file whose bytes can change what a member reviews,
# who reviews it, where a clearance lands, or whether a clearance is
# believed. Listing this set here is documentation of intent, not
# enforcement, a bad actor who can rewrite the working tree can rewrite this
# guard too, so treat AUDIT_MACHINERY_PATHS as a naming aid for the roster
# and for review, never as a security boundary on its own.
#
# One literal list, no second copy anywhere. Entries ending in `/**` are
# directory prefixes (every tracked file under them is machinery); an entry
# carrying any other `*` is a pattern whose `*` stays inside one path segment;
# every other entry is an exact path.
#
# Bash 3.2 compatible (macOS default). Never `cd`.

AUDIT_MACHINERY_PATHS="$(cat <<'EOF'
.gaia/audit-ci.yml
.claude/hooks/lib/audit-scope.sh
.claude/hooks/lib/audit-machinery.sh
.claude/hooks/lib/audit-clearance.sh
.gaia/scripts/audit-write-clearance.sh
.gaia/scripts/audit-write-findings.sh
# main-root-lib.sh decides WHERE the gate looks for a clearance
# (pr-merge-audit-check.sh, post-audit-status.sh all resolve their store root
# through it), and audit-key-lib.sh decides the key every findings sidecar and
# re-run ledger is written and read under.
# Both sit squarely inside the generating rule above; without them a change
# to the file that selects the gate's own root rotates only the shell
# member's digest and leaves the markers of the other members standing.
.gaia/scripts/main-root-lib.sh
.gaia/scripts/audit-key-lib.sh
.gaia/scripts/audit-member-digest.sh
# audit-resolve-scope.sh decides what every specialist member reviews and
# whether it self-skips: it derives the review and membership bases and the
# changed-file lists each member acts on.
.gaia/scripts/audit-resolve-scope.sh
.gaia/scripts/resolve-audit-members.sh
.claude/hooks/pr-merge-audit-check.sh
.claude/hooks/post-audit-status.sh
.claude/hooks/lib/**
.gaia/scripts/audit-noop-detect.sh
# The light-review router, the light-marker script and the reviewer definition
# decide whether a clearance is written without the member having run, so a
# change to any of them changes whether a clearance is believed.
# The loop unit definition is not machinery: it orchestrates rounds and writes no clearance (the light-marker script is the only light writer).
.gaia/scripts/audit-light-route.sh
.gaia/scripts/audit-light-mark.sh
.claude/agents/audit-light-reviewer.md
.gaia/scripts/link-worktree.sh
.github/audit/**
# The own definition of every Code Audit Team member, whoever registers it: the
# roster check refuses a member whose name lacks the `code-audit-` prefix, so
# this one pattern covers each member without a per-member line here.
.claude/agents/code-audit-*.md
# These three decide what a frontend clearance vouches for: the rule specialist
# and refuter the frontend member dispatches, and the oracle script it runs.
# The refuter reference needs no entry: the .claude/hooks/lib/** prefix above
# already covers it.
.claude/agents/audit-rule-specialist.md
.claude/agents/audit-refuter.md
.gaia/scripts/audit-frontend-oracles.sh
# gaia:maintainer-only:start
.claude/maintainers/**
.gaia/scripts/tests/fixtures/audit-quick-corpus.json
# gaia:maintainer-only:end
.claude/rules/**
.gaia/VERSION
EOF
)"

# _audit_machinery_pattern_matches <pattern> <path>: a `case` pattern's `*`
# also matches `/`, so equal slash counts are what keep each `*` inside one
# segment (`.claude/agents/code-audit-*.md` must not reach a file one directory
# down). A `#` comment line never matches: no tracked path starts with `#`.
_audit_machinery_pattern_matches() {
  local pattern="$1" path="$2" pattern_slashes path_slashes
  pattern_slashes="${pattern//[!\/]/}"
  path_slashes="${path//[!\/]/}"
  # shellcheck disable=SC2254 # the unquoted pattern is the point: it globs.
  case "$path" in
    $pattern) [ "$path_slashes" = "$pattern_slashes" ] ;;
    *) return 1 ;;
  esac
}

# audit_path_is_machinery <path> -> exit 0 iff the path is in the set above.
audit_path_is_machinery() {
  local path="$1" entry prefix

  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    case "$entry" in
      *"/**")
        prefix="${entry%\*\*}"
        case "$path" in
          "$prefix"*) return 0 ;;
        esac
        ;;
      *"*"*)
        _audit_machinery_pattern_matches "$entry" "$path" && return 0
        ;;
      *)
        [ "$path" = "$entry" ] && return 0
        ;;
    esac
  done <<EOF
$AUDIT_MACHINERY_PATHS
EOF

  return 1
}

# audit_delta_has_machinery: BATCH, paths on stdin; exit 0 iff any path is
# machinery, printing the first hit on stdout.
audit_delta_has_machinery() {
  local path

  while IFS= read -r path; do
    [ -n "$path" ] || continue
    if audit_path_is_machinery "$path"; then
      printf '%s\n' "$path"
      return 0
    fi
  done

  return 1
}

# audit_machinery_flags: BATCH classifier for a path list.
# Reads newline-delimited paths on stdin; prints "<path>\t<0|1>" per NON-EMPTY
# input line (1 = machinery). It parses the AUDIT_MACHINERY_PATHS heredoc into
# shell arrays ONCE, then tests each path against those arrays, so a caller
# classifying every tracked file does not re-read the heredoc once per path the
# way audit_path_is_machinery does. The membership semantics are byte-identical
# to audit_path_is_machinery (exact match, a `/**` directory-prefix match, or a
# one-segment `*` pattern);
# empty input lines are skipped, symmetric with audit_owners_for_paths, so the
# digest walk can align this output line-for-line with that classifier's.
audit_machinery_flags() {
  local entry path prefix hit i ne np
  local exact=() prefixes=() patterns=() npat

  # Parse the heredoc ONCE into exact-path and directory-prefix arrays.
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    case "$entry" in
      *"/**") prefixes[${#prefixes[@]}]="${entry%\*\*}" ;;
      *"*"*)  patterns[${#patterns[@]}]="$entry" ;;
      *)      exact[${#exact[@]}]="$entry" ;;
    esac
  done <<EOF
$AUDIT_MACHINERY_PATHS
EOF

  ne=${#exact[@]}
  np=${#prefixes[@]}
  npat=${#patterns[@]}

  while IFS= read -r path; do
    [ -n "$path" ] || continue
    hit=0
    i=0
    while [ "$i" -lt "$ne" ]; do
      if [ "$path" = "${exact[$i]}" ]; then hit=1; break; fi
      i=$((i + 1))
    done
    if [ "$hit" -eq 0 ]; then
      i=0
      while [ "$i" -lt "$np" ]; do
        prefix="${prefixes[$i]}"
        case "$path" in
          "$prefix"*) hit=1; break ;;
        esac
        i=$((i + 1))
      done
    fi
    if [ "$hit" -eq 0 ]; then
      i=0
      while [ "$i" -lt "$npat" ]; do
        if _audit_machinery_pattern_matches "${patterns[$i]}" "$path"; then hit=1; break; fi
        i=$((i + 1))
      done
    fi
    printf '%s\t%d\n' "$path" "$hit"
  done
}
