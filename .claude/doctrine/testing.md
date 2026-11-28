# Testing doctrine

Contents: Scope; What to test; Layers; Guards and security rows; Components, pages and stories; Served HTML; Production start; Committed tests and generators.

## Scope

This file owns which test to write and at which layer. Every test stage, executor, reviewer, evaluator, fixer and the tdd skills follow it, and every other source states only how to write a test at a layer, plus a pointer here. The reasons behind these rules live in `wiki/decisions/Test Layering.md`, `wiki/decisions/Testing Trophy Doctrine.md` and `wiki/decisions/Stories as Tests.md`.

How to write a test at a layer lives in the stack references:

- `apps/web/.claude/skills/tdd-react/references/tests-react.md`: unit, hook, story and route tests.
- `.claude/skills/tdd/references/tests-shell.md`: shell tests.
- `apps/web/.claude/rules/playwright.md`: real-server, browser and flow tests.
- `apps/web/.claude/rules/storybook.md`: stories.

## What to test

**Stated requirement.** A stated requirement is a SPEC flow, a success criterion, a scope boundary, an answered clarification, an audit directive, or a statement in a document the SPEC's Required reading names. A spec-less plan's stated requirement is its description; work with no plan states its requirement in its issue or request. A scope boundary or audit directive that directs the builder rather than stating what the app does (ask before adding a dependency, never add a database, rename an env var in every file that names it) names no behavior to test.

