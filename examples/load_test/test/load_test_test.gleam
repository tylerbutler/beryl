import beryl
import beryl/channel
import beryl/coordinator
import beryl/internal/unsupervised
import beryl/presence
import beryl/socket
import beryl/stats
import beryl/wire
import gleam/dynamic
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/json
import gleam/option.{None}
import gleam/string
import gleeunit
import gleeunit/should
import load_test/channel as benchmark_channel
import load_test/ewe as ewe_http
import load_test/http
import load_test/mist as mist_http

pub fn main() {
  gleeunit.main()
}

fn dynamic_payload(source: String) {
  let assert Ok(value) = json.parse(source, using: decode.dynamic)
  value
}

fn test_socket() {
  let transport =
    socket.new_transport(
      send_text: fn(_) { Ok(Nil) },
      send_binary: fn(_) { Ok(Nil) },
      close: fn() { Ok(Nil) },
    )
  socket.new("socket-test", Nil, transport)
}

fn connect_socket(
  channels: beryl.Channels,
  socket_id: String,
) -> process.Subject(String) {
  let sent = process.new_subject()
  process.send(
    beryl.coordinator_subject(channels),
    coordinator.SocketConnected(
      socket_id,
      fn(message) {
        process.send(sent, message)
        Ok(Nil)
      },
      fn(_) { Ok(Nil) },
      None,
      dynamic.nil(),
    ),
  )
  process.sleep(10)
  sent
}

fn join(
  channels: beryl.Channels,
  socket_id: String,
  sent: process.Subject(String),
) -> Nil {
  coordinator.route_message(
    beryl.coordinator_subject(channels),
    socket_id,
    "[\"join\",\"join\",\"bench:fanout\",\"phx_join\",{}]",
  )
  let assert Ok(reply) = process.receive(sent, 500)
  reply |> string.contains("\"status\":\"ok\"") |> should.be_true
}

fn push(
  channels: beryl.Channels,
  socket_id: String,
  reference: String,
  event: String,
  payload: String,
) -> Nil {
  coordinator.route_message(
    beryl.coordinator_subject(channels),
    socket_id,
    "[\"join\",\""
      <> reference
      <> "\",\"bench:fanout\",\""
      <> event
      <> "\","
      <> payload
      <> "]",
  )
}

fn receive_message(sent: process.Subject(String)) -> String {
  let assert Ok(message) = process.receive(sent, 500)
  message
}

fn assert_full_fanout_payload(message: String) -> Nil {
  message |> string.contains("\"marker\":\"fanout-1\"") |> should.be_true
  message |> string.contains("\"sent_at\":123456") |> should.be_true
  message
  |> string.contains("\"publisher_id\":\"publisher\"")
  |> should.be_true
}

pub fn health_endpoint_test() {
  let endpoint = http.health()
  endpoint.status |> should.equal(200)
  endpoint.body |> should.equal("{\"status\":\"ok\"}")
  mist_http.from_endpoint(endpoint).status |> should.equal(200)
  ewe_http.from_endpoint(endpoint).status |> should.equal(200)
}

pub fn stats_errors_have_typed_http_statuses_test() {
  let unavailable = http.stats_error(stats.CoordinatorUnavailable)
  unavailable.status |> should.equal(503)
  unavailable.body
  |> string.contains("coordinator_unavailable")
  |> should.be_true

  let timed_out = http.stats_error(stats.RequestTimedOut)
  timed_out.status |> should.equal(504)
  timed_out.body |> string.contains("coordinator_timeout") |> should.be_true
}

pub fn stats_include_beryl_and_beam_snapshots_test() {
  let assert Ok(channels) =
    unsupervised.start(beryl.config(wire.phoenix_codec()))
  let endpoint = http.stats(channels)
  endpoint.status |> should.equal(200)
  endpoint.body |> string.contains("\"beryl\"") |> should.be_true
  endpoint.body |> string.contains("\"beam\"") |> should.be_true
}

pub fn forbidden_channel_rejects_join_test() {
  case
    benchmark_channel.forbidden_join(
      "guardrail:forbidden",
      dynamic_payload("{}"),
      test_socket(),
    )
  {
    channel.JoinError(..) -> True
    _ -> False
  }
  |> should.be_true
}

