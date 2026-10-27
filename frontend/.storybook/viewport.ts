/* eslint-disable perfectionist/sort-objects -- viewports read largest to smallest, not alphabetically */
import type {ViewportMap} from 'storybook/viewport';

const viewport = {
  options: {
    landscape: {
      name: 'Landscape',
      styles: {
        height: '768px',
        width: '1024px',
      },
      type: 'tablet',
    },
    portrait: {
      name: 'Portrait',
      styles: {
        height: '1024px',
        width: '768px',
      },
      type: 'tablet',
    },
    mobileLarge: {
      name: 'Large mobile',
      styles: {
        height: '846px',
        width: '390px',
      },
      type: 'mobile',
    },
    mobileSmall: {
      name: 'Small mobile',
      styles: {
        height: '812px',
        width: '375px',
      },
      type: 'mobile',
    },
  },
} satisfies {options: ViewportMap};

export default viewport;
