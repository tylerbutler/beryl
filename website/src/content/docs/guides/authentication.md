---
title: Authentication
description: Verify real tokens in on_connect, decode claims into assigns, and authorize joins.
---

beryl authenticates a connection **once**, at the transport's `on_connect` hook,
before any channel join. This guide shows a realistic token flow: read a token
from the handshake, verify it into typed **claims**, seed those claims as the
socket's initial assigns, and then authorize individual topic joins.

For the mechanics of `with_on_connect` and rejection behavior, see the
[WebSocket Transport guide](/guides/websocket#authentication). This page focuses
on wiring *real* auth end to end.

## 1. Model your claims

Decode the token into a typed record so channels never touch raw token strings:

```gleam
pub type Claims {
  Claims(user_id: String, username: String, roles: List(String))
}
```

`Claims` becomes the socket's `assigns` type, so give your channels the same
`assigns` type parameter (commonly a record shared across every authenticated
topic).

## 2. Read the token from the handshake

Browsers cannot set custom headers on a WebSocket handshake, so the two common
transports for a token are a **query parameter** (browser clients) or the
**`Authorization` header** (server-to-server clients). Support whichever you
need:

```gleam
import gleam/http/request.{type Request}
import gleam/list
import gleam/result
import gleam/string
import mist

/// Prefer the Authorization: Bearer header, fall back to a ?token= query param.
fn extract_token(req: Request(mist.Connection)) -> Result(String, Nil) {
  case bearer_header(req) {
    Ok(token) -> Ok(token)
    Error(_) -> query_param(req, "token")
  }
}

fn bearer_header(req: Request(mist.Connection)) -> Result(String, Nil) {
  use header <- result.try(request.get_header(req, "authorization"))
  case string.split(header, " ") {
    ["Bearer", token] -> Ok(token)
    _ -> Error(Nil)
  }
}

fn query_param(req: Request(mist.Connection), name: String) -> Result(String, Nil) {
  use params <- result.try(request.get_query(req))
  list.find(params, fn(pair) { pair.0 == name })
  |> result.map(fn(pair) { pair.1 })
}
```

## 3. Verify the token in `on_connect`

`verify_token` is where you plug in your token library — for example a JWT
verifier such as [`vestibule`](https://hex.pm/) or a call to
[`gleam_crypto`](https://hexdocs.pm/gleam_crypto/) to check an HMAC signature.
It must validate the signature and expiry and return typed `Claims`:

```gleam
import beryl_mist as mist_transport

// let verify_token: fn(String) -> Result(Claims, Nil)

let ws_config =
  mist_transport.default_config("/socket/websocket")
  // Reject cross-site handshakes when auth relies on ambient credentials.
  |> mist_transport.with_allowed_origins(["https://app.example.com"])
  |> mist_transport.with_on_connect(fn(req) {
    case extract_token(req) {
      Ok(token) ->
        case verify_token(token) {
          // Seed the verified claims as the socket's initial assigns.
          Ok(claims) -> Ok(claims)
          Error(_) -> Error(mist_transport.ConnectRejected)
        }
      Error(_) -> Error(mist_transport.ConnectRejected)
    }
  })
```

Returning `Error(mist_transport.ConnectRejected)` sends HTTP 403 before the
upgrade, so an unauthenticated client never reaches a channel.

## 4. Read claims at join and authorize the topic

Because the claims are already in the socket's assigns, channels authenticate
for free and only need to decide **authorization** — is this user allowed on
*this* topic?

```gleam
import beryl/channel
import beryl/socket.{type Socket}
import gleam/option.{None}

fn join(topic: String, _payload, socket: Socket(Claims)) {
  let claims = socket.get_assigns(socket)
  case authorized_for_topic(claims, topic) {
    True -> channel.JoinOk(reply: None, socket:)
    False -> channel.JoinError(reason: channel.error("forbidden"))
  }
}

/// Example policy: "room:<user_id>:*" is private to that user.
fn authorized_for_topic(claims: Claims, topic: String) -> Bool {
  case string.split(topic, ":") {
    ["room", owner, ..] -> owner == claims.user_id || has_role(claims, "admin")
    _ -> True
  }
}

fn has_role(claims: Claims, role: String) -> Bool {
  list.contains(claims.roles, role)
}
```

## Notes

- **Verify once, trust everywhere.** Do the expensive signature/expiry check in
  `on_connect`; channel `join` should only apply cheap authorization rules
  against the already-verified claims.
- **Cookie sessions need origin checks.** If you authenticate from a cookie
  instead of a token, always pair it with `with_allowed_origins` to prevent
  Cross-Site WebSocket Hijacking. See
  [Origin validation and CSWSH](/guides/websocket#origin-validation-and-cswsh).
- **Rejection shape.** For the client-visible error when a join or connection is
  refused, see [Error Handling](/guides/error-handling#connection-level-authentication-rejection).
