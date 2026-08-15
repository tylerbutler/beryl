---
title: Troubleshooting
---

This page lists common symptoms with targeted diagnosis steps. Start from your symptom and follow the checks in order.

## Clients cannot connect at all

**Symptoms:** Browser WebSocket error, `net::ERR_CONNECTION_REFUSED`, or immediate close before any Phoenix messages.

**Checks:**

1. **Is Mist listening?** Confirm your HTTP server started without error. `mist.serve` or `mist.serve_ssl` returns a `Result` — make sure you handle `Error`.

2. **Path mismatch.** The Phoenix JS client appends `/websocket` to the socket path you pass:
   ```js
   new Socket("/socket", ...)  // → connects to /socket/websocket
   ```
   Your transport config must match:
   ```gleam
   server.default_config("/socket/websocket")
   ```
   Raw WebSocket clients (non-Phoenix) connect directly to the path with no suffix.

3. **on_connect rejection.** If you configured `with_on_connect`, returning `Error(server.ConnectRejected)` sends an HTTP 403 before the upgrade. Check your auth logic and incoming headers.

4. **Reverse proxy not forwarding upgrade headers.** See [Reverse proxy / nginx](#reverse-proxy--nginx) below.

---

## Client connects but joins are never acknowledged

**Symptoms:** Phoenix JS client hangs in "connecting" or "joining" state; no `phx_reply` received.

**Checks:**

1. **Does your `update` answer the join?** Every `Join` event must be answered with an `AcceptJoin` or `RejectJoin` effect. An unanswered join is rejected automatically (fail closed) — check the server logs for `Join not acknowledged by update; rejecting`, and confirm your topic match arms cover the topic the client is joining:
   ```gleam
   // "room:" <> _ matches "room:lobby", "room:42", etc.
   socket.Join("room:" <> _, payload, ref) ->
     socket.Next(model, [socket.AcceptJoin(ref, option.None)])
   ```

2. **Is `beryl.Sockets` passed to the transport?** The `mist_transport.upgrade` call must receive the `channels` value from the tuple returned by `beryl.child_spec` after its child spec is started:
   ```gleam
   use <- mist_transport.upgrade(req, channels, config)
   ```

3. **Update crashes on `Join`.** A crash while handling a `Join` rejects that join (the socket survives). Check the logs for the crash description and fix the panic.

4. **Topic string mismatch.** Your `update` routes topics with ordinary pattern matching — verify the prefix or shape you match covers the exact topic the client sends (`"room:" <> _` does not match `"rooms:lobby"`). For multi-segment shapes, `topic.extract_wildcards` with `topic.parse_pattern("document:*:*")` verifies the shape explicitly.

---

## Messages sent from the client are not received

**Symptoms:** `update` never receives a `Message` event; no reply or push received.

**Checks:**

1. **Did the client successfully join?** `Message` events are only delivered after a successful `phx_join`. If join was rejected, messages to the topic get an `unmatched topic` error reply (when they carry a ref) or are dropped.

2. **Rate limits dropping messages.** If `with_message_rate`, `with_channel_rate`, or `with_topic_rate` is configured and the client is sending faster than the limit, excess messages are silently dropped. Check your rate limit values or the `Message rate limited` / `Channel rate limited` warnings in the logs.

3. **Event name mismatch.** The `Message` event carries the raw event string. Verify the client sends the exact event name your `update` matches on.

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

Debug logs cover frame decode, join delivery, effect outcomes, reply/push send outcomes, disconnects, heartbeat decisions, broadcasts, and rate limiting. Payload and frame previews are omitted by default to reduce accidental sensitive-data exposure. If you need bounded previews locally, enable them explicitly:

```gleam
let logging =
  beryl.logging_config(level: beryl.DebugLevel, include_payloads: True)
  |> beryl.with_payload_preview_bytes(bytes: 100)
```

---

## Broadcasts are not received by clients

**Symptoms:** `beryl.broadcast` is called server-side but connected clients do not receive the event.

**Checks:**

1. **Topic string must match exactly.** `beryl.broadcast("room:lobby", ...)` delivers only to sockets subscribed to the *exact* topic `"room:lobby"`. Wildcard patterns are for *routing incoming messages*, not for targeting broadcasts.

2. **Client has not joined the topic.** A socket must have successfully completed `phx_join` for the topic before it receives broadcasts on that topic.

3. **Single-node vs. multi-node.** Without PubSub, broadcasts are local to the node. If your deployment runs multiple BEAM nodes, configure PubSub:
   ```gleam
   let ps = pubsub.start(pubsub.default_config())
   let config = beryl.config(wire.phoenix_codec()) |> beryl.with_pubsub(ps)
   ```

4. **broadcast_from excluding the wrong socket.** `beryl.broadcast_from` excludes the socket whose ID you pass. Verify that the socket ID matches the sender.

---

## Presence is stale or incorrect

**Symptoms:** `presence.list` returns entries for users who have disconnected; joins/leaves are not reflected.

**Checks:**

1. **Untrack on `Closed`.** Send a nonblocking cleanup command to an
   application-owned presence worker from the `Closed` arm:
   ```gleam
   socket.Closed(topic, _reason) ->
     {
       process.send(presence_worker, Untrack(topic, model.presence_ref))
       socket.Next(model, [])
     }
   ```
   The application owns every ref returned by `presence.track` and must
   untrack it. Do not run synchronous presence calls inside the shared runtime.

2. **Cross-node sync.** If running multiple nodes, each node must be configured with the same PubSub instance and each presence actor needs a unique replica ID. The CRDT merges state over PubSub; without PubSub, nodes have independent state.

3. **`on_diff` not broadcasting.** If clients rely on receiving `presence_diff` events, confirm `on_diff` is configured and calls `beryl.broadcast_presence_diff`. See the [Presence guide](/guides/presence).

4. **CRDT compaction.** The CRDT can accumulate causal history. Call `presence.compact` (on the state layer) if memory usage grows unexpectedly over a long uptime.

---

## Authentication failures

**Symptoms:** All clients get 403 on connect, or all joins are rejected.

**Checks:**

1. **`on_connect` bug.** Add logging to your `on_connect` callback to confirm tokens are being extracted correctly from headers/query parameters.

2. **Token validation error.** Check that your token validation logic handles expired or malformed tokens gracefully and returns `Error(Nil)` rather than panicking.

3. **`update` rejecting every join.** Log the `payload` argument of the `Join` event to confirm the client is sending the expected shape. `payload` arrives as `Dynamic` (already decoded from the raw frame) — run your decoder against it explicitly.

---

## Heartbeat disconnects

**Symptoms:** Clients are disconnected after a period of inactivity; `update` receives `Closed(topic, HeartbeatTimeout)`.

**Checks:**

1. **Client heartbeat interval vs. server timeout.** The Phoenix JS client sends heartbeats every 30 s by default. The beryl default server timeout is 60 s, which gives a safe margin. If you've lowered `heartbeat_timeout_ms`, ensure the client interval is at least half the server timeout.

2. **Load balancer idle timeout.** Some load balancers (AWS ALB, nginx) have their own WebSocket idle timeouts. Set the load balancer timeout to be longer than the client heartbeat interval, or configure load-balancer-level keepalives.

3. **Network interruption.** Mobile clients behind NAT may lose the WebSocket connection without a TCP close. The Phoenix JS client detects missed heartbeat replies and reconnects automatically.

---

## PubSub cluster issues

**Symptoms:** Broadcasts do not propagate across Erlang nodes; presence state diverges.

**Checks:**

1. **Nodes are clustered.** beryl PubSub uses Erlang `pg`, which requires Erlang distribution. Confirm nodes can reach each other: `Node.list()` in the Erlang shell should return connected nodes.

2. **Same pg scope.** All nodes must use the same `pg` scope name. `pubsub.default_config()` uses the default scope. If you customized it, make sure all nodes use the same value.

3. **broadcast_from exclusion is cluster-aware by socket id.** `beryl.broadcast_from` excludes the named socket locally and carries the excluded socket ID across PubSub. On remote nodes, all other sockets subscribed to the topic receive the message; a socket with the matching ID on a remote node is also suppressed.

---

## Rate limiting is unexpectedly aggressive

**Symptoms:** Clients receive partial message delivery; high-frequency operations are silently dropped.

**Checks:**

1. **Check burst values.** The `burst` parameter sets the token bucket capacity. If burst is too small, a legitimate burst of messages (e.g., on reconnect) exceeds the limit.

2. **message_rate vs. channel_rate.** `message_rate` is per-socket total; `channel_rate` is per-socket-per-topic. If a client joins many topics, `message_rate` limits across all of them while `channel_rate` limits each topic independently.

3. **No error is sent to the client.** Rate-limited messages are dropped silently (over-rate joins get an error reply). If you need clients to know they were limited, implement application-level feedback in `update`.

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

1. **Crash loop exhausted the restart budget.** The runtime always starts supervised and restarts automatically, but after 3 restarts in 5 seconds the supervisor gives up and the crash propagates to the process that called `child_spec`. Check the logs for the underlying crash.

2. **Panic in your app code.** Crashes inside `init`/`update` are rescued and scoped to one socket or topic — they do not stop the runtime. A runtime-wide stop points at a crash outside the rescued paths; audit `let assert` expressions in code the runtime calls indirectly (e.g. presence `on_diff` callbacks).

3. **After a restart, clients must rejoin.** A restarted runtime has no socket state. Connected clients will see their topics close (or stop receiving replies) and the Phoenix JS client will reconnect and rejoin automatically.
