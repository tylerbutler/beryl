---
title: Backend Integration
description: Use Beryl alongside an existing backend that owns auth and persistence and publishes over an internal endpoint.
---

Beryl does not have to own your whole application. A common setup keeps an existing backend — Phoenix, Rails, or another Gleam service — as the source of truth for **authentication and persistence**, and uses Beryl purely as the realtime fan-out layer.

This guide wires up that split:

1. the existing backend authenticates users and issues a token,
2. Beryl verifies that token at connect time,
3. when domain data changes, the backend calls an internal publish endpoint,
4. that endpoint forwards the change with `beryl.broadcast`.

```text
Browser ──WebSocket──► beryl ◄──HTTP POST /internal/publish── Backend
                         │                                      │
                         └── broadcasts to topic subscribers     └── owns auth + DB
```

The `beryl.Sockets` handle in this guide can come from either layer — `beryl.start` or `beryl_channels.start` return the same handle type, and `beryl.broadcast` behaves identically for both.

## The internal publish endpoint

Run the endpoint on the same Mist listener as the WebSocket transport. Guard it with a shared secret so only your backend can publish.

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
  req: Request(mist.Connection),
  sockets: beryl.Sockets,
  ws_config: server.TransportConfig(mist.Connection),
) -> Response(mist.ResponseData) {
  use <- mist_transport.upgrade(req, sockets, ws_config)

  case request.path_segments(req), req.method {
    ["internal", "publish"], Post -> publish(req, sockets)
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
  req: Request(mist.Connection),
  sockets: beryl.Sockets,
) -> Response(mist.ResponseData) {
  case authorized_internal(req) {
    False -> forbidden()
    True ->
      case read_publish_request(req) {
        Ok(msg) -> {
          beryl.broadcast(
            sockets,
            msg.topic,
            "order_updated",
            json.object([
              #("order_id", json.string(msg.order_id)),
              #("status", json.string(msg.status)),
            ]),
          )
          accepted()
        }
        Error(_) -> bad_request()
      }
  }
}

fn read_publish_request(
  req: Request(mist.Connection),
) -> Result(PublishRequest, Nil) {
  use req <- result.try(
    mist.read_body(req, 1_000_000) |> result.replace_error(Nil),
  )
  let decoder = {
    use topic <- decode.field("topic", decode.string)
    use order_id <- decode.field("order_id", decode.string)
    use status <- decode.field("status", decode.string)
    decode.success(PublishRequest(topic:, order_id:, status:))
  }
  json.parse_bits(req.body, decoder) |> result.replace_error(Nil)
}
```

## Guarding the endpoint

```gleam
import gleam/crypto

fn authorized_internal(req: Request(mist.Connection)) -> Bool {
  case request.get_header(req, "x-internal-secret") {
    Ok(provided) ->
      crypto.secure_compare(
        <<provided:utf8>>,
        <<internal_secret():utf8>>,
      )
    Error(_) -> False
  }
}
```

Keep this endpoint on a private network or behind trusted ingress. Browsers should never be able to hit it directly.

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

## Socket-local integrations

`beryl.broadcast` is the right tool when the backend wants to fan out JSON payloads by topic.

If you instead need a long-lived domain actor to stream typed updates into one socket, pair the socket's `socket.Sender(msg)` with `beryl/bridge` and forward that actor's subject into `socket.Info(msg)`.

## Why this split works

- **One source of truth.** Your backend keeps owning auth and the database; Beryl relays updates to connected clients.
- **Push from anywhere.** Any trusted backend process can publish — an HTTP handler, a worker, or a webhook consumer.
- **Distributed fan-out.** When Beryl is configured with PubSub, one `beryl.broadcast` reaches subscribers across the cluster.

For connect-time verification of the tokens your backend issues, see [Authentication](/guides/authentication/).
