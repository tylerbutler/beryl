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
import beryl/internal
import beryl/log
import beryl/presence.{type Diff}
import beryl/presence/wire as presence_wire
import beryl/pubsub.{type PubSub}
import beryl/rate_limit
import beryl/socket.{type Socket}
import beryl/topic
import beryl/wire/codec
import gleam/bool
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/result

type ChannelHandler =
  coordinator.ChannelHandler

/// A typed handle returned when a channel is registered.
///
/// Pass this handle to `send_info` so the compiler can prove that the message
/// matches the receiving channel's `info` type. The handle also identifies the
/// exact registered channel used for a joined socket/topic pair.
pub opaque type RegisteredChannel(assigns, info) {
  RegisteredChannel(
    coordinator: Subject(coordinator.Message),
    id: Int,
    handle_info: fn(info, coordinator.SocketContext) ->
      coordinator.HandleResultErased,
  )
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
    /// Optional PubSub for distributed broadcasts across nodes
    pubsub: Option(PubSub),
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
  )
}

/// Add PubSub to a configuration for distributed broadcasts
pub fn with_pubsub(config: Config, ps: PubSub) -> Config {
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
/// Frames larger than `max_bytes` are closed before decoding. Values <= 0
/// disable the cap. The default is 1 MiB.
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
pub fn config_pubsub(config: Config) -> Option(PubSub) {
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
        <> "and with_max_connections_per_ip (see the production hardening "
        <> "guide)",
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
/// This opaque handle is returned by `start` and passed to registration,
/// broadcast, bridge, group, supervisor, and transport functions. Its internal
/// actor protocol is intentionally hidden so Beryl can evolve coordinator
/// internals without breaking application code.
pub opaque type Channels {
  Channels(
    coordinator: Subject(coordinator.Message),
    config: Config,
    pubsub: Option(PubSub),
    connection_limiter: Option(connection_limit.ConnectionLimiter),
    /// Crash-survivable handler registry. When present, `register` writes
    /// here and syncs the coordinator, so registrations survive coordinator
    /// restarts.
    registry: Option(coordinator.Registry),
  )
}

// nolint: unused_exports -- package-internal constructor for supervised coordinators; hidden from public docs with @internal
@internal
pub fn channels_from_coordinator(
  coordinator coordinator: Subject(coordinator.Message),
  config config: Config,
  registry registry: Option(coordinator.Registry),
) -> Channels {
  Channels(
    coordinator: coordinator,
    config: config,
    pubsub: config.pubsub,
    connection_limiter: connection_limit.start_optional(
      config.max_connections_per_ip,
    ),
    registry: registry,
  )
}

// nolint: unused_exports -- package-internal accessor for transports/tests; hidden from public docs with @internal
@internal
pub fn coordinator_subject(channels: Channels) -> Subject(coordinator.Message) {
  channels.coordinator
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
  stop_coordinator(channels.coordinator)
  connection_limit.stop_optional(channels.connection_limiter)
  case channels.registry {
    Some(registry) -> coordinator.stop_registry(registry)
    None -> Nil
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
  let handle_info = typed_handle_info(handler)
  // Convert typed Channel to type-erased ChannelHandler
  let erased_handler = erase_channel_types(pattern, handler)

  let registration = case channels.registry {
    // Write to the crash-survivable registry, then sync the live
    // coordinator so the handler is visible before this call returns.
    Some(registry) -> {
      use id <- result.try(coordinator.registry_put(
        registry,
        pattern,
        erased_handler,
      ))
      let #(handlers, next_id) = coordinator.registry_snapshot(registry)
      process.call(channels.coordinator, 5000, fn(reply) {
        coordinator.SyncHandlers(handlers, next_id, reply)
      })
      Ok(id)
    }
    // No registry configured: register with the coordinator directly.
    None ->
      process.call(channels.coordinator, 5000, fn(reply) {
        coordinator.RegisterChannel(pattern, erased_handler, reply)
      })
  }

  registration
  |> result.map(fn(id) {
    RegisteredChannel(
      coordinator: channels.coordinator,
      id: id,
      handle_info: handle_info,
    )
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
  // Local broadcast via coordinator
  process.send(
    channels.coordinator,
    coordinator.Broadcast(topic_name, event, payload, None),
  )
  // Distributed broadcast via PubSub (if configured)
  case channels.pubsub, process.subject_owner(channels.coordinator) {
    Some(ps), Ok(coordinator_pid) ->
      pubsub.broadcast_from(ps, coordinator_pid, topic_name, event, payload)
    Some(_), _ ->
      // Coordinator exited between send and pubsub forward — local message
      // is already enqueued (dead-letters), skip the cluster fanout.
      Nil
    None, _ -> Nil
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
  // Local broadcast via coordinator (excluding sender)
  process.send(
    channels.coordinator,
    coordinator.Broadcast(topic_name, event, payload, Some(except_socket_id)),
  )
  // Distributed broadcast via PubSub (if configured)
  case channels.pubsub, process.subject_owner(channels.coordinator) {
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
    coordinator.HandleInfo(socket_id, topic_name, registered.id, fn(ctx) {
      registered.handle_info(message, ctx)
    }),
  )
}

// ─────────────────────────────────────────────────────────────────────────────
// Type erasure - Convert typed Channel to ChannelHandler
// ─────────────────────────────────────────────────────────────────────────────

/// Convert a typed Channel to a type-erased ChannelHandler
///
/// This is necessary because we need to store handlers for different
/// channel types in the same registry.
fn erase_channel_types(
  pattern_str: String,
  typed_channel: Channel(assigns, info),
) -> ChannelHandler {
  let pattern = topic.parse_pattern(pattern_str)
  let join = channel.join_callback(typed_channel)
  let handle_in = channel.handle_in_callback(typed_channel)
  let handle_binary = channel.handle_binary_callback(typed_channel)
  let terminate = channel.terminate_callback(typed_channel)

  coordinator.ChannelHandler(
    id: 0,
    pattern: pattern,
    join: fn(
      topic_name: String,
      payload: Dynamic,
      ctx: coordinator.SocketContext,
    ) {
      // Create a typed socket seeded with any connect-time assigns from the
      // transport's on_connect hook (Nil when none were seeded).
      let typed_socket = create_socket_with_assigns(ctx)

      // Call the typed join handler (unsafe coerce socket to expected type)
      case join(topic_name, payload, unsafe_coerce_socket(typed_socket)) {
        channel.JoinOk(reply, new_socket) -> {
          // Extract assigns and type-erase them
          let erased_assigns =
            unsafe_coerce_to_dynamic(socket.get_assigns(new_socket))
          coordinator.JoinOkErased(reply: reply, assigns: erased_assigns)
        }
        channel.JoinError(reason) -> {
          coordinator.JoinErrorErased(reason: reason)
        }
      }
    },
    handle_in: fn(
      event: String,
      payload: Dynamic,
      ctx: coordinator.SocketContext,
    ) {
      let typed_socket = create_socket_with_assigns(ctx)

      handle_in(event, payload, unsafe_coerce_socket(typed_socket))
      |> erase_handle_result
    },
    handle_binary: fn(data: BitArray, ctx: coordinator.SocketContext) {
      let typed_socket = create_socket_with_assigns(ctx)

      handle_binary(data, unsafe_coerce_socket(typed_socket))
      |> erase_handle_result
    },
    terminate: fn(reason: channel.StopReason, ctx: coordinator.SocketContext) {
      let typed_socket = create_socket_with_assigns(ctx)
      // Unsafe coerce socket to expected type
      terminate(reason, unsafe_coerce_socket(typed_socket))
    },
  )
}

fn typed_handle_info(
  typed_channel: Channel(assigns, info),
) -> fn(info, coordinator.SocketContext) -> coordinator.HandleResultErased {
  let handle_info = channel.handle_info_callback(typed_channel)

  fn(message: info, ctx: coordinator.SocketContext) {
    let typed_socket = create_socket_with_assigns(ctx)

    handle_info(message, unsafe_coerce_socket(typed_socket))
    |> erase_handle_result
  }
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

fn create_socket_with_assigns(
  ctx: coordinator.SocketContext,
) -> Socket(Dynamic) {
  socket.new(ctx.socket_id, ctx.assigns, transport_from_context(ctx))
}

fn result_to_transport_result(
  result: Result(Nil, Nil),
) -> Result(Nil, socket.TransportError) {
  case result {
    Ok(_) -> Ok(Nil)
    _ -> internal.result_error(socket.SendFailed("Send failed"))
  }
}

/// Convert a typed HandleResult to the type-erased coordinator variant
fn erase_handle_result(
  result: channel.HandleResult(assigns),
) -> coordinator.HandleResultErased {
  case result {
    channel.NoReply(new_socket) ->
      coordinator.NoReplyErased(
        assigns: unsafe_coerce_to_dynamic(socket.get_assigns(new_socket)),
      )
    channel.Reply(event, payload, new_socket) ->
      coordinator.ReplyErased(
        event: event,
        payload: payload,
        assigns: unsafe_coerce_to_dynamic(socket.get_assigns(new_socket)),
      )
    channel.ReplyError(payload, new_socket) ->
      coordinator.ReplyErrorErased(
        payload: payload,
        assigns: unsafe_coerce_to_dynamic(socket.get_assigns(new_socket)),
      )
    channel.Push(event, payload, new_socket) ->
      coordinator.PushErased(
        event: event,
        payload: payload,
        assigns: unsafe_coerce_to_dynamic(socket.get_assigns(new_socket)),
      )
    channel.Stop(reason) -> coordinator.StopErased(reason: reason)
  }
}

/// Unsafe coercion to Dynamic - only use for type erasure
@external(erlang, "beryl_ffi", "identity")
fn unsafe_coerce_to_dynamic(value: a) -> Dynamic

/// Unsafe coercion of socket types - only use for type erasure
@external(erlang, "beryl_ffi", "identity")
fn unsafe_coerce_socket(socket: Socket(a)) -> Socket(b)
