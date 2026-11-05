import type {ReactRenderer} from '@storybook/react-vite';
import {DARK_MODE_EVENT_NAME} from '@vueless/storybook-dark-mode';
import isChromatic from 'chromatic/isChromatic';
import type {DecoratorFunction} from 'storybook/internal/types';
import {addons} from 'storybook/preview-api';
import ToastDecorator from '../decorators/toast-decorator';
import WrapDecorator from '../decorators/wrap-decorator';
import ChromaticDecorator from './decorator';

export const isChromaticSnapshot =
  isChromatic() ||
  (process.env.NODE_ENV === 'production' ?
    // eslint-disable-next-line @typescript-eslint/no-unnecessary-condition -- Firefox has no `location.ancestorOrigins`, whatever the DOM type says
    [...(window.location.ancestorOrigins ?? [])].some((origin) =>
      origin.includes('www.chromatic.com')
    )
  : false);

if (!isChromaticSnapshot) {
  const channel = addons.getChannel();
  channel.on(DARK_MODE_EVENT_NAME, (isDark: boolean) => {
    // eslint-disable-next-line unicorn/prevent-abbreviations -- `docs-story` is Storybook's class name
    const docsStory = document.querySelector('.docs-story');

    if (isDark) {
      document.documentElement.classList.add('dark');
      docsStory?.classList.add('bg-background', 'text-foreground');
    } else {
      document.documentElement.classList.remove('dark');
      docsStory?.classList.remove('bg-background', 'text-foreground');
    }
  });
}

// The theme decorator applies the `theme` global, which a Chromatic mode sets
// and the `storybook-dark` Vitest project pins to dark. Anywhere else the
// dark-mode addon owns the class, so the decorator stays out of its way.
const ThemeDecorator: DecoratorFunction<ReactRenderer> = (storyFn, context) =>
  isChromaticSnapshot || context.globals.theme === 'dark' ?
    ChromaticDecorator(storyFn, context)
  : storyFn();

export const decorators = [WrapDecorator, ThemeDecorator, ToastDecorator];
