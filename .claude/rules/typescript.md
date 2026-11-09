---
paths:
  - '**/*.{ts,tsx}'
---

# TypeScript

Lint enforces most TypeScript style, so this rule omits it. A member with no `lint` script gets none of that: add `@gaia-harness/lint`, an `eslint.config.mjs` built from its presets, and the `lint` script.

## Names

- Object and schema fields are camelCase, which lint does not check. Map snake_case at API boundaries, not in schemas or application code. Exceptions: generated database types, schemas of an existing snake_case on-disk format, dynamic template-literal names, environment variable names.
- Booleans match `^((can|has|hide|is|show)[A-Z]|checked|disabled|required)`.

## Values

- Exported functions have explicit return types.
- Inline boolean coercion is `!!x`, never `Boolean(x)`, which is for point-free use such as `array.filter(Boolean)`. Coerce per operand in a nullable `||` chain: `!!a || !!b`.
- `undefined` for absence you control; `null` only where an external contract requires it, such as Zod `.nullable()` or a library API.

## One Source of Truth

A set of values (statuses, roles, locales, route paths, config keys) or a shared helper has exactly one definition.

- Before writing a constant list, union type, schema, lookup map or helper, search the member's source and tests for one and import it. Search by its values: a duplicate usually has a different name.
- Derive every other shape from the source, so a new member of the set reaches all of them:

```ts
export const orderStatuses = ['cancelled', 'pending', 'shipped'] as const;
export type OrderStatus = (typeof orderStatuses)[number];
export const orderStatusSchema = z.literal(orderStatuses);
export const orderStatusLabels = {
  cancelled: 'Cancelled',
  pending: 'Pending',
  shipped: 'Shipped',
} satisfies Record<OrderStatus, string>;
```

- Key maps with `satisfies Record<Union, ...>`, so a new member of the set is a type error at every map missing it.
- Tests and mocks import the source rather than retyping its values.

## Zod

Before writing a schema or calling an existing Zod form wrong, read `wiki/dependencies/Zod.md`: most Zod 3 forms still compile, so memory misleads.
