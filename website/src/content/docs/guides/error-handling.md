---
title: Error Handling
---

This guide explains how beryl reports errors to your app and clients. It also
shows how to handle them.

## Rejected joins

Return a `RejectJoin` effect to reject a client. The error payload is sent back as a `phx_reply` with `status: "error"`:

```gleam
fn update(model: Model, ev: Input(Msg)) -> Next(Model) {
  case ev {
    socket.Join(topic, payload, ref) ->
      case authenticate(payload) {
        Error(_) ->
          socket.Next(model, [
            socket.RejectJoin(
              ref,
              json.object([#("reason", json.string("unauthorized"))]),
            ),
          ])
        Ok(user) ->
          socket.Next(store_user(model, topic, user), [
            socket.AcceptJoin(ref, option.None),
          ])
      }
    // ...
  }
}
```

The client sees:
```json
["1", "1", "room:lobby", "phx_reply", {"status": "error", "response": {"reason": "unauthorized"}}]
```

After rejection, the client stays connected but does not join the topic. If the
payload has a `reason` field, Phoenix clients pass it to the
`.join().receive("error", ...)` callback.

With `beryl/channel`, return `channel.reject(reason)` from the handler's
`join` callback. A topic no handler matches is rejected automatically with
`{"reason": "unmatched topic"}`.

:::note[Unanswered joins fail closed]
Answer each `Join` with `AcceptJoin` or `RejectJoin` in the same update. The
runtime rejects and logs an unanswered join. A missing match branch cannot
admit a client.
:::

## Connection-level authentication rejection

`on_connect` in the transport config rejects the WebSocket upgrade before any topic join occurs. Return `Error(server.ConnectRejected)` to send an HTTP 403 response:

```gleam
import beryl/transport/server

let config =
  server.default_config("/socket/websocket")
  |> server.with_on_connect(fn(req) {
    case extract_token(req) {
      Ok(_) -> Ok(Nil)
      Error(_) -> Error(server.ConnectRejected)  // → HTTP 403, connection refused
    }
  })
```

The client never receives a WebSocket handshake and cannot send any messages.

## Malformed wire messages

beryl parses incoming Phoenix protocol arrays:
`[join_ref, ref, topic, event, payload]`. It drops frames that it cannot decode
and does not send an error. Malformed frames are protocol violations.

If you need to surface decode errors in your own payload handling, decode the `Dynamic` payload with `gleam/dynamic/decode` and return an explicit `ReplyOk` or `ReplyError`:

```gleam
socket.Message(_topic, "create_item", payload, option.Some(ref)) ->
  case decode.run(payload, item_decoder()) {
    Ok(item) ->
      // process item
      socket.Next(model, [
        socket.ReplyOk(ref, json.object([#("id", json.string(item.id))])),
      ])
    Error(_) ->
      socket.Next(model, [
        socket.ReplyError(
          ref,
          json.object([#("reason", json.string("invalid_payload"))]),
        ),
      ])
  }
```

:::note[Refless messages cannot be answered]
`ReplyOk` and `ReplyError` need the message `ReplyRef`. It is `Some` only when
the client expects a reply. A `Message` with `None` has no request reference.
Use `Push` for a server message with its own event name.
:::

## Unmatched topics

If `update` does not accept a `phx_join` topic, reject it with a catch-all
`Join` branch that returns `RejectJoin`. If `update` ignores the join, beryl's
fail-closed default rejects it.

Messages pushed to a topic the socket never joined get an automatic error reply with `response: {"reason": "unmatched topic"}` when they carry a ref, matching Phoenix; refless pushes to unjoined topics are dropped.

## Heartbeat timeouts

When a client goes silent beyond `heartbeat_timeout_ms`, the runtime evicts the socket. Every joined topic receives a `Closed` event with `HeartbeatTimeout`:

```gleam
socket.Closed(topic, reason) -> {
  case reason {
    socket.HeartbeatTimeout -> {
      // Clean up: remove from presence, release locks, etc.
      Nil
    }
    _ -> Nil
  }
  socket.Next(prune(model, topic), [])
}
```

The client-visible effect is that the WebSocket connection is closed from the server side. Phoenix JS clients will attempt to reconnect automatically.

## Crashes in your update function

Beryl rescues crashes in `init` and `update` rather than letting them take down the socket's runtime actor. The blast radius depends on where the crash happens:

| Crash site | Effect |
|------------|--------|
| `init` | The connecting socket is not registered; the connection is closed |
| `update` on `Join` | The join is rejected (`response: {"reason": "join crashed"}`); the socket survives |
| `update` on `Message`/`Binary` | Only that topic is closed (`phx_error`); other topics survive |
| `update` on `Info` | The socket is torn down |
| `update` on `Closed` | Logged; the close completes anyway |

Crash descriptions are depth-limited and truncated before logging so client-triggered crashes cannot bloat log metadata.

