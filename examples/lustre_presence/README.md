# Lustre presence

## Overview

This example shows how a Lustre page can reuse an authenticated browser
session when it connects to beryl.

The HTTP server has two demo users. A login route sets an HMAC-signed,
HTTP-only session cookie. The same-origin WebSocket handshake sends that
cookie automatically. The transport validates it once in `on_connect` and
stores the verified user fields in `ConnectSeed.metadata`. The dashboard
channel authorizes the join from that metadata; the client sends no second
token.

Run the example from this directory:

```sh
pnpm start
```

Then open <http://localhost:8002> and select a user.

The default transport origin policy rejects cross-origin browser WebSocket
handshakes. The session secret is generated at startup, so restarting the
example invalidates all demo sessions. A production HTTPS deployment must
also add the `Secure` cookie attribute.

## Subdirectories and boundaries

- [Server source](./src/README.md): startup, cookie authentication, and dashboard channel.
- [Client package](./client/README.md): Lustre model, Phoenix adapters, and presence decoding.
- [Bundler](./scripts/README.md): builds the browser asset from the compiled client.

## Interface

`src/lustre_presence.gleam:main` starts the Erlang server.
The nested `client/gleam.toml` owns the JavaScript-targeted
`lustre_presence_client` package. `package.json:scripts.start` builds the
client before starting the server.

## Invariants

- `src/lustre_presence.gleam:main` shares one startup secret between HTTP
  sessions and WebSocket authentication.
- `src/lustre_presence/auth.gleam:session_cookie` omits `Secure` in this
  local demo. `router.gleam:handle_request` lets you select a known demo user
  without credential verification.
- `src/lustre_presence/dashboard.gleam:channel` uses authenticated metadata;
  `client/src/lustre_presence_client.gleam:main` joins `page:dashboard`.

## Side effects

The server creates a secret, starts supervision, and listens on port 8002.
Login/logout responses change cookies; the browser starts Lustre and a
WebSocket. `scripts/bundle-client.mjs` writes the browser bundle.

## Verification

From the repository root: `cd examples/lustre_presence && gleam build`;
`pnpm -C examples/lustre_presence build:client` checks bundling.
`pnpm -C examples/lustre_presence test` runs Node tests followed by Gleam tests.
The root workspace test task excludes the nested client, not the server.
