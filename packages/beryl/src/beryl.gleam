//// Beryl - Type-safe real-time communication
////
//// A standalone Gleam library for building real-time applications on the BEAM.
//// Provides WebSocket channels, distributed presence tracking, pub/sub
//// messaging, and channel groups.
////
//// ## Features
////
//// - **Channels** — Topic-based WebSocket messaging with pattern matching
////   (`beryl`, `beryl/channel`)
//// - **PubSub** — Distributed publish/subscribe via Erlang `pg`
////   (`beryl/pubsub`)
//// - **Presence** — Distributed presence tracking backed by a causal-context
////   CRDT (add-wins observed-remove set) (`beryl/presence`)
//// - **Groups** — Named collections of topics for multi-topic broadcasting
////   (`beryl/group`)
////
//// ## Quick Start
////
//// ```gleam
//// import beryl
//// import beryl/channel
//// import beryl/pubsub
//// import beryl/presence
//// import beryl/group
//// import beryl/wire
////
//// pub fn main() {
////   // Optional: start PubSub for distributed messaging
////   let ps = pubsub.start(pubsub.default_config())
////
////   // Start channels system (with or without PubSub)
////   let config = beryl.config(wire.phoenix_codec()) |> beryl.with_pubsub(ps)
////   let assert Ok(channels) = beryl.start(config)
////
////   // Register a channel handler
////   let _ = beryl.register(channels, "room:*", room_channel.new())
////
////   // Start presence tracking
////   let assert Ok(p) = presence.start(presence.default_config("node1"))
////
////   // Start channel groups
////   let assert Ok(groups) = group.start()
////   let assert Ok(Nil) = group.create(groups, "team:eng")
////   let assert Ok(Nil) = group.add(groups, "team:eng", "room:frontend")
////
////   // Broadcast to all topics in a group
////   group.broadcast(groups, channels, "team:eng", "announce", payload)
//// }
//// ```

import beryl/channel.{type Channel}
import beryl/connection_limit
import beryl/coordinator
import beryl/error as beryl_error
import beryl/event
import beryl/internal
import beryl/log
import beryl/presence.{type Diff}
import beryl/presence/wire as presence_wire
import beryl/pubsub.{type PubSub}
import beryl/rate_limit
import beryl/runtime
import beryl/socket.{type Socket}
import beryl/topic
import beryl/wire/codec
import gleam/bool
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

type ChannelHandler =
  coordinator.ChannelHandler

/// A typed handle returned when a channel is registered.
///
/// Pass this handle to `send_info` so the compiler can prove that the message
/// matches the receiving channel's `info` type. The handle also identifies the
/// exact registered channel used for a joined socket/topic pair.
///
/// The `assigns` and `info` parameters are phantom: they carry the registered
/// channel's types so `send_info` is type-checked, while the handle itself
/// stores only the coordinator subject and the registration id.
pub opaque type RegisteredChannel(assigns, info) {
  RegisteredChannel(coordinator: Subject(coordinator.Message), id: Int)
}

/// Errors when registering a channel handler.
pub type RegisterError {
  /// A handler is already registered for this exact topic pattern.
  PatternAlreadyRegistered(String)
  /// The topic pattern is invalid. Patterns must be non-empty and must not
  /// contain control characters (codepoints 0–31 or 127).
  InvalidPattern(String)
}

/// Logging verbosity for Beryl's internal loggers.
///
/// The variants carry a `Level` suffix so `ErrorLevel` does not shadow the
/// prelude's `Result` `Error` constructor when imported unqualified.
pub type LogLevel {
  DebugLevel
  InfoLevel
  WarnLevel
  ErrorLevel
}

/// Logging configuration for Beryl diagnostics.
///
/// This type is opaque: construct it with `logging_config` and adjust it with
/// the `with_*` builder functions so Beryl can add logging options without a
/// breaking change.
pub opaque type LoggingConfig {
  LoggingConfig(
    /// Minimum level emitted by Beryl's namespaced loggers.
    level: LogLevel,
    /// Whether debug diagnostics may include bounded payload/frame previews.
    include_payloads: Bool,
    /// Maximum number of bytes/characters included in payload previews.
    payload_preview_bytes: Int,
  )
}

// nolint: unused_exports -- package-internal accessors for tests; hidden from public docs with @internal
@internal
pub fn logging_level(logging: LoggingConfig) -> LogLevel {
  logging.level
}

@internal
pub fn logging_include_payloads(logging: LoggingConfig) -> Bool {
  logging.include_payloads
}

@internal
pub fn logging_payload_preview_bytes(logging: LoggingConfig) -> Int {
  logging.payload_preview_bytes
}

