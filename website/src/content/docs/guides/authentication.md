---
title: Authentication
description: Verify real tokens in on_connect, decode claims into your model in init, and authorize joins.
---

beryl authenticates a connection **once**, at the transport's `on_connect` hook,
before any topic join. This guide shows a realistic token flow: read a token
from the handshake, verify it into typed **claims**, carry those claims in the
socket's model, and then authorize individual topic joins in `update`.

For the mechanics of `with_on_connect` and rejection behavior, see the
[WebSocket Transport guide](/guides/websocket#authentication). This page focuses
on wiring *real* auth end to end.

## 1. Model your claims

Decode the token into a typed record so your app logic never touches raw token
strings:

```gleam
pub type Claims {
  Claims(user_id: String, username: String, roles: List(String))
}
```

The claims live in your per-socket model, so every `Join` and `Message` arm of
`update` can read them without re-authenticating.

## 2. Read the token from the handshake

Browsers cannot set custom headers on a WebSocket handshake, so the two common
transports for a token are a **query parameter** (browser clients) or the
**`Authorization` header** (server-to-server clients). Support whichever you
need. The same helpers work on the transport request in `on_connect` and on
the `ConnectSeed` in `init`:

```gleam
import beryl/event
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

/// The same extraction against the ConnectSeed delivered to `init`.
fn seed_token(seed: event.ConnectSeed) -> Result(String, Nil) {
  case seed_bearer(seed) {
    Ok(token) -> Ok(token)
    Error(_) ->
      list.find(seed.query, fn(pair) { pair.0 == "token" })
      |> result.map(fn(pair) { pair.1 })
  }
}

fn seed_bearer(seed: event.ConnectSeed) -> Result(String, Nil) {
  use header <- result.try(list.key_find(seed.headers, "authorization"))
  case string.split(header, " ") {
    ["Bearer", token] -> Ok(token)
    _ -> Error(Nil)
  }
}
```

## 3. Verify the token in `on_connect`

`verify_token` is where you plug in your token library — for example a call to
[`gleam_crypto`](https://hexdocs.pm/gleam_crypto/) to check an HMAC signature, or
a JWT library to validate a signed token issued by your identity provider. It
must validate the signature and expiry and return typed `Claims`. (The upstream
sign-in flow that mints these tokens is a separate concern — an OAuth2 library
such as [`vestibule`](https://vestibule.tylerbutler.com) handles social login
and hands you an authenticated identity to build the token from.)

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
          Ok(_claims) -> Ok(Nil)
          Error(_) -> Error(mist_transport.ConnectRejected)
        }
      Error(_) -> Error(mist_transport.ConnectRejected)
    }
  })
```

Returning `Error(mist_transport.ConnectRejected)` sends HTTP 403 before the
upgrade, so an unauthenticated client never reaches your app.

## 4. Decode claims into the model in `init`

`on_connect` gates the connection; `init` builds the socket's state. The same
request data arrives in `init` as `ConnectInfo.seed`, so decode the (already
gate-checked) token into claims there and carry them in the model:

```gleam
pub type Model {
  Authenticated(claims: Claims)
  Anonymous
}

beryl.child_spec(
  config,
  init: fn(info: event.ConnectInfo(Msg)) {
    let model = case seed_token(info.seed) {
      Ok(token) ->
        case verify_token(token) {
          Ok(claims) -> Authenticated(claims)
          Error(_) -> Anonymous
        }
      Error(_) -> Anonymous
    }
    #(model, [])
  },
  update: update,
)
```

`verify_token` is a pure check, so running it in both places is cheap; the
`Anonymous` arm exists only for defense in depth (it is unreachable when
`on_connect` gates correctly, and every join under it rejects).

## 5. Authorize the topic at join

Because the claims are already in the model, `update` authenticates for free
and only needs to decide **authorization** — is this user allowed on *this*
topic?

```gleam
fn update(model: Model, ev: event.Input(Msg)) -> event.Next(Model, Msg) {
  case ev {
    event.Join(topic, _payload, ref) ->
      case model {
        Authenticated(claims) ->
          case authorized_for_topic(claims, topic) {
            True -> event.Next(model, [event.AcceptJoin(ref, option.None)])
            False -> event.Next(model, [event.RejectJoin(ref, forbidden())])
          }
        Anonymous -> event.Next(model, [event.RejectJoin(ref, forbidden())])
      }
    // ...
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

fn forbidden() -> json.Json {
  json.object([#("reason", json.string("forbidden"))])
}
```

## Notes

- **Verify once, trust everywhere.** Do the expensive signature/expiry check at
  connect time; the `Join` arms of `update` should only apply cheap
  authorization rules against the already-decoded claims in the model.
- **Cookie sessions need origin checks.** If you authenticate from a cookie
  instead of a token, always pair it with `with_allowed_origins` to prevent
  Cross-Site WebSocket Hijacking. See
  [Origin validation and CSWSH](/guides/websocket#origin-validation-and-cswsh).
- **Rejection shape.** For the client-visible error when a join or connection is
  refused, see [Error Handling](/guides/error-handling#connection-level-authentication-rejection).
