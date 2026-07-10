---
title: Production Hardening
---

Beryl ships with all rate and connection limits **disabled**, because no
default is right for every deployment. That is fine for development, but a
production server with no abuse controls can be degraded by a single hostile
(or buggy) client. Beryl logs a warning at startup when every control is
off; this guide explains what to turn on and why.

## What is always on

Even with no configuration, beryl enforces:

- **Frame size**: inbound WebSocket frames over 1 MiB close the connection
  (`with_max_inbound_frame_bytes` to adjust).
- **Topic and event lengths**: topics over 256 bytes and event names over 64
  bytes are rejected before reaching a channel
  (`with_max_topic_length`, `with_max_event_length`).
- **Joined-topic cap**: a socket may join at most 1000 topics
  (`with_max_joined_topics_per_socket`).
- **Protocol hygiene**: reserved `phx_*` events, reserved `beryl:*` topics,
  and messages carrying a stale `join_ref` are dropped; heartbeat and leave
  frames count against the message rate limit when one is configured.
- **Heartbeat eviction**: sockets that stop sending heartbeats are evicted
  and their connections closed (60 s window by default, `with_heartbeat`).

## What you should configure for production

```gleam
let config =
  beryl.config(wire.phoenix_codec())
  // Cap messages per socket. Size to your chattiest legitimate client:
  // for most interactive apps 50-100 msg/s with 2x burst is generous.
  |> beryl.with_message_rate(per_second: 100, burst: 200)
  // Joins are much rarer than messages. 10/s per socket tolerates
  // aggressive reconnect/rejoin loops while stopping join floods.
  |> beryl.with_join_rate(per_second: 10, burst: 20)
  // Concurrent connections per client IP. Size to your expected
  // clients-behind-one-NAT worst case; see the caveat below.
  |> beryl.with_max_connections_per_ip(max_connections: 100)
```

Optionally, `with_channel_rate` adds a per-socket-per-topic limit on top of
the global per-socket message rate, useful when a single busy topic must not
starve others.

### The per-IP caveat

The connection limit uses the **real TCP peer address** and deliberately
ignores forwarded headers like `X-Forwarded-For`, which clients can forge.
Two consequences:

- Behind a reverse proxy or load balancer, every connection appears to come
  from the proxy's IP, so a per-IP cap would throttle all clients together.
  Enforce per-client limits at the proxy layer instead.
- Users behind carrier-grade NAT or a corporate gateway share one IP. Set
  the cap high enough for your worst legitimate case, or leave it off and
  rely on rate limits.

### Rate limits reset on reconnect

Per-socket limits are keyed by connection, so a client that hits a limit
can reconnect for a fresh allowance. They bound the damage of any single
connection; they are not a substitute for infrastructure-level controls
(load balancer connection/request limits, WAF rules) against determined
attackers rotating connections.

## Origin checking and authentication

- `with_allowed_origins` on the Mist transport rejects browser connections
  from unexpected origins before the WebSocket handshake.
- `with_on_connect` authenticates the connection once, before upgrade —
  reject unauthenticated clients with a 403 rather than at join time.
- Authorize each topic in your channel's `join` callback; clients cannot
  send events to topics they have not joined.

## Operational notes

- The coordinator is a single actor per channels system. The transport
  sheds oversized frames and (when configured) rate-limited traffic before
  it, but extreme fan-out workloads may want multiple channels systems
  sharded by topic space.
- If beryl is embedded in your own supervision tree via
  `supervisor.child_spec`, restarts of the beryl subtree are bounded by a
  rest-for-one strategy with an intensity of 3 restarts per 5 seconds.
