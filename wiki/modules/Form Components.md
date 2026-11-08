---
type: module
path: apps/web/app/components/form/
status: active
language: typescript
purpose: Conform + Zod-powered form components
depends_on:
  - '[[Conform]]'
  - '[[Zod]]'
created: 2026-04-20
updated: 2026-11-09
tags: [module, components, forms]
---

# Form Components

`ConformField` wires one [[Conform]] field to its label, description and errors, and the caller renders the ui control ([[shadcn Component Layer]]) as its child, spreading Conform's props. `ConformFieldError` renders a field's errors. Each control's accessible name, invalid state, required state and keyboard behavior come from the ui component plus Conform's attributes, and [[Zod]] supplies validation.

## The wrapper

`ConformField` takes the field's metadata, a label, an optional description and an orientation. Its child is a function that receives the options for Conform's prop getter and returns the control, which is how the description reaches `aria-describedby` without the wrapper knowing the control. It sets `data-invalid`, the label's `htmlFor`, the description's id and the control's `key`. Conform's list intents reach an uncontrolled control only through that key, and Conform's getters leave it out. Only the `remove` intent has a test; `insert` and `reorder` rest on reading Conform's source.

`ConformFieldError` translates each schema message found in `errors.validation` and shows any other message as written, so a missing translation key appears as its raw key and a translated server error passes through.

## Groups

Groups of checkboxes or radios stay composed: a `FieldSet` with a `FieldLegend`, a ui `Field` per option, and `ConformFieldError`. Checkboxes share one name through `getCollectionProps`.

The submit button is a `ui/button` that shows a `ui/spinner` and disables itself while the navigation is submitting.

The step-by-step pattern, the Zod schema and action wiring are in `apps/web/.claude/skills/react-code/references/conform-forms.md`. The runnable reference is `apps/web/app/components/form/tests/composed-form.tsx` and its story, whose `.test()` behaviors are the tests ([[Stories as Tests]]).

## Conform + custom components

> [!warning] useInputControl is mandatory for stateful custom components
> When using custom form components that manage their own internal state (e.g. a date picker), you **must** use `useInputControl` to keep them in sync with Conform's validation state. Local `useState` becomes disconnected from Conform once validation fails.

```tsx
const fieldControl = useInputControl(fields.fieldName);

<CustomComponent
  onBlur={fieldControl.blur}
  onChange={fieldControl.change}
  value={fieldControl.value ?? DEFAULT}
/>;
```

See [[Component Testing]] for how form components are tested.

## Validation

- Use `parseWithZod(formData, {schema})` in actions
- Schemas live next to the component or as part of the action
- Server-side validation is the source of truth; client validation just provides UX

## Accessibility

`ConformField` points the label's `htmlFor` at the Conform field id, and Conform's getter points `aria-describedby` at `errorId`. For custom inputs, ensure `<label htmlFor>` or `aria-label`. See [[Accessibility]].
