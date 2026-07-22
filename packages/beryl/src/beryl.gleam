//// Beryl - Type-safe real-time communication
////
//// A standalone Gleam library for building real-time applications on the BEAM.
//// Provides WebSocket channels, distributed presence tracking, pub/sub
//// messaging, and channel groups.
////
//// ## Features
////
//// - **App-side dispatch** — One `start_app` entry point: the app supplies
////   `init`/`update` per socket and routes topics itself (`beryl`,
////   `beryl/event`)
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
//// import beryl/event
//// import beryl/wire
////
//// pub fn main() {
////   let assert Ok(channels) =
////     beryl.start_app(
////       beryl.config(wire.phoenix_codec()),
////       init: fn(_info) { #(initial_model(), []) },
////       update: update,
////     )
////
////   // Broadcast from anywhere holding the handle
////   beryl.broadcast(channels, "room:lobby", "announce", payload)
//// }
//// ```

import beryl/connection_limit
import beryl/error as beryl_error
import beryl/event
import beryl/internal
import beryl/log
import beryl/presence.{type Diff}
import beryl/presence/wire as presence_wire
import beryl/pubsub.{type PubSub}
import beryl/rate_limit
import beryl/runtime
import beryl/topic
import beryl/wire/codec
import gleam/bool
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/static_supervisor
import gleam/otp/supervision
import gleam/result

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
/// the README's "Security" section for deployment guidance.
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
/// should be a visible one. Called by `start_app`.
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

/// Channels system handle.
///
/// This opaque handle is returned by `start_app` and passed to broadcast,
/// group, and transport functions. The runtime actor is generic over the
/// app's `model`/`msg`; the handle reaches it through monomorphic closures
/// captured at start. Its internals are intentionally hidden so Beryl can
/// evolve them without breaking application code.
pub opaque type Channels {
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
    /// Current pid of the supervised runtime, if running (used by tests
    /// and PubSub sender attribution).
    runtime_owner: fn() -> Result(process.Pid, Nil),
  )
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
  /// The supervised runtime failed to start.
  RuntimeStartFailed(beryl_error.StartFailure)
  /// `heartbeat_timeout_ms` must be at least 2. The server derives its staleness
  /// check interval as `heartbeat_timeout_ms / 2` (integer division), so a
  /// timeout of 1 would round down to a check interval of 0 — which disables
  /// heartbeat eviction entirely. `start` rejects such a config loudly rather
  /// than silently turning eviction off.
  InvalidHeartbeatTimeout
}

/// Stop a channels system started by `start_app`.
///
/// Drains sockets gracefully and shuts down the supervised runtime plus any
/// auxiliary limiter actors owned by the `Channels` handle. Joined topics
/// receive a `Closed` event before the runtime exits. After this call the
/// `Channels` handle should no longer be used.
pub fn stop(channels: Channels) -> Nil {
  let AppChannels(app: app, connection_limiter: connection_limiter, ..) =
    channels
  app.stop()
  connection_limit.stop_optional(connection_limiter)
}

/// Start an app-side dispatch system.
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
  // There is no unsupervised app runtime: the runtime always runs under a
  // supervisor, with the `init`/`update` closures captured in the child
  // specification. A runtime crash therefore restarts dispatch
  // automatically (per-socket state is dropped, matching coordinator
  // restart semantics), and the registered name keeps the returned handle
  // valid across restarts. The child is `Transient` so a graceful `stop`
  // is not resurrected.
  let name = process.new_name("beryl_runtime")
  let child =
    supervision.worker(fn() {
      runtime.start_named(
        to_runtime_config(config),
        name: name,
        pubsub: config.pubsub,
        init: init,
        update: update,
      )
      |> result.map_error(fn(error) {
        case error {
          runtime.ActorStartFailed(error) -> error
          runtime.InvalidHeartbeatTimeout ->
            actor.InitFailed("invalid heartbeat timeout")
        }
      })
    })
    |> supervision.restart(supervision.Transient)

  let supervisor_result =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.restart_tolerance(intensity: 3, period: 5)
    |> static_supervisor.add(child)
    |> static_supervisor.start()

  case supervisor_result {
    Error(error) ->
      internal.result_error(
        RuntimeStartFailed(beryl_error.from_actor_start_error(error)),
      )
    Ok(_supervisor) ->
      Ok(AppChannels(
        config: config,
        connection_limiter: connection_limit.start_optional(
          config.max_connections_per_ip,
          config.max_connections,
        ),
        app: app_handle(process.named_subject(name), config.pubsub),
      ))
  }
}

