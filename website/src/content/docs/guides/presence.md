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
let ps = pubsub.start(pubsub.default_config())
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
  socket_id,       // session ID (unique per connection)
  json.object([    // metadata
    #("status", json.string("online")),
    #("joined_at", json.int(1234567890)),
  ]),
)
```

The **key** groups multiple connections from the same user. The **session ID**
uniquely identifies each connection (typically the socket ID).

## Untracking

```gleam
// Remove a specific presence, using the ref returned by `track`
presence.untrack(p, ref)

// Remove all presences for a session ID / socket (e.g., on disconnect)
presence.untrack_all(p, socket_id)
```

`track` returns a server-generated ref that identifies exactly the presence it
created. Hold onto that ref if you need to remove one specific presence later
with `untrack`. To clear every presence for a disconnecting socket, use
`untrack_all` with the session ID instead. The string `session_id` identifies
the logical session; it is not a BEAM process identifier.

## Listing presences

```gleam
// Get all presences in a topic
let entries = presence.list(p, "room:lobby")
// Returns: [PresenceEntry(session_id: "socket_1", key: "user:alice", meta: ...)]

// Get presences for a specific key
let alice_sessions = presence.get_by_key(p, "room:lobby", "user:alice")
// Returns: [#("socket_1", meta), #("socket_2", meta)]

// Count without materializing the entry list
let online_count = presence.count(p, "room:lobby")
```

`list`, `get_by_key`, and `count` read an actor-owned ETS snapshot rather than
calling through the actor mailbox, so reads remain nonblocking while the actor
is busy. Synchronous mutations publish before replying, giving immediate
read-after-write consistency. `count` reads a materialized count in O(1).

The table lifetime follows the actor: reads panic after that actor stops rather
than returning a misleading empty result. Other presence actors own independent
tables and remain unaffected.

The read model's ETS table is node-local: a `Presence` handle must stay on the node where `presence.start` created it. Sending the handle to (or otherwise calling `list`/`get_by_key`/`count` from) a process on a different BEAM node looks up a table reference that names nothing on that node, so those calls panic there too (`track`/`untrack`/`untrack_all` still work remotely, since they only need to reach the owning actor's process). Use PubSub replication (`with_pubsub`) to share presence state across nodes instead of moving the handle itself.

## Diff callbacks

Get notified immediately when presence state changes:

The callback runs synchronously on the presence actor — for both local mutations and remote merges, identically — before the affected topics' read-model snapshots are (re)published and before the triggering call replies. So if the callback reads presence state through the same handle (`list`, `get_by_key`, `count`) for a topic the diff touches, it sees the *previous* snapshot, not the one this diff is about to produce; read what you need from the `Diff` argument itself (`diff_joins`/`diff_leaves`) rather than re-reading through the handle inside the callback. Keep the callback fast: it runs on the actor process, so a slow callback delays that topic's publish, the reply to the mutating call, and anything else queued behind it in the actor's mailbox.

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
|> presence.with_on_diff(fn(diff) {
  diff
  |> presence.diff_topics
  |> list.each(fn(topic) {
    beryl.broadcast_presence_diff(channels, topic, diff)
  })
})
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

## Integration with app-side dispatch

Presence remains a standalone actor. Its public mutation and read calls are
synchronous and can wait up to five seconds, so do **not** call them from the
shared socket runtime's `init` or `update`.

Instead, send a command to an application-owned worker/actor from `update`.
That worker performs `presence.track` or `presence.untrack`, then publishes
the resulting `presence_diff`/snapshot with `beryl.broadcast` (or sends a
typed message back with `socket.notify`):

```gleam
socket.Join(topic, _payload, ref) ->
  {
    process.send(presence_worker, Track(topic, model.user_id, meta))
    socket.Next(model, [socket.AcceptJoin(ref, option.None)])
  }

socket.Closed(topic, _reason) ->
  {
    process.send(presence_worker, Untrack(topic, model.presence_ref))
    socket.Next(model, [])
  }
```

The application owns the tracking refs and cleanup. Lane B intentionally does
not expose partial synchronous presence effects on the shared runtime; the
indivisible async presence/read-model work is deferred.

## Next steps

- [PubSub guide](/guides/pubsub/) — required for cross-node presence replication; configure PubSub before passing it to presence config
- [Reference: Client compatibility](/reference/#client-compatibility) — Phoenix JS and other clients that can handle `presence_diff` events
- [Troubleshooting](/troubleshooting/#presence-is-stale-or-incorrect) — diagnosing stale entries, missing diffs, and cross-node sync failures
