---
title: Troubleshooting
---

This page lists common symptoms with targeted diagnosis steps. Start from your symptom and follow the checks in order.

## Clients cannot connect at all

**Symptoms:** Browser WebSocket error, `net::ERR_CONNECTION_REFUSED`, or immediate close before any Phoenix messages.

**Checks:**

1. **Is Mist listening?** Confirm your HTTP server started without error. `mist.serve`, `mist.serve_ssl`, or `mist.start` returns a `Result` — make sure you handle `Error`.

2. **Path mismatch.** The Phoenix JS client appends `/websocket` to the socket path you pass:
   ```js
   new Socket("/socket", ...)  // → connects to /socket/websocket
   ```
   Your transport config must match:
   ```gleam
   mist_transport.default_config("/socket/websocket")
   ```
   Raw WebSocket clients (non-Phoenix) connect directly to the path with no suffix.

3. **`on_connect` rejection.** If you configured `with_on_connect`, returning `Error(mist_transport.ConnectRejected)` sends an HTTP 403 before the upgrade. Check your auth logic and incoming headers.

4. **Reverse proxy not forwarding upgrade headers.** See [Reverse proxy / nginx](#reverse-proxy--nginx) below.

---

## Client connects but joins are never acknowledged

**Symptoms:** Phoenix JS client hangs in "connecting" or "joining" state, or `.join()` always lands in the `"error"` branch.

**Checks:**

1. **Does your `update` function match this topic and answer the join?** There is no registry anymore. A `Join` must return `socket.AcceptJoin(ref, ...)` or `socket.RejectJoin(ref, ...)` in the same `update` turn:
   ```gleam
   case ev {
     socket.Join("room:" <> _, _payload, ref) ->
       socket.Next(model, [socket.AcceptJoin(ref, None)])
     _ ->
       socket.Next(model, [])
   }
   ```
   If a `Join` falls through to `socket.Next(model, [])`, beryl rejects it automatically (fail closed).

2. **Is the same `beryl.Sockets` handle passed to the transport?** `mist_transport.upgrade` or `mist_transport.handler` must receive the exact `sockets` value returned by `beryl.start` or `beryl.child_spec`.

3. **`update` panics or crashes.** One runtime actor serves every socket for a `beryl.Sockets` handle. A panic in `update` terminates that shared runtime, drops its existing connections, and restarts a fresh runtime under supervision. See [Runtime & Effect Interpreter](/architecture/runtime/) and [Supervision](/guides/supervision/).

4. **Topic segment mismatch.** `"document:*:ops"` uses segment wildcards — each `*` matches exactly one colon-delimited segment. `"document:tenant-a:sub:ops"` does not match because there is an extra segment. Verify with `topic.parse_pattern` and `topic.matches`.

---

## Messages sent from the client are not received

**Symptoms:** Your `update` function never sees the expected `socket.Message(...)`; no reply or push received.

**Checks:**

1. **Did the client successfully join?** `socket.Message` is only delivered after a successful `phx_join`. If join was rejected, no further topic messages are delivered.

2. **Does your `update` branch match both topic and event name?** `socket.Message(topic, event_name, payload, ref)` carries the raw topic and event string. Verify the branch you expect actually matches.

3. **Rate limits dropping messages.** If `with_message_rate`, `with_channel_rate`, or `with_topic_rate` is configured and the client sends faster than the limit, excess messages are dropped before your application logic sees them.

4. **Event name limits.** If you configured `with_max_event_length`, overlong event names are dropped before they reach `update`.

---

## Enable Beryl debug diagnostics

Beryl uses [palabres](https://hexdocs.pm/palabres/) loggers under the `beryl.*` namespaces. Normal configurations keep production output quiet, but you can opt into detailed runtime lifecycle diagnostics while debugging integration issues:

```gleam
let config =
  beryl.config(wire.phoenix_codec())
  |> beryl.with_logging(beryl.logging_config(
    level: beryl.DebugLevel,
    include_payloads: False,
  ))
```

Debug logs cover frame decode, join routing, effect interpretation, reply/push send outcomes, disconnects, heartbeat decisions, broadcasts, and rate limiting. Payload and frame previews are omitted by default to reduce accidental sensitive-data exposure. If you need bounded previews locally, enable them explicitly:

```gleam
let logging =
  beryl.logging_config(level: beryl.DebugLevel, include_payloads: True)
  |> beryl.with_payload_preview_bytes(bytes: 100)
```

---

## Broadcasts are not received by clients

**Symptoms:** `beryl.broadcast` is called server-side but connected clients do not receive the event.

**Checks:**

1. **Topic string must match exactly.** `beryl.broadcast(sockets, "room:lobby", ...)` delivers only to sockets subscribed to the exact topic `"room:lobby"`. Wildcard patterns are for routing incoming events, not for targeting broadcasts.

2. **Client has not joined the topic.** A socket must have successfully completed `phx_join` for the topic before it receives broadcasts on that topic.

3. **Single-node vs. multi-node.** Without PubSub, broadcasts are local to the node. If your deployment runs multiple BEAM nodes, configure PubSub:
   ```gleam
   let ps = pubsub.start(pubsub.default_config())
   let config = beryl.config(wire.phoenix_codec()) |> beryl.with_pubsub(ps)
   ```

4. **`broadcast_from` excluding the wrong socket.** `beryl.broadcast_from` excludes the socket ID you pass. Verify that the ID belongs to the sender in this same `beryl.Sockets` system. When PubSub is configured, that exclusion is preserved across nodes.

---

## Presence is stale or incorrect

**Symptoms:** Presence snapshots or `presence_diff` events do not reflect joins, leaves, or typing state.

**Checks:**

1. **Did you attach a presence handle?** `PresenceTrack`, `PresenceUntrack`, `PushPresence`, and `BroadcastPresence` require `beryl.with_presence_handle(presence_actor)`. Without it, those effects are dropped with a warning.

2. **Are you returning the right effects?** `PresenceTrack` and `PresenceUntrack` emit standard Phoenix `presence_diff` updates automatically. If your UI expects a custom snapshot such as `presence_list`, return `PushPresence` or `BroadcastPresence` too.

3. **Effect ordering matters.** Presence snapshot effects encode at apply time. Put `PresenceTrack` / `PresenceUntrack` before `PushPresence` / `BroadcastPresence` when you want the snapshot to reflect the new state.

4. **Cross-node sync.** If running multiple nodes, each node must use the same PubSub instance and each presence actor needs a unique replica ID. Without PubSub, nodes have independent presence state.

5. **Clean up your own app model on `Closed`.** Presence entries tracked through effects are auto-untracked when a topic or socket closes, but any extra topic-local state you keep in your `Model` still needs to be pruned from your `socket.Closed(topic, reason)` branch.

---

## Authentication failures

**Symptoms:** All clients get 403 on connect, or all joins are rejected.

**Checks:**

1. **`on_connect` bug.** Add logging to your `with_on_connect` callback to confirm tokens are being extracted correctly from headers or query parameters.

2. **Token validation error.** Make sure failed validation returns `Error(mist_transport.ConnectRejected)` (for connect-level auth) or a controlled `socket.RejectJoin` (for join-level auth), not a panic.

3. **`update` returns `RejectJoin` for every `Join`.** Log the incoming topic and decode the join payload you expect. Join payloads arrive as `gleam/dynamic.Dynamic`, so shape mismatches are easy to miss without explicit decoding.

---

## Heartbeat disconnects

**Symptoms:** Clients are disconnected after a period of inactivity; `Closed(topic, HeartbeatTimeout)` follows.

**Checks:**

1. **Client heartbeat interval vs. server timeout.** The Phoenix JS client sends heartbeats every 30 s by default. The beryl default server timeout is 60 s, which gives a safe margin. If you've lowered `heartbeat_timeout_ms`, ensure the client interval is at most half the server timeout.

2. **Load balancer idle timeout.** Some load balancers (AWS ALB, nginx) have their own WebSocket idle timeouts. Set the load balancer timeout to be longer than the client heartbeat interval, or configure load-balancer-level keepalives.

3. **Network interruption.** Mobile clients behind NAT may lose the WebSocket connection without a TCP close. The Phoenix JS client detects missed heartbeat replies and reconnects automatically.

---

## PubSub cluster issues

**Symptoms:** Broadcasts do not propagate across Erlang nodes; presence state diverges.

**Checks:**

1. **Nodes are clustered.** beryl PubSub uses Erlang `pg`, which requires Erlang distribution. Confirm nodes can reach each other: `Node.list()` in the Erlang shell should return connected nodes.

2. **Same pg scope.** All nodes must use the same `pg` scope name. `pubsub.default_config()` uses the default scope. If you customized it, make sure all nodes use the same value.

3. **Subscribers joined the topic.** PubSub delivery is subscriber-based. If you're debugging your own consumers of `beryl/pubsub`, make sure you created a `subscriber`, called `pubsub.join(sub, topic)`, and folded `pubsub.selecting(sub, ...)` into the receiving actor.

---

## Rate limiting is unexpectedly aggressive

**Symptoms:** Clients receive partial message delivery; high-frequency operations are silently dropped.

**Checks:**

1. **Check burst values.** The `burst` parameter sets the token bucket capacity. If burst is too small, a legitimate burst of messages (for example right after reconnect) can exceed the limit.

2. **Global vs. per-topic limits.** `message_rate` is per socket overall; `channel_rate` is per socket per joined topic; `topic_rate` overrides `channel_rate` for the first matching topic pattern.

3. **No client error is sent automatically.** Over-limit messages are dropped before your `update` function runs. If clients need explicit feedback, design that at the application protocol level.

---

## Reverse proxy / nginx

WebSocket upgrades require forwarding the `Upgrade` and `Connection` headers. A minimal nginx configuration:

```nginx
location /socket/websocket {
    proxy_pass http://localhost:4000;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host $host;
    proxy_read_timeout 86400s;  # Long timeout for persistent connections
}
```

Without `proxy_http_version 1.1` and the upgrade headers, nginx downgrades to HTTP/1.0 and the WebSocket handshake fails. `proxy_read_timeout` should exceed your client heartbeat interval to avoid proxy-side idle disconnects.

---

## Runtime crash / no messages processed

**Symptoms:** All WebSocket operations stop working; the runtime is unresponsive.

**Checks:**

1. **Are you starting Beryl the right way?** `beryl.start(...)` already runs Beryl inside its own supervised subtree. If you use `beryl.child_spec(...)`, make sure the returned child spec is actually added to a running supervisor.

2. **Panic in `init` or `update`.** Gleam's `assert` expressions panic on mismatch. Audit your `init`/`update` code for `let assert` expressions or partial matches that may fail on unexpected inputs.

3. **A runtime crash affects every socket on that handle.** One runtime actor backs each `beryl.Sockets` system. After a crash, existing WebSocket connections close, clients must reconnect and rejoin, and the fresh runtime starts with no per-socket model or joined-topic state. See [Runtime & Effect Interpreter](/architecture/runtime/).
