# Portable channel protocol core

Status: Proposal

Date: 2026-10-27

## Goal

Extract beryl's channel protocol state machine into a Gleam package that
supports Erlang and JavaScript. Reuse its lifecycle rules with the official
Phoenix JavaScript client and a Cloudflare Durable Object host. Keep beryl's
existing BEAM APIs and behavior.

The first consumer is Monk: one Durable Object owns one match, while each
connection joins a `match:<code>` channel. Monk keeps its game authority,
authorization, snapshots, sequence checks, and command deduplication.

## Current constraints

`packages/beryl` targets Erlang. `beryl/runtime` combines protocol handling
with actors, supervision, rate limiting, PubSub, and presence operations.
`beryl/socket` uses Erlang references for join and reply capabilities.
`beryl/channel` depends on supervised topic workers.

The codec interface and topic helpers already use standard Gleam types.
Roost supports Phoenix framing on both targets, but provides no channel
lifecycle runtime.

## Package and runtime boundaries

Add `packages/beryl_protocol` as a dual-target package. It owns topic/event
validation, per-connection membership, join/reply correlation, heartbeat
deadlines, and ordered protocol actions. Its runtime dependencies must support
both targets; exclude OTP, Erlang references, transport APIs, and global state.

Use an explicit transition interface:

```text
step(state, input, now_ms) -> Result((next_state, ordered_actions), error)
```

Inputs include decoded frames, application decisions, timer expiry, and
connection closure. Actions include application notifications, outbound
messages, connection closure, and the next required deadline. The host owns
I/O, scheduling, authentication, and application callbacks. The core performs
no clock reads or socket writes.

Keep framing behind a codec boundary. Use Roost for the JavaScript host's
Phoenix frames. Preserve beryl's public codec API and existing text/binary
behavior; do not make a codec replacement part of the extraction.

The BEAM runtime must use the extracted transitions rather than retain a
second implementation. Keep actor supervision, queues, distributed PubSub,
presence, and effect execution in the BEAM package. Preserve the public
transport SPI and the channel layer's public-core import boundary.

## Required behavior

- Accept or reject joins through application authorization. Replace an
  existing same-topic instance through its normal cleanup path.
- Send a successful join reply before initial channel pushes.
- Reject or drop stale-instance messages and leaves according to existing
  beryl behavior.
- Keep reply handles single-use. Invalidate outstanding handles on topic
  closure or replacement, including when a client reuses a wire reference.
- Replace Erlang reference identity inside the core with opaque
  connection/channel generations and unique operation identifiers. Generate
  these independently of client-provided references. Preserve capability
  semantics through the existing BEAM API.
- Answer heartbeats with the matching reference. Let the host schedule
  deadline checks and execute timeout cleanup.
- Preserve ordered actions, bounded pending-operation capacity, and current
  cleanup guarantees. Do not copy BEAM-specific queue machinery into the core.

## Durable Object host

Provide a minimal integration example or test host. Map WebSocket events to
core inputs and execute actions in order. Put credentials in the channel join
payload, not the URL.

Define a versioned state export/restore format for connection attachments.
Retain channel generations and correlation state across hibernation.
Do not serialize callbacks or process handles. On restore, invalidate pending
application work that the host cannot recover and provide a defined retry or
rejoin path. Reconstruct deadlines without comparing monotonic timestamps
from different runtime instances.

Keep transport disconnect/channel leave separate from leaving Monk's roster.
Reauthorize on rejoin and obtain a fresh authoritative game snapshot.
Phoenix message references do not replace Monk's stable command IDs.

## Scope limits

Exclude a JavaScript port of OTP supervision, distributed presence, PubSub,
groups, Mist/Ewe, and the complete typed channel-worker API. Do not change
Monk's game rules or deploy either application.

## Acceptance and migration

1. Run the same pure transition cases on Erlang and JavaScript. Cover join
   rejection/replacement, action order, stale generations, deferred replies,
   wire-reference reuse, capacity limits, heartbeat expiry, and restoration.
2. Keep the existing BEAM runtime, transport, and raw-dispatch/channel parity
   tests passing after routing protocol handling through the new core.
3. Use shared Phoenix wire fixtures and the official Phoenix JavaScript client
   against the test host. Check joins, replies, disconnect/rejoin, heartbeat
   loss, and restoration without duplicate application commands.
4. Prove the JavaScript dependency graph has no BEAM-only modules. Keep
   beryl's existing public APIs compatible and document the new host contract.

Extract and adopt one lifecycle path at a time under existing integration
tests. Validate the Durable Object host before integrating it into Monk.
