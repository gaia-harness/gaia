---
subagents: [react-patterns]
library: shadcn Form Fields
---

# Form Field Gate

A single form control sits in `ConformField`, which handles the wiring while the caller renders the ui control; a group stays composed from the ui `Field` parts with `ConformFieldError`. The pattern and a code example per control type are in `apps/web/.claude/skills/react-code/references/conform-forms.md`.

`components/ui/*.tsx` is vendored shadcn output and exempt from this gate; it is the building block, not a call site.

Flag, in every other `.tsx` file:

| Pattern                                                              | Use instead                                                                                   |
| -------------------------------------------------------------------- | --------------------------------------------------------------------------------------------- |
| native `<input>` (text types), `<textarea>`, `<select>`              | `Input`, `Textarea`, `NativeSelect` from `~/components/ui/...` inside a `ConformField`        |
| native `<input type="checkbox">` or `<input type="radio">`           | `Checkbox` or `RadioGroup` with `RadioGroupItem`; a group sits in a `FieldSet` with a `FieldLegend` |
| a ui control with no `FieldLabel htmlFor`, `Label htmlFor` or `aria-label` | `ConformField` for a Conform field; a `Label` or `aria-label` outside a form                  |
| a hand-wired `Field` around a single control bound to a Conform field | `ConformField`; a `Field` per option inside a group is fine                                   |
| a `ConformField` child that does not pass `controlOptions` to Conform's getter | pass them, or the description never reaches `aria-describedby`                                |
| a page-local error mapper, or a group's `FieldError` fed Conform's errors | `ConformFieldError`                                                                           |
| a `RadioGroup` bound to a Conform field without `aria-invalid`, `aria-describedby` and `required={field.required}` | set them as the reference shows; no Conform getter supplies them                             |
| a GAIA wrapper per control type (Input, Select, Checkbox), or one that renders the control itself | the ui control as `ConformField`'s child                                                      |
| a disabled link standing in for a disabled action                    | a disabled `ui/button`                                                                        |

Exceptions (native OK): `<input type="hidden">`, `<input type="file">`, `<input type="range">`.
