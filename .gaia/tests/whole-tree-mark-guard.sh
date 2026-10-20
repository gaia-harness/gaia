#!/usr/bin/env bash
# whole-tree-mark-guard.sh: flag a bats test that enumerates the tracked tree
# without carrying the whole-tree mark.
#
# A test is whole-tree when its outcome depends on tracked files it does not
# name. The change selector (.gaia/scripts/bats-suites-for-change.sh) picks a
# suite only when the suite names a changed file, so a whole-tree test is never
# picked by it. The mark makes the verification runner's branch whole-tree step
# run the test. It comes in two bats-native spellings: a test tag on the line
# above one `@test` marks that test, a file tag before the first `@test` marks
# every test in the suite. The canonical patterns the runner discovers are the
# verify_whole_tree_*_mark_pattern variables in
# .gaia/tests/helpers/verify-harness-bats-lib.sh, read from there, never
# restated here.
#
# Recognized idioms (the ONLY ones this guard recognizes). First the suite's
# real-root variables are collected: a variable assigned from an expression
# containing $BATS_TEST_DIRNAME or $BATS_TEST_FILENAME, plus any variable whose
# assignment expression contains one already collected, repeated until no new
# variable joins. Then a statement, outside comments and outside the fixture
# data the shared scan library (.gaia/scripts/guard-awk-lib.sh) recognizes, is a
# hit when a real-root variable is the operand of:
#   1. git -C <root> ... ls-files   or   git -C <root> ... grep
#   2. find <root>   or   find <root>/<dir>
#   3. a glob loop: for <name> in <root>/<path>*...
# A backslash-continued statement is read joined, and its hit sits on its first
# physical line. A root that is a $BATS_TEST_TMPDIR-based or other fixture path
# is never a real root, so a fixture repository is never flagged. Neither is a
# root assigned from a path with a `fixtures` segment, nor a find or glob-loop
# operand under one: committed fixtures are the suite's own inputs, edited
# beside it, not the tracked tree it checks.
# An ls-files call is not enumeration when it uses --error-unmatch (a
# membership test) or when every operand is a literal path below the root that
# is not a tracked directory: it names those paths, so the change selector
# picks the suite when one changes. A glob, a magic pathspec, a variable, a
# tracked directory or a root-level operand still counts: the selector matches
# a root-level file as `/<name>`, which a bare operand never contains.
#
# Every hit is attributed to its scope, and the scan runs past the first one:
#   - Inside a `@test` body, that test needs the test mark, or the suite needs
#     the file mark. The finding names the test.
#   - Outside every test body (setup, setup_file, a helper, top level), the
#     suite needs the file mark, or every test in it marked, or a waiver on the
#     comment line(s) directly above the statement's first line, written as
#     `# gaia-lint-ignore whole-tree-mark-guard: <reason>`. A waiver above an
#     in-body hit is honored too.
# A waiver has two allowed reasons: every test that depends on the idiom
# carries the test mark, or the operand is not the tracked tree. The one
# recorded exception is the pre-push end-to-end suite's setup_file waiver,
# whose reason records the decision to keep that suite out of the whole-tree
# step because it duplicates coverage the step already runs. This guard does
# not read the reason: the shell-lint owner guard
# (.gaia/scripts/lint-git-path-quoting.sh) reports a waiver with no reason as
# malformed, and review, not this guard, checks that the reason is true. A
# waiver above a statement that holds no hit waives nothing and is reported as
# unused.
#
# Mark spelling and placement are checked against what bats itself applies (a
# comment line bats reads as a tag command, a test tag applying to the next
# `@test` and replaced by a later test tag before it, a file tag applying to
# every later test and replaced by a later file tag). Each of these is
# reported with its line, whatever the hits: a tag line bats honors as
# carrying whole-tree that the canonical pattern misses (the runner never
# discovers it), a canonical line whose tag list bats rejects, a file mark
# after the first `@test`, a file mark replaced by a later file tag line, a
# test mark replaced by a later test tag line before its `@test`, and a test
# mark with no `@test` after it.
#
# NOT claimed: enumeration delegated to a script the suite calls (a lint
# script, a roster check) is outside this guard. Such a test is marked by
# hand. There is no call-graph resolution: an idiom in a helper is an
# outside-body hit whichever tests call the helper. The guard never widens its
# parser to chase more shapes.
#
# Maintainer-only: .gaia/tests is release-excluded wholesale.
#
# Usage:
#   bash .gaia/tests/whole-tree-mark-guard.sh [--root <repo>] [<suite>...]
# With no suite operands every tracked *.bats under the root is scanned.
# Exit: 0 no finding; 1 one or more found; 2 usage error, an empty discovery
# set (a guard over nothing is not clean), or a scan that could not run.

