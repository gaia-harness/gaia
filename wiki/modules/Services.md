---
type: module
path: apps/web/app/services/
status: active
language: typescript
purpose: API client (Ky wrapper) and domain-specific service layers
depends_on:
  - '[[Ky]]'
  - '[[Zod]]'
created: 2026-04-20
updated: 2026-11-10
tags: [module, services, api]
---

# Services

`apps/web/app/services/` is where API calls and business logic live.

## `api/` vs the domain layer: the convention

- `apps/web/app/services/api/`: the [[Ky]] wrapper. A `create()` factory plus path/search-param interpolation, opt-in snake_case ↔ camelCase conversion, a per-request base URL, and per-request `token` / `language` request options. **Reusable across domains.**
- `apps/web/app/services/<layer>/`: the domain layer. The template ships it as `gaia/`, and `/gaia-init` renames it to the project slug. To name it after your company or 3rd-party API instead, ask Claude, which updates imports, barrels, and references across the app.

The pattern: each domain folder under `apps/web/app/services/<layer>/{domain}/` holds `parsers.ts`, `types.ts`, `requests.ts`, its own URL constants (`urls.ts`), and an `index.ts` barrel re-exporting parsers, types, and urls. Domains share the layer's `Ky` instance (`apps/web/app/services/<layer>/api.ts`) via `import {api, envelope} from '../api'`. `/new-service` scaffolds the full pattern into the domain layer.

Services are isomorphic: the same request functions run in a server loader, a `clientLoader`, and a TanStack Query function, so there is no `.server` barrel. React Router's build error for a `*.server*` import in the client module graph is the guard that keeps a service free of such imports. The data-loading rule is owned by `apps/web/.claude/skills/react-code/SKILL.md`; see [[Data Loading]].

## Why URL constants are mandatory

Each domain owns a per-domain URL constant in its own `urls.ts` (e.g. a `projects` domain exposes `PROJECTS_URLS`). That constant is the contract between the service layer and the MSW mocks ([[MSW Handlers]]): both the request functions and the handlers import the same per-domain constant, so a path change updates both sides together. Hardcoding paths breaks the contract and lets requests escape to the real network in tests.

## See also

- [[Ky]]: full Ky wrapper details
- [[API Service Pattern]]: service folder shape and conventions
- [[Data Loading]]: how routes consume services
- [[MSW Handlers]]: mock-side contract
