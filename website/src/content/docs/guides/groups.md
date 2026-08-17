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

`group.start()` returns `Result(Groups, GroupStartError)`. The only failure case is `GroupActorStartFailed` — an OTP actor spawn failure.

## Creating and deleting groups

```gleam
// Create a group
let assert Ok(Nil) = group.create(groups, "team:engineering")

// Error: GroupAlreadyExists if the name is taken
case group.create(groups, "team:engineering") {
  Ok(Nil) -> Nil
  Error(group.GroupAlreadyExists) -> Nil  // already there
  Error(_) -> Nil
}

// Delete a group (removes it and all its topic memberships)
let assert Ok(Nil) = group.delete(groups, "team:engineering")

// Error: GroupNotFound if it doesn't exist
case group.delete(groups, "team:gone") {
  Ok(Nil) -> Nil
  Error(group.GroupNotFound) -> Nil
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

// Both add and remove return Error(GroupNotFound) if the group doesn't exist
```

Adding the same topic twice is a no-op (topics are stored in a set).

## Inspecting groups

```gleam
// List all topics in a group
case group.topics(groups, "team:engineering") {
  Ok(topic_set) -> set.to_list(topic_set)  // ["room:frontend", "room:backend"]
  Error(group.GroupNotFound) -> []
  Error(_) -> []
}

// List all group names
let names = group.list_groups(groups)  // ["team:engineering", "team:design"]
```

## Broadcasting to a group

`group.broadcast` looks up the group's topics through the groups actor, then sends an event to every topic using `beryl.broadcast` in the caller's process. The lookup provides backpressure without making the actor perform fan-out. The return type is `Nil`, not `Result`. If the named group does not exist, the call silently does nothing.

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
`group.broadcast` never returns an error. Broadcasting to a group that does not exist (or has no topics) silently does nothing. Like other group operations, it panics if the groups actor is unavailable or does not reply within 5 seconds. If you need to confirm a group exists before broadcasting, call `group.topics` first and handle `GroupNotFound`.
:::

## Error reference

| Error | When |
|-------|------|
| `GroupAlreadyExists` | `create` called for a name already in use |
| `GroupNotFound` | `delete`, `add`, `remove`, or `topics` called for an unknown group name |
| `GroupActorStartFailed` | `group.start()` — the internal group actor failed to initialize |

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

## Lifecycle

The groups actor is a plain OTP actor linked to the process that calls `group.start()` — start it from your long-lived application process alongside `beryl.child_spec`. A `start_named` variant registers the actor under a `process.Name` for callers integrating it into their own supervision arrangements.

See the [Supervision guide](/guides/supervision) for the overall startup pattern.