/// Configuration for the channels system.
///
/// This type is opaque: construct it with `config` and adjust it with the
/// `with_*` builder functions. Keeping it opaque lets Beryl add configuration
/// options in the future without a breaking change.
pub opaque type Config {
  Config(
    /// Wire codec used to decode inbound text and encode replies/pushes.
    /// Use `wire.phoenix_codec()` for the historical Phoenix array format.
    codec: codec.Codec,
    /// Client-advisory heartbeat interval in milliseconds (default: 30000).
    /// The server does not read this value; it is the interval clients should
    /// use for their own pings. See `with_heartbeat`.
    heartbeat_interval_ms: Int,
    /// Server-side heartbeat staleness window in milliseconds (default: 60000).
    /// Sockets that send no heartbeat within this window are evicted. Must be
    /// at least 2 (see `with_heartbeat`).
    heartbeat_timeout_ms: Int,
    /// Max connections per IP (0 = unlimited)
    max_connections_per_ip: Int,
    /// Max concurrent connections node-wide across all IPs (0 = unlimited)
    max_connections: Int,
    /// Optional PubSub for distributed broadcasts across nodes
    pubsub: Option(PubSub(json.Json)),
    /// Per-socket message rate limit (messages/sec, 0 = unlimited)
    message_rate: Int,
    /// Per-socket message burst capacity (0 = defaults to message_rate)
    message_burst: Int,
    /// Per-socket join rate limit (joins/sec, 0 = unlimited)
    join_rate: Int,
    /// Per-socket join burst capacity (0 = defaults to join_rate)
    join_burst: Int,
    /// Per-channel message rate limit (messages/sec per socket+topic, 0 = unlimited)
    channel_rate: Int,
    /// Per-channel message burst capacity (0 = defaults to channel_rate)
    channel_burst: Int,
    /// Maximum active per-channel rate-limit buckets per socket.
    /// Values <= 0 disable the cap.
    channel_rate_max_keys_per_socket: Int,
    /// Maximum byte length for client-supplied topic strings (default: 256).
    /// Topics exceeding this limit are rejected with a `phx_reply` error before
    /// reaching a channel handler.
    max_topic_length: Int,
    /// Maximum byte length for client-supplied event name strings (default: 64).
    /// Events exceeding this limit are dropped before reaching a channel handler.
    max_event_length: Int,
    /// Maximum inbound WebSocket frame size in bytes (default: 1 MiB).
    /// Frames exceeding this limit are closed before wire decoding.
    max_inbound_frame_bytes: Int,
    /// Maximum joined topics per socket (default: 1000).
    /// Values <= 0 disable the cap.
    max_joined_topics_per_socket: Int,
    /// Logging configuration for Beryl diagnostics
    logging: LoggingConfig,
    /// Per-topic-pattern message rate limits (app-dispatch systems only).
    /// Ordered; the first matching pattern wins.
    topic_rates: List(#(String, rate_limit.RateLimitConfig)),
    /// Presence handle used by the `PresenceTrack`/`PresenceUntrack`
    /// effects (app-dispatch systems only).
    presence: Option(presence.Presence),
  )
}

/// Build a logging configuration.
///
/// Payloads are excluded by default to avoid accidental sensitive-data
/// exposure. Use `with_payload_preview_bytes` to adjust the bounded preview
/// size when payload previews are enabled.
pub fn logging_config(
  level level: LogLevel,
  include_payloads include_payloads: Bool,
) -> LoggingConfig {
  LoggingConfig(
    level: level,
    include_payloads: include_payloads,
    payload_preview_bytes: 200,
  )
}

/// Build a configuration with sensible defaults.
///
/// A `codec` is required — beryl no longer ships an implicit Phoenix
/// default. Pass `wire.phoenix_codec()` to keep Phoenix wire compatibility,
/// or your own `Codec` for a custom framing.
pub fn config(codec: codec.Codec) -> Config {
  Config(
    codec: codec,
    heartbeat_interval_ms: 30_000,
    heartbeat_timeout_ms: 60_000,
    max_connections_per_ip: 0,
    max_connections: 0,
    pubsub: None,
    message_rate: 0,
    message_burst: 0,
    join_rate: 0,
    join_burst: 0,
    channel_rate: 0,
    channel_burst: 0,
    channel_rate_max_keys_per_socket: 1000,
    max_topic_length: 256,
    max_event_length: 64,
    max_inbound_frame_bytes: 1_048_576,
    max_joined_topics_per_socket: 1000,
    logging: logging_config(level: InfoLevel, include_payloads: False),
    topic_rates: [],
    presence: None,
  )
}

/// Configure a per-topic-pattern message rate limit for app-dispatch
/// systems (`start_app`).
///
/// Patterns use the same syntax as topic routing (`"room:*"`,
/// `"document:*:ops"`, `"*"`). Limits are consulted in the order they were
/// added and the first matching pattern wins; topics matching no pattern
/// fall back to the global `with_channel_rate` limit. The limiter applies
/// only after a socket has joined the topic.
pub fn with_topic_rate(
  config: Config,
  pattern pattern: String,
  per_second rate: Int,
  burst burst: Int,
) -> Config {
  Config(
    ..config,
    topic_rates: list.append(config.topic_rates, [
      #(pattern, rate_limit.config(per_second: rate, burst: burst)),
    ]),
  )
}

/// Attach a presence handle for app-dispatch systems (`start_app`), used
/// by the `PresenceTrack`/`PresenceUntrack` effects. Without a handle
/// those effects are dropped with a warning.
pub fn with_presence_handle(
  config: Config,
  presence presence: presence.Presence,
) -> Config {
  Config(..config, presence: Some(presence))
}

/// Add PubSub to a configuration for distributed broadcasts
pub fn with_pubsub(config: Config, ps: PubSub(json.Json)) -> Config {
  Config(..config, pubsub: Some(ps))
}

/// Configure heartbeat timing.
///
/// `interval_ms` is **client-advisory only**: it is the interval clients should
/// use for their own outbound pings. The server never reads it and does not use
/// it to schedule anything — it exists purely to communicate a suggested ping
/// cadence to clients.
///
/// `timeout_ms` is the server-side staleness window — a socket that sends no
/// heartbeat within this window is evicted. The server derives its internal
/// check interval as `timeout_ms / 2` (integer division), so `timeout_ms` must
/// be at least 2; smaller values are rejected by `start` with
/// `InvalidHeartbeatTimeout` because a check interval of 0 would disable
/// eviction. The defaults are 30000 ms and 60000 ms respectively.
pub fn with_heartbeat(
  config: Config,
  interval_ms interval_ms: Int,
  timeout_ms timeout_ms: Int,
) -> Config {
  Config(
    ..config,
    heartbeat_interval_ms: interval_ms,
    heartbeat_timeout_ms: timeout_ms,
  )
}

/// Configure the maximum number of concurrent connections allowed per client
/// IP address.
///
/// A value of 0 (the default) means unlimited. When a limit is set, a transport
/// admits a new connection only while the peer is below the limit and rejects
/// it otherwise; the slot is freed when the connection closes.
///
/// ## Which IP is used
///
/// The limit is enforced on the **real socket peer IP** as reported by the
/// transport (for the Mist transport, the address of the TCP connection).
/// Beryl deliberately does **not** trust or parse forwarded headers such as
/// `X-Forwarded-For`, because a client can set them freely and would otherwise
/// be able to spoof its address and bypass this limit.
///
/// If Beryl runs behind a trusted reverse proxy or load balancer, every
/// connection shares the proxy's address, so a per-IP limit throttles all
/// clients as a single IP. In that topology you must resolve the real client
/// IP yourself at the proxy layer (for example, by enforcing limits there). A
/// built-in trusted-proxy opt-in may be added in a future release. See the
/// WebSocket transport guide for deployment guidance.
pub fn with_max_connections_per_ip(
  config: Config,
  max_connections max_connections: Int,
) -> Config {
  Config(..config, max_connections_per_ip: max_connections)
}

/// Configure the maximum number of concurrent connections allowed across the
/// whole node, regardless of source IP.
///
/// A value of 0 (the default) means unlimited. When a limit is set, a transport
/// admits a new connection only while the node is below the limit and rejects
/// it (before allocating any long-lived channel/coordinator state) otherwise;
/// the slot is freed when the connection closes, its process dies, or its
/// handshake/setup fails. The check-and-increment is atomic inside the limiter
/// actor, so a burst of concurrent opens cannot materially exceed the ceiling.
///
/// ## Composition with per-IP limits
///
/// This node-wide ceiling composes with `with_max_connections_per_ip`: when
/// both are set a connection must be under *both* limits to be admitted. The
/// per-IP limit throttles any single abusive peer, while this global ceiling
/// bounds the node's total resource use so that many distinct source addresses
/// (for example a botnet or IPv6 address rotation) still cannot exhaust the
/// node's process, socket, and coordinator budget — a case a per-IP limit alone
/// cannot stop.
///
/// ## Composition with external load balancers
///
/// This ceiling is enforced per BEAM node. If you run several nodes behind a
/// load balancer, each node enforces its own limit independently, so the
/// cluster's effective ceiling is roughly `max_connections × node_count`
/// (subject to how the balancer distributes connections). Size the per-node
/// value against a single node's capacity, and use the load balancer's own
/// global connection/rate controls when you need a cluster-wide cap.
pub fn with_max_connections(
  config: Config,
  max_connections max_connections: Int,
) -> Config {
  Config(..config, max_connections: max_connections)
}

/// Configure Beryl's internal logging.
pub fn with_logging(config: Config, logging: LoggingConfig) -> Config {
  Config(..config, logging: logging)
}

/// Configure the maximum payload/frame preview length for logs.
pub fn with_payload_preview_bytes(
  logging: LoggingConfig,
  bytes bytes: Int,
) -> LoggingConfig {
  LoggingConfig(..logging, payload_preview_bytes: int.max(bytes, 0))
}

fn coordinator_log_level(level: LogLevel) -> coordinator.LogLevel {
  case level {
    DebugLevel -> coordinator.Debug
    InfoLevel -> coordinator.Info
    WarnLevel -> coordinator.Warn
    ErrorLevel -> coordinator.Err
  }
}

fn coordinator_logging(logging: LoggingConfig) -> coordinator.LoggingConfig {
  coordinator.LoggingConfig(
    level: coordinator_log_level(logging.level),
    include_payloads: logging.include_payloads,
    payload_preview_bytes: logging.payload_preview_bytes,
  )
}

/// Configure per-socket message rate limiting
pub fn with_message_rate(
  config: Config,
  per_second rate: Int,
  burst burst: Int,
) -> Config {
  Config(..config, message_rate: rate, message_burst: burst)
}

/// Configure per-socket join rate limiting
pub fn with_join_rate(
  config: Config,
  per_second rate: Int,
  burst burst: Int,
) -> Config {
  Config(..config, join_rate: rate, join_burst: burst)
}

/// Configure per-channel message rate limiting.
///
/// The limiter applies only after a socket has joined a topic. Active
/// per-socket channel buckets are capped by default; use
/// `with_channel_rate_max_keys_per_socket` to adjust the cap.
pub fn with_channel_rate(
  config: Config,
  per_second rate: Int,
  burst burst: Int,
) -> Config {
  Config(..config, channel_rate: rate, channel_burst: burst)
}

/// Configure the maximum active per-channel rate-limit buckets per socket.
///
/// Values <= 0 disable the cap. The default is 1000.
pub fn with_channel_rate_max_keys_per_socket(
  config: Config,
  max_keys max_keys: Int,
) -> Config {
  Config(..config, channel_rate_max_keys_per_socket: max_keys)
}

/// Configure the maximum allowed byte length for client-supplied topic
/// strings.
///
/// Topics longer than `max_length` bytes are rejected with a `phx_reply`
/// error before reaching a channel handler, bounding the size of keys stored
/// in the coordinator's topic registry. The default is 256.
pub fn with_max_topic_length(
  config: Config,
  max_length max_length: Int,
) -> Config {
  Config(..config, max_topic_length: max_length)
}

/// Configure the maximum allowed byte length for client-supplied event name
/// strings.
///
/// Event names longer than `max_length` bytes are dropped before reaching a
/// channel handler. The default is 64.
pub fn with_max_event_length(
  config: Config,
  max_length max_length: Int,
) -> Config {
  Config(..config, max_event_length: max_length)
}

/// Configure the maximum allowed inbound WebSocket frame size in bytes.
///
/// The limit is enforced **post-assembly**: the transport (Mist/gramps)
/// buffers and assembles a complete frame first, and only then does Beryl
/// measure it and close the connection if it exceeds `max_bytes`. This bounds
/// per-message processing cost (decode, routing, rate-limit accounting), but
/// it does **not** by itself bound transport memory. A hostile client can
/// declare a huge payload and stream it slowly, or send many fragmented
/// continuation frames, and the transport's receive buffer grows before this
/// check ever runs — so this setting alone does not stop a single connection
/// from exhausting node memory.
///
/// For a true transport memory bound you **must** place an edge proxy or load
/// balancer in front of Beryl and configure a WebSocket frame-size limit
/// there (and a matching request/body size limit). Beryl's per-IP connection
/// limit and per-socket message-rate limit do not mitigate this vector. See
/// the "Security & deployment" section of the README and
/// `docs/security/frame-buffering-followup.md` for details.
///
/// Values <= 0 disable the cap. The default is 1 MiB.
pub fn with_max_inbound_frame_bytes(
  config: Config,
  max_bytes max_bytes: Int,
) -> Config {
  Config(..config, max_inbound_frame_bytes: max_bytes)
}

/// Configure the maximum number of topics a socket may join at once.
///
/// Values <= 0 disable the cap. The default is 1000.
pub fn with_max_joined_topics_per_socket(
  config: Config,
  max_topics max_topics: Int,
) -> Config {
  Config(..config, max_joined_topics_per_socket: max_topics)
}

// nolint: unused_exports -- package-internal accessors for supervisor/tests; hidden from public docs with @internal
@internal
pub fn config_heartbeat_interval_ms(config: Config) -> Int {
  config.heartbeat_interval_ms
}

@internal
pub fn config_heartbeat_timeout_ms(config: Config) -> Int {
  config.heartbeat_timeout_ms
}

@internal
pub fn config_max_connections_per_ip(config: Config) -> Int {
  config.max_connections_per_ip
}

@internal
pub fn config_max_connections(config: Config) -> Int {
  config.max_connections
}

@internal
pub fn config_pubsub(config: Config) -> Option(PubSub(json.Json)) {
  config.pubsub
}

@internal
pub fn config_logging(config: Config) -> LoggingConfig {
  config.logging
}

@internal
pub fn config_join_rate(config: Config) -> Int {
  config.join_rate
}

@internal
pub fn config_join_burst(config: Config) -> Int {
  config.join_burst
}

@internal
pub fn config_channel_rate(config: Config) -> Int {
  config.channel_rate
}

@internal
pub fn config_channel_burst(config: Config) -> Int {
  config.channel_burst
}

@internal
pub fn config_channel_rate_max_keys_per_socket(config: Config) -> Int {
  config.channel_rate_max_keys_per_socket
}

@internal
pub fn config_max_topic_length(config: Config) -> Int {
  config.max_topic_length
}

@internal
pub fn config_max_event_length(config: Config) -> Int {
  config.max_event_length
}

@internal
pub fn config_max_inbound_frame_bytes(config: Config) -> Int {
  config.max_inbound_frame_bytes
}

@internal
pub fn config_max_joined_topics_per_socket(config: Config) -> Int {
  config.max_joined_topics_per_socket
}

/// Warn when a channels system starts with every abuse control disabled.
///
/// Beryl ships with rate and connection limits off (like Phoenix) because
/// no default is right for every deployment — but running that way in
/// production leaves the server open to trivial floods, so the choice
/// should be a visible one. Called by both `start` and `supervisor.start`.
@internal
pub fn warn_if_unprotected(config: Config) -> Nil {
  let unprotected =
    config.max_connections_per_ip <= 0
    && config.max_connections <= 0
    && config.message_rate <= 0
    && config.join_rate <= 0
    && config.channel_rate <= 0
  use <- bool.guard(when: !unprotected, return: Nil)
  internal.logger("beryl")
  |> log.warn("No abuse controls configured", [
    #(
      "hint",
      "rate and connection limits are all disabled; fine for development, "
        <> "but for production configure with_message_rate, with_join_rate, "
        <> "with_max_connections_per_ip, and with_max_connections (see the "
        <> "production hardening guide)",
    ),
  ])
}

