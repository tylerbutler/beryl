---
title: Groups
---

Groups are **named topic collections on the server**. Use one group broadcast
to send an event to many topics. You do not need to track subscriptions. Groups
are similar to Socket.IO rooms and SignalR groups.

:::note[Server-side only]
Only the server uses groups. Clients join individual topics with `phx_join`.
Clients do not receive group information.
:::

## Starting the groups actor

```gleam
import beryl/group
import gleam/otp/static_supervisor

let #(groups, groups_spec) = group.child_spec()
let assert Ok(_root) =
  static_supervisor.new(static_supervisor.OneForOne)
  |> static_supervisor.add(groups_spec)
  |> static_supervisor.start()
```

`group.child_spec()` returns a stable `Groups` handle. Add its child
specification to the application supervisor before you use the handle.

Synchronous group operations wait up to 5 seconds for the actor by default.
Configure a different timeout when starting the actor:

```gleam
let config =
  group.default_config()
  |> group.with_call_timeout(10_000)
let #(groups, groups_spec) = group.child_spec_with_config(config)
let assert Ok(_root) =
  static_supervisor.new(static_supervisor.OneForOne)
  |> static_supervisor.add(groups_spec)
  |> static_supervisor.start()
```

`create`, `delete`, `add`, `remove`, `topics`, and `list_groups` panic if the
actor is unavailable or does not reply within this timeout. `broadcast` first
performs the same synchronous topic lookup, then sends each topic broadcast
without waiting for delivery.

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

Topics are strings that match channel topics. Groups do not check whether a
topic has subscribers. They store sets of strings.

```gleam
let assert Ok(Nil) = group.add(groups, "team:engineering", "room:frontend")
let assert Ok(Nil) = group.add(groups, "team:engineering", "room:backend")
let assert Ok(Nil) = group.add(groups, "team:engineering", "room:infra")

// Remove one topic
let assert Ok(Nil) = group.remove(groups, "team:engineering", "room:infra")

// Both add and remove return Error(GroupNotFound) if the group doesn't exist
```

Adding the same topic twice does nothing because the group stores a set.

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

`group.broadcast` asks the groups actor for the topic set. The calling process
then sends the event to each topic with `beryl.broadcast`. The lookup provides
backpressure, but the actor does not perform fan-out. The function returns
`Nil`, not `Result`. If the group does not exist, the function does nothing.

```gleam
group.broadcast(
  groups,
  channels,
  "team:engineering",
  "deploy_started",
  json.object([#("env", json.string("production"))]),
)
```

This has the same effect as one `beryl.broadcast` call for each group topic.

:::note[Missing group is a no-op]
`group.broadcast` does not return an error. It does nothing if the group is
missing or empty. It panics if the groups actor is unavailable or does not
reply within 5 seconds. To check a group first, call `group.topics` and handle
`GroupNotFound`.
:::

## Error reference

| Error | When |
|-------|------|
| `GroupAlreadyExists` | `create` called for a name already in use |
| `GroupNotFound` | `delete`, `add`, `remove`, or `topics` called for an unknown group name |

## Full example: team rooms

```gleam
import beryl
import beryl/group
import gleam/json
import gleam/otp/static_supervisor

// At startup
let #(groups, groups_spec) = group.child_spec()
let assert Ok(_root) =
  static_supervisor.new(static_supervisor.OneForOne)
  |> static_supervisor.add(groups_spec)
  |> static_supervisor.start()
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

Start the groups actor with `group.child_spec`. Its handle uses a stable
registered name and reaches the replacement actor after a supervised restart.
The actor keeps group definitions and topic memberships in memory. A restart
clears them.

The registered name is node-local. Keep a `Groups` handle on the node where its
child specification runs. From another BEAM node, synchronous operations cannot
reach the owning actor and panic as unavailable. `broadcast` also panics during
its synchronous topic lookup. Group definitions and memberships are not
replicated between nodes.

See the [Supervision guide](/guides/supervision) for the overall startup pattern.
