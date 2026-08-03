import beryl
import beryl/presence
import beryl/supervisor
import beryl/wire
import envoy
import gleam/int
import gleam/list
import gleam/option.{Some}
import gleam/otp/static_supervisor
import gleam/result
import gleam/string
import load_test/channel

pub type App {
  App(channels: beryl.Channels)
}

pub fn start() -> App {
  let beryl_config = environment_config()
  let base = supervisor.config(beryl_config)
  let channels = supervisor.channels(base)
  let presence_config =
    presence.default_config("load-test")
    |> presence.with_on_diff(fn(diff) {
      presence.diff_topics(diff)
      |> list.each(fn(topic) {
        beryl.broadcast_presence_diff(channels, topic, diff)
      })
    })
  let supervised = base |> supervisor.with_presence(presence_config)
  let assert Ok(_root) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(supervisor.start(supervised))
    |> static_supervisor.start()
  let channels = supervisor.channels(supervised)
  let assert Some(presence_actor) = supervisor.presence(supervised)
  let assert Ok(_) =
    beryl.register(
      channels,
      "bench:*",
      channel.benchmark(channels, presence_actor),
    )
  let assert Ok(_) =
    beryl.register(channels, "guardrail:forbidden", channel.forbidden())
  App(channels:)
}

pub fn port() -> Int {
  env_int("PORT", 8000)
}

pub fn bind_address() -> String {
  envoy.get("BIND_ADDRESS") |> result.unwrap("127.0.0.1")
}

fn environment_config() -> beryl.Config {
  let configured =
    beryl.config(wire.phoenix_codec())
    |> beryl.with_heartbeat(
      interval_ms: env_int("BERYL_HEARTBEAT_INTERVAL_MS", 30_000),
      timeout_ms: env_int("BERYL_HEARTBEAT_TIMEOUT_MS", 60_000),
    )
    |> beryl.with_max_connections_per_ip(max_connections: env_int(
      "BERYL_MAX_CONNECTIONS_PER_IP",
      0,
    ))
    |> beryl.with_max_connections(max_connections: env_int(
      "BERYL_MAX_CONNECTIONS",
      0,
    ))
    |> beryl.with_message_rate(
      per_second: env_int("BERYL_MESSAGE_RATE", 0),
      burst: env_int("BERYL_MESSAGE_BURST", 0),
    )
    |> beryl.with_join_rate(
      per_second: env_int("BERYL_JOIN_RATE", 0),
      burst: env_int("BERYL_JOIN_BURST", 0),
    )
    |> beryl.with_channel_rate(
      per_second: env_int("BERYL_CHANNEL_RATE", 0),
      burst: env_int("BERYL_CHANNEL_BURST", 0),
    )
    |> beryl.with_channel_rate_max_keys_per_socket(max_keys: env_int(
      "BERYL_CHANNEL_RATE_MAX_KEYS_PER_SOCKET",
      1000,
    ))
    |> beryl.with_max_topic_length(max_length: env_int(
      "BERYL_MAX_TOPIC_LENGTH",
      256,
    ))
    |> beryl.with_max_event_length(max_length: env_int(
      "BERYL_MAX_EVENT_LENGTH",
      64,
    ))
    |> beryl.with_max_inbound_frame_bytes(max_bytes: env_int(
      "BERYL_MAX_INBOUND_FRAME_BYTES",
      1_048_576,
    ))
    |> beryl.with_max_joined_topics_per_socket(max_topics: env_int(
      "BERYL_MAX_JOINED_TOPICS_PER_SOCKET",
      1000,
    ))
  case env_bool("BERYL_TELEMETRY", False) {
    True -> beryl.with_telemetry(configured)
    False -> configured
  }
}

fn env_int(name: String, default: Int) -> Int {
  envoy.get(name)
  |> result.try(int.parse)
  |> result.unwrap(default)
}

fn env_bool(name: String, default: Bool) -> Bool {
  case envoy.get(name) {
    Error(_) -> default
    Ok(value) ->
      case string.lowercase(value) {
        "1" -> True
        "true" -> True
        "yes" -> True
        "on" -> True
        _ -> False
      }
  }
}
