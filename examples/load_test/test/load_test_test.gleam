import beryl
import beryl/rate_limit
import beryl/socket
import beryl/stats
import beryl/transport
import beryl/wire
import beryl/wire/codec
import envoy
import example_helpers/session_presence
import gleam/erlang/process
import gleam/option.{type Option, None, Some}
import gleam/otp/static_supervisor
import gleam/string
import gleeunit/should
import load_test/app as load_app
import load_test/channel
import load_test/ewe as ewe_http
import load_test/http
import load_test/mist as mist_http
import vouch

@external(erlang, "load_test_test_ffi", "run_after")
fn run_after(run: fn() -> value, cleanup: fn() -> Nil) -> value

pub fn main() {
  vouch.main()
}

fn start_system() -> beryl.Sockets {
  let presence_tracker = session_presence.start()
  let assert Ok(#(sockets, spec)) =
    beryl.child_spec(
      beryl.config(wire.phoenix_codec()),
      init: channel.init,
      update: fn(model, input) {
        channel.update(presence_tracker, model, input)
      },
    )
  session_presence.configure(presence_tracker, sockets)
  let assert Ok(_) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(spec)
    |> static_supervisor.start()
  sockets
}

fn connect(
  sockets: beryl.Sockets,
  socket_id: String,
) -> process.Subject(String) {
  let sent = process.new_subject()
  let assert Ok(owner) = transport.runtime_pid(sockets)
  transport.admit_socket(
    sockets: sockets,
    owner: owner,
    socket_id: socket_id,
    send: fn(message) {
      process.send(sent, message)
      Ok(Nil)
    },
    send_binary: fn(_) { Ok(Nil) },
    codec: None,
    seed: socket.empty_seed(),
    close: fn() { Nil },
  )
  |> should.equal(Ok(Nil))
  sent
}

fn route(sockets: beryl.Sockets, socket_id: String, raw: String) -> Nil {
  let assert Ok(message) =
    codec.decode_text(transport.active_codec(sockets))(raw)
  transport.route_decoded(sockets, socket_id, message)
}

fn join(sockets: beryl.Sockets, socket_id: String, topic: String) -> Nil {
  route(
    sockets,
    socket_id,
    "[\"join-ref\",\"join-ref\",\"" <> topic <> "\",\"phx_join\",{}]",
  )
}

fn push(
  sockets: beryl.Sockets,
  socket_id: String,
  event_name: String,
  payload: String,
) -> Nil {
  route(
    sockets,
    socket_id,
    "[\"join-ref\",\"message-ref\",\"bench:fanout\",\""
      <> event_name
      <> "\","
      <> payload
      <> "]",
  )
}

fn recv(subject: process.Subject(String)) -> String {
  let assert Ok(message) = process.receive(subject, 500)
  message
}

pub fn health_endpoint_test() {
  let endpoint = http.health()
  endpoint.status |> should.equal(200)
  endpoint.body |> should.equal("{\"status\":\"ok\"}")
  mist_http.from_endpoint(endpoint).status |> should.equal(200)
  ewe_http.from_endpoint(endpoint).status |> should.equal(200)
}

pub fn stats_errors_have_typed_http_statuses_test() {
  let unavailable = http.stats_error(stats.RuntimeUnavailable)
  unavailable.status |> should.equal(503)
  unavailable.body
  |> should.equal("{\"error\":\"runtime_unavailable\"}")

  let timed_out = http.stats_error(stats.RequestTimedOut)
  timed_out.status |> should.equal(504)
  timed_out.body |> should.equal("{\"error\":\"runtime_timeout\"}")
}

pub fn stats_include_beryl_and_beam_snapshots_test() {
  let endpoint = http.stats(start_system())
  endpoint.status |> should.equal(200)
  endpoint.body |> string.contains("\"beryl\"") |> should.be_true
  endpoint.body |> string.contains("\"beam\"") |> should.be_true
  endpoint.body
  |> string.contains("\"connected_sockets\"")
  |> should.be_true
}

pub fn forbidden_topic_rejects_join_test() {
  let sockets = start_system()
  let frames = connect(sockets, "forbidden")
  join(sockets, "forbidden", "guardrail:forbidden")
  recv(frames) |> string.contains("forbidden") |> should.be_true
}

pub fn echo_replies_with_unchanged_payload_test() {
  let sockets = start_system()
  let frames = connect(sockets, "echo")
  join(sockets, "echo", "bench:fanout")
  let _ = recv(frames)
  push(
    sockets,
    "echo",
    "echo",
    "{\"marker\":\"same\",\"sent_at\":123,\"publisher_id\":\"publisher\"}",
  )
  let reply = recv(frames)
  reply |> string.contains("\"marker\":\"same\"") |> should.be_true
  reply |> string.contains("\"sent_at\":123") |> should.be_true
}

pub fn broadcast_fans_out_full_payload_test() {
  let sockets = start_system()
  let publisher = connect(sockets, "publisher")
  let peer = connect(sockets, "peer")
  join(sockets, "publisher", "bench:fanout")
  let _ = recv(publisher)
  join(sockets, "peer", "bench:fanout")
  let _ = recv(peer)

  push(
    sockets,
    "publisher",
    "broadcast",
    "{\"marker\":\"fanout-1\",\"sent_at\":123456,\"publisher_id\":\"publisher\"}",
  )

  let publisher_messages = recv(publisher) <> recv(publisher)
  publisher_messages |> string.contains("fanout-1") |> should.be_true
  recv(peer) |> string.contains("fanout-1") |> should.be_true
}

pub fn app_configures_frame_rate_from_environment_test() {
  with_env_values(
    [
      #("BERYL_HEARTBEAT_TIMEOUT_MS", None),
      #("BERYL_MAX_CONNECTIONS_PER_IP", None),
      #("BERYL_MAX_CONNECTIONS", None),
      #("BERYL_FRAME_RATE", Some("10")),
      #("BERYL_FRAME_BURST", Some("20")),
      #("BERYL_MESSAGE_RATE", None),
      #("BERYL_MESSAGE_BURST", None),
      #("BERYL_JOIN_RATE", None),
      #("BERYL_JOIN_BURST", None),
      #("BERYL_CHANNEL_RATE", None),
      #("BERYL_CHANNEL_BURST", None),
      #("BERYL_CHANNEL_RATE_MAX_KEYS_PER_SOCKET", None),
      #("BERYL_MAX_TOPIC_LENGTH", None),
      #("BERYL_MAX_EVENT_LENGTH", None),
      #("BERYL_MAX_INBOUND_FRAME_BYTES", None),
      #("BERYL_MAX_JOINED_TOPICS_PER_SOCKET", None),
      #("BERYL_TELEMETRY", None),
    ],
    fn() {
      let load_app.App(sockets) = load_app.start()
      beryl.frame_limits(sockets)
      |> should.equal(
        Some(rate_limit.RateLimitConfig(per_second: 10, burst: 20)),
      )
    },
  )
}

fn with_env_values(
  values: List(#(String, Option(String))),
  run: fn() -> value,
) -> value {
  case values {
    [] -> run()
    [#(name, value), ..rest] ->
      with_env_value(name, value, fn() { with_env_values(rest, run) })
  }
}

fn with_env_value(name: String, value: Option(String), run: fn() -> a) -> a {
  let previous = envoy.get(name)
  case value {
    Some(value) -> envoy.set(name, value)
    None -> envoy.unset(name)
  }

  run_after(run, fn() {
    case previous {
      Ok(value) -> envoy.set(name, value)
      Error(Nil) -> envoy.unset(name)
    }
  })
}
