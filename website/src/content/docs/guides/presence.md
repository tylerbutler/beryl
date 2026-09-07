---
title: Presence
description: Track connected users, publish Phoenix-compatible updates, and replicate presence across nodes.
---

beryl can track connected users and their metadata. It uses a
`lattice_presence` conflict-free replicated data type (CRDT), which merges
concurrent changes from Erlang nodes without a central coordinator.

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

## Add presence to a channel

`channel.with_presence` is a shorthand for the existing track and snapshot
actions. It saves you from choosing the Phoenix event name and encoder for
each channel. It does not add a new presence lifecycle or component system.

Start and supervise a presence actor as shown above, then attach its handle to
the channel system's config with `beryl.with_presence_handle`. Use
`channel.with_presence` on an accepted join:

```gleam
import beryl/channel
import gleam/json

pub fn room() -> channel.Handler {
  channel.handler("room:*", fn(context) {
    channel.accept(Nil)
    |> channel.with_presence(
      key: context.socket_id,
      meta: json.object([#("status", json.string("online"))]),
    )
  })
}
```

The builder tracks this connection on the joined topic, then sends it a
Phoenix-compatible `presence_state` snapshot. Use an authenticated user ID as
the key to group that user's connections under one roster entry. Each
connection has its own metadata and tracking ref.

### Equivalent actions

`channel.with_presence(key: key, meta: meta)` adds exactly these actions:

```gleam
import beryl/presence/wire as presence_wire

channel.accept(state)
|> channel.with_actions([
  channel.presence_track(key, meta),
  channel.push_presence("presence_state", presence_wire.encode_state),
])
```

Both forms use the same tracking, diff delivery, and automatic cleanup.
Existing channels that assemble these actions do not need to change. Keep
the explicit actions when you need a custom snapshot event name or encoder.

### Lifecycle and updates

The runtime sends the join acknowledgment first. Tracking emits a
`presence_diff`, which can arrive before the snapshot; Phoenix Presence
clients buffer these diffs until `presence_state`. The runtime removes this
connection's tracked entries when the topic closes or the socket disconnects.
No `on_terminate` callback is needed for presence cleanup.

To change metadata, return `channel.presence_track(key, new_meta)` from a
callback with the same key. To stop tracking while the channel stays joined,
return `channel.presence_untrack(key)`. State changes alone do not update
presence. Add `channel.on_presence` to react to changes on the server.

`with_presence` appends to existing join actions and leaves rejected joins
unchanged. It requires the same presence handle as other presence actions;
without one, the runtime logs warnings and skips tracking and the snapshot.
It does not reserve capacity: a presence count followed by a track is not an
atomic room-limit check.

## React to presence changes in a channel

`channel.on_presence` gives a channel its topic's initial roster, then sends
joins, leaves, and metadata changes to the same callback. It runs in the
channel worker with the channel's private state, not in the shared presence
actor.

```gleam
import beryl/presence
import gleam/list

pub fn observed_room() -> channel.Handler {
  channel.handler("room:*", fn(_context) {
    channel.accept(0)
    |> channel.on_presence(fn(online_sessions, event) {
      let next = case event {
        presence.Snapshot(entries) -> list.length(entries)
        presence.Changed(joins, leaves) ->
          online_sessions + list.length(joins) - list.length(leaves)
      }
      channel.next(next, [
        channel.push("online_sessions", json.int(next)),
      ])
    })
  })
}
```

This example counts connections, not distinct users. It observes without
tracking itself. Add `with_presence` to track the connection as well; either
builder order works. Neither builder creates an extra process.

### Snapshot and change ordering

The actor registers the subscription and captures its snapshot in one turn.
The callback receives one `Snapshot`, even when the topic is empty, followed
by non-empty `Changed` events. Changes cannot fall between registration and
the snapshot. Ordinary message and info callbacks wait until the initial
callback's effects finish. The join reply and existing join actions keep
their wire order.

Events contain only this topic's entries, including changes from this
connection. When combined with `with_presence`, the connection's initial
track can be in the snapshot or a later change, depending on actor ordering.
It is not counted twice.

A metadata update is one change with the old entry in `leaves` and the new
entry in `joins`. Apply leaves before joins when maintaining a roster. A user
key can have several sessions, and each session retains its own metadata.

The stream includes standalone presence mutations and committed remote
merges. It reflects the local replica, not a globally consistent cluster
roster or every intermediate mutation on a remote node. Separate calls to
`presence.list` can see a newer state than the current callback event.

:::caution[Avoid update loops]
A callback that returns `presence_track` can trigger another presence
callback. Change metadata only when needed; do not write it unconditionally
in response to every presence event.
:::

### Failure and cleanup

`on_presence` requires a configured presence handle. Without one, the join is
rejected. A source exit, subscription timeout, callback panic, or full pending
queue closes only the affected topic with `phx_error`. Rejoin to obtain a
fresh snapshot. A stable handle does not reconnect an existing observer to a
replacement presence actor.

The runtime allows one outstanding callback event and up to 64 pending change
batches per observer. It returns credit after the callback's effects finish,
including asynchronous presence effects. It does not silently drop changes
when the queue fills. This limit bounds batches, not bytes: applications must
still limit large rosters and metadata values.

Subscription startup has a five-second timeout. This is not a callback
execution timeout. Callback failures use the existing topic termination path.

The runtime removes subscriptions on topic close and monitors workers to
clean up after abrupt exits. Events from an old join cannot reach a later
join. No `on_terminate` cleanup is needed for the subscription.

This API does not replace `presence.with_on_diff`. That callback still runs
in the presence actor before read-model publication; `channel.on_presence`
receives committed changes asynchronously in each observing worker.

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