/// Rate-limit settings as a pure config, `None` when the rate is unlimited.
fn optional_limits(
  rate: Int,
  burst: Int,
) -> Option(rate_limit.RateLimitConfig) {
  use <- bool.guard(when: rate <= 0, return: None)
  Some(rate_limit.config(per_second: rate, burst: burst))
}

// nolint: unused_exports -- package-internal accessor for transports; hidden from public docs with @internal
/// Per-socket message rate limits for transports, `None` when unlimited.
///
/// Transports enforce this with a local token bucket per connection so
/// flooded sockets are shed at the edge, before frames are decoded or
/// enqueued on the coordinator.
@internal
pub fn message_limits(
  channels: Channels,
) -> Option(rate_limit.RateLimitConfig) {
  optional_limits(channels.config.message_rate, channels.config.message_burst)
}

/// Build a coordinator config from a `Config`.
/// Shared by `start` and the supervisor so the mapping lives in one place.
@internal
pub fn to_coordinator_config(config: Config) -> coordinator.CoordinatorConfig {
  // Server checks at half the timeout interval to detect stale sockets
  // promptly. The client heartbeat_interval_ms is informational only.
  let check_interval = config.heartbeat_timeout_ms / 2

  coordinator.CoordinatorConfig(
    codec: config.codec,
    heartbeat_check_interval_ms: check_interval,
    heartbeat_timeout_ms: config.heartbeat_timeout_ms,
    message_limits: optional_limits(config.message_rate, config.message_burst),
    join_limits: optional_limits(config.join_rate, config.join_burst),
    channel_limits: optional_limits(config.channel_rate, config.channel_burst),
    channel_limiter_max_keys_per_socket: config.channel_rate_max_keys_per_socket,
    max_topic_length: config.max_topic_length,
    max_event_length: config.max_event_length,
    max_joined_topics_per_socket: config.max_joined_topics_per_socket,
    logging: coordinator_logging(config.logging),
    registry: None,
  )
}

