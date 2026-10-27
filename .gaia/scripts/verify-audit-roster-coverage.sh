#!/usr/bin/env bash
# verify-audit-roster-coverage.sh: the invariant that every tracked path
# resolves an owner.
#
# One contiguous span of the roster check, moved here unchanged.
# verify-audit-roster.sh sources it from its own directory at the point the
# span stood, so it runs in the same order over the same globals; it is never
# run on its own. Its last line tells the parent it was read to the end.
#
# Bash 3.2 compatible (macOS-default bash).

# SC2016: single-quoted awk and printf text is literal, as in the parent.
# shellcheck disable=SC2016,SC2034,SC2154  # the roster globals cross files: the parent and the other siblings set and read them

# --- Invariant: every tracked path resolves an owner -------------------------
#
# The inverse of every invariant above. Those ask whether the roster's entries
# are well-formed; this asks whether the roster's entries COVER the repository,
# which is the one question the dispatch resolver structurally cannot answer for
# itself. A path no member's globs match resolves an empty dispatched set, falls
# to the merge gate's legacy branch, is out-of-scope-allowlisted, and merges
# unreviewed -- and that is silent by construction, because an empty member set
# is also the legitimate answer for a genuinely out-of-remit diff. Nothing else
# distinguishes "nothing here needs an owner" from "this needs one and has none".
#
# So the roster declares the difference, in an `unowned:` list beside `auditors:`,
# and this invariant is the ledger over the two together. The list is read only
# here: no dispatch path consults it, so an entry can never suppress a review it
# would otherwise have forced.
#
# WHY AN EXEMPTION LIST IS NOT THE RUBBER STAMP IT LOOKS LIKE, which is the
# objection this design has to answer rather than dodge, since a freely
# appendable opt-out reproduces the current situation with more machinery:
#
#   * Appending is REVIEWED. The list lives in .gaia/audit-ci.yml, a path the
#     roster already grants to a member, so adding an exemption dispatches an
#     auditor. Adding an ownerless file today dispatches nobody. That is the
#     whole asymmetry: the silent move becomes the loud one.
#   * A blanket exemption CANNOT PASS. An entry that reaches a path some member
#     already owns is broader than the ownerless region it exists to describe,
#     and fails as overbroad -- which `**`, the one move that would neuter this
#     invariant in a single line, necessarily does.
#
# THE UNIVERSE is the tracked file list of the repository ROOTED AT $root:
# `git ls-files`, so untracked scratch files and ignored build output are not
# the roster's problem. It is deliberately not "$root looks like it is inside a
# checkout": a --root naming a SUBDIRECTORY of a repository would otherwise
# enumerate the enclosing repository and report every path outside the injected
# tree as ownerless, answering a question nobody asked. When $root is not itself
# a repository root the universe is empty and this invariant does not run. That
# is not a fail-open on the real path: with no --root the root is derived from
# `git rev-parse --show-toplevel` above, so a default run is always at a
# repository root, and the injected case is a caller who has explicitly named
# the tree to describe.
#
# Residue, bounded and stated rather than silently carried: the record stream
# below is TAB-separated and newline-delimited, so a tracked path containing
# either character misaligns its fields. The roster's own dialect rejects
# whitespace in a glob for the same reason, and no such path exists here.

# The harness trees, on an adopter clone. The release strips the maintainer
# members that own them, so they arrive with no reviewer. A path under one of
# these prefixes that no member claims is not counted as ownerless, whoever
# wrote it: a file the adopter adds there (its own hook, agent or rule) is
# exempt too and gets no reviewer from this check. Granting such files to a
# member of the adopter's own is how they get reviewed. A member that does claim
# one wins as usual, so an adopter granting part of a tree (a member's own
# definition, say) never meets an overbroad finding. These are prefixes, not
# `unowned:` entries, for that reason: an entry reaching a claimed path fails.
# In GAIA's own repository the list is empty, because there every harness path
# has a member and an ownerless one is a real gap.
harness_prefixes='.claude/ .gaia/ .githooks/ .github/audit/'
# gaia:maintainer-only:start
harness_prefixes=''
# gaia:maintainer-only:end

