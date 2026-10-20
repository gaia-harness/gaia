# shellcheck shell=bash
# GAIA usage-ledger active time: GAIA_USAGE_ACTIVE_JQ, the jq defs that turn the
# activity facts the flusher appends into busy windows at read time, give each
# segment the window pieces its spend produced, and union a row's pieces
# clipped to its wall-clock span. Defines that variable only; sourcing runs no
# command.
#
# The defs expect GAIA_USAGE_JQ_DEFS (usage-lib.sh) and GAIA_USAGE_RESOLVE_JQ
# (usage-resolve-lib.sh) ahead of them and call nothing else. The record
# readout's program is exactly those two plus this one, and jq resolves every
# name at compile time, so one call into a pricing or model def breaks that
# readout. Every def here is a usage_active_* entry point or starts
# _usage_active_, because a later def of the same name silently shadows an
# earlier one.
#
# Facts arrive as `act` objects on segment rows, cursor rows and backfill
# `activity` rows, in the encoding usage-parse-lib.sh writes: `b` in epoch
# milliseconds, every other time a whole-second offset from it, openers delta
# encoded, chunks and waits as [start, length], turn lengths as [end, seconds].
# A segment is covered when it carries the key `act` or an activity row of its
# session and source covers its span; only covered segments get pieces.

# shellcheck disable=SC2034,SC2016  # consumed by sourcing scripts; jq source, no shell expansion
GAIA_USAGE_ACTIVE_JQ='
def _usage_active_source: if (.agent_id | type) == "string" then .agent_id else "main" end;

# A segment as both the index and a readout group see it: a group may carry
# fields the index never saw (rkey, _t, prices), so only the row fields count.
def _usage_active_identity:
  [.session_id, .agent_id, .key, .inherit, .first_ts, .last_ts, .messages, .agent_type] | tojson;