/// Channels system handle.
///
/// This opaque handle is returned by `start` (channel-module systems) and
/// `start_app` (app-side dispatch systems, ADR 0002) and passed to
/// broadcast, group, supervisor, and transport functions. Its internals are
/// intentionally hidden so Beryl can evolve them without breaking
/// application code.
pub opaque type Channels {
  Channels(
    config: Config,
    connection_limiter: Option(connection_limit.ConnectionLimiter),
    coordinator: Subject(coordinator.Message),
    pubsub: Option(PubSub(json.Json)),
    /// Crash-survivable handler registry. When present, `register` writes
    /// here and syncs the coordinator, so registrations survive coordinator
    /// restarts.
    registry: Option(coordinator.Registry),
  )
  /// An app-side dispatch system started by `start_app`. The runtime actor
  /// is generic over the app's `model`/`msg`; this variant reaches it
  /// through monomorphic closures captured at start.
  AppChannels(
    config: Config,
    connection_limiter: Option(connection_limit.ConnectionLimiter),
    app: AppHandle,
  )
}

/// Monomorphic closures over a generic runtime actor, captured by
/// `start_app`. This is what lets the frame-level transport SPI stay
/// unparameterized while the runtime holds typed per-socket models.
type AppHandle {
  AppHandle(
    socket_connected: fn(
      String,
      fn(String) -> Result(Nil, Nil),
      fn(BitArray) -> Result(Nil, Nil),
      event.ConnectSeed,
    ) -> Nil,
    register_closer: fn(String, fn() -> Nil) -> Nil,
    socket_disconnected: fn(String) -> Nil,
    route_decoded: fn(String, codec.Inbound) -> Nil,
    route_binary: fn(String, BitArray) -> Nil,
    broadcast: fn(String, String, json.Json, Option(String)) -> Nil,
    stop: fn() -> Nil,
  )
}

// nolint: unused_exports -- package-internal constructor for supervised coordinators; hidden from public docs with @internal
@internal
pub fn channels_from_coordinator(
  coordinator coordinator: Subject(coordinator.Message),
  config config: Config,
  registry registry: Option(coordinator.Registry),
) -> Channels {
  channels_from_parts(
    coordinator: coordinator,
    config: config,
    registry: registry,
    connection_limiter: connection_limit.start_optional(
      config.max_connections_per_ip,
      config.max_connections,
    ),
  )
}

@internal
pub fn channels_from_supervised_parts(
  coordinator coordinator: Subject(coordinator.Message),
  config config: Config,
  registry registry: coordinator.Registry,
  connection_limiter connection_limiter: Option(
    connection_limit.ConnectionLimiter,
  ),
) -> Channels {
  channels_from_parts(
    coordinator: coordinator,
    config: config,
    registry: Some(registry),
    connection_limiter: connection_limiter,
  )
}

fn channels_from_parts(
  coordinator coordinator: Subject(coordinator.Message),
  config config: Config,
  registry registry: Option(coordinator.Registry),
  connection_limiter connection_limiter: Option(
    connection_limit.ConnectionLimiter,
  ),
) -> Channels {
  Channels(
    coordinator: coordinator,
    config: config,
    pubsub: config.pubsub,
    connection_limiter: connection_limiter,
    registry: registry,
  )
}

// nolint: unused_exports -- package-internal accessor for transports/tests; hidden from public docs with @internal
@internal
pub fn coordinator_subject(channels: Channels) -> Subject(coordinator.Message) {
  let assert Channels(coordinator: coordinator, ..) = channels
    as "coordinator_subject requires a channel-module system (beryl.start)"
  coordinator
}

@internal
pub fn configured_codec(channels: Channels) -> codec.Codec {
  channels.config.codec
}

/// A held per-IP connection slot returned by `acquire_connection_slot`.
///
/// Opaque so Beryl can restructure the connection limiter without breaking
/// transport authors. Hold it for the lifetime of the connection and pass it
/// to `release_connection_slot` when the connection closes. When no per-IP
/// limit is configured the permit is an admit-everything placeholder and
/// releasing it is a no-op.
pub opaque type ConnectionPermit {
  ConnectionPermit(inner: Option(connection_limit.Permit))
}