coverage_universe=""
coverage_top="$(git -C "$root" rev-parse --show-toplevel 2>/dev/null || true)"
if [ -n "$coverage_top" ] && [ "$(cd "$coverage_top" 2>/dev/null && pwd -P)" = "$(cd "$root" 2>/dev/null && pwd -P)" ]; then
  coverage_universe="$(git -C "$root" ls-files -z 2>/dev/null | tr '\0' '\n')"
else
  # Say so. A skipped invariant and a satisfied one both end in `roster clean`
  # on stdout, and a caller that cannot tell them apart will read the second
  # meaning from the first. A run against a staging directory that is not
  # itself a checkout takes exactly this path. stderr rather than a finding,
  # because not-run is not a violation, and the exit status stays untouched.
# The marker pair below stays at column 0. The lockstep tests model the strip
# with a line-anchored match, which is stricter than the shipped stripper's
# substring match, so an indented pair survives their model and fails them;
# this file's other pairs sit at column 0 for the same reason.
# gaia:maintainer-only:start
  # The concrete such caller in this repo is
  # .gaia/tests/distribution/16-audit-remit-parity.sh, which runs the scrubbed
  # checker against the staged bundle.
# gaia:maintainer-only:end
  printf 'verify-audit-roster: coverage invariant SKIPPED, %s is not a repository root\n' "$root" >&2
fi

# The same skip, for a --config naming an `auditors:`-less file: there is no
# roster to classify against, and audit_scope_init returns non-zero on it.
# Not-run is not a violation, so this is stderr and the exit status stays
# untouched.
if [ -n "$coverage_universe" ] && [ -z "$class_records" ]; then
  coverage_universe=""
  printf 'verify-audit-roster: coverage invariant SKIPPED, %s carries no auditors\n' "$config" >&2
fi

