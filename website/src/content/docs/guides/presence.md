---
title: Presence
description: Track per-topic presence with CRDT replication, diff callbacks, and runtime-applied presence effects.
---

Beryl includes a presence system for tracking connected users and their metadata. It is backed by the `lattice_presence` CRDT, which automatically resolves conflicts across distributed Erlang nodes.

## How it works

Presence uses an **add-wins observed-remove set** with causal context. When a user joins or leaves, state is merged across nodes without leader election or consensus.

The presence system still has two layers:

1. `beryl/presence` — an OTP actor wrapping the CRDT with optional PubSub replication
2. `beryl/presence.Diff` — an opaque diff value for `with_on_diff` and `beryl.broadcast_presence_diff`

## Starting presence

```gleam
import beryl/presence
import beryl/pubsub

// Without PubSub (single-node only)
let assert Ok(p) = presence.start(presence.default_config("node1"))

// With PubSub for cross-node replication
let ps = pubsub.start(pubsub.default_config())
let config =
  presence.default_config("node1")
  |> presence.with_pubsub(ps)
  |> presence.with_broadcast_interval(1500)
let assert Ok(p) = presence.start(config)
```

## Tracking and untracking directly

The underlying presence API is still available when you need it directly.

```gleam
import gleam/json

let ref =
  presence.track(
    p,
    "room:lobby",
    "user:alice",
    "socket-1",
    json.object([
      #("status", json.string("online")),
      #("joined_at", json.int(1234567890)),
    ]),
  )

presence.untrack(p, ref)
presence.untrack_all(p, "socket-1")
```

- the **key** groups multiple connections for one user,
- the **session id** is usually the socket id,
- `track` returns a server-generated ref that identifies one specific tracked presence.

## Listing presence

```gleam
let entries = presence.list(p, "room:lobby")
let alice_sessions = presence.get_by_key(p, "room:lobby", "user:alice")
```

`presence.list` returns full `PresenceEntry` values. `presence.get_by_key` narrows the query to one key.

## Diff callbacks

Use `with_on_diff` when you want to react to local changes or remote merges immediately.

```gleam
import gleam/list
import gleam/io
import gleam/string

let config =
  presence.default_config("node1")
  |> presence.with_pubsub(ps)
  |> presence.with_broadcast_interval(1500)
  |> presence.with_on_diff(fn(diff) {
    diff
    |> presence.diff_topics
    |> list.each(fn(topic_name) {
      io.println("Topic changed: " <> topic_name)
      io.println("Joins: " <> string.inspect(presence.diff_joins(diff, topic_name)))
      io.println("Leaves: " <> string.inspect(presence.diff_leaves(diff, topic_name)))
    })
  })
```

## Broadcasting Phoenix-compatible diffs manually

`beryl.broadcast_presence_diff` is still public for applications that want the classic `on_diff` → manual broadcast pipeline.

```gleam
import beryl
import gleam/list

let config =
  presence.default_config("node1")
  |> presence.with_pubsub(ps)
  |> presence.with_broadcast_interval(1500)
  |> presence.with_on_diff(fn(diff) {
    diff
    |> presence.diff_topics
    |> list.each(fn(topic_name) {
      beryl.broadcast_presence_diff(sockets, topic_name, diff)
    })
  })
```

The payload matches Phoenix Presence's `presence_diff` shape.

```json
{
  "joins": { "user:alice": { "metas": [{ "status": "online" }] } },
  "leaves": { "user:bob": { "metas": [{ "status": "offline" }] } }
}
```

For lower-level integrations, `beryl/presence/wire.encode_diff(diff, topic)` returns the JSON payload without broadcasting it.

## Cross-node replication

When PubSub is configured, the presence actor:

1. periodically broadcasts its full CRDT state to `beryl:presence:sync`,
2. receives remote state over PubSub,
3. merges that state with the local CRDT,
4. fires `with_on_diff` for non-empty local or merged changes.

Self-delivery is prevented by `pubsub.broadcast_from`, so a node does not process its own sync message.

## Integrating presence with app-side dispatch

In the current Beryl API, applications usually attach a presence handle to `beryl.Config` and let the runtime apply presence effects.

```gleam
import beryl
import beryl/event as event
import beryl/presence/wire as presence_wire
import beryl/wire
import gleam/json

let assert Ok(p) = presence.start(presence.default_config("node1"))

let config =
  beryl.config(wire.phoenix_codec())
  |> beryl.with_presence_handle(p)

fn update(model: Model, ev: event.Event(Msg)) -> event.Next(Model, Msg) {
  case ev {
    event.Join(topic_name, _payload, ref) ->
      event.Next(
        model,
        [
          event.AcceptJoin(ref, None),
          event.PresenceTrack(
            topic_name,
            "user:" <> model.user_id,
            json.object([#("status", json.string("online"))]),
          ),
          event.PushPresence(
            topic_name,
            "presence_state",
            presence_wire.encode_state,
          ),
        ],
      )

    event.Closed(topic_name, _reason) ->
      event.Next(
        model,
        [event.PresenceUntrack(topic_name, "user:" <> model.user_id)],
      )

    _ -> event.Next(model, [])
  }
}
```

A few things to notice:

- `beryl.with_presence_handle(p)` enables presence-aware effects.
- `event.PresenceTrack` and `event.PresenceUntrack` are interpreted by the runtime.
- `event.PushPresence` and `event.BroadcastPresence` read presence state **when the effect is applied**, so they already reflect earlier `PresenceTrack` / `PresenceUntrack` effects in the same list.
- the runtime still auto-cleans any leftover tracked keys when a topic closes, so `PresenceUntrack` in `event.Closed` is explicit cleanup, not the only cleanup path.

## Next steps

- [PubSub](/guides/pubsub/) — required for cross-node replication
- [App-Side Dispatch](/guides/dispatch/) — see where presence effects fit into your socket model and routing logic
- [Troubleshooting](/troubleshooting/#presence-is-stale-or-incorrect) — diagnosing stale entries, missing diffs, and replication issues
