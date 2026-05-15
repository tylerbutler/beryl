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
import gleam/option.{None, Some}

pub fn main() {
  let config = supervisor.SupervisedConfig(
    channels: beryl.config(wire.phoenix_codec()),
    presence: Some(presence.default_config("node1")),
    groups: True,
  )

  let assert Ok(supervised) = supervisor.start(config)

  // Use the handles
  // supervised.channels  → beryl.Channels
  // supervised.presence  → option.Option(presence.Presence)
  // supervised.groups    → option.Option(group.Groups)
}
```

## SupervisedConfig

```gleam
pub type SupervisedConfig {
  SupervisedConfig(
    channels: beryl.Config,         // always started
    presence: Option(presence.Config), // Some → start presence, None → skip
    groups: Bool,                   // True → start groups actor
  )
}
```

Pass `None` for presence and `False` for groups if your application does not use them. The coordinator is always started.

## SupervisedChannels

`supervisor.start` returns `SupervisedChannels`:

```gleam
pub type SupervisedChannels {
  SupervisedChannels(
    channels: beryl.Channels,
    presence: Option(presence.Presence),
    groups: Option(group.Groups),
    supervisor_pid: process.Pid,
  )
}
```

The optional fields reflect your configuration — if you passed `groups: False`, `supervised.groups` is `None`.

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
`beryl/pubsub` is backed by Erlang's `pg` module, which has its own lifecycle managed by the BEAM runtime. Start PubSub separately and pass it to `beryl.Config` via `beryl.with_pubsub`.
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

let beryl_config = supervisor.SupervisedConfig(
  channels: beryl.config(wire.phoenix_codec()),
  presence: None,
  groups: True,
)

static_supervisor.new(static_supervisor.OneForOne)
|> static_supervisor.add(supervisor.child_spec(beryl_config))
|> static_supervisor.start()
```

`child_spec` returns a supervisor-type `ChildSpecification` so the beryl subtree is treated as a supervisor node by the parent.

## Startup errors

```gleam
pub type StartError {
  SupervisorStartFailed(actor.StartError)
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
