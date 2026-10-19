# /gaia-spec: the Socratic clarify loop

Step 5 of `/gaia-spec`: the coverage-based question loop, its escape option, its revisit counter, and the question ceiling that bounds it. `spec.md` routes here on entering step 5, together with `spec/clarify-prompts.md` and `spec/system-prompt.md`. When the loop stops, control returns to `spec.md` step 6.

Contents: The loop; Escape option; Per-topic revisit counter; The question ceiling; 5a. AskUserQuestion mediation; 5b. Discuss-this escape; 5c. Open-ended questions; 5d. Per-topic exhaustion checkpoint; 5e. Research subagent dispatch; When the loop stops.

## The loop

This is GAIA's own loop. The templates `.claude/skills/gaia/references/spec/clarify-prompts.md` and `.claude/skills/gaia/references/spec/system-prompt.md`, read alongside this file, carry the coach-tone persona, the Q&A copy, the topic bank, and the coverage scan.

Run sequential, coverage-based questioning over the draft. One question per turn. The mechanics are 5a through 5e below: `AskUserQuestion` mediation for closed-set questions with the recommended option first, plain prompts for open-ended ones, the Discuss-this escape, the per-topic exhaustion checkpoint, and research-subagent dispatch.

**The stop rule is the coverage scan, not the ceiling.** Maintain the scan defined in `.claude/skills/gaia/references/spec/clarify-prompts.md` (Rule 8) over the topic bank: mark every topic Clear, Partial, or Missing, and prioritize what remains. Ask until no topic is Partial or Missing, then stop. That is the normal termination condition, and on a simple feature it fires after 2 to 4 questions.

**The ceiling bounds the loop:** at most 10 substantive questions (see `## The question ceiling` below, which also defines what happens if the loop reaches it with topics still uncovered).

**Auto-mode exception:** the ceiling in auto mode is **5 substantive questions**, and the agent answers each question itself rather than mediating to the user, per Auto-mode rules 4 to 7. No `AskUserQuestion` calls fire in this step. Each agent-chosen answer is folded into `clarifications.answered[]` exactly as a human selection would be. Skip sub-steps 5a to 5d's `AskUserQuestion` mechanics and 5b's Discuss-this branch entirely; sub-step 5e (research dispatch) runs unmodified except for the uncertain-outcome fallback. The coverage scan still governs the stop.

For every **substantive** question asked (5a, 5b, 5c), increment `question_count` in the session-shape cache per the operational primitive (`spec-session-<spec_id>.json`). That counter is the ceiling counter. The loop's meta-prompts, 5d's exhaustion checkpoint, the 3-revisit settle prompt, and the research-outcome prompts do not increment it.

## Escape option (used in step 5 AskUserQuestion sets)

`Save partial and resume later` is never a listed option: `AskUserQuestion` takes at most four options, and each of them goes to a real answer or to `Discuss this`. The user reaches the escape two ways:

- **Typed into `Other`.** The tool adds a free-text `Other` to every question. When the user types a save request there ("save", "save partial", "resume later", or the like), take this escape rather than folding the text as an answer.
- **From inside `Discuss this`.** While discussing a topic (5b), offer saving as one way to end the discussion, and take this escape when the user picks it.

