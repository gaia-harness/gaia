import {DARK_MODE_EVENT_NAME} from '@vueless/storybook-dark-mode';
import isChromatic from 'chromatic/isChromatic';
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

export const decorators =
  isChromaticSnapshot ?
    [WrapDecorator, ChromaticDecorator, ToastDecorator]
  : [WrapDecorator, ToastDecorator];
