#!/usr/bin/env bash
# shellcheck shell=bash
#
# Prints the CHANGELOG sections an update crosses: every `## [x.y.z]` block
# strictly newer than <baseline> through <latest>, in file order, without the
# `[Unreleased]` block or the trailing link-reference list.
#
#   changelog-range.sh <baseline> <latest> [<changelog file>]
#
# Reads the file when one is given, stdin otherwise. /update-gaia runs it on
# the fetched CHANGELOG to show the release notes, and on the release copy to
# recover documented adopter actions, so the two always agree on the range.
#
# Exit codes: 0 printed the range (possibly empty), 2 usage error or an
# unreadable file.

set -euo pipefail

usage() {
  echo "usage: changelog-range.sh <baseline x.y.z> <latest x.y.z> [<changelog file>]" >&2
  exit 2
}

[ "$#" -ge 2 ] && [ "$#" -le 3 ] || usage

version_pattern='^[0-9]+\.[0-9]+\.[0-9]+$'
[[ "$1" =~ $version_pattern ]] || usage
[[ "$2" =~ $version_pattern ]] || usage

if [ "$#" -eq 3 ] && [ ! -r "$3" ]; then
  echo "changelog-range.sh: cannot read $3" >&2
  exit 2
fi

# Versions compare numerically per component, so 1.10.0 sorts above 1.9.0.
# The link-reference rule ends printing at the first `[x.y.z]: http...` line,
# which Keep a Changelog places after the last section.
awk -v baseline="$1" -v latest="$2" '
  function vcmp(a,b,   x,y,i){split(a,x,".");split(b,y,".");for(i=1;i<=3;i++){if((x[i]+0)>(y[i]+0))return 1;if((x[i]+0)<(y[i]+0))return -1}return 0}
  /^## \[Unreleased\]/           {printing=0; next}
  /^\[[^][]+\]:[[:space:]]*http/ {printing=0; next}
  /^## \[[0-9]+\.[0-9]+\.[0-9]+\]/ {
    v=$0; sub(/^## \[/,"",v); sub(/\].*/,"",v)
    printing=(vcmp(v,baseline)>0 && vcmp(v,latest)<=0)
  }
  printing {print}
' "${3:--}"
