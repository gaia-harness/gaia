#!/usr/bin/env bash
#
# Sourced by bats-suites-for-change.sh. Decides, for each suite that contains a
# changed file's match text, whether any occurrence of that text can be the
# real file, so a suite that names a changed file only as fixture data, or
# names a different file sharing the basename, is not selected.
#
#   bats_selector_reaching_suites <repository root> <pair file> <top-level file> <suite list> [helper-mode]
#
# <pair file> holds `<changed path><TAB><match text>` lines, <top-level file>
# the tracked top-level names, <suite list> the name-matched suites (repo-relative).
# A non-empty helper-mode reads <suite list> as helper files: comment lines are not
# mentions and BATS_TEST_DIRNAME/FILENAME are unknown. Prints the files that stay selected, in input order.
# Returns non-zero only when awk itself fails; the caller reads that as "the change could not be read".
#
# A suite is dropped only when every occurrence of every match text in it,
# comment lines included and `@test` names excepted, is proven not to be the
# changed file. Anything this cannot decide keeps the suite: that is the safe
# direction, because a wrong drop hides a red until the push-to-main full run,
# while a wrong keep only costs run time. An occurrence is proven not the file
# when:
#
#   - the text runs on into a longer name (`settings.json.bak`);
#   - it is a literal absolute path, or a relative literal that is not a
#     trailing part of the changed path (`gaia-debt/SKILL.md` for
#     `.claude/skills/gaia-wiki/SKILL.md`), so no working directory makes it
#     the changed file;
#   - it follows a variable whose repo directory the suite fixes
#     (`REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"`,
#     `SCRIPTS="$REPO_ROOT/.gaia/scripts"`) and the joined path is a different
#     file;
#   - it follows a fixture root the suite itself writes that path under. A
#     fixture root is a variable every assignment of which comes from
#     `mktemp`, a bats temporary directory, or another fixture root, that no
#     line populates from outside the fixture, and that the suite writes the
#     path under with a redirection, `touch` or `tee`;
#   - it is the target of a truncating redirection (`> "$FIXTURE/CHANGELOG.md"`)
#     through no variable fixed to a repo directory, which overwrites the file
#     without reading it.
#
# A line populates a fixture root, and so taints it, when it carries the root
# and copies, links, moves, unpacks or checks out into it from anything that is
# not a fixture root (such as cp, rsync, ln, mv, tar, unzip, or a git clone,
# worktree, archive or checkout not run with `-C` on a fixture), when it also
# carries a variable fixed to a repo directory that holds a changed path, or
# when it carries a bare repo path (`.claude/...`). Passing the root to a suite
# function whose body does any of those taints it the same way. A suite that
# sources or `load`s any file has no fixture roots at all, since a helper can
# set or populate one where this cannot read it.
#
# Limit: a script under test that copies a real file into a fixture root the
# suite wrote first, overwriting it, is not seen. The push-to-main full run
# backstops it, as it backstops a suite reaching a file through a spelling the
# match text is not part of.

