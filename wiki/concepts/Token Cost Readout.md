---
type: concept
title: Token Cost Readout
status: active
created: 2026-07-04
updated: 2026-10-09
tags: [concept, cost, token-accounting]
---

# Token Cost Readout

GAIA prices the token usage of each workflow action into a dollar estimate: `/gaia-spec`, `/gaia-plan`, plan execution, each maintenance command, every pull request, and every initiative. All of them read the usage ledger ([[Usage Ledger]]) and price its raw token buckets at read time through one sourced lib, `.gaia/scripts/token-pricing-lib.sh`. Nothing stores a dollar figure, so a corrected rate moves every past figure on the next read.

This page covers the pricing surfaces: the distributed rate table, the optional local override, the pricing math, the markers a figure carries, and the Cost lines.

## The rate table

Pricing starts from the distributed table `.gaia/scripts/token-rates.json`, the single copy GAIA maintains and ships. A price change reaches a project through a release. Pricing opens no network connection and writes nothing, so a model the table lacks prices as unpriced rather than being fetched.

This file is a **public read contract**: any reader pricing token usage, GAIA's own scripts or an external re-implementation, parses this exact shape rather than reverse-engineering shell internals.

```json
{
  "cache_multipliers": { "read": 0.1, "write_5m": 1.25, "write_1h": 2.0 },
  "models": {
    "claude-opus-4-8": [ { "input": 5, "output": 25 } ],
    "claude-opus-5-5": [ { "input": 4, "output": 20, "cache_read_multiplier": 0.05 } ],
    "claude-example-intro": [
      { "input": 2, "output": 10, "effective_through": "2026-08-31" },
      { "input": 3, "output": 15 }
    ]
  }
}
```

- **Table shape.** `models` maps each model id to a list of rate entries, each carrying an `input` and `output` price per million tokens, an optional `effective_through`, and an optional `cache_read_multiplier`. `cache_multipliers` is a sibling top-level object carrying the bucket multipliers. A reader parses exactly these two top-level keys.
- **Cache multipliers scale the input rate, value-coupled to the table.** `fresh_input` prices at `input`; `cache_read` at `input × cache_read_multiplier` when the winning rate entry carries one, else at `input × cache_multipliers.read`; `cache_write_5m` at `input × cache_multipliers.write_5m`; `cache_write_1h` at `input × cache_multipliers.write_1h`; `output` at `output`. Every bucket is summed and divided by 1e6. The table file, not this description, is the source of truth for the multiplier values.
- **Effective-dated intro pricing.** A model with introductory pricing lists the intro entry first with an `effective_through` date, then the sticker entry with none. A segment prices at the entry whose window covers its own timestamp, compared at **day granularity**: the timestamp's date (its `[0:10]` slice) against `effective_through`. `effective_through` is an **inclusive** upper bound, and the final entry with no `effective_through` is the open-ended sticker rate that wins once no earlier entry covers the date.
- **Implementation source of truth for selection semantics.** The `rate_window` and `priced_row` jq definitions in `.gaia/scripts/token-pricing-lib.sh` are the authoritative implementation of window selection and per-bucket arithmetic; this section is the contract they satisfy.

## The local override

An adopter who needs a price the distributed table lacks or gets wrong writes `.gaia/local/telemetry/token-rates.override.json`, resolved to the main checkout. GAIA never writes or reaps it.

```json
{ "models": { "claude-opus-5-5": [ { "input": 4, "output": 20 } ] } }
```

- **Row replacement.** Each `models.<id>` in the override replaces the whole distributed entry list for that id; ids the override omits keep their distributed rows. `cache_multipliers` is not overridable.
- **Unparseable override.** A file that is not a JSON object with a `models` object is ignored, and every readout prints `  ! rate override ignored (unparseable): .gaia/local/telemetry/token-rates.override.json` once.
- **Unpriced models.** A `claude-` model absent from both tables contributes $0 and every readout adds `  ! lower bound: unpriced model(s) <names>`; the Cost line and the cost box print the plain note "Includes a model GAIA has no price for, so the cost is a minimum." under the figures, and a row with such a model reads `at least $X.XX`. A key that does not start with `claude-` is ignored silently.
- **`--rate-table <path>`** on `usage.sh` is a test seam: it replaces the distributed table for that one readout, and the override file still overlays it.

