---
type: decision
status: active
priority: 2
date: 2026-11-01
created: 2026-11-01
updated: 2026-11-05
tags: [decision, testing, tdd, layering, authorization]
---

# Test Layering

Write tests, not too many, mostly integration: the route layer is the default home for behavior. Story interaction tests carry component behavior and real-server checks carry what the framework serves; unit and browser tests stay thin. A unit test is written only when both unit-test conditions hold: the integration layer cannot cover its cases cheaply, and the logic is important or likely to fail. Important means a wrong result corrupts data, breaks auth or a security or trust boundary, mishandles untrusted input, or computes money, dates or other values users rely on. Likely to fail means non-obvious logic: parsing, normalization, edge-heavy rules, concurrency. Branchy but low-stakes helpers do not qualify: formatting, small array, string and object utilities, and thin wrappers get their coverage from the integration tests that use them, or none if nothing uses them. One test per user-observable behavior; a parameterized table is one test; nothing the type checker or lint already proves is tested. Browser tests stay few and focused on critical flows, and a simple project needs less than the full shape: a tiny app gets few tests, not a scaled-down copy of a big app's suite. A browser is the most expensive layer, so a check that a cheaper layer proves does not get a browser test. This page owns that principle, its rationale and the stack mapping. The operational ladder a plan follows is in `.claude/skills/gaia/references/plan/planner.md`; the React testing reference is `apps/web/.claude/skills/tdd-react/references/tests-react.md`. Both link here rather than restate it.

## Rationale

Browser time is the expensive layer in three ways. A browser test boots the server and Chromium, so each one costs seconds where a unit or route test costs milliseconds. Browser tests share a live stack, so parallel workers contend for one database and a test needs per-worker isolation (see [[#Worker isolation]]). And a failing browser test names a flow, not a cause, so finding the broken rule costs more than the test saved.

A check that duplicates one another test already proves adds cost and no coverage. The overlap pass reads every layer and proposes dropping or merging a duplicate, folding two or more tests into an existing integration test that already asserts their property, moving a browser test to the real-server or route layer, moving component behavior to a story, and moving a test to the unit layer only with a reason stating both unit-test conditions. The worthiness review judges each new test on its own worth and may cite an integration test that covers a unit test; proposals across layers are the overlap pass's ([[Worthiness Audit]]).

## The layers

From lowest to highest:

1. **Unit and story.** A function, a hook, or one component given props; a unit test needs both unit-test conditions above. Vitest `node` and `browser` projects and Storybook stories ([[Stories as Tests]]).
2. **Route.** A request taken in process by a route module's `loader` or `action`, with no browser and no server. The route surface is the lowest layer that takes a request in process: it shows a status, a redirect, returned data, a validation error, an authorization outcome or a side effect. It runs in the Vitest `node` project.
3. **Real server.** The live stack, driven by Playwright's request fixture: it opens no page and makes no browser round trip. Only this layer shows what the framework serves: middleware, the HTTP status of a refusal, cookies and the session across the server, and the server's rendered HTML, read through the request fixture and a parsed response body. A forged request belongs here only when its guard is one a direct route call skips, and rendered HTML only when that HTML is itself the requirement; a heading whose text is data the loader returns is a route check, and so is a refusal or error outcome a direct `loader` or `action` call returns, even when a page or error boundary renders it.
4. **Browser.** A real page, used only for a capability no lower layer shows, from the closed list at the browser step of the planner's ladder (`.claude/skills/gaia/references/plan/planner.md`), one test per user flow. A JavaScript-disabled Given or a native form post rules out the browser and nothing else: it routes by the route and real-server layers, and a then-clause that needs the served form or a multi-page workflow over native forms is a real-server check, with the form body built by `serializeForm` (`apps/web/.playwright/html.ts`) from the served page.

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
| A guarded route module's refusal is served with the wrong HTTP status | Real server | A request with redirects off asserts the status and the `Location` header the framework serves   |

A route test does not observe the status the framework serves, so only the third class needs the real server. A plan carries one real-server check per guarded route module; every other refusal a direct `loader` or `action` call shows is a route check.

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
