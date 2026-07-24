---
title: Groups
description: Organize topics into named server-side collections and broadcast to all of them with one call.
---

Groups are **server-side named collections of topics**. They let you broadcast one event to many topics without tracking those topic lists yourself.

:::note[Server-side only]
Clients join ordinary topics such as `room:lobby`. Groups are a server convenience for your own code.
:::

## Starting the groups actor

```gleam
import beryl/group

let assert Ok(groups) = group.start()
```

`group.start()` returns `Result(group.Groups, group.GroupStartError)`. The only startup failure is `GroupActorStartFailed`.

## Creating and deleting groups

```gleam
// Create a group
let assert Ok(Nil) = group.create(groups, "team:engineering")

// Error: GroupAlreadyExists if the name is taken
case group.create(groups, "team:engineering") {
  Ok(Nil) -> Nil
  Error(group.GroupAlreadyExists) -> Nil
  Error(_) -> Nil
}

// Delete a group (removes it and all topic memberships)
let assert Ok(Nil) = group.delete(groups, "team:engineering")
```

## Adding and removing topics

Groups store plain topic strings. They do not care whether a topic currently has subscribers.

```gleam
let assert Ok(Nil) = group.add(groups, "team:engineering", "room:frontend")
let assert Ok(Nil) = group.add(groups, "team:engineering", "room:backend")
let assert Ok(Nil) = group.add(groups, "team:engineering", "room:infra")

let assert Ok(Nil) = group.remove(groups, "team:engineering", "room:infra")
```

Adding the same topic twice is a no-op because groups store topics in a set.

## Inspecting groups

```gleam
import gleam/set

case group.topics(groups, "team:engineering") {
  Ok(topic_set) -> set.to_list(topic_set)
  Error(group.GroupNotFound) -> []
  Error(_) -> []
}

let names = group.list_groups(groups)
```

## Broadcasting to a group

`group.broadcast` sends through `beryl.broadcast` for every topic in the named group.

```gleam
import beryl
import gleam/json

group.broadcast(
  groups,
  sockets,
  "team:engineering",
  "deploy_started",
  json.object([#("env", json.string("production"))]),
)
```

Signature shape:

```gleam
pub fn broadcast(
  groups: group.Groups,
  sockets: beryl.Sockets,
  group_name: String,
  event: String,
  payload: json.Json,
) -> Nil
```

Missing groups are a silent no-op.

## Starting groups alongside Beryl

Groups are **independent** of the Beryl runtime subtree. Start them separately, then use the handle anywhere you already have `beryl.Sockets`.

```gleam
import beryl
import beryl/socket
import beryl/group
import beryl/wire

fn init(_info: socket.ConnectInfo(Nil)) -> #(Nil, List(socket.Effect)) {
  #(Nil, [])
}

fn update(model: Nil, _event: socket.Input(Nil)) -> socket.Next(Nil, Nil) {
  socket.Next(model, [])
}

let assert Ok(groups) = group.start()
let assert Ok(sockets) =
  beryl.start(beryl.config(wire.phoenix_codec()), init: init, update: update)

let assert Ok(Nil) = group.create(groups, "team:eng")
let assert Ok(Nil) = group.add(groups, "team:eng", "room:frontend")

group.broadcast(groups, sockets, "team:eng", "alert", payload)
```

If your application supervises groups, do that in your own tree. They are not part of the Beryl subtree returned by `beryl.start` or `beryl.child_spec`.

## Error reference

| Error | When |
|-------|------|
| `GroupAlreadyExists` | `create` called for a name already in use |
| `GroupNotFound` | `delete`, `add`, `remove`, or `topics` called for an unknown group |
| `GroupActorStartFailed` | `group.start()` could not start the actor |

## Next steps

- [App-Side Dispatch](/guides/dispatch/) — route joins and messages, then call `group.broadcast` from your own app logic
- [Backend Integration](/guides/backend-integration/) — publish into Beryl from ordinary HTTP handlers and background processes
- [Supervision](/guides/supervision/) — understand which processes Beryl owns and which ones, like groups, stay application-owned