bats_selector_reaching_suites() {
  LC_ALL=C awk -v root="$1" -v pair_file="$2" -v top_file="$3" -v suite_list="$4" -v helper_mode="${5:-}" '
    function normalize(path,   parts, count, i, out, depth, stack) {
      count = split(path, parts, "/")
      depth = 0
      for (i = 1; i <= count; i++) {
        if (parts[i] == "" || parts[i] == ".") continue
        if (parts[i] == "..") { if (depth == 0) return "\001"; depth--; continue }
        stack[++depth] = parts[i]
      }
      out = ""
      for (i = 1; i <= depth; i++) out = out (i > 1 ? "/" : "") stack[i]
      return out
    }
    function is_suffix_path(short, long) {
      return short == long || substr("/" long, length(long) + 2 - length(short) - 1) == "/" short
    }
    function reset_suite() {
      split("", lines); split("", is_comment); split("", kind_list); split("", fixture)
      split("", tainted); split("", written); split("", root_path); split("", root_unknown)
      split("", defined_function); split("", populator); split("", nonfixture)
      line_count = 0; has_source = 0
    }
    function referenced_names(text, names,   rest, name, count) {
      split("", names); count = 0; rest = text
      while (match(rest, /\$\{?[A-Za-z_][A-Za-z0-9_]*/)) {
        name = substr(rest, RSTART, RLENGTH); sub(/^\$\{?/, "", name)
        names[name] = 1; count++
        rest = substr(rest, RSTART + RLENGTH)
      }
      return count
    }
    function strip_head(text) {
      while (1) {
        if (substr(text, 1, 1) == "\"") text = substr(text, 2)
        else if (text ~ /^[ \t]/) sub(/^[ \t]+/, "", text)
        else if (substr(text, 1, 2) == "$(") text = substr(text, 3)
        else if (text ~ /^cd[ \t]+/) sub(/^cd[ \t]+/, "", text)
        else break
      }
      return text
    }
    # Records one assignment of `name` whose right-hand side starts `value`.
    function record_assignment(name, value, suite_directory,   head, base, tail, rest, dependency) {
      if (value ~ /^(""|'"''"'|[ \t;)&|]|$)/) return
      head = strip_head(value)
      kind_count[name]++
      if (head ~ /^mktemp([ \t)"]|$)/ || head ~ /^\$\{?BATS_(TEST|FILE|RUN|SUITE)_TMPDIR([^A-Za-z0-9_]|$)/) {
        kind_list[name, kind_count[name]] = "base"
      } else if (match(head, /^\$\{?[A-Za-z_][A-Za-z0-9_]*\}?/)) {
        dependency = substr(head, 1, RLENGTH); gsub(/[${}]/, "", dependency)
        kind_list[name, kind_count[name]] = "dep:" dependency
      } else {
        kind_list[name, kind_count[name]] = "non"
      }
      # The repo directory the value fixes, when its shape allows: a bats
      # directory variable or another fixed variable, then literal path
      # characters, then the end of the word.
      # Any command substitution other than the cd and dirname forms decided
      # below runs code this cannot read, so the directory it yields is unknown.
      if (value ~ /^"?\$\(/ && value !~ /^"?\$\([ \t]*(cd|dirname)[ \t]/) { root_unknown[name] = 1; return }
      base = ""
      if (helper_mode != "" && head ~ /BATS_TEST_(DIRNAME|FILENAME)/) { root_unknown[name] = 1; return }
      if (match(head, /^\$\{?BATS_TEST_DIRNAME\}?/)) base = suite_directory
      else if (head ~ /^dirname[ \t]+"?\$\{?BATS_TEST_FILENAME\}?"?\)/) { base = suite_directory; sub(/^dirname[ \t]+"?\$\{?BATS_TEST_FILENAME\}?"?\)/, "", head); RSTART = 1; RLENGTH = 0 }
      else if (match(head, /^\$\{?[A-Za-z_][A-Za-z0-9_]*\}?/)) {
        dependency = substr(head, 1, RLENGTH); gsub(/[${}]/, "", dependency)
        base = "\002" dependency
      } else { root_unknown[name] = 1; return }
      tail = substr(head, RSTART + RLENGTH)
      if (!match(tail, /^[A-Za-z0-9_.@+\/-]*/)) { root_unknown[name] = 1; return }
      rest = substr(tail, RLENGTH + 1); tail = substr(tail, 1, RLENGTH)
      if (value ~ /^"?\$\([ \t]*cd[ \t]/) {
        # A cd substitution fixes the directory only when its command is a
        # bare pwd (or pwd -P); a path tail after the closing paren joins on.
        if (!match(rest, /^"?[ \t]*&&[ \t]*pwd([ \t]+-P)?[ \t]*\)/)) { root_unknown[name] = 1; return }
        rest = substr(rest, RLENGTH + 1)
        if (match(rest, /^\/[A-Za-z0-9_.@+\/-]*/)) { tail = tail substr(rest, 1, RLENGTH); rest = substr(rest, RLENGTH + 1) }
      }
      if (rest !~ /^["\047)]*([ \t;|&]|$)/) { root_unknown[name] = 1; return }
      root_candidate[name, kind_count[name]] = base SUBSEP tail
    }
    function resolve_roots(suite_directory,   changed, name, i, parts, base, value, settled, round) {
      for (round = 0; round < 8; round++) {
        changed = 0
        for (name in kind_count) {
          if ((name in root_path) || (name in root_unknown)) continue
          settled = 1; value = ""
          for (i = 1; i <= kind_count[name]; i++) {
            if (!((name, i) in root_candidate)) { root_unknown[name] = 1; changed = 1; settled = 0; break }
            split(root_candidate[name, i], parts, SUBSEP)
            base = parts[1]
            if (substr(base, 1, 1) == "\002") {
              base = substr(base, 2)
              if (base in root_unknown) { root_unknown[name] = 1; changed = 1; settled = 0; break }
              if (!(base in root_path)) { settled = 0; break }
              base = root_path[base]
            }
            parts[1] = normalize(base "/" parts[2])
            if (parts[1] == "\001" || (value != "" && value != parts[1])) { root_unknown[name] = 1; changed = 1; settled = 0; break }
            value = parts[1]; if (value == "") value = "\003"
          }
          if (settled) { root_path[name] = (value == "\003" ? "" : value); changed = 1 }
        }
        if (!changed) break
      }
      for (name in kind_count) if (!(name in root_path)) root_unknown[name] = 1
    }
    function resolve_fixtures(   changed, name, i, kind, all_fixture, round) {
      for (round = 0; round < 8; round++) {
        changed = 0
        for (name in kind_count) {
          if ((name in fixture) || (name in nonfixture)) continue
          all_fixture = 1
          for (i = 1; i <= kind_count[name]; i++) {
            kind = kind_list[name, i]
            if (kind == "base") continue
            if (kind ~ /^dep:/ && (substr(kind, 5) in fixture)) continue
            all_fixture = 0; break
          }
          if (all_fixture) { fixture[name] = 1; changed = 1 }
        }
        if (!changed) break
      }
    }
    # True when a variable in `names` is fixed to a repo directory holding a
    # changed path.
    function carries_repo_directory(names,   name, i, directory) {
      for (name in names) {
        if (!(name in root_path)) continue
        directory = root_path[name]
        if (directory == "") return 1
        for (i = 1; i <= pair_count; i++) if (index(pair_path[i], directory "/") == 1) return 1
      }
      return 0
    }
    function carries_bare_repo_path(text,   count, i, words, word, first) {
      count = split(text, words, /[ \t"'"'"'=(:;|&<>]+/)
      for (i = 1; i <= count; i++) {
        word = words[i]
        if (word == "" || substr(word, 1, 1) == "$" || substr(word, 1, 1) == "-") continue
        first = word; sub(/\/.*/, "", first)
        if (first in top) return 1
      }
      return 0
    }
    # True when the segment after a populating command has an argument that
    # does not start with a fixture root.
    function populates_from_outside(segment,   count, i, words, word, name) {
      sub(/[;&|>].*/, "", segment)
      count = split(segment, words, /[ \t]+/)
      for (i = 1; i <= count; i++) {
        word = words[i]; gsub(/"/, "", word)
        if (word == "" || substr(word, 1, 1) == "-") continue
        if (!match(word, /^\$\{?[A-Za-z_][A-Za-z0-9_]*/)) return 1
        name = substr(word, RSTART, RLENGTH); sub(/^\$\{?/, "", name)
        if (!(name in fixture)) return 1
      }
      return 0
    }
    function line_populates(text,   names, name, segment, all_fixture) {
      referenced_names(text, names)
      if (carries_repo_directory(names) || carries_bare_repo_path(text)) return 1
      if (match(text, /(^|[ \t;&|(`"])(cp|rsync|ln|mv|tar|install|ditto|unzip|patch)[ \t]/)) {
        segment = substr(text, RSTART + RLENGTH)
        if (populates_from_outside(segment)) return 1
      }
      if (text ~ /(^|[ \t;&|(`"])git[ \t]/ && text ~ /[ \t](clone|worktree|archive|checkout|restore|show|cat-file|pull|fetch|stash|reset|read-tree|checkout-index|apply|am|cherry-pick|merge|rebase|switch)([ \t]|$)/) {
        all_fixture = 1
        for (name in names) if (!(name in fixture)) all_fixture = 0
        if (!all_fixture || text !~ /git[ \t]+-C[ \t]+"?\$\{?[A-Za-z_]/) return 1
      }
      return 0
    }
    function analyze_suite(path, suite_directory,   row, i, rest, name, value, current_function, names, fname) {
      reset_suite()
      while ((getline row < path) > 0) {
        lines[++line_count] = row
        if (row ~ /^[ \t]*#/) is_comment[line_count] = 1
      }
      close(path)
      split("", kind_count); split("", root_candidate)
      current_function = ""
      for (i = 1; i <= line_count; i++) {
        if (i in is_comment) continue
        row = lines[i]
        if (row ~ /^[ \t]*(load|source|\.|bats_load_library)[ \t]/ || row ~ /[;&|][ \t]*(source|\.)[ \t]/) has_source = 1
        if (match(row, /^[ \t]*(function[ \t]+)?[A-Za-z_][A-Za-z0-9_:-]*[ \t]*\(\)/)) {
          fname = substr(row, RSTART, RLENGTH); sub(/^[ \t]*(function[ \t]+)?/, "", fname); sub(/[ \t]*\(\)$/, "", fname)
          defined_function[fname] = 1; current_function = fname
        } else if (row ~ /^}/) current_function = ""
        rest = row
        while (match(rest, /(^|[ \t;&|(])[A-Za-z_][A-Za-z0-9_]*=/)) {
          name = substr(rest, RSTART, RLENGTH); sub(/^[ \t;&|(]/, "", name); sub(/=$/, "", name)
          value = substr(rest, RSTART + RLENGTH)
          record_assignment(name, value, suite_directory)
          rest = value
        }
        if (match(row, /(^|[ \t;&|])(read|mapfile|readarray)[ \t]/)) {
          rest = substr(row, RSTART + RLENGTH); sub(/[;&|<>].*/, "", rest)
          while (match(rest, /(^|[ \t])[A-Za-z_][A-Za-z0-9_]*/)) {
            name = substr(rest, RSTART, RLENGTH); sub(/^[ \t]/, "", name); nonfixture[name] = 1
            rest = substr(rest, RSTART + RLENGTH)
          }
        }
        if (match(row, /(^|[ \t;&|])for[ \t]+[A-Za-z_][A-Za-z0-9_]*/)) {
          name = substr(row, RSTART, RLENGTH); sub(/.*for[ \t]+/, "", name); nonfixture[name] = 1
        }
        if (match(row, /printf[ \t]+-v[ \t]+[A-Za-z_][A-Za-z0-9_]*/)) {
          name = substr(row, RSTART, RLENGTH); sub(/.*-v[ \t]+/, "", name); nonfixture[name] = 1
        }
      }
      resolve_roots(suite_directory)
      if (!has_source) resolve_fixtures()
      current_function = ""
      for (i = 1; i <= line_count; i++) {
        if (i in is_comment) continue
        row = lines[i]
        if (match(row, /^[ \t]*(function[ \t]+)?[A-Za-z_][A-Za-z0-9_:-]*[ \t]*\(\)/)) {
          fname = substr(row, RSTART, RLENGTH); sub(/^[ \t]*(function[ \t]+)?/, "", fname); sub(/[ \t]*\(\)$/, "", fname)
          current_function = fname
        } else if (row ~ /^}/) current_function = ""
        if (current_function != "" && line_populates(row)) populator[current_function] = 1
      }
      for (i = 1; i <= line_count; i++) {
        if (i in is_comment) continue
        row = lines[i]
        if (!referenced_names(row, names)) continue
        if (line_populates(row) || calls_populator(row)) {
          for (name in names) if (name in fixture) tainted[name] = 1
        }
      }
    }
    function calls_populator(text,   fname) {
      for (fname in populator) if (text ~ ("(^|[ \t;&|(`])" fname "([ \t]|$)")) return 1
      return 0
    }
    # True when the text before an occurrence ends in a truncating redirection:
    # the occurrence overwrites the file and never reads what it held.
    function truncating_write(text) {
      sub(/"$/, "", text)
      return text ~ />[ \t]*$/ && text !~ /(>>|<>)[ \t]*$/
    }
    # Classifies one occurrence: 1 when it may be the changed file.
    function occurrence_may_be_file(row, position, text_length, changed,   after, next_char, start, token, before, name, tail, joined, prefix_text, relative) {
      after = position + text_length
      next_char = substr(row, after, 1)
      if (next_char ~ /[A-Za-z0-9_]/) return 0
      if (next_char ~ /[.-]/ && substr(row, after + 1, 1) ~ /[A-Za-z0-9]/) return 0
      if (substr(row, position, 1) != "/" && position > 1 && substr(row, position - 1, 1) ~ /[A-Za-z0-9_.-]/) return 0
      start = position
      while (start > 1 && substr(row, start - 1, 1) ~ /[A-Za-z0-9_.@+\/-]/) start--
      token = substr(row, start, after - start)
      before = (start > 1 ? substr(row, start - 1, 1) : "")
      name = ""
      prefix_text = substr(row, 1, start - 1)
      if (before == "$") {
        if (!match(token, /^([A-Za-z_][A-Za-z0-9_]*|[0-9])/)) return 1
        name = substr(token, 1, RLENGTH); tail = substr(token, RLENGTH + 1)
        prefix_text = substr(row, 1, start - 2)
      } else if ((before == "}" || before == "\"") && substr(token, 1, 1) == "/") {
        prefix_text = substr(row, 1, start - 2)
        if (before == "\"" && match(prefix_text, /\$\{?[A-Za-z_][A-Za-z0-9_]*\}?$/)) {
          name = substr(prefix_text, RSTART, RLENGTH); prefix_text = substr(prefix_text, 1, RSTART - 1)
        } else if (before == "}" && match(prefix_text, /\$\{[A-Za-z_][A-Za-z0-9_]*$/)) {
          name = substr(prefix_text, RSTART, RLENGTH); prefix_text = substr(prefix_text, 1, RSTART - 1)
        } else if (before == "}") return 1
        else prefix_text = substr(row, 1, start - 1)
        if (name != "") { gsub(/[${}"]/, "", name); tail = token }
      } else if (before ~ /[)*?\]`$\\]/) {
        return 1
      }
      if (name == "" && substr(token, 1, 1) == "/") return 0
      # A relative path a `git -C <variable>` reads is under that variable.
      if (name == "" && match(prefix_text, /git[ \t]+-C[ \t]+"?\$\{?[A-Za-z_][A-Za-z0-9_]*\}?"?[ \t][^;&|]*$/)) {
        name = substr(prefix_text, RSTART, RLENGTH)
        sub(/^git[ \t]+-C[ \t]+"?\$\{?/, "", name); sub(/[^A-Za-z0-9_].*/, "", name)
        tail = "/" token
      }
      if (name in root_path) {
        joined = normalize(root_path[name] "/" tail)
        if (joined == "\001") return 1
        return joined == changed
      }
      relative = (name == "" ? token : tail)
      if (index(relative, "..")) return 1
      joined = normalize(relative)
      # Neither path a trailing part of the other: they differ in a named
      # segment, so no working directory or variable value joins to the file.
      if (!is_suffix_path(joined, changed) && !is_suffix_path(changed, joined)) return 0
      if (truncating_write(prefix_text)) return 0
      if (name == "") return is_suffix_path(joined, changed)
      if ((name in fixture) && !(name in tainted) && ((name, joined) in written)) return 0
      return 1
    }
    function record_writes(   i, row, rest, offset, name, tail, before_text) {
      for (i = 1; i <= line_count; i++) {
        if (i in is_comment) continue
        row = lines[i]; rest = row; offset = 0
        while (match(rest, /\$\{?[A-Za-z_][A-Za-z0-9_]*\}?"?[A-Za-z0-9_.@+\/-]*/)) {
          name = substr(rest, RSTART, RLENGTH)
          before_text = substr(row, 1, offset + RSTART - 1)
          rest = substr(rest, RSTART + RLENGTH); offset = length(row) - length(rest)
          tail = name; sub(/^\$\{?[A-Za-z_][A-Za-z0-9_]*\}?"?/, "", tail)
          sub(/^\$\{?/, "", name); sub(/[^A-Za-z0-9_].*/, "", name)
          if (!(name in fixture)) continue
          sub(/"$/, "", before_text)
          if (before_text ~ />[ \t]*$/ || before_text ~ /(^|[ \t;&|])(touch|tee)([ \t]+-[A-Za-z]+)*([ \t]+[^ \t;&|]+)*[ \t]+$/) written[name, normalize(tail)] = 1
        }
      }
    }
    function suite_reaches(suite,   path, suite_directory, i, j, row, position, found) {
      path = root "/" suite
      suite_directory = suite; if (!sub(/\/[^\/]*$/, "", suite_directory)) suite_directory = ""
      analyze_suite(path, suite_directory)
      record_writes()
      for (i = 1; i <= line_count; i++) {
        row = lines[i]
        # A test name labels the test; it reads nothing.
        if (row ~ /^[ \t]*@test[ \t]/ || (helper_mode != "" && (i in is_comment))) continue
        for (j = 1; j <= pair_count; j++) {
          found = 0
          while ((position = index(substr(row, found + 1), pair_text[j])) > 0) {
            position += found
            if (occurrence_may_be_file(row, position, length(pair_text[j]), pair_path[j])) return 1
            found = position
          }
        }
      }
      return 0
    }
    BEGIN {
      pair_count = 0
      while ((getline row < pair_file) > 0) {
        tab = index(row, "\t"); if (!tab) continue
        pair_path[++pair_count] = substr(row, 1, tab - 1); pair_text[pair_count] = substr(row, tab + 1)
      }
      close(pair_file)
      while ((getline row < top_file) > 0) top[row] = 1
      close(top_file)
      while ((getline suite < suite_list) > 0) if (suite_reaches(suite)) print suite
      close(suite_list)
    }
  '
}
