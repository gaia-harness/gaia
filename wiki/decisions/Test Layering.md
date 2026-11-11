---
type: decision
status: active
priority: 2
date: 2026-11-01
created: 2026-11-01
updated: 2026-11-11
tags: [decision, testing, tdd, layering, authorization]
---

# Test Layering

Write tests, not too many, mostly integration: the route layer is the default home for behavior. Story interaction tests carry component behavior and real-server checks carry what the framework serves; unit and browser tests stay thin. A unit test is written only when both unit-test conditions hold: the integration layer cannot cover its cases cheaply, and the logic is important or likely to fail. Important means a wrong result corrupts data, breaks auth or a security or trust boundary, mishandles untrusted input, or computes money, dates or other values users rely on. Likely to fail means non-obvious logic: parsing, normalization, edge-heavy rules, concurrency. Branchy but low-stakes helpers do not qualify: formatting, small array, string and object utilities, and thin wrappers get their coverage from the integration tests that use them, or none if nothing uses them. At most one test per user-observable behavior, and a parameterized table is one test: a cap, not a quota; the tests the rules require (a critical flow, a guard's failing state, a bug fix) still apply. Nothing the type checker or lint already proves is tested. Browser tests stay few and focused on critical flows, and a simple project needs less than the full shape: a tiny app gets few tests, not a scaled-down copy of a big app's suite. A browser is the most expensive layer, so a check that a cheaper layer proves does not get a browser test. This page owns that principle, its rationale and the stack mapping. The React testing reference is `apps/web/.claude/skills/tdd-react/references/tests-react.md`; it links here rather than restating it.

## Rationale

Browser time is the expensive layer in three ways. A browser test boots the server and Chromium, so each one costs seconds where a unit or route test costs milliseconds. Browser tests share a live stack, so parallel workers contend for one store and a test needs per-worker isolation (see [[#Worker isolation]]). And a failing browser test names a flow, not a cause, so finding the broken rule costs more than the test saved.

A check that duplicates one another test already proves adds cost and no coverage. The overlap pass reads every layer and proposes dropping or merging a duplicate, folding two or more tests into an existing integration test that already asserts their property, moving a browser test to the real-server or route layer, moving component behavior to a story, and moving a test to the unit layer only with a reason stating both unit-test conditions. The worthiness review judges each new test on its own worth and may cite an integration test that covers a unit test; proposals across layers are the overlap pass's ([[Worthiness Audit]]).

## The layers

From lowest to highest:

1. **Unit and story.** A function, a hook, or one component given props; a unit test needs both unit-test conditions above. Vitest `node` and `browser` projects and Storybook stories ([[Stories as Tests]]).
2. **Route.** A request taken in process by a route module's `loader` or `action`, with no browser and no server. The route surface is the lowest layer that takes a request in process: it shows a status, a redirect, returned data, a validation error, an authorization outcome or a side effect. It runs in the Vitest `node` project.
3. **Real server.** The live stack, driven by Playwright's request fixture: it opens no page and makes no browser round trip. Only this layer shows what the framework serves: middleware, the HTTP status of a refusal, cookies and the session across the server, and the server's rendered HTML, read through the request fixture and a parsed response body. A forged request belongs here only when its guard is one a direct route call skips, and rendered HTML only when that HTML is itself the requirement; a heading whose text is data the loader returns is a route check, and so is a refusal or error outcome a direct `loader` or `action` call returns, even when a page or error boundary renders it.
4. **Browser.** A real page, used only for a capability no lower layer shows, from the closed list under [[#When a test needs a real browser]], one test per user flow, plus one Playwright spec per critical web flow (see that section). A JavaScript-disabled Given or a native form post rules out the browser and nothing else: it routes by the route and real-server layers, and a then-clause that needs the served form or a multi-page workflow over native forms is a real-server check, with the form body built by `serializeForm` (`apps/web/.playwright/html.ts`) from the served page.

Sibling browser tests that walk one flow fold into one journey, and the fold is the recommended fix. Every transition, status or role rule has exactly one case table, at the layer this page picks, holding every case of the rule; a test of that rule at any other layer keeps one row per outcome to prove the wiring. The real-server check of a guarded module is not a test of the rule and keeps its single refusal row. Rules of one kind may share one parameterized table.

A live-stack test goes to the real-server or browser surface, never to the legacy end-to-end surface.

Only the frontend package renders route rows today. [[Testing]] describes the frontend's layers in place.

## When a test needs a real browser

A browser test is written only for a capability no lower layer shows. The closed list:

- `client JavaScript`: behavior that runs in the page, such as an update without a reload or an optimistic change.
- `layout or visual position`: where an element sits relative to another, or whether it fits the viewport.
- `focus or keyboard`: where focus lands and how keys move it.
- `rendered-DOM accessibility scan`: an automated accessibility check of the DOM the browser renders.
- `browser-only navigation`: history, back and forward, or a client-side transition no request shows.

One exception: one Playwright spec per critical web flow, written after the build in `<frontend package>/.playwright/flows/`, is admitted on the browser layer whatever a cheaper layer could prove. It carries the journey, the effects that take several requests or sessions to stage, and, where the SPEC requires the flow to work without JavaScript, a real-server check of its native form posts; a refusal or validation one request shows sits at the route or real-server layer this page picks. The list governs every other browser test.

## Stack mapping

The layers are not React-specific. Each has an equivalent in other server stacks:

| Concept          | Other stacks                                                                                                                                              |
| ---------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Route surface    | Rails request specs, the Django test client, supertest on Express, Go `httptest`                                                                          |
| Worker isolation | one Postgres schema per worker, Rails `parallelize`, pytest-xdist with a database per worker, one SQLite file and server per worker |

## Worker isolation

Parallel workers that share one store cannot hold independent state. Each worker seeds and reads the MSW store of its own dev server, keyed on its worker index. A serial project is not an accepted way to share one. The shipped pattern is in `apps/web/.playwright/fixtures.ts` and its rule is in `apps/web/.claude/rules/playwright.md`.

## Authorization bug classes

Each class of authorization bug has one layer that fails for it, and a test that fails when the bug is present:

| Bug class                                    | Layer       | The test that fails                                                                              |
| -------------------------------------------- | ----------- | ------------------------------------------------------------------------------------------------ |
| A rule function returns the wrong answer     | Unit        | The rule function called with an actor it must refuse                                            |
| A route module omits its guard               | Route       | The `action` or `loader` called with an anonymous `Request` returns data or performs the write   |
| A guarded route module's refusal is served with the wrong HTTP status | Real server | A request with redirects off asserts the status and any `Location` header the framework serves   |

A route test does not observe the status the framework serves, so only the third class needs the real server. A plan carries one real-server check per guarded route module, asserting only the served status and any `Location` header, never page content a route test shows; every other refusal a direct `loader` or `action` call shows is a route check. The one exception to the status-only assertion is the parent-loader `.data` check below: it asserts the child's data is absent from the response body, since a status alone does not show that refusal.

### What a route test cannot prove

- A direct call to a `loader` or `action` skips middleware, so a guard that lives in middleware is proven by a real-server check.
- A parent loader guards neither a child's action nor a child's loader on a single-fetch request. A write action guards itself, and a direct anonymous call to it is the proof. A parent-loader guard on a read is proven by a real-server `.data` request naming only the child route.
- An authorization outcome owned by an upstream API cannot be proven by a route test, since an MSW handler answers as the test wrote it.

### What a real-server check cannot prove

The Playwright stack is `pnpm dev` with MSW. Production-only cookie and error behavior is not exercised, and neither is authorization an upstream API owns, since MSW answers for it.

## What mocks cannot prove

GAIA's layers run against MSW handlers that mirror the backend's contract. They cannot prove the hookup (auth cookies, CORS, environment config, proxies), which needs a thin smoke suite the project runs against its real backend, and drift between the handlers and the backend's contract is the project's to guard. Behavior only a real backend shows is that suite's, never a GAIA layer's.

## Related

- [[Testing]]: the frontend's layers in place.
- [[Stories as Tests]]: the component layer.
- [[Worthiness Audit]]: the emergent surface the audit judges.
- [[Determinism Classifier]]: the per-file signal that labels a test file strict or emergent for the worthiness audit.