# One facts object in fractional epoch seconds. b + 1000 * offset is an exact
# integer, so dividing once lands as close to usage_epoch of the same stamp as
# a double allows. A malformed object decodes to nothing, as a torn row reads.
def _usage_active_decode:
  select((.b | type) == "number")
  | try (.b as $base
      | def _usage_active_at($offset): ($base + 1000 * $offset) / 1000;
      {entrypoint: .e,
       openers: (reduce (.o // [])[] as $gap ({sum: 0, at: []}; .sum += $gap | .at += [_usage_active_at(.sum)]) | .at),
       chunks: [(.c // [])[] | [_usage_active_at(.[0]), _usage_active_at(.[0] + .[1])]],
       waits: [(.w // [])[] | [_usage_active_at(.[0]), _usage_active_at(.[0] + .[1])]],
       asked: [(.q // [])[] | select(.[0] | type == "string") | {id: .[0], at: _usage_active_at(.[1])}],
       answered: [(.r // [])[] | select(.[0] | type == "string") | {id: .[0], at: _usage_active_at(.[1])}],
       lengths: [(.d // [])[] | {end: _usage_active_at(.[0]), seconds: .[1]}]})
    catch empty;

# How many of the ascending $sorted are below $value (or equal to it, when
# $inclusive): a binary search, so a long session stays linear-logarithmic.
def _usage_active_count($sorted; $value; $inclusive):
  {low: 0, high: ($sorted | length)}
  | until(.low >= .high;
      ((.low + .high) / 2 | floor) as $middle
      | if $sorted[$middle] < $value or ($inclusive and $sorted[$middle] == $value)
        then .low = $middle + 1 else .high = $middle end)
  | .low;

def _usage_active_subtract($interval; $holes):
  reduce ([$holes[] | select(.[0] < $interval[1] and .[1] > $interval[0])] | sort[]) as $hole
      ({cursor: $interval[0], pieces: []};
    (if $hole[0] > .cursor then .pieces += [[.cursor, $hole[0]]] else . end)
    | .cursor = ([.cursor, $hole[1]] | max))
  | .pieces + (if .cursor < $interval[1] then [[.cursor, $interval[1]]] else [] end);

# The first $seconds of ascending $pieces: trims from the end, never extends.
def _usage_active_trim($pieces; $seconds):
  reduce $pieces[] as $piece ({left: $seconds, kept: []};
    if .left <= 0 then .
    elif $piece[1] - $piece[0] <= .left then .kept += [$piece] | .left -= ($piece[1] - $piece[0])
    else .kept += [[$piece[0], $piece[0] + .left]] | .left = 0 end)
  | .kept;

# The busy windows of an interactive main thread. Turn k runs from opener k to
# the latest end of the chunks whose first stamp falls before opener k+1, less
# its waits on the maintainer, capped by the smallest turn length that ends in
# the turn. Openers from every facts object merge by time: attachments are
# never openers, and the parse collapses a dequeue with its own prompt within
# a range. A turn length only lowers a figure, because some report a duration
# reaching back past the previous prompt.
def _usage_active_turns($facts):
  ([$facts[].chunks[]] | unique) as $chunks
  | if ($chunks | length) == 0 then [] else
      ([$facts[].openers[]] | unique) as $explicit_openers
      | (if ($explicit_openers | length) == 0 or $chunks[0][0] < $explicit_openers[0]
         then [$chunks[0][0]] + $explicit_openers else $explicit_openers end) as $openers
      | (reduce $chunks[] as $chunk ([];
          (_usage_active_count($openers; $chunk[0]; true) - 1) as $turn
          | .[$turn] = ([.[$turn], $chunk[1]] | max))) as $turn_ends
      | (reduce $facts[].asked[] as $ask ({}; .[$ask.id] = ([.[$ask.id], $ask.at] | map(numbers) | min))) as $asked
      | (reduce $facts[].answered[] as $answer ({}; .[$answer.id] = ([.[$answer.id], $answer.at] | map(numbers) | min))) as $answered
      | ([$facts[].waits[]] + [$asked | to_entries[] | select($answered[.key] != null) | [.value, $answered[.key]]]
          | unique) as $waits
      | [$asked | to_entries[] | select($answered[.key] == null) | .value] as $open_wait_starts
      | ([$facts[].lengths[]] | unique | sort_by(.end)) as $lengths
      | ($lengths | map(.end)) as $length_ends
      | [range(0; $openers | length) as $index
          | $openers[$index] as $start
          | $turn_ends[$index] as $end
          | select($end != null and $end > $start)
          | ($openers[$index + 1] // infinite) as $next
          | ([$lengths[_usage_active_count($length_ends; $start; false):_usage_active_count($length_ends; $next; false)][] | .seconds]
              | min) as $cap
          | ($waits + [$open_wait_starts[] | select(. >= $start and . < $next) | [., $end]]) as $holes
          | _usage_active_subtract([$start, $end]; $holes) as $pieces
          | (if $cap == null then $pieces else _usage_active_trim($pieces; $cap) end)[]]
    end;

# A window cut at the territory boundaries it crosses, each part tagged with
# the index of the territory holding it.
def _usage_active_split($window; $boundaries):
  {territory: _usage_active_count($boundaries; $window[0]; true), cursor: $window[0], parts: []}
  | until(.cursor >= $window[1];
      ([$window[1], ($boundaries[.territory] // infinite)] | min) as $end
      | (if $end > .cursor then .parts += [{territory, piece: [.cursor, $end]}] else . end)
      | .cursor = ([.cursor, $end] | max) | .territory += 1)
  | .parts;

# The pieces of each of the $ordered segments of one source (ascending by
# start). Territory i ends where territory i+1 begins: at the latest split stamp in
# (last_ts of i, first_ts of i+1], the same stamps the parse grouping splits
# spend at, else at first_ts of i+1. The first opens at minus infinity and the
# last closes at plus infinity. Boundary i lies at or after first_ts of i and
# at or before first_ts of i+1, so the boundaries ascend and no instant lands
# in two territories.
def _usage_active_attribute($ordered; $windows; $splits):
  [range(1; $ordered | length) as $index
    | $ordered[$index - 1]._active_end as $previous_end
    | $ordered[$index]._active_start as $next_start
    | (_usage_active_count($splits; $next_start; true) - 1) as $latest
    | if $latest >= 0 and $splits[$latest] > $previous_end then $splits[$latest] else $next_start end] as $boundaries
  | reduce ($windows[] | _usage_active_split(.; $boundaries)[]) as $part
      ([range(0; $ordered | length) | []]; .[$part.territory] += [$part.piece]);

# $rows: raw ledger rows of the sessions concerned (any kind may be missing).
# $segments: the resolved segments of those sessions. The index is keyed by segment,
# so its work grows with the sessions in $segments, not with the ledger.
def usage_active_index($rows; $segments):
  (($rows // []) | usage_by_session_id) as $rows_by_session
  | [($segments // [])[] | objects
      | . + {_active_start: (._t // (.first_ts | usage_epoch)), _active_end: ((.last_ts // .first_ts) | usage_epoch),
             _active_identity: _usage_active_identity}
      | select(._active_start != null)]
  | unique_by(._active_identity) | group_by(.session_id | tojson)
  | {segments: (reduce .[] as $session_segments ({};
      usage_of_session_id($rows_by_session; $session_segments[0].session_id) as $session_rows
      | ([$session_rows[] | select(.kind == "binding" and (.type == "declare" or .type == "close" or .type == "start" or .type == "research"))
          | .ts | usage_epoch | numbers] | unique) as $splits
      | [$session_rows[] | select(.kind == "activity" and (.cover | type) == "array")
          | {source: _usage_active_source, from: (.cover[0] | usage_epoch), to: (.cover[1] | usage_epoch)}
          | select(.from != null and .to != null)] as $covers
      | ([($session_rows[] | select(.kind == "segment" or .kind == "cursor" or .kind == "activity")), $session_segments[]
          | select((.act | type) == "object") | {source: _usage_active_source, act}] | unique) as $fact_rows
      | any($fact_rows[]; .act.e == "sdk-cli") as $headless
      | [$fact_rows[] | select(.source == "main") | .act | _usage_active_decode] as $main_facts
      | reduce ($session_segments | group_by(_usage_active_source))[] as $source_segments (.;
          ($source_segments[0] | _usage_active_source) as $source
          | [$source_segments | sort_by(._active_start, ._active_end)[]
              | . as $segment
              | . + {_active_covered: (has("act")
                  or any($covers[]; .source == $source and .from <= $segment._active_start and $segment._active_end <= .to))}] as $ordered
          | (if $source != "main" or $headless
             then [$ordered[] | select(._active_covered)]
               | if length == 0 then [] else [[(map(._active_start) | min), (map(._active_end) | max)]] end
             else _usage_active_turns($main_facts) end) as $windows
          | _usage_active_attribute($ordered; $windows; $splits) as $territory_pieces
          | reduce range(0; $ordered | length) as $index (.;
              $ordered[$index] as $segment
              | .[$segment._active_identity] = {covered: $segment._active_covered,
                  pieces: $territory_pieces[$index]}))))};

def usage_active_pieces($index; $group):
  [$group[] | $index.segments[_usage_active_identity] | objects | select(.covered) | .pieces[]];

def usage_active_union($pieces; $from; $to):
  [$pieces[] | [([.[0], $from] | max), ([.[1], $to] | min)] | select(.[1] > .[0])] | sort
  | reduce .[] as $piece ({total: 0, start: null, end: null};
      if .end == null then .start = $piece[0] | .end = $piece[1]
      elif $piece[0] <= .end then .end = ([.end, $piece[1]] | max)
      else .total += (.end - .start) | .start = $piece[0] | .end = $piece[1] end)
  | .total + (if .end == null then 0 else .end - .start end);

def _usage_active_covered($index): $index.segments[_usage_active_identity].covered // has("act");

# The total is rounded to the millisecond before the one floor: the stamps are
# millisecond values held as doubles, so an exact 300 s can sum to 299.9999999.
def usage_active_figure($index; $group; $from; $to):
  [$group[] | _usage_active_covered($index)] as $coverage
  | {active_seconds: (if any($coverage[]; .)
       then usage_active_union(usage_active_pieces($index; $group); $from; $to) | (. * 1000 | round) / 1000 | floor
       else null end),
     active_lower_bound: (any($coverage[]; .) and any($coverage[]; . | not))};
'
