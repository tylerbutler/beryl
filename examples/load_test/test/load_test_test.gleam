import beryl
import beryl/socket
import beryl/stats
import beryl/transport
import beryl/wire
import beryl/wire/codec
import gleam/erlang/process
import gleam/string
import gleeunit
import gleeunit/should
import load_test/channel
import load_test/ewe as ewe_http
import load_test/http
import load_test/mist as mist_http

pub fn main() {
  gleeunit.main()
}

fn start_system() -> beryl.Sockets {
  let assert Ok(sockets) =
    beryl.start(
      beryl.config(wire.phoenix_codec()),
      init: channel.init,
      update: channel.update,
    )
  sockets
}

fn connect(
  sockets: beryl.Sockets,
  socket_id: String,
) -> process.Subject(String) {
  let sent = process.new_subject()
  transport.socket_connected(
    sockets: sockets,
    socket_id: socket_id,
    send: fn(message) {
      process.send(sent, message)
      Ok(Nil)
    },
    send_binary: fn(_) { Ok(Nil) },
    seed: socket.empty_seed(),
  )
  process.sleep(10)
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
  event: String,
  payload: String,
) -> Nil {
  route(
    sockets,
    socket_id,
    "[\"join-ref\",\"message-ref\",\"bench:fanout\",\""
      <> event
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
  http.stats_error(stats.CoordinatorUnavailable).status |> should.equal(503)
  http.stats_error(stats.RequestTimedOut).status |> should.equal(504)
}

pub fn stats_include_beryl_and_beam_snapshots_test() {
  let endpoint = http.stats(start_system())
  endpoint.status |> should.equal(200)
  endpoint.body |> string.contains("\"beryl\"") |> should.be_true
  endpoint.body |> string.contains("\"beam\"") |> should.be_true
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
