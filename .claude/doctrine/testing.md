# Testing doctrine

## Scope

This file owns which test to write and at which layer. Every plan, executor, reviewer, evaluator, fixer and the tdd skills follow it, and every other source states only how to write a test at a layer, plus a pointer here. The reasons behind these rules live in `wiki/decisions/Test Layering.md`, `wiki/decisions/Testing Trophy Doctrine.md` and `wiki/decisions/Stories as Tests.md`.

How to write a test at a layer lives in the stack references:

- `apps/web/.claude/skills/tdd-react/references/tests-react.md`: unit, hook, story and route tests.
- `.claude/skills/tdd/references/tests-shell.md`: shell tests.
- `apps/web/.claude/rules/playwright.md`: real-server, browser and flow tests.
- `apps/web/.claude/rules/storybook.md`: stories.

## What to test

**Stated requirement.** A stated requirement is a SPEC flow, a success criterion, a scope boundary, an answered clarification, an audit directive, or a statement in a document the SPEC's Required reading names. A spec-less plan's stated requirement is its description; work with no plan states its requirement in its issue or request.

- Test stated requirements only.
- Never plan, list or write a test for a corner case or an error path no stated requirement names.
- Give a bug fix one test that reproduces the bug.
- Write at most one test per user-observable behavior; a case table is one test. This is a cap, not a quota: the tests the rules below require still apply.
- Assert every case a multi-case requirement lists. Split a compound condition into one case per part (`an open, unlocked account`: a closed account, a locked account). Split an order-of-checks requirement into one case per adjacent pair of checks, with an input that passes every earlier check, fails both checks of the pair, and asserts the earlier one refused.
- Give every transition, status or role rule exactly one case table holding every case, at the layer the layer rule picks. A test of that rule at another layer keeps one row per outcome to prove the wiring, except an allowed outcome the closing flow test walks and asserts.
- Assert a role, accessible name or exact wording a stated requirement gives as that stated literal (`A New user link`: role link, name `New user`). One existing or planned test at any layer satisfies it, and one story or route test may hold all of a page's stated literals; never add a flow for one.
- Never assert through an import of the app's own string: it proves only that the app agrees with itself.
- Name the closing flow test as the owner of a happy path it walks and asserts, with no success-path route test of its own; an effect the flow cannot observe keeps its route test.
- Test several callers that map an upstream failure through one shared helper once, at the mapping, unless a caller maps differently. This never applies to a guard (`## Guards and security rows`).
- Never test what the type checker or lint already proves.
- Never plan a self-test of a mock, fixture, Given builder or test-fixture wiring once an app test exercises that path.
- Give a behavior only a real backend shows (data surviving a restart, a database reset, a production start against a real store) no test; name it as adopter-owned end-to-end work in the plan's follow-ups.

## Layers

**Layer.** Every test has exactly one layer:

- **Unit test**: a function or a hook, in the Vitest `node` or `browser` project.
- **Story**: a component or page given props, with each behavior a `.test()` attached to a story (`## Components, pages and stories`).
- **Route test**: a request taken in process by a route module's `loader` or `action`, with no server and no browser. It shows a status, a redirect, returned data, a validation error, an authorization outcome or a side effect.
- **Real-server check**: the live stack driven by Playwright's request fixture, opening no page. It shows what only the framework serves: middleware, the served status of a refusal, cookies and the session across requests, and served HTML (`## Served HTML`).
- **Browser test**: a real page, for a capability on the closed list below.
- **Flow test**: the one test file of one critical flow, written in the plan's closing phase after the build.
- **Shell test**: a bats suite driving a script or hook through its public interface.

**Default.** The route layer is the default home for behavior.

**The layer rule.** Place each test on the layer this section assigns to what it asserts: rendered output of one component or page is a story; a request outcome is a route test; what only the framework serves is a real-server check; a closed-list capability is a browser test; a script's behavior is a shell test. A harness guard with no user-facing page is tested where its caller sees it. Every other source that places a test points to this rule.

**Unit-test conditions.** Write a unit test only when both hold:

