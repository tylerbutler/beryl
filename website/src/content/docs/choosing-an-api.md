---
title: Choose an API
description: Compare beryl's channel handlers and raw dispatch API.
---

beryl has one runtime and two ways to program it.

- **The channel layer** (`beryl/channel`): Register one handler for each topic
  pattern. Each channel keeps private state and a server-side message type. The
  layer routes each event to the correct channel. **Use this API by default.**
- **Raw dispatch** (`beryl`): Define one `init` and `update` pair for
  the socket system. beryl runs them separately for each connected socket.
  Match `socket.Input` values and return ordered effects. The channel layer
  uses this public core API.

Both APIs use the same socket processes, message format, presence, PubSub,
connection limits, and rate limits. They support the same client features.
The main difference is who routes topics.

## Choose by app structure

| If your app… | Use |
|---|---|
| serves several topic namespaces on one socket | [Channel layer](/guides/channels/) |
| is a port of a Phoenix Channels design | [Channel layer](/guides/channels/) |
| wants colocated per-topic callbacks and state | [Channel layer](/guides/channels/) |
| consumes channels published by someone else | [Channel layer](/guides/channels/) |
| serves exactly one topic family | [Raw dispatch](/guides/dispatch/) |
| needs total control over routing and effect order | [Raw dispatch](/guides/dispatch/) |
| wants one model that spans every topic on a socket | [Raw dispatch](/guides/dispatch/) |

## Compare the APIs

|  | Channel layer | Raw dispatch |
|---|---|---|
| Package | `beryl` | `beryl` |
| Entry point | `channel.child_spec(config, handlers:)` | `beryl.child_spec(config, init:, update:)` |
| Routing | Handler table, first matching pattern wins | Your `update`, pattern matching on topics |
| Per-topic state | One private value per joined topic, pruned on close | Your own model; you prune it in the `Closed` branch |
| Server-side messages | One typed `info` type per channel | One typed `msg` type per socket |
| Side effects | Ordered `Action(Active)` lists scoped to the channel's topic | `socket.Effect` values naming any topic |
| Cleanup | `on_terminate` per channel | `socket.Closed(topic, reason)` in your `update` |
| Cross-topic effects | External `Sockets` APIs only | Direct, in any effect list |
| Routing code as channels grow | Handler list stays the same shape | More topic families require more branches |

## Use channel handlers for separate topic features

To add a topic family to raw dispatch, extend the socket model and message
union. Then add router branches. With the channel layer, add one handler to the
list.

The layer gives each channel a private state type and server-side message type.
Unrelated channels do not need a shared `Model` or `Msg`. A library can publish
a channel value for direct use.

## Use raw dispatch for socket-wide control

One `update` sees all events for a socket. An event on one topic can broadcast
on another topic in the same ordered effect list. Channel actions apply only to
their own topic. Use the `Sockets` handle for cross-topic publishing.

Raw dispatch has fewer concepts: no handler table and no routing rules other
than the ones you write.

## Use one API for each socket endpoint

Select one API for each socket endpoint. The channel layer owns the
socket-level model and message type. This design lets each channel keep private
state. Do not embed a channel system in a hand-written `update`. Different
endpoints can use different APIs and share presence, PubSub, and group actors.

A later migration changes routing code only. Both APIs use the same wire
format, join rules, presence payloads, and client code.

## Next steps

- [Channels](/guides/channels/) — the full channel-layer guide
- [Raw Dispatch](/guides/dispatch/) — route socket events in one update function
- [Quick Start](/quick-start/) — a working server on either layer
- [Coming from Phoenix](/guides/coming-from-phoenix/) — the concept map for both
