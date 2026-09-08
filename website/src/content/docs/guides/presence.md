---
title: Presence
description: Track connected users, publish Phoenix-compatible updates, and replicate presence across nodes.
---

beryl can track connected users and their metadata. It uses a
`lattice_presence` conflict-free replicated data type (CRDT), which merges
concurrent changes from Erlang nodes without a central coordinator.

To see the join, track, diff, and leave flow before you read about it, open
the [live presence lab](/examples/#live-presence-lab) on the examples page.

## How beryl tracks presence

Presence uses an **add-wins observed-remove set** (AWORSet) with causal context.
When a user joins or leaves, nodes merge their state without coordination. The
system does not need a leader or consensus.

The presence API has two main parts:

1. **`beryl/presence`**: an OTP actor that manages the CRDT and PubSub replication
2. **`beryl/presence.Diff`**: a change value for `on_diff`, with functions that read changed topics, joins, and leaves

## Starting presence

```gleam
import beryl/presence
import beryl/pubsub
import gleam/otp/static_supervisor

// Without PubSub (single-node only)
let #(presence_handle, presence_specification) =
  presence.child_spec(presence.default_config("node1"))

// With PubSub for cross-node replication
let pubsub_handle = pubsub.start(pubsub.default_config())
let config =
  presence.default_config("node1")
  |> presence.with_pubsub(pubsub_handle)
  |> presence.with_broadcast_interval(1500)
let #(presence_handle, presence_specification) = presence.child_spec(config)

let assert Ok(_root) =
  static_supervisor.new(static_supervisor.OneForOne)
  |> static_supervisor.add(presence_specification)
  |> static_supervisor.start()
```

Presence mutations wait up to 5 seconds for the actor by default. Use
`with_call_timeout` to configure their timeout:

```gleam
let config =
  presence.default_config("node1")
  |> presence.with_call_timeout(10_000)
let #(presence_handle, presence_specification) = presence.child_spec(config)
let assert Ok(_root) =
  static_supervisor.new(static_supervisor.OneForOne)
  |> static_supervisor.add(presence_specification)
  |> static_supervisor.start()
```

`track`, `update`, `untrack`, and `untrack_all` panic if the actor is
unavailable or does not reply within this timeout. Presence reads bypass the
actor mailbox and do not use it.

## Track connected users

Track a user's presence when they join a channel:

```gleam
import gleam/json

// Track a user in a topic
let ref = presence.track(
  presence_handle,
  "room:lobby",   // topic
  "user:alice",    // key (groups multiple connections)
  socket_id,       // session ID (unique per connection)
  json.object([    // metadata
    #("status", json.string("online")),
    #("joined_at", json.int(1234567890)),
  ]),
)
```

The **key** groups connections from one user. The **session ID** identifies one
connection and is usually the socket ID.

## Updating metadata

Replace one presence entry's metadata without removing its key from the roster:

```gleam
let assert Ok(new_ref) =
  presence.update(
    presence_handle,
    ref,
    json.object([#("status", json.string("away"))]),
  )
```

`update` emits the old ref's leave and the new ref's join in one diff, while
leaving other refs for the same key unchanged. Keep the returned ref for the
next `update` or `untrack`; the previous ref becomes stale. An unknown, removed,
or non-public ref returns `Error(presence.UnknownRef(ref))`.

## Remove presence entries

```gleam
// Remove a specific presence, using the ref returned by `track`
presence.untrack(presence_handle, new_ref)

// Remove all presences for a session ID / socket (e.g., on disconnect)
presence.untrack_all(presence_handle, socket_id)
```

`track` returns a ref for the new presence entry. Keep the ref if you must
remove that entry with `untrack`. To clear all entries for a disconnected
socket, call `untrack_all` with the session ID. The `session_id` string
identifies the logical session, not a BEAM process.

## Read presence

```gleam
// Get all presences in a topic
let assert Ok(entries) = presence.list(presence_handle, "room:lobby")
// Returns: [PresenceEntry(session_id: "socket_1", key: "user:alice", meta: ...)]

// Get presences for a specific key
let assert Ok(alice_sessions) =
  presence.get_by_key(presence_handle, "room:lobby", "user:alice")
// Returns: [#("socket_1", meta), #("socket_2", meta)]

// Count without materializing the entry list
let assert Ok(online_count) = presence.count(presence_handle, "room:lobby")
```

`list`, `get_by_key`, and `count` read a snapshot from an ETS table owned by the
actor. They do not wait in the actor mailbox. Synchronous changes update the
snapshot before replying, so the next read sees the change. `count` reads a
stored count in O(1).

The table lifetime follows the actor. Before startup, after the actor stops, or
during the brief window before a supervisor starts its replacement,
`list`, `get_by_key`, and `count` return `Error(Nil)` rather than a misleading
empty result. Other presence actors own independent tables and remain
unaffected.

Both the stable actor name and the read model's ETS table are node-local, so a
`Presence` handle must stay on the node where its child specification runs.
From another BEAM node, `track`/`update`/`untrack`/`untrack_all` cannot reach
the owning actor and panic as unavailable, while `list`/`get_by_key`/`count`
return `Error(Nil)`. Use PubSub replication (`with_pubsub`) to share presence
state across nodes instead of moving the handle itself.

The handle is backed by stable process and ETS names, so it reaches the
replacement actor and read model after a supervised restart. Presence entries
and tracking refs are in-memory state and reset on restart; connected clients
must re-track their presence.

## Handle presence changes

Use `on_diff` to receive presence changes.

The presence actor calls the callback for local changes and remote merges. It
calls the function before it publishes new read-model snapshots and before it
replies to the source call. If the callback calls `list`, `get_by_key`, or
`count` for an affected topic, it reads the previous snapshot. Read the change
from the `Diff` argument with `diff_joins` and `diff_leaves`. Keep the callback
short. A slow callback delays snapshot publication, the source call reply, and
later actor messages.

```gleam
let config =
  presence.default_config("node1")
  |> presence.with_pubsub(pubsub_handle)
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

The actor calls `on_diff` after a local change or a remote merge produces a
non-empty diff. It calls the function for each change, so rapid changes do not
lose diffs.

## Send Phoenix-compatible `presence_diff` events

Use `beryl.broadcast_presence_diff` to send a `presence_diff` event to sockets
on the changed topic:

```gleam
import beryl

let config =
  presence.default_config("node1")
  |> presence.with_pubsub(pubsub_handle)
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

For direct integrations, `beryl/presence/wire.encode_diff(diff, topic)`
returns the encoded JSON payload without broadcasting it. If channels use
PubSub, `broadcast_presence_diff` uses the same cross-node delivery as
`beryl.broadcast`.

## Replicate presence across nodes

When you configure PubSub, the presence actor:

1. Sends its full CRDT state to `beryl:presence:sync` at set intervals.
2. Receives remote state from other nodes through PubSub.
3. Merges remote state with the AWORSet merge algorithm.
4. Calls `on_diff` for changes from the merge.

Self-delivery is prevented by `pubsub.broadcast_from`, so nodes don't process their own sync messages.

The underlying CRDT state is intentionally internal. Applications should use PubSub replication rather than constructing or merging raw presence state values.

## Use presence from raw dispatch

Start and supervise the standalone presence actor, then attach its handle with
`beryl.with_presence_handle`. In `update`, use presence effects rather than
calling the synchronous public mutation functions:

```gleam
socket.Join(topic, _payload, ref) ->
  socket.Next(model, [
    socket.AcceptJoin(ref, option.None),
    socket.PresenceTrack(topic, model.user_id, meta),
    socket.BroadcastPresence(topic, "presence_list", encode_presence),
  ])

socket.Message(topic, "offline", _payload, _ref) ->
  socket.Next(model, [
    socket.PresenceUntrack(topic, model.user_id),
    socket.BroadcastPresence(topic, "presence_list", encode_presence),
  ])
```

The runtime sends each mutation asynchronously and suspends only that socket
until presence acknowledges that the CRDT and ETS read model are current. The
rest of the effect list then resumes in order, so the snapshot above sees the
track or untrack it follows. Other sockets, broadcasts, heartbeats, and
shutdown handling continue while one socket waits.

With `beryl/channel`, use the corresponding
`channel.presence_track`, `presence_untrack`, `push_presence`, and
`broadcast_presence` actions. They convert to the same effects, preserve the
same order, and wait for asynchronous presence changes.

The runtime owns refs created by `PresenceTrack` and automatically removes any
remaining refs when the topic closes. Public synchronous `presence.track`
calls remain available to application actors and code outside the socket runtime;
their refs are independently addressable and are not part of runtime cleanup.
Repeating `PresenceTrack` for the same topic and key replaces the runtime-owned
metadata atomically. Code outside the socket runtime should use
`presence.update` with the
ref returned by `presence.track`.

## Next steps

- [PubSub guide](/guides/pubsub/): configure PubSub for cross-node presence replication
- [Client compatibility](/reference/#client-compatibility): clients that handle `presence_diff` events
- [Troubleshooting](/troubleshooting/#presence-is-stale-or-incorrect): diagnose stale entries, missing diffs, and cross-node synchronization failures
