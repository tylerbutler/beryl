---
title: Handle overload
description: Configure local work limits and handle rejected sends and presence mutations.
---

beryl reserves capacity before it accepts local work through its runtime and
presence APIs. A full queue rejects new work. Moving accepted work from a queue
into a callback or a suspended effect list does not release its capacity.

## Default limits

| Boundary | Outstanding items | Accounted bytes |
|---|---:|---:|
| Router | 4096 | 32 MiB |
| Each socket | 1024 | 8 MiB |
| Each topic worker | 256 | 8 MiB |
| Each presence actor | 4096 | 32 MiB |
| Each callback result | 256 effects | 8 MiB |

The socket limit includes input, pending worker reports, active effect lists,
and unanswered reply refs. Callback completion does not release an unanswered
ref. A reply, topic close, or socket close releases it.

A worker can have one normal report waiting for the socket. Its input stays
charged until the socket applies or cancels the report and its continuation.
Join and termination results also need socket capacity. The runtime checks a
callback's complete result before applying its first effect, including join
success. Your callback still allocates that result before beryl can reject it.

Each socket owner with runtime presence reserves one cleanup item in addition
to its mutation work. Socket close or owner exit activates this item even when
the presence queue is full. Cleanup uses the owner's process identity, so an
old socket cannot remove a replacement socket's reservation or presence refs.
Idle cleanup reservations consume capacity until the session ends.

The supervisor admits one stop request at a time. Repeated disconnects and
terminal stop requests do not create repeated socket control work. A timeout
or caller exit stops a connection initializer that has not committed.

## Configure limits

Use `overload.limits` to validate positive item and byte limits. Zero does not
mean unlimited.

```gleam
import beryl
import beryl/overload
import beryl/wire

let assert Ok(router_limit) =
  overload.limits(items: 4096, bytes: 32 * 1024 * 1024)
let assert Ok(socket_limit) =
  overload.limits(items: 1024, bytes: 8 * 1024 * 1024)
let assert Ok(worker_limit) =
  overload.limits(items: 256, bytes: 8 * 1024 * 1024)

let config =
  beryl.config(wire.phoenix_codec())
  |> beryl.with_router_queue_limits(router_limit)
  |> beryl.with_socket_queue_limits(socket_limit)
  |> beryl.with_worker_queue_limits(worker_limit)
  |> beryl.with_effect_limits(worker_limit)
```

Use `presence.with_queue_limits(config, limit)` for a presence actor. These
limits are safety defaults, not measured throughput recommendations. Keep room
for input, results, reply refs, and cleanup at the same time.

## Handle send results

`socket.notify`, `channel.notify`, `beryl.broadcast`, `beryl.broadcast_from`,
and `beryl.broadcast_presence_diff` return
`Result(Nil, overload.AdmissionError)`.

`Ok(Nil)` means local admission. It does not confirm callback completion,
delivery to all subscribers, a transport write, or peer receipt.

| Error | Meaning |
|---|---|
| `Overloaded(boundary)` | Outstanding work already uses the available capacity. |
| `ItemTooLarge(boundary)` | This item or callback result exceeds the boundary's limit. |
| `Closed` | This owner has stopped accepting work. |
| `Unavailable` | The owner or its queue no longer exists. |

Handle the result at the calling boundary:

```gleam
import beryl
import beryl/overload
import gleam/io
import gleam/json

case beryl.broadcast(sockets, "room:lobby", "refresh", json.null()) {
  Ok(Nil) -> Nil
  Error(error) ->
    io.println_error("Refresh rejected: " <> overload.describe(error))
}
```

Do not create an unlimited retry queue. A rejected server notification does
not close a healthy target. A stale sender cannot send to a later socket or
join. A `Sockets` handle can resolve a restarted router; sends during the
restart window return an error.

After router admission, a broadcast can reach some recipients and fail at
others. The router closes saturated destination sockets and continues with
healthy destinations. A socket-originated broadcast reserves router capacity
before sending its own copy.

`group.broadcast` returns `GroupLookupFailed(error)` for a missing group, or
`BroadcastRejected(admitted_topics, reason)` after partial admission. Earlier
topics stay admitted. Group actor lookup retains its existing call timeout
and panic behavior if that actor is unavailable.

## Client and callback overload

Mist and Ewe close the connection when the shared frame pipeline cannot admit
a text or binary frame. Worker input or callback-result rejection closes the
affected topic with `phx_error`. Socket input, report, reply-ref, or index
admission failure closes the socket. An oversized join result cannot send
join success or apply a prefix of its actions.

Already accepted reports retain their order before terminal frames where
teardown can complete. Existing shutdown deadlines still apply. A blocked
worker does not block another topic's worker. A socket-wide presence wait or
ordered close can still delay that socket's other topics.

## Presence calls and timeouts

`presence.track` returns `Result(String, overload.CallError)`. `untrack` and
`untrack_all` return `Result(Nil, overload.CallError)`. `update` returns either
the replacement ref, `UnknownRef(ref)`, or `RequestFailed(call_error)`.

`AdmissionRejected(error)` means the mutation did not enter the queue.
`RequestTimedOut` does not prove that the mutation failed: beryl cancels work
that is still pending, but running work stays charged and may complete.
`OwnerUnavailable` means the presence owner exited during the call. Reply
aliases discard late replies after the caller stops waiting.

Reads use the existing ETS snapshot and do not wait on the mutation queue.
Runtime presence rejection closes the affected scope without applying later
success-dependent effects. Reserved session cleanup remains available.

## Observe capacity

Use `snapshot.queue(sockets)`, `socket.queue_snapshot(sender)`,
`channel.queue_snapshot(sender)`, or `presence.queue_snapshot(handle)`.
These calls do not need an actor turn. They return current items and bytes,
limits, high-water marks, rejected and cancelled totals, and
`oldest_age_ms`. Age uses monotonic milliseconds and excludes idle presence
cleanup reservations. Poll at a modest rate; snapshots still read queue data.

Runtime telemetry follows `beryl.with_telemetry`. Enable presence queue
telemetry with `presence.with_telemetry(config)`. The event
`[beryl, queue, occupancy]` has measurements `items`, `bytes`, `max_items`,
`max_bytes`, `high_items`, `high_bytes`, `rejected`, `cancelled`, and
`oldest_age_ms`. Its only labels are `boundary` and `outcome`; outcomes are
`changed` and `rejected`. Boundaries are `router_queue`, `socket_queue`,
`worker_queue`, `presence_queue`, and `callback_batch`. Concurrent producers
can emit observations in a different order from their reservations.

## Memory boundaries

Accounted bytes measure inspectable term structure. This includes list,
tuple, and map structure and binary backing allocations. A small sub-binary
can therefore cost as much as its large backing binary. This is not an exact
BEAM heap or RSS measurement. Function environments, sealed channel messages,
and arbitrary application models do not have a retained-heap byte guarantee.

The limits cover supported local admission APIs. They do not bound raw
PID/Subject sends, generic PubSub delivery before receipt, remote presence
sync, transport buffering before frame receipt, application-owned publisher
or bridge queues, or retained presence/group state. Keep callbacks, logging,
and telemetry handlers bounded.

OTP supervisor/bootstrap RPC mailboxes and arbitrary system traffic remain
outside the ledger protocol. Do not infer a bound for an externally suspended
socket factory from the router's admission limit.

Outbound connection queues remain outside this contract; follow
[issue #249](https://github.com/tylerbutler/beryl/issues/249). Per-owner limits
also need finite connection and topic populations before they can support a
node-wide memory estimate. The existing unlimited connection defaults have
not changed. See [production controls](/guides/production-hardening/).