pub fn echo_replies_ok_with_unchanged_payload_test() {
  let assert channel.Reply(event:, payload:, ..) =
    benchmark_channel.echo_reply(
      dynamic_payload(
        "{\"marker\":\"same\",\"sent_at\":123,\"publisher_id\":\"publisher\"}",
      ),
      test_socket(),
    )
  event |> should.equal("echo")
  json.to_string(payload)
  |> should.equal(
    "{\"marker\":\"same\",\"publisher_id\":\"publisher\",\"sent_at\":123}",
  )
}

pub fn broadcast_and_distinct_peer_acks_fan_out_full_payload_test() {
  let assert Ok(channels) =
    unsupervised.start(beryl.config(wire.phoenix_codec()))
  let assert Ok(presence_actor) =
    presence.start(presence.default_config("load-test-contract"))
  let assert Ok(_) =
    beryl.register(
      channels,
      "bench:*",
      benchmark_channel.benchmark(channels, presence_actor),
    )

  let publisher = connect_socket(channels, "publisher-socket")
  let peer_one = connect_socket(channels, "peer-one-socket")
  let peer_two = connect_socket(channels, "peer-two-socket")
  join(channels, "publisher-socket", publisher)
  join(channels, "peer-one-socket", peer_one)
  join(channels, "peer-two-socket", peer_two)

  let broadcast_payload =
    "{\"marker\":\"fanout-1\",\"sent_at\":123456,\"publisher_id\":\"publisher\"}"
  push(
    channels,
    "publisher-socket",
    "broadcast-ref",
    "broadcast",
    broadcast_payload,
  )

  let publisher_messages =
    receive_message(publisher) <> receive_message(publisher)
  publisher_messages
  |> string.contains("\"broadcast\"")
  |> should.be_true
  publisher_messages
  |> string.contains("\"status\":\"ok\"")
  |> should.be_true
  assert_full_fanout_payload(publisher_messages)
  assert_full_fanout_payload(receive_message(peer_one))
  assert_full_fanout_payload(receive_message(peer_two))

  let ack_one =
    "{\"marker\":\"fanout-1\",\"sent_at\":123456,\"publisher_id\":\"publisher\",\"recipient_id\":\"peer-one\"}"
  push(channels, "peer-one-socket", "ack-one-ref", "broadcast_ack", ack_one)
  let publisher_ack_one = receive_message(publisher)
  publisher_ack_one
  |> string.contains("\"broadcast_ack\"")
  |> should.be_true
  assert_full_fanout_payload(publisher_ack_one)
  publisher_ack_one
  |> string.contains("\"recipient_id\":\"peer-one\"")
  |> should.be_true
  let peer_one_ack_messages =
    receive_message(peer_one) <> receive_message(peer_one)
  peer_one_ack_messages
  |> string.contains("\"status\":\"ok\"")
  |> should.be_true
  peer_one_ack_messages
  |> string.contains("\"recipient_id\":\"peer-one\"")
  |> should.be_true
  // ACKs fan out to every joined peer, not only the original publisher.
  receive_message(peer_two)
  |> string.contains("\"recipient_id\":\"peer-one\"")
  |> should.be_true

  let ack_two =
    "{\"marker\":\"fanout-1\",\"sent_at\":123456,\"publisher_id\":\"publisher\",\"recipient_id\":\"peer-two\"}"
  push(channels, "peer-two-socket", "ack-two-ref", "broadcast_ack", ack_two)
  let publisher_ack_two = receive_message(publisher)
  publisher_ack_two
  |> string.contains("\"broadcast_ack\"")
  |> should.be_true
  assert_full_fanout_payload(publisher_ack_two)
  publisher_ack_two
  |> string.contains("\"recipient_id\":\"peer-two\"")
  |> should.be_true
  let peer_two_ack_messages =
    receive_message(peer_two) <> receive_message(peer_two)
  peer_two_ack_messages
  |> string.contains("\"status\":\"ok\"")
  |> should.be_true
  peer_two_ack_messages
  |> string.contains("\"recipient_id\":\"peer-two\"")
  |> should.be_true
  publisher_ack_one |> should.not_equal(publisher_ack_two)
}
