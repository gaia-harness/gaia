#!/usr/bin/env bash
# verify-audit-roster-dialect.sh: the remit-region and unowned-glob dialect
# invariant.
#
# One contiguous span of the roster check, moved here unchanged.
# verify-audit-roster.sh sources it from its own directory at the point the
# span stood, so it runs in the same order over the same globals; it is never
# run on its own. Its last line tells the parent it was read to the end.
#
# Bash 3.2 compatible (macOS-default bash).

# SC2016: single-quoted awk and printf text is literal, as in the parent.
# shellcheck disable=SC2016,SC2034,SC2154  # the roster globals cross files: the parent and the other siblings set and read them

# --- Invariant: the remit-region and unowned-glob dialect --------------------
#
# One awk pass, which is where the classifier's own glob compiler lives too.
# It reads the record streams, tab-normalized, and emits one machine-readable
# line per violation for the shell to verify and render.
#
# The `unowned:` stream is here for one reason: this pass holds the single copy
# of glob_items(), and the dialect gate must not become a second one. Its
# entries are only classified, never compared against a claimant's.

violation_records="$(
  {
    printf '%s\n' "$class_records" |
      awk '{ record_kind = $1; member = $2; record_remainder = $0; sub(/^[^ ]+[ ]+[^ ]+[ ]*/, "", record_remainder); printf "%s\t%s\t%s\n", record_kind, member, record_remainder }'
    printf '%s\n' "$raw_records"
    printf '%s\n' "$region_records"
    printf '%s\n' "$unowned_records"
    printf '%s\n' "$light_records"
    printf '%s\n' "$skip_class_records"
  } | awk -F'\t' '
    # --- The glob layer ------------------------------------------------------
    #
    # Splits a glob into items: "**" (a whole-segment globstar) or a segment
    # pattern. Returns the item count, or -1 with REJECTION_REASON naming why the pair is
    # undecidable. Everything rejected here is either a construct the classifier
    # silently escapes into a literal or a shape the segment model cannot
    # represent; deciding either would be the fail-open this check exists to
    # delete.
    function glob_items(glob, items,   item_count, i, segment) {
      REJECTION_REASON = ""
      if (glob == "") { REJECTION_REASON = "the glob is empty"; return -1 }
      if (index(glob, " ") || index(glob, "\t")) { REJECTION_REASON = "the glob contains whitespace, which the classifier record contract cannot carry"; return -1 }
      if (index(glob, "?")) { REJECTION_REASON = "the glob contains `?`, which the classifier does not treat as a wildcard"; return -1 }
      if (index(glob, "[") || index(glob, "]")) { REJECTION_REASON = "the glob contains a bracket, which the classifier escapes into a literal"; return -1 }
      if (index(glob, "{") || index(glob, "}")) { REJECTION_REASON = "the glob contains a brace, which the classifier escapes into a literal"; return -1 }
      if (index(glob, "\\")) { REJECTION_REASON = "the glob contains a backslash, which the classifier escapes into a literal"; return -1 }
      if (index(glob, "***")) { REJECTION_REASON = "the glob contains a run of three or more `*`"; return -1 }
      item_count = split(glob, items, "/")
      for (i = 1; i <= item_count; i++) {
        segment = items[i]
        if (segment == "") { REJECTION_REASON = "the glob has an empty path segment"; return -1 }
        if (segment == "**") continue
        if (index(segment, "**")) { REJECTION_REASON = "`**` appears inside the segment \"" segment "\" rather than as a whole segment"; return -1 }
      }
      return item_count
    }

    # Only the count is read (the reader-drift comparison below); the compiled
    # regex itself is never needed.
    $1 == "GLOB" || $1 == "DEFAULTGLOB" { compiled_glob_count[$2]++; next }
    $1 == "MEMBER" { member_count++; members[member_count] = $2; next }
    $1 == "RAW" { raw_glob_count[$2]++; raw[$2, raw_glob_count[$2]] = $3; next }
    # An exact field compare, so REGIONOK / REGIONMISSING / REGIONDUP /
    # REGIONUNBALANCED / REGIONREVERSED never match the REGION handler. These
    # four shape records fall through every handler here and are ignored,
    # which is right: they are rendered shell-side, and a member whose region
    # could not be read carries no has_region entry, so the parity section below
    # skips it.
    $1 == "REGIONOK" { has_region[$2] = 1; next }
    $1 == "REGION" { region_glob_count[$2]++; region_globs[$2, region_glob_count[$2]] = $3; next }
    # Field 3 is the compiled regex, which this pass never reads: it classifies
    # the raw glob, exactly as the claimant and region positions do.
    $1 == "UNOWNED" { unowned_entry_count++; unowned_globs[unowned_entry_count] = $2; next }
    $1 == "RELEASESKIP" && $3 == "true" { raw_skip[$2] = 1; next }
    $1 == "SKIPREADER" { class_skip_reader = 1; next }
    $1 == "SKIPCLASS" { class_skip[$2] = 1; next }
    $1 == "HARDFULL" { light_glob_count++; light_glob_member[light_glob_count] = $2; light_glob_text[light_glob_count] = $3; next }

    END {
      # The scrape and the classifier agree about how many globs each member
      # declares, or neither the regexes nor the raw globs below line up and no
      # verdict is produced at all.
      drift = 0
      for (i = 1; i <= member_count; i++) {
        member = members[i]
        if (member in seen_drift_member) continue
        seen_drift_member[member] = 1
        if ((raw_glob_count[member] + 0) != (compiled_glob_count[member] + 0)) {
          printf "MISMATCH\t%s\t%d\t%d\n", member, raw_glob_count[member] + 0, compiled_glob_count[member] + 0
          drift = 1
        }
      }
      if (class_skip_reader) {
        for (member in raw_skip) if (!(member in class_skip)) { printf "SKIPDRIFT\t%s\tthis check\tthe classifier\n", member; drift = 1 }
        for (member in class_skip) if (!(member in raw_skip)) { printf "SKIPDRIFT\t%s\tthe classifier\tthis check\n", member; drift = 1 }
      }
      if (drift) exit 0

      # --- Remit region parity, and the region-glob dialect -------------------
      #
      # Parity is an ORDERED string comparison between a member remit region and
      # its roster entry; it needs no glob-language decision. The dialect
      # classification does, and it reuses glob_items() rather than a second
      # copy of it. That reuse is also why every region glob of the DEFAULT
      # member and of a lone claimant is classified here: a lone claimant plus
      # a default is the whole adopter roster shape.
      #
      # Membership is a nested string comparison over lists of at most a dozen
      # globs. A hash keyed on the glob string would have to handle SUBSEP
      # collisions to be correct; the nested loop is clearer and fast enough.
      split("", seen_region_member)
      for (i = 1; i <= member_count; i++) {
        member = members[i]
        if (member in seen_region_member) continue
        seen_region_member[member] = 1
        if (!(member in has_region)) continue
        for (k = 1; k <= (region_glob_count[member] + 0); k++) {
          if (glob_items(region_globs[member, k], REGION_ITEMS) < 0)
            printf "REMITUNDECIDABLE\t%s\t%s\t%s\n", member, region_globs[member, k], REJECTION_REASON
        }
        missing_count = 0; extra_count = 0
        for (raw_index = 1; raw_index <= (raw_glob_count[member] + 0); raw_index++) {
          hit = 0
          for (region_index = 1; region_index <= (region_glob_count[member] + 0); region_index++) if (raw[member, raw_index] == region_globs[member, region_index]) { hit = 1; break }
          if (!hit) { printf "REMITMISSING\t%s\t%s\n", member, raw[member, raw_index]; missing_count++ }
        }
        for (region_index = 1; region_index <= (region_glob_count[member] + 0); region_index++) {
          hit = 0
          for (raw_index = 1; raw_index <= (raw_glob_count[member] + 0); raw_index++) if (region_globs[member, region_index] == raw[member, raw_index]) { hit = 1; break }
          if (!hit) { printf "REMITEXTRA\t%s\t%s\n", member, region_globs[member, region_index]; extra_count++ }
        }
        # Order is only meaningful once the two lists hold the same globs; a
        # set comparison must never pass a permuted region, so the first
        # differing position is reported.
        if (missing_count == 0 && extra_count == 0 && (region_glob_count[member] + 0) == (raw_glob_count[member] + 0)) {
          for (position = 1; position <= (raw_glob_count[member] + 0); position++) {
            if (raw[member, position] != region_globs[member, position]) {
              printf "REMITORDER\t%s\t%d\t%s\t%s\n", member, position, raw[member, position], region_globs[member, position]
              break
            }
          }
        }
      }

      # --- The `unowned:` dialect ---------------------------------------------
      #
      # The one glob position that had no bounded-dialect gate. Its sibling, a
      # region glob, fails undecidable-remit-glob -- and this position needs it
      # MORE, because an exemption that compiles wider than its author read it
      # does not merely misdescribe a remit, it SUPPRESSES the ownerless
      # finding for every extra path it reaches. `docs**` is the concrete
      # shape: `**` inside a segment rather than as a whole one, which the
      # classifier escapes into `^docs.*$`, crossing `/` and quietly exempting
      # `docsextra/` too.
      #
      # Reached only past the reader-drift exit above, like every other verdict
      # here: two readers that disagree about the roster are the finding to fix
      # first, and nothing downstream of them is worth trusting.
      for (i = 1; i <= (unowned_entry_count + 0); i++) {
        if (glob_items(unowned_globs[i], UNOWNED_ITEMS) < 0)
          printf "UNOWNEDUNDECIDABLE\t%s\t%s\n", unowned_globs[i], REJECTION_REASON
      }

      # --- The light_hard_full dialect and coverage --------------------------
      #
      # A hard-Full glob must fit the dialect, and must lie inside what the
      # member owns. Coverage is decided here only by the two string relations
      # that are exact in the segment model: identical to an owned glob, or
      # beginning with the literal prefix of an owned `<prefix>/**`. A glob
      # with no wildcard at all is a concrete path, so the shell side tests it
      # with the classifier matcher rather than a second matcher here. Every
      # other wildcard shape is reported rather than guessed at.
      for (i = 1; i <= (light_glob_count + 0); i++) {
        member = light_glob_member[i]; glob = light_glob_text[i]
        if (glob_items(glob, LIGHT_ITEMS) < 0) {
          printf "LIGHTUNDECIDABLE\t%s\t%s\t%s\n", member, glob, REJECTION_REASON
          continue
        }
        covered = 0
        for (k = 1; k <= (raw_glob_count[member] + 0) && !covered; k++) {
          owned = raw[member, k]
          if (owned == glob) covered = 1
          else if (length(owned) > 3 && substr(owned, length(owned) - 2) == "/**") {
            owned_prefix = substr(owned, 1, length(owned) - 2)
            if (!index(owned_prefix, "*") && index(glob, owned_prefix) == 1) covered = 1
          }
        }
        if (covered) continue
        if (!index(glob, "*")) printf "LIGHTLITERAL\t%s\t%s\n", member, glob
        else printf "LIGHTUNCOVERED\t%s\t%s\n", member, glob
      }
    }
  '
)"

