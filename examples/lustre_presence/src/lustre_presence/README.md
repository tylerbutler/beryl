# Authenticated dashboard modules

## Overview

These modules supply demo-user session authentication, dashboard channel
authorization, and HTTP routing.

## Interface

- `auth.gleam:User`, `new_secret`, `find_user`, `session_cookie`,
  `authenticate_request`, `metadata`, and `from_metadata` form the local
  authentication boundary.
- `dashboard.gleam:channel` supplies the dashboard channel.
- `router.gleam:Context` and `handle_request` supply HTTP routing.

## Invariants

- `auth.gleam:new_secret` obtains 32 random bytes; `authenticate_request`
  verifies known demo-user IDs. `session_cookie` sets `Path=/`, `HttpOnly`,
  and `SameSite=Strict`, without `Secure`.
- `router.gleam:handle_request` allows login as a known demo identity without
  credential verification; this is a demonstration, not production login.
- `dashboard.gleam:channel` admits joins from metadata supplied by the
  authenticated transport.

## Side effects

- `auth.gleam:new_secret` obtains randomness; `session_cookie` and
  `authenticate_request` sign/verify session data.
- `router.gleam:handle_request` serves static/dashboard responses, sets or
  clears cookies for login/logout, and returns redirects.

## Verification

From the repository root: `cd examples/lustre_presence && gleam build`.
The example's `pnpm test` runs Node tests followed by `gleam test`.
