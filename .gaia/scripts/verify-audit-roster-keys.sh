#!/usr/bin/env bash
# verify-audit-roster-keys.sh: the light-review scalar keys and the
# release-skip key invariants.
#
# One contiguous span of the roster check, moved here unchanged.
# verify-audit-roster.sh sources it from its own directory at the point the
# span stood, so it runs in the same order over the same globals; it is never
# run on its own. Its last line tells the parent it was read to the end.
#
# Bash 3.2 compatible (macOS-default bash).

# SC2016: single-quoted awk and printf text is literal, as in the parent.
# shellcheck disable=SC2016,SC2034,SC2154  # the roster globals cross files: the parent and the other siblings set and read them

# --- Invariant: the light-review scalar keys ---------------------------------
#
# The router reads these values as typed, so each is checked as typed: no
# unquoting, so a quoted `"true"` or `"50"` is a malformed value rather than a
# value one reader accepts and another does not. The ceiling is the router's
# built-in maximum; a cap above it is a roster that states a budget the router
# will not apply.

light_line_cap_ceiling=50

while IFS=$'\t' read -r kind member value; do
  case "$kind" in
    REVIEW)
      if [ "$value" != "true" ] && [ "$value" != "false" ]; then
        findings=$((findings + 1))
        printf 'verify-audit-roster: FAIL invalid-light-review\n'
        printf '  member: %s\n' "$member"
        printf '  value:  %s\n' "$value"
        printf '  `light_review` is the literal `true` or `false`. The router opts a\n'
        printf '  member in only on `true`, so any other spelling silently leaves the\n'
        printf '  member on full review while the roster reads as if it opted in.\n'
        printf '\n'
      fi
      ;;
    CAP)
      cap_problem=""
      case "$value" in
        ''|*[!0-9]*|0*) cap_problem="not a positive integer" ;;
        *)
          if [ "${#value}" -gt 3 ] || [ "$value" -gt "$light_line_cap_ceiling" ]; then
            cap_problem="above the ceiling of ${light_line_cap_ceiling}; the router clamps it, so the roster would state a cap that does not apply"
          fi
          ;;
      esac
      if [ -n "$cap_problem" ]; then
        findings=$((findings + 1))
        printf 'verify-audit-roster: FAIL invalid-light-line-cap\n'
        printf '  member: %s\n' "$member"
        printf '  value:  %s\n' "$value"
        printf '  reason: %s\n' "$cap_problem"
        printf '  `light_line_cap` is a positive integer no greater than %s.\n' "$light_line_cap_ceiling"
        printf '\n'
      fi
      ;;
  esac
done < <(printf '%s\n' "$light_records")

# --- Invariant: the release-skip key -------------------------------------------
#
# Checked as typed, like the light-review keys: the classifier honors only the
# raw literal `true`, so a quoted or capitalized spelling would read as opted in
# on the roster and as not opted in at dispatch. The default member owns whatever
# no claimant claims, so skipping GAIA-owned files there would hide them from
# every member.

skip_default_member="$(printf '%s\n' "$class_records" | awk '$1 == "DEFAULT" { print $2; exit }')"

while IFS=$'\t' read -r kind member value; do
  [ "$kind" = "RELEASESKIP" ] || continue
  skip_problem=""
  if [ "$value" != "true" ] && [ "$value" != "false" ]; then
    skip_problem="not the literal \`true\` or \`false\`"
  elif [ "$member" = "$skip_default_member" ]; then
    skip_problem="the default member cannot carry the key"
  fi
  if [ -n "$skip_problem" ]; then
    findings=$((findings + 1))
    printf 'verify-audit-roster: FAIL invalid-release-skip-key\n'
    printf '  member: %s\n' "$member"
    printf '  value:  %s\n' "$value"
    printf '  reason: %s\n' "$skip_problem"
    printf '  `skip_gaia_release_changes` is the literal `true` or `false`, on a\n'
    printf '  claimant member only. The classifier honors only `true`, so any other\n'
    printf '  spelling leaves the member reviewing release-applied files while the\n'
    printf '  roster reads as if it opted out. Set it to `true`, `false`, or drop it.\n'
    printf '\n'
  fi
done < <(printf '%s\n' "$raw_records")

_verify_roster_sibling_loaded=keys
