# shellcheck shell=bash
#
# The filing script's outcome records, read for the one question two callers
# share: which keys did the filer refuse because the branch wrote the site.
# Sourced by audit-dispositions-check.sh and audit-loop-state-lib.sh, which do
# not source each other, so the logic lives here once. Sources nothing and
# runs nothing at source time. Bash 3.2 compatible. Never `cd`s.

# gaia_filing_refused_keys <run-folder>: a compact JSON array of
# [member, finding_class, path, line], one per key whose latest outcome across
# the run's filing-outcomes-<r>.jsonl files is refused-authored. Rounds are
# read numerically, so round 10 follows round 9. A line that does not parse is
# skipped: a lost record leaves a key pending, never refused. Prints [] when
# nothing qualifies or jq fails.
gaia_filing_refused_keys() {
  local outcome_file base round chunks="" refused
  for outcome_file in "$1"/filing-outcomes-*.jsonl; do
    [ -e "$outcome_file" ] || continue
    base="${outcome_file##*/}"
    [[ "$base" =~ ^filing-outcomes-([0-9]+)\.jsonl$ ]] || continue
    round=$((10#${BASH_REMATCH[1]}))
    chunks="$chunks$(jq -c -R --argjson round "$round" 'fromjson? | select(type == "object" and (.key | type) == "object") | . + {round: $round}' <"$outcome_file" 2>/dev/null)"$'\n'
  done
  refused="$(printf '%s' "$chunks" | jq -c -s 'sort_by(.round) | group_by(.key | [.member, .finding_class, .path, .line]) | map(last)
    | map(select(.outcome == "refused-authored") | .key | [.member, .finding_class, .path, .line])' 2>/dev/null)" || refused=""
  printf '%s\n' "${refused:-[]}"
  return 0
}
