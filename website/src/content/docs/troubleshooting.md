---
title: Troubleshooting
---

Find the symptom that matches your problem. Perform its checks in order.

## Clients cannot connect at all

**Symptoms:** The browser reports a WebSocket error or
`net::ERR_CONNECTION_REFUSED`. The connection can also close before a Phoenix
message arrives.

**Checks:**

1. **Check that Mist is listening.** Confirm that `mist.start` returned
   `Ok(_)`. Handle the `Error` case.

2. **Path mismatch.** The Phoenix JS client appends `/websocket` to the socket path you pass:
   ```js
   new Socket("/socket", ...)  // → connects to /socket/websocket
   ```
   Your transport config must match:
   ```gleam
   server.default_config("/socket/websocket")
   ```
   Raw WebSocket clients (non-Phoenix) connect directly to the path with no suffix.

3. **Check `on_connect`.** If `with_on_connect` returns
   `Error(server.ConnectRejected)`, the server sends HTTP 403 before the
   upgrade. Check the authentication logic and request headers.

4. **Check the reverse proxy headers.** See
   [Reverse proxy / nginx](#reverse-proxy--nginx).

---

## Client connects but joins are never acknowledged

**Symptoms:** The Phoenix JS client stays in the `connecting` or `joining`
state. It does not receive `phx_reply`.

**Checks:**

1. **Check that `update` answers the join.** Return `AcceptJoin` or
   `RejectJoin` for each `Join` event. The runtime rejects an unanswered join.
   Check the logs for `Join not acknowledged by update; rejecting`. Confirm
   that a match branch covers the client topic:
   ```gleam
   // "room:" <> _ matches "room:lobby", "room:42", etc.
   socket.Join("room:" <> _, payload, ref) ->
     socket.Next(model, [socket.AcceptJoin(ref, option.None)])
   ```
   With `beryl/channel`, confirm a handler pattern matches the topic. The
   layer rejects an unclaimed topic with `{"reason": "unmatched topic"}`.

2. **Is `beryl.Sockets` passed to the transport?** The `mist_transport.upgrade` call must receive the `channels` value from the tuple returned by `beryl.child_spec` or `channel.child_spec` after its child spec is started:
   ```gleam
   use <- mist_transport.upgrade(request, channels, config)
   ```

3. **Check for a `Join` crash.** A crash during `Join` rejects the join but
   keeps the socket open. Check the crash description in the logs and fix the
   panic.

4. **Check the topic string.** `update` routes topics with pattern matching.
   Confirm that the prefix or shape matches the exact client topic.
   `"room:" <> _` does not match `"rooms:lobby"`. For multiple segments, use
   `topic.extract_wildcards` with
   `topic.parse_pattern("document:*:*")`.

---

## Messages sent from the client are not received

**Symptoms:** `update` does not receive a `Message` event. The client does not
receive a reply or push.

**Checks:**

1. **Did the client successfully join?** `Message` events are only delivered after a successful `phx_join`. If join was rejected, messages to the topic get an `unmatched topic` error reply (when they carry a ref) or are dropped.

2. **Check rate limits.** `with_frame_rate` drops complete frames before
   decoding. `with_message_rate`, `with_channel_rate`, and `with_topic_rate`
   apply after decoding in the runtime.

3. **Check the event name.** `Message` contains the event string from the
   client. Confirm that it matches the string in `update`.

---

## Channel handler problems

### `child_spec` returns a handler error

- `InvalidPattern(pattern, reason)` means the pattern is not valid
  `beryl/topic` syntax. `reason` is the nested `TopicError` (`EmptyTopic` or
  `InvalidFormat(detail)`). Match both variants explicitly.
- `DuplicatePattern(pattern)` means the same pattern string appears twice.
  Overlapping but different patterns are valid; first match wins.

### `channel.notify` never reaches `on_info`

The sender belongs to one accepted channel join. Messages for a channel that
closed or joined again are dropped, and `notify` does not report whether the
channel is still open. Capture `context.self` from each new join and install
`channel.on_info`.

### A termination action does not compile

`on_terminate` accepts `Action(Closing)`. Use `broadcast`, `broadcast_from`,
`presence_untrack`, or `broadcast_presence`; active-only pushes, replies, and
presence tracking are rejected by the type checker.

- If `on_terminate` panics, the runtime discards its actions. The runtime still
  closes the topic and sibling channels. The worker stops.

### One channel crash closes more than expected

Crash scope depends on the callback. A `join` panic rejects one join. An
`on_message` or `on_info` panic closes one topic. Each topic runs in its own
worker process. See
[Crash behavior](/guides/channels/#crash-behavior).

---

## Turn on debug logs

beryl uses [palabres](https://hexdocs.pm/palabres/) loggers under the `beryl.*`
namespaces. Enable debug logs when you diagnose integration problems:

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

**Symptoms:** Server code calls `beryl.broadcast`, but connected clients do not
receive the event.

**Checks:**

1. **Check the exact topic string.**
   `beryl.broadcast(sockets, "room:lobby", ...)` sends only to sockets on
   `"room:lobby"`. Wildcard patterns route incoming messages. They do not
   select broadcast targets.

2. **Client has not joined the topic.** A socket must have successfully completed `phx_join` for the topic before it receives broadcasts on that topic.

3. **Single-node vs. multi-node.** Without PubSub, broadcasts are local to the node. If your deployment runs multiple BEAM nodes, configure PubSub:
   ```gleam
   let pubsub_handle = pubsub.start(pubsub.default_config())
   let config =
     beryl.config(wire.phoenix_codec())
     |> beryl.with_pubsub(pubsub_handle)
   ```

4. **broadcast_from excluding the wrong socket.** `beryl.broadcast_from` excludes the socket whose ID you pass. Verify that the socket ID matches the sender.

---

## Presence is stale or incorrect

**Symptoms:** `presence.list` includes disconnected users. It does not show
recent joins or leaves.

**Checks:**

1. **Untrack on `Closed`.** Return a presence effect from the `Closed` arm
   (or `channel.presence_untrack` from `on_terminate`):
   ```gleam
   socket.Closed(topic, _reason) ->
     socket.Next(model, [
       socket.PresenceUntrack(topic, model.presence_key),
     ])
   ```
   The runtime applies presence effects asynchronously. Do not call the
   synchronous public presence API inside `init` or `update`.

2. **Cross-node sync.** If running multiple nodes, each node must use the same
   PubSub scope and each presence actor needs a unique replica ID. The CRDT
   merges state over PubSub; without PubSub, nodes have independent state.

3. **`on_diff` not broadcasting.** If clients rely on receiving `presence_diff` events, confirm `on_diff` is configured and calls `beryl.broadcast_presence_diff`. See the [Presence guide](/guides/presence).

---

## Authentication failures

**Symptoms:** All connections receive HTTP 403, or all joins are rejected.

**Checks:**

1. **`on_connect` bug.** Add logging to your `on_connect` callback to confirm tokens are being extracted correctly from headers/query parameters.

2. **Token validation error.** Check that your token validation logic handles expired or malformed tokens gracefully and returns `Error(Nil)` rather than panicking.

3. **Check whether `update` rejects each join.** Log the `Join` payload and
   confirm its shape. The transport has decoded the raw frame, but `payload`
   is still `Dynamic`. Run your decoder on it.

---

## Heartbeat disconnects

**Symptoms:** Clients disconnect after inactivity. `update` receives
`Closed(topic, HeartbeatTimeout)`.

**Checks:**

1. **Client heartbeat interval vs. server timeout.** The Phoenix JS client
   sends heartbeats every 30 s by default. The beryl default server timeout is
   60 s, which gives a safe margin. If you lower `heartbeat_timeout_ms`, keep
   the client interval at or below half the server timeout.

2. **Load balancer idle timeout.** Some load balancers (AWS ALB, nginx) have their own WebSocket idle timeouts. Set the load balancer timeout to be longer than the client heartbeat interval, or configure load-balancer-level keepalives.

3. **Network interruption.** Mobile clients behind NAT may lose the WebSocket connection without a TCP close. The Phoenix JS client detects missed heartbeat replies and reconnects automatically.

---

## Broadcasts fail across Erlang nodes

**Symptoms:** Broadcasts do not reach other Erlang nodes. Presence state differs
between nodes.

**Checks:**

1. **Nodes are clustered.** beryl PubSub uses Erlang `pg`, which requires
   Erlang distribution. Confirm nodes can reach each other: `nodes().` in the
   Erlang shell should return connected nodes.

2. **Same pg scope.** All nodes must use the same `pg` scope name. `pubsub.default_config()` uses the default scope. If you customized it, make sure all nodes use the same value.

3. **broadcast_from exclusion is cluster-aware by socket id.** `beryl.broadcast_from` excludes the named socket locally and sends the excluded socket ID across PubSub. On remote nodes, all other sockets subscribed to the topic receive the message; a socket with the matching ID on a remote node is also suppressed.

---

## Rate limits drop valid traffic

**Symptoms:** Clients receive only some messages. High-rate operations are
dropped.

**Checks:**

1. **Check burst values.** The `burst` parameter sets the token bucket capacity. If burst is too small, a legitimate burst of messages (e.g., on reconnect) exceeds the limit.

2. **frame_rate vs. message_rate.** These are independent. `frame_rate` counts malformed frames, joins, leaves, heartbeats, and messages before decode; `message_rate` counts decoded non-join envelopes.

3. **message_rate vs. channel_rate.** `message_rate` is per-socket total; `channel_rate` is per-socket-per-topic.

4. **No error is sent to the client.** Rate-limited traffic is dropped silently (over-rate joins get an error reply). Add application-level feedback if needed.

---

## Reverse proxy / nginx

WebSocket upgrades require the `Upgrade` and `Connection` headers. Use this
minimal nginx configuration:

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

Without HTTP/1.1 and the upgrade headers, nginx uses HTTP/1.0 and the WebSocket
handshake fails. Set `proxy_read_timeout` above the client heartbeat interval.
This prevents proxy idle disconnects.

---

## All socket messages stop

**Symptoms:** All WebSocket operations stop. The runtime does not respond.

**Checks:**

1. **Check the restart budget.** The supervised runtime restarts after a crash.
   After 3 restarts in 5 seconds, the supervisor stops and sends the failure to
   the process that called `child_spec`. Check the logs for the first crash.

2. **Check the failure scope.** beryl catches crashes in `init` and `update`
   and limits them to one socket or topic. A fault elsewhere in a socket actor
   closes only that socket. If every connection closes, inspect the router and
   supervisor logs for the first fault.

3. **Rejoin after a restart.** A restarted runtime has no socket state.
   Transports close their connections when the router dies. The Phoenix JS
   client reconnects and rejoins after the replacement router starts.
