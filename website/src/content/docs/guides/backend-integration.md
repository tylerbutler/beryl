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

Run the endpoint on the Ewe listener that serves the WebSocket transport.
Protect it with a shared secret. Only the backend must be able to publish.

```gleam
import beryl
import beryl/transport/server
import beryl_ewe
import ewe
import gleam/http.{Post}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}

fn handler(
  sockets: beryl.Sockets,
  websocket_config: server.TransportConfig(ewe.Connection),
) -> fn(Request(ewe.Connection)) -> Response(ewe.Body) {
  use http_request <- beryl_ewe.handler(sockets, websocket_config)
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
  http_request: Request(ewe.Connection),
  sockets: beryl.Sockets,
) -> Response(ewe.Body) {
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
  http_request: Request(ewe.Connection),
) -> Result(PublishRequest, Nil) {
  use http_request <- result.try(
    ewe.read_body(http_request, limit: 1_000_000) |> result.replace_error(Nil),
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

fn authorized_internal(http_request: Request(body)) -> Bool {
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
import gleam/http/response.{type Response}

fn accepted() -> Response(ewe.Body) {
  response.new(202) |> response.set_body(ewe.Empty)
}

fn bad_request() -> Response(ewe.Body) {
  response.new(400) |> response.set_body(ewe.Empty)
}

fn forbidden() -> Response(ewe.Body) {
  response.new(403) |> response.set_body(ewe.Empty)
}

fn not_found() -> Response(ewe.Body) {
  response.new(404) |> response.set_body(ewe.Empty)
}
```

## Send typed updates to one socket

Use `beryl.broadcast` when the backend sends JSON payloads by topic.

For typed updates from a long-lived application actor, pass
`socket.ConnectInfo.self` to the producer and call
`socket.notify(sender, message)`. The socket's `update` callback receives
`socket.Info(message)`. With channel handlers, pass `channel.JoinContext.self`
and call `channel.notify(sender, message)` to deliver to that join's `on_info`
callback.

Both functions return an admission `Result`. `Ok(Nil)` means queued, not
handled. The producer must handle rejection when the target is closed,
unavailable, or full, or when the message is too large. A channel sender
belongs to one join and cannot deliver to a later join of the same topic.

### Migrating from `beryl/bridge`

`beryl/bridge` was removed before 1.0, including `Bridge`, `StartError`,
`start`, `subject`, `pid`, and `stop`. beryl no longer starts a forwarding
process for an external actor's subscription.

Direct notification works when the producer accepts a typed sender or a
callback that can map its event to your application message and return the
notification result. Neither `socket.Sender` nor `channel.Sender` is a
`Subject`; you cannot pass one to an interface that accepts only
`Subject(event)`.

For a Subject-only producer, change its subscription interface if you control
it, or keep the adaptation in your application. Any application-owned
forwarder must handle message conversion, admission errors, unsubscription,
and cleanup when the socket or join ends. Direct notification does not supply
that lifecycle policy.

## Why publish from the backend

Your backend remains the source of truth for authentication and database
writes. Trusted HTTP handlers, workers, and webhook consumers can publish
updates. With PubSub, one `beryl.broadcast` reaches subscribers on every
connected node.

For connect-time verification of the tokens your backend issues, see [Authentication](/guides/authentication/).
