# shellcheck shell=bash
# jq programs for the usage-ledger flusher (usage-flush.sh). Sourced after
# usage-lib.sh, whose GAIA_USAGE_JQ_DEFS prefixes the parse and segment programs.
# Defines variables only; sourcing runs no command.
#
# GAIA_USAGE_PARSE_JQ reads one file's complete lines (`jq -nR`) and prints the
# extraction as one compact JSON line, then each distinct raw gitBranch on its
# own line (the caller builds the branch map from those in bash, so
# gaia_branch_normalize stays the only normalizer). The extraction also lists,
# per line, the raw activity facts the line holds (turn openers, work entries,
# tool uses and results, turn lengths, entrypoint) with millisecond stamps.
# Line numbers count from 1 at the start of the parsed range. Arguments: $roots (tree roots), $research_roots
# (research roots), $startset (workflow names), $line_count (complete lines in the
# range; a trailing line past it has no newline yet and is not read).
#
# GAIA_USAGE_SEGMENT_JQ applies the high-water filter, the trailing-group
# holdback, dedup, keying, and the split-point grouping. Split points are the
# session's declare and close bindings in usage.jsonl, and the file's own
# start and research events. Every segment row carries $agent_type, and $agent_id
# when it is non-empty (a sidecar's), and ends with `act`: a main file's first
# segment of a range holds the activity facts object (b, e, o, c, w, q, r, d;
# b in epoch ms, every other time an integer whole-second offset from b, openers
# delta-encoded, spans as start and length) and every other segment holds 0. A main
# range with facts but no segment row carries the facts on its cursor row. It
# prints the held line number (or null), then the cursor row's JSON before and
# after its offset (the caller fills the byte offset of the held line in bash),
# then one row per line.

