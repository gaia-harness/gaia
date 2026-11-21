#!/usr/bin/env bash
#
# Sourced by bats-suites-for-change.sh, after bats-selector-reach-lib.sh. Finds
# the suites that reach a changed file only through a file they load, such as a
# helper that copies a script into a fixture repository, so the suite itself
# never names the script.
#
#   bats_selector_helper_suites <repository root> <tracked list> <pair file> <top-level file> <pattern file>
#
# The pair, top-level and pattern files are the ones bats-suites-for-change.sh
# builds. Prints the suites to select, one per line.
# Returns non-zero when git or awk fails; the caller treats that as "the change
# could not be read".
#
# A shell file under a `tests/` or `helpers/` directory naming a changed file's
# match text is judged by the same rules a suite is (bats-selector-reach-lib.sh),
# so a helper that names the file only as fixture data stays ruled out and a
# mention that cannot be ruled out counts. Two rules differ for a helper: a
# comment line is not a mention, since a comment copies nothing, and
# `BATS_TEST_DIRNAME` and `BATS_TEST_FILENAME` are unknown, since bats sets them
# to the loading suite's path and not the helper's. A suite is selected when a file it loads, or a
# file such a file sources in turn, is one that counts. Production code a suite
# sources is the code under test and is not searched.
#
# A `load` or `source` line names its target by a path, and the path is often
# built from a variable. The edge is read from the literal tail after the
# variable (`"$BATS_TEST_DIRNAME/helpers/run-hook.sh"` gives `helpers/run-hook.sh`)
# and joined to every tracked shell file that path ends: a tail shared by two
# files links both, which only over-selects. A target that is only a variable
# (`. "$1"`) has no tail and is not followed.
#
# Limit: a helper that copies a file by glob or by a derived name
# (`cp "$root"/dir/*.sh`, a loop over a computed list) never names the file, so
# a change to such a file is not seen here.

bats_selector_helper_suites() {
  local repository_root="$1" tracked_list="$2" pair_list="$3" top_level_list="$4" pattern_list="$5"
  local scratch status
  scratch="$(mktemp -d)" || return 1

  # git grep exits 1 on no match; only a status above 1 is a failure.
  git -C "$repository_root" grep -l -F -f "$pattern_list" -- '*.sh' '*.bash' > "$scratch/matches"
  status=$?
  if [ "$status" -gt 1 ]; then rm -rf "$scratch"; return 1; fi
  grep -E '(^|/)(tests|helpers)/' "$scratch/matches" > "$scratch/candidates"
  if [ ! -s "$scratch/candidates" ]; then rm -rf "$scratch"; return 0; fi

  bats_selector_reaching_suites "$repository_root" "$pair_list" "$top_level_list" "$scratch/candidates" helper-mode > "$scratch/reaching" \
    || { rm -rf "$scratch"; return 1; }
  if [ ! -s "$scratch/reaching" ]; then rm -rf "$scratch"; return 0; fi

  git -C "$repository_root" grep -n -I -E '^[[:space:]]*(load|source|\.|bats_load_library)[[:space:]]|[;&|][[:space:]]*(source|\.)[[:space:]]' \
    -- '*.bats' '*.sh' '*.bash' > "$scratch/loads"
  status=$?
  if [ "$status" -gt 1 ]; then rm -rf "$scratch"; return 1; fi

  LC_ALL=C awk -v tracked_file="$tracked_list" -v reaching_file="$scratch/reaching" '
    function last_segment(path,   segments, segment_count) {
      segment_count = split(path, segments, "/")
      return segments[segment_count]
    }
    # The literal path a load or source line names, or "" when it has none.
    function load_tail(text,   rest, run, before) {
      if (!match(text, /(^[ \t]*|[;&|][ \t]*)(load|source|bats_load_library|\.)[ \t]+/)) return ""
      rest = substr(text, RSTART + RLENGTH)
      if (match(rest, /[A-Za-z0-9_.@+\/-]+\.(sh|bash)([^A-Za-z0-9_.@+\/-]|$)/)) {
        run = substr(rest, RSTART, RLENGTH)
        sub(/[^A-Za-z0-9_.@+\/-]$/, "", run)
        before = (RSTART > 1 ? substr(rest, RSTART - 1, 1) : "")
        if (before == "$" || before == "{") {
          if (index(run, "/") == 0) return ""
          sub(/^[^\/]*/, "", run)
        }
      } else {
        # `load name` drops the extension: take the first word, when it is a
        # plain literal path.
        run = rest; sub(/[ \t;&|].*/, "", run); gsub(/["\047]/, "", run)
        if (run == "" || run ~ /[^A-Za-z0-9_.@+\/-]/) return ""
        run = run ".bash"
      }
      while (run ~ /^(\.\/|\.\.\/|\/)/) sub(/^(\.\/|\.\.\/|\/)/, "", run)
      return run
    }
    function add_edges(from, tail,   base, index_in_base, candidate, fallback) {
      if (tail == "") return
      base = last_segment(tail)
      for (index_in_base = 1; index_in_base <= by_base_count[base]; index_in_base++) {
        candidate = by_base[base, index_in_base]
        if (candidate == tail || substr(candidate, length(candidate) - length(tail)) == "/" tail) link(from, candidate)
      }
      if (base ~ /\.bash$/) {
        fallback = tail; sub(/\.bash$/, ".sh", fallback)
        if (fallback != tail) add_edges(from, fallback)
      }
    }
    function link(from, to) {
      if ((from SUBSEP to) in linked) return
      linked[from SUBSEP to] = 1
      out_count[from]++
      out[from, out_count[from]] = to
    }
    function reaches_helper(suite,   stack, depth, seen, node, i, target) {
      split("", seen); depth = 0
      stack[++depth] = suite; seen[suite] = 1
      while (depth > 0) {
        node = stack[depth--]
        for (i = 1; i <= out_count[node]; i++) {
          target = out[node, i]
          if (target in reaching) return 1
          if (!(target in seen)) { seen[target] = 1; stack[++depth] = target }
        }
      }
      return 0
    }
    BEGIN {
      while ((getline row < reaching_file) > 0) reaching[row] = 1
      close(reaching_file)
      while ((getline row < tracked_file) > 0) {
        if (row ~ /\.(sh|bash)$/) { base_name = last_segment(row); by_base[base_name, ++by_base_count[base_name]] = row }
      }
      close(tracked_file)
    }
    {
      first_colon = index($0, ":"); if (!first_colon) next
      remainder = substr($0, first_colon + 1)
      second_colon = index(remainder, ":"); if (!second_colon) next
      source_path = substr($0, 1, first_colon - 1)
      line_text = substr(remainder, second_colon + 1)
      if (line_text ~ /^[ \t]*#/) next
      add_edges(source_path, load_tail(line_text))
    }
    END {
      for (node in out_count) if (node ~ /\.bats$/ && reaches_helper(node)) print node
    }
  ' "$scratch/loads"
  status=$?
  rm -rf "$scratch"
  return "$status"
}
