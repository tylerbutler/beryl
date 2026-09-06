---
title: Connect beryl to an existing backend
description: Keep authentication and database writes in your backend, then send real-time updates through beryl.
---

beryl does not need to manage your full application. An existing Phoenix,
Rails, or Gleam backend can manage **authentication and database writes**.
beryl can send real-time updates to connected clients.

This guide uses this design:

1. The backend authenticates users and issues a token.
2. beryl verifies the token when the socket connects.
3. The backend calls an internal publish endpoint when application data changes.
4. The endpoint sends the change with `beryl.broadcast`.

```text
Browser ──WebSocket──► beryl ◄──HTTP POST /internal/publish── Backend
                         │                                      │
                         └── broadcasts to topic subscribers     └── owns auth + DB
```

Either API can provide the `beryl.Sockets` handle.
`beryl.child_spec` and `channel.child_spec` return the same handle type.
`beryl.broadcast` works the same with both APIs.

## Add a private publish endpoint

Run the endpoint on the Mist listener that serves the WebSocket transport.
Protect it with a shared secret. Only the backend must be able to publish.

```gleam
import beryl
import beryl/transport/server
import beryl_mist as mist_transport
import gleam/bytes_tree
import gleam/http.{Post}
import gleam/http/request
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import mist

fn handle_request(
  http_request: Request(mist.Connection),
  sockets: beryl.Sockets,
  websocket_config: server.TransportConfig(mist.Connection),
) -> Response(mist.ResponseData) {
  use <- mist_transport.upgrade(http_request, sockets, websocket_config)

  case request.path_segments(http_request), http_request.method {
    ["internal", "publish"], Post -> publish(http_request, sockets)
    _, _ -> not_found()
  }
}
```

The handler decodes the backend's request into a typed event and forwards it.

```gleam
import gleam/dynamic/decode
import gleam/http/response as response
import gleam/json
import gleam/result

pub type PublishRequest {
  PublishRequest(topic: String, order_id: String, status: String)
}

fn publish(
  http_request: Request(mist.Connection),
  sockets: beryl.Sockets,
) -> Response(mist.ResponseData) {
  case authorized_internal(http_request) {
    False -> forbidden()
    True ->
      case read_publish_request(http_request) {
        Ok(publish_request) -> {
          beryl.broadcast(
            sockets,
            publish_request.topic,
            "order_updated",
            json.object([
              #("order_id", json.string(publish_request.order_id)),
              #("status", json.string(publish_request.status)),
            ]),
          )
          accepted()
        }
        Error(_) -> bad_request()
      }
  }
}

fn read_publish_request(
  http_request: Request(mist.Connection),
) -> Result(PublishRequest, Nil) {
  use http_request <- result.try(
    mist.read_body(http_request, 1_000_000) |> result.replace_error(Nil),
  )
  let decoder = {
    use topic <- decode.field("topic", decode.string)
    use order_id <- decode.field("order_id", decode.string)
    use status <- decode.field("status", decode.string)
    decode.success(PublishRequest(topic:, order_id:, status:))
  }
  json.parse_bits(http_request.body, decoder) |> result.replace_error(Nil)
}
```

## Protect the endpoint

```gleam
import gleam/crypto

fn authorized_internal(http_request: Request(mist.Connection)) -> Bool {
  case request.get_header(http_request, "x-internal-secret") {
    Ok(provided) ->
      crypto.secure_compare(
        <<provided:utf8>>,
        <<internal_secret():utf8>>,
      )
    Error(_) -> False
  }
}
```

Keep this endpoint on a private network or behind a trusted proxy. Do not let
browsers access it.

## Response helpers

```gleam
import gleam/http/response
import gleam/http/response.{type Response}

fn accepted() -> Response(mist.ResponseData) {
  response.new(202) |> response.set_body(mist.Bytes(bytes_tree.new()))
}

fn bad_request() -> Response(mist.ResponseData) {
  response.new(400) |> response.set_body(mist.Bytes(bytes_tree.new()))
}

fn forbidden() -> Response(mist.ResponseData) {
  response.new(403) |> response.set_body(mist.Bytes(bytes_tree.new()))
}

fn not_found() -> Response(mist.ResponseData) {
  response.new(404) |> response.set_body(mist.Bytes(bytes_tree.new()))
}
```

## Send typed updates to one socket

Use `beryl.broadcast` when the backend sends JSON payloads by topic.

For typed updates from a long-lived application actor, use the socket's
`socket.Sender(message)` with `beryl/bridge`. The bridge forwards messages from
the actor to `socket.Info(message)`.

## Why publish from the backend

Your backend remains the source of truth for authentication and database
writes. Trusted HTTP handlers, workers, and webhook consumers can publish
updates. With PubSub, one `beryl.broadcast` reaches subscribers on every
connected node.

For connect-time verification of the tokens your backend issues, see [Authentication](/guides/authentication/).
