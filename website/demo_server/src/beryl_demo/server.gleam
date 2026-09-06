//// Compose the beryl channel system, presence tracking, absolute scenario
//// expiry, and the Mist listener into a single hardened demo service.

import beryl
import beryl/channel
import beryl/presence
import beryl/transport/server as transport
import beryl/wire
import beryl_demo/config
import beryl_demo/expiry.{type Expiry}
import beryl_demo/presence_channel
import beryl_demo/router
import beryl_mist as mist_transport
import gleam/erlang/process
import gleam/otp/actor
import gleam/otp/static_supervisor.{type Supervisor}
import gleam/result
import mist

/// Origin policy applied to the WebSocket handshake.
///
/// - `AllowOrigins` pins an explicit allow-list (production and staging).
/// - `TestOnlyAllowAll` bypasses origin checks so integration tests can drive
///   raw Erlang WebSocket clients that never emit an `Origin` header.
pub type OriginMode {
  AllowOrigins(List(String))
  TestOnlyAllowAll
}

/// Handles returned by `start` that the caller owns for lifecycle management.
///
/// `supervisor` owns the beryl channel system; `listener` is the Mist
/// listener. Stop both, plus `expiry`, to tear the service down.
pub type Started {
  Started(
    port: Int,
    sockets: beryl.Sockets,
    expiry: Expiry,
    supervisor: actor.Started(Supervisor),
    listener: actor.Started(Supervisor),
  )
}

/// Why the demo service failed to start.
pub type StartError {
  PresenceNotStarted(reason: actor.StartError)
  ExpiryNotStarted(reason: actor.StartError)
  InvalidChannelSystem(reason: channel.ChildSpecError)
  SupervisorNotStarted(reason: actor.StartError)
  ListenerNotStarted(reason: actor.StartError)
  /// Mist started but did not report its bound port within five seconds.
  PortNotReported
}

/// Start the demo service and return handles for lifecycle management.
///
/// The returned `port` is the actual port Mist bound to (matches the
/// configured port unless the caller requested `0` for an ephemeral one).
pub fn start(
  service_config: config.Config,
  origin_mode: OriginMode,
) -> Result(Started, StartError) {
  use presence_actor <- result.try(
    presence.start(presence.default_config("beryl_demo@node"))
    |> result.map_error(PresenceNotStarted),
  )
  use expiry_actor <- result.try(
    expiry.start(service_config.session_ttl_ms)
    |> result.map_error(ExpiryNotStarted),
  )

  let beryl_config =
    beryl.config(wire.phoenix_codec())
    |> beryl.with_presence_handle(presence: presence_actor)
    |> beryl.with_heartbeat(timeout_ms: 60_000)
    |> beryl.with_max_connections(max_connections: 200)
    |> beryl.with_max_connections_per_ip(max_connections: 8)
    |> beryl.with_max_inbound_frame_bytes(max_bytes: 16 * 1024)
    |> beryl.with_max_joined_topics_per_socket(max_topics: 2)
    |> beryl.with_join_rate(per_second: 4, burst: 8)
    |> beryl.with_message_rate(per_second: 10, burst: 20)
  use #(sockets, channel_spec) <- result.try(
    channel.child_spec(beryl_config, handlers: [
      presence_channel.handler(presence_actor, expiry_actor),
    ])
    |> result.map_error(InvalidChannelSystem),
  )
  use supervisor <- result.try(
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(channel_spec)
    |> static_supervisor.start
    |> result.map_error(SupervisorNotStarted),
  )

  let port_subject = process.new_subject()
  use listener <- result.try(
    mist_transport.handler(
      sockets,
      transport_config(origin_mode),
      fn(http_request) { router.handle_request(http_request, service_config) },
    )
    |> mist.new
    |> mist.port(service_config.port)
    |> mist.bind(service_config.bind_address)
    |> mist.after_start(fn(port, _scheme, _ip_address) {
      process.send(port_subject, port)
    })
    |> mist.start
    |> result.map_error(ListenerNotStarted),
  )
  use port <- result.try(
    process.receive(port_subject, 5000)
    |> result.replace_error(PortNotReported),
  )
  Ok(Started(port:, sockets:, expiry: expiry_actor, supervisor:, listener:))
}

fn transport_config(
  origin_mode: OriginMode,
) -> transport.TransportConfig(mist.Connection) {
  let base = transport.default_config(config.socket_path)
  case origin_mode {
    AllowOrigins(origins) -> transport.with_allowed_origins(base, origins)
    TestOnlyAllowAll -> transport.with_allow_all_origins(base)
  }
}
