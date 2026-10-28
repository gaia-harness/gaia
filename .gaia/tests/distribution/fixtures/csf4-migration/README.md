# csf4-migration fixtures

Used by `.gaia/tests/distribution/16-csf4-migration.sh`, which copies them into a staged release tree to prove `gaia migrate-csf4` with the adopter's own toolchain.

- `config/`: CSF3 Storybook config an adopter would hold (`preview.csf3.ts`, `preview-no-i18n.csf3.ts`, `main.csf3.ts`). The scenario copies them over `.storybook/preview.ts` and `.storybook/main.ts`.
- `adopter/`: components and CSF3 stories covering the shapes the upstream codemod breaks: assignments on a render-function story, custom args beyond the component's props, a factory-built story set under a leading comment, and a `parameters.msw` story whose component renders the handler's distinctive text.
- `csf2/`: a `Template.bind({})` story and a `storiesOf` story, which the command refuses.
- `load-failure/`: a story that imports a module throwing at import time, so its file converts and typechecks but never loads.
- `failing-test/`, `type-error/`: CSF4 projects with one failing `.test()` and one story type error.

Every old-format story is stored as `*.stories.tsx.csf3` or `*.stories.tsx.csf2` so no old-format `*.stories.tsx` file exists in this tree; the scenario drops the suffix when it copies a file into a staged tree.
