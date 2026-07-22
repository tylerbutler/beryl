---
title: beryl/presence
description: Presence - Distributed presence tracking backed by a CRDT
---

Presence - Distributed presence tracking backed by a CRDT

 Wraps the pure `lattice_presence/presence_state` CRDT in an OTP actor that:
 - Handles track/untrack calls
 - Periodically broadcasts state via PubSub for cross-node replication
 - Receives remote state from PubSub and merges it internally
 - Invokes `on_diff` callback when merges produce non-empty diffs

 ## Example

 ```gleam
 let ps = pubsub.start(pubsub.default_config())
 let config =
   presence.default_config("node1")
   |> presence.with_pubsub(ps)
   |> presence.with_broadcast_interval(1500)
 let assert Ok(p) = presence.start(config)
 let ref = presence.track(p, "room:lobby", "user:1", "socket-1", meta)
 let entries = presence.list(p, "room:lobby")
 ```

## Types

### `Config`

Configuration for starting presence.

 Build configs with `default_config` and the `with_*` functions so Beryl can
 add future options without exposing record fields as public API.

```gleam
pub type Config
```

### `Diff`

An opaque diff representing presence joins and leaves grouped by topic.

 This is passed to `Config.on_diff` and accepted by
 `beryl.broadcast_presence_diff`.

```gleam
pub type Diff
```

### `Message`

Messages the presence actor handles

```gleam
pub type Message
```

### `Presence`

A running Presence instance.

 This handle is intentionally opaque so callers cannot forge actor subjects
 or depend on the runtime representation.

```gleam
pub type Presence
```

### `PresenceEntry`

A presence entry returned from queries and diff accessors.

 This type is intentionally transparent so callers can inspect query results
 and construct entries for `diff`.

```gleam
pub type PresenceEntry {
  PresenceEntry(
    session_id: String,
    key: String,
    meta: json.Json
  )
}
```

### `PresenceError`

Errors from presence operations

```gleam
pub type PresenceError {
  PresenceStartFailed(error.StartFailure)
}
```

#### Constructors

##### `PresenceStartFailed(error.StartFailure)`

The presence actor failed to start.

## Functions

### `default_config`

Default configuration (no PubSub).

 The broadcast interval defaults to 1500 ms so that adding `with_pubsub`
 yields working two-way replication out of the box; without PubSub the
 interval is unused. Use `with_broadcast_interval(0)` to disable periodic
 broadcasts and control replication manually.

```gleam
pub fn default_config(String) -> Config
```

### `diff`

Build a presence diff from topic-grouped joins and leaves.

 Most applications receive diffs from `Config.on_diff`; this helper is for
 callers that need to construct a diff to pass to `beryl.broadcast_presence_diff`.

```gleam
pub fn diff(
  joins: List(#(String, List(PresenceEntry))),
  leaves: List(#(String, List(PresenceEntry)))
) -> Diff
```

### `diff_joins`

Get presence joins for a topic in this diff.

```gleam
pub fn diff_joins(
  Diff,
  String
) -> List(PresenceEntry)
```

### `diff_leaves`

Get presence leaves for a topic in this diff.

```gleam
pub fn diff_leaves(
  Diff,
  String
) -> List(PresenceEntry)
```

### `diff_topics`

List topics touched by this diff.

```gleam
pub fn diff_topics(Diff) -> List(String)
```

### `get_by_key`

Get presences for a specific key within a topic

 Panics if the presence actor is unavailable or does not reply within 5 seconds.

```gleam
pub fn get_by_key(
  Presence,
  String,
  String
) -> List(#(String, json.Json))
```

### `list`

List all presences for a topic

 Panics if the presence actor is unavailable or does not reply within 5 seconds.

```gleam
pub fn list(
  Presence,
  String
) -> List(PresenceEntry)
```

### `start`

Start the presence actor

```gleam
pub fn start(Config) -> Result(Presence, PresenceError)
```

### `track`

Track a presence in a topic.

 `session_id` identifies the session (e.g. socket) that owns this presence
 and is the value `untrack_all` matches on when the session disconnects.

 Returns a server-generated tracking ref: an opaque, unique handle for this
 specific presence. Pass it to `untrack` to remove exactly this entry later.
 The ref is not the session id — it is minted by the presence actor and is
 only meaningful to that actor. The ref is also merged into object metas as
 `phx_ref` for Phoenix client compatibility.

 Panics if the presence actor is unavailable or does not reply within 5 seconds.

```gleam
pub fn track(
  Presence,
  String,
  String,
  String,
  json.Json
) -> String
```

### `untrack`

Untrack a specific presence using the ref returned by `track`.

 Removing an unknown or already-removed ref is a harmless no-op.

 Panics if the presence actor is unavailable or does not reply within 5 seconds.

```gleam
pub fn untrack(
  Presence,
  String
) -> Nil
```

### `untrack_all`

Untrack all presences for a session (e.g., when a socket disconnects)

 Panics if the presence actor is unavailable or does not reply within 5 seconds.

```gleam
pub fn untrack_all(
  Presence,
  String
) -> Nil
```

### `with_broadcast_interval`

Set how often presence state is broadcast for replication.

 Use `0` to disable periodic broadcasts.

```gleam
pub fn with_broadcast_interval(
  Config,
  Int
) -> Config
```

### `with_on_diff`

Set the callback invoked when local changes or remote merges produce a diff.

```gleam
pub fn with_on_diff(
  Config,
  fn(Diff) -> Nil
) -> Config
```

### `with_pubsub`

Enable PubSub replication for presence.

```gleam
pub fn with_pubsub(
  Config,
  pubsub.PubSub(SyncPayload)
) -> Config
```