/// Try to acquire a configured per-IP connection slot for transports.
///
/// Transports call this before admitting a connection, passing the **real
/// socket peer IP**. Do not pass a client-supplied address (e.g. from
/// `X-Forwarded-For`): a spoofed value would defeat the per-IP limit. Returns
/// `Ok(permit)` when admitted (release the permit with
/// `release_connection_slot` on close; when no limit is configured every
/// connection is admitted), or `Error(Nil)` when the peer is already at its
/// limit.
pub fn acquire_connection_slot(
  channels: Channels,
  ip: String,
) -> Result(ConnectionPermit, Nil) {
  connection_limit.acquire_optional(channels.connection_limiter, ip)
  |> result.map(ConnectionPermit)
}

/// Bind an acquired connection slot to the calling process.
///
/// Call this from the long-lived connection process (e.g. the WebSocket
/// handler's init) after `acquire_connection_slot`. The limiter monitors the
/// caller so the slot is reclaimed even if the connection process dies
/// without running its close path — otherwise crashed connections would
/// permanently exhaust their IP's slots.
pub fn bind_connection_slot(permit: ConnectionPermit) -> Nil {
  connection_limit.bind_optional(permit.inner)
}

/// Release a per-IP connection slot acquired by a transport.
///
/// Call from the process the permit was bound to (or from an unbound
/// process when releasing before the connection was established).
pub fn release_connection_slot(permit: ConnectionPermit) -> Nil {
  connection_limit.release_optional(permit.inner)
}

// nolint: unused_exports -- transport SPI, consumed by transport packages such as beryl_mist
/// Return the configured inbound frame size cap for transports.
pub fn max_inbound_frame_bytes(channels: Channels) -> Int {
  channels.config.max_inbound_frame_bytes
}

/// Errors when starting channels
pub type StartError {
  /// The coordinator actor failed to start.
  CoordinatorStartFailed(beryl_error.StartFailure)
  /// `heartbeat_timeout_ms` must be at least 2. The server derives its staleness
  /// check interval as `heartbeat_timeout_ms / 2` (integer division), so a
  /// timeout of 1 would round down to a check interval of 0 — which disables
  /// heartbeat eviction entirely. `start` rejects such a config loudly rather
  /// than silently turning eviction off.
  InvalidHeartbeatTimeout
}

/// Start the channels system
///
/// Call once at application startup. Returns a handle that can be passed
/// to the WebSocket transport and used for broadcasting.
///
/// Heartbeat eviction is configured via `heartbeat_timeout_ms` in the Config.
/// The coordinator evicts any socket that has not sent a heartbeat within that
/// window, checking for stale sockets at a server-derived interval of
/// `heartbeat_timeout_ms / 2`. `heartbeat_interval_ms` is client-advisory only
/// (see `with_heartbeat`) and does not schedule anything on the server.
///
/// Returns `Error(InvalidHeartbeatTimeout)` if `heartbeat_timeout_ms` is less
/// than 2.
///
/// ## Example
///
/// ```gleam
/// pub fn main() {
///   let assert Ok(channels) = beryl.start(beryl.config(wire.phoenix_codec()))
///   // Use channels...
/// }
/// ```
pub fn start(config: Config) -> Result(Channels, StartError) {
  use <- bool.guard(
    when: config.heartbeat_timeout_ms < 2,
    return: internal.result_error(InvalidHeartbeatTimeout),
  )
  warn_if_unprotected(config)
  // Registrations live in a registry that outlives the coordinator, so a
  // supervised restart (or manual coordinator replacement) can re-seed
  // them.
  use registry <- result.try(
    coordinator.start_registry()
    |> result.map_error(fn(error) {
      CoordinatorStartFailed(beryl_error.from_actor_start_error(error))
    }),
  )
  let coord_config =
    coordinator.CoordinatorConfig(
      ..to_coordinator_config(config),
      registry: Some(registry),
    )

  let coordinator_result = case config.pubsub {
    Some(ps) -> coordinator.start_with_config_and_pubsub(coord_config, ps)
    None -> coordinator.start_with_config(coord_config)
  }

  case coordinator_result {
    Ok(coord) ->
      Ok(channels_from_coordinator(
        coordinator: coord,
        config: config,
        registry: Some(registry),
      ))
    error_result -> {
      case
        result.unwrap_error(
          error_result,
          or: coordinator.InvalidHeartbeatTimeout,
        )
      {
        coordinator.ActorStartFailed(error) ->
          internal.result_error(
            CoordinatorStartFailed(beryl_error.from_actor_start_error(error)),
          )
        coordinator.InvalidHeartbeatTimeout ->
          internal.result_error(InvalidHeartbeatTimeout)
      }
    }
  }
}

/// Stop an unsupervised channels system.
///
/// This shuts down the coordinator actor started by `start` and any auxiliary
/// limiter actors owned by the `Channels` handle. Joined channel handlers
/// receive `channel.Shutdown` in their `terminate` callback before the
/// coordinator exits. After this call the `Channels` handle should no longer be
/// used.
pub fn stop(channels: Channels) -> Nil {
  case channels {
    Channels(
      coordinator: coordinator_subject,
      registry: registry,
      connection_limiter: connection_limiter,
      ..,
    ) -> {
      stop_coordinator(coordinator_subject)
      connection_limit.stop_optional(connection_limiter)
      case registry {
        Some(registry) -> coordinator.stop_registry(registry)
        None -> Nil
      }
    }
    AppChannels(app: app, connection_limiter: connection_limiter, ..) -> {
      app.stop()
      connection_limit.stop_optional(connection_limiter)
    }
  }
}

/// Start an app-side dispatch system (ADR 0002).
///
/// One entry point replaces channel modules and registration: the app
/// supplies `init`, producing the per-socket model when a socket connects,
/// and `update`, receiving every event for the socket and returning the
/// next model plus a list of effects. The app routes topics itself by
/// matching on the event's topic — see `beryl/event` for the event and
/// effect types.
///
/// The returned `Channels` handle works with the same transports and
/// broadcast/group helpers as `start`, but `register`/`send_info` do not
/// apply: server-side messages are sent through the socket's typed
/// `Sender` (`event.notify`) instead.
///
/// ## Example
///
/// ```gleam
/// import beryl
/// import beryl/event.{AcceptJoin, Broadcast, Join, Message, Next}
///
/// pub fn main() {
///   let assert Ok(channels) =
///     beryl.start_app(
///       beryl.config(wire.phoenix_codec()),
///       init: fn(_info) { #(MyModel(joined: False), []) },
///       update: fn(model, ev) {
///         case ev {
///           Join("room:" <> _, _payload, ref) ->
///             Next(MyModel(joined: True), [AcceptJoin(ref, option.None)])
///           Message(topic, "new_msg", payload, _ref) ->
///             Next(model, [Broadcast(topic, "new_msg", relay(payload))])
///           _ -> Next(model, [])
///         }
///       },
///     )
/// }
/// ```
pub fn start_app(
  config: Config,
  init init: fn(event.ConnectInfo(msg)) -> #(model, List(event.Effect)),
  update update: fn(model, event.Event(msg)) -> event.Next(model, msg),
) -> Result(Channels, StartError) {
  use <- bool.guard(
    when: config.heartbeat_timeout_ms < 2,
    return: internal.result_error(InvalidHeartbeatTimeout),
  )
  warn_if_unprotected(config)
  case runtime.start(to_runtime_config(config), config.pubsub, init, update) {
    Error(runtime.InvalidHeartbeatTimeout) ->
      internal.result_error(InvalidHeartbeatTimeout)
    Error(runtime.ActorStartFailed(error)) ->
      internal.result_error(
        CoordinatorStartFailed(beryl_error.from_actor_start_error(error)),
      )
    Ok(started) ->
      Ok(AppChannels(
        config: config,
        connection_limiter: connection_limit.start_optional(
          config.max_connections_per_ip,
          config.max_connections,
        ),
        app: app_handle(started.data, started.pid, config.pubsub),
      ))
  }
}