set -u

usage() {
  echo "usage: whole-tree-mark-guard.sh [--root <repo>] [<suite>...]" >&2
}

root=""
suites=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --root)
      if [ "$#" -lt 2 ] || [ -z "$2" ]; then
        usage
        exit 2
      fi
      root="$2"
      shift 2
      ;;
    -h | --help)
      usage
      exit 2
      ;;
    -*)
      usage
      exit 2
      ;;
    *)
      suites+=("$1")
      shift
      ;;
  esac
done

# Script-relative, never cwd-relative: every fixture test runs this guard from
# a throwaway directory. The shared scan library lives in .gaia/scripts, one
# directory over; its pragma token resolution also tries .gaia/tests, where
# this guard lives.
_gaia_guard_script_directory="${BASH_SOURCE[0]%/*}"
if [ "$_gaia_guard_script_directory" = "${BASH_SOURCE[0]}" ]; then _gaia_guard_script_directory="."; fi
_gaia_guard_library_directory="$_gaia_guard_script_directory/../scripts"
# shellcheck source=.gaia/scripts/guard-awk-lib.sh
[ -f "$_gaia_guard_library_directory/guard-awk-lib.sh" ] && . "$_gaia_guard_library_directory/guard-awk-lib.sh" 2>/dev/null
type gaia_guard_bats_files >/dev/null 2>&1 || {
  echo "whole-tree-mark-guard: guard-awk-lib.sh is missing from $_gaia_guard_library_directory" >&2
  exit 2
}
case "$GAIA_AWK_STATUS" in
  5)
    echo "whole-tree-mark-guard: no awk interpreter found; install mawk (macOS: brew install mawk; Debian/Ubuntu: apt-get install mawk) or ensure /usr/bin/awk is present" >&2
    exit 2
    ;;
  6)
    echo "whole-tree-mark-guard: GAIA_AWK resolved to an unsanctioned interpreter ($GAIA_AWK_IDENTITY); the sanctioned set is mawk and BWK one-true-awk" >&2
    exit 2
    ;;
esac

# shellcheck source=.gaia/tests/helpers/verify-harness-bats-lib.sh
. "$_gaia_guard_script_directory/helpers/verify-harness-bats-lib.sh" 2>/dev/null
if [ -z "${verify_whole_tree_file_mark_pattern:-}" ] || [ -z "${verify_whole_tree_test_mark_pattern:-}" ]; then
  echo "whole-tree-mark-guard: the mark patterns did not load from $_gaia_guard_script_directory/helpers/verify-harness-bats-lib.sh" >&2
  exit 2
fi

if [ -z "$root" ]; then
  root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
    echo "whole-tree-mark-guard: not inside a git repository; pass --root <repo>" >&2
    exit 2
  }
fi

scan_paths=()
if [ "${#suites[@]}" -gt 0 ]; then
  scan_paths=(${suites[@]+"${suites[@]}"})
else
  while IFS= read -r -d '' tracked_suite; do
    scan_paths+=("$root/$tracked_suite")
  done < <(git -C "$root" ls-files -z '*.bats' 2>/dev/null)