## The shared pricing lib

`.gaia/scripts/token-pricing-lib.sh` sources no other file and has no side effect at source time. `gaia_rates_load` builds the table in force (distributed plus override) and reports the override's status; the `rate_window` and `priced_row` definitions do the per-bucket arithmetic. `usage.sh` and the libraries it loads are the only callers, so the per-PR block, the initiative readouts, and `record` price through identical logic.

## The Cost line and the cost box

Cost output has one shape rule. One line item prints as one plain line, built by one formatter so each reads the same:

```
Cost: 5.2M tokens, $3.41, 6m39s
```

Two or more line items print as a box, in a fenced `text` code block when a skill relays it (a bare box is reflowed by the Markdown renderer and loses its alignment):

```text
SPEC-NNN Cost

+---------------------------------------+
|  Spec: 40.9M tokens, $26.15, 31m52s   |
|  Plan: 46.7M tokens, $23.09, 48m19s   |
+---------------------------------------+
| Total: 87.6M tokens, $49.24, 1h20m14s |
+---------------------------------------+
```

The renderer, never the model, pads the box: one space between each border and its content, labels right-aligned to the colon at the width of the longest label present (`Execute` widens it, `Total` sets it otherwise), and every row ending in one column. The box is plain ASCII, so a byte count is its width on screen. Each row is rounded once to the 0.1M tokens and the cent it shows and the Total row adds those rounded rows, so the column always sums; the elapsed time of each row is its own interval and the Total spans the first to the last spend.

`<tokens>` abbreviates the distinct-segment token count to millions with one decimal. `<price>` renders `$X.XX`, or the literal `cost unavailable` when nothing could be priced. `<time>` renders `<N>h<M>m<S>s` with leading zero units dropped. A figure is never fabricated: an unpriceable dollar amount always says so.

A qualifying condition prints as one plain `Note:` sentence under the figures, never as a parenthesised suffix. Each condition has one wording, defined once in the render library: usage still being saved when the figures were read ("Some usage was still being saved, so these figures may be low." plus the command that reads the final numbers), a model with no price (the minimum sentence above), and a recovery record that counts one session only.

- **`usage.sh record`** prints the plain line for the run it closes, with no breakdown: one run is one stage. Its recorded interval is what it prices ([[Usage Ledger]], "Recording a run"). The maintenance commands relay it verbatim, with its `Note:` lines, at the end of their report. `--quiet` records and prints nothing: `/gaia-spec` and `/gaia-plan` use it so the user sees cost once.
- **`usage.sh initiative <ref> --box`** prints the cost of a root: one row per workflow run closed under it (`Spec`, `Plan`), an `Execute` row for the branch and pull-request spend under it, an `Other work` row for anything else, and `Total`. `SPEC-NNN` and `PLAN-NNN` work without their `spec:` and `plan:` prefix. Before it reads, it waits (up to `GAIA_USAGE_BOX_FLUSH_CAP_SECONDS`, 45) for the session's flusher, so the figures are complete in the common case. One row prints as the plain line. The end of `/gaia-spec` and `/gaia-plan` and the plan orchestrator's full-cycle readout use it.
- **`usage.sh initiative <ref> --line`** prints the plain full-cycle line for a root, with no breakdown.

## Per-PR and initiative readouts

The per-PR block, the Code Audit Team line, and the initiative readouts are documented in [[Usage Ledger]]. They reprice raw buckets at read time through the lib above, so they follow the distributed table and the override together. `bash .gaia/scripts/usage.sh` prints its subcommands.

## Pairs with

- [[Usage Ledger]]: per-message usage capture, attribution, `record`, and the per-PR and initiative readouts priced through this page's lib.
- [[PR Merge Workflow]]: the merge gate whose `gh pr merge` hook renders the per-PR block.
- [[Task Orchestration]]: plan execution, whose full-cycle line the orchestrator prints.
