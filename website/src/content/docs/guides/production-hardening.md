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
  bytes are rejected before reaching your app
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
  // Node-wide ceiling on concurrent connections across all IPs. Size to a
  // single node's process/socket/runtime budget; see below.
  |> beryl.with_max_connections(max_connections: 10_000)
```

Optionally, `with_channel_rate` adds a per-socket-per-topic limit on top of
the global per-socket message rate, useful when a single busy topic must not
starve others.

### Per-IP and node-wide limits compose

`with_max_connections_per_ip` throttles a single abusive peer, while
`with_max_connections` caps concurrent connections across the whole node. When
both are set a connection must be under **both** ceilings to be admitted;
otherwise the transport rejects it with `429` **before** allocating any
long-lived socket or runtime state. Freed capacity is reclaimed on normal
close, transport failure, heartbeat eviction, crash, and setup failure.

The node-wide ceiling exists because a per-IP limit alone cannot stop many
**distinct** source addresses — a botnet, or a single host rotating through an
IPv6 range — from each opening a few connections and collectively exhausting
the node's process, socket, and runtime budget. The global ceiling bounds
that total regardless of how the connections are spread across IPs.

Because it is enforced per BEAM node, a load-balanced cluster of N nodes has an
effective ceiling of roughly `max_connections × N`. Size the per-node value
against one node's capacity, and use your load balancer's own global
connection/rate controls when you need a cluster-wide cap.

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
- Authorize each topic in your update's `Join` arm; clients cannot
  send events to topics they have not joined.

## Erlang cluster security boundary

Beryl's distributed PubSub and presence replication run over Erlang
distribution. Every node in your Erlang cluster is **fully trusted**: a
process on any peer node can subscribe to any topic, receive all
broadcasts, and deliver messages that beryl's runtime will process as
legitimate internal traffic. Channel authorization callbacks and
WebSocket-layer controls do **not** apply to messages delivered over
distribution — they protect only inbound WebSocket clients.

### Internal vs. client messages

| Source | Trust level | Gated by |
|---|---|---|
| WebSocket clients | Untrusted | `with_on_connect` authentication, `Join` authorization, and `Message` handling in `update` |
| Erlang distribution peers | Fully trusted | Erlang cookie + network controls |

A hostile distribution peer can broadcast arbitrary messages into any
topic and read all presence state. Secure the cluster boundary **before**
deploying multi-node beryl.

### Erlang cookie

Set a long, randomly generated cookie in `vm.args` or the
`RELEASE_COOKIE` environment variable. The cookie is the only
authentication mechanism for distribution peers; a weak or default cookie
(`CHANGE_ME`, the hostname, etc.) allows any process that can reach your
distribution port to join the cluster.

Generate a strong cookie with, for example:

```shell
openssl rand -base64 48
```

### TLS distribution

When nodes communicate across networks you do not fully control — cloud
subnets, VPNs, or any link that may traverse untrusted infrastructure —
enable TLS distribution. See the
[Erlang TLS Distribution guide](https://www.erlang.org/doc/apps/ssl/ssl_distribution.html)
for setup instructions.

### Restrict EPMD and distribution ports

The EPMD port (default 4369) and the Erlang distribution listen range must
not be reachable from untrusted networks. Use firewall rules or security
groups to allow only cluster-internal traffic. You can fix the distribution
port to a known value for simpler rules:

```shell
# vm.args
-kernel inet_dist_listen_min 9100
-kernel inet_dist_listen_max 9100
```

Or set `ERL_DIST_PORT` when using Elixir/Mix releases. Restrict both 4369
and your chosen distribution port at the network layer.

### Do not share clusters with untrusted tenants

Adding a node to an existing cluster grants it full visibility into all `pg`
groups (PubSub topics) and all presence state on every node. Never connect
beryl to a cluster that contains nodes owned or operated by parties outside
your trust boundary.

See [SECURITY.md](https://github.com/tylerbutler/beryl/blob/main/SECURITY.md)
for the full trust-boundary and distribution-hardening reference.

## Operational notes

- The runtime is a single actor per channels system. The transport
  sheds oversized frames and (when configured) rate-limited traffic before
  it, but extreme fan-out workloads may want multiple channels systems
  sharded by topic space.
- The runtime always starts supervised (`child_spec` has no unsupervised
  mode); restarts are bounded at 3 per 5 seconds, after which the crash
  propagates to the process that called `child_spec`. See the
  [Supervision guide](/guides/supervision/).
