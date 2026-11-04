---
type: decision
status: active
priority: 2
date: 2026-11-01
created: 2026-11-01
updated: 2026-11-04
tags: [decision, testing, tdd, layering, authorization]
---

# Test Layering

Every check lives at the lowest layer that can prove it. A browser is the most expensive layer, so a check that a cheaper layer proves does not get a browser test. This page owns that principle, its rationale and the stack mapping. The operational ladder a plan follows is in `.claude/skills/gaia/references/plan/planner.md`; the React testing reference is `apps/web/.claude/skills/tdd-react/references/tests-react.md`. Both link here rather than restate it.

## Rationale

Browser time is the expensive layer in three ways. A browser test boots the server and Chromium, so each one costs seconds where a unit or route test costs milliseconds. Browser tests share a live stack, so parallel workers contend for one database and a test needs per-worker isolation (see [[#Worker isolation]]). And a failing browser test names a flow, not a cause, so finding the broken rule costs more than the test saved.

A check that duplicates one a lower layer already proves adds cost and no coverage. The overlap pass reads every layer and proposes dropping or merging such a duplicate and demoting a test to the lowest layer that shows its property, including a browser test to the real-server layer; the worthiness audit stays on its own surface, the emergent tests, and does not compare across layers ([[Worthiness Audit]]).

## The layers

From lowest to highest:

1. **Unit and story.** A function, a hook, or one component given props. Vitest `node` and `browser` projects and Storybook stories ([[Stories as Tests]]).
2. **Route.** A request taken in process by a route module's `loader` or `action`, with no browser and no server. The route surface is the lowest layer that takes a request in process: it shows a status, a redirect, returned data, a validation error, an authorization outcome or a side effect. It runs in the Vitest `node` project.
3. **Real server.** The live stack, driven by Playwright's request fixture: it opens no page and makes no browser round trip. Only this layer shows what the framework serves: middleware, the HTTP status of a refusal, a forged request against a live route, and the server's rendered HTML, read through the request fixture and a parsed response body.
4. **Browser.** A real page, used only for a capability no lower layer shows, from the closed list at the browser step of the planner's ladder (`.claude/skills/gaia/references/plan/planner.md`), one test per user flow. A JavaScript-disabled Given, a native form post and a multi-page workflow over native forms are real-server checks, with the form body built by the template's form-serializing helper from the served page.

Sibling browser UATs that walk one flow fold into one browser journey UAT, and the fold is the recommended fix. Each transition, status or role rule stays its own UAT, routed by the planner's ladder. Sibling non-browser UATs stay separate, one per rule.

A new plan routes a live-stack UAT to `real-server` or `browser`, never to the legacy end-to-end surface; the operational ladder is in `.claude/skills/gaia/references/plan/planner.md`.

Only the frontend package renders route rows today. [[Testing]] describes the frontend's layers in place.

## Stack mapping

The layers are not React-specific. Each has an equivalent in other server stacks:

| Concept          | Other stacks                                                                                                                                              |
| ---------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Route surface    | Rails request specs, the Django test client, supertest on Express, Go `httptest`                                                                          |
| Worker isolation | one Postgres schema per worker, Rails `parallelize`, pytest-xdist with a database per worker, one SQLite file and server per worker |

## Worker isolation

Parallel workers that share one database cannot hold independent state. Each worker reaches its own database through the server it talks to, keyed on its worker index. A serial project is not an accepted way to share one. The shipped pattern is in `apps/web/.playwright/fixtures.ts` and its rule is in `apps/web/.claude/rules/playwright.md`.

## Authorization bug classes

Each class of authorization bug has one layer that fails for it, and a test that fails when the bug is present:

| Bug class                                    | Layer       | The test that fails                                                                              |
| -------------------------------------------- | ----------- | ------------------------------------------------------------------------------------------------ |
| A rule function returns the wrong answer     | Unit        | The rule function called with an actor it must refuse                                            |
| A route module omits its guard               | Route       | The `action` or `loader` called with an anonymous `Request` returns data or performs the write   |
| A refusal is served with the wrong HTTP status | Real server | A request with redirects off asserts the status and the `Location` header the framework serves   |

A route test does not observe the status the framework serves, so only the third class needs the real server. A plan carries one real-server check per guarded route module.

### What a route test cannot prove

- A direct call to a `loader` or `action` skips middleware, so a guard that lives in middleware is proven by a real-server check.
- A parent loader guards neither a child's action nor a child's loader on a single-fetch request. A write action guards itself, and a direct anonymous call to it is the proof. A parent-loader guard on a read is proven by a real-server `.data` request naming only the child route.
- An authorization outcome owned by an upstream API cannot be proven by a route test, since an MSW handler answers as the test wrote it.

### What a real-server check cannot prove

The Playwright stack is `pnpm dev` with MSW. Production-only cookie and error behavior is not exercised, and neither is authorization an upstream API owns, since MSW answers for it.

## Related

- [[Testing]]: the frontend's layers in place.
- [[Stories as Tests]]: the component layer.
- [[Worthiness Audit]]: the emergent surface the audit judges.
- [[Determinism Classifier]] and [[TDD RED Verification]]: how a route test is gated.
