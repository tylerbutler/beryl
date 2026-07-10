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

 let config =
   supervisor.config(beryl.config(wire.phoenix_codec()))
   |> supervisor.with_presence(presence.default_config("node1"))
   |> supervisor.with_groups()
 let assert Ok(supervised) = supervisor.start(config)
 // supervisor.channels(supervised), supervisor.presence(supervised),
 // supervisor.groups(supervised)
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

`heartbeat_timeout_ms` must be at least 2 — the same validation as
 `beryl.start` (the staleness check interval is derived as
 `heartbeat_timeout_ms / 2`, so 1 would silently disable eviction).

### `SupervisedChannels`

Handle to all supervised beryl subsystems.

 Opaque: read its fields with the accessor functions
 ([`channels`](#channels), [`presence`](#presence), [`groups`](#groups),
 [`supervisor_pid`](#supervisor_pid)). This lets the handle grow new
 fields post-1.0 without breaking readers.

```gleam
pub type SupervisedChannels
```

### `SupervisedConfig`

Configuration for starting all beryl subsystems under a supervisor.

 Opaque: build it with [`config`](#config) and refine it with the
 `with_*` functions. This keeps the configuration extensible — new
 subsystem options can be added post-1.0 without breaking callers.

```gleam
pub type SupervisedConfig
```

## Functions

### `channels`

The channels system handle (always present).

```gleam
pub fn channels(SupervisedChannels) -> beryl.Channels
```

### `child_spec`

Create a child specification for composing beryl into a larger supervision tree

 Returns a supervisor-type child spec that starts the beryl supervision tree.
 This enables embedding beryl as a subtree in an application's top-level
 supervisor.

 ## Example

 ```gleam
 import beryl/supervisor
 import gleam/otp/static_supervisor

 let beryl_config =
   supervisor.config(beryl.config(wire.phoenix_codec()))
   |> supervisor.with_groups()

 static_supervisor.new(static_supervisor.OneForOne)
 |> static_supervisor.add(supervisor.child_spec(beryl_config))
 |> static_supervisor.start()
 ```

```gleam
pub fn child_spec(SupervisedConfig) -> supervision.ChildSpecification(SupervisedChannels)
```

### `config`

Start building a supervised configuration.

 Requires the channels configuration (the coordinator is always started).
 Presence and groups are opt-in via [`with_presence`](#with_presence) and
 [`with_groups`](#with_groups); by default neither is started.

```gleam
pub fn config(beryl.Config) -> SupervisedConfig
```

### `groups`

The groups handle, if groups were configured.

```gleam
pub fn groups(SupervisedChannels) -> option.Option(group.Groups)
```

### `presence`

The presence handle, if presence was configured.

```gleam
pub fn presence(SupervisedChannels) -> option.Option(presence.Presence)
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

### `supervisor_pid`

The supervisor process PID (for lifecycle management).

```gleam
pub fn supervisor_pid(SupervisedChannels) -> process.Pid
```

### `with_groups`

Enable the named channel groups subsystem.

```gleam
pub fn with_groups(SupervisedConfig) -> SupervisedConfig
```

### `with_presence`

Enable presence tracking with the given configuration.

```gleam
pub fn with_presence(
  SupervisedConfig,
  presence.Config
) -> SupervisedConfig
```
