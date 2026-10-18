# Frontend audit

## Data loading

- Loaders return typed data.
- Errors surface through the route error boundary.
- Flag any fetch call in a loader that has no timeout.

## Network

- Requests go through the shared client.

## Styling

- Use design tokens, never raw hex colors.
- No inline styles.
- Dark mode is checked in Storybook.
