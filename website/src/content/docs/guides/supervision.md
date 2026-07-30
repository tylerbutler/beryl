---
title: Supervision
---

`beryl/supervisor` integrates beryl into your application's OTP supervision tree. `supervisor.start` returns a supervisor child specification that you add to your own root supervisor, rather than starting a process itself.

This is the only way to start beryl. There is deliberately no unsupervised entry point: a channel system with nothing watching it stays down after a coordinator crash, stranding every connected socket, so the API does not offer that as a choice.

## Add beryl to your application supervisor

```gleam
import beryl
import beryl/presence
import beryl/supervisor
import beryl/wire
import gleam/otp/static_supervisor

pub fn main() {
  let beryl =
    supervisor.config(beryl.config(wire.phoenix_codec()))
    |> supervisor.with_presence(presence.default_config("node1"))
    |> supervisor.with_groups()

  let assert Ok(_root) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(supervisor.start(beryl))
    |> static_supervisor.start()

  let channels = supervisor.channels(beryl)
  let presence = supervisor.presence(beryl)
  let groups = supervisor.groups(beryl)

  // Register channels and start the rest of the application.
}
```

The application owns the root supervisor and its lifecycle. beryl only provides the child specification for its subtree.

## SupervisedConfig

`SupervisedConfig` contains both the subsystem configuration and stable names for the supervised processes. Build it with `supervisor.config` and refine it with the `with_*` functions:

```gleam
let beryl =
  supervisor.config(beryl.config(wire.phoenix_codec()))
  |> supervisor.with_presence(presence.default_config("node1"))
  |> supervisor.with_groups()
```

The coordinator is always included. Omit `with_presence` to skip presence and `with_groups` to skip groups.

The accessor functions resolve stable named subjects, so the same handles continue routing to replacement processes after a crash:

```gleam
supervisor.channels(beryl)  // beryl.Channels
supervisor.presence(beryl)  // Option(presence.Presence)
supervisor.groups(beryl)    // Option(group.Groups)
```

Add `supervisor.start(beryl)` to a running supervision tree before using these handles.

## The start return type

`supervisor.start` returns:

```gleam
supervision.ChildSpecification(static_supervisor.Supervisor)
```

This is the type accepted by `static_supervisor.add`. The child specification starts a supervisor process, so OTP applies supervisor shutdown semantics and can restart the entire beryl subtree as part of the application's tree.

## Restart strategy

The beryl subtree has a one-for-one parent with two independent children:

```text
beryl supervisor (one-for-one)
|- connection limiter (optional)
`- channel supervisor (rest-for-one)
   |- registry
   |- coordinator
   |- presence (optional)
   `- groups (optional)
```

- A connection limiter crash restarts only the limiter.
- The registry survives coordinator crashes, preserving channel registrations.
- The connection limiter survives coordinator crashes, preserving live connection counts.
- A coordinator crash restarts the coordinator, presence, and groups.
- A presence crash restarts presence and groups.
- A groups crash restarts only groups.

The default restart tolerance is **3 restarts in 5 seconds** before the beryl supervisor itself shuts down and lets its parent decide what to do next.

:::note[PubSub is not supervised]
`beryl/pubsub` is backed by Erlang's `pg` module, whose lifecycle is managed by the BEAM runtime. Configure it with `beryl.with_pubsub`.
:::

## Startup errors

Configuration and child startup failures are reported when the application starts its root supervisor:

```gleam
case
  static_supervisor.new(static_supervisor.OneForOne)
  |> static_supervisor.add(supervisor.start(beryl))
  |> static_supervisor.start()
{
  Ok(root) -> run(root)
  Error(error) -> handle_start_error(error)
}
```

A heartbeat timeout below 2 is reported as `actor.InitFailed("invalid heartbeat timeout")`.

## Production checklist

- Add `supervisor.start(config)` to the application's root supervision tree.
- Start the root supervisor before registering channels or using subsystem handles.
- Configure PubSub when running more than one BEAM node.
- Configure rate limits to protect against runaway clients.
- Let the application supervisor own startup, shutdown, and restart policy.
