---
title: Error Handling
description: Understand how joins, message replies, connection rejection, startup failures, and runtime shutdown are surfaced.
---

This guide covers how Beryl surfaces errors to your app logic and to connected clients.

## Rejected joins

Reject a pending join by returning `event.RejectJoin(ref, reason)` from `update`.

```gleam
import beryl/event as event
import gleam/json

fn update(model: Model, ev: event.Event(Msg)) -> event.Next(Model, Msg) {
  case ev {
    event.Join(_topic_name, _payload, ref) ->
      event.Next(
        model,
        [
          event.RejectJoin(
            ref,
            json.object([
              #("reason", json.string("unauthorized")),
            ]),
          ),
        ],
      )

    _ -> event.Next(model, [])
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
  mist_transport.default_config("/socket/websocket")
  |> mist_transport.with_on_connect(fn(req) {
    case extract_token(req) {
      Ok(_token) -> Ok([])
      Error(_) -> Error(mist_transport.ConnectRejected)
    }
  })
```

`Error(mist_transport.ConnectRejected)` returns HTTP 403 before the WebSocket handshake completes.

## Malformed wire messages

Beryl still speaks Phoenix array frames: `[join_ref, ref, topic, event, payload]`.

Frames that cannot be decoded are dropped silently. If the frame was syntactically valid but the payload shape is wrong for your app, return your own explicit error reply from `update`.

```gleam
import beryl/event as event
import gleam/json

fn update(model: Model, ev: event.Event(Msg)) -> event.Next(Model, Msg) {
  case ev {
    event.Message(_topic_name, "create_item", payload, Some(ref)) ->
      case decode_item(payload) {
        Ok(item) -> persist_item(model, item, ref)
        Error(_) ->
          event.Next(
            model,
            [
              event.ReplyError(
                ref,
                json.object([
                  #("reason", json.string("invalid_payload")),
                ]),
              ),
            ],
          )
      }

    _ -> event.Next(model, [])
  }
}
```

## Unanswered joins fail closed

Routing now lives entirely in your own `update`. If a `Join` falls through every branch and you return no `event.AcceptJoin` or `event.RejectJoin`, the runtime rejects it automatically at the end of the turn.

The client-visible error payload is:

```json
{"reason": "join not acknowledged"}
```

This also applies when your join logic returns `event.Stop(...)` before answering the join.

## Heartbeat timeouts and topic closure

When a socket goes silent past the configured heartbeat timeout, the runtime closes the connection. Every joined topic is delivered to your app as `event.Closed(topic, event.HeartbeatTimeout)`.

```gleam
import beryl/event as event
import gleam/list

fn update(model: Model, ev: event.Event(Msg)) -> event.Next(Model, Msg) {
  case ev {
    event.Closed(topic_name, event.HeartbeatTimeout) ->
      event.Next(
        Model(
          ..model,
          joined_topics: list.filter(model.joined_topics, fn(topic) {
            topic != topic_name
          }),
        ),
        [],
      )

    _ -> event.Next(model, [])
  }
}
```

## Runtime crashes inside your app logic

Crash behavior depends on which event was being processed:

- a crash while handling `event.Join` rejects that join with `{"reason": "join crashed"}`,
- a crash while handling `event.Message` or `event.Binary` closes that topic,
- a crash while handling `event.Info` closes the whole socket,
- a crash while handling `event.Closed` is logged and teardown continues.

## Rate limiting

When a client exceeds a configured rate limit, the offending message is **dropped**. No automatic error is sent back to the client.

| Limit | Scope | Config function |
|-------|-------|-----------------|
| `message_rate` | Per socket, all topics | `beryl.with_message_rate` |
| `join_rate` | Per socket, join attempts | `beryl.with_join_rate` |
| `channel_rate` | Per socket plus topic | `beryl.with_channel_rate` |
| `topic_rate` | First matching topic pattern | `beryl.with_topic_rate` |

```gleam
let config =
  beryl.config(wire.phoenix_codec())
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

`event.notify(sender, message)` is safe to call from any process. If the socket has already disconnected, the message is ignored.

```gleam
import beryl/event

event.notify(sender, RefreshRequested)
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
