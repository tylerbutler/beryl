# beryl_protocol

A pure state machine for Phoenix-compatible channels, for Gleam on Erlang and
JavaScript.

## Overview

`beryl_protocol` decides what happens on one channel connection: joins, leaves,
messages, replies, pushes, heartbeats, and closes. It does no I/O. Your host
gives it decoded input and the current time. It returns the new state and a
list of actions. Your host runs the actions.

Use this package to run beryl channels where beryl's OTP runtime is not
available, for example on a JavaScript server or in a Cloudflare Durable
Object. beryl's own runtime uses the same package.

The host is responsible for:

- Sockets, frames, and the wire codec.
- Join authorization and application handlers.
- Clocks and timers.
- Payload size limits and rate limits.

The package depends on `gleam_stdlib` and `gleam_json`.

## Installation

beryl includes this package. The package has no separate release. To use it
without beryl, add a git dependency:

```toml
[dependencies]
beryl_protocol = { git = "https://github.com/tylerbutler/beryl.git", ref = "main", path = "packages/beryl_protocol" }
```

## Example: join a channel

```gleam
import beryl_protocol as protocol
import gleam/dynamic
import gleam/json
import gleam/option.{Some}

pub fn main() -> Nil {
  let assert Ok(config) =
    protocol.config()
    |> protocol.with_heartbeat_timeout(timeout_ms: 30_000)
  let assert Ok(state) = protocol.new(config, "connection-1", 0)

  // 1. The client asks to join "room:lobby".
  let join =
    protocol.Join(
      topic: "room:lobby",
      payload: dynamic.nil(),
      join_ref: Some("1"),
      ref: Some("1"),
    )
  let assert Ok(#(state, [protocol.DeliverJoin(operation:, ..), _deadline])) =
    protocol.step(state, protocol.Receive(join), 10)

  // 2. The application accepts the join.
  let accept =
    protocol.AcceptJoin(
      operation,
      json.object([]),
      protocol.InvalidateImmediately,
    )
  let assert Ok(#(state, [protocol.AdmitJoin(operation:, ..), _deadline])) =
    protocol.step(state, accept, 20)

  // 3. The host subscribes the channel to the topic.
  let assert Ok(#(
    _state,
    [protocol.Joined(..), protocol.Send(reply), _deadline],
  )) = protocol.step(state, protocol.AdmissionFinished(operation, True), 30)

  // 4. Encode the join reply and send it to the client.
  let assert protocol.ReplyMessage(status: protocol.StatusOk, ..) = reply
  Nil
}
```

For a complete host, see the
[portable channels example](../../examples/portable_channels/README.md). It runs
the protocol in a Cloudflare Durable Object with the Phoenix JavaScript client.

## Write a host

1. Make one state for each connection with `new`.
2. For each event, call `step(state, input, now_ms)`.
3. Keep the state that `step` returns. Run its actions in list order.
4. When an action asks for a result, send the result back with `step`.

### Inputs

The host sends these inputs when events occur:

| Input                         | When to send it                                                       |
| ----------------------------- | --------------------------------------------------------------------- |
| `Receive(decoded)`            | The client sends a frame. Decode it to `Join`, `Message`, `Leave`, or `Heartbeat`. |
| `Push(channel, event, data)`  | The server pushes an event. Get the channel with `channel(state, topic)`. |
| `BeginClose(channel, reason)` | The server closes one channel.                                        |
| `Disconnect(reason)`          | The transport closes.                                                 |
| `CheckDeadline`               | A timer from a `Deadline` action fires.                               |

### Actions

| Action            | What the host does                              | Input to send back                                   |
| ----------------- | ----------------------------------------------- | ---------------------------------------------------- |
| `DeliverJoin`     | Authorizes the join.                            | `AcceptJoin`, `RejectJoin`, or `CallbackFinished`    |
| `AdmitJoin`       | Subscribes the channel to its topic.            | `AdmissionFinished`                                  |
| `Joined`          | Nothing. The channel is now joined.             | None                                                 |
| `DeliverMessage`  | Runs the application handler.                   | `Reply` or `Discard`, if `operation` is `Some`       |
| `CloseChannel`    | Releases the channel's resources.               | `CleanupFinished`                                    |
| `Send(outbound)`  | Encodes the message and sends it to the client. | None                                                 |
| `CloseConnection` | Closes the socket.                              | None                                                 |
| `Deadline`        | Sets a timer for the given time, or clears it for `None`. | `CheckDeadline` when the timer fires       |

Each `step` result ends with a `Deadline` action.

`CallbackFinished` ends a join that the application did not answer. The client
gets an error reply.

### Barriers

Admission and cleanup are barriers. After `AdmitJoin`, send
`AdmissionFinished` before other inputs. After `CloseChannel`, send
`CleanupFinished` before other inputs. If the work fails, still send the
completion. For a failed admission, send `AdmissionFinished(operation, False)`.

### Close modes

`AcceptJoin` takes a `CloseMode`. It controls what happens to work in progress
when the channel starts to close:

- `InvalidateImmediately`: the protocol drops pending replies and pushes.
- `DrainBeforeCleanup`: committed replies and pushes continue. Send
  `DrainFinished` when that work is done, then send `CleanupFinished`.

### Host rules

- Give each connection a new epoch: a string of 1 to 256 bytes. Do not use the
  same epoch again, also not on reconnect. Do not use socket IDs or client
  references as epochs.
- Give `now_ms` in milliseconds. Time must not go backward. A backward clock
  can return `InvalidClock`.
- Send operations back exactly as the actions gave them. Do not make them from
  wire references.
- An operation that is no longer current is not an error. `step` accepts it and
  does nothing.
- If `step` returns an error, it changes nothing. Keep the old state.
  `describe_error` gives a message without application data.

## Configuration

`config()` uses these defaults:

| Limit                                  | Default | Function                 |
| -------------------------------------- | ------- | ------------------------ |
| Topic size                             | 256 B   | `with_max_topic_bytes`   |
| Event name size                        | 64 B    | `with_max_event_bytes`   |
| Channels for each connection           | 1000    | `with_max_channels`      |
| Pending joins and replies              | 1024    | `with_max_pending`       |
| Heartbeat timeout                      | 60 s    | `with_heartbeat_timeout` |

To set all limits at once, use `with_limits`. A value out of range returns
`InvalidConfig(limit, value)`.

`with_topicless_events(config, True)` lets a client send an event without a
topic. The protocol accepts it only when exactly one channel is joined.

`validate_topic`, `validate_pattern`, and `validate_event` check names before
you use them.

## Save and restore state

Use `export` and `restore` to keep a connection across a host restart, for
example when a Durable Object hibernates.

`export(state, now_ms)` returns a JSON string of no more than 1 MiB. It does not
contain application payloads or callbacks. Save a trusted wall-clock time with
it.

`restore(snapshot, elapsed_ms, now_ms)` returns a state and actions. Set
`elapsed_ms` to the wall-clock time since the export. Run the actions before
other inputs.

- If the wall clock went backward or is not available, do not restore. Close
  the connection and let the client reconnect.
- Channels with unfinished authorization, replies, or cleanup get `phx_error`.
  The client must join them again.
- A snapshot from an unknown version returns `UnsupportedVersion`. A damaged
  snapshot returns `InvalidSnapshot`.

## Reference

The [source contract](./src/README.protocol.md) lists all types, queries, and
errors.

## Development

From the repository root, `just protocol-test` builds the package in strict
mode and runs its tests on Erlang and JavaScript.