while IFS=$'\t' read -r kind first_field second_field third_field fourth_field; do
  case "$kind" in
    MISMATCH)
      findings=$((findings + 1))
      printf 'verify-audit-roster: FAIL roster-reader-drift\n'
      printf '  member: %s\n' "$first_field"
      printf '  globs scraped by this check: %s; globs compiled by the classifier: %s\n' "$second_field" "$third_field"
      printf '  This check scrapes the raw globs while the classifier compiles\n'
      printf '  them, and the two disagree, so no remit-parity verdict was\n'
      printf '  produced: one of the two readers has drifted from the roster\n'
      printf '  format. The remit-region parity, unowned-dialect and\n'
      printf '  light_hard_full dialect-and-coverage checks below did not run\n'
      printf '  either, for the same reason. Fix that before trusting this check.\n'
      printf '\n'
      ;;
    SKIPDRIFT)
      findings=$((findings + 1))
      printf 'verify-audit-roster: FAIL roster-reader-drift\n'
      printf '  member: %s\n' "$first_field"
      printf '  `skip_gaia_release_changes` is read as true by %s and not by %s.\n' "$second_field" "$third_field"
      printf '  The two readers disagree about the roster, so no remit-parity\n'
      printf '  verdict was produced, and the unowned-dialect and light_hard_full\n'
      printf '  dialect-and-coverage checks below did not run either. Fix that\n'
      printf '  before trusting this check.\n'
      printf '\n'
      ;;
    REMITMISSING)
      findings=$((findings + 1))
      printf 'verify-audit-roster: FAIL remit-glob-missing\n'
      printf '  member:     %s\n' "$first_field"
      printf '  glob:       %s\n' "$second_field"
      printf '  roster:     %s\n' "$config"
      printf '  agent file: .claude/agents/%s.md\n' "$first_field"
      printf '  The roster grants this member the glob above and its remit region\n'
      printf '  omits it, so the dispatched member filters the changed-file list\n'
      printf '  against a narrower remit than the one it was dispatched for and\n'
      printf '  self-skips work the gate sent it to do. The roster is the\n'
      printf '  authority; regenerate the region rather than editing the roster\n'
      printf '  down to fit it.\n'
      printf '  repair:  bash .gaia/scripts/write-audit-remits.sh\n'
      printf '\n'
      ;;
    REMITEXTRA)
      findings=$((findings + 1))
      printf 'verify-audit-roster: FAIL remit-glob-ungranted\n'
      printf '  member:     %s\n' "$first_field"
      printf '  glob:       %s\n' "$second_field"
      printf '  roster:     %s\n' "$config"
      printf '  agent file: .claude/agents/%s.md\n' "$first_field"
      printf '  This remit region claims a glob the roster does not grant this\n'
      printf '  member, so a file matching it reads as covered while dispatching\n'
      printf '  nobody: no clearance is ever demanded for it and the diff clears\n'
      printf '  the merge gate having been reviewed by no one. Regenerate the\n'
      printf '  region, or grant the glob in the roster if the claim is the\n'
      printf '  intended one.\n'
      printf '  repair:  bash .gaia/scripts/write-audit-remits.sh\n'
      printf '\n'
      ;;
    REMITORDER)
      findings=$((findings + 1))
      printf 'verify-audit-roster: FAIL remit-glob-order\n'
      printf '  member:   %s\n' "$first_field"
      printf '  position: %s\n' "$second_field"
      printf '  roster:   %s\n' "$third_field"
      printf '  region:   %s\n' "$fourth_field"
      printf '  The region holds exactly the globs the roster grants, in a\n'
      printf '  different order. Ownership is first-match-wins over roster order,\n'
      printf '  so a reordered region is a different reading order and a path two\n'
      printf '  of its globs both match resolves differently than dispatch does.\n'
      printf '  Parity is ordered; it is never a set comparison.\n'
      printf '  repair:  bash .gaia/scripts/write-audit-remits.sh\n'
      printf '\n'
      ;;
    REMITUNDECIDABLE)
      findings=$((findings + 1))
      printf 'verify-audit-roster: FAIL undecidable-remit-glob\n'
      printf '  member:  %s\n' "$first_field"
      printf '  glob:    %s\n' "$second_field"
      printf '  reason:  %s\n' "$third_field"
      printf '  This check decides the classifier three-construct dialect only:\n'
      printf '  literals, `*` within one segment, and a whole-segment `**`. It\n'
      printf '  fails an undecidable glob rather than passing it, because a glob\n'
      printf '  silently called harmless is the fail-open it exists to catch.\n'
      printf '  Every glob inside a region is classified, the default member and\n'
      printf '  a lone claimant included. Express the glob in the dialect, or\n'
      printf '  teach the classifier and this check the new construct together.\n'
      printf '  repair:  bash .gaia/scripts/write-audit-remits.sh\n'
      printf '\n'
      ;;
    UNOWNEDUNDECIDABLE)
      findings=$((findings + 1))
      printf 'verify-audit-roster: FAIL undecidable-unowned-glob\n'
      printf '  glob:    %s\n' "$first_field"
      printf '  roster:  %s\n' "$config"
      printf '  reason:  %s\n' "$second_field"
      printf '  This check decides the classifier three-construct dialect only:\n'
      printf '  literals, `*` within one segment, and a whole-segment `**`. An\n'
      printf '  `unowned:` entry outside it compiles to something wider than it\n'
      printf '  reads -- `docs**` becomes `^docs.*$`, which crosses `/` -- and a\n'
      printf '  wider exemption does not misdescribe anything, it SUPPRESSES the\n'
      printf '  ownerless finding for every extra path it reaches. That is the\n'
      printf '  silent green this invariant exists to delete, so the entry is\n'
      printf '  REPORTED here and the run fails. Reporting is not quarantine:\n'
      printf '  the coverage pass below still compiles and matches the entry, so\n'
      printf '  it goes on exempting every path it reaches until you fix it.\n'
      printf '  Express it in the dialect.\n'
      printf '\n'
      ;;
    LIGHTUNDECIDABLE)
      findings=$((findings + 1))
      printf 'verify-audit-roster: FAIL undecidable-light-hard-full-glob\n'
      printf '  member:  %s\n' "$first_field"
      printf '  glob:    %s\n' "$second_field"
      printf '  reason:  %s\n' "$third_field"
      printf '  A `light_hard_full` glob outside the classifier dialect compiles to\n'
      printf '  something other than it reads, so the router would force a full\n'
      printf '  review on a different set of paths than the roster states. Express\n'
      printf '  it in the dialect.\n'
      printf '\n'
      ;;
    LIGHTUNCOVERED)
      findings=$((findings + 1))
      printf 'verify-audit-roster: FAIL light-hard-full-glob-uncovered\n'
      printf '  member:  %s\n' "$first_field"
      printf '  glob:    %s\n' "$second_field"
      printf '  roster:  %s\n' "$config"
      printf '  This `light_hard_full` glob is not one of the member'"'"'s own globs and\n'
      printf '  does not sit under a literal `<prefix>/**` the member owns, so it\n'
      printf '  either names paths the member is never dispatched for or cannot be\n'
      printf '  shown to lie inside what it owns. Both read as a hard-Full rule that\n'
      printf '  protects nothing. Grant the surface to the member first, or restate\n'
      printf '  the glob as one the member already owns.\n'
      printf '\n'
      ;;
    LIGHTLITERAL)
      # A wildcard-free glob is one concrete path: the classifier's own matcher
      # decides whether any owned glob contains it. Exit 2 from the matcher is
      # a finding, never a pass.
      light_literal_covered=0
      light_literal_failed=0
      while IFS=$'\t' read -r raw_kind raw_member owned_glob; do
        [ "$raw_kind" = "RAW" ] && [ "$raw_member" = "$first_field" ] || continue
        audit_glob_matches "$owned_glob" "$second_field"
        case "$?" in
          0) light_literal_covered=1; break ;;
          1) ;;
          *) light_literal_failed=1 ;;
        esac
      done < <(printf '%s\n' "$raw_records")
      if [ "$light_literal_covered" -eq 0 ]; then
        findings=$((findings + 1))
        printf 'verify-audit-roster: FAIL light-hard-full-glob-uncovered\n'
        printf '  member:  %s\n' "$first_field"
        printf '  glob:    %s\n' "$second_field"
        printf '  roster:  %s\n' "$config"
        if [ "$light_literal_failed" -eq 1 ]; then
          printf '  The glob matcher failed (exit 2) while testing this path against the\n'
          printf '  member'"'"'s globs, so coverage is unproven.\n'
        else
          printf '  This path is outside every glob the member owns, so a hard-Full rule\n'
          printf '  on it protects nothing. Grant it to the member first, or drop it.\n'
        fi
        printf '\n'
      fi
      ;;
  esac
done < <(printf '%s\n' "$violation_records")

_verify_roster_sibling_loaded=dialect
