---
title: beryl/group
description: Channel Groups - Named collections of topics for multi-topic broadcasting
---

Channel Groups - Named collections of topics for multi-topic broadcasting

 Groups let you organize topics and broadcast to all of them at once.
 Useful for scenarios like broadcasting to all channels in a "team" or
 sending a system-wide notification.

 ## Example

 ```gleam
 let assert Ok(groups) = group.start()
 let assert Ok(Nil) = group.create(groups, "team:engineering")
 let assert Ok(Nil) = group.add(groups, "team:engineering", "room:frontend")
 let assert Ok(Nil) = group.add(groups, "team:engineering", "room:backend")
 group.broadcast(groups, channels, "team:engineering", "announce", payload)
 ```

## Types

### `GroupError`

Errors from group operations

```gleam
pub type GroupError {
  GroupAlreadyExists
  GroupNotFound
}
```

#### Constructors

##### `GroupAlreadyExists`

The group already exists

##### `GroupNotFound`

The group was not found

### `Groups`

A running Groups instance.

 This handle is intentionally opaque so callers cannot forge the backing
 actor subject or depend on its runtime representation.

```gleam
pub type Groups
```

### `GroupStartError`

Errors when starting the groups actor.

```gleam
pub type GroupStartError {
  GroupActorStartFailed(error.StartFailure)
}
```

#### Constructors

##### `GroupActorStartFailed(error.StartFailure)`

The actor failed to start

### `Message`

Messages the groups actor handles

```gleam
pub type Message
```

## Functions

### `add`

Add a topic to a group

 Panics if the groups actor is unavailable or does not reply within 5 seconds.

```gleam
pub fn add(
  Groups,
  String,
  String
) -> Result(Nil, GroupError)
```

### `broadcast`

Broadcast a message to all topics in a group

 Sends the message to every topic in the named group via beryl.broadcast().
 If the group doesn't exist, this is a silent no-op (fire and forget).

```gleam
pub fn broadcast(
  Groups,
  beryl.Channels,
  String,
  String,
  json.Json
) -> Nil
```

### `create`

Create a new named group

 Panics if the groups actor is unavailable or does not reply within 5 seconds.

```gleam
pub fn create(
  Groups,
  String
) -> Result(Nil, GroupError)
```

### `delete`

Delete a group

 Panics if the groups actor is unavailable or does not reply within 5 seconds.

```gleam
pub fn delete(
  Groups,
  String
) -> Result(Nil, GroupError)
```

### `list_groups`

List all group names

 Panics if the groups actor is unavailable or does not reply within 5 seconds.

```gleam
pub fn list_groups(Groups) -> List(String)
```

### `remove`

Remove a topic from a group

 Panics if the groups actor is unavailable or does not reply within 5 seconds.

```gleam
pub fn remove(
  Groups,
  String,
  String
) -> Result(Nil, GroupError)
```

### `start`

Start the groups actor

```gleam
pub fn start() -> Result(Groups, GroupStartError)
```

### `topics`

Get all topics in a group

 Panics if the groups actor is unavailable or does not reply within 5 seconds.

```gleam
pub fn topics(
  Groups,
  String
) -> Result(set.Set(String), GroupError)
```