fi

if [ "${#scan_paths[@]}" -eq 0 ]; then
  echo "whole-tree-mark-guard: no tracked *.bats suite found under $root; a guard over nothing is not clean" >&2
  exit 2
fi

# The detector, concatenated after $GAIA_GUARD_AWK and run once per suite with
# the suite named twice. Pass 1 feeds the library prepass and joins logical
# lines to find every hit; pass 2 feeds the library line by line, so scope and
# waivers are read on the physical line each hit starts on, the only line its
# waiver block is active for. Exit 0 clean, 1 findings printed.
# shellcheck disable=SC2016
readonly OWN_AWK='
    function is_comment(text) { return text ~ /^[ \t]*#/ }
    function refers(text, name) {
      return text ~ ("\\$\\{?" name "([^A-Za-z0-9_]|$)")
    }
    function names_only(rest,   tail, token_count, tokens, t, token, operand_count) {
      if (rest ~ /(^|[ \t])--error-unmatch([ \t]|$)/) { return 1 }
      tail = rest
      sub(/^.*(^|[ \t])ls-files([ \t]|$)/, "", tail)
      if (match(tail, /[|)<>;&]/)) { tail = substr(tail, 1, RSTART - 1) }
      operand_count = 0
      token_count = split(tail, tokens, /[ \t]+/)
      for (t = 1; t <= token_count; t++) {
        token = tokens[t]
        gsub(/["\047]/, "", token)
        if (token == "" || token ~ /^-/) { continue }
        if (token ~ /[$*?[]/ || token ~ /^:/ || token ~ /\/$/ || token !~ /\// || (token in is_directory)) { return 0 }
        operand_count++
      }
      return operand_count > 0
    }

    # Pass 1: one physical line into the logical-line store, joining a
    # backslash continuation onto the line it continues.
    function collect_line(raw) {
      if (pending == "") { pending_start = FNR }
      if (raw ~ /\\[ \t]*$/ && !is_comment(raw)) {
        sub(/\\[ \t]*$/, " ", raw)
        pending = pending raw
        return
      }
      logical_count++
      logical_text[logical_count] = pending raw
      logical_start[logical_count] = pending_start
      pending = ""
    }

    # The idiom one real root is the operand of on one logical line, as a
    # priority (1 git listing, 2 git grep, 3 find, 4 glob loop) so the verdict
    # does not depend on the order awk walks the root set in; 0 for none.
    function idiom_priority(text, name,   git_call, rest, find_call, fixture_find, loop_call, fixture_loop) {
      if (text !~ ("\\$\\{?" name "([^A-Za-z0-9_]|$)")) { return 0 }
      git_call = "git[ \t]+(.*[ \t])?-C[ \t]+\"?" "\\$\\{?" name "([^A-Za-z0-9_]|$)"
      if (match(text, git_call)) {
        rest = substr(text, RSTART + RLENGTH)
        if (rest ~ /(^|[ \t])ls-files([ \t]|$)/ && names_only(rest)) { return 0 }
        if (rest ~ /(^|[ \t])ls-files([ \t]|$)/) { return 1 }
        if (rest ~ /(^|[ \t])grep([ \t]|$)/) { return 2 }
      }
      find_call = "(^|[^A-Za-z0-9_-])find[ \t]+\"?\\$\\{?" name "([^A-Za-z0-9_]|$)"
      fixture_find = "find[ \t]+\"?\\$\\{?" name "\\}?/([^ \t\"]*/)?fixtures([/\" \t]|$)"
      if (text ~ find_call && text !~ fixture_find) { return 3 }
      loop_call = "(^|[^A-Za-z0-9_])for[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t]+in[ \t]+[^;]*\"?\\$\\{?" name "\\}?\"?[^ \t;]*\\*"
      fixture_loop = "in[ \t]+\"?\\$\\{?" name "\\}?\"?/([^ \t;\"]*/)?fixtures/"
      if (text ~ loop_call && text !~ fixture_loop) { return 4 }
      return 0
    }

    # End of pass 1: the real-root fixpoint, then every hit keyed by the first
    # physical line of its logical line.
    function find_hits(   i, statement, equals_position, assigned_count, assigned_name, assigned_value, a, name, value, joins, known, changed, best, priority) {
      if (pending != "") {
        logical_count++
        logical_text[logical_count] = pending
        logical_start[logical_count] = pending_start
        pending = ""
      }
      assigned_count = 0
      for (i = 1; i <= logical_count; i++) {
        if (is_comment(logical_text[i])) { continue }
        statement = logical_text[i]
        sub(/^[ \t]*/, "", statement)
        sub(/^(local|export|readonly|declare)[ \t]+(-[A-Za-z]+[ \t]+)?/, "", statement)
        if (statement !~ /^[A-Za-z_][A-Za-z0-9_]*=/) { continue }
        equals_position = index(statement, "=")
        assigned_count++
        assigned_name[assigned_count] = substr(statement, 1, equals_position - 1)
        assigned_value[assigned_count] = substr(statement, equals_position + 1)
      }
      changed = 1
      while (changed) {
        changed = 0
        for (a = 1; a <= assigned_count; a++) {
          name = assigned_name[a]
          if (name in is_root) { continue }
          value = assigned_value[a]
          if (value ~ /\/fixtures([\/" \t]|$)/) { continue }
          joins = 0
          if (index(value, "$BATS_TEST_DIRNAME") || index(value, "${BATS_TEST_DIRNAME") \
              || index(value, "$BATS_TEST_FILENAME") || index(value, "${BATS_TEST_FILENAME")) {
            joins = 1
          } else {
            for (known in is_root) {
              if (refers(value, known)) { joins = 1; break }
            }
          }
          if (joins) { is_root[name] = 1; changed = 1 }
        }
      }
      for (i = 1; i <= logical_count; i++) {
        if (is_comment(logical_text[i])) { continue }
        best = 0
        for (name in is_root) {
          priority = idiom_priority(logical_text[i], name)
          if (priority > 0 && (best == 0 || priority < best)) { best = priority }
        }
        if (best > 0) { hit_idiom[logical_start[i]] = idiom_label[best] }
      }
      hits_found = 1
    }

    # 1 when bats applies the whole-tree tag from this tag list: the list
    # passes the bats tag-list syntax (an invalid list applies no tag at all)
    # and one comma element, trimmed of spaces, is whole-tree.
    function bats_applies_whole_tree(tag_list,   element_count, elements, e, element) {
      if (tag_list !~ /^ *([-_:A-Za-z0-9]+)?( *, *[-_:A-Za-z0-9]+)* *$/) { return 0 }
      element_count = split(tag_list, elements, ",")
      for (e = 1; e <= element_count; e++) {
        element = elements[e]
        gsub(/^ +/, "", element)
        gsub(/ +$/, "", element)
        if (element == "whole-tree") { return 1 }
      }
      return 0
    }

    # The test name bats reads from an @test line: the text between @test and
    # the last blank-preceded opening brace, one outer quote stripped from each
    # end. Empty when the line is not a test line.
    function test_name_of(text,   rest, i, candidate) {
      if (text !~ /^[ \t]*@test[ \t]+.*[^ \t][ \t]+\{/) { return "" }
      rest = text
      sub(/^[ \t]*@test[ \t]+/, "", rest)
      for (i = length(rest); i > 1; i--) {
        if (substr(rest, i, 1) != "{" || substr(rest, i - 1, 1) !~ /[ \t]/) { continue }
        candidate = substr(rest, 1, i - 1)
        sub(/[ \t]+$/, "", candidate)
        if (candidate == "") { continue }
        sub(/^["\047]/, "", candidate)
        sub(/["\047]$/, "", candidate)
        return candidate
      }
      return ""
    }

    function finding(line_number, reason) {
      printf "%s:%d: %s\n", file, line_number, reason
      findings++
    }

    # One tag command line, tracked the way bats applies it.
    function read_tag_line(text, command,   kind, tag_list, honored, canonical) {
      if (command ~ /^test_tags=/) { kind = "test" } else if (command ~ /^file_tags=/) { kind = "file" } else { return }
      tag_list = command
      sub(/^[a-z]+_tags=/, "", tag_list)
      honored = bats_applies_whole_tree(tag_list)
      canonical = (text ~ (kind == "test" ? test_mark_pattern : file_mark_pattern))
      if (honored && !canonical) {
        finding(FNR, "bats applies this whole-tree " kind " tag, but the runner discovers only the canonical spelling (column 0, \047# bats " kind "_tags=\047, no spaces around = or commas), so it never runs the suite for it")
      }
      if (canonical && !honored) {
        finding(FNR, "the canonical whole-tree " kind " tag is in a tag list bats rejects, so bats applies no tag from this line")
      }
      if (kind == "test") {
        if (test_mark_line && !honored) {
          finding(test_mark_line, "the whole-tree test mark is replaced by the test_tags line at line " FNR " before its @test, so bats never applies it")
        }
        pending_test_marked = honored
        test_mark_line = (honored || canonical) ? FNR : 0
        return
      }
      if ((honored || canonical) && test_count > 0) {
        finding(FNR, "the whole-tree file mark sits after the first @test, so bats leaves it off every test above it; move it before the first test")
      }
      if (file_mark_line && !honored) {
        finding(file_mark_line, "the whole-tree file mark is replaced by the file_tags line at line " FNR ", so bats leaves it off every test below that line")
      }
      file_tag_whole_tree = honored
      file_mark_line = (honored || canonical) ? FNR : 0
    }

    BEGIN {
      gaia_scan_reset()
      while ((getline directory < directory_list) > 0) { is_directory[directory] = 1 }
      close(directory_list)
      # Split so the path-quoting lint does not read the label as a listing.
      idiom_label[1] = "git -C <root> ls-" "files"
      idiom_label[2] = "git -C <root> grep"
      idiom_label[3] = "find <root>"
      idiom_label[4] = "glob loop over <root>"
      pending = ""; logical_count = 0; hits_found = 0; findings = 0
      test_count = 0; current_test = ""; current_test_marked = 0
      every_test_marked = 1; every_test_file_marked = 1
      pending_test_marked = 0; test_mark_line = 0
      file_tag_whole_tree = 0; file_mark_line = 0
      hit_count = 0
    }
    NR == FNR { gaia_scan_prepass($0); collect_line($0); next }
    FNR == 1 && !hits_found { find_hits() }
    {
      gaia_scan_feed($0, 1)
      physical = $0
      sub(/\r$/, "", physical)
      name = test_name_of(physical)
      if (name == "" && physical ~ /[ \t]*[^ \t()]+[ \t]*\(?\)?[ \t]+\{[ \t]+#[ \t]*@test[ \t]*$/) {
        name = physical
        sub(/^[ \t]*/, "", name)
        sub(/[ \t(].*$/, "", name)
      }
      if (name != "") {
        test_count++
        current_test = name
        current_test_marked = (pending_test_marked || file_tag_whole_tree)
        if (!current_test_marked) { every_test_marked = 0 }
        if (!file_tag_whole_tree) { every_test_file_marked = 0 }
        pending_test_marked = 0
        test_mark_line = 0
      } else if (physical ~ /^[ \t]*#[ \t]*bats[ \t]+/) {
        command = physical
        sub(/^[ \t]*#[ \t]*bats[ \t]+/, "", command)
        read_tag_line(physical, command)
      }
      if (!(FNR in hit_idiom) || gaia_scan_skip()) { next }
      hit_count++
      hit_line[hit_count] = FNR
      hit_label[hit_count] = hit_idiom[FNR]
      hit_in_test[hit_count] = gaia_scan_in_test()
      hit_test[hit_count] = current_test
      hit_test_marked[hit_count] = current_test_marked
      hit_waived[hit_count] = gaia_scan_suppressed("whole-tree-mark-guard")
    }
    END {
      if (test_mark_line) {
        finding(test_mark_line, "the whole-tree test mark has no @test after it, so bats never applies it")
      }
      if (gaia_scan_end(file, 1, "whole-tree-mark-guard", 0, 0)) { findings++ }
      file_marked = (test_count > 0) ? every_test_file_marked : file_tag_whole_tree
      for (h = 1; h <= hit_count; h++) {
        if (hit_waived[h] || file_marked) { continue }
        if (hit_in_test[h]) {
          if (hit_test_marked[h]) { continue }
          printf "%s: test \"%s\" enumerates the tracked tree (%s, line %d) without the whole-tree mark; add \047# bats test_tags=whole-tree\047 on the line above it\n", file, hit_test[h], hit_label[h], hit_line[h]
          findings++
          continue
        }
        if (test_count > 0 && every_test_marked) { continue }
        printf "%s: enumerates the tracked tree outside any test body (%s, line %d) without the file-level whole-tree mark; add \047# bats file_tags=whole-tree\047 before the first test, mark every test with \047# bats test_tags=whole-tree\047, or put a waiver \047# gaia-lint-ignore whole-tree-mark-guard: <reason>\047 on the comment line directly above the statement\n", file, hit_label[h], hit_line[h]
        findings++
      }
      exit (findings > 0) ? 1 : 0
    }
'

# Every directory holding a tracked file, so a literal ls-files operand naming
# one still counts as enumeration. Empty when the root is not a repository.
directory_list="$(mktemp)" || { echo "whole-tree-mark-guard: cannot create a temporary file" >&2; exit 2; }
trap 'rm -f "$directory_list"' EXIT
git -C "$root" ls-files -z 2>/dev/null \
  | tr '\0' '\n' \
  | awk -F/ '{ path = $1; for (i = 2; i <= NF; i++) { print path; path = path "/" $i } }' \
  | sort -u >"$directory_list"

flagged=0
for suite_path in ${scan_paths[@]+"${scan_paths[@]}"}; do
  if [ ! -f "$suite_path" ]; then
    echo "whole-tree-mark-guard: not a file: $suite_path" >&2
    exit 2
  fi
  display="$suite_path"
  case "$suite_path" in
    "$root"/*) display="${suite_path#"$root"/}" ;;
  esac
  "$GAIA_AWK" -v file="$display" -v is_bats=1 -v scripts_directory="$_gaia_guard_library_directory" \
    -v directory_list="$directory_list" \
    -v file_mark_pattern="$verify_whole_tree_file_mark_pattern" \
    -v test_mark_pattern="$verify_whole_tree_test_mark_pattern" \
    "$GAIA_GUARD_AWK$OWN_AWK" "$suite_path" "$suite_path"
  scan_status=$?
  case "$scan_status" in
    0) ;;
    1) flagged=$((flagged + 1)) ;;
    *)
      echo "whole-tree-mark-guard: the scan of $display failed (awk exited $scan_status); this guard cannot certify it" >&2
      exit 2
      ;;
  esac
done

if [ "$flagged" -gt 0 ]; then
  echo "whole-tree-mark-guard: $flagged suite(s) flagged. Only the idioms in this script's header are recognized (git -C <root> listing tracked files or grep, find <root>, a glob loop over <root>); enumeration delegated to a script the suite calls is outside this guard's claim and needs the mark by hand."
  exit 1
fi

echo "whole-tree-mark-guard: no unmarked test uses a recognized enumeration idiom (enumeration delegated to a called script is outside this guard's claim)"
exit 0
