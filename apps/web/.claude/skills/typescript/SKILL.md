---
name: typescript
description: Applies GAIA's patterns and conventions for all TypeScript code. Use this skill whenever writing or reviewing TypeScript, typing exports, choosing between type and interface, using Zod schemas, defining a constant list, union type, or lookup map that other code shares, structuring function parameters, or enforcing code patterns like avoiding switch statements and enums.
---

# TypeScript

## Types

- `import type {}` for type-only imports: `import type {ReactNode} from 'react'`

## Naming, camelCase

All identifiers use camelCase: Zod fields, form `name`/`id`/`htmlFor`, props, state, params.

**Exceptions (snake_case OK):**

- `types/database.ts`, mirrors DB column names
- Dynamic template literal names where variable part is already lowercase
- Environment variable names (`SUPABASE_URL`)

Map snake_case ↔ camelCase at API call boundaries, not in schemas or UI code.

## Naming, Descriptive and Self-Documenting

Owned by the naming-conventions skill (`.claude/skills/naming-conventions/SKILL.md`).

## Exported Functions, Explicit Return Types

All exported functions must have explicit return types.

**Exceptions:**

- Route loaders/actions (complex generics)
- React components (props typed inline on the destructured parameter, return type inferred)

```tsx
// BAD
export const formatDate = (date: Date) => format(date, 'yyyy-MM-dd');

// GOOD
export const formatDate = (date: Date): string => format(date, 'yyyy-MM-dd');
```

## General Rules

- Use `type` not `interface`
- Arrays: `string[]` not `Array<string>`
- Boolean naming: `^((can|has|hide|is|show)[A-Z]|checked|disabled|required)`

## Code Patterns

- No `switch` statements, use if/else chains or object maps
- No TypeScript enums, use `as const` objects with derived types
- JSX boolean props: always explicit `={true}`
- Max 3 function parameters, use an options object beyond that
- Inline boolean coercion uses `!!x`, never `Boolean(x)`; reserve `Boolean` for point-free use (e.g. `array.filter(Boolean)`), and coerce per operand in a nullable `||` chain (`!!a || !!b`), since `!!(a || b)` trips `@typescript-eslint/prefer-nullish-coalescing`
- Prefer `undefined` over `null` for GAIA-controlled absence (state, optional fields, internal sentinels); reserve `null` for external contracts that require it: DOM `useRef(null)`, ref-callback params, React Router `data(null)`, Zod `.nullable()`, and platform/library APIs that return `null`

## One Source of Truth

A set of values (statuses, roles, locales, route paths, config keys) or a shared helper has exactly one definition.

- **Search before you define.** Before writing a constant list, union type, schema, lookup map, or helper, search `app/` and `test/` for an existing one and import it. Search by its values, not only its name: a duplicate usually has a different name.
- **Derive, don't restate.** Every other shape of the set is computed from the one source, so adding a member reaches all of them:

```ts
// the one source
export const orderStatuses = ['cancelled', 'pending', 'shipped'] as const;

// derived, never retyped
export type OrderStatus = (typeof orderStatuses)[number];
export const orderStatusSchema = z.literal(orderStatuses);
export const orderStatusLabels = {
  cancelled: 'Cancelled',
  pending: 'Pending',
  shipped: 'Shipped',
} satisfies Record<OrderStatus, string>;
```

- **Key maps by the union with `satisfies Record<Union, ...>`**, so a new member is a type error at every map that does not handle it. `Record<string, ...>` or `Partial<...>` accepts the gap silently.
- Tests, stories, and MSW mocks import the source rather than retyping its values.

## Zod

**This project uses Zod 4**, in every schema. Most Zod 3 forms still compile; several fail typecheck, among them single-arg `z.record()`, `.args().returns()`, `.deepPartial()`, `z.string().ip()`, and the `required_error` / `invalid_type_error` / `errorMap` params. `.strict()` compiles and lints clean, so reach for `z.strictObject()` deliberately. The deprecated forms (`.passthrough()`, `z.string().email()` and the other string formats, the `message` param) also compile, but `sonarjs/deprecation` flags them.

- **`z.literal([...])` not `z.enum()`** for string unions, sort values alphanumerically

Read `references/zod.md` for the Zod 3 → Zod 4 migration map and how to verify an uncertain Zod form against the official docs rather than v3-era memory.
