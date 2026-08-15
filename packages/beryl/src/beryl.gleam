//// Beryl - Type-safe real-time communication
////
//// A standalone Gleam library for building real-time applications on the BEAM.
//// Provides app-side WebSocket dispatch, distributed presence tracking,
//// pub/sub messaging, and topic groups.
////
//// ## Features
////
//// - **Sockets** — App-side dispatch: topic-based WebSocket messaging
////   routed by your `update` function (`beryl`, `beryl/socket`)
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
//// import beryl/socket.{AcceptJoin, Broadcast, Join, Message, Next}
//// import beryl/pubsub
//// import beryl/wire
//// import gleam/option
//// import gleam/otp/static_supervisor
////
//// pub fn main() {
////   // Optional: start PubSub for distributed messaging
////   let ps = pubsub.start(pubsub.default_config())
////
////   // Build the supervised system. The app supplies `init` (the per-socket
////   // model) and `update` (which routes every event by topic).
////   let config = beryl.config(wire.phoenix_codec()) |> beryl.with_pubsub(ps)
////   let assert Ok(#(sockets, spec)) =
////     beryl.child_spec(
////       config,
////       init: fn(_info) { #(Nil, []) },
////       update: fn(model, ev) {
////         case ev {
////           Join("room:" <> _, _payload, ref) ->
////             Next(model, [AcceptJoin(ref, option.None)])
////           Message(topic, "new_msg", payload, _ref) ->
////             Next(model, [Broadcast(topic, "new_msg", payload)])
////           _ -> Next(model, [])
////         }
////       },
////     )
////   let assert Ok(_root) =
////     static_supervisor.new(static_supervisor.OneForOne)
////     |> static_supervisor.add(spec)
////     |> static_supervisor.start()
////
////   // Broadcast to all subscribers of a topic
////   beryl.broadcast(sockets, "room:lobby", "announce", payload)
//// }
//// ```

import beryl/app_supervisor
import beryl/connection_limit
import beryl/internal
import beryl/log
import beryl/presence.{type Diff}
import beryl/presence/wire as presence_wire
import beryl/pubsub.{type PubSub}
import beryl/rate_limit
import beryl/runtime
import beryl/socket
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

/// Configuration for an app-side socket runtime.
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
    /// reaching the app's `update` function.
    max_topic_length: Int,
    /// Maximum byte length for client-supplied event name strings (default: 64).
    /// Events exceeding this limit are dropped before reaching the app's `update`
    /// function.
    max_event_length: Int,
    /// Maximum inbound WebSocket frame size in bytes (default: 1 MiB).
    /// Frames exceeding this limit are closed before wire decoding.
    max_inbound_frame_bytes: Int,
    /// Maximum joined topics per socket (default: 1000).
    /// Values <= 0 disable the cap.
    max_joined_topics_per_socket: Int,
    /// Whether beryl emits `:telemetry` events (default: false).
    telemetry: Bool,
    /// Logging configuration for Beryl diagnostics
    logging: LoggingConfig,
    /// Per-topic-pattern message rate limits (app-dispatch systems only).
    /// Ordered; the first matching pattern wins.
    topic_rates: List(#(String, rate_limit.RateLimitConfig)),
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
    telemetry: False,
    logging: logging_config(level: InfoLevel, include_payloads: False),
    topic_rates: [],
  )
}

/// Configure a per-topic-pattern message rate limit for an app-dispatch
/// runtime built with `child_spec`.
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

/// Add PubSub to a configuration for distributed broadcasts
pub fn with_pubsub(config: Config, ps: PubSub(json.Json)) -> Config {
  Config(..config, pubsub: Some(ps))
}

