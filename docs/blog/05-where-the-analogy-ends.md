# Where the analogy ends

Model-update vocabulary helps organize Beryl application code, but it can
mislead you about execution. Beryl does not create an independent actor for
each model, render output from state, or restart socket state after a runtime
crash. One shared runtime actor stores many logical socket models, calls the
application update, and interprets ordered effects.

The production decisions start where the frontend analogy ends.

## Follow one frame

For a text frame, the path is:

```text
transport connection
  -> configured wire codec
  -> shared Beryl runtime actor
  -> app update or channel callback
  -> effect/action interpreter
  -> encoded wire frame or broadcast fan-out
```

The transport owns the WebSocket connection and edge controls. It checks the
frame size and frame-rate bucket, decodes the frame with the configured codec,
and sends the decoded value to the runtime. Malformed input and decode cost
stay out of the shared actor.

The runtime validates protocol state and constructs a `socket.Input`. Raw
dispatch receives that input directly. `beryl/channel` supplies the raw
router, locates the live channel instance, calls its callback, and lowers
channel actions to core effects.

The runtime then interprets effects in list order. Replies and pushes become
encoded frames. Broadcasts fan out to the topic's subscribers and can cross
nodes through PubSub when configured.

This path contains one intentional `Dynamic` boundary: decoded client
payloads. The core runtime's app model and message types stay captured in
typed closures. The channel layer adds separate closure sealing for each
handler's private state and info type.

## Logical models share one physical actor

Raw `init` runs once per socket and returns one app-defined `Model`. A channel
router creates one private state value per accepted topic. Those values are
logically separate, but they all reside in one Beryl runtime actor.

The runtime processes its mailbox sequentially. That gives it a consistent
view of socket ids, models, pending and joined topics, subscriber sets, and
heartbeat timestamps without locks. It also means an update callback should
finish promptly. Blocking I/O, sleeps, or expensive work delay other sockets
on the same runtime.

The live-poll example follows that rule:

- `store.Store` serializes shared poll state in its own actor;
- `timer.Timer` waits and runs delayed callbacks in its own actor;
- Beryl callbacks make short calls, choose the next state, and return effects.

If an external operation needs more time, run it under application
supervision and send a typed result through `socket.Sender` or
`channel.Sender`.

## Callback crashes are rescued with a scope

"Let it crash" is incomplete advice for a shared runtime. Beryl rescues
application callback crashes and applies behavior based on the input that
failed:

| Callback or raw input | Runtime behavior |
|---|---|
| raw `init` | Leave the socket unregistered |
| `Join`, or a channel `join` | Reject that join |
| topic-scoped `Message` / `Binary`, or `on_message` / `on_binary` | Close that topic |
| `Info`, or channel `on_info` | Tear down that socket |
| `Closed`, or channel `on_terminate` | Log the crash and continue teardown |

Other sockets remain in the runtime. Beryl truncates and depth-limits crash
descriptions before logging.

The `on_terminate` case has a narrow channel-layer edge. A panic discards that
callback's returned router update and actions, so the old sealed instance can
remain reachable through its own generation-scoped sender until the topic is
joined again or the socket ends. Client traffic cannot reach it because the
topic has closed. Keep termination callbacks small and free of partial
application work.

This policy contains app callback failures without pretending every failure
has the same scope.

## Supervision covers runtime crashes

`beryl.child_spec` and `channel.child_spec` return a child specification for
the application's supervisor. Beryl starts an internal one-for-one subtree
with a restart tolerance of 3 restarts in 5 seconds. The runtime child is
transient, so a graceful `beryl.stop` does not restart it.

The child specification retains the typed `init` and `update` closures. A
runtime restart can resume dispatch without re-registering application code,
and the name-backed `beryl.Sockets` handle remains usable. Fire-and-forget
operations during the restart window become quiet no-ops, while connection
admission fails cleanly.

Runtime state is ephemeral:

- connected socket records disappear;
- raw per-socket models disappear;
- channel instances disappear;
- joined-topic and subscriber maps disappear;
- clients must reconnect and rejoin.

Supervision restores the service process, not the live WebSocket sessions it
held. Keep durable or reconstructable domain state in application-owned
storage, as the example does with `store.Store`.

## Heartbeats test connection liveness

Phoenix clients send heartbeat frames on the `phoenix` topic. Beryl handles
them inside the runtime; the application update does not receive them. The
runtime records a monotonic last-seen timestamp and periodically evicts stale
sockets.

Eviction closes the transport and delivers `Closed(topic,
HeartbeatTimeout)` for every joined topic. Raw dispatch can prune its model.
The channel layer invokes `on_terminate` for each accepted instance.

