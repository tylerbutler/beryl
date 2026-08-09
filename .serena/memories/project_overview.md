# Beryl - Project Overview

## Purpose

Type-safe real-time sockets, channels, PubSub, and presence for Gleam on the
Erlang/BEAM runtime, with Phoenix V2 wire compatibility.

## Tech Stack

- **Language/runtime**: Gleam on Erlang/OTP
- **Tool versions**: `.tool-versions` (Erlang 27.2.1, Gleam 1.16.0, just 1.50.0)
- **Workspace/release tooling**: trellis
- **Tests**: gleeunit; Playwright for examples
- **Transports**: Mist (`beryl_mist`) and Ewe (`beryl_ewe`)

## Architecture Layers

1. **App dispatch** (`beryl`, `beryl/event`, internal `beryl/runtime`) -
   `beryl.child_spec` captures typed `init`/`update` callbacks; one supervised
   runtime owns socket models, topic membership, heartbeat state, and ordered
   effect interpretation.
2. **Transport SPI** (`beryl/transport`) - connection ownership, atomic socket
   admission, frame decoding/routing, edge rate limiting, and telemetry.
3. **PubSub** (`beryl/pubsub`) - distributed broadcasts through Erlang `pg`.
4. **Presence** (`beryl/presence`) - CRDT-backed distributed presence actor.
5. **Groups** (`beryl/group`) - named collections of topics for broadcast.
6. **Wire protocol** (`beryl/wire`, `beryl/wire/codec`) - Phoenix text and
   binary framing.
7. **Observability and controls** (`beryl/stats`, internal telemetry, connection
   and rate limits).

## Key Design Patterns

- Opaque `Sockets` and configuration values with builder functions.
- Typed per-socket `model` and `msg`; decoded payloads alone use `Dynamic`.
- `Event`/`Next`/`Effect` app loop with strict effect-list wire ordering.
- Join `Ref` values carry unique pending-join identity; stale completions cannot
  answer a replacement join even when wire correlation fields are reused.
- Transport admission binds to an exact runtime pid and uses a cancellation
  token so timed-out admissions cannot later register or apply init effects.
- PubSub validates its frozen raw record shape before the package-internal
  identity coercion needed at the Erlang mailbox boundary.
- Result types, exhaustive matching, and supervised OTP lifecycle.

## Source Structure

```text
packages/beryl/src/beryl.gleam             # Config, child_spec, stop, broadcast
packages/beryl/src/beryl/event.gleam       # Events, effects, refs, Sender
packages/beryl/src/beryl/runtime.gleam     # Internal app-dispatch runtime
packages/beryl/src/beryl/transport.gleam   # Public transport SPI
packages/beryl/src/beryl/pubsub.gleam      # Typed pg-based PubSub
packages/beryl/src/beryl/presence.gleam    # Presence actor
packages/beryl/src/beryl/group.gleam       # Topic groups
packages/beryl/src/beryl/stats.gleam       # Runtime stats
packages/beryl/src/beryl/wire.gleam        # Built-in wire codecs
packages/beryl_mist/src/beryl_mist.gleam   # Mist transport
packages/beryl_ewe/src/beryl_ewe.gleam     # Ewe transport
```

## Testing Notes

- BEAM mailbox state matters: select exact message shapes and drain messages
  created by tests.
- Prefer polling helpers over sleeps for asynchronous state.
- Public socket/event behavior needs runtime-level coverage; transport behavior
  needs Mist and Ewe contract coverage.

## Note on Serena

The Gleam language server is not supported by Serena, so use file-based search
and editing tools rather than symbolic tools.