/// Build the monomorphic closure record over a generic runtime. This is
/// plain closure capture by a generic function — the `model`/`msg` types
/// are sealed in here and never appear in any public signature.
fn app_handle(
  subject: Subject(runtime.Msg(msg)),
  runtime_pid: process.Pid,
  ps: Option(PubSub(json.Json)),
) -> AppHandle {
  AppHandle(
    socket_connected: fn(socket_id, send, send_binary, seed) {
      process.send(
        subject,
        runtime.SocketConnected(socket_id, send, send_binary, None, seed),
      )
    },
    register_closer: fn(socket_id, close) {
      process.send(subject, runtime.RegisterCloser(socket_id, close))
    },
    socket_disconnected: fn(socket_id) {
      process.send(subject, runtime.SocketDisconnected(socket_id))
    },
    route_decoded: fn(socket_id, msg) {
      process.send(subject, runtime.RouteDecoded(socket_id, msg))
    },
    route_binary: fn(socket_id, data) {
      process.send(subject, runtime.HandleBinary(socket_id, data))
    },
    broadcast: fn(topic_name, event_name, payload, except) {
      // Local fan-out via the runtime; distributed fan-out via PubSub with
      // the runtime's pid as sender so it does not echo back to itself.
      process.send(
        subject,
        runtime.Broadcast(topic_name, event_name, payload, except),
      )
      case ps, process.is_alive(runtime_pid) {
        Some(ps), True ->
          case except {
            None ->
              pubsub.broadcast_from(
                ps,
                runtime_pid,
                topic_name,
                event_name,
                payload,
              )
            Some(socket_id) ->
              pubsub.broadcast_from_socket(
                ps,
                runtime_pid,
                socket_id,
                topic_name,
                event_name,
                payload,
              )
          }
        _, _ -> Nil
      }
    },
    stop: fn() {
      use <- bool.guard(when: !process.is_alive(runtime_pid), return: Nil)
      let reply = process.new_subject()
      process.send(subject, runtime.Stop(reply))
      let _stop_result = process.receive(reply, 5000)
      Nil
    },
  )
}

fn to_runtime_config(config: Config) -> runtime.Config {
  runtime.Config(
    codec: config.codec,
    // Server checks at half the timeout interval, matching `start`.
    heartbeat_check_interval_ms: config.heartbeat_timeout_ms / 2,
    heartbeat_timeout_ms: config.heartbeat_timeout_ms,
    message_limits: optional_limits(config.message_rate, config.message_burst),
    join_limits: optional_limits(config.join_rate, config.join_burst),
    channel_limits: optional_limits(config.channel_rate, config.channel_burst),
    channel_limiter_max_keys_per_socket: config.channel_rate_max_keys_per_socket,
    topic_rates: list.map(config.topic_rates, fn(entry) {
      let #(pattern, limits) = entry
      #(topic.parse_pattern(pattern), limits)
    }),
    max_topic_length: config.max_topic_length,
    max_event_length: config.max_event_length,
    max_joined_topics_per_socket: config.max_joined_topics_per_socket,
    logging: internal_logging_config(config.logging),
    presence: config.presence,
  )
}

fn internal_logging_config(logging: LoggingConfig) -> internal.LoggingConfig {
  internal.LoggingConfig(
    level: case logging.level {
      DebugLevel -> internal.Debug
      InfoLevel -> internal.Info
      WarnLevel -> internal.Warn
      ErrorLevel -> internal.Err
    },
    include_payloads: logging.include_payloads,
    payload_preview_bytes: logging.payload_preview_bytes,
  )
}

// ─────────────────────────────────────────────────────────────────────────────
// Transport dispatch — branch between the coordinator (channel-module
// systems) and the app runtime closures, so the frame-level SPI in
// `beryl/transport` works unchanged with both `start` and `start_app`.
// ─────────────────────────────────────────────────────────────────────────────

// nolint: unused_exports -- package-internal dispatch for beryl/transport; hidden from public docs with @internal
@internal
pub fn transport_socket_connected(
  channels: Channels,
  socket_id: String,
  send: fn(String) -> Result(Nil, Nil),
  send_binary: fn(BitArray) -> Result(Nil, Nil),
  assigns: Dynamic,
  seed: event.ConnectSeed,
) -> Nil {
  case channels {
    Channels(coordinator: coordinator_subject, ..) ->
      process.send(
        coordinator_subject,
        coordinator.SocketConnected(socket_id, send, send_binary, None, assigns),
      )
    AppChannels(app: app, ..) ->
      app.socket_connected(socket_id, send, send_binary, seed)
  }
}

@internal
pub fn transport_register_closer(
  channels: Channels,
  socket_id: String,
  close: fn() -> Nil,
) -> Nil {
  case channels {
    Channels(coordinator: coordinator_subject, ..) ->
      process.send(
        coordinator_subject,
        coordinator.RegisterCloser(socket_id, close),
      )
    AppChannels(app: app, ..) -> app.register_closer(socket_id, close)
  }
}

@internal
pub fn transport_socket_disconnected(
  channels: Channels,
  socket_id: String,
) -> Nil {
  case channels {
    Channels(coordinator: coordinator_subject, ..) ->
      process.send(
        coordinator_subject,
        coordinator.SocketDisconnected(socket_id),
      )
    AppChannels(app: app, ..) -> app.socket_disconnected(socket_id)
  }
}

@internal
pub fn transport_route_decoded(
  channels: Channels,
  socket_id: String,
  message: codec.Inbound,
) -> Nil {
  case channels {
    Channels(coordinator: coordinator_subject, ..) ->
      coordinator.route_decoded(coordinator_subject, socket_id, message)
    AppChannels(app: app, ..) -> app.route_decoded(socket_id, message)
  }
}

@internal
pub fn transport_route_binary(
  channels: Channels,
  socket_id: String,
  data: BitArray,
) -> Nil {
  case channels {
    Channels(coordinator: coordinator_subject, ..) ->
      coordinator.route_binary(coordinator_subject, socket_id, data)
    AppChannels(app: app, ..) -> app.route_binary(socket_id, data)
  }
}

