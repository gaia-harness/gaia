import {http, HttpResponse} from 'msw/http';
import {expect} from 'storybook/test';
import {url} from 'test/mocks/url';
import preview from '#.storybook/preview';
import {ITEMS_URLS} from '~/services/gaia/items';
import ItemNames from '..';

// Both stories read the same query key from different handlers. Run in this
// order, the second story fails if it inherits the first story's cache.
const meta = preview.meta({
  component: ItemNames,
  title: 'Fixtures/ItemNames/HandlerAFirst',
});

export const HandlerA = meta.story({
  beforeEach({msw}) {
    msw.use(
      http.get(url(ITEMS_URLS.items), () =>
        HttpResponse.json({data: [{display_name: 'Handler A item', id: 'a'}]})
      )
    );
  },
  play: async ({canvas}) => {
    await canvas.findByText('Handler A item');
  },
});

HandlerA.test('shows only its own handler data', async ({canvas}) => {
  await expect(await canvas.findByText('Handler A item')).toBeInTheDocument();
  await expect(canvas.queryByText('Handler B item')).not.toBeInTheDocument();
});

export const HandlerB = meta.story({
  beforeEach({msw}) {
    msw.use(
      http.get(url(ITEMS_URLS.items), () =>
        HttpResponse.json({data: [{display_name: 'Handler B item', id: 'b'}]})
      )
    );
  },
  play: async ({canvas}) => {
    await canvas.findByText('Handler B item');
  },
});

HandlerB.test('shows only its own handler data', async ({canvas}) => {
  await expect(await canvas.findByText('Handler B item')).toBeInTheDocument();
  await expect(canvas.queryByText('Handler A item')).not.toBeInTheDocument();
});
