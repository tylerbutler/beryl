---
title: Groups
---

Groups are **server-side named collections of topics**. They let you broadcast a single event to many topics at once without tracking subscriptions yourself — similar to Socket.IO rooms or SignalR groups, but adapted to beryl's topic/channel model.

:::note[Server-side only]
Groups are a server concern. Clients join individual topics via `phx_join`; they have no concept of groups. Groups exist purely to make multi-topic server broadcasts convenient.
:::

## Starting the groups actor

```gleam
import beryl/group

let assert Ok(groups) = group.start()
```

`group.start()` returns `Result(Groups, GroupError)`. The only failure case is `StartFailed` — an OTP actor spawn failure.

## Creating and deleting groups

```gleam
// Create a group
let assert Ok(Nil) = group.create(groups, "team:engineering")

// Error: AlreadyExists if the name is taken
case group.create(groups, "team:engineering") {
  Ok(Nil) -> Nil
  Error(group.AlreadyExists) -> Nil  // already there
  Error(_) -> Nil
}

// Delete a group (removes it and all its topic memberships)
let assert Ok(Nil) = group.delete(groups, "team:engineering")

// Error: NotFound if it doesn't exist
case group.delete(groups, "team:gone") {
  Ok(Nil) -> Nil
  Error(group.NotFound) -> Nil
  Error(_) -> Nil
}
```

## Adding and removing topics

Topics are plain strings that match existing channel topics. Groups do not validate that a topic has any subscribers — they are just sets of strings.

```gleam
let assert Ok(Nil) = group.add(groups, "team:engineering", "room:frontend")
let assert Ok(Nil) = group.add(groups, "team:engineering", "room:backend")
let assert Ok(Nil) = group.add(groups, "team:engineering", "room:infra")

// Remove one topic
let assert Ok(Nil) = group.remove(groups, "team:engineering", "room:infra")

// Both add and remove return Error(NotFound) if the group doesn't exist
```

Adding the same topic twice is a no-op (topics are stored in a set).

## Inspecting groups

```gleam
// List all topics in a group
case group.topics(groups, "team:engineering") {
  Ok(topic_set) -> set.to_list(topic_set)  // ["room:frontend", "room:backend"]
  Error(group.NotFound) -> []
  Error(_) -> []
}

// List all group names
let names = group.list_groups(groups)  // ["team:engineering", "team:design"]
```

## Broadcasting to a group

`group.broadcast` sends an event to every topic in the named group using `beryl.broadcast` internally. It is **fire-and-forget**: the return type is `Nil`, not `Result`. If the named group does not exist, the call silently does nothing.

```gleam
group.broadcast(
  groups,
  channels,
  "team:engineering",
  "deploy_started",
  json.object([#("env", json.string("production"))]),
)
```

This is equivalent to calling `beryl.broadcast` on each topic in the group in sequence.

:::note[Missing group is a no-op]
`group.broadcast` never returns an error. Broadcasting to a group that does not exist (or has no topics) silently does nothing. If you need to confirm a group exists before broadcasting, call `group.topics` first and handle `NotFound`.
:::

## Error reference

| Error | When |
|-------|------|
| `AlreadyExists` | `create` called for a name already in use |
| `NotFound` | `delete`, `add`, `remove`, or `topics` called for an unknown group name |
| `StartFailed` | `group.start()` — the OTP actor failed to initialize |

## Full example: team rooms

```gleam
import beryl
import beryl/group
import gleam/json

// At startup
let assert Ok(groups) = group.start()
let assert Ok(Nil) = group.create(groups, "team:eng")
let assert Ok(Nil) = group.add(groups, "team:eng", "room:frontend")
let assert Ok(Nil) = group.add(groups, "team:eng", "room:backend")

// Later: broadcast deployment notice to all engineering rooms
group.broadcast(
  groups,
  channels,
  "team:eng",
  "deploy_complete",
  json.object([
    #("version", json.string("1.4.2")),
    #("deployed_by", json.string("ci")),
  ]),
)

// When a team is disbanded
let assert Ok(Nil) = group.delete(groups, "team:eng")
```

## Using groups with the supervisor

When using `beryl/supervisor`, set `groups: True` in `SupervisedConfig` and access the groups handle from the returned `SupervisedChannels`:

```gleam
import beryl
import beryl/supervisor
import beryl/wire
import gleam/option.{None}

let config = supervisor.SupervisedConfig(
  channels: beryl.config(wire.phoenix_codec()),
  presence: None,
  groups: True,
)
let assert Ok(supervised) = supervisor.start(config)

// supervised.groups is Option(group.Groups)
case supervised.groups {
  Some(g) -> group.broadcast(g, supervised.channels, "team:eng", "alert", payload)
  None -> Nil
}
```

See the [Supervision guide](/guides/supervision) for details on the supervised startup pattern.
