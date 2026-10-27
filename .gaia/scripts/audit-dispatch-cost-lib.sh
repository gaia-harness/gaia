# shellcheck shell=bash
# Measurement library for the per-dispatch cost record of the Code Audit Team.
# Sourced, never executed: it defines functions only (plus the pricing library
# it builds on) and has no other effect at source time.
#
#   gaia_dispatch_cost_measure <subagents-directory> <agent-id> <rates-json>
#
# <subagents-directory> holds agent-<id>.jsonl and agent-<id>.meta.json for
# every agent of one session (flat; nothing below it is read). <rates-json> is
# the GAIA_RATES_JSON string gaia_rates_load produced. Prints one compact JSON
# object and returns 0; returns 1, printing nothing, only when jq cannot run.
#
# The toolkit .gaia/tests/audit-cost/measure-dispatch.mjs is the post hoc
# oracle: on the figures both define the same way (calls, cache tokens, wall
# seconds, dollars) the two must agree. This file is the only place the
# measurement rules live; it adds no pricing code of its own.
#
# Cost of the walk: two jq processes however many descendants there are. One
# reads every meta, one reads the dispatch's transcript and all its
# descendants' transcripts together.

# shellcheck source=/dev/null
. "${BASH_SOURCE[0]%/*}/token-pricing-lib.sh"

