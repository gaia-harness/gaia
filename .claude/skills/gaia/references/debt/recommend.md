# /gaia-debt: recommend and present

The no-argument offer of `/gaia-debt`. `debt.md` routes here on a `top` parse after its backlog read, and `debt/named.md` routes here when the operator picks option 3 of the direct-number cluster offer.

## Recommend and present

Runs on a `top` parse, after the backlog read in `debt.md`, or when the operator picks option 3 of the direct-number cluster offer in `debt/named.md`; a named set never reaches it. The top candidate is the first in the sorted list. Before building the prompt, apply the offer-time security and spec reads (`debt.md`, `### Offer-time reads`), which decide which candidates are public-batch-eligible, then resolve which cluster, if any, anchors the recommendation.

**Offer-mode call.** With two or more remaining candidates, after the offer-time reads, run the scorer's offer mode over the files written in `debt.md`'s backlog read and write its stdout as `offer.json` in the same offer directory, which carries `parts` to the commit step. The scorer's header owns the inputs, the output, and the exits.

```bash
bash .gaia/scripts/debt-batch-budget.sh --offer --backlog "<offer directory>/backlog.json" --report "<offer directory>/report.json" --withheld "<withheld numbers>" --probe-report "<offer directory>/probe.json" > "<offer directory>/offer.json"
```

The withheld list comes from the offer-time security read, in three arms. PUBLIC, INTERNAL, and a failed visibility read count as non-PRIVATE:

- Confirmed PRIVATE: pass an empty list, with no classification.
- Non-PRIVATE with the classification complete on every candidate: pass the security-class issue numbers, comma-separated. The list may be empty, and the budget option still shows.
- Non-PRIVATE with the classification failed or absent: make no offer-mode call and show no budget option.

Two failures cost the option and nothing else:

- A failed probe (no `probe.json`, because the probe exited non-zero): run offer mode without `--probe-report`, because the fix-time staleness screen re-checks the selected part.
- A failed run, meaning a non-zero exit, output that is not JSON, or output lacking a `members` array: report one line saying the budget option could not be computed, and present the offer without it. The run does not stop.

The **recommended batch**, when one exists, is the top cluster all of whose members are public-batch-eligible: normally the cluster containing the top-ranked candidate, but a security-class top candidate is never public-batch-eligible on a non-PRIVATE repo, and a spec-class top candidate is never batch-eligible on any repo, so either anchors no batch and is offered only as its own single candidate. An eligible batch may span severities, a `severity:minor` in the same file as a `severity:major` is a cheap add-on.

How you present the choice depends on backlog size and cluster shape, counted over the **remaining candidates** (the backlog pass's `candidates`), not the raw open-issue count:

- **Zero remaining candidates** (`candidates` is empty and `excluded.investigate` is empty too: every open `tech-debt` issue already carries `in-progress` or one of the two park labels) → do not prompt. State that every open `tech-debt` issue is already in progress or parked on a SPEC, and stop. (Run ends here; see `## Cost record (run end)` in `debt.md`.)
- **Exactly one remaining candidate** → do not prompt. State the issue (number, title, severity band, age derived from `createdAt`) and fix it directly. This is also the peer-session case: two open issues, one already claimed, fixes the single remaining candidate with no prompt.
- **Top candidate heads a public-batch-eligible cluster of 2 or more** → a batch is recommended. Offer it with a single `AskUserQuestion` prompt (header `Debt item`, single-select), phrased around the batch, for example: `"Top item #<A> is related to <N> other issue(s) (<shared signal>). Fix them together, or one at a time?"`. Options, top option carrying `(Recommended)`, the budget batch last:
  1. `Batch #<A> #<B> #<C> (Recommended)`, description: the shared signal (e.g. "all in app/foo/index.ts"), the member count, the severity span, and "one branch, one PR, all close on merge."
  2. `#<A> only`, description: fix just the top issue (its severity band and its age), one at a time.
  3. (optional) the next distinct candidate slot: a batch option when that candidate itself heads a >= 2 cluster, else a single option.
  4. The budget batch, when offer mode returned members; it is the last numbered option, after the optional next candidate slot, and takes the third slot when that slot is empty. Its rules follow the option list.
  - The tool's built-in **Other** entry lets the human type any open `tech-debt` issue number to fix that one alone.
- **Top candidate is a singleton (no cluster), or a security-class top candidate on a non-PRIVATE repo** → present the top three candidates as options (or both when only two exist), top candidate first and its label suffixed `(Recommended)`. Any shown candidate that itself heads a public-batch-eligible cluster of 2 or more is presented as a **batch** option rather than a single, which keeps one-at-a-time the default natural path. Then add the budget batch as the last option, when offer mode returned members, so the list is up to three candidates and the budget batch. Any top candidate that heads no public-batch-eligible cluster takes this singleton-headed shape.

Cap the option set at **4** (plus the built-in Other), the `AskUserQuestion` maximum. Four options fit both shapes, so nothing is dropped to fit the budget batch. When the backlog is deeper than the shown options, first print the full ordered backlog (per issue: number, title, severity band, age), now annotated with cluster membership (e.g. `[batch with #B #C]`), so numbers beyond the shown options are visible before choosing.

Budget batch rules:

The budget batch is the scorer's `members`, shown only when `members` is not empty. Its option label carries those members and the scorer's total against its budget, both read from the scorer's output, and it never carries the recommended mark. Its description says one branch, one pull request, all close on merge, and states no number of its own. The option to fix the top issue alone stays on every offer that carries a budget batch. An empty `members` list shows no budget option and leaves the offer as it was before offer mode, with every candidate still offered.

When the full backlog prints, annotate each budget batch member (for example `[budget batch]`). Skip reasons are never printed, and the annotation never enters a pull request body or a commit.

A picked budget batch continues at `## Claim the fix unit` in `debt.md` as a non-named selection.

Handle the pick, and anything typed into **Other**, as `### Offer-time reads` in `debt.md` states, then continue at `## Claim the fix unit` in `debt.md`.