1. The integration layer cannot cover its cases cheaply.
2. The logic is important (a wrong result corrupts data, breaks auth or a trust boundary, mishandles untrusted input, or computes money, dates or other values users rely on) or likely to fail (parsing, normalization, edge-heavy rules, concurrency).

Formatting helpers, small array, string and object utilities, and thin wrappers meet neither; they get their coverage from the tests that use them.

**Browser-only capabilities.** Write a browser test only for one of these, never for a check a cheaper layer proves:

- client JavaScript: behavior that runs in the page, such as an update without a reload or an optimistic change;
- layout or visual position: where an element sits relative to another, or whether it fits the viewport;
- focus or keyboard: where focus lands and how keys move it;
- rendered-DOM accessibility scan;
- browser-only navigation: history, back and forward, or a client-side transition no request shows.

Fold sibling browser tests that walk one flow into one journey.

**Flow test.** Write one flow test per critical flow, in the closing phase only, never in a build phase. It holds the journey through the happy path, plus only the effects that take several requests or sessions to stage, plus, when the flow must work without JavaScript, a real-server check of its native form posts. A web flow test is admitted on the browser layer whatever a cheaper layer could prove. It asserts no markup structure or ARIA attribute beyond a stated role or accessible name, and repeats no refusal a build task's test or another flow owns.

**Path to layer.** In the web package:

- `.playwright/flows/**/*.spec.ts`, and any test a plan names as a flow test: flow. A page-less flow test is a flow test, never a real-server check.
- other `.playwright/**/*.spec.ts`: browser when the file opens a page anywhere, otherwise real-server.
- `app/route-tests/**/*.test.ts` and `test/**/*.server.test.ts`: route.
- `app/**/*.stories.tsx`: story.
- any other `app/**/*.test.ts(x)` and `test/**/*.test.ts(x)`: unit.

Outside it, a `.bats` file is shell unless a plan names it as a flow test. A harness self-check that opens no page is a Vitest `node` test, never a Playwright spec.

## Guards and security rows

**Guard.** A guard is code that refuses: an access check, a refusal, a validation or a gate.

- Drive every guard into its failing state with a test that asserts the refusal. A test that only watches a guard pass cannot tell a working guard from an inert one.
- Name a guard's test in the task that delivers the guard, never leave it to the closing flow test. One test may cover several guards.
- A flow test never stands in for a guard's lower-layer test, and a browser test or flow test never counts as the covering sibling of the only lower-layer test driving a guard.

**Anonymous write.** Prove that an authenticated write action refuses an anonymous request, with no side effect, by a route test calling the action with an anonymous `Request`.

**Protected read.** Prove that a loader returning protected data gives an anonymous request none of it, by a route test. A guard on a parent loader protecting a child's read also needs a real-server `.data` request naming only the child route, asserting the child's data is absent.

**Served check.** Give each guarded route module one real-server check, with redirects off, asserting only the served status and any `Location` header, never page content a route test shows. The parent-loader `.data` request is the one served check that asserts on the body.

**Shared guard.** Test a guard written once (middleware, a shared guard applied above the route) once at the guard, plus one served check. Give a module its own refusal test only when its own code wires the guard, so removing that wiring leaves the module unguarded.

**Middleware guard.** A route test that runs the real middleware chain proves a middleware guard; a route test that hand-calls a context provider does not, and without the chain the guard needs a real-server check. An authorization outcome an upstream API owns is proven by no GAIA layer, since a mock handler answers as the test wrote it.

**Later-request rule.** Test a rule that takes effect on a later request (a role change, a deactivation, a sign-out ending a token) with a before-and-after read in one session, at the row's layer.

**Forged value.** For a signed or encrypted value the app issues (a cookie, a session, a token), send a forged or edited one and assert the refusal. For a server-owned field the server must ignore (an owner or author), submit a forged value and assert the server ignored it.

**Absence requirement.** For a value that must never be exposed, sent, stored or rendered, every task that adds a way for it to reach the forbidden surface tests its absence on that surface while the value is present upstream. Served HTML, a cookie or the session is a real-server check; returned data, an outgoing request or any other write is a route test.

