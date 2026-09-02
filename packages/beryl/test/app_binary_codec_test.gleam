//// Binary-decoder codec parity for app-side dispatch. A codec with a binary
//// decoder routes binary join/event frames through normal dispatch, replies
//// over the binary transport (never text), consumes one message-rate token
//// per binary event, and encodes broadcasts through the binary send path.

import app_test_helper
import beryl
import beryl/socket.{AcceptJoin, Broadcast, Join, Message, Next, ReplyOk}
import beryl/transport
import binary_test_codec
import gleam/bit_array
import gleam/erlang/process
import gleam/json
import gleam/option.{None, Some}
import gleeunit/should

fn start_system() -> beryl.Sockets {
  start_with(beryl.config(binary_test_codec.new()))
}

fn start_with(config: beryl.Config) -> beryl.Sockets {
  let assert Ok(channels) =
    app_test_helper.start_app(
      config,
      init: fn(_info) { #(Nil, []) },
      update: fn(model, ev) {
        case ev {
          Join(_, _, ref) ->
            Next(model, [
              AcceptJoin(ref, Some(json.object([#("joined", json.bool(True))]))),
            ])
          Message(_topic, "ping", _payload, Some(ref)) ->
            Next(model, [ReplyOk(ref, json.object([#("ok", json.bool(True))]))])
          Message(topic, "cast", _payload, _ref) ->
            Next(model, [
              Broadcast(
                topic,
                "announcement",
                json.object([#("body", json.string("hello"))]),
              ),
            ])
          _ -> Next(model, [])
        }
      },
    )
  channels
}

fn connect_binary(
  channels: beryl.Sockets,
  socket_id: String,
) -> #(process.Subject(String), process.Subject(BitArray)) {
  let text = process.new_subject()
  let binary = process.new_subject()
  let assert Ok(owner) = transport.runtime_pid(channels)
  transport.admit_socket(
    sockets: channels,
    owner: owner,
    socket_id: socket_id,
    send: fn(message) {
      process.send(text, message)
      Ok(Nil)
    },
    send_binary: fn(data) {
      process.send(binary, data)
      Ok(Nil)
    },
    codec: None,
    seed: socket.empty_seed(),
    close: fn() { Nil },
  )
  |> should.equal(Ok(Nil))
  #(text, binary)
}

fn recv_binary(subject: process.Subject(BitArray)) -> String {
  let assert Ok(bits) = process.receive(subject, 500)
  let assert Ok(text) = bit_array.to_string(bits)
  text
}

fn route_binary(
  channels: beryl.Sockets,
  socket_id: String,
  raw: String,
) -> Nil {
  transport.route_binary(channels, socket_id, bit_array.from_string(raw))
}

pub fn binary_join_and_event_route_and_reply_over_binary_test() -> Nil {
  let channels = start_system()
  let #(text, binary) = connect_binary(channels, "s1")

  route_binary(channels, "s1", "J|join-ref|join-1|room:lobby|{}")
  recv_binary(binary)
  |> should.equal("R|join-1|room:lobby|ok|{\"joined\":true}")

  route_binary(channels, "s1", "E|event-1|room:lobby|ping|{}")
  recv_binary(binary)
  |> should.equal("R|event-1|room:lobby|ok|{\"ok\":true}")

  // Nothing was ever written to the text transport.
  process.receive(text, 50) |> should.be_error
}

pub fn binary_event_consumes_one_message_rate_token_test() -> Nil {
  let channels =
    start_with(
      beryl.config(binary_test_codec.new())
      |> beryl.with_message_rate(per_second: 100, burst: 1),
    )
  let #(_text, binary) = connect_binary(channels, "s1")
  route_binary(channels, "s1", "J|join-ref|join-1|room:lobby|{}")
  let _join_reply = recv_binary(binary)

  // The first event takes the single token and replies; the second is shed.
  route_binary(channels, "s1", "E|event-1|room:lobby|ping|{}")
  recv_binary(binary)
  |> should.equal("R|event-1|room:lobby|ok|{\"ok\":true}")

  route_binary(channels, "s1", "E|event-2|room:lobby|ping|{}")
  process.receive(binary, 100) |> should.be_error
}

pub fn binary_broadcast_uses_binary_send_test() -> Nil {
  let channels = start_system()
  let #(text, binary) = connect_binary(channels, "s1")
  route_binary(channels, "s1", "J|join-ref|join-1|room:lobby|{}")
  let _join_reply = recv_binary(binary)

  // A Broadcast effect is encoded through the codec's binary push encoder.
  route_binary(channels, "s1", "E|cast-1|room:lobby|cast|{}")
  recv_binary(binary)
  |> should.equal("P|room:lobby|announcement|{\"body\":\"hello\"}")
  process.receive(text, 50) |> should.be_error
}

pub fn undecodable_binary_frame_is_dropped_test() -> Nil {
  let channels = start_system()
  let #(text, binary) = connect_binary(channels, "s1")
  route_binary(channels, "s1", "J|join-ref|join-1|room:lobby|{}")
  let _join_reply = recv_binary(binary)

  // An undecodable binary frame is dropped by the decoder codec before
  // dispatch: no reply, and nothing is fanned out raw.
  route_binary(channels, "s1", "not-a-valid-frame")
  process.receive(binary, 100) |> should.be_error

  // A following valid event still routes and replies (liveness + ordering).
  route_binary(channels, "s1", "E|event-1|room:lobby|ping|{}")
  recv_binary(binary)
  |> should.equal("R|event-1|room:lobby|ok|{\"ok\":true}")
  process.receive(text, 50) |> should.be_error
}
