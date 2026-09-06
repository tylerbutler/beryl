---
title: Prepare beryl for production
description: Configure traffic limits, authentication, and Erlang distribution security.
---

beryl disables rate and connection limits by default because each deployment
needs different values. These defaults are suitable for development. In
production, one hostile or faulty client can degrade a server that has no
traffic controls. beryl logs a startup warning when all controls are off. This
guide explains which controls to configure.

## Controls enabled by default

Even with no configuration, beryl enforces:

- **Post-receipt frame size**: once the transport has assembled a complete
  inbound WebSocket frame, beryl closes the connection if it exceeds 1 MiB
  (`with_max_inbound_frame_bytes` to adjust).
- **Topic and event lengths**: topics over 256 bytes and event names over 64
  bytes are rejected before reaching your app
  (`with_max_topic_length`, `with_max_event_length`).
- **Joined-topic cap**: a socket may join at most 1000 topics
  (`with_max_joined_topics_per_socket`).
- **Protocol checks**: reserved `phx_*` events, reserved `beryl:*` topics,
  and messages carrying a stale `join_ref` are dropped.
- **Heartbeat eviction**: sockets that stop sending heartbeats are evicted
  and their connections closed (60 s window by default, `with_heartbeat`).

The frame-size check limits decoding and routing work. It does **not** limit
transport memory because buffering and reassembly occur before beryl receives
the frame. In production, set a WebSocket frame or message limit in the reverse
proxy or load balancer. Set it at or below beryl's limit. Also set a matching
HTTP request or body limit for the upgrade.

## Configure production limits

```gleam
let config =
  beryl.config(wire.phoenix_codec())
  // Drop over-rate complete frames before decoding them.
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

`with_frame_rate` and `with_message_rate` are independent. Joins use frame and
join quota, but not message quota. Leaves and heartbeats use frame and message
quota. Configure both limits. Give the frame limit more capacity for protocol
traffic and malformed frames. If a limiter drops a heartbeat, the runtime does
not refresh the heartbeat deadline. Continued excess traffic then causes
heartbeat eviction.

Size both rate and burst allowances with enough headroom for legitimate client
traffic **plus heartbeats**. A limit that admits an application's normal events
but leaves no heartbeat capacity can evict healthy clients during ordinary
bursts.

Optionally, `with_channel_rate` adds a per-socket-per-topic limit on top of
the global per-socket message rate, useful when a single busy topic must not
starve others.

### Combine per-IP rate and connection limits

`with_connection_rate_per_ip` caps how quickly each peer can open connections,
which prevents repeated reconnects from refreshing per-connection frame and
message bursts. Its token buckets are stored in the supervised connection
limiter, so they survive disconnects and app runtime restarts. Idle buckets are
removed after their allowance has fully refilled.

`with_max_connections_per_ip` separately throttles a single peer's concurrent
connections, while `with_max_connections` caps concurrent connections across
the whole node. A connection must pass every configured rate and concurrency
limit; otherwise the transport rejects it with `429` **before** allocating any
long-lived socket or runtime state. Freed concurrency capacity is reclaimed on
normal close, transport failure, heartbeat eviction, crash, and setup failure.

A per-IP limit cannot stop many source addresses. A botnet or a host that
rotates IPv6 addresses can open a few connections from each address. Together,
these connections can exhaust the node. The node-wide ceiling limits the total
number of connections across all IP addresses.

Because it is enforced per BEAM node, a load-balanced cluster of N nodes has an
effective ceiling of roughly `max_connections × N`. Size the per-node value
against one node's capacity, and use your load balancer's own global
connection/rate controls when you need a cluster-wide cap.

### Limits behind proxies and shared IP addresses

The connection limit uses the **TCP peer address**. It ignores forwarded
headers such as `X-Forwarded-For` because clients can forge them. This has two
effects:

- Behind a reverse proxy or load balancer, every connection appears to come
  from the proxy's IP, so a per-IP cap would throttle all clients together.
  Enforce per-client limits at the proxy layer instead.
- Users behind carrier-grade NAT or a corporate gateway share one IP. Set
  the cap high enough for your worst legitimate case, or leave it off and
  rely on rate limits.

### Reconnects reset per-connection limits

Per-socket limits are keyed by connection, so a client that hits a limit
can reconnect for a fresh allowance. They bound the damage of any single
connection. Configure `with_connection_rate_per_ip` to limit repeated reconnects
from one peer IP, and retain infrastructure-level controls (load balancer
connection/request limits, WAF rules) against attackers rotating source
addresses.

## Check origins and authenticate

- `with_allowed_origins` on the Mist transport rejects browser connections
  from unexpected origins before the WebSocket handshake.
- `with_on_connect` authenticates the connection once, before upgrade.
  reject unauthenticated clients with a 403 rather than at join time.
- Authorize each topic in your update's `Join` arm; clients cannot
  send events to topics they have not joined.

<a id="erlang-cluster-security-boundary"></a>

## Secure the Erlang cluster

beryl PubSub and presence replication use Erlang distribution. Trust every
connected peer. Erlang peers can run arbitrary code on connected nodes. A
hostile peer can compromise the full cluster. Topic access, broadcasts,
internal traffic, and presence state are only part of that access. Channel
authorization and WebSocket controls do not apply to distribution messages.
They protect only WebSocket clients.

### Trust for client and cluster traffic

| Source | Trust level | Protected by |
|---|---|---|
| WebSocket clients | Untrusted | `with_on_connect` authentication, `Join` authorization, and `Message` handling in `update` |
| Erlang distribution peers | Fully trusted | Network isolation + mutually verified TLS distribution (cookies prevent accidental cross-cluster connections only) |

All distributed BEAM applications need network isolation and secure
distribution. beryl assumes that you enforce this trust boundary.

### The Erlang cookie does not secure distribution

Set a long, randomly generated cookie in `vm.args` or the
`RELEASE_COOKIE` environment variable. Erlang
[uses the cookie to distinguish clusters](https://www.erlang.org/doc/system/distributed.html#security)
and prevent accidental cross-cluster connections; its handshake is not
cryptographically secure authentication against an adversary. A strong cookie
prevents accidental matches and makes offline guessing harder, but it must
never be the security control. Keep distribution ports isolated and use
mutually verified TLS distribution.

Generate a strong cookie with, for example:

```shell
openssl rand -base64 48
```

### Use mutually verified TLS distribution

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

### Keep untrusted nodes outside the cluster

Adding a node to a cluster lets it run arbitrary code on connected nodes. It
can also access all `pg` groups and presence state. Do not connect beryl to
nodes you do not trust.

See [SECURITY.md](https://github.com/tylerbutler/beryl/blob/main/SECURITY.md)
for the full distribution security reference.

## Runtime capacity

- The runtime uses one router actor per channel system and one actor per
  connected socket. The transport drops oversized frames and, when configured,
  over-rate traffic before routing. Applications that send one event to
  many subscribers may need several channel systems divided by topic so one
  router does not handle every subscriber.
- The runtime always starts supervised (`child_spec` has no unsupervised
  mode); restarts are bounded at 3 per 5 seconds, after which the crash
  propagates through the application's supervision tree. See the
  [Supervision guide](/guides/supervision/).
- Rate limits do not bound worker input, pending action reports, router
  fan-out, or outbound connection queues. See
  [Queue limits and overload](/architecture/runtime/#queue-limits-and-overload)
  for current controls and non-guarantees.
