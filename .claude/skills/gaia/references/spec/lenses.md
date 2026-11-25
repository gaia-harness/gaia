# /gaia-spec: lens focus text

The focus text of each SPEC review lens. Each lens agent `spec/audit.md` `## The lenses` dispatches reads only its own section, named by its id prefix; every other section belongs to another lens of the same wave. The main thread never reads this file.

## Core lenses

### TST: Flow and criteria testability (id prefix `TST`)

Attack each behavior, flow and success criterion for falsifiability and GAMEABILITY. For each weak one, describe the concrete scenario where it passes while the feature is still broken or useless (e.g. a "points to X" criterion that passes on a bare path drop), and propose a tighter, doc-grep- or test-checkable statement. A behavior states its cases (each actor, state, input and refusal it covers, and the outcome by value: the status, message, redirect or literal text the user observes) concretely enough that a test could be written from the text alone; one stated by example, by "etc." or over a set the draft never lists does not. Name the property a test must prove, never the layer, fixture or helper that proves it. A tighter statement says what the user observes (`the page shows Status: Open`); when the gap is page markup or accessibility structure (an element's whole text, a heading level, a landmark, a label association), propose a plan-time directive stating that rule for the page or component it applies to, never flow or success-criterion text. Flag any flow or success criterion with no obvious verification method. A flow or success criterion that needs a real backend (persistence across a restart, a database reset, a production start against a real store) is a finding: move it to Out of scope as adopter-owned end-to-end.

Three miss classes recur; hunt each one for every behavior:

- **Forged or edited input.** For every field, id or value a client submits, the draft states the outcome when it is forged or edited (another actor's id, a status the actor may not set, a field the form never sends): the refusal or the unchanged state, by value.
- **Displayed form.** For every stored or wire value (a date, an amount, a status, an enum, an id), the draft states the form the user sees (the label, format and literal text), never the raw stored value.
- **State after a partial write.** For every operation that makes more than one write or call, the draft states the state left when a later call fails midway: what is kept, what is rolled back, and what the user sees.

### COV: Coverage and consistency (id prefix `COV`)

Build the cross-matrix intent, `success_criteria`, flows, behaviors and `scope_boundaries`, and find the holes: orphan success criteria no flow or criterion covers; promises in the intent no flow covers; critical flows the SPEC needs but lacks; contradictions between `always`/`never`/`ask_first` and the flows or intent; flows the SPEC's own behavior rules make impossible, such as a control, transition or value the SPEC allows only in another state (cite the flow line and the rule line); `scope_boundaries` entries that are not enforceable or observable; every requirement in `<REQUIREMENTS_PATH>` that reaches no stated behavior; and whether the SPEC respects the project's established conventions (its `CLAUDE.md` rules, coding guidelines, naming).

Two of the miss classes recur here; hunt each one for every behavior:

- **Displayed form.** For every stored or wire value (a date, an amount, a status, an enum, an id), the draft states the form the user sees (the label, format and literal text), never the raw stored value.
- **State after a partial write.** For every operation that makes more than one write or call, the draft states the state left when a later call fails midway: what is kept, what is rolled back, and what the user sees.

### SEC: Security (id prefix `SEC`)

Hunts for: injection, SSRF, open redirect, token or secret leakage, missing authorization, unsafe deserialization; a credential the app holds for another service (an API or session token, even the user's own) with no SPEC rule keeping it unreadable in the browser (a signed-only cookie is readable); whether the SPEC's security claim holds and its acceptance gate is adversarial.

Two of the miss classes recur here; hunt each one for every behavior:

- **Forged or edited input.** For every field, id or value a client submits, the draft states the outcome when it is forged or edited (another actor's id, a status the actor may not set, a field the form never sends): the refusal or the unchanged state, by value.
- **Who is refused each grant.** For every action, page, field or record the draft grants an actor, it states who is refused it, including the link or action withheld from each other role, not only the actor it is granted to.

### BRIEF-FIT: Brief fit (id prefix `BRIEF-FIT`)

The brief is the source of truth and the draft is checked against it, never the reverse. Read the `## Brief` section of `<REQUIREMENTS_PATH>` whole before the draft, and list for yourself every statement it makes: each actor and what the brief says it may and may not do, see or change; each entity, field, state and transition; each value, limit, message and other literal; each refusal; each exclusion or out-of-scope line. Then read the draft whole, including its decisions, assumptions, defaults, resolved questions and behaviors, and find:

- **Against the brief.** Every decision, default, assumption, resolved question or behavior in the draft that a brief statement contradicts. A label such as "decision", "assumption" or "default" never licenses contradicting the brief. Quote both lines.
- **Widened authority.** Every action, page, field, record or data access the draft lets an actor (a role, a signed-out visitor, an owner or non-owner, an assignee) reach that no brief statement grants that actor. Where the brief lists who may do something, read the list as closed: every actor outside it is refused, and a draft that grants it to anyone else widens the brief, however harmless the grant looks. A draft refusing an actor something the brief grants is a finding too.
- **Added scope.** Every feature, page, endpoint, field, state, setting or limit the draft adds that the brief does not ask for. One a stated behavior cannot work without is forced: still list it, as `minor`, and say what forces it. A default that only fills a gap the brief leaves (a sort order, a page size, a format) and changes no actor's access and no stated outcome is not a finding.
- **Dropped or changed.** Every brief statement the draft does not carry: a rule, an actor, a state, a value, a limit, a refusal, an exclusion, or a user-visible literal (a label, a message, a heading, a button text). A statement the draft carries with a different value, wording or scope is changed, and counts the same.

One of the miss classes recurs here; hunt it for every grant:

- **Who is refused each grant.** For every action, page, field or record the draft grants an actor, it states who is refused it, including the link or action withheld from each other role, not only the actor it is granted to.

Severity, a lens-specific addition to the shared rubric: a contradiction of the brief, widened authority, or a dropped or changed refusal, access rule or security statement is `critical`; a narrowing (the draft refusing more than the brief) is `major` at most; any other dropped or changed rule, value or literal is `major`; added scope that changes no access and no stated outcome is `minor`. Evidence quotes the brief as `REQUIREMENTS.md § <heading>` and the draft as `file:line`. Each recommendation brings the draft back to the brief: remove the grant and state the refusal, restore the statement by value, or remove the added scope (forced scope stays, marked in the draft as an assumption with what forces it). Where the brief can be read two ways, recommend the narrower reading for who may do what, stated as an assumption in the draft; never recommend widening the brief.

### FG: Factual grounding (id prefix `FG`)

Treat the SPEC as a set of factual claims and verify each load-bearing claim true or false against ground truth. For every claim about code, an installed dependency, an export subpath, a file path, or an existing convention, open the artifact and confirm it resolves, including whether any newly added dependency is justified and version-pinned. Any claim that is false or overstated is at least `major`, likely `critical`.

## Specialist lenses

Each section is what that specialist hunts for.

### MIG

Existing-data handling, reversibility and rollback, dual-read or dual-write windows, version skew, what breaks for legacy or in-flight records.

### A11Y

Flows and criteria that pass an axe rule yet fail real assistive tech; missing keyboard, focus-order, label, contrast, or landmark criteria; aria misuse.

### DOC

Duplication of an authoritative source, rot-resistance, dead cross-references, pointer criteria satisfiable by a bare path drop.

### PERF

Speculative-versus-real cost, N+1, unbounded growth, flaky warm/cold performance gates.
