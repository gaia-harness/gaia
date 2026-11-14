---
type: decision
status: active
priority: 2
date: 2026-11-01
created: 2026-11-01
updated: 2026-11-14
tags: [decision, testing, tdd, layering, authorization]
---

# Test Layering

Write tests, not too many, mostly integration. The rules that say which test to write and at which layer live in [`.claude/doctrine/testing.md`](../../.claude/doctrine/testing.md), which every plan, executor, reviewer and fixer follows; this page keeps the reasons behind them. The React testing reference is `apps/web/.claude/skills/tdd-react/references/tests-react.md`; it links here for the reasons rather than restating them.

## Rationale

Browser time is the expensive layer in three ways. A browser test boots the server and Chromium, so each one costs seconds where a unit or route test costs milliseconds. Browser tests share a live stack, so parallel workers contend for one store and a test needs per-worker isolation (see [[#Worker isolation]]). And a failing browser test names a flow, not a cause, so finding the broken rule costs more than the test saved.

A check that duplicates one another test already proves adds cost and no coverage. A tiny app needs few tests, not a scaled-down copy of a big app's suite, and a test earns its place by failing when the behavior breaks.

## Why route is the default

Route is the default home for behavior because the route surface is the lowest layer that takes a request in process. A request through a route module's `loader` or `action` shows a status, a redirect, returned data, a validation error, an authorization outcome or a side effect, with no server and no browser, in the Vitest `node` project. Most behavior a user relies on crosses that surface, so one route test proves what a unit test of each helper behind it would only approximate, and it keeps passing when the helpers are refactored.

A unit test sits below the default and earns its place only for logic the integration layer cannot cover cheaply and whose wrong answer is costly or likely. Formatting helpers and thin wrappers get their coverage from the tests that use them, since a test of each would pin the implementation and fail on a refactor that changes no behavior.

Only the frontend package renders route rows today. [[Testing]] describes the frontend's layers in place.

## Why the browser list is closed

A browser is the most expensive layer, so it is reserved for what no lower layer shows: behavior that runs in the page, layout, focus and keyboard movement, a rendered-DOM accessibility scan, and browser-only navigation. Each is something the browser alone computes. A request, a status or a rendered value is shown cheaper below, so a closed list keeps one more browser test from eroding that cost. The closing flow test is admitted to the browser layer whatever a cheaper layer could prove, because the journey walked end to end is itself the requirement. Sibling browser tests that walk one flow fold into one journey because each repeats the same boot and sign-in cost for no new capability.

A JavaScript-disabled Given or a native form post rules out the browser and nothing else: it is a real-server check, with the form body built by `serializeForm` (`apps/web/.playwright/html.ts`) from the served page, because only the framework serves that form.

## Why a case table is one test

A rule with many cases is one behavior with many inputs. A parameterized table asserts every case in one place, so a new case is a new row rather than a new test, and the rule has one home a reader can find instead of the same cases restated at several layers. Another layer keeps one row per outcome only to prove the wiring reaches the rule, since the rule's own cases were already driven where it lives.

## Worker isolation

Parallel workers that share one store cannot hold independent state. Each worker seeds and reads the MSW store of its own dev server, keyed on its worker index. A serial project is not an accepted way to share one. The shipped pattern is in `apps/web/.playwright/fixtures.ts` and its rule is in `apps/web/.claude/rules/playwright.md`.

## Stack mapping

The layers are not React-specific. Each has an equivalent in other server stacks:

| Concept          | Other stacks                                                                                                                         |
| ---------------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| Route surface    | Rails request specs, the Django test client, supertest on Express, Go `httptest`                                                     |
| Worker isolation | one Postgres schema per worker, Rails `parallelize`, pytest-xdist with a database per worker, one SQLite file and server per worker |

## Authorization bug classes

Each class of authorization bug has one layer that fails for it, and a test that fails when the bug is present:

| Bug class                                                             | Layer       | The test that fails                                                                            |
| --------------------------------------------------------------------- | ----------- | ---------------------------------------------------------------------------------------------- |
| A rule function returns the wrong answer                              | Unit        | The rule function called with an actor it must refuse                                          |
| A route module omits its guard                                        | Route       | The `action` or `loader` called with an anonymous `Request` returns data or performs the write |
| A guarded route module's refusal is served with the wrong HTTP status | Real server | A request with redirects off asserts the status and any `Location` header the framework serves |

A route test does not observe the status the framework serves, so only the third class needs the real server. The served check asserts only the status and any `Location` header because page content is what the route test already shows, and repeating it at the served layer adds cost and no coverage. The parent-loader `.data` check is the exception, since a status alone does not show that a refused read returned none of the child's data.

### What a route test cannot prove

- A direct call to a `loader` or `action` skips middleware, so a guard that lives in middleware is proven by a real-server check.
- A parent loader guards neither a child's action nor a child's loader on a single-fetch request, so a write action guards itself and a parent-loader guard on a read needs its own served check.
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