**Security row.** A security row's test proves one of three kinds:

- **Access**: who may act or see. Sign-in, role, ownership and visibility, account state that decides whether an actor may act (deactivated, suspended, a role change on the next request), and authorization checked before validation or data access. A status rule that decides whether an actor may act is access.
- **Forgery**: refusal of forged, tampered or server-owned values.
- **Secrets**: values that must never be exposed.

Ordinary validation and status rules are not security rows. A retire or change row on an existing test of one of these kinds carries the flag too.

- When a security test fails, fix the code, never weaken the test.
- Only the maintainer rules a security row wrong, removes its flag, or retires an existing security test.
- Retire or fold a test asserting escaping, sanitization, injection resistance or data integrity only into a test on its own layer or higher that asserts the same property.

## Components, pages and stories

**Story.** Every component and page has a story, one story per visual state. A pure-utility component with no visual output (a context provider, a markup-less higher-order component) gets a Vitest test instead.

- Test a component's or page's behavior as a `.test()` on its story. A fresh render in a separate test file is for hooks only.
- A play function drives the UI into the state the snapshot shows and asserts nothing.
- A render-only story is complete only for a component with no interactive behavior.
- Every page story carries the landmark check, one `.test()` asserting one level-1 heading and one `main` landmark. It is standing: its row cites the requirement that delivers the page, and no reviewer flags it as trivial.
- A vendored `ui` component gets render-only stories, plus a `.test()` only for behavior the app adds on top of it.

**Own key and focus code.** Code in the app's tree that handles keys or moves focus (a key handler, roving tabindex, focus moved on open, close or error), vendored code included. Its tests assert the keyboard path and the focus outcome.

- Library-supplied key and focus behavior gets no test.
- Native controls in DOM order get no keyboard or focus test, and a `required` attribute the browser renders from a literal prop gets no test. The wiring from a schema to `required` is the app's and is testable.

## Served HTML

**Served HTML.** Rendered HTML is a real-server check only when the HTML itself is the requirement. Example: a requirement that the served document carries a `<title>` and meta description, which crawlers read from the HTML before any script runs.

- A heading whose text is data the loader returns is a route test.
- A refusal or error a direct `loader` or `action` call returns is a route test, even when a page or error boundary renders it.
- A flow that must work without JavaScript checks its native form posts as a real-server check, with the body built from the served form, never as a page with JavaScript disabled.

## Test-design table

**Test-design table.** Every plan decides each test, its layer and its action in its test-design table, before any code is written. `.claude/skills/gaia/references/plan/test-table.md` owns the row fields.

**Actions.** Every row carries one:

- `new`: write a test no existing test holds.
- `reuse`: an existing test already asserts the case; leave it unchanged.
- `extend`: add the case to an existing test's case table.
- `change`: the plan changes the behavior an existing test asserts; change that test.
- `retire`: the new work supersedes an existing test; delete it.

**Table rules.**

- Read the existing tests that drive the routes, modules and components a plan touches before writing its rows; a case an existing test asserts is `reuse` or `extend`, never `new`.
- Approving the plan approves its retire rows. Retiring an existing test no approved row retires, or deleting a test outside the table, needs the maintainer; the default is keep.
- Executors write their own rows' tests, using the planned titles verbatim, and never edit the table.
- Only the security writer writes a security row's test.
- A test outside the table is unplanned drift.
- An audit fix that changes what a test must cover amends the rows it touches before that round's gate runs, and never drops a security row's requirement coverage without the maintainer.

## Honesty

**Hollow test.** A hollow test is an untested requirement. A test is hollow when it has:

- an assertion that cannot fail, including a guard test that never drives the guard into its failing state;
- an assertion through an import of the app's own string;
- a test of a test double instead of the app;
- an assertion inside a play function.

A skipped, todo, fixme or conditionally skipped test, or one with an empty body, is no test.

## Committed tests and generators

**Committed test.** Every committed test follows this file. The vendored playwright-cli test-generation guide does not apply to committed tests; it serves exploration and debugging only.