This is not a generic catch-and-continue policy. Letting a callback crash its
socket actor would close every topic on that socket. Beryl instead discards
the failed callback result and closes the narrowest safe scope. Faults outside
these boundaries stop that socket actor; the router closes the connection and
removes its entries. A router fault still invokes supervision and disconnects
all sockets. See
[Runtime crash containment](/architecture/runtime/#crash-containment) for the
trade-off.

The channel layer maps those scopes to callbacks:

| Channel callback | Effect |
|---|---|
| `join` | Rejects only that join |
| `on_message` | Closes only that topic |
| `on_info` | Tears down that socket |
| `on_terminate` | Logs the panic and continues core teardown; the callback's actions are lost |

A terminate panic also discards the router model returned by that `Closed`
turn. The old instance therefore remains reachable through its own typed
sender until the topic is rejoined or the socket ends, even though client
traffic cannot reach the closed topic. Keep `on_terminate` small and
non-panicking; see [Crash behavior](/guides/channels/#crash-behavior).

## Rate limiting

When a client exceeds a rate limit, beryl **drops** the frame or message. It
does not send an error. An over-rate join is the exception. It receives an
error reply with `reason: "rate_limited"`.

| Limit | Scope | Enforced | Config function |
|-------|-------|----------|-----------------|
| `frame_rate` | Per connection, every complete frame | Transport edge | `beryl.with_frame_rate` |
| `message_rate` | Per socket, decoded non-join traffic | Runtime | `beryl.with_message_rate` |
| `join_rate` | Per socket, joins | Runtime | `beryl.with_join_rate` |
| `channel_rate` | Per socket+topic | Runtime | `beryl.with_channel_rate` |
| `topic_rates` | First matching pattern | Runtime | `beryl.with_topic_rate` |

The frame and message buckets are independent. Joins consume frame tokens like
every inbound frame, never message tokens, and use `join_rate` for runtime
accounting.

```gleam
let config =
  beryl.config(wire.phoenix_codec())
  |> beryl.with_frame_rate(per_second: 150, burst: 300)
  |> beryl.with_message_rate(per_second: 100, burst: 200)
  |> beryl.with_join_rate(per_second: 5, burst: 10)
  |> beryl.with_channel_rate(per_second: 50, burst: 100)
  |> beryl.with_topic_rate(pattern: "cursor:*", per_second: 30, burst: 60)
```

`with_topic_rate` overrides the global `channel_rate` for matching topics. Use
it to give a high-rate namespace, such as live cursors, more capacity than
chat. A non-positive `per_second` makes matching topics unlimited,
even when a global channel limit is configured, and allocates no per-topic
bucket. If you need to inform the client that it has been rate-limited,
implement application-level tracking in `update` and return an explicit
`ReplyError`.

## Group errors

Group operations (`create`, `delete`, `add`, `remove`, `topics`) return `Result(_, GroupError)`:

```gleam
case group.create(groups, name) {
  Ok(Nil) -> Nil
  Error(group.GroupAlreadyExists) -> Nil  // idempotent: treat as success if desired
  Error(group.GroupNotFound) -> Nil       // shouldn't happen for create
}
```

`group.broadcast` resolves the group's topics synchronously and never returns an error. If the group does not exist, the call is a no-op. Like other group operations, it panics if the groups actor is unavailable or does not reply within 5 seconds.

## Startup failures

`beryl.child_spec` validates configuration before returning the child spec:

```gleam
case beryl.child_spec(config, init: init, update: update) {
  Ok(#(sockets, spec)) -> add_to_supervisor(sockets, spec)
  Error(beryl.HeartbeatTimeoutTooLow(2)) ->
    // heartbeat_timeout_ms below 2 would silently disable eviction
    panic as "fix the heartbeat config"
  Error(beryl.InvalidTopicPattern(pattern, topic.EmptyTopic)) ->
    panic as { pattern <> " is empty" }
  Error(beryl.InvalidTopicPattern(pattern, topic.InvalidFormat(detail))) ->
    panic as { pattern <> ": " <> detail }
  Error(beryl.InvalidTopicPattern(pattern, _other)) ->
    panic as { pattern <> " is invalid" }
}
```

`InvalidTopicPattern` nests `beryl/topic.TopicError` rather than flattening it
to a string. New `TopicError` variants may be added in a minor release, so
match exact variants only when your handling differs and keep a catch-all
otherwise.

`channel.child_spec` validates the handler table first and reports
`InvalidPattern(pattern, reason)`, `DuplicatePattern(pattern)`, or
`InvalidConfig(beryl.ConfigError)`. `InvalidPattern` nests
`beryl/topic.TopicError`; match a catch-all reason unless your code handles
a specific variant differently.

## Sender delivery is best-effort

`socket.notify` sends a typed message to socket `update` as an `Info` event. If
the socket disconnected, beryl drops the message and returns no error:

```gleam
// This is always Nil — no error even if the socket is gone
socket.notify(sender, MyMessage)
```

If delivery confirmation is important, have the `Info` arm of `update` acknowledge back to the sending process.

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

Phoenix client libraries handle `phx_error` and `phx_close`. The client marks
the channel as errored or closed and can try to rejoin.

## See also

- [Troubleshooting](/troubleshooting/) — symptom-first diagnosis for connection failures, missed messages, and auth issues
- [WebSocket Transport guide](/guides/websocket/#authentication) — setting up `on_connect` for connection-level auth
- [Supervision guide](/guides/supervision/) — the built-in runtime supervision and crash semantics