if [ -n "$coverage_universe" ]; then
  # The classifier decides ownership, exactly as dispatch does: this invariant
  # must never acquire a second opinion about who owns a path. Both injection
  # points are honored, which is why audit_scope_init takes the config here
  # rather than deriving it from the root.
  #
  # This call is the script's dominant cost, because audit_owners_for_paths
  # matches in bash across every tracked path rather than in the awk pass
  # below, and the obvious optimization is to interpolate the compiled regexes
  # into that awk and match there. DO NOT. The
  # compiler would still be shared, but the PRECEDENCE ALGORITHM would not:
  # every claimant first in roster order, then the default member's own tier,
  # then ownerless. Reimplementing that here is precisely the second opinion the
  # paragraph above forbids, and a coverage check that disagrees with dispatch
  # about who owns a path reports the wrong set in both directions. Speed on a
  # read-only advisory job is not worth buying with that.
  # No release context is armed: this classifies the whole tracked tree with no diff, so raw ownership is the answer.
  audit_scope_init "$root" "$config"

  coverage_records="$(
    {
      # The `P` tag looks redundant -- exemption records already carry three
      # fields and owner records two, so the merge below could branch on NF and
      # save a process. It is deliberate, and the tab-in-a-path residue noted
      # above is why: an untagged owner record for such a path arrives with
      # three fields and is read as an EXEMPTION, whose third field then becomes
      # a live regex matched against every other path, failing toward
      # SUPPRESSING findings across the whole tree.
      #
      # The tag does not make such a path harmless, and it is worth being exact
      # about what it does buy, because the damage is wider than the path
      # itself: the record still splits, the segment after the first tab is read
      # as the owner, and since that is not `-` the path counts as OWNED. So a
      # genuine orphan is hidden, and every `unowned:` entry matching the
      # segment before the tab takes an `OWNED_HIT_COUNT` and is reported overbroad on a
      # witness that is not a real path. What the tag buys is that the record
      # stays a path: it cannot become a live exemption regex. Bounded
      # mis-reporting rather than tree-wide suppression, and no such path is
      # tracked here.
      printf '%s\n' "$unowned_records"
      printf '%s\n' "$coverage_universe" | audit_owners_for_paths |
        awk -F'\t' '{ printf "P\t%s\t%s\n", $1, $2 }'
    } | awk -F'\t' -v cap=25 -v harness_prefixes="$harness_prefixes" '
      BEGIN { harness_count = split(harness_prefixes, HARNESS_PREFIX, " ") }
      $1 == "UNOWNED" {
        unowned_entry_count++; UNOWNED_GLOB[unowned_entry_count] = $2; UNOWNED_REGEX[unowned_entry_count] = $3
        OWNED_HIT_COUNT[unowned_entry_count] = 0
        next
      }
      $1 == "P" {
        path = $2; owner = $3
        # ownerless_match_count counts the OWNERLESS matches, which is the tier the list exists
        # to describe.
        ownerless_match_count = 0
        for (i = 1; i <= unowned_entry_count; i++) {
          if (path ~ UNOWNED_REGEX[i]) {
            if (owner != "-") {
              if (OWNED_HIT_COUNT[i] == 0) { OWNED_WITNESS_PATH[i] = path; OWNED_WITNESS_OWNER[i] = owner }
              OWNED_HIT_COUNT[i]++
            } else { ownerless_match_count++ }
          }
        }
        if (owner == "-" && ownerless_match_count == 0) {
          for (h = 1; h <= harness_count; h++) if (index(path, HARNESS_PREFIX[h]) == 1) next
          orphans++; if (orphans <= cap) ORPHAN_PATH[orphans] = path
        }
        next
      }
      END {
        if (orphans > 0) {
          printf "ORPHANCOUNT\t%d\t%d\n", orphans, cap
          for (k = 1; k <= orphans && k <= cap; k++) printf "ORPHAN\t%s\n", ORPHAN_PATH[k]
        }
        for (i = 1; i <= unowned_entry_count; i++) {
          if (OWNED_HIT_COUNT[i] > 0) printf "OVERBROAD\t%s\t%s\t%s\n", UNOWNED_GLOB[i], OWNED_WITNESS_PATH[i], OWNED_WITNESS_OWNER[i]
        }
      }
    '
  )"

  # The ownerless set is ONE finding, not one per path: the repair is a single
  # decision over the set (give these an owner, or declare them unowned), and a
  # directory added with two hundred files in it would otherwise bury every
  # other invariant's output under two hundred blocks.
  if grep -q '^ORPHANCOUNT' <<<"$coverage_records"; then
    findings=$((findings + 1))
    orphan_count="$(printf '%s\n' "$coverage_records" | awk -F'\t' '$1 == "ORPHANCOUNT" { print $2 }')"
    orphan_cap="$(printf '%s\n' "$coverage_records" | awk -F'\t' '$1 == "ORPHANCOUNT" { print $3 }')"
    printf 'verify-audit-roster: FAIL ownerless-path\n'
    printf '  roster: %s\n' "$config"
    printf '  tracked paths dispatching no member and matching no `unowned:` entry: %s\n' "$orphan_count"
    printf '%s\n' "$coverage_records" | awk -F'\t' '$1 == "ORPHAN" { printf "    %s\n", $2 }'
    if [ "$orphan_count" -gt "$orphan_cap" ]; then
      printf '    ... and %d more\n' "$((orphan_count - orphan_cap))"
    fi
    printf '  A path no member owns resolves an empty dispatched set, which the\n'
    printf '  merge gate reads as "nobody is owed a clearance", so a change to it\n'
    printf '  merges having been reviewed by no one. Either grant it to a member\n'
    printf '  in `auditors:`, or declare it in `unowned:` -- which is a reviewed\n'
    printf '  edit to a path the roster itself grants to a member, where adding\n'
    printf '  the file was not.\n'
    printf '\n'
  fi

  while IFS=$'\t' read -r kind first_field second_field third_field; do
    case "$kind" in
      OVERBROAD)
        findings=$((findings + 1))
        printf 'verify-audit-roster: FAIL overbroad-unowned-glob\n'
        printf '  glob:    %s\n' "$first_field"
        printf '  witness: %s (owned by %s)\n' "$second_field" "$third_field"
        printf '  An `unowned:` entry describes a region that dispatches nobody,\n'
        printf '  so one reaching a path a member already owns is broader than the\n'
        printf '  region it exists to describe. This is what stops the list from\n'
        printf '  becoming a rubber stamp: a blanket entry covers owned paths by\n'
        printf '  construction and cannot pass here. Narrow it to the ownerless\n'
        printf '  region.\n'
        printf '\n'
        ;;
    esac
  done < <(printf '%s\n' "$coverage_records")

  # --- Invariant: every remit glob and every `unowned:` glob matches a file ---
  #
  # A glob that matches no tracked file either describes a surface that no
  # longer exists (dead text that reads as coverage) or is a typo that never
  # reaches the path it was written for. The exceptions are the allowlist
  # below and nothing else: a roster comment exempts nothing, because the
  # roster is the file being checked. Each allowlist entry matches no file
  # today and must keep matching one the day it appears: a deliberate
  # extension-family spelling (one glob per JS/TS config extension, the YAML
  # `.yaml` twin of `.yml`), or a shipped `unowned:` entry for a file the
  # release withholds and an adopter commonly adds (a licence, a docs tree).
  # Matching reuses the classifier's own glob compiler so this check never
  # holds a second opinion about what a glob reaches.
  #
  # The marker pair below stays at column 0, like the pair above: the
  # allowlist reader strips comment lines, and the scrub removes the block.
  zero_match_allowlist="$(sed -e '/^#/d' <<'ALLOWLIST'
