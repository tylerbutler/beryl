---
title: Authentication
description: Verify tokens in on_connect, store verified claims in your model, and authorize topics in update.
---

Beryl authenticates a connection **once** at the transport's `with_on_connect` hook, before any topic join. That hook can reject the whole WebSocket upgrade or return connect metadata that becomes part of `socket.ConnectInfo.seed.metadata`.

This guide shows a common flow:

1. model your claims as a typed record,
2. read a token from the handshake,
3. verify it in `with_on_connect`,
4. turn the returned metadata into typed model state in `init`,
5. authorize each topic by matching on `socket.Join` in `update`.

For transport mechanics and origin policy, see [WebSocket Transport](/guides/websocket/#authentication).

## 1. Model your claims

Keep authentication results in a typed record so the rest of your app never touches raw token strings.

```gleam
pub type Claims {
  Claims(user_id: String, username: String, roles: List(String))
}
```

## 2. Read the token from the handshake

Browsers usually send a token as a query parameter. Server-to-server clients often use an `Authorization` header.

```gleam
import gleam/http/request
import gleam/http/request.{type Request}
import gleam/list
import gleam/result
import gleam/string
import mist

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
  list.key_find(params, name)
}
```

## 3. Verify once in `with_on_connect`

`with_on_connect` returns `Result(List(#(String, String)), ConnectError)`.

- `Ok(metadata)` allows the WebSocket upgrade and appends `metadata` to `ConnectSeed.metadata`.
- `Error(server.ConnectRejected)` rejects the connection with HTTP 403 before any topic join.

```gleam
import beryl/transport/server
import beryl_mist as mist_transport
import gleam/string

// let verify_token: fn(String) -> Result(Claims, Nil)

let ws_config =
  server.default_config("/socket/websocket")
  |> server.with_allowed_origins(["https://app.example.com"])
  |> server.with_on_connect(fn(req) {
    case extract_token(req) {
      Ok(token) ->
        case verify_token(token) {
          Ok(claims) ->
            Ok([
              #("user_id", claims.user_id),
              #("username", claims.username),
              #("roles", string.join(claims.roles, ",")),
            ])
          Error(_) -> Error(server.ConnectRejected)
        }

      Error(_) -> Error(server.ConnectRejected)
    }
  })
```

This keeps the expensive signature and expiry check at connection time instead of repeating it for every topic join.

## 4. Build typed auth state in `init`

`init` receives `socket.ConnectInfo(msg)`, including the transport-provided metadata.

```gleam
import beryl/socket
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

pub type Msg {
  NoOp
}

pub type Model {
  Model(claims: Option(Claims))
}

fn init(info: socket.ConnectInfo(Msg)) -> #(Model, List(socket.Effect)) {
  let claims =
    case claims_from_metadata(info.seed.metadata) {
      Ok(claims) -> Some(claims)
      Error(_) -> None
    }
  #(Model(claims: claims), [])
}

fn claims_from_metadata(
  metadata: List(#(String, String)),
) -> Result(Claims, Nil) {
  use user_id <- result.try(list.key_find(metadata, "user_id"))
  use username <- result.try(list.key_find(metadata, "username"))
  use roles <- result.try(list.key_find(metadata, "roles"))
  Ok(Claims(user_id:, username:, roles: string.split(roles, ",")))
}
```

`ConnectSeed.metadata` is just ordered string pairs. `init` is where you turn those values into your own typed model.

## 5. Authorize each topic in `update`

Once the model carries verified claims, topic authorization is just application logic.

```gleam
import beryl/socket
import gleam/json
import gleam/list
import gleam/option.{Some}
import gleam/string

fn update(model: Model, ev: socket.Input(Msg)) -> socket.Next(Model, Msg) {
  case ev {
    socket.Join(topic_name, _payload, ref) ->
      case model.claims {
        Some(claims) ->
          case authorized_for_topic(claims, topic_name) {
            True -> socket.Next(model, [socket.AcceptJoin(ref, None)])
            False ->
              socket.Next(
                model,
                [
                  socket.RejectJoin(
                    ref,
                    json.object([
                      #("reason", json.string("forbidden")),
                    ]),
                  ),
                ],
              )
          }

        None ->
          socket.Next(
            model,
            [
              socket.RejectJoin(
                ref,
                json.object([
                  #("reason", json.string("unauthenticated")),
                ]),
              ),
            ],
          )
      }

    _ -> socket.Next(model, [])
  }
}

fn authorized_for_topic(claims: Claims, topic_name: String) -> Bool {
  case string.split(topic_name, ":") {
    ["room", owner, ..] -> owner == claims.user_id || has_role(claims, "admin")
    _ -> True
  }
}

fn has_role(claims: Claims, role: String) -> Bool {
  list.contains(claims.roles, role)
}
```

## Notes

- Verify signatures and expiry in `with_on_connect`; keep `update` focused on topic-specific authorization rules.
- Pair cookie-based authentication with origin validation to prevent Cross-Site WebSocket Hijacking.
- A refused connection becomes HTTP 403. A refused topic join becomes a `phx_reply` error payload. See [Error Handling](/guides/error-handling/#rejected-joins).
