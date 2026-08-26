---
title: Presence
---

## How presence stores changes

beryl presence uses an OTP actor and
[`lattice_presence/presence_state`](https://hex.pm/packages/lattice_presence).
an **add-wins, observed-remove conflict-free replicated data type (CRDT)**.
Each cluster node keeps one copy. Nodes can merge their copies in any order.
Joins and leaves that happen at the same time produce the same final result.

Each tracked entry has a **replica name**, set by the `replica` argument to
`default_config/1`. Use a unique name for each cluster node. The CRDT uses this
name to identify remote state.

## Add presence to an app

The application builds the presence actor with `presence.child_spec`. Add the
child to the supervision tree. Then pass its handle to `beryl.Config` with
`with_presence_handle`.

Raw dispatch uses `PresenceTrack`, `PresenceUntrack`, `PushPresence`, and
`BroadcastPresence` effects. The runtime sends mutations to the presence actor. The actor acknowledges a
mutation after it updates the CRDT and ETS read model. Until then, the runtime
pauses later effects and inputs for that socket. Other sockets, broadcasts,
heartbeats, and shutdown work continue.

Snapshot effects read the actor-owned ETS model directly, so they do not wait
on the actor mailbox. Re-tracking a runtime-owned key is one atomic
leave-plus-join transition, and topic close cleans up that socket's remaining
runtime refs in one batch. Tracking refs resolve to exact local CRDT tags, so a
late runtime acknowledgement cannot remove an independently owned public
`presence.track` entry with the same session, topic, and key.

The public `track`, `untrack`, and `untrack_all` APIs remain synchronous for
application actors and other out-of-band workflows. Public `list`,
`get_by_key`, and `count` calls read ETS directly and retain immediate
read-after-write behavior.

## Presence functions

### Starting presence

| Function | Description |
|---|---|
| `child_spec(config)` | Return a stable presence handle and its supervised child specification |

The handle keeps working after an actor restart on the same node. The process
and ETS read model use stable names. The replacement actor starts with empty
in-memory CRDT state and tracking refs. The handle works only on its node.
PubSub copies presence state between nodes.

### Configuration builders

| Function | Description |
|---|---|
| `default_config(replica)` | Create a config with no PubSub and a 1500 ms interval that remains unused until PubSub is attached |
| `with_pubsub(config, ps)` | Attach a PubSub instance for cross-node state replication |
| `with_broadcast_interval(config, ms)` | Set how often (in ms) the actor broadcasts its CRDT state; `0` disables |
| `with_on_diff(config, callback)` | Register a callback invoked whenever a local change or merge produces a non-empty diff |

### Tracking

| Function | Description |
|---|---|
| `track(presence, topic, key, session_id, meta)` | Add a presence entry; returns a server-generated tracking ref for later `untrack` |
| `untrack(presence, ref)` | Remove one tracked entry by the ref returned from `track` |
| `untrack_all(presence, session_id)` | Remove all entries for a session id |

### Querying

| Function | Description |
|---|---|
| `list(presence, topic)` | Return all `PresenceEntry` values for a topic |
| `get_by_key(presence, topic, key)` | Return `{session_id, meta}` pairs for a specific key within a topic |

### Diff helpers

`on_diff` callbacks receive an opaque `Diff`. Use these accessors:

| Function | Description |
|---|---|
| `diff(joins, leaves)` | Construct a diff from topic-grouped join and leave lists |
| `diff_topics(diff)` | List every topic touched by this diff |
| `diff_joins(diff, topic)` | Get joined entries for a topic |
| `diff_leaves(diff, topic)` | Get departed entries for a topic |

## Sync between nodes

When you configure `with_pubsub`, the presence actor runs a broadcast loop at
the configured interval, which defaults to 1500 ms:

1. On each tick, the actor checks the `dirty` value. If local state changed,
   it sends `SyncPayload(v, sender, state)` to `"beryl:presence:sync"`.
   `broadcast_from` prevents self-delivery.
2. Remote replicas receive the typed payload through PubSub. They merge it with
   `state.merge_with_diff` and update their CRDT state.
3. If the merge changes membership, the actor calls `on_diff` with the
   resulting `Diff`. It calls the function for each merge, so rapid merges do
   not lose diffs.

Use `with_broadcast_interval(0)` to disable periodic broadcasts. Without
PubSub, the configured interval is unused.

Automated tests currently exercise replication with multiple presence actors
on one BEAM node. [Issue #365](https://github.com/tylerbutler/beryl/issues/365)
tracks integration coverage across separate distributed Erlang nodes.

## Request and sync flow

```mermaid
sequenceDiagram
  participant App as app update
  participant Runtime as runtime
  participant Pres as presence actor
  participant Read as ETS read model
  participant PS as pubsub
  participant Remote as remote replica
  App->>Runtime: PresenceTrack / PresenceUntrack / PushPresence / BroadcastPresence
  Runtime->>Pres: track / untrack (async, acknowledged)
  Pres->>Read: publish touched topics
  Pres-->>Runtime: mutation ack
  Runtime->>Read: list / count (direct read)
  loop every broadcast_interval
    Pres->>PS: broadcast CRDT state
  end
  Remote->>PS: its state
  PS-->>Pres: remote state
  Pres->>Pres: merge -> diff
  Pres-->>App: on_diff(diff)
```

## Source files

| File | Role |
|---|---|
| `packages/beryl/src/beryl/presence.gleam` | OTP actor, public API, CRDT wiring, PubSub subscription and broadcast |
| `packages/beryl/src/beryl/presence/wire.gleam` | Wire helpers for encoding and decoding presence diffs over the channel protocol |