frontend/*.config.mts
frontend/*.config.cjs
frontend/*.config.js
*.config.ts
*.config.mts
*.config.cjs
*.config.js
.github/workflows/*.yaml
.github/actions/**/*.yaml
**/*.bats
LICENSE
docs/**
# gaia:maintainer-only:start
.gaia/cli/src/**/*.snap
.gaia/cli/*.config.mts
.gaia/cli/*.config.cjs
.gaia/cli/*.config.js
.gaia/codify-declines/**
# gaia:maintainer-only:end
ALLOWLIST
)"

  zero_match_records="$(
    {
      printf '%s\n' "$zero_match_allowlist" | awk 'NF { printf "A\t%s\n", $0 }'
      printf '%s\n' "$raw_records" | awk -F'\t' '$1 == "RAW" { printf "G\tremit of %s\t%s\n", $2, $3 }'
      printf '%s\n' "$unowned_records" | awk -F'\t' '$1 == "UNOWNED" { printf "G\tunowned list\t%s\n", $2 }'
      printf '%s\n' "$coverage_universe" | awk '{ printf "P\t%s\n", $0 }'
    } | awk -F'\t' "$_AUDIT_SCOPE_GLOB_AWK"'
      $1 == "A" { allowed[$2] = 1; next }
      $1 == "G" { glob_count++; glob_source[glob_count] = $2; glob_text[glob_count] = $3; glob_pattern[glob_count] = glob_to_regex($3); next }
      $1 == "P" {
        for (i = 1; i <= glob_count; i++) if (!matched[i] && $2 ~ glob_pattern[i]) matched[i] = 1
        next
      }
      END {
        for (i = 1; i <= glob_count; i++)
          if (!matched[i] && !(glob_text[i] in allowed)) printf "ZEROMATCH\t%s\t%s\n", glob_source[i], glob_text[i]
      }
    '
  )"

  while IFS=$'\t' read -r kind first_field second_field; do
    case "$kind" in
      ZEROMATCH)
        findings=$((findings + 1))
        printf 'verify-audit-roster: FAIL zero-match-glob\n'
        printf '  where:   %s\n' "$first_field"
        printf '  glob:    %s\n' "$second_field"
        printf '  roster:  %s\n' "$config"
        printf '  This glob matches no tracked file, so it either names a surface\n'
        printf '  that no longer exists or never reached the path it was written\n'
        printf '  for. Delete it, or correct it. A deliberate extension-family\n'
        printf '  spelling belongs on the allowlist inside this script; a roster\n'
        printf '  comment exempts nothing.\n'
        printf '\n'
        ;;
    esac
  done < <(printf '%s\n' "$zero_match_records")
fi

_verify_roster_sibling_loaded=coverage
