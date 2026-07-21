---
title: Error Handling
---

This guide covers how beryl surfaces errors to your channel code and to connected clients, and how to handle them defensively.

## Rejected joins

Return `JoinError` from your join callback to reject a client. The error payload is sent back as a `phx_reply` with `status: "error"`:

```gleam
fn join(topic, payload, socket) -> JoinResult(MyAssigns) {
  case authenticate(payload) {
    Error(_) ->
      channel.JoinError(
        json.object([#("reason", json.string("unauthorized"))]),
      )
    Ok(user) -> {
      let assigns = MyAssigns(user_id: user.id)
      channel.JoinOk(reply: None, socket: socket.set_assigns(socket, assigns))
    }
  }
}
```

The client sees:
```json
["1", "1", "room:lobby", "phx_reply", {"status": "error", "response": {"reason": "unauthorized"}}]
```

The coordinator discards the socket's join record on rejection — the client remains connected but is not subscribed to the topic.

## Connection-level authentication rejection

`on_connect` in the transport config rejects the WebSocket upgrade before any topic join occurs. Return `Error(mist_transport.ConnectRejected)` to send an HTTP 403 response:

```gleam
let config =
  mist_transport.default_config("/socket/websocket")
  |> mist_transport.with_on_connect(fn(req) {
    case extract_token(req) {
      Ok(_) -> Ok(Nil)
      Error(_) -> Error(mist_transport.ConnectRejected)  // → HTTP 403, connection refused
    }
  })
```

The client never receives a WebSocket handshake and cannot send any messages.

## Malformed wire messages

beryl parses incoming frames as Phoenix protocol arrays `[join_ref, ref, topic, event, payload]`. Frames that cannot be decoded are dropped silently — no error is sent to the client. This is intentional: malformed frames are treated as protocol violations and do not warrant a reply.

If you need to surface decode errors in your own payload handling, decode the
`Dynamic` payload with `channel.decode_payload` and return an explicit `Reply`
or `Push` from `handle_in`:

```gleam
fn handle_in(event, payload, socket) -> HandleResult(MyAssigns) {
  case event {
    "create_item" -> {
      case channel.decode_payload(payload, item_decoder()) {
        Ok(item) -> {
          // process item
          channel.Reply("ok", json.object([#("id", json.string(item.id))]), socket)
        }
        Error(_) ->
          channel.Reply(
            "error",
            json.object([#("reason", json.string("invalid_payload"))]),
            socket,
          )
      }
    }
    _ -> channel.NoReply(socket)
  }
}
```

:::note[Reply event name is ignored]
When returning `Reply` from `handle_in`, the `event` string is not used. The coordinator always encodes the response as `phx_reply` tied to the original client ref. Use `Push` when you want to control the event name.
:::

## Unmatched topics

If a client sends `phx_join` for a topic that does not match any registered pattern, the coordinator replies with a `phx_reply` carrying `status: "error"` and `response: {"reason": "no_channel_handler"}`. The join is rejected and the client remains connected but unsubscribed. Register handlers for all patterns you expect clients to join.

## Heartbeat timeouts

When a client goes silent beyond `heartbeat_timeout_ms`, the coordinator evicts the socket. All joined channels receive `terminate` with `HeartbeatTimeout`:

```gleam
fn terminate(reason, socket) -> Nil {
  case reason {
    channel.HeartbeatTimeout -> {
      // Clean up: remove from presence, release locks, etc.
      Nil
    }
    _ -> Nil
  }
}
```

The client-visible effect is that the WebSocket connection is closed from the server side. Phoenix JS clients will attempt to reconnect automatically.

## Rate limiting

When a client exceeds a configured rate limit, the offending message is **dropped**. No error is sent to the client. Rate limits are applied at three levels:

| Limit | Scope | Config function |
|-------|-------|-----------------|
| `message_rate` | Per socket, all topics | `beryl.with_message_rate` |
| `join_rate` | Per socket, join attempts | `beryl.with_join_rate` |
| `channel_rate` | Per socket+topic | `beryl.with_channel_rate` |

```gleam
let config =
  beryl.config(wire.phoenix_codec())
  |> beryl.with_message_rate(per_second: 100, burst: 200)
  |> beryl.with_join_rate(per_second: 5, burst: 10)
  |> beryl.with_channel_rate(per_second: 50, burst: 100)
```

If you need to inform the client that it has been rate-limited, implement application-level tracking in `handle_in` and return an explicit error reply.

## Group errors

Group operations (`create`, `delete`, `add`, `remove`, `topics`) return `Result(_, GroupError)`:

```gleam
case group.create(groups, name) {
  Ok(Nil) -> Nil
  Error(group.GroupAlreadyExists) -> Nil  // idempotent: treat as success if desired
  Error(group.GroupNotFound) -> Nil       // shouldn't happen for create
}
```

`group.broadcast` is fire-and-forget and never returns an error. If the group does not exist, the call is a no-op.

## Supervisor startup failures

`supervisor.start` returns `Result(SupervisedChannels, supervisor.StartError)`:

```gleam
case supervisor.start(config) {
  Ok(supervised) -> {
    // proceed
  }
  Error(supervisor.InvalidHeartbeatTimeout) -> {
    // Config error: heartbeat_timeout_ms must be >= 2
    panic
  }
  Error(supervisor.SupervisorStartFailed(err)) -> {
    // Internal actor startup failure — log and exit gracefully
    panic
  }
}
```

`InvalidHeartbeatTimeout` is always a configuration mistake. `SupervisorStartFailed` wraps a Beryl-owned startup failure; use `beryl/error.describe_start_failure` to format it for logs.

## send_info silent ignoring

`beryl.send_info` delivers a message to a channel's `handle_info` callback. If the socket is not connected, the topic is not joined, or no handler matches the topic, the message is **silently ignored** — no error is returned:

```gleam
// This is always Nil — no error even if socket_id is unknown
beryl.send_info(channels, socket_id, "room:lobby", my_message)
```

If delivery confirmation is important, implement a reply mechanism in `handle_info` that sends an acknowledgment back via `beryl.broadcast`.

## Client-visible error shapes

beryl uses the Phoenix wire protocol. Error responses take these shapes:

**Join rejected:**
```json
["1", "1", "room:lobby", "phx_reply", {"status": "error", "response": {}}]
```

**Channel error push (server-initiated):**
```json
[null, null, "room:lobby", "phx_error", {}]
```

**Channel closed:**
```json
[null, null, "room:lobby", "phx_close", {}]
```

Phoenix client libraries handle `phx_error` and `phx_close` automatically — the channel is marked as errored or closed, and the client may attempt to rejoin.

## See also

- [Troubleshooting](/troubleshooting/) — symptom-first diagnosis for connection failures, missed messages, and auth issues
- [WebSocket Transport guide](/guides/websocket/#authentication) — setting up `on_connect` for connection-level auth
- [Supervision guide](/guides/supervision/) — crash recovery and production startup to prevent coordinator failures silencing all errors
