---
title: beryl/supervisor
description: Supervisor - OTP supervision tree for beryl subsystems
---

Supervisor - OTP supervision tree for beryl subsystems

 Starts all configured beryl subsystems (coordinator, presence, groups)
 under an OTP supervisor with a rest-for-one strategy. If the coordinator
 crashes, downstream subsystems (presence, groups) are also restarted to
 maintain state consistency — a fresh coordinator has no knowledge of
 existing subscriptions, so presence/groups tracking stale topic data
 would be inconsistent. PubSub is not supervised here; it is backed by
 Erlang's `pg` module which has its own lifecycle.

 ## Example

 ```gleam
 import beryl
 import beryl/supervisor
 import beryl/presence
 import beryl/wire
 import gleam/option.{None, Some}

 let config = supervisor.SupervisedConfig(
   channels: beryl.config(wire.phoenix_codec()),
   presence: Some(presence.default_config("node1")),
   groups: True,
 )
 let assert Ok(supervised) = supervisor.start(config)
 // supervised.channels, supervised.presence, supervised.groups
 ```

## Types

### `StartError`

Errors when starting the supervised system

```gleam
pub type StartError {
  SupervisorStartFailed(error.StartFailure)
  InvalidHeartbeatTimeout
}
```

#### Constructors

##### `SupervisorStartFailed(error.StartFailure)`

The supervisor failed to start

##### `InvalidHeartbeatTimeout`

heartbeat_timeout_ms must be > 0

### `SupervisedChannels`

Handle to all supervised beryl subsystems

```gleam
pub type SupervisedChannels {
  SupervisedChannels(
    channels: beryl.Channels,
    presence: option.Option(presence.Presence),
    groups: option.Option(group.Groups),
    supervisor_pid: process.Pid
  )
}
```

### `SupervisedConfig`

Configuration for starting all beryl subsystems under a supervisor

```gleam
pub type SupervisedConfig {
  SupervisedConfig(
    channels: beryl.Config,
    presence: option.Option(presence.Config),
    groups: Bool
  )
}
```

## Functions

### `child_spec`

Create a child specification for composing beryl into a larger supervision tree

 Returns a supervisor-type child spec that starts the beryl supervision tree.
 This enables embedding beryl as a subtree in an application's top-level
 supervisor.

 ## Example

 ```gleam
 import beryl/supervisor
 import gleam/otp/static_supervisor

 let beryl_config = supervisor.SupervisedConfig(
   channels: beryl.config(wire.phoenix_codec()),
   presence: None,
   groups: True,
 )

 static_supervisor.new(static_supervisor.OneForOne)
 |> static_supervisor.add(supervisor.child_spec(beryl_config))
 |> static_supervisor.start()
 ```

```gleam
pub fn child_spec(SupervisedConfig) -> supervision.ChildSpecification(SupervisedChannels)
```

### `start`

Start all configured beryl subsystems under an OTP supervisor

 Uses a rest-for-one strategy: if the coordinator crashes, presence and
 groups are also restarted to maintain state consistency (a fresh coordinator
 has no knowledge of existing subscriptions or sockets).
 Child start order: coordinator -> presence (optional) -> groups (optional).

 The existing `beryl.start()` function is preserved for unsupervised use.

```gleam
pub fn start(SupervisedConfig) -> Result(SupervisedChannels, StartError)
```

### `stop`

Stop the supervisor and all its children

 Cleanly shuts down the supervisor process, which terminates all child
 processes (coordinator, presence, groups) in reverse start order. After
 this call the `SupervisedChannels` handle should no longer be used.

```gleam
pub fn stop(SupervisedChannels) -> Nil
```
