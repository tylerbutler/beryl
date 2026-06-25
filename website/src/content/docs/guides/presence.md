---
title: Presence
---

beryl includes a presence system for tracking connected users and their metadata. It's backed by the `lattice_presence` CRDT (conflict-free replicated data type), which automatically resolves conflicts across distributed Erlang nodes.

## How it works

Presence tracking uses an **add-wins observed-remove set** (AWORSet) with causal context. When a user joins or leaves, the state is merged across all nodes without coordination — no leader election or consensus required.

The presence system has two layers:

1. **`beryl/presence`** — OTP actor wrapping the CRDT with PubSub replication
2. **`beryl/presence.Diff`** — An opaque notification value for `on_diff`, with accessor helpers for changed topics, joins, and leaves

## Starting presence

```gleam
import beryl/presence
import beryl/pubsub

// Without PubSub (single-node only)
let assert Ok(p) = presence.start(presence.default_config("node1"))

// With PubSub for cross-node replication
let assert Ok(ps) = pubsub.start(pubsub.default_config())
let config =
  presence.default_config("node1")
  |> presence.with_pubsub(ps)
  |> presence.with_broadcast_interval(1500)
let assert Ok(p) = presence.start(config)
```

## Tracking presences

Track a user's presence when they join a channel:

```gleam
import gleam/json

// Track a user in a topic
let ref = presence.track(
  p,
  "room:lobby",   // topic
  "user:alice",    // key (groups multiple connections)
  socket_id,       // pid (unique per connection)
  json.object([    // metadata
    #("status", json.string("online")),
    #("joined_at", json.int(1234567890)),
  ]),
)
```

The **key** groups multiple connections from the same user. The **pid** uniquely identifies each connection (typically the socket ID).

## Untracking

```gleam
// Remove a specific presence
presence.untrack(p, "room:lobby", "user:alice", socket_id)

// Remove all presences for a socket (e.g., on disconnect)
presence.untrack_all(p, socket_id)
```

## Listing presences

```gleam
// Get all presences in a topic
let entries = presence.list(p, "room:lobby")
// Returns: [PresenceEntry(pid: "socket_1", key: "user:alice", meta: ...)]

// Get presences for a specific key
let alice_sessions = presence.get_by_key(p, "room:lobby", "user:alice")
// Returns: [#("socket_1", meta), #("socket_2", meta)]
```

## Diff callbacks

Get notified immediately when presence state changes:

```gleam
let config =
  presence.default_config("node1")
  |> presence.with_pubsub(ps)
  |> presence.with_broadcast_interval(1500)
  |> presence.with_on_diff(fn(diff) {
    diff
    |> presence.diff_topics
    |> list.each(fn(topic) {
      io.println("Topic changed: " <> topic)
      io.println("Joins: " <> string.inspect(presence.diff_joins(diff, topic)))
      io.println("Leaves: " <> string.inspect(presence.diff_leaves(diff, topic)))
    })
  })
```

The `on_diff` callback fires whenever local tracking changes or remote merges produce non-empty changes, ensuring no diffs are lost during rapid state changes.

## Broadcasting Phoenix-compatible diffs

Use `beryl.broadcast_presence_diff` to send a `presence_diff` event to sockets subscribed to the changed topic:

```gleam
import beryl

let config =
  presence.default_config("node1")
  |> presence.with_pubsub(ps)
  |> presence.with_broadcast_interval(1500)
  |> presence.with_on_diff(fn(diff) {
    beryl.broadcast_presence_diff(channels, "room:lobby", diff)
  })
```

`broadcast_presence_diff` broadcasts to a single topic. The `diff` passed to `on_diff` may span multiple topics; if you track presence across several topics, iterate over the affected topics:

```gleam
on_diff: option.Some(fn(diff) {
  diff
  |> presence.diff_topics
  |> list.each(fn(topic) {
    beryl.broadcast_presence_diff(channels, topic, diff)
  })
}),
```

Passing the full diff on each iteration is safe: `broadcast_presence_diff` encodes only the named topic's entries from the diff, so unrelated topics are never included in a broadcast.

The payload matches Phoenix Presence's shape, with joins and leaves grouped by presence key:

```json
{
  "joins": { "user:alice": { "metas": [{ "status": "online" }] } },
  "leaves": { "user:bob": { "metas": [{ "status": "offline" }] } }
}
```

For lower-level integrations, `beryl/presence/wire.encode_diff(diff, topic)` returns the encoded JSON payload without broadcasting it. If channels are configured with PubSub, `broadcast_presence_diff` uses the same distributed delivery behavior as `beryl.broadcast`.

## Cross-node replication

When PubSub is configured, the presence actor:

1. Periodically broadcasts its full CRDT state to the `beryl:presence:sync` topic
2. Receives remote state from other nodes via PubSub
3. Merges remote state using the AWORSet merge algorithm
4. Fires `on_diff` for any changes from the merge

Self-delivery is prevented by `pubsub.broadcast_from`, so nodes don't process their own sync messages.

The underlying CRDT state is intentionally internal. Applications should use PubSub replication rather than constructing or merging raw presence state values.

## Integration with channels

A common pattern is to track presence in your channel's join handler and untrack in terminate:

```gleam
fn join(topic, payload, socket) -> JoinResult(MyAssigns) {
  let socket_id = socket.id(socket)
  let _ref = presence.track(p, topic, "user:" <> user_id, socket_id, meta)
  channel.JoinOk(reply: None, socket: socket)
}

fn terminate(reason, socket) -> Nil {
  presence.untrack_all(p, socket.id(socket))
}
```

## Next steps

- [PubSub guide](/guides/pubsub/) — required for cross-node presence replication; configure PubSub before passing it to presence config
- [Reference: Client compatibility](/reference/#client-compatibility) — Phoenix JS and other clients that can handle `presence_diff` events
- [Troubleshooting](/troubleshooting/#presence-is-stale-or-incorrect) — diagnosing stale entries, missing diffs, and cross-node sync failures
