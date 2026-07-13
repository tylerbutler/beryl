---
title: Migration & Releases
description: How beryl is released, how to find changelogs, and notable recent changes.
---

:::caution[Pre-1.0 Software]
beryl is not yet 1.0. Minor releases may include breaking changes. Read this page before upgrading.
:::

## Release process

beryl uses a fully automated release pipeline:

1. **Changelog fragments** are authored with `trellis changelog new` (or `just change <package> <kind> "<body>"`) and committed alongside the code change. Fragments live in `.changes/unreleased/` until a release is cut.
2. **`trellis release pr`** collects unreleased fragments, bumps each affected package's version, regenerates its CHANGELOG.md, and opens a release PR.
3. Merging the release PR publishes each package to [Hex.pm](https://hex.pm/packages/beryl) in dependency order.
4. Per-package tags (`beryl-v1.2.3`, `beryl_mist-v1.2.3`) and GitHub releases are created after a successful publish.

**Where to find changelogs:**

- [GitHub Releases](https://github.com/tylerbutler/beryl/releases) — the canonical per-version changelog
- `.changes/unreleased/` in the repository — what is staged for the _next_ release

---

## Recent notable changes

The following changes have accumulated since the last release. They are described at a high level here; see GitHub for exact signatures.

### Mist transport split into `beryl_mist`

The Mist WebSocket transport now ships as its own package. Add it alongside the core library (`gleam add beryl beryl_mist`) and change imports from `beryl/transport/mist` to `beryl_mist`:

```gleam
// before
import beryl/transport/mist as mist_transport
// after
import beryl_mist as mist_transport
```

Call sites are unchanged. Applications that don't serve WebSockets (or that use a custom transport built on the new public `beryl/transport` SPI) no longer pull in `mist` and `gleam_http` through beryl.

### `send_info` and `with_handle_info`

Channels can now receive server-originated OTP messages. Add a `handle_info` callback with `channel.with_handle_info/2`, then deliver messages from anywhere using `beryl.send_info/4`. The callback receives the **typed** message you sent (see the `info` type parameter below) — no `Dynamic` decode and no unsafe cast. A `Reply` returned from `handle_info` becomes a push (no client ref exists, so no `phx_reply` is sent).

### Phoenix presence diff broadcasting

`beryl.broadcast_presence_diff/3` sends Phoenix-shaped presence diffs — `joins`/`leaves` objects keyed by presence key with `metas` arrays. Local `track` and `untrack` operations also invoke `on_diff` with concrete diff values. Anonymous entries are excluded from encoded diffs.

### Segment-aware topic wildcards

`topic.parse_pattern/1` now recognises multi-segment wildcard patterns like `"document:*:*"`. Use `topic.extract_wildcards/2` to pull out the matched segments. Single trailing `*` patterns retain existing prefix-wildcard behaviour.

### Mist direct transport

The core WebSocket transport now uses Mist directly instead of Wisp. If your application used `beryl/transport/wisp`, migrate to `beryl_mist`. Examples also use Mist for HTTP routing and static assets. See the [WebSocket Transport guide](/guides/websocket) for the updated setup.

### PubSub socket exclusion fix

`broadcast_from` now correctly excludes the originating socket when a channel is PubSub-enabled. Previously, broadcasts through PubSub could echo back to the sender.

### Rate limiter fail-closed

The rate limiter now **denies** requests when the token bucket actor cannot be started, rather than silently allowing them through. If you rely on rate limiting for security, this change removes a potential bypass under resource exhaustion.

### Removed: `socket.topics()` and `socket.is_subscribed()`

These functions always returned empty/false because subscriptions are tracked internally by the coordinator. They have been removed from the public API.

### Type-safe `handle_info`: `info` type parameter on `Channel`

`Channel` is parameterized as `Channel(assigns, info)`. The `info` type is the
server-originated message delivered to `handle_info`, so `with_handle_info`
wires up `fn(info, Socket(assigns)) -> HandleResult(assigns)` and `send_info/4`
delivers a value of that type — end to end with no `Dynamic` and no unsafe
identity FFI cast in application code. Channels that do not use `handle_info`
leave `info` generic, so existing channel definitions keep compiling; only
explicit `Channel(MyAssigns)` type annotations need to become
`Channel(MyAssigns, info)` (or a concrete info type). This is a **breaking**
type-signature change.

### WebSocket authentication hook

The Mist transport config accepts an `on_connect` callback. Return `Error(mist_transport.ConnectRejected)` to reject the upgrade with a 403 before the WebSocket handshake completes, or `Ok(assigns)` to allow it and seed initial socket-level assigns visible to channels at join time (return `Ok(Nil)` for none). See [WebSocket Transport → Seeding initial assigns](/guides/websocket#seeding-initial-assigns).

---

## Upgrading

When upgrading across a minor version boundary:

1. Read the [GitHub Release notes](https://github.com/tylerbutler/beryl/releases) for the target version.
2. Check removed or changed exports against the [module map](/reference#module-map).
3. Run `gleam check` — the Gleam compiler will surface type mismatches caused by API changes.
4. Run `just test` to verify runtime behaviour.

If you hit a regression not covered by the release notes, please [open an issue](https://github.com/tylerbutler/beryl/issues).
