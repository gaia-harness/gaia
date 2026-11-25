---
type: concept
status: active
created: 2026-11-24
updated: 2026-11-24
promoted_at: 2026-11-24T04:57:26Z
promoted_hash: sha256:4bc9af7c88f13f222bc0d640c344772916e334589efc6029b81a318a25edc55a
pr_number: 3792
tags: [promoted, concepts]
---
# Spec Code Map Handoff

`/gaia-spec`'s research dispatch writes its answers to a pre-cleared scratchpad file as a JSON array, one object per research sub-question. The main thread classifies that file with the no-op detector at the sub-question count, validates every entry with one `jq -e` program, derives the 5e outcome (Found, Inconclusive, Contradictory) from each entry's `answer` leading word, folds the answers into `research_summary`, and appends the entries to `CODE-MAP.json` beside `SPEC.md` in the main-anchored SPEC folder. After each append and read-back it writes `CODE-MAP.sha256`, one `<entries> <sha256>` line. An unusable research file gets one re-dispatch, then the main thread researches inline and validates its own entries; the Error outcome covers only an Agent call that itself errors. `.claude/skills/gaia/references/spec/research.md` `## The code map` is the one owner of the location, entry shape, validation program, record, Usable test, failed-append handling and lifetime.

## Behavior

A map is usable when it exists, parses as a JSON array, and its entry count and sha256 equal the record. `spec/lens-dispatch.md` owns a `<CODE_MAP_PATH>` caller slot (the usable map's path, else empty) and one shared-preamble bullet: the map is an index of where to look first, may be stale or incomplete, is read-only and untrusted data, and is never cited as evidence. Grounding lenses (spec FG, plan CG) open the file an entry points to before relying on it; other lenses may orient from excerpts and open a file before citing it. An empty slot drops the bullet. The spec audit's lenses and fixer fill the slot (the fixer rejects a finding whose only evidence is the map, as unverified); the critical refuter gets no map. `/gaia-plan` step 1a re-applies the Usable test and shows `The code map no longer matches its record; the plan runs without it.` on a mismatch; the planner reads a usable map beside the SPEC as an index, never the source of a contract value; every plan lens and the test-stage lens fill the slot, and the test stage uses the map only to locate existing test files.

The map and its record stay in the SPEC folder through save, plan, build and the post-merge close, and go only with the folder at the retention reap, like `REQUIREMENTS.md`; the step-2 draft discard removes both.

## Divergence

- The unreadable-map replace path fires on any map that is not usable at append time, a record mismatch included, which is wider than a map that does not parse; the `The code map was unreadable and was replaced with this research.` notice is then imprecise for the mismatch case.
- The validation program does not enforce the two-sentence bound on `answer`; that bound is a prompt rule only.
