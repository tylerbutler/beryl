# beryl changelog

## v0.2.0 - 2026-08-07

### Added

- New app-side dispatch API (ADR 0002): `beryl.start_app(config, init, update)` with `beryl/event` (`Event`/`Next`/`Effect`, typed `Sender`/`notify`, `ConnectInfo`), per-topic-pattern rate limits via `with_topic_rate`, single-use reply refs with duplicate-outstanding rejection, and the existing socket/channel/broadcast telemetry schema. The channel-module API is unchanged; both run side by side during the migration.

### Changed

- PubSub now uses a typed `Subscriber(payload)` handle that can join or leave many topics while preserving the frozen raw `Message(payload)` record sent between BEAM nodes: replace `pubsub.subscribe`/`pubsub.unsubscribe` with `pubsub.subscriber` plus `join`/`leave`, and pass that subscriber to `pubsub.selecting`, which keeps raw-mailbox recovery inside the library. `beryl/bridge` is decoupled from channels and now forwards to an `event.Sender` via `event.notify` — `bridge.start(to:, with:)` returns a `Result` and no longer takes a RegisteredChannel, socket id, or topic. Distributed broadcast shape and semantics, sender exclusion, and subscriber counts are unchanged.
- Transport SPI: transports capture `connection_owner`, monitor the exact app runtime, then atomically register the socket, closer, and `ConnectSeed` with `transport.admit_socket`; channel-module systems remain unmonitored.

### Fixed

- Preserve binary message classification when transports decode binary frames before routing them to the app runtime.
- Prevent stale same-topic join completions and timed-out admissions from affecting live sockets.
- Recover the app runtime subtree after nested supervisor restart-intensity exhaustion.
- Recover the app supervisor when the runtime crashes during beryl.stop so later stops and restart exhaustion remain correct.

### Removed

- `beryl.start` and `beryl.StartError` are no longer public. Starting a channel system without supervision left a runtime crash unrecoverable and every connected socket stranded, so the API no longer offers it as a choice. Applications build beryl with `beryl.child_spec` and add the returned child specification to their own OTP supervision tree. `beryl.stop` remains available for gracefully stopping an app-dispatch runtime.

## v0.1.0 - 2026-08-07

### Added

- App-side dispatch API: `beryl.start_app(config, init, update)` with `beryl/event` (`Event`/`Next`/`Effect`, typed `Sender`/`notify`, `ConnectInfo`), per-topic-pattern rate limits via `with_topic_rate`, single-use reply refs with duplicate-outstanding rejection, and socket/channel/broadcast telemetry. The channel-module API is unchanged; both can run side by side.
- Initial release: type-safe Phoenix-style real-time channels for Gleam on the BEAM. Channel join/message/info/terminate callbacks with typed assigns and typed server-originated messages (send_info and the beryl/bridge actor forwarder), segment-aware topic pattern matching with wildcards, broadcasts including broadcast_from sender exclusion, Phoenix-compatible error/close reply semantics, named channel groups, and OTP supervision via beryl/supervisor.
- Abuse controls and hardening: heartbeat-based socket eviction, per-socket message/join/channel token-bucket rate limits, per-IP and node-wide connection ceilings, frame-size/topic-length/event-length caps, callback crash isolation, and a startup warning when no controls are configured.
- Structured logging through palabres with configurable level and bounded, opt-in payload previews, plus a public transport SPI (beryl/transport) so WebSocket transports such as beryl_mist can be implemented outside the core package.
- Added `transport.socket_connected_with_codec`, letting a transport announce a socket that frames its outbound messages with its own codec instead of the configured one. One coordinator — sharing channels, pubsub, and presence — can serve transports speaking different wire formats. `socket_connected` is unchanged.
- Phoenix-compatible presence tracking backed by lattice_presence CRDTs: track/untrack with server-minted refs, presence_state and presence_diff wire encoding (including phx_ref metas), and cluster replication over PubSub guarded by an exception boundary.
- pg-based PubSub for multi-node broadcast fan-out and presence replication. `PubSub`/`Message` are generic over a `payload` type — broadcasts travel as native BEAM terms, with no forced JSON encoding — and `pubsub.selecting` lets any gleam_erlang/gleam_otp actor receive them through its own `Selector` without touching raw process messages. The wire shape is frozen per `payload` type across the trusted Erlang cluster boundary.
- Phoenix V2 wire protocol (JSON text framing and the binary subprotocol) as the default codec, plus a pluggable codec API (beryl/wire/codec) for custom text/binary framing with opt-in topicless events and close/error encoders.

### Dependencies

- Update locked Gleam dependencies.
