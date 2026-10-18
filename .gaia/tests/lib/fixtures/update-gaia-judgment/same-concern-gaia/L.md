# Frontend audit

## Data loading

- Loaders return typed data.
- Errors surface through the route error boundary.

## Network

- Requests go through the shared client.
- Every network request (fetch, the shared client, a websocket) sets a timeout and handles its expiry.

## Styling

- Use design tokens, never raw hex colors.
- No inline styles.