# Pass one. Reads every meta file in the directory; prints a summary line, then
# one line per descendant id of $root. A torn meta never fails the pass: it
# only clears metas_ok, and the descendants are then not walked.
_gaia_dispatch_cost_metas_program() {
  cat <<'JQ'
reduce inputs as $line ({}; .[input_filename] += [$line])
| to_entries
| map({
    id: (.key | sub("^.*/agent-"; "") | sub("\\.meta\\.json$"; "")),
    meta: (try (.value | join("\n") | fromjson) catch null)
  }) as $entries
| ((($entries | length) == $expected) and ($entries | all(.meta | type == "object"))) as $metas_ok
| ($entries
   | map(select(.meta | type == "object")
         | {key: .id, value: {type: (.meta.agentType // null), parent: (.meta.parentAgentId // null)}})
   | from_entries) as $agents
| (if $metas_ok then
     (reduce range(0; ($agents | length) + 1) as $step ([$root];
        . as $seen
        | ($seen + [$agents | to_entries[]
                    | select(.value.parent as $parent | $parent != null and ($seen | index($parent) != null))
                    | .key])
        | unique)) - [$root]
   else [] end) as $descendants
| ({
    metas_ok: $metas_ok,
    agent_type: ($agents[$root].type // null),
    direct_children: ([$agents[] | select(.parent == $root)] | length),
    roles: ($descendants
            | map({key: ., value: ($agents[.].type
                | if . == "audit-rule-specialist" then "specialist"
                  elif . == "audit-refuter" then "refuter"
                  else "other" end)})
            | from_entries)
  } | tojson),
  $descendants[]
JQ
}

# Pass two: the measurement rules. The pricing definitions are prepended.
_gaia_dispatch_cost_measure_program() {
  cat <<'JQ'
def round3: (. * 1000 | round) / 1000;
def round6: (. * 1e6 | round) / 1e6;

def epoch:
  if type != "string" then null
  elif test("\\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?Z\\z")
  then ((.[0:19] + "Z") | fromdateiso8601) + (if length > 20 then ("0" + .[19:-1] | tonumber) else 0 end)
  else null end;

# One usage block as the five priced buckets. A block with the 5m/1h split
# uses it; a block with only the written total counts all of it as 5m.
def buckets($usage):
  ($usage.cache_creation | if type == "object" then . else null end) as $split
  | ($split.ephemeral_1h_input_tokens // 0) as $one_hour
  | ($usage.cache_creation_input_tokens // (($split.ephemeral_5m_input_tokens // 0) + $one_hour)) as $written
  | {
      fresh_input: ($usage.input_tokens // 0),
      cache_write_5m: ([0, ($written - $one_hour)] | max),
      cache_write_1h: $one_hour,
      cache_read: ($usage.cache_read_input_tokens // 0),
      output: ($usage.output_tokens // 0)
    };

def sum_of(f): map(f) | add // 0;

# The figures of one transcript, given its lines.
def measure($lines):
  ($lines | map(fromjson? | objects)) as $records
  | (reduce ($records[]
              | select(.type == "assistant" and (.message | type == "object")
                       and (.message.id | type == "string") and .message.id != "")) as $record
      ({order: [], by_id: {}};
        $record.message.id as $message_id
        | if .by_id[$message_id] == null then
            .order += [$message_id]
            | .by_id[$message_id] = {ts: ($record.timestamp // null), model: ($record.message.model // null), usage: ($record.message.usage | if type == "object" then . else {} end)}
          else
            .by_id[$message_id] |= (.usage = ($record.message.usage | if type == "object" then . else {} end) | .model = ($record.message.model // .model))
          end)) as $deduped
  | [$deduped.order[] as $message_id
     | $deduped.by_id[$message_id]
     | . + {buckets: buckets(.usage)}
     | select(.buckets | any(.[]; . != 0))] as $calls
  | [$calls[]
     | (.model // "unknown") as $model
     | if ($model | startswith("claude-")) then
         priced_row({ts: .ts, by_model: {($model): .buckets}})
         | {dollars: .dollars, missing: .missing_anchor, unpriced: .unpriced}
       else
         {dollars: 0, missing: false, unpriced: [$model]}
       end] as $priced
  | [$records[] | (.timestamp | epoch) | numbers] as $stamps
  | {
      calls: ($calls | length),
      models: ($calls | map(.model // "unknown") | unique),
      input_tokens: ($calls | sum_of(.buckets.fresh_input)),
      cache_write_5m_tokens: ($calls | sum_of(.buckets.cache_write_5m)),
      cache_write_1h_tokens: ($calls | sum_of(.buckets.cache_write_1h)),
      cache_read_tokens: ($calls | sum_of(.buckets.cache_read)),
      output_tokens: ($calls | sum_of(.buckets.output)),
      wall_s: (if ($stamps | length) == 0 then 0 else ($stamps[-1] - $stamps[0]) | round3 end),
      raw_dollars: ($priced | sum_of(.dollars)),
      unpriced: ($priced | map(.unpriced[]) | unique),
      missing_anchor: ($priced | any(.missing)),
      dispatch_count: ([$records[]
                        | select(.type == "assistant")
                        | (.message.content? // []) | arrays | .[] | objects
                        | select(.type == "tool_use" and (.name == "Agent" or .name == "Task"))
                        | .id | strings] | unique | length),
      version: ([$records[] | .version | strings] | .[0])
    };

def priced_or_null: if (.unpriced | length) > 0 or .missing_anchor then null else .raw_dollars end;

def role_figures:
  . as $children
  | ($children | map(.unpriced[]) | unique) as $unpriced
  | ($children | any(.missing_anchor)) as $missing
  | {
      models: ($children | map(.models[]) | unique),
      calls: ($children | sum_of(.calls)),
      input_tokens: ($children | sum_of(.input_tokens)),
      cache_write_5m_tokens: ($children | sum_of(.cache_write_5m_tokens)),
      cache_write_1h_tokens: ($children | sum_of(.cache_write_1h_tokens)),
      cache_read_tokens: ($children | sum_of(.cache_read_tokens)),
      output_tokens: ($children | sum_of(.output_tokens)),
      longest_wall_s: ($children | map(.wall_s) | max),
      raw_dollars: (if ($unpriced | length) > 0 or $missing then null else ($children | sum_of(.raw_dollars)) end),
      unpriced: $unpriced,
      missing_anchor: $missing,
      dispatches: ($children | length)
    };

reduce inputs as $line ({}; .[input_filename] += [$line])
| with_entries(.key |= (sub("^.*/agent-"; "") | sub("\\.jsonl$"; "")))
| map_values(measure(.)) as $measured
| ($measured[$root] // null) as $own
| $summary.roles as $roles
| if $own == null or $own.calls == 0 then
    {state: "transcript_unparsed", agent_type: $summary.agent_type, claude_code_version: ($own.version // null),
     own: null, children_state: null, children: null, children_dollars: null}
  else
    (if ($summary.metas_ok | not) then "unparsed"
     elif $own.dispatch_count != $summary.direct_children then "unparsed"
     elif ($roles | keys | any(. as $id | ($measured[$id] // null) == null or $measured[$id].calls == 0)) then "unparsed"
     else "ok" end) as $children_state
    | (if $children_state == "ok" then
         ($roles | to_entries | map({role: .value, child: $measured[.key]}) | group_by(.role)
          | map({key: .[0].role, value: (map(.child) | role_figures)}) | from_entries)
       else null end) as $role_map
    | {
        state: "ok",
        agent_type: $summary.agent_type,
        claude_code_version: $own.version,
        own: ($own | {models, calls, input_tokens, cache_write_5m_tokens, cache_write_1h_tokens, cache_read_tokens,
                      output_tokens, wall_s,
                      dollars: (priced_or_null | if . == null then null else round6 end),
                      unpriced, missing_anchor}),
        children_state: $children_state,
        children: (if $role_map == null then null
                   else $role_map | map_values(del(.raw_dollars) + {dollars: (.raw_dollars | if . == null then null else round6 end)}) end),
        children_dollars: (if $role_map == null then null
                           else [$role_map[] | .raw_dollars] | if any(. == null) then null else (add // 0) | round6 end end)
      }
  end
JQ
}

gaia_dispatch_cost_measure() {
  local directory="${1:-}" agent_id="${2:-}" rates_json="${3:-null}"
  local meta_files=() transcript_files=() meta_path transcript_path meta_output summary descendant_ids descendant_id

  command -v jq >/dev/null 2>&1 || return 1
  [ -n "$rates_json" ] || rates_json=null

  for meta_path in "$directory"/agent-*.meta.json; do
    if [ -e "$meta_path" ]; then
      meta_files[${#meta_files[@]}]="$meta_path"
    fi
  done
  meta_output="$(jq -nRr --arg root "$agent_id" --argjson expected "${#meta_files[@]}" \
    "$(_gaia_dispatch_cost_metas_program)" ${meta_files[@]+"${meta_files[@]}"} </dev/null)" || return 1
  summary="${meta_output%%$'\n'*}"
  descendant_ids=""
  case "$meta_output" in
    *$'\n'*) descendant_ids="${meta_output#*$'\n'}" ;;
  esac

  if [[ "$agent_id" =~ ^[A-Za-z0-9_-]+$ ]]; then
    transcript_path="$directory/agent-$agent_id.jsonl"
    if [ -f "$transcript_path" ]; then
      transcript_files[${#transcript_files[@]}]="$transcript_path"
    fi
  fi
  if [ -n "$descendant_ids" ]; then
    while IFS= read -r descendant_id; do
      transcript_path="$directory/agent-$descendant_id.jsonl"
      if [ -f "$transcript_path" ]; then
        transcript_files[${#transcript_files[@]}]="$transcript_path"
      fi
    done <<<"$descendant_ids"
  fi

  jq -nRc --arg root "$agent_id" --argjson summary "$summary" --argjson rates "$rates_json" \
    "$GAIA_PRICING_JQ_DEFS
$(_gaia_dispatch_cost_measure_program)" ${transcript_files[@]+"${transcript_files[@]}"} </dev/null
}
