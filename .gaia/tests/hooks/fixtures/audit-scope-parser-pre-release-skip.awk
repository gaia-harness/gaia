# The roster ownership parser (_audit_scope_parse_auditors in
# .claude/hooks/lib/audit-scope.sh) exactly as it stood at commit
# 7e27090d0194a3789ca95c5681c32a4db0812e11, the branch's base, before the
# release-change skip key existed: the shared glob awk followed by the
# parser program, verbatim. Pinned so a test can prove a pre-change reader
# ends a member's globs on the skip key and never reads it as a glob.
# Run with: awk -f <this file> < roster. Never regenerate it from the
# current tree: it must stay the old parser.

    function unq(s) {
      if (s ~ /^".*"$/) return substr(s, 2, length(s) - 2)
      if (s ~ /^'.*'$/) return substr(s, 2, length(s) - 2)
      return s
    }
    # Convert a posix glob (**, *) into an anchored ERE, matched against
    # repo-relative POSIX paths. Mirrors scrub.ts globToRegex: escape ERE
    # specials (not *), then handle **/, **, * via sentinels so single-* is
    # not re-substituted.
    function glob_to_regex(glob,   g) {
      g = glob
      gsub(/\\/, "\\\\", g)
      gsub(/\./, "\\.", g)
      gsub(/\+/, "\\+", g)
      gsub(/\^/, "\\^", g)
      gsub(/\$/, "\\$", g)
      gsub(/\(/, "\\(", g)
      gsub(/\)/, "\\)", g)
      gsub(/\[/, "\\[", g)
      gsub(/\]/, "\\]", g)
      gsub(/\{/, "\\{", g)
      gsub(/\}/, "\\}", g)
      gsub(/\|/, "\\|", g)
      gsub(/\*\*\//, "@@DIRSTAR@@", g)
      gsub(/\*\*/,   "@@STAR@@", g)
      gsub(/\*/,     "[^/]*", g)
      gsub(/@@STAR@@/,   ".*", g)
      gsub(/@@DIRSTAR@@/, "(.*/)?", g)
      return "^" g "$"
    }

    function flush(   i) {
      if (have_member) {
        if (is_default) {
          print "DEFAULT " member
          for (i = 1; i <= nglobs; i++) print "DEFAULTGLOB " member " " glob_to_regex(globs[i])
        } else {
          for (i = 1; i <= nglobs; i++) print "GLOB " member " " glob_to_regex(globs[i])
        }
      }
      have_member = 0; member = ""; is_default = 0; nglobs = 0; in_globs = 0
    }
    BEGIN { in_auditors = 0; in_globs = 0; have_member = 0; member = ""; is_default = 0; nglobs = 0 }
    {
      raw = $0
      # Top-level `auditors:` key opens the block.
      if (raw ~ /^auditors[[:space:]]*:/) { in_auditors = 1; next }
      if (!in_auditors) next
      # Any other top-level key (column 0, a letter) closes the block.
      if (raw ~ /^[A-Za-z_]/) { flush(); in_auditors = 0; next }
      # Blank lines and comments (including the maintainer-only markers) are
      # skipped and never end a member or the block.
      if (raw ~ /^[[:space:]]*$/) next
      if (raw ~ /^[[:space:]]*#/) next
      # New member: `- name: X`.
      if (raw ~ /^[[:space:]]*-[[:space:]]+name[[:space:]]*:/) {
        flush()
        have_member = 1
        v = raw
        sub(/^[[:space:]]*-[[:space:]]+name[[:space:]]*:[[:space:]]*/, "", v)
        sub(/[[:space:]]+#.*$/, "", v)
        sub(/^[[:space:]]+/, "", v); sub(/[[:space:]]+$/, "", v)
        member = unq(v)
        next
      }
      # `globs:` opens the glob sublist.
      if (raw ~ /^[[:space:]]+globs[[:space:]]*:/) { in_globs = 1; next }
      # `default: <bool>`.
      if (raw ~ /^[[:space:]]+default[[:space:]]*:/) {
        in_globs = 0
        v = raw
        sub(/^[[:space:]]+default[[:space:]]*:[[:space:]]*/, "", v)
        sub(/[[:space:]]+#.*$/, "", v)
        sub(/^[[:space:]]+/, "", v); sub(/[[:space:]]+$/, "", v)
        if (tolower(v) == "true") is_default = 1
        next
      }
      # Any other member-level scalar key (audience, a retired key an older
      # roster still carries, ...) ends globs and is otherwise ignored.
      if (raw ~ /^[[:space:]]+[A-Za-z_]+[[:space:]]*:/) { in_globs = 0; next }
      # A `- <value>` list item while inside globs is one glob.
      if (in_globs && raw ~ /^[[:space:]]*-[[:space:]]+/) {
        g = raw
        sub(/^[[:space:]]*-[[:space:]]+/, "", g)
        sub(/[[:space:]]+#.*$/, "", g)
        sub(/^[[:space:]]+/, "", g); sub(/[[:space:]]+$/, "", g)
        g = unq(g)
        if (g != "") { nglobs++; globs[nglobs] = g }
        next
      }
    }
    END { flush() }
  