fn stop_coordinator(coordinator: Subject(coordinator.Message)) -> Nil {
  let should_send = case process.subject_owner(coordinator) {
    Ok(pid) -> process.is_alive(pid)
    _ -> False
  }

  use <- bool.guard(when: !should_send, return: Nil)
  let reply = process.new_subject()
  process.send(coordinator, coordinator.Stop(reply))
  let _stop_result = process.receive(reply, 5000)
  Nil
}

/// Register a channel handler for a topic pattern
///
/// Patterns can be exact matches like "room:lobby", legacy prefix wildcards
/// like "room:*" which match any topic starting with "room:", or segment
/// wildcards like "document:*:ops" where "*" matches one complete segment.
/// The bare pattern "*" is a catch-all that matches every topic.
///
/// Patterns are validated at registration: they must be non-empty and must
/// not contain control characters (codepoints 0–31 or 127). Invalid patterns
/// are rejected with `InvalidPattern`.
///
/// Panics if the coordinator actor is unavailable or does not reply within
/// 5 seconds (e.g. during a supervisor restart window after a crash).
///
/// ## Example
///
/// ```gleam
/// // Create a typed channel
/// let chat_channel = channel.new(fn(topic, payload, socket) {
///   // Handle join
///   channel.JoinOk(reply: None, socket: socket)
/// })
/// |> channel.with_handle_in(fn(event, payload, socket) {
///   // Handle incoming messages
///   channel.NoReply(socket)
/// })
///
/// // Register it with a legacy prefix wildcard
/// let assert Ok(chat) = beryl.register(channels, "chat:*", chat_channel)
///
/// // Exact topic
/// let assert Ok(lobby) = beryl.register(channels, "room:lobby", lobby_channel)
///
/// // Segment-aware wildcard
/// let assert Ok(ops) = beryl.register(channels, "document:*:ops", ops_channel)
/// ```
pub fn register(
  channels: Channels,
  pattern: String,
  handler: Channel(assigns, info),
) -> Result(RegisteredChannel(assigns, info), RegisterError) {
  let assert Channels(
    coordinator: coordinator_subject,
    registry: channels_registry,
    ..,
  ) = channels
    as "beryl.register requires a channel-module system (beryl.start); app-dispatch systems (beryl.start_app) route topics in their update function"

  // Convert typed Channel to type-erased ChannelHandler
  let erased_handler = erase_channel_types(pattern, handler)

  let registration = case channels_registry {
    // Write to the crash-survivable registry, then sync the live
    // coordinator so the handler is visible before this call returns.
    Some(registry) -> {
      use id <- result.try(coordinator.registry_put(
        registry,
        pattern,
        erased_handler,
      ))
      let #(handlers, next_id) = coordinator.registry_snapshot(registry)
      process.call(coordinator_subject, 5000, fn(reply) {
        coordinator.SyncHandlers(handlers, next_id, reply)
      })
      Ok(id)
    }
    // No registry configured: register with the coordinator directly.
    None ->
      process.call(coordinator_subject, 5000, fn(reply) {
        coordinator.RegisterChannel(pattern, erased_handler, reply)
      })
  }

  registration
  |> result.map(fn(id) {
    RegisteredChannel(coordinator: coordinator_subject, id: id)
  })
  |> result.map_error(map_register_error)
}

fn map_register_error(error: coordinator.RegisterError) -> RegisterError {
  case error {
    coordinator.PatternAlreadyRegistered(pattern) ->
      PatternAlreadyRegistered(pattern)
    coordinator.InvalidPattern(pattern) -> InvalidPattern(pattern)
  }
}

/// Broadcast a message to all subscribers of a topic
///
/// This sends the message to all sockets subscribed to the topic.
///
/// ## Example
///
/// ```gleam
/// beryl.broadcast(
///   channels,
///   "room:lobby",
///   "new_message",
///   json.object([#("text", json.string("Hello!"))]),
/// )
/// ```
pub fn broadcast(
  channels: Channels,
  topic_name: String,
  event: String,
  payload: json.Json,
) -> Nil {
  case channels {
    AppChannels(app: app, ..) -> app.broadcast(topic_name, event, payload, None)
    Channels(coordinator: coordinator_subject, pubsub: ps, ..) -> {
      // Local broadcast via coordinator
      process.send(
        coordinator_subject,
        coordinator.Broadcast(topic_name, event, payload, None),
      )
      // Distributed broadcast via PubSub (if configured)
      case ps, process.subject_owner(coordinator_subject) {
        Some(ps), Ok(coordinator_pid) ->
          pubsub.broadcast_from(ps, coordinator_pid, topic_name, event, payload)
        Some(_), _ ->
          // Coordinator exited between send and pubsub forward — local
          // message is already enqueued (dead-letters), skip the cluster
          // fanout.
          Nil
        None, _ -> Nil
      }
    }
  }
}

/// Broadcast a Phoenix-compatible `presence_diff` event for a topic.
///
/// This encodes the topic's joins and leaves as:
///
/// ```json
/// {
///   "joins": { "user:1": { "metas": [{ "status": "online" }] } },
///   "leaves": { "user:2": { "metas": [{ "status": "offline" }] } }
/// }
/// ```
///
/// When the channels system was started with PubSub, the broadcast is
/// distributed using the same semantics as `broadcast`.
pub fn broadcast_presence_diff(
  channels: Channels,
  topic_name: String,
  diff: Diff,
) -> Nil {
  broadcast(
    channels,
    topic_name,
    "presence_diff",
    presence_wire.encode_diff(diff, topic_name),
  )
}

/// Broadcast a message to all subscribers except one socket
///
/// Useful for broadcasting a message to everyone except the sender.
/// When PubSub is configured, the excluded socket ID is preserved across
/// coordinators so clustered deployments do not echo the event back to that
/// socket on another node.
///
/// ## Example
///
/// ```gleam
/// // In a channel handler, broadcast to others
/// beryl.broadcast_from(
///   channels,
///   socket_id,
///   "room:lobby",
///   "user_typing",
///   json.object([#("user", json.string("alice"))]),
/// )
/// ```
pub fn broadcast_from(
  channels: Channels,
  except_socket_id: String,
  topic_name: String,
  event: String,
  payload: json.Json,
) -> Nil {
  case channels {
    AppChannels(app: app, ..) ->
      app.broadcast(topic_name, event, payload, Some(except_socket_id))
    Channels(coordinator: coordinator_subject, pubsub: ps, ..) -> {
      // Local broadcast via coordinator (excluding sender)
      process.send(
        coordinator_subject,
        coordinator.Broadcast(
          topic_name,
          event,
          payload,
          Some(except_socket_id),
        ),
      )
      // Distributed broadcast via PubSub (if configured)
      case ps, process.subject_owner(coordinator_subject) {
        Some(ps), Ok(coordinator_pid) ->
          pubsub.broadcast_from_socket(
            ps,
            coordinator_pid,
            except_socket_id,
            topic_name,
            event,
            payload,
          )
        Some(_), _ -> Nil
        None, _ -> Nil
      }
    }
  }
}

