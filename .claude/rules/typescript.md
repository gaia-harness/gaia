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

## Deriving from a value set

Declare the set once with `as const` and derive the type, schema and maps from it:

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

Key maps with `satisfies Record<Union, ...>`, so a new member of the set is a type error at every map missing it.

## Zod

Before writing a schema or calling an existing Zod form wrong, read `wiki/dependencies/Zod.md`: most Zod 3 forms still compile, so memory misleads.