/// Enable beryl's `:telemetry` events.
pub fn with_telemetry(config: Config) -> Config {
  Config(..config, telemetry: True)
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
/// be at least 2; smaller values are rejected by `child_spec` and
/// `validate_config` with `HeartbeatTimeoutTooLow` because a check interval
/// of 0 would disable eviction. The defaults are 30000 ms and 60000 ms
/// respectively.
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
/// it (before allocating any long-lived per-socket runtime state) otherwise;
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
/// node's process, socket, and runtime budget — a case a per-IP limit alone
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

// nolint: unused_exports -- public logging builder intended for downstream users
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
/// error before reaching your `update` function, bounding the size of keys
/// tracked per socket. The default is 256.
pub fn with_max_topic_length(
  config: Config,
  max_length max_length: Int,
) -> Config {
  Config(..config, max_topic_length: max_length)
}

/// Configure the maximum allowed byte length for client-supplied event name
/// strings.
///
/// Event names longer than `max_length` bytes are dropped before reaching the
/// app's `update` function. The default is 64.
pub fn with_max_event_length(
  config: Config,
  max_length max_length: Int,
) -> Config {
  Config(..config, max_event_length: max_length)
}

// nolint: unused_exports -- enforced in sibling transport handler tests
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

/// Warn when an app-side socket runtime starts with every abuse control
/// disabled.
///
/// Beryl ships with rate and connection limits off (like Phoenix) because
/// no default is right for every deployment — but running that way in
/// production leaves the server open to trivial floods, so the choice
/// should be a visible one. Called while building the `child_spec` subtree.
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

/// Per-socket message rate limits for transports, `None` when unlimited.
///
/// Transports enforce this with a local token bucket per connection so
/// flooded sockets are shed at the edge, before frames are decoded or
/// enqueued on the runtime.
@internal
pub fn message_limits(channels: Sockets) -> Option(rate_limit.RateLimitConfig) {
  optional_limits(channels.config.message_rate, channels.config.message_burst)
}

/// Runtime system handle.
///
/// This opaque handle is returned with the supervised subtree from
/// `child_spec` and passed to broadcast, group, and transport functions. Its
/// internals are intentionally hidden so Beryl can evolve them without
/// breaking application code.
///
/// The handle is deliberately non-generic: an app-side dispatch system is
/// generic over the application's `model`/`msg`, but those types are sealed
/// inside the monomorphic closures captured at construction time, so they
/// never appear in this handle or in any transport signature.
pub opaque type Sockets {
  Sockets(
    config: Config,
    connection_limiter: Option(connection_limit.ConnectionLimiter),
    app: AppHandle,
  )
}

/// Monomorphic closures over a generic runtime actor, captured by
/// `child_spec`. This is what lets the frame-level transport SPI stay
/// unparameterized while the runtime holds typed per-socket models.
@internal
pub type AppHandle {
  AppHandle(
    admit_socket: fn(
      process.Pid,
      String,
      fn(String) -> Result(Nil, Nil),
      fn(BitArray) -> Result(Nil, Nil),
      Option(codec.Codec),
      socket.ConnectSeed,
      fn() -> Nil,
    ) -> Bool,
    socket_disconnected: fn(String) -> Nil,
    route_decoded: fn(String, codec.Inbound) -> Nil,
    route_decoded_binary: fn(String, codec.Inbound) -> Nil,
    route_binary: fn(String, BitArray) -> Nil,
    broadcast: fn(String, String, json.Json, Option(String)) -> Nil,
    stop: fn() -> Result(Nil, StopError),
    /// Current pid of the supervised runtime, if running (used by tests
    /// and PubSub sender attribution).
    runtime_owner: fn() -> Result(process.Pid, Nil),
    stats: fn() -> Result(#(Int, Int, Int, Int), Bool),
  )
}

/// The wire codec configured for this system.
@internal
pub fn configured_codec(channels: Sockets) -> codec.Codec {
  channels.config.codec
}

@internal
pub fn channels_telemetry_enabled(channels: Sockets) -> Bool {
  channels.config.telemetry
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
  channels: Sockets,
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
pub fn max_inbound_frame_bytes(channels: Sockets) -> Int {
  channels.config.max_inbound_frame_bytes
}

/// Why an eagerly validated `Config` was rejected before any process started.
///
/// `child_spec` validates the configuration before allocating names or
/// starting the runtime, so an invalid configuration fails fast instead of
/// crashing a supervised child at init time.
pub type ConfigError {
  /// `heartbeat_timeout_ms` was below the minimum. The server derives its
  /// staleness check interval as `heartbeat_timeout_ms / 2` (integer
  /// division), so a timeout of 1 would round down to a check interval of 0 —
  /// which disables heartbeat eviction entirely. The wrapped `Int` is the
  /// smallest accepted timeout.
  HeartbeatTimeoutTooLow(minimum: Int)
  /// A per-topic-pattern rate limit used a pattern string that is not a valid
  /// topic pattern. `pattern` is the offending pattern and `reason` describes
  /// the problem.
  InvalidTopicPattern(pattern: String, reason: String)
}

/// Errors when stopping a Beryl system with [`stop`](#stop).
pub type StopError {
  /// The handle referred to a system that was not running: it was never
  /// started (for example, a `child_spec` handle whose supervisor was never
  /// added to a running tree) or it has already been stopped. `stop` is safe
  /// to call in these cases; it reports `NotRunning` rather than crashing.
  NotRunning
  /// The runtime did not acknowledge the stop request within the shutdown
  /// window. The system may still be terminating.
  StopTimeout
}

/// Eagerly validate a [`Config`](#config) without starting anything.
///
/// This checks that `heartbeat_timeout_ms` is at least 2 and that every
/// per-topic rate-limit pattern is valid.
pub fn validate_config(config: Config) -> Result(Nil, ConfigError) {
  use <- bool.guard(
    when: config.heartbeat_timeout_ms < 2,
    return: internal.result_error(HeartbeatTimeoutTooLow(2)),
  )
  list.try_each(config.topic_rates, fn(entry) {
    let #(pattern, _limits) = entry
    topic.validate_pattern(pattern)
    |> result.map_error(fn(error) {
      InvalidTopicPattern(pattern, topic_error_reason(error))
    })
  })
}

fn topic_error_reason(error: topic.TopicError) -> String {
  case error {
    topic.EmptyTopic -> "pattern cannot be empty"
    topic.InvalidFormat(reason) -> reason
  }
}

/// Stop a Beryl system.
///
/// This drains the supervised runtime and stops it, delivering `Closed` to
/// every joined topic before closing each transport connection. Presence is
/// application-owned and is not stopped by this function. The runtime is a
/// `Transient` child, so it is not restarted after a graceful stop.
///
/// `stop` is safe to call more than once and on a handle whose system was
/// never started: in those cases it returns `Error(NotRunning)` rather than
/// crashing. It returns `Error(StopTimeout)` if the app runtime does not
/// acknowledge the stop within the shutdown window. After a successful stop
/// the handle should no longer be used.
pub fn stop(sockets: Sockets) -> Result(Nil, StopError) {
  // The app-side dispatch limiter is supervised inside the Beryl subtree,
  // so it is not stopped directly here; it is torn down with the subtree.
  stop_app_subtree(sockets.app, sockets.connection_limiter)
}

/// Gracefully stop only the nested Beryl subtree and wait for it to
/// terminate.
///
/// The runtime is the subtree's significant transient child, so draining and
/// stopping it (normal termination) auto-shuts down the subtree supervisor and
/// its sibling limiter. To honour "wait for only the Beryl subtree to
/// terminate", the runtime and the optional limiter processes are monitored
/// before the drain and their `Down` messages are awaited afterwards; the
/// application's parent supervisor and sibling children are never touched.
///
/// Idempotent: `Error(NotRunning)` when the runtime is already down (pre-start,
/// a restart window, or a prior stop); `Error(StopTimeout)` if the runtime does
/// not acknowledge the drain or the subtree does not terminate in time.
fn stop_app_subtree(
  app: AppHandle,
  connection_limiter: Option(connection_limit.ConnectionLimiter),
) -> Result(Nil, StopError) {
  case app.runtime_owner() {
    Error(Nil) -> internal.result_error(NotRunning)
    Ok(runtime_pid) -> {
      let runtime_monitor = process.monitor(runtime_pid)
      let limiter_monitor =
        option.from_result(app_limiter_owner(connection_limiter))
        |> option.map(process.monitor)
      // Drain sockets (deliver `Closed` and close transports) and stop the
      // runtime; this triggers the subtree auto-shutdown.
      case app.stop() {
        Error(error) -> {
          drop_subtree_monitors(runtime_monitor, limiter_monitor)
          Error(error)
        }
        Ok(Nil) -> await_subtree_down(runtime_monitor, limiter_monitor)
      }
    }
  }
}

/// Release the subtree monitors taken before a drain that failed, so the
/// caller's mailbox does not collect their later `Down` messages.
fn drop_subtree_monitors(
  runtime_monitor: process.Monitor,
  limiter_monitor: Option(process.Monitor),
) -> Nil {
  process.demonitor_process(runtime_monitor)
  case limiter_monitor {
    Some(monitor) -> process.demonitor_process(monitor)
    None -> Nil
  }
}

/// Wait for the runtime and, when one is supervised, the sibling limiter to
/// terminate. `Error(StopTimeout)` when either is still alive at the deadline.
fn await_subtree_down(
  runtime_monitor: process.Monitor,
  limiter_monitor: Option(process.Monitor),
) -> Result(Nil, StopError) {
  let awaited =
    await_down(runtime_monitor)
    |> result.try(fn(_) {
      case limiter_monitor {
        Some(monitor) -> await_down(monitor)
        None -> Ok(Nil)
      }
    })
  case awaited {
    Ok(Nil) -> Ok(Nil)
    Error(Nil) -> internal.result_error(StopTimeout)
  }
}

/// The pid of the app subtree's optional limiter, if it is running.
fn app_limiter_owner(
  connection_limiter: Option(connection_limit.ConnectionLimiter),
) -> Result(process.Pid, Nil) {
  case connection_limiter {
    Some(limiter) -> connection_limit.pid(limiter)
    None -> Error(Nil)
  }
}

/// Wait for a monitored process's `Down` message, returning `Error(Nil)` on
/// timeout so the caller can report `StopTimeout`.
fn await_down(monitor: process.Monitor) -> Result(Nil, Nil) {
  let selector =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(_down) { Nil })
  process.selector_receive(selector, 5000)
}

/// Build the app-side dispatch supervision child specification.
///
/// Add the returned specification to the application's own supervision tree.
/// The configuration is validated eagerly, before the application's supervisor
/// starts, rather than crashing a supervised child at init time.
///
/// The returned `Sockets` handle is name-backed and usable immediately, even
/// before the supervision tree that owns the returned child specification is
/// started. Before startup, during a runtime restart window, and after
/// shutdown, fire-and-forget handle operations are no-ops and connection
/// admission fails cleanly rather than panicking.
///
/// ## Example
///
/// ```gleam
/// let assert Ok(#(sockets, spec)) =
///   beryl.child_spec(beryl.config(wire.phoenix_codec()), init:, update:)
///
/// let assert Ok(_root) =
///   static_supervisor.new(static_supervisor.OneForOne)
///   |> static_supervisor.add(spec)
///   |> static_supervisor.start()
///
/// // `sockets` is usable once the tree above is running.
/// ```
pub fn child_spec(
  config: Config,
  init init: fn(socket.ConnectInfo(msg)) -> #(model, List(socket.Effect)),
  update update: fn(model, socket.Input(msg)) -> socket.Next(model, msg),
) -> Result(
  #(Sockets, supervision.ChildSpecification(static_supervisor.Supervisor)),
  ConfigError,
) {
  use subtree <- result.map(build_app_subtree(config, init, update))
  // The subtree is a `Transient` child of the application's supervisor: a
  // graceful `beryl.stop` auto-shuts the subtree down with reason `shutdown`,
  // which a transient child treats as normal, so the parent does not restart
  // Beryl. A genuine crash (subtree restart intensity exceeded) still gets
  // restarted by the parent.
  #(
    subtree.handle,
    supervision.supervisor(subtree.start_supervisor)
      |> supervision.restart(supervision.Transient),
  )
}

/// A validated, name-allocated app-side dispatch subtree that has not been
/// started yet.
///
/// `handle` is the stable, non-generic `Sockets` returned to callers before
/// startup. `start_supervisor` starts the nested Beryl subtree; the generic
/// `init`/`update` closures are captured inside it, so `AppSubtree` itself
/// stays non-generic.
type AppSubtree {
  AppSubtree(
    handle: Sockets,
    start_supervisor: fn() ->
      Result(actor.Started(static_supervisor.Supervisor), actor.StartError),
  )
}

/// Validate the config, allocate the runtime and (optional) limiter names
/// once, and build the supervised subtree.
///
/// Names are allocated here so the returned `Sockets` handle is stable before
/// the subtree starts: the runtime is reached through its registered name and
/// the limiter through `connection_limit.from_name`, so the handle keeps
/// working across supervised runtime restarts. There is no unsupervised app
/// runtime — the runtime always runs under the nested Beryl supervisor, with
/// the `init`/`update` closures captured in the child specification. A runtime
/// crash therefore restarts dispatch automatically (per-socket state is
/// dropped). The runtime child is `Transient` so a graceful `stop` is not
/// resurrected.
fn build_app_subtree(
  config: Config,
  init: fn(socket.ConnectInfo(msg)) -> #(model, List(socket.Effect)),
  update: fn(model, socket.Input(msg)) -> socket.Next(model, msg),
) -> Result(AppSubtree, ConfigError) {
  use _ <- result.map(validate_config(config))
  warn_if_unprotected(config)

  let runtime_name = process.new_name("beryl_runtime")
  let supervisor_name = process.new_name("beryl_app_supervisor")
  let limiter_name = case
    connection_limit.enabled(
      config.max_connections_per_ip,
      config.max_connections,
    )
  {
    True -> Some(process.new_name("beryl_connection_limiter"))
    False -> None
  }

  let handle =
    Sockets(
      config: config,
      connection_limiter: option.map(limiter_name, connection_limit.from_name),
      app: app_handle(
        process.named_subject(runtime_name),
        process.named_subject(supervisor_name),
        config.pubsub,
      ),
    )

  AppSubtree(handle: handle, start_supervisor: fn() {
    app_supervisor.start(
      supervisor_name,
      stop_runtime(process.named_subject(runtime_name), _),
      fn() {
        child_spec_supervisor(config, runtime_name, limiter_name, init, update)
      },
    )
  })
}

/// Start the nested Beryl subtree: a one-for-one supervisor owning the runtime
/// as a transient child, with the optional connection limiter as a sibling.
fn child_spec_supervisor(
  config: Config,
  runtime_name: process.Name(runtime.Msg(msg)),
  limiter_name: Option(process.Name(connection_limit.Message)),
  init: fn(socket.ConnectInfo(msg)) -> #(model, List(socket.Effect)),
  update: fn(model, socket.Input(msg)) -> socket.Next(model, msg),
) -> Result(actor.Started(static_supervisor.Supervisor), actor.StartError) {
  let runtime_child =
    supervision.worker(fn() {
      runtime.start_named(
        to_runtime_config(config),
        name: runtime_name,
        pubsub: config.pubsub,
        init: init,
        update: update,
      )
      |> result.map_error(runtime_start_error)
    })
    |> supervision.restart(supervision.Transient)
    // The runtime is the subtree's significant child: a graceful stop (normal
    // termination) auto-shuts down the whole Beryl subtree — including the
    // sibling limiter — while an abnormal crash is restarted in place under
    // the same name (dispatch resumes with fresh per-socket state).
    |> supervision.significant(True)

  let builder =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.restart_tolerance(intensity: 3, period: 5)
    |> static_supervisor.auto_shutdown(static_supervisor.AnySignificant)
    |> static_supervisor.add(runtime_child)

  let builder = case limiter_name {
    Some(name) ->
      builder
      |> static_supervisor.add(
        supervision.worker(fn() {
          connection_limit.start_named(
            config.max_connections_per_ip,
            config.max_connections,
            name,
          )
        }),
      )
    None -> builder
  }

  static_supervisor.start(builder)
}

fn runtime_start_error(error: runtime.StartError) -> actor.StartError {
  case error {
    runtime.ActorStartFailed(error) -> error
    runtime.InvalidHeartbeatTimeout ->
      actor.InitFailed("invalid heartbeat timeout")
  }
}

fn await_admission(
  reply: Subject(Bool),
  admission: runtime.AdmissionToken,
) -> Bool {
  case process.receive(reply, 1000) {
    Ok(admitted) -> admitted
    Error(Nil) -> !runtime.cancel_admission(admission)
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
  supervisor: Subject(app_supervisor.Message),
  ps: Option(PubSub(json.Json)),
) -> AppHandle {
  AppHandle(
    admit_socket: fn(
      owner,
      socket_id,
      send,
      send_binary,
      socket_codec,
      seed,
      close,
    ) {
      case process.subject_owner(subject) {
        Ok(current_owner) if current_owner == owner -> {
          let reply = process.new_subject()
          let admission = runtime.new_admission_token()
          process.send(
            subject,
            runtime.AdmitSocket(
              owner,
              socket_id,
              send,
              send_binary,
              socket_codec,
              seed,
              close,
              admission,
              reply,
            ),
          )
          await_admission(reply, admission)
        }
        _ -> False
      }
    },
    socket_disconnected: fn(socket_id) {
      send_runtime(subject, runtime.SocketDisconnected(socket_id))
    },
    route_decoded: fn(socket_id, msg) {
      send_runtime(subject, runtime.RouteDecoded(socket_id, msg))
    },
    route_decoded_binary: fn(socket_id, msg) {
      send_runtime(subject, runtime.RouteDecodedBinary(socket_id, msg))
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
    stop: fn() { request_runtime_stop(supervisor) },
    runtime_owner: fn() { process.subject_owner(subject) },
    stats: fn() {
      case process.subject_owner(subject) {
        Error(Nil) -> Error(False)
        Ok(_) -> {
          let reply = process.new_subject()
          send_runtime(subject, runtime.GetStats(reply))
          case process.receive(reply, 1000) {
            Error(Nil) -> Error(True)
            Ok(snapshot) ->
              Ok(#(
                snapshot.connected_sockets,
                snapshot.joined_socket_topic_pairs,
                snapshot.active_topics,
                snapshot.runtime_mailbox_length,
              ))
          }
        }
      }
    },
  )
}

// Record the intentional stop before asking the runtime to drain, so
// restart-intensity exhaustion remains distinguishable from shutdown.
fn request_runtime_stop(
  supervisor: Subject(app_supervisor.Message),
) -> Result(Nil, StopError) {
  use _ <- result.try(ensure_supervisor_running(supervisor))
  let started = process.new_subject()
  let finished = process.new_subject()
  process.send(supervisor, app_supervisor.StopRuntime(started, finished))

  case process.receive(started, 1000) {
    Ok(False) -> internal.result_error(NotRunning)
    Error(Nil) -> internal.result_error(StopTimeout)
    Ok(True) ->
      case process.receive(finished, 5000) {
        Ok(True) -> Ok(Nil)
        Ok(False) -> internal.result_error(StopTimeout)
        Error(Nil) -> internal.result_error(StopTimeout)
      }
  }
}

fn ensure_supervisor_running(
  supervisor: Subject(app_supervisor.Message),
) -> Result(Nil, StopError) {
  case process.subject_owner(supervisor) {
    Ok(_) -> Ok(Nil)
    Error(Nil) -> internal.result_error(NotRunning)
  }
}

fn stop_runtime(
  subject: Subject(runtime.Msg(msg)),
  finished: Subject(Nil),
) -> Result(process.Monitor, Nil) {
  case process.subject_owner(subject) {
    Error(Nil) -> Error(Nil)
    Ok(pid) -> {
      let monitor = process.monitor(pid)
      process.send(subject, runtime.Stop(finished))
      Ok(monitor)
    }
  }
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

@internal
pub fn app_runtime_pid(channels: Sockets) -> Result(process.Pid, Nil) {
  channels.app.runtime_owner()
}

/// The pid of the app subtree's optional connection limiter, if running.
@internal
pub fn app_limiter_pid(channels: Sockets) -> Result(process.Pid, Nil) {
  app_limiter_owner(channels.connection_limiter)
}

fn to_runtime_config(config: Config) -> runtime.Config {
  runtime.Config(
    codec: config.codec,
    // Server checks at half the timeout interval validated by `child_spec`.
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
    telemetry: config.telemetry,
    logging: internal_logging_config(config.logging),
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
// Transport dispatch — forward the frame-level SPI in `beryl/transport` to the
// app runtime closures captured by `child_spec`.
// ─────────────────────────────────────────────────────────────────────────────

@internal
pub fn app_dispatch(sockets: Sockets) -> AppHandle {
  sockets.app
}

@internal
pub fn transport_admit_socket(
  channels: Sockets,
  owner: Option(process.Pid),
  socket_id: String,
  send: fn(String) -> Result(Nil, Nil),
  send_binary: fn(BitArray) -> Result(Nil, Nil),
  socket_codec: Option(codec.Codec),
  seed: socket.ConnectSeed,
  close: fn() -> Nil,
) -> Bool {
  case owner {
    Some(runtime_owner) ->
      channels.app.admit_socket(
        runtime_owner,
        socket_id,
        send,
        send_binary,
        socket_codec,
        seed,
        close,
      )
    None -> False
  }
}

@internal
pub fn transport_socket_disconnected(
  channels: Sockets,
  socket_id: String,
) -> Nil {
  channels.app.socket_disconnected(socket_id)
}

@internal
pub fn transport_route_decoded(
  channels: Sockets,
  socket_id: String,
  message: codec.Inbound,
) -> Nil {
  channels.app.route_decoded(socket_id, message)
}

@internal
pub fn transport_route_decoded_binary(
  channels: Sockets,
  socket_id: String,
  message: codec.Inbound,
) -> Nil {
  channels.app.route_decoded_binary(socket_id, message)
}

@internal
pub fn transport_route_binary(
  channels: Sockets,
  socket_id: String,
  data: BitArray,
) -> Nil {
  channels.app.route_binary(socket_id, data)
}

/// Broadcast a message to all subscribers of a topic
///
/// This sends the message to all sockets subscribed to the topic. When the
/// system was started with PubSub, the broadcast is also distributed to
/// subscribers on other nodes.
///
/// ## Example
///
/// ```gleam
/// beryl.broadcast(
///   sockets,
///   "room:lobby",
///   "new_message",
///   json.object([#("text", json.string("Hello!"))]),
/// )
/// ```
pub fn broadcast(
  channels: Sockets,
  topic_name: String,
  event: String,
  payload: json.Json,
) -> Nil {
  channels.app.broadcast(topic_name, event, payload, None)
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
/// When the system was started with PubSub, the broadcast is distributed
/// using the same semantics as `broadcast`.
pub fn broadcast_presence_diff(
  channels: Sockets,
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
/// nodes so clustered deployments do not echo the event back to that
/// socket on another node.
///
/// ## Example
///
/// ```gleam
/// beryl.broadcast_from(
///   sockets,
///   socket_id,
///   "room:lobby",
///   "user_typing",
///   json.object([#("user", json.string("alice"))]),
/// )
/// ```
pub fn broadcast_from(
  channels: Sockets,
  except_socket_id: String,
  topic_name: String,
  event: String,
  payload: json.Json,
) -> Nil {
  channels.app.broadcast(topic_name, event, payload, Some(except_socket_id))
}
