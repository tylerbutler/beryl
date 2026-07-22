# Security

This document describes beryl's security model and the deployment hardening it
assumes. Read it before running beryl in production, especially the **trust
boundary** section — beryl's distributed features inherit the BEAM's cluster
trust model, and evaluating that boundary is a deployment responsibility, not
something the library can enforce for you.

> [!IMPORTANT]
> beryl is not yet 1.0 and is not considered production-ready. This document
> describes the intended security model, not a guarantee.

## Reporting a vulnerability

Please report suspected vulnerabilities privately via
[GitHub Security Advisories](https://github.com/tylerbutler/beryl/security/advisories/new)
rather than opening a public issue. We will acknowledge the report and
coordinate a fix and disclosure timeline with you.

## Trust boundary

Beryl runs on the Erlang/BEAM runtime and uses **Erlang distribution** for its
distributed features:

- **PubSub** (`beryl/pubsub`) is backed by Erlang's `pg` process groups.
  Broadcasts fan out to subscribers on every connected node.
- **Presence** (`beryl/presence`) replicates CRDT state between nodes so that
  presence is eventually consistent across the cluster.

Both of these deliver messages **directly between BEAM nodes**, with no
application-level authentication or validation on the receiving side. This is
the standard, correct BEAM model, and it has one blunt consequence:

> **Every Erlang distribution peer is fully trusted.** A node that can connect
> to your cluster's distribution mesh is, for security purposes, part of your
> application.

Application- and socket-level authorization — `on_connect`, per-topic join
checks in the app's `update`, rate limits — protects you against untrusted
**WebSocket clients**. It
does **not** protect you against a hostile **distribution peer**. A malicious or
compromised node that has joined your cluster can:

- Publish arbitrary internal beryl PubSub messages, including to reserved
  `beryl:*` topics that clients are never allowed to reach. Those messages are
  delivered to the runtime as trusted cluster input.
- Inject or corrupt presence replication (sync) data, distorting who appears
  present across the cluster.
- Cause unbounded fan-out work by broadcasting to high-cardinality topics.
- Exercise any cluster-only code path that assumes its inputs came from a
  trusted sibling node.

There is no in-library defense against this. **The security boundary is the
edge of your Erlang cluster**, and keeping that boundary trustworthy is a
deployment responsibility. The rest of this document is about how to keep
untrusted nodes out.

## Erlang distribution hardening

If you run more than one node, you must secure Erlang distribution itself.
None of the following is specific to beryl; it is the baseline for any
distributed BEAM application, and beryl assumes you have done it.

### Use a strong, protected Erlang cookie

Nodes authenticate to one another with a shared **Erlang cookie**. Any node
that knows the cookie can join the cluster and is then fully trusted (see the
trust boundary above).

- Generate a long, high-entropy cookie; never ship the default `~/.erlang.cookie`
  that some tooling auto-generates, and never commit a cookie to source control.
- Distribute it as a secret (secrets manager, orchestrator secret, restricted
  file with `0400` permissions owned by the runtime user) — not in an image
  layer, environment dump, or log.
- Rotate it if it may have been exposed.

The cookie is an authentication token, but it is transmitted and used in a way
that provides **no confidentiality on its own**. It is not a substitute for
transport encryption.

### Use TLS distribution across untrusted networks

Plain Erlang distribution traffic is unencrypted and unauthenticated at the
transport layer. For any distribution traffic that crosses a network you do not
fully control — between availability zones, across a cloud VPC boundary, or over
the public internet — enable **TLS distribution** (`inet_tls_dist`) with mutual
certificate verification. This protects cookie exchange and inter-node payloads
from eavesdropping and tampering. See the Erlang/OTP
[Using TLS for Erlang Distribution](https://www.erlang.org/doc/apps/ssl/ssl_distribution.html)
guide.

### Restrict EPMD and distribution ports at the network layer

Erlang distribution is reachable through the **EPMD** port mapper (TCP 4369 by
default) plus a range of per-node distribution ports. Treat these as internal,
privileged ports:

- Firewall EPMD and the distribution port range so they are reachable **only**
  from other cluster nodes — never from the public internet or from general
  workload networks.
- Pin the distribution port range (`inet_dist_listen_min` / `inet_dist_listen_max`)
  so you can write tight firewall/security-group rules instead of opening a wide
  ephemeral range.
- Do not co-locate the cluster on a shared network segment where untrusted hosts
  can reach EPMD.

### Keep cluster membership closed

- **Do not connect beryl nodes to a shared or untrusted cluster.** Because every
  peer is trusted, adding beryl to a multi-tenant or third-party BEAM cluster
  hands those peers the ability to inject internal beryl traffic. Run beryl in a
  dedicated cluster whose membership you control.
- Prefer explicit, static topologies (or a vetted cluster-formation mechanism)
  over open auto-discovery that could admit an unexpected node.

## Client messages vs. cluster messages

It is important to keep two very different message sources distinct:

| | Untrusted client (WebSocket) | Trusted cluster (Erlang distribution) |
|---|---|---|
| Source | Remote browser / device over the WebSocket transport | A peer BEAM node in your cluster |
| Trust | **Untrusted** — treat as adversarial input | **Fully trusted** — treated as internal state |
| Validation | Origin checks, `on_connect` auth, per-topic join authorization in `update`, frame-size limits, topic/event length limits, reserved `phx_*` / `beryl:*` filtering, message/join rate limits | **None** — delivered directly to the runtime/presence as internal input |
| Where enforced | Mist/Ewe transport + runtime (see the [Production Hardening guide](https://beryl.tylerbutler.com/guides/production-hardening/)) | N/A — enforced by the cluster boundary itself |

The takeaway: beryl validates and rate-limits everything that arrives over a
client WebSocket, but **internal PubSub and presence traffic between nodes is
trusted by design.** The defenses that make client input safe do not, and are
not meant to, apply to inter-node messages.

## The `config_with_scope` atom constraint

`beryl/pubsub` exposes `config_with_scope(name: String)` for selecting a custom
`pg` scope. It converts `name` to an Erlang atom via `binary_to_atom`.

Erlang atoms are **never garbage-collected**, and the atom table is bounded. If
an attacker (or a high-cardinality data source) can drive the creation of
unbounded distinct atoms, the atom table fills and the VM crashes — a
denial-of-service.

Therefore:

> `config_with_scope` is **configuration-only**. Its argument must be a static,
> bounded value chosen by the operator. **Never** pass a user-derived,
> request-derived, or otherwise attacker-influenced value to it.

If you do not need a custom scope, use `pubsub.default_config()`, which uses the
fixed `beryl_pubsub` scope and creates no dynamic atoms.
