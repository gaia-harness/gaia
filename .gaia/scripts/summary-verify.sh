#!/usr/bin/env bash
# summary-verify.sh: deterministic verify-gate for the consolidated
# wiki-purposed SUMMARY.md artifact produced at merge. Every
# consolidation producer (the orchestrator's consolidation step and the
# pre-flight sweep's cold consolidation) calls this before the irreversible
# removal of SPEC.md / AUDIT.md: a failed or malformed consolidation keeps
# the layers (fail-closed).
#
# Usage: summary-verify.sh <summary_md_path>
#
# Exit 0 iff the file exists, is non-empty, and is well-formed per the pinned
# shape (frozen contract, plan/README.md #2): a closed leading frontmatter
# block (`---` ... `---`) containing wiki_promote_default: and
# wiki_promote_targets: keys, a non-empty H1 (`# <title>`; later H1 lines are
# body), and a non-empty body after it. An optional `## Divergence` section is
# allowed but not required. The first wiki_promote_default: line must carry
# yes, ask or no (optionally in matching quotes).
# Under a yes default, wiki_promote_targets must be non-empty (inline list or
# block list): the promotion step reads an empty one as nothing to promote, a
# silent no-op. Its values are not deep-validated here: target routing is
# validated by the wiki promotion step.
#
# Exit 1 otherwise: absent/empty file, missing or unclosed frontmatter,
# frontmatter missing either key, a wiki_promote_default outside the
# vocabulary, a yes default with empty targets, missing H1, or empty body. Violations
# accumulate and are reported to stderr; no stdout noise.
#
# Deterministic and side-effect-free: no writes, no network, no git.
# gaia:maintainer-only:start
#
# Sibling bats suite: .gaia/scripts/tests/summary-verify.bats.
# gaia:maintainer-only:end
set -uo pipefail

path="${1:-}"

if [ -z "$path" ] || [ ! -s "$path" ]; then
  echo "summary-verify: missing or empty file: ${path:-<none>}" >&2
  exit 1
fi

awk -v single_quote="'" '
  BEGIN { frontmatter_open = 0; frontmatter_closed = 0; saw_wiki_promote_default = 0; saw_wiki_promote_targets = 0; seen_h1 = 0; body_nonempty = 0 }
  NR == 1 {
    if ($0 == "---") frontmatter_open = 1
    next
  }
  frontmatter_open && !frontmatter_closed {
    if ($0 == "---") { frontmatter_closed = 1; next }
    if ($0 ~ /^wiki_promote_default:/ && !saw_wiki_promote_default) {
      saw_wiki_promote_default = 1
      default_value = $0
      sub(/^wiki_promote_default:/, "", default_value)
      gsub(/^[ \t]+|[ \t\r]+$/, "", default_value)
      raw_default_value = default_value
      if (default_value ~ /^".*"$/ || (length(default_value) >= 2 && substr(default_value, 1, 1) == single_quote && substr(default_value, length(default_value), 1) == single_quote)) default_value = substr(default_value, 2, length(default_value) - 2)
    }
    if ($0 ~ /^wiki_promote_targets:/) {
      saw_wiki_promote_targets = 1
      in_targets_block = 1
      targets_value = $0
      sub(/^wiki_promote_targets:/, "", targets_value)
      gsub(/[ \t\r]/, "", targets_value)
      if (targets_value != "" && targets_value != "[]") targets_nonempty = 1
      next
    }
    if (in_targets_block && $0 ~ /^[ \t]+-[ \t]*[^ \t\r]/) { targets_nonempty = 1; next }
    in_targets_block = 0
    next
  }
  frontmatter_closed && !seen_h1 {
    if ($0 ~ /^# /) {
      text = $0
      sub(/^# /, "", text)
      gsub(/^[ \t]+|[ \t]+$/, "", text)
      if (text != "") seen_h1 = 1
    }
    next
  }
  frontmatter_closed && seen_h1 {
    line = $0
    gsub(/^[ \t]+|[ \t]+$/, "", line)
    if (line != "") body_nonempty = 1
  }
  END {
    ok = 1
    if (!frontmatter_open) {
      print "summary-verify: missing leading frontmatter block (^---$)" > "/dev/stderr"
      ok = 0
    } else if (!frontmatter_closed) {
      print "summary-verify: unclosed frontmatter block (no closing ^---$)" > "/dev/stderr"
      ok = 0
    } else {
      if (!saw_wiki_promote_default) {
        print "summary-verify: frontmatter missing wiki_promote_default:" > "/dev/stderr"
        ok = 0
      }
      if (saw_wiki_promote_default && default_value != "yes" && default_value != "ask" && default_value != "no") {
        print "summary-verify: wiki_promote_default must be yes, ask or no (got " single_quote raw_default_value single_quote ")" > "/dev/stderr"
        ok = 0
      }
      if (!saw_wiki_promote_targets) {
        print "summary-verify: frontmatter missing wiki_promote_targets:" > "/dev/stderr"
        ok = 0
      } else if (default_value == "yes" && !targets_nonempty) {
        print "summary-verify: wiki_promote_default yes needs a non-empty wiki_promote_targets (it would promote nothing)" > "/dev/stderr"
        ok = 0
      }
      if (!seen_h1) {
        print "summary-verify: missing non-empty H1 (^# <title>)" > "/dev/stderr"
        ok = 0
      } else if (!body_nonempty) {
        print "summary-verify: empty body after H1" > "/dev/stderr"
        ok = 0
      }
    }
    exit ok ? 0 : 1
  }
' "$path"
