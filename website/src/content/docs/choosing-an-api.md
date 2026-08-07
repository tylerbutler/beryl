---
title: Choose an API
description: Channel layer or raw app-side dispatch — a short decision guide for beryl's two programming models.
---

beryl has one runtime and two ways to program it.

- **The channel layer** (`beryl_channels`) — register a list of channel
  handlers, one per topic pattern. Each channel keeps private state and a
  private server-side message type, and the layer routes every event to
  the channel that owns the topic. **This is the recommended default.**
- **Raw app-side dispatch** (`beryl`) — one `init`/`update` pair per
  socket. You match on `socket.Input` values and return ordered effects.
  This is the core; the channel layer is built on top of it, using nothing
  but its public API.

Both lower to the same runtime, wire codec, presence, PubSub, and abuse
controls. Neither is faster or more capable at the wire level — the
difference is who writes the router.

## Pick in one line

| If your app… | Use |
|---|---|
| serves several topic namespaces on one socket | [Channel layer](/guides/channels/) |
| is a port of a Phoenix Channels design | [Channel layer](/guides/channels/) |
| wants colocated per-topic callbacks and state | [Channel layer](/guides/channels/) |
| consumes channels published by someone else | [Channel layer](/guides/channels/) |
| serves exactly one topic family | [Raw dispatch](/guides/dispatch/) |
| needs total control over routing and effect order | [Raw dispatch](/guides/dispatch/) |
| wants one model that spans every topic on a socket | [Raw dispatch](/guides/dispatch/) |
| wants the smallest possible dependency set | [Raw dispatch](/guides/dispatch/) |

## Side by side

|  | Channel layer | Raw dispatch |
|---|---|---|
| Package | `beryl_channels` (adds `beryl`) | `beryl` |
| Entry point | `beryl_channels.child_spec(config, handlers:)` | `beryl.child_spec(config, init:, update:)` |
| Routing | Handler table, first matching pattern wins | Your `update`, pattern matching on topics |
| Per-topic state | One private value per joined topic, pruned on close | Your own model; you prune it in the `Closed` branch |
| Server-side messages | One typed `info` type per channel | One typed `msg` type per socket |
| Side effects | `Actions` scoped to the channel's topic | `socket.Effect` values naming any topic |
| Cleanup | `on_terminate` per channel | `socket.Closed(topic, reason)` in your `update` |
| Cross-topic effects | External `Sockets` APIs only | Direct, in any effect list |
| Boilerplate as channels grow | Constant | Grows with the number of topic families |

## What the layer buys you

Adding a fourth topic family to a raw-dispatch app means widening the
socket model, widening the message union, and adding branches to the
router — work that grows linearly with the number of channel types. With
the channel layer, it means adding one value to a list.

The layer also gives each channel a *private* state type and a *private*
server-side message type, so unrelated channels never have to agree on a
shared `Model` or `Msg`. And because a channel is just a value, a channel
can be published by a library and used without app-side wiring.

## What raw dispatch buys you

One `update` sees everything for a socket, so cross-topic behavior is
ordinary code: an event on one topic can broadcast on another in the same
effect list, in a guaranteed order. The channel layer gives that up on
purpose — its actions are always scoped to the channel's own topic, and
cross-topic publishing has to go through the `Sockets` handle.

Raw dispatch is also the smaller surface: no extra package, no handler
table, and no routing rules other than the ones you write.

## Mixing them

Pick one per socket endpoint. The channel layer owns the socket-level
model and message type — that is what lets channels keep private state —
so a channel system is not something you embed inside a hand-written
`update`. Two different endpoints in one application can use different
layers, and both can share the same presence, PubSub, and group actors.

Migrating later is a rewrite of your routing code, not of your protocol:
the wire format, join semantics, presence payloads, and client code are
identical either way.

## Next steps

- [Channels](/guides/channels/) — the full channel-layer guide
- [App-Side Dispatch](/guides/dispatch/) — the full raw-dispatch guide
- [Quick Start](/quick-start/) — a working server on either layer
- [Coming from Phoenix](/guides/coming-from-phoenix/) — the concept map for both