# shellcheck disable=SC2034,SC2016  # consumed by usage-flush.sh; jq source, no shell expansion
GAIA_USAGE_PARSE_JQ="${GAIA_USAGE_JQ_DEFS:-}"'
def text_of:
  if type == "string" then .
  elif type == "array" then map(if type == "object" then (.text // "" | strings) elif type == "string" then . else "" end) | join("\n")
  else "" end;
def buckets:
  {fresh_input: (.input_tokens // 0),
   cache_write_5m: (.cache_creation.ephemeral_5m_input_tokens? // 0),
   cache_write_1h: (.cache_creation.ephemeral_1h_input_tokens? // (.cache_creation_input_tokens // 0)),
   cache_read: (.cache_read_input_tokens // 0),
   output: (.output_tokens // 0)}
  | map_values(if type == "number" then . else 0 end);
def in_set($workflow_name): any($startset[]; . == $workflow_name);
# Seconds since the epoch for a UTC ISO stamp (Z or +00:00, optional fraction);
# null for anything else. Same accepted forms as usage_epoch.
def _usage_parse_epoch_seconds:
  if type != "string" then null
  elif test("\\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?Z\\z")
  then ((.[0:19] + "Z") | fromdateiso8601) + (if length > 20 then ("0" + .[19:-1] | tonumber) else 0 end)
  else [capture("^(?<date_time>[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(?<fraction>\\.[0-9]+)?(Z|[+]00:?00)$")?
      | ((.date_time + "Z") | fromdateiso8601) + (if .fraction == null then 0 else ("0" + .fraction | tonumber) end)] | first
  end;
def _usage_parse_epoch_ms: _usage_parse_epoch_seconds | if . == null then null else (. * 1000 + 0.5) | floor end;
# One line of activity facts as a compact item, or empty when it holds none.
# n line number; t ms; p opener (u user prompt, d dequeue); k work entry;
# u every tool_use id; q wait tool_use ids; r tool_result ids; d turn length ms;
# e entrypoint.
def _usage_parse_fact($record; $line_number):
  ($record.timestamp | _usage_parse_epoch_ms) as $stamp
  | ($record.entrypoint | if type == "string" and . != "" then . else null end) as $entrypoint
  | ($record.message | if type == "object" then .content else null end) as $content
  | (if $record.type == "assistant" and ($content | type) == "array" then [$content[] | objects | select(.type == "tool_use")] else [] end) as $tool_uses
  | (if $record.type == "user" and ($content | type) == "array" then [$content[] | objects | select(.type == "tool_result")] else [] end) as $tool_results
  | {n: $line_number, e: $entrypoint}
    + (if $stamp == null then {} else
        {t: $stamp,
         p: (if $record.type == "queue-operation" and $record.operation == "dequeue" then "d"
             elif $record.type == "user" and ($tool_results | length) == 0 and $record.isMeta != true
                  and (($content | type) == "string" or ($content | type) == "array")
                  and (($content | text_of) | startswith("[Request interrupted by user") | not) then "u"
             else null end),
         k: (if $record.type == "assistant" or ($tool_results | length) > 0 then true else null end),
         u: [$tool_uses[] | .id | strings],
         q: [$tool_uses[] | select(.name == "AskUserQuestion" or .name == "ExitPlanMode") | .id | strings],
         r: [$tool_results[] | .tool_use_id | strings],
         d: (if $record.type == "system" and $record.subtype == "turn_duration" and ($record.durationMs | type) == "number" then $record.durationMs else null end)}
      end)
  | with_entries(select(.value != null and .value != []))
  | if length > 1 then . else empty end;
reduce inputs as $line ({line_number: 0, usage: [], events: [], facts: []};
  .line_number += 1
  | if .line_number > $line_count then .
    else
      ($line | try fromjson catch null) as $record
      | (if ($record | type) == "object" and (($record.cwd | type) != "string" or usage_member($record.cwd; $roots))
         then .facts += [_usage_parse_fact($record; .line_number)]
         else . end)
      | if ($record | type) != "object" or (usage_member($record.cwd; $roots) | not) then .
        else
          .line_number as $line_number
          | ($record.message.id? // $record.uuid // null | if type == "string" then . else null end) as $id
          | ($record.timestamp | if type == "string" then . else null end) as $timestamp
          | (if ($record.message.usage? | type) == "object"
             then .usage += [{line_number: $line_number, id: $id, ts: $timestamp,
                   model: ($record.message.model | if type == "string" and . != "" then . else null end),
                   token_buckets: ($record.message.usage | buckets),
                   branch: ($record.gitBranch | if type == "string" then . else null end),
                   session_id: ($record.sessionId | if type == "string" and . != "" then . else null end)}]
             else . end)
          | if $record.type == "assistant" then
              .events += [$record.message.content[]? | objects | select(.type == "tool_use")
                | if .name == "Write" then
                    usage_research_slug(.input.file_path?; $research_roots) as $slug
                    | select($slug != null)
                    | {line_number: $line_number, id: $id, ts: $timestamp, type: "research", ref: ("research:" + $slug)}
                  elif .name == "Skill" then
                    (.input.skill? | strings | sub("\\A[^:]*:"; "")) as $workflow_name
                    | select(in_set($workflow_name))
                    | {line_number: $line_number, id: $id, ts: $timestamp, type: "start", workflow: $workflow_name}
                  else empty end]
            elif $record.type == "user" then
              .events += [$record.message.content? | text_of
                | match("<command-name>/?([^<]*)</command-name>"; "g") | .captures[0].string
                | sub("\\A[^:]*:"; "") | select(in_set(.))
                | {line_number: $line_number, id: $id, ts: $timestamp, type: "start", workflow: .}]
            else . end
        end
    end)
| (del(.line_number) | tojson),
  ([.usage[].branch | strings | select(test("\n") | not)] | unique | .[])
'

# The holdback line is the one guards-must-fail mutation targets; keep it a
# single line so a scratch copy can disable it with one sed.
# shellcheck disable=SC2034,SC2016
GAIA_USAGE_SEGMENT_JQ="${GAIA_USAGE_JQ_DEFS:-}"'
def zero_buckets: {fresh_input: 0, cache_write_5m: 0, cache_write_1h: 0, cache_read: 0, output: 0};
def add_buckets($added):
  {fresh_input: (.fresh_input + $added.fresh_input), cache_write_5m: (.cache_write_5m + $added.cache_write_5m),
   cache_write_1h: (.cache_write_1h + $added.cache_write_1h), cache_read: (.cache_read + $added.cache_read),
   output: (.output + $added.output)};
def fresh($seen; $high_water_timestamp):
  (.id == null or ($seen[.id] | not)) and ($high_water_timestamp == null or .ts == null or .ts >= $high_water_timestamp);
# The facts object for a range of committed fact items (file order), or null
# when it holds no opener, work, wait, result or turn length. Times are integer
# whole-second offsets from b, the earliest stamp in epoch ms (openers delta
# encoded, spans as start and length). A user prompt that follows a dequeue
# with no work between is the notification prompt entry of that dequeue: it is dropped.
def _usage_activity($items):
  (reduce $items[] as $item ({openers: [], chunks: [], chunk: null, previous: null, worked: false};
      if $item.p == "u" and .previous == "d" and (.worked | not) then .previous = "u"
      elif $item.p != null
      then (if .chunk == null then . else .chunks += [.chunk] end) | .chunk = null | .openers += [$item.t] | .previous = $item.p | .worked = false
      elif $item.k == true
      then .worked = true | .chunk = (if .chunk == null then [$item.t, $item.t] else [([.chunk[0], $item.t] | min), ([.chunk[1], $item.t] | max)] end)
      else . end)) as $walk
  | $walk.openers as $openers
  | ($walk.chunks + (if $walk.chunk == null then [] else [$walk.chunk] end)) as $chunks
  | ([$items[] | .u // [] | .[] | {key: ., value: true}] | from_entries) as $used
  | (reduce ($items[] | select(.q) | .t as $at | .q[] | {id: ., at: $at}) as $start ({}; if .[$start.id] == null then .[$start.id] = $start.at else . end)) as $starts
  | (reduce ($items[] | select(.r) | .t as $at | .r[] | {id: ., at: $at}) as $result ({}; if .[$result.id] == null then .[$result.id] = $result.at else . end)) as $results
  | [$starts | to_entries[] | select($results[.key] != null) | [.value, $results[.key]]] as $waits
  | [$starts | to_entries[] | select($results[.key] == null) | [.key, .value]] as $open_waits
  | [$results | to_entries[] | select($used[.key] == null) | [.key, .value]] as $orphan_results
  | [$items[] | select(.d) | [.t, .d]] as $lengths
  | ([$items[] | .e // empty] | first) as $entrypoint
  | ([$openers[], $chunks[][], $waits[][], $open_waits[][1], $orphan_results[][1], $lengths[][0]] | min) as $base
  | if $base == null then null
    else (def whole_seconds($at): (($at - $base) / 1000 | round);
      ($openers | map(whole_seconds(.))) as $opener_seconds
      | {b: $base}
      + (if $entrypoint == null then {} else {e: $entrypoint} end)
      + ({o: [range(0; $opener_seconds | length) as $i | $opener_seconds[$i] - (if $i == 0 then 0 else $opener_seconds[$i - 1] end)],
          c: [$chunks[] | [whole_seconds(.[0]), (whole_seconds(.[1]) - whole_seconds(.[0]))]],
          w: [$waits[] | [whole_seconds(.[0]), (whole_seconds(.[1]) - whole_seconds(.[0]))]],
          q: [$open_waits[] | [.[0], whole_seconds(.[1])]],
          r: [$orphan_results[] | [.[0], whole_seconds(.[1])]],
          d: [$lengths[] | [whole_seconds(.[0]), (.[1] / 1000 | round)]]}
         | with_entries(select(.value != []))))
    end;
$extraction[0] as $extracted
| ($high_water_mark.hw_ts | if type == "string" then . else null end) as $high_water_timestamp
| ($high_water_mark.hw_ids // [] | map(strings)) as $previous_ids
| ($previous_ids | map({key: ., value: true}) | from_entries) as $seen
| [$extracted.usage[] | select(fresh($seen; $high_water_timestamp))] as $usage_entries
| [$extracted.events[] | select(.ts != null) | select(fresh($seen; $high_water_timestamp))] as $event_entries
| (if ($usage_entries | length) == 0 then null else ($usage_entries[-1].id) as $last_id | [$usage_entries[] | select(.id == $last_id)][0].line_number end) as $trailing_line
| (if $finished then null else $trailing_line end) as $hold
| (if $hold == null then $usage_entries else [$usage_entries[] | select(.line_number < $hold)] end) as $committed_usage
| (if $hold == null then $event_entries else [$event_entries[] | select(.line_number < $hold)] end) as $committed_events
| (if $role == "main" then [($extracted.facts // [])[] | select($hold == null or .n < $hold)] else [] end) as $committed_facts
| _usage_activity($committed_facts) as $activity
| (($committed_usage | map(select(.id != null)) | group_by(.id) | map(max_by(.line_number))) + ($committed_usage | map(select(.id == null)))
   | sort_by(.line_number) | map(. + usage_key(.branch; (.session_id // $file_session_id); $default; $branch_map))) as $deduped_usage
| ([$splitsraw | split("\n")[] | select(length > 0) | (try fromjson catch null) | objects
    | select(.session_id == $file_session_id)
    | select(.kind == "binding" and (.type == "declare" or .type == "close"))
    | .ts | strings] + [$committed_events[].ts]) | unique as $split_timestamps
| (reduce $deduped_usage[] as $entry ([];
    if length == 0 then [[$entry]]
    else .[length - 1][-1] as $previous_entry
      | if $previous_entry.key != $entry.key or $previous_entry.inherit != $entry.inherit
          or ($previous_entry.ts != null and $entry.ts != null and any($split_timestamps[]; $previous_entry.ts < . and . <= $entry.ts))
        then . + [[$entry]]
        else .[length - 1] += [$entry] end
    end)) as $groups
| [$groups | to_entries[] | .key as $group_index | .value | {schema_version: 1, kind: "segment", key: .[0].key, session_id: $file_session_id, inherit: .[0].inherit,
    first_ts: ([.[].ts | strings] | min), last_ts: ([.[].ts | strings] | max),
    messages: ([.[].id] | unique | length),
    by_model: (reduce .[] as $entry ({}; ($entry.model // "unknown") as $model | .[$model] = ((.[$model] // zero_buckets) | add_buckets($entry.token_buckets)))
      | with_entries(select(([.value[]] | add) > 0))),
    agent_type: $agent_type} + (if $agent_id == "" then {} else {agent_id: $agent_id} end)
    + {act: (if $group_index == 0 and $activity != null then $activity else 0 end)}] as $segments
| [$committed_events | sort_by(.line_number)[]
    | if .type == "research"
      then {schema_version: 1, kind: "binding", type: "research", session_id: $file_session_id, ts, ref, source: "transcript"}
      else {schema_version: 1, kind: "binding", type: "start", session_id: $file_session_id, ts, workflow, source: "transcript"} end] as $bindings
| ([$deduped_usage[], $committed_events[] | {line_number, id, ts}] | sort_by(.line_number)) as $committed
| ([$committed[].ts | strings] | max) as $latest_timestamp
| (if $high_water_timestamp == null then $latest_timestamp elif $latest_timestamp == null or $latest_timestamp <= $high_water_timestamp then $high_water_timestamp else $latest_timestamp end) as $new_high_water_timestamp
| ([$committed[] | select($new_high_water_timestamp != null and .ts == $new_high_water_timestamp) | .id | strings]
   + (if $new_high_water_timestamp == $high_water_timestamp then $previous_ids else [] end)
   + (($previous_ids + [$committed[].id | strings]) | .[-8:]) | unique) as $new_high_water_ids
| ($hold | tojson),
  ({schema_version: 1, kind: "cursor"} + (if $activity != null and ($segments | length) == 0 then {act: $activity} else {} end)
    + {session_id: $file_session_id, role: $role, path: $path} | tojson | .[:-1]),
  ({size: $size, hw_ts: $new_high_water_timestamp, hw_ids: $new_high_water_ids, ts: $now} | tojson | .[1:]),
  ($segments[], $bindings[] | tojson)
'

# Folds cursor rows (stdin, one per line) into the cache object $cache_state. Latest row
# wins; an unknown schema_version is skipped.
# shellcheck disable=SC2034,SC2016
GAIA_USAGE_FOLD_JQ='
def fold($cache_state):
  reduce (inputs | try fromjson catch null | objects
      | select(.schema_version == 1 and .kind == "cursor" and (.path | type) == "string"
          and (.session_id | type) == "string" and (.role | type) == "string")) as $cursor_row ($cache_state;
    .files[$cursor_row.path] = {session_id: $cursor_row.session_id, role: $cursor_row.role, offset: $cursor_row.offset, size: $cursor_row.size}
    | .pairs[$cursor_row.session_id + "|" + $cursor_row.role] = {hw_ts: $cursor_row.hw_ts, hw_ids: ($cursor_row.hw_ids // [])});
def base: ($cache_text | try fromjson catch null)
  | if type == "object" and (.files | type) == "object" and (.pairs | type) == "object" then . else null end;
'