/// Send a typed server-originated OTP message to a joined channel context.
///
/// The `registered` handle carries the receiving channel's `info` type, so the
/// compiler rejects messages for incompatible channels. The coordinator also
/// verifies that the socket/topic pair was joined through that same registered
/// channel before dispatching the callback. If the socket is not connected, the
/// topic is not joined, or the registered channel does not match the joined
/// channel, the message is ignored.
pub fn send_info(
  registered: RegisteredChannel(assigns, info),
  socket_id: String,
  topic_name: String,
  message: info,
) -> Nil {
  process.send(
    registered.coordinator,
    coordinator.HandleInfo(
      socket_id,
      topic_name,
      registered.id,
      erase_info(message),
    ),
  )
}

// ─────────────────────────────────────────────────────────────────────────────
// Type erasure - Convert typed Channel to ChannelHandler
// ─────────────────────────────────────────────────────────────────────────────

/// Convert a typed Channel to a type-erased ChannelHandler
///
/// This is necessary because we need to store handlers for different
/// channel types in the same registry. The erased handler carries only
/// `join`: a successful join returns a `JoinedChannel` instance whose
/// closures capture the channel's typed assigns (see `channel_instance`),
/// so assigns never cross the coordinator boundary type-erased.
fn erase_channel_types(
  pattern_str: String,
  typed_channel: Channel(assigns, info),
) -> ChannelHandler {
  let pattern = topic.parse_pattern(pattern_str)
  let join = channel.join_callback(typed_channel)

  coordinator.ChannelHandler(
    id: 0,
    pattern: pattern,
    join: fn(
      topic_name: String,
      payload: Dynamic,
      connect_assigns: Dynamic,
      ctx: coordinator.SocketContext,
    ) {
      // Connect-time assigns are seeded type-erased by the transport's
      // on_connect hook (Nil when none were seeded); restoring them to this
      // channel's assigns type is unchecked (ADR 0001).
      let seeded = restore_connect_assigns(connect_assigns)
      case join(topic_name, payload, context_socket(ctx, seeded)) {
        channel.JoinOk(reply, new_socket) ->
          coordinator.JoinOkErased(
            reply: reply,
            channel: channel_instance(
              typed_channel,
              socket.get_assigns(new_socket),
            ),
          )
        channel.JoinError(reason) -> coordinator.JoinErrorErased(reason: reason)
      }
    },
  )
}

/// Build the erased instance for a joined channel, capturing the current
/// typed assigns in its closures. Each callback returns the next instance
/// via `erase_handle_result`, so assigns threading between callbacks is
/// compiler-checked here instead of round-tripped through Dynamic.
fn channel_instance(
  typed_channel: Channel(assigns, info),
  assigns: assigns,
) -> coordinator.JoinedChannel {
  coordinator.JoinedChannel(
    handle_in: fn(
      event: String,
      payload: Dynamic,
      ctx: coordinator.SocketContext,
    ) {
      channel.handle_in_callback(typed_channel)(
        event,
        payload,
        context_socket(ctx, assigns),
      )
      |> erase_handle_result(typed_channel, _)
    },
    handle_binary: fn(data: BitArray, ctx: coordinator.SocketContext) {
      channel.handle_binary_callback(typed_channel)(
        data,
        context_socket(ctx, assigns),
      )
      |> erase_handle_result(typed_channel, _)
    },
    handle_info: fn(message: Dynamic, ctx: coordinator.SocketContext) {
      // Restore the info type erased by send_info. Sound because the
      // coordinator dispatches only after matching the joined channel id
      // against the RegisteredChannel handle the message was sent through,
      // and both derive from the same register call.
      channel.handle_info_callback(typed_channel)(
        restore_info(message),
        context_socket(ctx, assigns),
      )
      |> erase_handle_result(typed_channel, _)
    },
    terminate: fn(reason: channel.StopReason, ctx: coordinator.SocketContext) {
      channel.terminate_callback(typed_channel)(
        reason,
        context_socket(ctx, assigns),
      )
    },
  )
}

fn transport_from_context(ctx: coordinator.SocketContext) -> socket.Transport {
  socket.new_transport(
    send_text: fn(text) {
      ctx.send(text)
      |> result_to_transport_result()
    },
    send_binary: fn(data) {
      ctx.send_binary(data)
      |> result_to_transport_result()
    },
    close: fn() {
      ctx.close()
      Ok(Nil)
    },
  )
}

fn context_socket(
  ctx: coordinator.SocketContext,
  assigns: assigns,
) -> Socket(assigns) {
  socket.new(ctx.socket_id, assigns, transport_from_context(ctx))
}

fn result_to_transport_result(
  result: Result(Nil, Nil),
) -> Result(Nil, socket.TransportError) {
  case result {
    Ok(_) -> Ok(Nil)
    _ -> internal.result_error(socket.SendFailed("Send failed"))
  }
}

/// Convert a typed HandleResult to the type-erased coordinator variant,
/// wrapping the updated assigns in the next channel instance.
fn erase_handle_result(
  typed_channel: Channel(assigns, info),
  result: channel.HandleResult(assigns),
) -> coordinator.HandleResultErased {
  case result {
    channel.NoReply(new_socket) ->
      coordinator.NoReplyErased(next: next_instance(typed_channel, new_socket))
    channel.Reply(event, payload, new_socket) ->
      coordinator.ReplyErased(
        event: event,
        payload: payload,
        next: next_instance(typed_channel, new_socket),
      )
    channel.ReplyError(payload, new_socket) ->
      coordinator.ReplyErrorErased(
        payload: payload,
        next: next_instance(typed_channel, new_socket),
      )
    channel.Push(event, payload, new_socket) ->
      coordinator.PushErased(
        event: event,
        payload: payload,
        next: next_instance(typed_channel, new_socket),
      )
    channel.Stop(reason) -> coordinator.StopErased(reason: reason)
  }
}

fn next_instance(
  typed_channel: Channel(assigns, info),
  new_socket: Socket(assigns),
) -> coordinator.JoinedChannel {
  channel_instance(typed_channel, socket.get_assigns(new_socket))
}

/// Erase a typed server message for transit through the coordinator.
/// Paired with `restore_info`; sound via the registered-channel id check
/// performed before dispatch (see ADR 0001).
@external(erlang, "beryl_ffi", "identity")
fn erase_info(message: info) -> Dynamic

/// Restore a server message erased by `erase_info`.
@external(erlang, "beryl_ffi", "identity")
fn restore_info(message: Dynamic) -> info

/// Restore transport-seeded connect assigns to the channel's assigns type.
/// Unchecked: transports and channels must agree on the seeded type
/// (ADR 0001).
@external(erlang, "beryl_ffi", "identity")
fn restore_connect_assigns(assigns: Dynamic) -> assigns
