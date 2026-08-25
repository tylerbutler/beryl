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

Browsers cannot set custom headers on a WebSocket handshake, so browser
clients usually send a token in a **query parameter**; server clients can use
the **`Authorization` header**. Support the methods your clients need.

```gleam
import beryl/socket
import gleam/http/request.{type Request}
import gleam/list
import gleam/result
import gleam/string
import mist

/// Prefer the Authorization: Bearer header, fall back to a ?token= query param.
fn extract_token(req: Request(mist.Connection)) -> Result(String, Nil) {
  case bearer_token(request.get_header(req, "authorization")) {
    Ok(token) -> Ok(token)
    Error(_) ->
      request.get_query(req)
      |> result.try(list.key_find(_, "token"))
  }
}

fn bearer_token(header: Result(String, Nil)) -> Result(String, Nil) {
  use header <- result.try(header)
  case string.split(header, " ") {
    ["Bearer", token] -> Ok(token)
    _ -> Error(Nil)
  }
}
```

The same shape applies to the `ConnectSeed` delivered to `init` — read
`seed.headers` and `seed.query` (both `List(#(String, String))`) with
`list.key_find` instead of `request.get_header`/`request.get_query`.

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
          Ok(claims) -> Ok(claims_metadata(claims))
          Error(_) -> Error(server.ConnectRejected)
        }
      Error(_) -> Error(server.ConnectRejected)
    }
  })

/// `ConnectSeed.metadata` holds string pairs, so a list of roles becomes
/// one comma-joined value.
fn claims_metadata(claims: Claims) -> List(#(String, String)) {
  [
    #("user_id", claims.user_id),
    #("username", claims.username),
    #("roles", string.join(claims.roles, ",")),
  ]
}
```

Return `Error(server.ConnectRejected)` to send HTTP 403 before the upgrade.
The app does not receive an unauthenticated connection.

`Ok(metadata)` accepts the connection and hands that list to the app. This is
how the verified identity crosses the handshake boundary. Verify the token in
`on_connect`, then use claims metadata downstream. `init` still receives the
original request headers and query through `ConnectInfo.seed`, so do not assume
the raw token was removed. Return `Ok([])` to accept a connection with no
metadata.

## 4. Decode claims into the model in `init`

`on_connect` accepts or rejects the connection. `init` builds the socket state.
The claims `on_connect` verified reach `init` as `ConnectInfo.seed.metadata`,
so rebuild the record from those pairs instead of checking the token again:

```gleam
pub type Model {
  Authenticated(claims: Claims)
  Anonymous
}

beryl.child_spec(
  config,
  init: fn(info: socket.ConnectInfo(Msg)) {
    #(model_from_metadata(info.seed.metadata), [])
  },
  update: update,
)

fn model_from_metadata(metadata: List(#(String, String))) -> Model {
  case list.key_find(metadata, "user_id"), list.key_find(metadata, "username") {
    Ok(user_id), Ok(username) ->
      Authenticated(Claims(
        user_id: user_id,
        username: username,
        roles: decode_roles(metadata),
      ))
    _, _ -> Anonymous
  }
}

fn decode_roles(metadata: List(#(String, String))) -> List(String) {
  case list.key_find(metadata, "roles") {
    Ok("") | Error(_) -> []
    Ok(roles) -> string.split(roles, ",")
  }
}
```

Signature and expiry checks stay in `on_connect`, where they run once per
socket. This `init` reads only verified metadata, so a wrong or expired token
cannot produce an authenticated model. The `Anonymous` branch covers a socket
that connected without `on_connect` configured; correct wiring makes it
unreachable, and it rejects every join.

The seed's `headers` and `query` remain available to `init`, for request data
that authentication does not produce — a locale, a client version, a room
preselected in the URL.

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
has no app-level `init`. Each handler receives the same `ConnectSeed` as
`channel.JoinContext.seed`, so read the verified identity from
`seed.metadata` with the same `model_from_metadata` shape. Apply topic
authorization and store the typed claims with `channel.accept`.

Put signature and expiry checks in `with_on_connect`. In each join callback,
only read the metadata and apply authorization rules.
See [JoinContext and the typed sender](/guides/channels/#joincontext-and-the-typed-sender).

## Notes

- **Verify once, trust everywhere.** Do the expensive signature/expiry check at
  connect time and return the result as `on_connect` metadata; the `Join` arms
  of `update` should only apply cheap authorization rules against the
  already-decoded claims in the model.
- **Cookie sessions need origin checks.** If you authenticate from a cookie
  instead of a token, always pair it with `with_allowed_origins` to prevent
  Cross-Site WebSocket Hijacking. See
  [Origin validation and CSWSH](/guides/websocket#origin-validation-and-cswsh).
- **Rejection shape.** For the client-visible error when a join or connection is
  refused, see [Error Handling](/guides/error-handling#connection-level-authentication-rejection).
