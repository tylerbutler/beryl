# Beryl - Project Overview

## Purpose
Type-safe real-time channels and presence for Gleam, targeting the Erlang (BEAM) runtime. Inspired by Phoenix Channels.

## Tech Stack
- **Language**: Gleam (targeting Erlang/BEAM)
- **Runtime**: Erlang 27.2.1
- **Gleam version**: 1.14.0
- **Task runner**: just 1.38.0
- **Test framework**: gleeunit
- **Dependencies**: gleam_stdlib, gleam_erlang, gleam_otp, gleam_json, gleam_crypto, wisp (local path dep for WebSocket)

## Architecture Layers
1. **Channel System** (`beryl`, `beryl/channel`, `beryl/coordinator`) - Topic-based WebSocket messaging with pattern matching
2. **PubSub** (`beryl/pubsub`) - Distributed publish/subscribe via Erlang `pg` process groups
3. **Presence** (`beryl/presence`, `beryl/presence/state`) - Distributed presence tracking via CRDT (add-wins observed-remove set)
4. **Groups** (`beryl/group`) - Named channel groups for multi-topic broadcast
5. **Transport** (`beryl/transport/websocket`) - Wisp WebSocket transport integration
6. **Wire Protocol** (`beryl/wire`) - JSON encode/decode for the wire format
7. **Socket** (`beryl/socket`) - Socket abstraction with typed assigns
8. **Topic** (`beryl/topic`) - Topic pattern matching (exact and wildcard)

## Key Design Patterns
- Type erasure via Erlang FFI identity coercion for heterogeneous channel storage
- OTP actors for coordinator and presence
- Result types over exceptions
- Builder pattern for channel construction (`new()` + `with_*()` functions)
- Typed socket assigns (generic type parameter on Socket)

## Levee Integration
- `beryl/levee/document_channel` - Fluid Framework document channel
- `beryl/levee/runtime` - Elixir runtime bridge

## Source Structure
```
src/beryl.gleam                    # Main public API
src/beryl_ffi.erl                  # Erlang FFI (identity coercion)
src/beryl_pubsub_ffi.erl           # Erlang FFI for pg-based PubSub
src/beryl/channel.gleam            # Channel behaviour/callbacks
src/beryl/coordinator.gleam        # Channel lifecycle coordinator (OTP actor)
src/beryl/group.gleam              # Named channel groups
src/beryl/presence.gleam           # Presence tracking (OTP actor wrapping CRDT)
src/beryl/presence/state.gleam     # Pure CRDT (add-wins observed-remove set)
src/beryl/pubsub.gleam             # PubSub abstraction (pg-based)
src/beryl/socket.gleam             # Socket abstraction
src/beryl/topic.gleam              # Topic pattern matching
src/beryl/transport/websocket.gleam # Wisp WebSocket transport
src/beryl/wire.gleam               # Wire protocol (JSON encode/decode)
src/beryl/levee/document_channel.gleam
src/beryl/levee/runtime.gleam
```

## Tests
```
test/beryl_test.gleam
test/group_test.gleam
test/presence_test.gleam
test/presence_state_test.gleam
test/pubsub_test.gleam
```

## Note on Serena
The Gleam language server is not supported by Serena, so symbolic tools (get_symbols_overview, find_symbol, etc.) will not work. Use file-based tools (read_file, search_for_pattern, list_dir) instead.
