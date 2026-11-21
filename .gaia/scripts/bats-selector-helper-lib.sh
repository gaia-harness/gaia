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
# A suite also reaches a helper it runs by a path word (`"$HELPERS/make.sh"`)
# when that word names a tracked shell file under a `tests/` or `helpers/`
# directory; a word naming no such file adds nothing.
#
# A helper that copies by glob (`cp`, or a `for ... in` over `"$root"/dir/*.sh`)
# reaches every changed file the glob's tail ends, and a glob this reader cannot
# resolve (`$directory/*.sh`) counts as reaching. A helper that copies a script
# and also greps it reaches whatever that script sources.
#
# Limit: a copy list built any other way (a computed array, a `find`, a name
# read from a file) names no file, so a change to a file it picks is not seen
# here.

bats_selector_helper_suites() {
  local repository_root="$1" tracked_list="$2" pair_list="$3" top_level_list="$4" pattern_list="$5"
  local scratch status
  scratch="$(mktemp -d)" || return 1

  # git grep exits 1 on no match; only a status above 1 is a failure.
  git -C "$repository_root" grep -l -F -f "$pattern_list" -- '*.sh' '*.bash' > "$scratch/matches"
  status=$?
  if [ "$status" -gt 1 ]; then rm -rf "$scratch"; return 1; fi
  grep -E '(^|/)(tests|helpers)/' "$scratch/matches" > "$scratch/candidates"
  : > "$scratch/reaching"
  if [ -s "$scratch/candidates" ]; then
    bats_selector_reaching_suites "$repository_root" "$pair_list" "$top_level_list" "$scratch/candidates" helper-mode > "$scratch/reaching" \
      || { rm -rf "$scratch"; return 1; }
  fi

  git -C "$repository_root" grep -n -I -E '^[[:space:]]*(load|source|\.|bats_load_library)[[:space:]]|[;&|][[:space:]]*(source|\.)[[:space:]]' \
    -- '*.bats' '*.sh' '*.bash' > "$scratch/loads"
  status=$?
  if [ "$status" -gt 1 ]; then rm -rf "$scratch"; return 1; fi

  git -C "$repository_root" grep -n -I -E '(^|[^A-Za-z0-9_])(cp|grep)[[:space:]]|^[[:space:]]*for[[:space:]]' \
    -- '*.sh' '*.bash' > "$scratch/copies"
  status=$?
  if [ "$status" -gt 1 ]; then rm -rf "$scratch"; return 1; fi

  git -C "$repository_root" grep -n -I -E '\.sh([^A-Za-z0-9_.]|$)' -- '*.bats' '*.sh' '*.bash' > "$scratch/invokes"
  status=$?
  if [ "$status" -gt 1 ]; then rm -rf "$scratch"; return 1; fi

  LC_ALL=C awk -v tracked_file="$tracked_list" -v reaching_file="$scratch/reaching" -v pair_file="$pair_list" -v copies_file="$scratch/copies" -v invokes_file="$scratch/invokes" '
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
    function add_edges(from, tail) {
      add_edges_to(from, tail, 0)
    }
    function add_edges_to(from, tail, helpers_only,   base, index_in_base, candidate, fallback) {
      if (tail == "") return
      base = last_segment(tail)
      for (index_in_base = 1; index_in_base <= by_base_count[base]; index_in_base++) {
        candidate = by_base[base, index_in_base]
        if (helpers_only && candidate !~ /(^|\/)(tests|helpers)\//) continue
        if (candidate == tail || substr(candidate, length(candidate) - length(tail)) == "/" tail) link(from, candidate)
      }
      if (base ~ /\.bash$/) {
        fallback = tail; sub(/\.bash$/, ".sh", fallback)
        if (fallback != tail) add_edges_to(from, fallback, helpers_only)
      }
    }
    function add_invoked_edges(from, text,   run, before, remaining) {
      remaining = text
      while (match(remaining, /[A-Za-z0-9_.@+\/-]+\.sh([^A-Za-z0-9_.@+\/-]|$)/)) {
        run = substr(remaining, RSTART, RLENGTH)
        sub(/[^A-Za-z0-9_.@+\/-]$/, "", run)
        before = (RSTART > 1 ? substr(remaining, RSTART - 1, 1) : "")
        remaining = substr(remaining, RSTART + RLENGTH - 1)
        if (before == "$" || before == "{") {
          if (index(run, "/") == 0) continue
          sub(/^[^\/]*/, "", run)
        }
        while (run ~ /^(\.\/|\.\.\/|\/)/) sub(/^(\.\/|\.\.\/|\/)/, "", run)
        if (run != "") add_edges_to(from, run, 1)
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
    # What a glob word names below its root variable, or "?" when another
    # expansion makes it unreadable.
    function glob_tail(word) {
      gsub(/["\047]/, "", word)
      sub(/;+$/, "", word)
      sub(/^\$(\{[A-Za-z_][A-Za-z0-9_]*\}|[A-Za-z_][A-Za-z0-9_]*)/, "", word)
      if (word ~ /[$`(){}]/) return "?"
      sub(/^\/+/, "", word)
      return word
    }
    function glob_regex(glob,   position, character, regex) {
      regex = "(^|/)"
      for (position = 1; position <= length(glob); position++) {
        character = substr(glob, position, 1)
        if (character == "*") regex = regex "[^/]*"
        else if (character == "?") regex = regex "[^/]"
        else if (character ~ /[.+^$|\\()\[\]{}]/) regex = regex "\\" character
        else regex = regex character
      }
      return regex "$"
    }
    function glob_names_a_change(glob,   regex, changed_index) {
      regex = glob_regex(glob)
      for (changed_index = 1; changed_index <= changed_count; changed_index++) {
        if (changed_paths[changed_index] ~ regex) return 1
      }
      return 0
    }
    function closure_has_change(script,   stack, depth, seen, node, i, target) {
      if (script in changed) return 1
      split("", seen); depth = 0
      stack[++depth] = script; seen[script] = 1
      while (depth > 0) {
        node = stack[depth--]
        for (i = 1; i <= out_count[node]; i++) {
          target = out[node, i]
          if (target in changed) return 1
          if (!(target in seen)) { seen[target] = 1; stack[++depth] = target }
        }
      }
      return 0
    }
    # A helper that copies by glob, or by a list derived from a script it
    # copies, reaches every file those name.
    function mark_copying_helpers(   row_index, row, first_colon, remainder, second_colon, helper, text, kind, word_count, words, word_index, word, tail, base, pair_index, path_index) {
      for (row_index = 1; row_index <= copy_row_count; row_index++) {
        row = copy_rows[row_index]
        first_colon = index(row, ":"); remainder = substr(row, first_colon + 1)
        second_colon = index(remainder, ":")
        helper = substr(row, 1, first_colon - 1); text = substr(remainder, second_colon + 1)
        if (text ~ /^[ \t]*cp[ \t]/) kind = "cp"
        else if (text ~ /^[ \t]*for[ \t]/) { kind = "for"; sub(/^[ \t]*for[ \t].*[ \t]in[ \t]/, "", text) }
        else kind = "grep"
        word_count = split(text, words, /[ \t]+/)
        for (word_index = 1; word_index <= word_count; word_index++) {
          word = words[word_index]
          if (kind != "grep" && index(word, "*") > 0) {
            tail = glob_tail(word)
            if (tail == "?" || glob_names_a_change(tail)) reaching[helper] = 1
          }
          gsub(/["\047]/, "", word); sub(/[^A-Za-z0-9_.\/-]+$/, "", word)
          if (word !~ /\.sh$/) continue
          base = last_segment(word)
          if (kind == "cp") copied[helper, base] = 1
          else if (kind == "grep" && (base in by_base_count)) { derive_count++; derive_helper[derive_count] = helper; derive_base[derive_count] = base }
        }
      }
      for (pair_index = 1; pair_index <= derive_count; pair_index++) {
        if (!((derive_helper[pair_index], derive_base[pair_index]) in copied)) continue
        for (path_index = 1; path_index <= by_base_count[derive_base[pair_index]]; path_index++) {
          if (closure_has_change(by_base[derive_base[pair_index], path_index])) reaching[derive_helper[pair_index]] = 1
        }
      }
    }
    BEGIN {
      while ((getline row < reaching_file) > 0) reaching[row] = 1
      close(reaching_file)
      while ((getline row < tracked_file) > 0) {
        if (row ~ /\.(sh|bash)$/) { base_name = last_segment(row); by_base[base_name, ++by_base_count[base_name]] = row }
      }
      close(tracked_file)
      while ((getline row < pair_file) > 0) {
        split(row, columns, "\t")
        if (!(columns[1] in changed)) { changed[columns[1]] = 1; changed_paths[++changed_count] = columns[1] }
      }
      close(pair_file)
      while ((getline row < copies_file) > 0) {
        first_colon = index(row, ":")
        if (substr(row, 1, first_colon - 1) !~ /(^|\/)(tests|helpers)\//) continue
        if (row ~ /^[^:]*:[0-9]+:[ \t]*#/) continue
        copy_rows[++copy_row_count] = row
      }
      close(copies_file)
      while ((getline row < invokes_file) > 0) {
        first_colon = index(row, ":"); remainder = substr(row, first_colon + 1)
        second_colon = index(remainder, ":"); if (!first_colon || !second_colon) continue
        invoke_text = substr(remainder, second_colon + 1)
        if (invoke_text ~ /^[ \t]*#/) continue
        invoke_source = substr(row, 1, first_colon - 1)
        if (invoke_source ~ /\.(bats|sh)$/) add_invoked_edges(invoke_source, invoke_text)
      }
      close(invokes_file)
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
      mark_copying_helpers()
      for (node in out_count) if (node ~ /\.bats$/ && reaches_helper(node)) print node
    }
  ' "$scratch/loads"
  status=$?
  rm -rf "$scratch"
  return "$status"
}
