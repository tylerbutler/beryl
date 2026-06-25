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
 let assert Ok(ps) = pubsub.start(pubsub.default_config())
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

 Build with `default_config` and the `with_*` functions so Beryl can
 add future options without exposing record fields as public API.

```gleam
pub opaque type Config
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
pub opaque type Presence
```

### `PresenceEntry`

A presence entry returned from queries and diff accessors.

```gleam
pub type PresenceEntry {
  PresenceEntry(
    pid: String,
    key: String,
    meta: json.Json
  )
}
```

### `PresenceError`

Errors from presence operations

```gleam
pub type PresenceError {
  StartFailed(actor.StartError)
}
```

#### Constructors

##### `StartFailed(actor.StartError)`

The actor failed to start, wrapping the underlying OTP start error

## Functions

### `default_config`

Default configuration (no PubSub, no replication)

```gleam
pub fn default_config(String) -> Config
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
  pubsub.PubSub
) -> Config
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

```gleam
pub fn get_by_key(
  Presence,
  String,
  String
) -> List(#(String, json.Json))
```

### `list`

List all presences for a topic

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

### `start_named`

Start the presence actor with a registered name (for supervision)

```gleam
pub fn start_named(
  Config,
  process.Name(Message)
) -> Result(actor.Started(process.Subject(Message)), actor.StartError)
```

### `track`

Track a presence in a topic

 Returns a reference string (the pid) that can be used to untrack later.

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

Untrack a specific presence by topic, key, and pid

```gleam
pub fn untrack(
  Presence,
  String,
  String,
  String
) -> Nil
```

### `untrack_all`

Untrack all presences for a pid (e.g., when a socket disconnects)

```gleam
pub fn untrack_all(
  Presence,
  String
) -> Nil
```
