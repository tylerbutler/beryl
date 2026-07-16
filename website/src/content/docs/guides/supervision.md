---
title: Supervision
---

beryl provides two ways to start its subsystems: **unsupervised** with `beryl.start` and **supervised** with `beryl/supervisor.start`. For production deployments, the supervised approach is strongly recommended.

## beryl.start vs supervisor.start

| | `beryl.start` | `supervisor.start` |
|---|---|---|
| Coordinator | Started unsupervised | Supervised, auto-restarts |
| Presence | Manual `presence.start` | Optional, supervised |
| Groups | Manual `group.start` | Optional, supervised |
| Restart on crash | ❌ Process dies | ✅ Rest-for-one |
| Embedding in your supervision tree | Manual | `child_spec/1` |

Use `beryl.start` for simple scripts, tests, or examples where crash recovery is not needed. Use `beryl/supervisor.start` for any long-running production application.

## Supervised startup

```gleam
import beryl
import beryl/supervisor
import beryl/presence
import beryl/wire

pub fn main() {
  let config =
    supervisor.config(beryl.config(wire.phoenix_codec()))
    |> supervisor.with_presence(presence.default_config("node1"))
    |> supervisor.with_groups()

  let assert Ok(supervised) = supervisor.start(config)

  // Read the handles with the accessor functions
  // supervisor.channels(supervised)  → beryl.Channels
  // supervisor.presence(supervised)  → option.Option(presence.Presence)
  // supervisor.groups(supervised)    → option.Option(group.Groups)
}
```

## SupervisedConfig

`SupervisedConfig` is an opaque type. Build it with `supervisor.config` and refine
it with the `with_*` functions:

```gleam
supervisor.config(beryl.config(wire.phoenix_codec())) // coordinator only
|> supervisor.with_presence(presence.default_config("node1")) // enable presence
|> supervisor.with_groups()                                   // enable groups
```

The coordinator (channels) is always started. Omit `with_presence` to skip
presence and `with_groups` to skip the groups actor.

## SupervisedChannels

`supervisor.start` returns an opaque `SupervisedChannels` handle. Read its
subsystems with the accessor functions:

```gleam
supervisor.channels(supervised)       // beryl.Channels (always present)
supervisor.presence(supervised)       // Option(presence.Presence)
supervisor.groups(supervised)         // Option(group.Groups)
supervisor.supervisor_pid(supervised) // process.Pid
```

The optional accessors reflect your configuration — if you did not call
`with_groups`, `supervisor.groups(supervised)` is `None`.

## Restart strategy

The supervisor uses **rest-for-one** with the following child order:

```
coordinator → presence (optional) → groups (optional)
```

Under rest-for-one, if a child crashes, that child and all children started *after* it are restarted. This means:

- **Coordinator crash** → coordinator, presence, and groups all restart. This is correct: a fresh coordinator has no socket or subscription state, so presence and groups tracking stale topic data would be inconsistent.
- **Presence crash** → presence restarts (and groups if configured). The coordinator keeps running, existing connections are preserved.
- **Groups crash** → only groups restarts.

The default restart tolerance is **3 restarts in 5 seconds** before the supervisor itself shuts down.

:::note[PubSub is not supervised]
`beryl/pubsub` is backed by Erlang's `pg` module, which has its own lifecycle managed by the BEAM runtime. Start PubSub separately and add it to the channels config via `beryl.with_pubsub`.
:::

## Stopping the supervisor

```gleam
// Cleanly shut down all children in reverse start order
supervisor.stop(supervised)
```

After `stop` returns, `supervised` should not be used. All child processes have been terminated.

## Embedding in a larger supervision tree

Use `supervisor.child_spec` to embed beryl as a subtree in your application's top-level supervisor:

```gleam
import beryl
import beryl/supervisor
import beryl/wire
import gleam/otp/static_supervisor

let beryl_config =
  supervisor.config(beryl.config(wire.phoenix_codec()))
  |> supervisor.with_groups()

static_supervisor.new(static_supervisor.OneForOne)
|> static_supervisor.add(supervisor.child_spec(beryl_config))
|> static_supervisor.start()
```

`child_spec` returns a supervisor-type `ChildSpecification` so the beryl subtree is treated as a supervisor node by the parent.

## Startup errors

```gleam
pub type StartError {
  SupervisorStartFailed(error.StartFailure)
  InvalidHeartbeatTimeout   // heartbeat_timeout_ms must be > 0
}
```

`InvalidHeartbeatTimeout` is a configuration mistake — check that `heartbeat_timeout_ms` in your `beryl.Config` is a positive integer.

## Production checklist

- Use `supervisor.start` (or `child_spec`) in production — not bare `beryl.start`.
- Configure PubSub if you run more than one BEAM node (see [PubSub guide](/guides/pubsub)).
- Set reasonable heartbeat values: default is 30 s interval / 60 s timeout. Lower timeouts mean faster stale socket eviction but more network activity.
- Configure rate limits via `beryl.with_message_rate`, `with_join_rate`, `with_channel_rate` to protect against runaway clients (see [WebSocket Transport guide](/guides/websocket)).
- Let the supervisor's restart tolerance guard against transient crashes; do not `assert` on `supervisor.start` in production code — handle the `Error` case and log or halt gracefully.
- If the coordinator stops processing messages after a crash, see the [Troubleshooting guide](/troubleshooting/) for coordinator crash and callback panic diagnosis.
