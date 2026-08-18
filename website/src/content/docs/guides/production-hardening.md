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

- **Post-receipt frame size**: once the transport has assembled a complete
  inbound WebSocket frame, Beryl closes the connection if it exceeds 1 MiB
  (`with_max_inbound_frame_bytes` to adjust).
- **Topic and event lengths**: topics over 256 bytes and event names over 64
  bytes are rejected before reaching your app
  (`with_max_topic_length`, `with_max_event_length`).
- **Joined-topic cap**: a socket may join at most 1000 topics
  (`with_max_joined_topics_per_socket`).
- **Protocol hygiene**: reserved `phx_*` events, reserved `beryl:*` topics,
  and messages carrying a stale `join_ref` are dropped.
- **Heartbeat eviction**: sockets that stop sending heartbeats are evicted
  and their connections closed (60 s window by default, `with_heartbeat`).

The frame-size check limits downstream decoding and routing work, but it does
**not** bound transport-layer memory: buffering and reassembly happen before
Beryl receives the frame. In production, configure a WebSocket frame/message
size limit at or below Beryl's limit at your reverse proxy or load balancer,
plus a matching request/body limit for the HTTP upgrade.

## What you should configure for production

```gleam
let config =
  beryl.config(wire.phoenix_codec())
  // Shed all complete frames at the transport edge before decode.
  |> beryl.with_frame_rate(per_second: 150, burst: 300)
  // Cap messages per socket. Size to your chattiest legitimate client:
  // for most interactive apps 50-100 msg/s with 2x burst is generous.
  |> beryl.with_message_rate(per_second: 100, burst: 200)
  // Joins are much rarer than messages. 10/s per socket tolerates
  // aggressive reconnect/rejoin loops while stopping join floods.
  |> beryl.with_join_rate(per_second: 10, burst: 20)
  // Cap connection attempts per client IP. This allowance survives
  // disconnects and app runtime restarts.
  |> beryl.with_connection_rate_per_ip(per_second: 5, burst: 10)
  // Concurrent connections per client IP. Size to your expected
  // clients-behind-one-NAT worst case; see the caveat below.
  |> beryl.with_max_connections_per_ip(max_connections: 100)
  // Node-wide ceiling on concurrent connections across all IPs. Size to a
  // single node's process/socket/runtime budget; see below.
  |> beryl.with_max_connections(max_connections: 10_000)
```

`with_frame_rate` and `with_message_rate` are independent. Joins consume frame
and join quota, but not message quota; leaves and heartbeats consume both frame
and message quota. Configure both, with frame capacity slightly higher for
protocol traffic and malformed frames that never reach the runtime. If either
limiter sheds a heartbeat, the socket's heartbeat deadline is not refreshed.
Sustained over-rate traffic is therefore terminated by heartbeat eviction
rather than merely being shed forever.

Size both rate and burst allowances with enough headroom for legitimate client
traffic **plus heartbeats**. A limit that admits an application's normal events
but leaves no heartbeat capacity can evict healthy clients during ordinary
bursts.

Optionally, `with_channel_rate` adds a per-socket-per-topic limit on top of
the global per-socket message rate, useful when a single busy topic must not
starve others.

### Per-IP rate and connection limits compose

`with_connection_rate_per_ip` caps how quickly each peer can open connections,
which prevents reconnect churn from repeatedly refreshing per-connection frame
and message bursts. Its token buckets live in the supervised connection
limiter, so they survive disconnects and app runtime restarts. Idle buckets are
removed after their allowance has fully refilled.

`with_max_connections_per_ip` separately throttles a single peer's concurrent
connections, while `with_max_connections` caps concurrent connections across
the whole node. A connection must pass every configured rate and concurrency
limit; otherwise the transport rejects it with `429` **before** allocating any
long-lived socket or runtime state. Freed concurrency capacity is reclaimed on
normal close, transport failure, heartbeat eviction, crash, and setup failure.

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

### Per-connection rate limits reset on reconnect

Per-socket limits are keyed by connection, so a client that hits a limit
can reconnect for a fresh allowance. They bound the damage of any single
connection. Configure `with_connection_rate_per_ip` to bound reconnect churn
from one peer IP, and retain infrastructure-level controls (load balancer
connection/request limits, WAF rules) against attackers rotating source
addresses.

## Origin checking and authentication

- `with_allowed_origins` on the Mist transport rejects browser connections
  from unexpected origins before the WebSocket handshake.
- `with_on_connect` authenticates the connection once, before upgrade —
  reject unauthenticated clients with a 403 rather than at join time.
- Authorize each topic in your update's `Join` arm; clients cannot
  send events to topics they have not joined.

## Erlang cluster security boundary

Beryl's distributed PubSub and presence replication run over Erlang
distribution. Every connected peer is **fully trusted**: distributed Erlang
allows peers to execute arbitrary code on connected nodes, so a hostile peer
means full node compromise that can extend across the cluster. Subscribing to
beryl topics, receiving broadcasts, injecting trusted internal traffic, and
reading or corrupting presence state are only a subset of that access. Channel
authorization callbacks and WebSocket-layer controls do **not** apply to
messages delivered over distribution — they protect only inbound WebSocket
clients.

### Internal vs. client messages

| Source | Trust level | Gated by |
|---|---|---|
| WebSocket clients | Untrusted | `with_on_connect` authentication, `Join` authorization, and `Message` handling in `update` |
| Erlang distribution peers | Fully trusted | Network isolation + mutually verified TLS distribution (cookies prevent accidental cross-cluster connections only) |

This is not a beryl-specific deployment prerequisite. Network isolation and
secure distribution are the baseline for every distributed BEAM application;
beryl assumes that boundary is already enforced.

### Erlang cookie

Set a long, randomly generated cookie in `vm.args` or the
`RELEASE_COOKIE` environment variable. Erlang
[uses the cookie to distinguish clusters](https://www.erlang.org/doc/system/distributed.html#security)
and prevent accidental cross-cluster connections; its handshake is not
cryptographically secure authentication against an adversary. A strong cookie
prevents accidental matches and makes offline guessing harder, but it must
never be the security boundary. Keep distribution ports isolated and use
mutually verified TLS distribution.

Generate a strong cookie with, for example:

```shell
openssl rand -base64 48
```

### TLS distribution

Use TLS distribution with mutual certificate verification for secure
multi-node deployments, including traffic within private networks. See the
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

Adding a node to an existing cluster grants it arbitrary code execution on
connected nodes; visibility into all `pg` groups (PubSub topics) and presence
state is only part of that access. Never connect beryl to a cluster that
contains nodes owned or operated by parties outside your trust boundary.

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
