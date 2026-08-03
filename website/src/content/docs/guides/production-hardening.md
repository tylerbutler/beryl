---
title: Production Hardening
description: Turn on the limits, origin policy, and deployment controls you need before exposing Beryl publicly.
---

Beryl ships with its rate and connection limits **disabled**, because no default is right for every deployment. That is fine for development, but a production server with no abuse controls can be degraded by one hostile or buggy client.

## What is always on

Even with no extra configuration, Beryl enforces:

- **Frame size**: inbound WebSocket frames over 1 MiB close the connection (`with_max_inbound_frame_bytes` to adjust).
- **Topic and event lengths**: topics over 256 bytes and event names over 64 bytes are rejected before reaching your app logic (`with_max_topic_length`, `with_max_event_length`).
- **Joined-topic cap**: a socket may join at most 1000 topics (`with_max_joined_topics_per_socket`).
- **Protocol hygiene**: reserved `phx_*` events, reserved `beryl:*` topics, and stale `join_ref` messages are dropped.
- **Heartbeat eviction**: sockets that stop sending heartbeats are evicted and closed (`with_heartbeat`).

## What you should configure for production

```gleam
let config =
  beryl.config(wire.phoenix_codec())
  |> beryl.with_frame_rate(per_second: 150, burst: 300)
  |> beryl.with_message_rate(per_second: 100, burst: 200)
  |> beryl.with_join_rate(per_second: 10, burst: 20)
  |> beryl.with_channel_rate(per_second: 50, burst: 100)
  |> beryl.with_max_connections_per_ip(max_connections: 100)
  |> beryl.with_max_connections(max_connections: 10_000)
```

`with_frame_rate` and `with_message_rate` are independent buckets: the
former is enforced by the transport at the edge, per connection, before any
decoding happens (every frame counts — malformed ones included); the latter
is enforced by the runtime, per socket, after a frame decodes successfully
(joins never count against it — see `with_join_rate`). Configure both so a
flood is shed at the edge before it costs a decode, *and* so decoded traffic
is still capped per socket. Size `with_frame_rate` a little above
`with_message_rate` since a socket's frames also include joins, leaves, and
heartbeats that only the frame bucket counts.

Optionally, add `with_topic_rate(pattern:, per_second:, burst:)` when some topic patterns need tighter limits than the global per-topic ceiling.

### Per-IP and node-wide limits compose

`with_max_connections_per_ip` throttles one abusive peer. `with_max_connections` caps concurrent connections across the whole node.

When both are set, a connection must be under **both** ceilings to be admitted. This matters because a per-IP cap alone cannot stop many distinct source addresses from exhausting the node.

### The per-IP caveat

The connection limit uses the **real TCP peer address** and deliberately ignores forwarded headers such as `X-Forwarded-For`, which clients can forge.

Two consequences:

- behind a reverse proxy or load balancer, every connection appears to come from the proxy's IP, so a per-IP cap would throttle all clients together,
- users behind carrier-grade NAT or a corporate gateway share one IP, so size the cap for your worst legitimate case or leave it off and rely on other controls.

### Rate limits reset on reconnect

Per-socket limits are keyed by connection, so a client that hits a limit can reconnect for a fresh allowance. These limits bound the damage from one connection; they are not a substitute for infrastructure-level controls at your edge.

## Origin checking and authentication

- `with_allowed_origins` (or the default same-origin policy) rejects unexpected browser origins before the WebSocket handshake.
- `with_on_connect` authenticates the socket once, before upgrade.
- Authorize each topic by matching on `socket.Join` in `update` and returning `socket.RejectJoin` when the caller is not allowed.

## Erlang cluster security boundary

Beryl's distributed PubSub and presence replication run over Erlang distribution. Every node in that Erlang cluster is **fully trusted**: a process on any peer node can subscribe to any topic, receive broadcasts, and deliver messages that Beryl's runtime will process as legitimate internal traffic.

WebSocket authentication and join-time authorization protect only external clients. They do **not** protect you from a hostile distribution peer.

### Internal vs client messages

| Source | Trust level | Gated by |
|---|---|---|
| WebSocket clients | Untrusted | `with_on_connect`, origin policy, join-time authorization in `update`, and your own event handling |
| Erlang distribution peers | Fully trusted | Erlang cookie plus network controls |

A hostile distribution peer can broadcast arbitrary messages into any topic and read all presence state. Secure the cluster boundary before you deploy multi-node Beryl.

### Erlang cookie

Set a long, randomly generated cookie in `vm.args` or `RELEASE_COOKIE`. The cookie is the only authentication mechanism for distribution peers.

```shell
openssl rand -base64 48
```

### TLS distribution

When nodes communicate across networks you do not fully control, enable TLS distribution. See the [Erlang TLS Distribution guide](https://www.erlang.org/doc/apps/ssl/ssl_distribution.html).

### Restrict EPMD and distribution ports

The EPMD port (default 4369) and the Erlang distribution listen range must not be reachable from untrusted networks.

```shell
# vm.args
-kernel inet_dist_listen_min 9100
-kernel inet_dist_listen_max 9100
```

### Do not share clusters with untrusted tenants

Adding a node to an existing cluster grants it full visibility into all `pg` groups and all presence state. Never connect Beryl to a cluster outside your trust boundary.

See [SECURITY.md](https://github.com/tylerbutler/beryl/blob/main/SECURITY.md) for the full security reference.

## Operational notes

- One Beryl runtime actor serves one `beryl.Sockets` system. Oversized frames and rate-limited traffic are shed before they reach it, but extreme fan-out workloads may still shard by topic space.
- The Beryl subtree is a one-for-one supervisor with a **Transient, significant** runtime child and an optional connection limiter sibling.
- Restart tolerance is **3 restarts in 5 seconds**. A runtime crash drops live socket state and closes existing connections; new connections work again after the restart.
- See [Supervision](/guides/supervision/) for the full lifecycle contract.
