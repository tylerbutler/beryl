---
title: Authentication
description: Verify real tokens in on_connect, decode claims into your model in init, and authorize joins.
---

beryl authenticates a connection once in the transport `on_connect` hook. This
happens before any topic join. This guide reads a token from the handshake and
verifies it into typed **claims**. It stores the claims in the socket model.
Then `update` uses them to authorize topic joins.

For the mechanics of `with_on_connect` and rejection behavior, see the
[WebSocket Transport guide](/guides/websocket#authentication). This page focuses
on wiring *real* auth end to end.

## 1. Model your claims

Decode the token into a typed record. Do not use raw token strings in app
logic:

```gleam
pub type Claims {
  Claims(user_id: String, username: String, roles: List(String))
}
```

Store the claims in the per-socket model. Each `Join` and `Message` branch can
then read them without another authentication check.

## 2. Read the token from the handshake

Browsers cannot set custom headers on a WebSocket handshake. Browser clients
usually send a token in a **query parameter**. Server clients can use the
**`Authorization` header**. Support the methods that your clients need. The
same helpers work with the transport request in `on_connect` and the
`ConnectSeed` in `init`:

```gleam
import beryl/socket
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
fn seed_token(seed: socket.ConnectSeed) -> Result(String, Nil) {
  case seed_bearer(seed) {
    Ok(token) -> Ok(token)
    Error(_) ->
      list.find(seed.query, fn(pair) { pair.0 == "token" })
      |> result.map(fn(pair) { pair.1 })
  }
}

fn seed_bearer(seed: socket.ConnectSeed) -> Result(String, Nil) {
  use header <- result.try(list.key_find(seed.headers, "authorization"))
  case string.split(header, " ") {
    ["Bearer", token] -> Ok(token)
    _ -> Error(Nil)
  }
}
```

## 3. Verify the token in `on_connect`

Implement `verify_token` with your token library. For example, use
[`gleam_crypto`](https://hexdocs.pm/gleam_crypto/) to check an HMAC signature.
You can also use a JWT library for signed identity-provider tokens. The
function must validate the signature and expiry and return typed `Claims`.
Token creation is a separate process. An OAuth2 library such as
[`vestibule`](https://vestibule.tylerbutler.com) can provide an authenticated
identity for token creation.

```gleam
import beryl_mist as mist_transport
import beryl/transport/server

// let verify_token: fn(String) -> Result(Claims, Nil)

let ws_config =
  server.default_config("/socket/websocket")
  // Reject cross-site handshakes when auth relies on ambient credentials.
  |> server.with_allowed_origins(["https://app.example.com"])
  |> server.with_on_connect(fn(req) {
    case extract_token(req) {
      Ok(token) ->
        case verify_token(token) {
          Ok(_claims) -> Ok(Nil)
          Error(_) -> Error(server.ConnectRejected)
        }
      Error(_) -> Error(server.ConnectRejected)
    }
  })
```

Return `Error(server.ConnectRejected)` to send HTTP 403 before the upgrade.
The app does not receive an unauthenticated connection.

## 4. Decode claims into the model in `init`

`on_connect` accepts or rejects the connection. `init` builds the socket state.
The same request data reaches `init` as `ConnectInfo.seed`. Decode the verified
token into claims and store them in the model:

```gleam
pub type Model {
  Authenticated(claims: Claims)
  Anonymous
}

beryl.child_spec(
  config,
  init: fn(info: socket.ConnectInfo(Msg)) {
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

`verify_token` is a pure check, so this example calls it in both places. The
`Anonymous` branch provides a second check. Correct `on_connect` logic makes
that branch unreachable, and it rejects all joins.

## 5. Authorize the topic at join

The model already contains the claims. `update` only decides whether the user
can join the topic:

```gleam
fn update(model: Model, ev: socket.Input(Msg)) -> socket.Next(Model) {
  case ev {
    socket.Join(topic, _payload, ref) ->
      case model {
        Authenticated(claims) ->
          case authorized_for_topic(claims, topic) {
            True -> socket.Next(model, [socket.AcceptJoin(ref, option.None)])
            False -> socket.Next(model, [socket.RejectJoin(ref, forbidden())])
          }
        Anonymous -> socket.Next(model, [socket.RejectJoin(ref, forbidden())])
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

## With the channel layer

Transport authentication is the same for the channel layer.
`with_on_connect` validates the handshake before the upgrade. A channel system
has no app-level `init`. Each handler receives the request `ConnectSeed` as
`channel.JoinContext.seed`. Decode the verified identity from `seed.query` or
`seed.headers`. Apply topic authorization and store the typed claims with
`channel.accept`.

Put signature and expiry checks in `with_on_connect`. In each join callback,
only decode request data and apply authorization rules.
See [JoinContext and the typed sender](/guides/channels/#joincontext-and-the-typed-sender).

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
