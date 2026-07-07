---
title: Backend Integration
description: Use beryl alongside an existing backend that owns auth and persistence and publishes over an internal endpoint.
---

beryl does not have to own your application. A common setup keeps an existing
backend — a Phoenix, Rails, or another Gleam service — as the source of truth
for **authentication and persistence**, and uses beryl purely as the realtime
fan-out layer. The backend tells beryl *what* to push; beryl handles delivery to
connected sockets.

This guide wires up that split:

1. The existing backend authenticates users and issues a token.
2. beryl verifies that token at connect (see [Authentication](/guides/authentication)).
3. When domain data changes, the backend calls an **internal publish endpoint**
   on the beryl service, which forwards the change with `beryl.broadcast`.

```
Browser ──WebSocket──► beryl ◄──HTTP POST /internal/publish── Backend
                         │                                      │
                         └── broadcasts to topic subscribers     └── owns auth + DB
```

## The internal publish endpoint

Run the endpoint on the same Mist listener as the WebSocket transport. Guard it
with a shared secret so only your backend — never a browser — can publish:

```gleam
import beryl
import beryl/transport/mist as mist_transport
import gleam/bytes_tree
import gleam/dynamic/decode
import gleam/http.{Post}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/json
import gleam/result
import mist

fn handle_request(
  req: Request(mist.Connection),
  channels: beryl.Channels,
  ws_config,
) -> Response(mist.ResponseData) {
  // WebSocket upgrades go to beryl; everything else is normal HTTP routing.
  use <- mist_transport.upgrade(req, channels, ws_config)

  case request.path_segments(req), req.method {
    ["internal", "publish"], Post -> publish(req, channels)
    _, _ -> not_found()
  }
}
```

The handler decodes the backend's request into a typed event and forwards it:

```gleam
/// The contract your backend POSTs to /internal/publish.
type PublishRequest {
  PublishRequest(topic: String, order_id: String, status: String)
}

fn publish(
  req: Request(mist.Connection),
  channels: beryl.Channels,
) -> Response(mist.ResponseData) {
  // Only the trusted backend knows this secret.
  case authorized_internal(req) {
    False -> forbidden()
    True ->
      case read_publish_request(req) {
        Ok(msg) -> {
          // Fan out to every socket subscribed to the topic.
          beryl.broadcast(
            channels,
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

`authorized_internal` compares a shared secret from an internal-only header. Keep
the endpoint on a private network or behind your ingress so it is never exposed
to browsers:

```gleam
import gleam/crypto

fn authorized_internal(req: Request(mist.Connection)) -> Bool {
  case request.get_header(req, "x-internal-secret") {
    Ok(provided) ->
      // Constant-time comparison avoids leaking the secret via timing.
      crypto.secure_compare(
        <<provided:utf8>>,
        <<internal_secret():utf8>>,
      )
    Error(_) -> False
  }
}
```

## Response helpers

The backend only needs an acknowledgement — beryl returns `202 Accepted` once the
broadcast is queued:

```gleam
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

## Why this split works

- **One source of truth.** Your backend keeps owning auth and the database; beryl
  never persists domain state, it only relays it.
- **Push from anywhere.** Any backend process — an HTTP handler, a background job,
  a webhook consumer — can publish by POSTing to the internal endpoint.
- **Distributed fan-out for free.** If beryl runs as a cluster, use the
  [PubSub layer](/guides/pubsub) so a broadcast on one node reaches subscribers on
  every node.

For the connect-time verification of the tokens your backend issues, see the
[Authentication guide](/guides/authentication).
