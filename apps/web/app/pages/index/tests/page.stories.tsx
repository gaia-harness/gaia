import {expect} from 'storybook/test';
import stubs from 'test/stubs';
import preview from '#.storybook/preview';
import {LANGUAGES} from '~/languages';
import common from '~/languages/en/common';
import type {RequestInfo} from '~/utils/request-info';
import IndexPage from '../page';

const meta = preview.meta({
  component: IndexPage,
  decorators: [
    stubs.reactRouter(({parameters}) =>
      parameters.storedTheme ?
        {
          id: 'root',
          loader: async () => ({
            requestInfo: {
              origin: '',
              path: '/',
              userPreferences: {theme: parameters.storedTheme},
            } satisfies RequestInfo,
          }),
        }
      : {}
    ),
  ],
  render: () => <IndexPage />,
  title: 'Pages/Index',
});

export const Default = meta.story({});

Default.test(
  'renders the site heading and the theme switch in its system default',
  async ({canvas}) => {
    const headings = await canvas.findAllByRole('heading', {level: 1});
    await expect(headings).toHaveLength(1);
    await expect(headings[0]).toHaveTextContent(common.meta.siteName);

    // The language select renders only once a second locale is configured, so
    // the expectation follows the configured language count.
    const languageSelect = canvas.queryByRole('combobox', {name: /language/i});
    // Annotated as number so lint does not read the literal length of an
    // `as const` LANGUAGES tuple and flag this branch as always one way.
    const languageCount: number = LANGUAGES.length;

    if (languageCount <= 1) {
      await expect(languageSelect).not.toBeInTheDocument();
    } else {
      await expect(languageSelect).toBeInTheDocument();
    }

    // ThemeSwitch's aria-label names the mode the button switches to. The router
    // stub registers no route the root loader data hangs off, so no stored
    // preference reaches the component and the mode is the "system" default.
    await expect(
      canvas.getByRole('button', {name: common.theme.enableLightMode})
    ).toBeInTheDocument();
  }
);

export const StoredDarkTheme = meta.story({
  parameters: {storedTheme: 'dark'},
});

StoredDarkTheme.test(
  'passes the stored theme preference to the theme switch',
  async ({canvas}) => {
    // A stored dark preference makes the switch offer the system theme next.
    await expect(
      await canvas.findByRole('button', {name: common.theme.useSystemTheme})
    ).toBeInTheDocument();
  }
);

export const Mobile = meta.story({
  parameters: {
    chromatic: {modes: {dark: {viewport: 375}, light: {viewport: 375}}},
  },
});