Taking the escape triggers: write draft cache (the working-draft checkpoint in `spec.md`'s Operational primitives), **Release the session lock (save-partial escape)** (`bash .gaia/scripts/spec/spec-session-lock.sh release "$PWD" "$SPEC_ID" || true`), print one-line resume hint (`SPEC-NNN saved as draft. Re-invoke /gaia-spec to resume.`), and exit gracefully.

The session-shape cache is NOT deleted on the `Save partial and resume later` path, a future resume reads it and continues counting questions against the same `start_at`. (Cache deletion happens only on canonical save at step 9, or on the `Discard SPEC-NNN draft cache` branch in step 2, see `spec/resume.md` for the discard handler, or on an abandoned-exit branch other than this one, see `### Abandoned exit` in `spec.md`.) The session lock, by contrast, IS released on this path; see the **Save-partial asymmetry** note in `spec/resume.md`'s `## Session-lock` for why the two caches are released on different schedules by design.

## Per-topic revisit counter

Track `push_deeper[<topic>] = <count>` in working memory. Increment on every "Push deeper on <topic>" selection at step 5d. When `count == 3` for any topic, replace the standard step 5d prompt with:

- question: `"<topic> has been revisited 3 times. Settle on a candidate, defer with rationale, or push deeper anyway?"`
- options:
  - `{ label: "Settle on the recommended option (Recommended)", description: "Accept the PO's best-judgment candidate and move on." }`
  - `{ label: "Defer <topic> with rationale", description: "Mark unresolved with a note for the planner." }`
  - `{ label: "Push deeper anyway", description: "Mine the topic further despite repeated revisits." }`

A save request typed into `Other` takes the escape in `## Escape option`.

## The question ceiling

The interactive Socratic loop asks **at most 10 substantive questions**. Auto mode asks **at most 5**.

**Substantive** means a closed-set question (5a), a Discuss-this settlement (5b), or an open-ended question (5c), counted once on first surfacing. Nothing that merely re-surfaces or resolves an already-counted question spends a second unit, and the loop's own meta-prompts, 5d's exhaustion checkpoint, the 3-revisit settle prompt, and the research-outcome prompts, never count.

There is exactly one counter and it needs no new storage: `question_count` in the session-shape cache (`.gaia/local/cache/spec-session-<spec_id>.json`, see the session-shape cache in `spec.md`'s Operational primitives) already counts substantive questions and already survives a pause and resume. The ceiling is therefore enforced against the **total across all sittings** of a session; a resumed session does not get a fresh budget.

**The ceiling is a bound, not a goal**: the coverage scan stops the loop (`## The loop`), and an unspent budget is the normal outcome.

**When the ceiling is reached with coverage incomplete**, the loop stops asking. Every topic still marked Partial or Missing is written to `clarifications.deferred[]` with a rationale naming it as ceiling-truncated (for example: `"Ceiling-truncated: 10 substantive questions asked; <topic> remained Partial."`). The loop does not push past the ceiling, and it does not advance to gate 2 as though coverage were complete.

The per-topic revisit counter and the escape option above both fit inside this budget.

## 5a. AskUserQuestion mediation (closed-set questions)

For every question with discrete possible answers, surface it via `AskUserQuestion`. The tool takes at most four options and adds its own free-text `Other` to every question, so list exactly these, in this order:

1. **Recommended option FIRST**: labeled `"<option text> (Recommended)"`. Use the PO's best judgment; the recommendation is annotated with code-context where helpful (e.g. `"Cards (reuses existing Card component)"`).
2. **Up to two alternatives**: the next most plausible options, in descending order of plausibility. When more than two alternatives are viable, list the strongest two and name the rest in the question text, so none is dropped silently and the user can still pick one through `Other`.
3. **`Discuss this`**: escape to plain Q&A (see 5b).

Never list `Other`: the tool supplies it. Text typed there is a free-form answer, or, when it asks to save, the escape in `## Escape option`.

Ask exactly one question per turn.

After the user selects an option (or types an answer into `Other`), persist the fold via a single `Write` per the working-draft checkpoint primitive (answer into `clarifications.answered[]`, topic removed from `clarifications.pending[]`, statusline updated, all in one call). `Discuss this` and a save request follow their own paths (5b and `## Escape option` respectively).

## 5b. Discuss-this escape

When the user picks `Discuss this`, drop the structured loop and engage in plain Q&A on that single topic. Mirror, name trade-offs, propose candidates. Offer saving as one way to end the discussion; if the user takes it, follow `## Escape option` instead of folding. When the user signals settlement (an explicit "ok, that one" or equivalent):

1. Persist the fold per the working-draft checkpoint primitive, single `Write` covering: discussion outcome appended to `clarifications.answered[]` as `{ q: "<original question>", a: "<settled outcome from discussion>" }`, topic removed from `clarifications.pending[]`, statusline updated. Once folded, **do not re-quote the raw Q&A** in downstream prompts.
2. Resume the structured loop on the next topic.

Do not loop back to the same closed-set options after a Discuss-this settlement. The discussion replaces the structured choice for that topic.

## 5c. Open-ended questions

For genuinely open-ended questions (no clean discrete option set), use a plain prompt, not `AskUserQuestion`. Coach tone, never interrogator. Ask one at a time. After each answer, persist the fold via a single `Write` per the working-draft checkpoint primitive (answer into `clarifications.answered[]`, topic removed from `clarifications.pending[]`, statusline updated, all in one call).

## 5d. Per-topic exhaustion checkpoint

When the loop is about to leave the current topic, whether because its coverage mark has reached **Clear** or because the coverage scan's prioritization now ranks a different topic above it (see the coverage scan, Rule 8, in `.claude/skills/gaia/references/spec/clarify-prompts.md`), announce explicitly via `AskUserQuestion`:

- question: `"Out of questions on <topic>. Move to <next topic>, or push deeper?"`
- header: `"Topic"`
- options:
  - `{ label: "Move to <next topic> (Recommended)", description: "Advance to the next discovery area." }`
  - `{ label: "Push deeper on <topic>", description: "Mine the current topic further." }`

The tool's `Other` takes a typed topic name to jump to, or a save request (`## Escape option`); list neither.

On `Push deeper on <topic>`, increment `push_deeper[<topic>]`. When that counter reaches 3 for any topic, switch to the revisit-counter prompt (see `## Per-topic revisit counter`) instead of repeating this checkpoint.

## 5e. Research subagent dispatch

For any question that requires prior-art lookup, repo-convention investigation, or competitive analysis, dispatch a research subagent, never punt the research to the user.

**Announce the dispatch before dispatching**, verbatim per `clarify-prompts.md` Rule 6.

Spawn a `general-purpose` Agent, passing `effort: "medium"` on the Agent call, with a focused research prompt. Handle the return based on outcome:

- **Found (useful findings).** Fold into `research_summary` of the draft. Cite sources. Write draft cache. Continue the loop.
- **Inconclusive (agent searched but found nothing definitive).** Fold the inconclusive note into `research_summary` as a known gap. Re-prompt the original closed-set question with the research context attached as a footnote so the user can decide informed.
- **Error (agent did not return findings or returned an error).** Surface to the user via `AskUserQuestion` (header `Research`, single-select), question `Research agent did not return findings on "<question>". How should this question proceed?`, with the options `Answer manually (Recommended)`, `Defer with rationale` and `Skip this question`. Wait for direction. Do not silently continue.
- **Contradictory (agent returned multiple plausible answers).** Surface the candidates via `AskUserQuestion` in the 5a shape: each candidate as an option, the recommended one first and at most three in all, then `Discuss this`; name any further candidate in the question text. Let the user pick.

If the user has selected `Discuss this` on a question that turns out to need research, dispatch the research subagent (the same `general-purpose` dispatch with `effort: "medium"`) and surface findings in the discussion before requesting settlement.

## When the loop stops

Once the coverage scan stops the loop, or the ceiling bounds it with the uncovered topics deferred, control returns to `spec.md` step 6 (self-review).
