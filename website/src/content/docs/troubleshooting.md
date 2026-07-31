---
title: Troubleshooting
---

This page lists common symptoms with targeted diagnosis steps. Start from your symptom and follow the checks in order.

Examples use `beryl_mist`. `beryl_ewe` exposes the same config-builder and handler API, so every check applies with `ewe_transport` substituted for `mist_transport`.

## Clients cannot connect at all

**Symptoms:** Browser WebSocket error, `net::ERR_CONNECTION_REFUSED`, or immediate close before any Phoenix messages.

**Checks:**

1. **Is the HTTP server listening?** Confirm it started without error — `mist.start` (and the Ewe equivalent) returns a `Result`, so make sure you handle `Error` rather than discarding it.

2. **Path mismatch.** The Phoenix JS client appends `/websocket` to the socket path you pass:
   ```js
   new Socket("/socket", ...)  // → connects to /socket/websocket
   ```
   Your transport config must match:
   ```gleam
   mist_transport.default_config("/socket/websocket")
   ```
   Raw WebSocket clients (non-Phoenix) connect directly to the path with no suffix.

3. **on_connect rejection.** If you configured `with_on_connect`, returning `Error(mist_transport.ConnectRejected)` sends an HTTP 403 before the upgrade. Check your auth logic and incoming headers.

