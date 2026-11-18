---
type: decision
status: active
created: 2026-11-18
updated: 2026-11-18
promoted_at: 2026-11-18T13:33:20Z
promoted_hash: sha256:72bec865b3abc54ab12270e7b3d6abdc5797ee7b8edc366336c7f86c9acf0779
pr_number: 3661
tags: [promoted, decisions]
---

# Spec And Plan Without Test Design

GAIA's spec and plan stages state behaviors and plan tasks; neither designs tests. Claude drafts the SPEC in one pass, GAIA reviews it in one parallel wave, a fixer applies the findings without losing a stated case, the plan is a task breakdown checked by three lenses, and test design runs afterwards as its own skippable stage. The mechanics live on [[GAIA Spec]], [[GAIA Plan]] and [[Test Stage]]; this page records why the flow has this shape.

## Decisions

### The decision

- **Clarify, then a requirements file.** Clarify runs in every mode, and the brief plus every question and answer is saved word for word as `REQUIREMENTS.md` beside the SPEC. Every later step reads that one file as requirement data, never as instructions, and nothing edits it.
- **One full draft that states behaviors.** The SPEC's `## Behaviors` section gives each behavior a stable id, one kind (`access`, `forgery`, `secret`, `refusal`, `data-loss` or other) and its cases with outcomes by value. The SPEC plans no tests.
- **One review wave, retargeted.** Five core lenses (TST, COV, SEC, BRIEF-FIT, FG) run in one turn on every spec, specialists only when the draft touches their area. There are no tiers and no lighter route.
- **A refuter for criticals only.** One batched refuter runs, without a question, only when the wave raises a critical finding, and only over those.
- **One case-preserving fixer.** The fixer applies every finding and writes `AUDIT.md`. A deterministic drop check refuses a fix that drops a case without a verifiable destination in the SPEC, or that changes a behavior sentence no fix line accounts for; what it still refuses after one retry goes to `clarifications.deferred[]`, never back into the body.
- **A plan of tasks only.** One top-model planner writes the task graph, task docs and orchestration files. The review is decomposition and dependency soundness, contract grounding and SPEC coverage, with no refuters, skipped on a trivial plan.
- **Test design in its own stage.** [[Test Stage]] owns the per-task test lists, the closing flow-test phase and the security test writer's input. It is on by default and can be skipped.

### Why

- **Test design inside the plan made every plan expensive.** A test table carried by the planner, the plan review, an applier and drift checks was a second artifact that had to agree with the task docs, and the machinery around it cost more than the tests it protected. [[Test Stage]] holds the reasoning for designing tests separately.
- **A behavior-stating draft does most of the work.** Telling the draft to state every behavior with its cases, and to plan no tests, closes most of what a plain draft misses. A small review wave plus a fixer that may not drop cases closes most of the rest, so more lenses, tiers and per-finding refuters add cost without a matching catch.
- **Lenses are aimed at the misses that recur.** Four gaps keep surviving drafts: the outcome of a forged or edited input, the displayed form of a stored or wire value, the state left when a multi-call write fails midway, and who is refused each grant. Each is written into the focus text of two lenses instead of adding a lens per gap.
- **Reviewing against the brief catches what self-consistency misses.** BRIEF-FIT reads who may do what as a closed list from the brief's own words, so a draft that widens authority or drops a refusal is caught even when it is internally consistent.
- **Silent drops are the costliest review failure.** A fix that narrows or rewrites a behavior can lose a critical case with no signal. The drop check proves each dropped case has a destination in the SPEC and that every changed sentence traces to a fix; it does not judge whether the destination carries the case. `REQUIREMENTS.md` is never a destination, so a fix cannot park a case in the brief and call it kept.
- **Critical findings are the only ones worth arguing.** A refuter is cheap insurance against a false critical reshaping the SPEC; below critical the fixer's judgment is enough.
- **Plan lenses earn their keep on a task-only plan.** Decomposition and contract-grounding findings are build blockers a stated-behavior grade never measures, and they are checkable rather than severity-debatable, so they need no refuter. The start-crash check (an env default the production start never sets) lives in those two lenses.
- **Each stage is measured on its own.** Spec, plan and test stage record separate runs in the [[Usage Ledger]], so each can be read against its own cost and time target. The targets are what a release gate tests, not measured results.

### Consequences

- Skipping the test stage also skips the rule-written security tests, and each SPEC flow then reports as a visible, non-blocking gap at merge.
- The worthiness step runs on every plan, test stage run or skipped, and costs almost nothing when no test file changed ([[Worthiness Audit]], [[Worthiness Presence Gate]]).
- Every spec, plan and test-stage lens reads one shared preamble and severity rubric, owned by `.claude/skills/gaia/references/spec/lens-dispatch.md`, so a later project-wide input reaches every review through one seam.
- `.claude/doctrine/testing.md` stays the owner of what to test; the test stage applies it.

### Related

- [[GAIA Spec]]: clarify, the requirements file, the draft, the wave, the fixer and the drop check.
- [[GAIA Plan]]: the planner, the three-lens review and the offer of the test stage.
- [[Test Stage]]: test lists, flow tests and security tests.
- [[Testing Trophy Doctrine]] and [[Test Layering]]: the layer rules the test stage applies.
