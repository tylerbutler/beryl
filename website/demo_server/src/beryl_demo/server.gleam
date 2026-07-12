//// Compose the beryl channels system, presence tracking, absolute scenario
//// expiry, and the Mist listener into a single hardened demo service.

import beryl
import beryl/presence
import beryl/transport/mist as mist_transport
import beryl/wire
import beryl_demo/config
import beryl_demo/expiry.{type Expiry}
import beryl_demo/presence_channel
import beryl_demo/router
import gleam/erlang/process
import gleam/list
import gleam/otp/actor
import gleam/otp/static_supervisor
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

/// Handle returned by `start`, exposing all handles the caller must own to
/// tear the service down cleanly.
pub type Started {
  Started(
    port: Int,
    channels: beryl.Channels,
    expiry: Expiry,
    supervisor: actor.Started(static_supervisor.Supervisor),
  )
}

/// Start the demo service and return handles for lifecycle management.
///
/// The returned `port` is the actual port Mist bound to (matches the
/// configured port unless the caller requested `0` for an ephemeral one).
pub fn start(
  service_config: config.Config,
  origin_mode: OriginMode,
) -> Result(Started, Nil) {
  case do_start(service_config, origin_mode) {
    Ok(started) -> Ok(started)
    Error(_) -> Error(Nil)
  }
}

type StartError {
  ChannelsStartError
  PresenceStartError
  ExpiryStartError
  ChannelRegisterError
  ListenerStartError
  PortNotReported
}

fn do_start(
  service_config: config.Config,
  origin_mode: OriginMode,
) -> Result(Started, StartError) {
  let beryl_config =
    beryl.config(wire.phoenix_codec())
    |> beryl.with_heartbeat(interval_ms: 30_000, timeout_ms: 60_000)
    |> beryl.with_max_connections(max_connections: 200)
    |> beryl.with_max_connections_per_ip(max_connections: 8)
    |> beryl.with_max_inbound_frame_bytes(max_bytes: 16 * 1024)
    |> beryl.with_max_joined_topics_per_socket(max_topics: 2)
    |> beryl.with_join_rate(per_second: 4, burst: 8)
    |> beryl.with_message_rate(per_second: 10, burst: 20)

  use channels <- try_map(beryl.start(beryl_config), ChannelsStartError)

  let presence_config =
    presence.default_config("beryl_demo@node")
    |> presence.with_on_diff(fn(diff) {
      presence.diff_topics(diff)
      |> list.each(fn(topic) {
        beryl.broadcast_presence_diff(channels, topic, diff)
      })
    })

  use presence_actor <- try_map(
    presence.start(presence_config),
    PresenceStartError,
  )

  use expiry_actor <- try_map(
    expiry.start(service_config.session_ttl_ms),
    ExpiryStartError,
  )

  let channel_handler =
    presence_channel.new(
      channels: channels,
      presence_actor: presence_actor,
      expiry_actor: expiry_actor,
    )
  use registered <- try_map(
    beryl.register(channels, "demo:presence:*", channel_handler),
    ChannelRegisterError,
  )

  expiry.initialize(expiry_actor, fn(socket_id, topic) {
    beryl.send_info(registered, socket_id, topic, presence_channel.Expire)
  })

  let transport_config = build_transport_config(origin_mode)

  let port_subject = process.new_subject()
  let handler =
    mist_transport.handler(channels, transport_config, fn(req) {
      router.handle_request(req, service_config)
    })

  let listener_result =
    handler
    |> mist.new
    |> mist.port(service_config.port)
    |> mist.bind(service_config.bind_address)
    |> mist.after_start(fn(port, _scheme, _ip_address) {
      process.send(port_subject, port)
    })
    |> mist.start

  case listener_result {
    Error(_) -> Error(ListenerStartError)
    Ok(supervisor) ->
      case process.receive(port_subject, 5000) {
        Error(_) -> Error(PortNotReported)
        Ok(actual_port) ->
          Ok(Started(
            port: actual_port,
            channels: channels,
            expiry: expiry_actor,
            supervisor: supervisor,
          ))
      }
  }
}

fn build_transport_config(
  origin_mode: OriginMode,
) -> mist_transport.TransportConfig(Nil) {
  let base = mist_transport.default_config(config.socket_path)
  case origin_mode {
    AllowOrigins(origins) -> mist_transport.with_allowed_origins(base, origins)
    TestOnlyAllowAll -> mist_transport.with_allow_all_origins(base)
  }
}

fn try_map(
  result: Result(a, error),
  wrap: StartError,
  next: fn(a) -> Result(b, StartError),
) -> Result(b, StartError) {
  case result {
    Ok(value) -> next(value)
    Error(_) -> Error(wrap)
  }
}