The final checkpoint sets:

```gleam
beryl.config(wire.phoenix_codec())
|> beryl.with_heartbeat(timeout_ms: 45_000)
|> beryl.with_max_connections(500)
|> beryl.with_max_connections_per_ip(20)
|> beryl.with_max_inbound_frame_bytes(16_384)
|> beryl.with_frame_rate(per_second: 20, burst: 40)
|> beryl.with_message_rate(per_second: 10, burst: 20)
|> beryl.with_join_rate(per_second: 4, burst: 8)
|> beryl.with_topic_rate(pattern: "poll:*", per_second: 5, burst: 10)
```

This exact excerpt comes from
[`step_05.gleam`](../../examples/blog_series/src/blog_series/step_05.gleam).
These values make the example production-shaped, not universally correct.
Choose limits from expected traffic and deployment capacity.

## PubSub and presence sit outside the MVU analogy

PubSub distributes broadcasts between BEAM nodes through Erlang `pg`. The
remote payload and subscriber contract belong to distributed messaging, not
to a local model-update-view loop. The runtime fans a received broadcast out
to local subscribers.

Presence is an application-owned actor backed by a CRDT state. Presence
effects can pause the remaining effects for one socket while the presence
actor applies a mutation. Other sockets, heartbeats, broadcasts, and shutdown
work continue. When the mutation completes, the waiting socket resumes its
list in the original order.

Neither PubSub nor presence is a hidden field in the socket `Model`. Their
lifecycle and distributed semantics need separate design:

- configure PubSub when broadcasts must cross nodes;
- start and supervise presence when clients need replicated membership;
- keep synchronous capacity or authorization state in an application-owned
  process when a check and mutation must be atomic.

The Elm analogy explains state transitions. It does not explain cluster
membership, CRDT convergence, or supervision.

## Raw dispatch or channels

Both APIs use the same transport, runtime, codec, presence, PubSub, and abuse
controls. Choose based on where you want routing and composition to live.

Use raw dispatch when:

- the endpoint serves one topic family;
- one socket-wide model is natural;
- callbacks need direct cross-topic effects in one ordered list;
- explicit routing is worth the control.

Use `beryl/channel` by default when:

- the endpoint serves several topic namespaces;
- the design follows Phoenix Channels;
- each channel should own private state and a private info type;
- handler values are the useful unit of composition.

Raw dispatch remains the clearest teaching lens and Beryl's core.
`beryl/channel` is the recommended default for multi-channel and
Phoenix-shaped applications. The layer narrows actions to the current topic
and uses phase types during close. Raw effects can name any topic, so
cross-topic coordination stays ordinary app code.

## The boundaries to remember

The five posts began with a familiar update loop. The production model needs
the mismatches kept in view:

- Beryl has no `view`.
- Raw `init` runs once per socket.
- One shared runtime actor stores many logical per-socket models.
- Client payload stays `Dynamic` until application decoding succeeds.
- `JoinRef` and `ReplyRef` are protocol capabilities, not data to rebuild.
- Effect list order is observable wire order.
- Raw effects can coordinate across topics; channel actions are topic-scoped
  and phase-typed.
- Callback crashes are rescued with input-specific scope.
- A supervised runtime restart restores dispatch but loses live socket state.

Those constraints tell you where to put state and work. Keep connection-local
facts in raw models or channel state. Keep shared domain state in
application-owned processes. Decode at the wire boundary. Return short,
ordered effect lists. Let supervision restore services while clients restore
ephemeral subscriptions by reconnecting.

## Sources and further reading

- [Beryl runtime architecture](../../website/src/content/docs/architecture/runtime.md)
- [Beryl message lifecycle](../../website/src/content/docs/architecture/message-lifecycle.md)
- [Choose a Beryl API](../../website/src/content/docs/choosing-an-api.md)
- [`beryl` source](../../packages/beryl/src/beryl.gleam)
- [`beryl/socket` source](../../packages/beryl/src/beryl/socket.gleam)
- [`beryl/channel` source](../../packages/beryl/src/beryl/channel.gleam)

## Runnable checkpoint: step 05

```sh
cd examples/blog_series && gleam run -m blog_series/step_05
```

Open <http://localhost:8105>, join `demo`, vote from two tabs, and close the
poll now or wait 60 seconds. The behavior matches step 04 while the runtime
uses the heartbeat and abuse-control settings shown above. In another shell,
run `curl http://localhost:8105/healthz`; the expected response is `ok`.

Series index: [Beryl introduction series](README.md).
