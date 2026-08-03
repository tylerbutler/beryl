---
title: Error Handling
description: Understand how joins, message replies, connection rejection, startup failures, and runtime shutdown are surfaced.
---

This guide covers how Beryl surfaces errors to your app logic and to connected clients.

## Rejected joins

Reject a pending join by returning `socket.RejectJoin(ref, reason)` from `update`.

```gleam
import beryl/socket
import gleam/json

fn update(model: Model, ev: socket.Input(Msg)) -> socket.Next(Model, Msg) {
  case ev {
    socket.Join(_topic_name, _payload, ref) ->
      socket.Next(
        model,
        [
          socket.RejectJoin(
            ref,
            json.object([
              #("reason", json.string("unauthorized")),
            ]),
          ),
        ],
      )

    _ -> socket.Next(model, [])
  }
}
```

The client sees a Phoenix `phx_reply` error frame:

```json
["1", "1", "room:lobby", "phx_reply", {"status": "error", "response": {"reason": "unauthorized"}}]
```

## Connection-level authentication rejection

Reject the entire WebSocket upgrade from `with_on_connect`.

```gleam
let config =
  server.default_config("/socket/websocket")
  |> server.with_on_connect(fn(req) {
    case extract_token(req) {
      Ok(_token) -> Ok([])
      Error(_) -> Error(server.ConnectRejected)
    }
  })
```

`Error(server.ConnectRejected)` returns HTTP 403 before the WebSocket handshake completes.

## Malformed wire messages

Beryl still speaks Phoenix array frames: `[join_ref, ref, topic, event, payload]`.

Frames that cannot be decoded are dropped silently. If the frame was syntactically valid but the payload shape is wrong for your app, return your own explicit error reply from `update`.

```gleam
import beryl/socket
import gleam/json

fn update(model: Model, ev: socket.Input(Msg)) -> socket.Next(Model, Msg) {
  case ev {
    socket.Message(_topic_name, "create_item", payload, Some(ref)) ->
      case decode_item(payload) {
        Ok(item) -> persist_item(model, item, ref)
        Error(_) ->
          socket.Next(
            model,
            [
              socket.ReplyError(
                ref,
                json.object([
                  #("reason", json.string("invalid_payload")),
                ]),
              ),
            ],
          )
      }

    _ -> socket.Next(model, [])
  }
}
```

## Unanswered joins fail closed

Routing now lives entirely in your own `update`. If a `Join` falls through every branch and you return no `socket.AcceptJoin` or `socket.RejectJoin`, the runtime rejects it automatically at the end of the turn.

The client-visible error payload is:

```json
{"reason": "join not acknowledged"}
```

This also applies when your join logic returns `socket.Stop(...)` before answering the join.

## Heartbeat timeouts and topic closure

When a socket goes silent past the configured heartbeat timeout, the runtime closes the connection. Every joined topic is delivered to your app as `socket.Closed(topic, socket.HeartbeatTimeout)`.

```gleam
import beryl/socket
import gleam/list

fn update(model: Model, ev: socket.Input(Msg)) -> socket.Next(Model, Msg) {
  case ev {
    socket.Closed(topic_name, socket.HeartbeatTimeout) ->
      socket.Next(
        Model(
          ..model,
          joined_topics: list.filter(model.joined_topics, fn(topic) {
            topic != topic_name
          }),
        ),
        [],
      )

    _ -> socket.Next(model, [])
  }
}
```

## Runtime crashes inside your app logic

Crash behavior depends on which event was being processed:

- a crash while handling `socket.Join` rejects that join with `{"reason": "join crashed"}`,
- a crash while handling `socket.Message` or `socket.Binary` closes that topic,
- a crash while handling `socket.Info` closes the whole socket,
- a crash while handling `socket.Closed` is logged and teardown continues.

## Rate limiting

When a client exceeds a configured rate limit, the offending frame or message is **dropped**. No automatic error is sent back to the client.

| Limit | Scope | Enforced | Config function |
|-------|-------|----------|-----------------|
| `frame_rate` | Per connection, every inbound frame (pre-decode, including malformed ones) | Transport edge | `beryl.with_frame_rate` |
| `message_rate` | Per socket, decoded non-join traffic | Runtime | `beryl.with_message_rate` |
| `join_rate` | Per socket, join attempts | Runtime | `beryl.with_join_rate` |
| `channel_rate` | Per socket plus topic | Runtime | `beryl.with_channel_rate` |
| `topic_rate` | First matching topic pattern | Runtime | `beryl.with_topic_rate` |

`frame_rate` and `message_rate` are independent: neither falls back to the
other, and joins consume only `join_rate` regardless of either setting.

```gleam
let config =
  beryl.config(wire.phoenix_codec())
  |> beryl.with_frame_rate(per_second: 150, burst: 300)
  |> beryl.with_message_rate(per_second: 100, burst: 200)
  |> beryl.with_join_rate(per_second: 5, burst: 10)
  |> beryl.with_channel_rate(per_second: 50, burst: 100)
```

## Group errors

Group operations return `Result(_, group.GroupError)` for logical failures such as `GroupAlreadyExists` or `GroupNotFound`.

`group.broadcast` is fire-and-forget and silently does nothing when the named group does not exist.

## Startup and shutdown errors

`beryl.start` can fail with either eager config validation or a runtime startup failure.

```gleam
import beryl/error as beryl_error
import gleam/io

case beryl.start(config, init: init, update: update) {
  Ok(sockets) -> run(sockets)
  Error(beryl.InvalidConfig(error)) -> handle_config_error(error)
  Error(beryl.RuntimeStartFailed(failure)) ->
    io.println(beryl_error.describe_start_failure(failure))
}
```

`beryl.child_spec` fails only with `beryl.ConfigError`, because it validates before any child process starts.

`beryl.stop(sockets)` returns:

- `Ok(Nil)` when the Beryl subtree stopped cleanly,
- `Error(beryl.NotRunning)` when the handle was never started, is restarting, or was already stopped,
- `Error(beryl.StopTimeout)` when shutdown took too long.

## Typed server-side messages after disconnect

`socket.notify(sender, message)` is safe to call from any process. If the socket has already disconnected, the message is ignored.

```gleam
import beryl/socket

socket.notify(sender, RefreshRequested)
```

## Client-visible error shapes

Beryl still uses Phoenix-compatible wire frames.

**Join rejected:**
```json
["1", "1", "room:lobby", "phx_reply", {"status": "error", "response": {}}]
```

**Topic error push:**
```json
[null, null, "room:lobby", "phx_error", {}]
```

**Topic closed:**
```json
[null, null, "room:lobby", "phx_close", {}]
```

## See also

- [WebSocket Transport](/guides/websocket/#authentication) — connection rejection and origin policy
- [Supervision](/guides/supervision/) — standalone vs embedded startup and what a restart actually resets
- [Troubleshooting](/troubleshooting/) — symptom-first diagnosis for failed joins, missed broadcasts, and auth problems