- Test stated requirements only.
- Never plan, list or write a test for a corner case or an error path no stated requirement names. A usage error (a bad flag, a missing argument) is such an error path unless a calling script depends on its exit code or message.
- Give a bug fix one test that reproduces the bug.
- Write at most one test per user-observable behavior; a case table is one test. This is a cap, not a quota: the tests the rules below require still apply.
- Assert every case a multi-case requirement lists. Split a compound condition into one case per part (`an open, unlocked account`: a closed account, a locked account). Split an order-of-checks requirement into one case per adjacent pair of checks, with an input that passes every earlier check, fails both checks of the pair, and asserts the earlier one refused.
- Give every transition, status or role rule exactly one case table holding every case, at the layer the layer rule picks. A test of that rule at another layer holds one case per outcome to prove the wiring, except an allowed outcome the closing flow test walks and asserts; a case another requirement states goes into the table as a case citing that requirement, never into a second wiring case of the same outcome. Each wiring case takes an input clear of every boundary and exception the table cases, unless only a boundary or exception case produces its outcome. A case belongs to the rule whose input it varies, whichever requirement states it and whatever effect it names (an alert shown, a button hidden). A rule stated as sets (the roles or relationships that take each action, the statuses each action leaves from) has one case per action and each role or relationship, inside its set or out, and one per action and each status, inside its from-statuses or out, so a status no action leaves (a final one) is a case for every action. Each role or relationship case takes a status inside the action's from-statuses, and each status case a role or relationship inside its set, so each case refuses or allows on its own dimension alone. Every role or relationship that takes an action runs at least one case at each status. A table holding one example per requirement that states the rule samples it. A case table names each case it holds by its values (each role or relationship and status, each input), never by class (`every role`) or by sample (`including an unknown tool`).
- Assert a role, accessible name, exact wording or attribute a stated requirement gives as that stated literal (`A New user link`: role link, name `New user`; `a Quantity field named qty`: an input named `qty`). One existing or planned test satisfies it at any layer, a flow test only for a role or accessible name; one story or route test may hold all of a page's stated literals, a loader-data heading's route test aside (`## Served HTML`); never add a flow for one. A stated literal a task doc names for its builder counts as asserted only once a test, or a flow task doc's list of the literals it asserts, names it.
- Never assert through an import of the app's own string: it proves only that the app agrees with itself.
- The closing flow test owns a happy path it walks and asserts, with no success-path route test of its own; an effect the flow cannot observe keeps its route test.
- Test several callers that map an upstream failure through one shared helper once, at the mapping, unless a caller maps differently. This never applies to a guard (`## Guards and security rows`).
- Test a stated mapping from a value the app reads (an API field, a stored or query value) to what the user sees (a stored `status: 2` shown as `Shipped`) with one case per value, at the layer the layer rule picks for the code that maps it: the route test of a loader or action that maps it, the unit test of a helper that meets the unit-test conditions, or, when a component maps it, itself or through a small helper it calls, one story per value given the raw value. A story given the mapped props never runs the mapping.
- Never test what the type checker or lint already proves.
- Never plan a test of a test double (a mock, fixture, Given builder or test-fixture wiring) once another app test, existing or planned in any phase, exercises that path. Judge by what the test can catch, not the code it calls: a test whose only catch beyond that app test is app code disagreeing with a double (that a client reaches its mock handlers, that the mocks share the app's base URL, what a seed holds) tests that double.
- Give a behavior only a real backend shows (data surviving a restart, a database reset, a production start against a real store) no test; name it as adopter-owned end-to-end work in the plan's follow-ups.

**Hollow test.** A hollow test is an untested requirement. A test is hollow when it has:

- an assertion that cannot fail, including a guard test that never drives the guard into its failing state;
- an assertion through an import of the app's own string;
- a test of a test double instead of the app;
- an assertion inside a play function.

A skipped, todo, fixme or conditionally skipped test, or one with an empty body, is no test.

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

**Flow test.** Write one flow test per critical flow, in the closing phase only, never in a build phase. It holds only the journey through the happy path, the happy path's effects that take several requests or sessions to stage, and, when the flow must work without JavaScript, a page-less check that posts the happy path's native forms (a separate real-server file holding them is also accepted). A stated no-JavaScript error path gets no native post: the action's route test and the page's story cover it. A web flow test is admitted on the browser layer whatever a cheaper layer could prove. It asserts no markup structure or ARIA attribute beyond a stated role or accessible name, repeats no refusal a build task's test or another flow owns, however many requests or sessions the refusal takes to stage, and asserts no stated literal or state a lower-layer test owns, even one the SPEC flow's own statement names: a flow that sees a placed order with its total lands on the order's page, and the total stays on its route and story tests. A happy-path step's own result that the user sees as a refusal (after sign-out the protected page redirects to sign-in) is a happy-path effect and stays. A flow whose only steps reach a page to see a stated literal or state a lower-layer test owns has no journey through the happy path.

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
- Never commit a mutant or red twin (a test that runs a guard or the suite's checker against a mutated copy only to prove it can go red): it is a test-of-test. Prove the suite can fail by mutating, then restoring or discarding the mutant; the committed test is the guard's real deny case.
<!-- gaia:maintainer-only:start -->
- In a bats suite, tag that deny case per `.claude/rules/bats-assertions.md`, ``## Mark a guard's real deny case with `# bats test_tags=protected` ``.
<!-- gaia:maintainer-only:end -->
- Name a guard's test in the task that delivers the guard, never leave it to the closing flow test. One test may cover several guards of one security kind.
- A flow test never stands in for a guard's lower-layer test, and a browser test or flow test never counts as the covering sibling of the only lower-layer test driving a guard.

**Anonymous write.** Prove that an authenticated write action refuses an anonymous request, with no side effect, by a route test calling the action with an anonymous `Request`.

**Protected read.** Prove that a loader returning protected data gives an anonymous request none of it, by a route test. A guard on a parent loader protecting a child's read also needs a real-server `.data` request naming only the child route, asserting the child's data is absent.

**Served check.** Give each guarded route module one real-server check, with redirects off, asserting only the served status and any `Location` header, never page content a route test shows. The parent-loader `.data` request is the one served check that asserts on the body.

**Shared guard.** Test a guard written once (middleware, a shared guard applied above the route) once at the guard, plus one served check. For middleware, the test at the guard is a route test that runs the real middleware chain, and without one the served check alone; never a test, at any layer, that hand-calls the middleware function; a new case for that guard extends the row that runs the real chain. Give a module its own refusal test only when its own code wires the guard, so removing that wiring leaves the module unguarded.

**Middleware guard.** A route test that runs the real middleware chain proves a middleware guard; a route test that hand-calls a context provider does not, and without the chain the guard needs a real-server check. An authorization outcome an upstream API owns is proven by no GAIA layer, since a mock handler answers as the test wrote it. The app's own response to an upstream refusal (no session created, the error shown) is still an access row; only the upstream's verdict itself is unprovable.

**Later-request rule.** Test a rule that takes effect on a later request (a role change, a deactivation, a sign-out ending a token) with a before-and-after read in one session, at the layer the layer rule picks for the rule.

**Forged value.** For a signed or encrypted value the app issues (a cookie, a session, a token), send a forged or edited one and assert the refusal. For a server-owned field the server must ignore (an owner or author), submit a forged value and assert the server ignored it. For a destination the server sends the user or a request to (a redirect target, a callback URL), send one outside its allowed destinations and assert it is refused or replaced with an allowed destination.

**Absence requirement.** For a value that must never be exposed, sent, stored or rendered, every task that adds a way for it to reach the forbidden surface tests its absence on that surface while the value is present upstream. Served HTML, a cookie or the session is a real-server check; returned data, an outgoing request or any other write is a route test.

A failing security test is fixed in the code, never weakened; the security kinds and the rest of the security rules live in the security section of `.claude/skills/gaia/references/test-stage.md`.

## Components, pages and stories

**Story.** Every component and page has a story, one story per visual state. A pure-utility component with no visual output (a context provider, a markup-less higher-order component) gets a Vitest test instead.

- Test a component's or page's behavior as a `.test()` on its story. A fresh render in a separate test file is for hooks only.
- A play function drives the UI into the state the snapshot shows and asserts nothing.
- A render-only story is complete only for a component with no interactive behavior.
- Every page story, an error page an error boundary renders included, carries the landmark check, one `.test()` asserting one level-1 heading and one `main` landmark; a row asserting a stated heading is that check only when it asserts the `main` landmark too. It is standing: its row cites the requirement that delivers the page, and no reviewer flags it as trivial.
- A vendored `ui` component gets render-only stories, plus a `.test()` only for behavior the app adds on top of it.

**Own key and focus code.** Code in the app's tree that handles keys or moves focus (a key handler, roving tabindex, focus moved on open, close or error), vendored code included. Its tests assert the keyboard path and the focus outcome.

- Library-supplied key and focus behavior gets no test.
- Native controls in DOM order get no keyboard or focus test, and a `required` attribute the browser renders from a literal prop gets no test. The wiring from a schema to `required` is the app's and is testable.

## Served HTML

**Served HTML.** Rendered HTML is a real-server check only when the HTML itself is the requirement. Example: a requirement that the served document carries a `<title>` and meta description, which crawlers read from the HTML before any script runs.

- A heading whose text is data the loader returns is a route test asserting the loader returns that text, beside the page story that renders it; a story given that text as a prop never shows the loader supplies it.
- A real-server row for a served error status (a 404 for an unknown path or a missing record) asserts only the status and any `Location`, like a `**Served check.**`; the heading and other page content served with it stay on its story or route test. Which route answers a path is shown by its route test and, for a guarded route, its served check (a signed-out request its guard redirects), never by a served heading.
- A refusal or error a direct `loader` or `action` call returns is a route test, even when a page or error boundary renders it.
- A flow that must work without JavaScript checks its happy path's native form posts page-less in its flow test, never an error post, with the body built from the served form, never as a page with JavaScript disabled. A native post that belongs to no flow is a real-server check.

## Production start

**Production start.** A test or check that starts the production server never reads the developer's `.env`: it sets `DOTENV_CONFIG_PATH=/dev/null` and passes every variable the start needs explicitly. The server entry loads `.env` through dotenv, which fills every variable the shell leaves unset, so `env -u NAME` hands `NAME` to `.env` rather than removing it, and a `.env` holding the dev values `.env.example` ships (a `SESSION_SECRET` production refuses) fails the start locally while CI, which has no `.env`, passes.

## Committed tests and generators

**Committed test.** Every committed test follows this file. The vendored playwright-cli test-generation guide does not apply to committed tests; it serves exploration and debugging only.
