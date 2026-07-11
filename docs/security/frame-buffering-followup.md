# Follow-up: enforce frame limits before WebSocket payload buffering

Tracking record for the upstream half of GitHub issue #198,
"Enforce frame limits before WebSocket payload buffering".

## Summary of the gap

`beryl.with_max_inbound_frame_bytes` is enforced **post-assembly**: it runs in
Beryl's transport callback only after Mist/gramps has already buffered and
reassembled a complete `Text`/`Binary` frame. The transport buffers
incomplete, slowly-streamed, or fragmented (continuation) payloads with **no
configurable pre-buffer size cap**, so a single connection can grow the BEAM
receive buffer without ever tripping Beryl's frame-size or message-rate checks.
One connection can exhaust node memory.

Mist's only size limit, `max_body_limit`, applies to HTTP request bodies
(via the `content-length` header), not to WebSocket frames.

## Code locations

### Beryl (where the limit is enforced — too late)

- `src/beryl/transport/mist.gleam:445-463` — `on_message` measures
  `string.byte_size(text)` / `bit_array.byte_size(data)` and calls
  `mist.stop()` when `frame_too_large` is true. This only fires **after** Mist
  emits a complete `Text`/`Binary` message, i.e. after buffering/aggregation.
- `src/beryl/transport/mist.gleam:556-558` — `frame_too_large(max_bytes,
  actual_bytes)` predicate; operates on an already-assembled payload length.
- `src/beryl.gleam` — `with_max_inbound_frame_bytes` doc comment (now corrected
  to state the post-assembly semantics and the edge-proxy requirement).

### mist 6.0.3 (buffers before Beryl ever sees a frame)

- `build/packages/mist/src/mist/internal/websocket.gleam:43` — `WebsocketState`
  carries a `buffer: BitArray` field.
- `build/packages/mist/src/mist/internal/websocket.gleam:133-157` — on each
  inbound TCP chunk it does
  `websocket.decode_many_frames(<<state.buffer:bits, data:bits>>, ...)` then
  `websocket.aggregate_frames(None, [])`, and stores the still-incomplete
  remainder back into `state.buffer` (`WebsocketState(..state, buffer: rest,
  ...)`). There is **no cap** on the size of `state.buffer`; it grows until a
  frame completes.
- `build/packages/mist/src/mist.gleam:220-239` — `read_body` /
  `max_body_limit` is HTTP-body only (checks `content-length`), unrelated to
  WebSocket frame buffering.

### gramps 6.0.1 (frame decode + fragmentation aggregation, no size guard)

- `build/packages/gramps/src/gramps/websocket.gleam:85-160` — `decode_frame`
  reads the 7-bit `payload_length`, expands it to a 16- or 64-bit extended
  length, then pattern-matches `payload:bytes-size(payload_byte_size)`. When
  the declared payload has not fully arrived it returns
  `Error(NeedMoreData(message))`, retaining the whole buffer. **No maximum is
  applied to the declared length**, so a header can declare an arbitrarily
  large payload and the caller keeps buffering until it arrives.
- `build/packages/gramps/src/gramps/websocket.gleam:451-474` —
  `aggregate_frames` joins `Continuation` fragments via `append_frame`
  (BitArray concatenation) with **no cumulative size limit**, so a long run of
  fragmented frames aggregates into one unbounded buffer.

## Concrete options for the upstream fix

1. **Upstream a size cap into gramps/mist (preferred).**
   - Add a configurable `max_frame_bytes` (or reuse a WebSocket-specific limit)
     that `decode_frame` checks against the *declared* extended payload length
     immediately after parsing the header, returning an error (leading to a
     `1009 Message Too Big` close) instead of `NeedMoreData` for oversized
     declarations.
   - Add a cumulative cap in `aggregate_frames` / the mist buffering loop so
     fragmented continuation frames cannot exceed the same limit in aggregate.
   - Thread the limit through `mist`'s WebSocket handler config so Beryl can
     set it from `with_max_inbound_frame_bytes`.
   - This is the only option that yields a true in-process memory bound; it
     requires PRs to gramps and mist and a released version bump.

2. **Pin a patched fork of gramps/mist.**
   - Carry the size-cap patch in a fork pinned via `gleam.toml` until the
     upstream change is released. Higher maintenance cost; acceptable as a
     stopgap if the memory bound must ship before upstream merges.

3. **Mandate an edge-proxy / load-balancer frame-size limit (shipped now).**
   - Documented in the README "Security & deployment" section and in the
     `with_max_inbound_frame_bytes` doc comment. An nginx/HAProxy/Envoy/cloud-LB
     WebSocket frame-size limit (plus request/body size limit for the upgrade)
     rejects oversized frames at the edge before the BEAM node buffers them.
   - This is operational, not in-process, and depends on correct deployment
     configuration — but it is the only mitigation fully within reach today.

## Status of issue #198 acceptance criteria

Closed by the docs branch (`fix/frame-limit-buffering-docs`):

- [x] Documentation states the remaining transport/proxy requirements
  accurately (doc comment + README + this tracking doc).

Still OPEN — require the upstream/dependency change above:

- [ ] Bound transport memory *before* payload accumulation.
- [ ] Close oversized frames after header parse (reject on declared length,
  before buffering the body).
- [ ] Bound fragmented/continuation aggregation to the same limit.
- [ ] Tests for slowly-streamed and fragmented oversized payloads.