4. **Reverse proxy not forwarding upgrade headers.** See [Reverse proxy / nginx](#reverse-proxy--nginx) below.

---

## Client connects but joins are never acknowledged

**Symptoms:** Phoenix JS client hangs in "connecting" or "joining" state; no `phx_reply` received.

**Checks:**

1. **Is the channel registered?** `beryl.register` must be called before any client connects. Confirm the pattern matches the topic the client is joining:
   ```gleam
   // Pattern "room:*" matches "room:lobby", "room:42", etc.
   // Pattern "room:lobby" matches ONLY "room:lobby"
   beryl.register(channels, "room:*", my_channel.new())
   ```

2. **Is `beryl.Channels` passed to the transport?** The `mist_transport.upgrade` call must receive the same `channels` value that was registered against:
   ```gleam
   use <- mist_transport.upgrade(req, channels, config)
   ```

3. **Join callback panics or crashes.** A panic in `join` terminates the coordinator actor. Ensure `supervisor.start(config)` was added to the application's supervision tree so the coordinator restarts, then fix the panic.

4. **Topic segment mismatch.** `"document:*:ops"` uses segment wildcards — each `*` matches exactly one colon-delimited segment. `"document:tenant-a:sub:ops"` would not match because there is an extra segment. Verify with `topic.parse_pattern` and `topic.matches`.

---

## Messages sent from the client are not received

**Symptoms:** `handle_in` is never called; no reply or push received.

**Checks:**

1. **Did the client successfully join?** `handle_in` is only called after a successful `phx_join`. If join was rejected, no further messages are delivered.

2. **Rate limits dropping messages.** If `with_message_rate` or `with_channel_rate` is configured and the client is sending faster than the limit, excess messages are silently dropped. Check your rate limit values or add server-side logging in `handle_in`.

3. **Event name mismatch.** `handle_in` receives the raw event string. Verify the client sends the exact event name your callback expects.

---

## Enable beryl debug diagnostics

beryl uses [palabres](https://hexdocs.pm/palabres/) loggers under the `beryl.*` namespaces. Normal configurations keep production output quiet, but you can opt into detailed coordinator lifecycle diagnostics while debugging channel integration issues:

```gleam
let config =
  beryl.config(wire.phoenix_codec())
  |> beryl.with_logging(beryl.logging_config(
    level: beryl.DebugLevel,
    include_payloads: False,
  ))
```

Debug logs cover frame decode, join routing, callback results, reply/push send outcomes, disconnects, heartbeat decisions, broadcasts, and rate limiting. Payload and frame previews are omitted by default to reduce accidental sensitive-data exposure. If you need bounded previews locally, enable them explicitly:

```gleam
let logging =
  beryl.logging_config(level: beryl.DebugLevel, include_payloads: True)
  |> beryl.with_payload_preview_bytes(bytes: 100)
```

---

## Broadcasts are not received by clients

**Symptoms:** `beryl.broadcast` is called server-side but connected clients do not receive the event.

**Checks:**

1. **Topic string must match exactly.** `beryl.broadcast(channels, "room:lobby", event, payload)` delivers only to sockets subscribed to the *exact* topic `"room:lobby"`. Wildcard patterns are for *routing incoming messages*, not for targeting broadcasts.

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

1. **`untrack_all` in terminate.** Call `presence.untrack_all(p, socket.id(socket))` from your `terminate` callback:
   ```gleam
   fn terminate(_reason, socket) -> Nil {
     presence.untrack_all(presence, socket.id(socket))
   }
   ```
   Without this, presence entries for the disconnected socket remain in the CRDT indefinitely.

2. **Cross-node sync.** If running multiple nodes, each node must be configured with the same PubSub instance and each presence actor needs a unique replica ID. The CRDT merges state over PubSub; without PubSub, nodes have independent state.

3. **`on_diff` not broadcasting.** If clients rely on receiving `presence_diff` events, confirm `on_diff` is configured and calls `beryl.broadcast_presence_diff`. See the [Presence guide](/guides/presence/).

4. **Long-lived causal history.** The CRDT retains causal context for tracked entries. beryl exposes no public compaction hook, so if presence memory grows over a long uptime the cause is almost always check 1 — entries that are never untracked — rather than unbounded CRDT metadata.

---

## Authentication failures

**Symptoms:** All clients get 403 on connect, or all joins are rejected.

**Checks:**

1. **`on_connect` bug.** Add logging to your `on_connect` callback to confirm tokens are being extracted correctly from headers/query parameters.

2. **Token validation error.** Check that your token validation logic handles expired or malformed tokens gracefully and returns `Error(Nil)` rather than panicking.

3. **Join callback returning JoinError for all.** Log the `payload` argument in `join` to confirm the client is sending the expected shape. `payload` arrives as `Dynamic` — decode it with `channel.decode_payload` and a `gleam/dynamic/decode` decoder, and check that a failed decode is not falling through to a rejection.

---

## Heartbeat disconnects

**Symptoms:** Clients are disconnected after a period of inactivity; `terminate` is called with `HeartbeatTimeout`.

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

3. **broadcast_from exclusion is per-coordinator.** `beryl.broadcast_from` excludes the socket on the originating coordinator. On remote nodes, all sockets subscribed to the topic receive the message, including (if any) a socket with the same ID on a different node. This is expected behavior.

---

## Rate limiting is unexpectedly aggressive

**Symptoms:** Clients receive partial message delivery; high-frequency operations are silently dropped.

**Checks:**

1. **Check burst values.** The `burst` parameter sets the token bucket capacity. If burst is too small, a legitimate burst of messages (e.g., on reconnect) exceeds the limit.

2. **message_rate vs. channel_rate.** `message_rate` is per-socket total; `channel_rate` is per-socket-per-topic. If a client joins many topics, `message_rate` limits across all of them while `channel_rate` limits each topic independently.

3. **No error is sent to the client.** Rate-limited messages are dropped silently. If you need clients to know they were limited, implement application-level feedback in `handle_in`.

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

## Coordinator crash / no messages processed

**Symptoms:** All WebSocket operations stop working; the coordinator is unresponsive.

**Checks:**

1. **Is beryl in the application supervision tree?** Add `supervisor.start(config)` to the root supervisor. It returns the child specification that restarts the coordinator automatically.

2. **Panic in a callback.** Gleam's `assert` expressions panic on mismatch. Audit your `join`, `handle_in`, and `terminate` callbacks for `let assert` expressions that may fail on unexpected inputs.

3. **After restart, clients must rejoin.** A restarted coordinator has no socket state. Connected clients will see their WebSocket close (or stop receiving replies) and the Phoenix JS client will reconnect and rejoin automatically.