/// Build the monomorphic closure record over a generic runtime. This is
/// plain closure capture by a generic function — the `model`/`msg` types
/// are sealed in here and never appear in any public signature. The
/// subject is name-backed, so the closures keep working across supervised
/// runtime restarts; sends are owner-guarded so use during a restart
/// window or after `stop` degrades to a no-op instead of a crash.
fn app_handle(
  subject: Subject(runtime.Msg(msg)),
  ps: Option(PubSub(json.Json)),
) -> AppHandle {
  AppHandle(
    socket_connected: fn(socket_id, send, send_binary, seed) {
      send_runtime(
        subject,
        runtime.SocketConnected(socket_id, send, send_binary, None, seed),
      )
    },
    register_closer: fn(socket_id, close) {
      send_runtime(subject, runtime.RegisterCloser(socket_id, close))
    },
    socket_disconnected: fn(socket_id) {
      send_runtime(subject, runtime.SocketDisconnected(socket_id))
    },
    route_decoded: fn(socket_id, msg) {
      send_runtime(subject, runtime.RouteDecoded(socket_id, msg))
    },
    route_binary: fn(socket_id, data) {
      send_runtime(subject, runtime.HandleBinary(socket_id, data))
    },
    broadcast: fn(topic_name, event_name, payload, except) {
      // Local fan-out via the runtime; distributed fan-out via PubSub with
      // the runtime's pid as sender so it does not echo back to itself.
      send_runtime(
        subject,
        runtime.Broadcast(topic_name, event_name, payload, except),
      )
      case ps, process.subject_owner(subject) {
        Some(ps), Ok(runtime_pid) ->
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
      // Drain sockets gracefully; the Transient child is not restarted
      // after a normal stop. The internal supervisor remains as an inert
      // shell linked to the process that called `start_app`, and exits
      // with it.
      case process.subject_owner(subject) {
        Error(Nil) -> Nil
        Ok(_) -> {
          let reply = process.new_subject()
          process.send(subject, runtime.Stop(reply))
          let _stop_result = process.receive(reply, 5000)
          Nil
        }
      }
    },
    runtime_owner: fn() { process.subject_owner(subject) },
  )
}

/// Send to the runtime only while its name is registered, so handle use
/// during a supervised restart window or after `stop` is a quiet no-op.
fn send_runtime(
  subject: Subject(runtime.Msg(msg)),
  message: runtime.Msg(msg),
) -> Nil {
  case process.subject_owner(subject) {
    Ok(_) -> process.send(subject, message)
    Error(Nil) -> Nil
  }
}

// nolint: unused_exports -- package-internal accessor for supervision tests; hidden from public docs with @internal
@internal
pub fn app_runtime_pid(channels: Channels) -> Result(process.Pid, Nil) {
  let AppChannels(app: app, ..) = channels
  app.runtime_owner()
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
// Transport dispatch — forward frame-level SPI calls from
// `beryl/transport` into the app runtime closures.
// ─────────────────────────────────────────────────────────────────────────────

// nolint: unused_exports -- package-internal dispatch for beryl/transport; hidden from public docs with @internal
@internal
pub fn transport_socket_connected(
  channels: Channels,
  socket_id: String,
  send: fn(String) -> Result(Nil, Nil),
  send_binary: fn(BitArray) -> Result(Nil, Nil),
  seed: event.ConnectSeed,
) -> Nil {
  let AppChannels(app: app, ..) = channels
  app.socket_connected(socket_id, send, send_binary, seed)
}

@internal
pub fn transport_register_closer(
  channels: Channels,
  socket_id: String,
  close: fn() -> Nil,
) -> Nil {
  let AppChannels(app: app, ..) = channels
  app.register_closer(socket_id, close)
}

@internal
pub fn transport_socket_disconnected(
  channels: Channels,
  socket_id: String,
) -> Nil {
  let AppChannels(app: app, ..) = channels
  app.socket_disconnected(socket_id)
}

@internal
pub fn transport_route_decoded(
  channels: Channels,
  socket_id: String,
  message: codec.Inbound,
) -> Nil {
  let AppChannels(app: app, ..) = channels
  app.route_decoded(socket_id, message)
}

@internal
pub fn transport_route_binary(
  channels: Channels,
  socket_id: String,
  data: BitArray,
) -> Nil {
  let AppChannels(app: app, ..) = channels
  app.route_binary(socket_id, data)
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
  let AppChannels(app: app, ..) = channels
  app.broadcast(topic_name, event, payload, None)
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
  let AppChannels(app: app, ..) = channels
  app.broadcast(topic_name, event, payload, Some(except_socket_id))
}
